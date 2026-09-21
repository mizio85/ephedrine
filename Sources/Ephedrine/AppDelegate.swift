//
//  AppDelegate.swift
//  Ephedrine
//
//  Central controller. Owns the status item, the popover, the monitor loop and all the state
//  that decides whether the Mac should be kept awake.
//
//  Monitor loop (one `tick()` every `pollInterval` seconds, default 2 s):
//
//     1. read settings (external `defaults write` changes are picked up automatically)
//     2. read session-state files written by the agent integrations
//     3. scan the process table for monitored agents and sample their CPU usage
//     4. classify every detected process as working / waiting
//     5. decide whether to hold the power assertions, honouring mode, grace period and AC-only
//     6. engage/release assertions, toggle closed-display sleep, refresh icon + popover model
//
//  Classification rules, in priority order (all documented in `activityKind` and
//  `fallbackActivity`):
//
//     state==busy                                    → working
//     state==idle, integration reports busy too       → waiting (authoritative)
//     state==idle, integration reports idle only      → CPU ≥ 5% ⇒ working (new turn), else waiting
//     no state, respectSessionState on                → CPU ≥ 5% ⇒ working, else waiting
//     no state, requireCPUActivity on                 → CPU ≥ 3% ⇒ working, else waiting
//     no state, both off                              → process presence ⇒ always working
//
//  Grace period: after the last "working" observation the assertions stay engaged for
//  `gracePeriod` seconds, so short gaps (LLM thinking, tool restarts) never release the Mac.
//

import AppKit
import ServiceManagement
import SwiftUI

/// `NSHostingController` that keeps the popover in sync with the SwiftUI content size.
///
/// Without this, expanding the "Avanzate" disclosure would leave the popover clipped, because
/// `NSPopover` only resizes when its `contentSize` is updated explicitly.
@MainActor
private final class PopoverHostingController<Content: View>: NSHostingController<Content> {
    weak var popover: NSPopover?

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let popover, popover.isShown else { return }
        let fitting = view.fittingSize
        guard fitting.height > 80, fitting.width > 0 else { return }
        if abs(popover.contentSize.height - fitting.height) > 1 || abs(popover.contentSize.width - fitting.width) > 1 {
            popover.contentSize = fitting
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // Collaborators
    private let settings = Settings.shared
    private let power = PowerManager()
    private let detector = AgentDetector()

    // UI
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private lazy var model = MenuModel(delegate: self)

    // Monitor loop
    private var tickTimer: Timer?

    // Latest observation, consumed by the menu bar icon, the tooltip and the popover model.
    private var currentAgents: [DetectedAgent] = []
    private var sessionSnapshot = SessionStateSnapshot(states: [])
    private var lastAgentSeen: Date?
    private var lastActivityDeclared: Date?
    private var isKeepingAwake = false
    private var pausedForBattery = false
    private var closedDisplayError: String?
    /// True once the Always-mode maximum duration has elapsed: forces release until the user
    /// switches mode or changes the limit.
    private var maxDurationElapsed = false

    // Cached UI state: avoid rebuilding images/strings (and invalidating SwiftUI) every tick.
    private var appliedIconState: IconState?
    private var lastTooltip: String?

    /// Last time the actual `disablesleep` value was verified against our bookkeeping flag.
    private var lastClosedDisplayCheck: Date?

    /// The four menu bar icon variants.
    private enum IconState: Hashable {
        case active    // an agent is working → green filled cup
        case grace     // nothing working yet, within grace → orange hourglass
        case standby   // armed, nothing to do → template outline cup
        case disabled  // mode Off → dimmed outline cup
    }

    /// SF Symbols are parsed system-side on every `NSImage(systemSymbolName:)` call, so each
    /// variant is built once and reused.
    private lazy var iconCache: [IconState: NSImage?] = [
        .active: Self.symbolImage("cup.and.saucer.fill", color: .systemGreen),
        .grace: Self.symbolImage("hourglass", color: .systemOrange),
        .standby: Self.symbolImage("cup.and.saucer", color: nil),
        .disabled: Self.symbolImage("cup.and.saucer", color: nil)
    ]

    private static func symbolImage(_ name: String, color: NSColor?) -> NSImage? {
        guard let color else {
            // Template image: macOS tints it like the other menu bar icons.
            let image = NSImage(systemSymbolName: name, accessibilityDescription: "Ephedrine")
            image?.isTemplate = true
            return image
        }
        let configuration = NSImage.SymbolConfiguration(paletteColors: [color])
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Ephedrine")?
            .withSymbolConfiguration(configuration)
        // Coloured images must not be treated as templates, otherwise the colour is dropped.
        image?.isTemplate = false
        return image
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageOnly
        }

        popover.behavior = .transient       // closes when clicking outside
        popover.animates = true
        let hosting = PopoverHostingController(rootView: MenuView(model: model))
        hosting.popover = popover
        popover.contentViewController = hosting

        // If a previous run left `disablesleep 1` behind (crash, force quit), repair it now.
        restoreStaleClosedDisplay()

        // After every system wake the lid setting must be verified again: macOS can drop or
        // ignore it across sleep and power-source transitions without notifying us.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        updateStatusItem()
        refreshModel(full: false)
        startTimer()
        tick()
    }

    func applicationWillTerminate(_ notification: Notification) {
        tickTimer?.invalidate()
        power.releaseAll()
        shutdownClosedDisplay()
    }

    /// Left click on the status item: open/close the popover.
    @objc private func togglePopover() {        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            refreshModel(full: true) // heavy sections (integrations, pmset state) are read on open
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// (Re)starts the monitor timer. `.common` mode keeps it firing while a menu/popover is open.
    private func startTimer() {
        tickTimer?.invalidate()
        let timer = Timer(timeInterval: settings.pollInterval, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    // MARK: - Monitoring

    @objc private func tick() {
        let now = Date()

        // Mode Off: release everything and skip detection entirely (no process scanning at all).
        guard settings.mode != .off else {
            currentAgents = []
            sessionSnapshot = SessionStateSnapshot(states: [])
            lastAgentSeen = nil
            pausedForBattery = false
            maxDurationElapsed = false
            settings.sessionStartedAt = 0
            applyState(wantAwake: false)
            return
        }

        // 1. Session state from integrations (skipped when the user disables it).
        sessionSnapshot = settings.respectSessionState
            ? SessionStateStore.shared.snapshot()
            : SessionStateSnapshot(states: [])

        // 2. Process detection + CPU sampling.
        var agents = detector.detect(patterns: settings.enabledPatterns)

        // 3. Classification.
        var working: [DetectedAgent] = []
        for index in agents.indices {
            let state = sessionSnapshot.state(for: agents[index])
            agents[index].activity = activityKind(for: agents[index], state: state)
            if agents[index].activity == .working {
                working.append(agents[index])
            }
        }
        currentAgents = agents
        if !working.isEmpty { lastAgentSeen = now }

        // 4. Decision.
        let withinGrace = graceRemaining(now: now) > 0
        var wantAwake = false
        switch settings.mode {
        case .always:
            wantAwake = true
        case .auto:
            wantAwake = !working.isEmpty || withinGrace
        case .off:
            wantAwake = false
        }

        // 5. AC-only gate.
        // Maximum duration cap (Always mode only; in Auto the agents themselves define the end).
        if wantAwake, settings.mode == .always, settings.maxDuration > 0 {
            let started = settings.sessionStartedAt
            if started <= 0 {
                // First tick of a new session: start counting now.
                settings.sessionStartedAt = now.timeIntervalSince1970
            } else if now.timeIntervalSince1970 - started >= settings.maxDuration {
                maxDurationElapsed = true
            }
            if maxDurationElapsed { wantAwake = false }
        }

        pausedForBattery = false
        if wantAwake, settings.onlyOnAC, !PowerManager.isOnACPower {
            wantAwake = false
            pausedForBattery = true
        }

        applyState(wantAwake: wantAwake)
    }

    /// Seconds left before the maximum-duration cap releases the Mac (0 when unlimited/expired).
    private func maxDurationRemaining(now: Date) -> TimeInterval {
        guard settings.maxDuration > 0, settings.mode == .always, settings.sessionStartedAt > 0 else { return 0 }
        let endsAt = settings.sessionStartedAt + settings.maxDuration
        return max(0, endsAt - now.timeIntervalSince1970)
    }

    /// Decides whether a single detected process is working or waiting.
    ///
    /// See the file header for the full priority table.
    private func activityKind(for agent: DetectedAgent, state: AgentSessionState?) -> AgentActivity {
        guard settings.respectSessionState else {
            return fallbackActivity(for: agent)
        }

        if let state {
            switch state.status {
            case .busy:
                return .working
            case .idle:
                // Integrations that can only report the end of a turn (Codex `notify`) fall back
                // to CPU activity to detect the start of the next one.
                if !state.reportsBusy, let cpu = agent.cpuPercent, cpu >= Settings.busyOverrideThreshold {
                    return .working
                }
                return .waiting
            }
        }

        return fallbackActivity(for: agent)
    }

    /// Classification for agents with no session state (no integration installed).
    private func fallbackActivity(for agent: DetectedAgent) -> AgentActivity {
        if settings.requireCPUActivity {
            guard let cpu = agent.cpuPercent else { return .working }
            return cpu >= Settings.cpuThreshold ? .working : .waiting
        }
        if settings.respectSessionState {
            // First sample after a process appears has no CPU fraction yet: assume working to
            // avoid a one-tick "waiting" flicker.
            guard let cpu = agent.cpuPercent else { return .working }
            return cpu >= Settings.busyOverrideThreshold ? .working : .waiting
        }
        // Both helpers disabled: classic behaviour, presence alone keeps the Mac awake.
        return .working
    }

    /// Engages or releases everything according to `wantAwake`.
    private func applyState(wantAwake: Bool) {
        isKeepingAwake = wantAwake
        let now = Date()

        if wantAwake {
            let reason = assertionReason(now: now)
            power.engage(
                reason: reason,
                preventDisplay: settings.preventDisplaySleep,
                preventSystemSleep: settings.preventSystemSleepOnAC && PowerManager.isOnACPower
            )
            power.updateReason(reason)

            // Optional "simulate user activity" heartbeat (resets screensaver/lock timers).
            if settings.simulateActivity {
                if lastActivityDeclared == nil || now.timeIntervalSince(lastActivityDeclared!) >= settings.activityInterval {
                    power.declareUserActivity(reason: "Ephedrine user activity")
                    lastActivityDeclared = now
                }
            } else {
                lastActivityDeclared = nil
            }
        } else {
            power.releaseAll()
            lastActivityDeclared = nil
        }

        updateClosedDisplay(wantAwake: wantAwake)
        verifyClosedDisplay(now: now)
        updateStatusItem()
        refreshModel(full: popover.isShown)
    }

    // MARK: - Closed display (lid closed)

    /// Mirrors `pmset -a disablesleep` with the desired state, using the privileged helper.
    /// Only touches the system when the desired state actually changes.
    private func updateClosedDisplay(wantAwake: Bool) {
        let shouldEngage = wantAwake && settings.closedDisplayMode
        guard shouldEngage != settings.closedDisplayEngaged else { return }

        if shouldEngage {
            guard ClosedDisplayHelper.shared.isInstalled else {
                settings.closedDisplayMode = false
                closedDisplayError = "Supporto non installato"
                return
            }
            if ClosedDisplayHelper.shared.setEnabled(true) {
                settings.closedDisplayEngaged = true
                closedDisplayError = nil
            } else {
                settings.closedDisplayMode = false
                settings.closedDisplayEngaged = false
                closedDisplayError = "Attivazione non riuscita (serve il supporto admin)"
            }
        } else {
            guard ClosedDisplayHelper.shared.isInstalled else {
                settings.closedDisplayEngaged = false
                closedDisplayError = "Supporto rimosso: lo sleep da coperchio può restare disattivato"
                return
            }
            if ClosedDisplayHelper.shared.setEnabled(false) {
                settings.closedDisplayEngaged = false
                closedDisplayError = nil
            }
        }
    }

    /// Crash recovery: if the persisted flag says `disablesleep` may still be active, turn it off.
    private func restoreStaleClosedDisplay() {
        if settings.closedDisplayEngaged {
            if ClosedDisplayHelper.shared.isInstalled {
                _ = ClosedDisplayHelper.shared.setEnabled(false)
            }
            settings.closedDisplayEngaged = false
        }
    }

    /// Called by `NSWorkspace` after every system wake: force a full re-evaluation.
    @objc private func systemDidWake() {
        lastClosedDisplayCheck = nil
        tick()
    }

    /// Re-applies `disablesleep` when the system silently dropped it. This was observed across
    /// sleep/wake cycles and power-source transitions: the persisted flag cannot detect the drift,
    /// so the real system value is verified periodically (and immediately after a wake).
    /// Only acts when this app is the one that enabled it.
    private func verifyClosedDisplay(now: Date) {
        guard settings.closedDisplayEngaged, settings.closedDisplayMode,
              ClosedDisplayHelper.shared.isInstalled else { return }
        if let last = lastClosedDisplayCheck, now.timeIntervalSince(last) < 30 { return }
        lastClosedDisplayCheck = now
        if !ClosedDisplayHelper.shared.systemSleepDisabled() {
            _ = ClosedDisplayHelper.shared.setEnabled(true)
        }
    }

    /// Normal termination path: never leave lid-close sleep disabled behind.
    private func shutdownClosedDisplay() {
        if settings.closedDisplayEngaged, ClosedDisplayHelper.shared.isInstalled {
            _ = ClosedDisplayHelper.shared.setEnabled(false)
        }
        settings.closedDisplayEngaged = false
    }

    // MARK: - Derived state

    /// Seconds left before the grace period expires (0 when inactive).
    private func graceRemaining(now: Date) -> TimeInterval {
        guard settings.gracePeriod > 0, let lastSeen = lastAgentSeen else { return 0 }
        return max(0, settings.gracePeriod - now.timeIntervalSince(lastSeen))
    }

    /// User-visible name for the held assertions (`pmset -g assertions`). Kept ASCII on purpose:
    /// `pmset` prints assertion names with a lossy C-string conversion.
    private func assertionReason(now: Date) -> String {
        let working = currentAgents.filter { $0.activity == .working }
        if !working.isEmpty {
            var names: [String] = []
            for agent in working where !names.contains(agent.pattern) {
                names.append(agent.pattern)
            }
            return "Ephedrine - agent attivi: " + names.joined(separator: ", ")
        }
        if settings.mode == .always { return "Ephedrine - sempre attivo" }
        if graceRemaining(now: now) > 0 { return "Ephedrine - periodo di grazia" }
        return "Ephedrine"
    }

    // MARK: - Status item

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        let state: IconState
        if isKeepingAwake {
            state = .active
        } else if settings.mode == .off {
            state = .disabled
        } else if graceRemaining(now: Date()) > 0 {
            state = .grace
        } else {
            state = .standby
        }

        // Reassign only on change: keeps AppKit (and the GPU) idle most of the time.
        if state != appliedIconState {
            button.image = iconCache[state] ?? nil
            button.appearsDisabled = state == .disabled
            appliedIconState = state
        }

        let tooltip = tooltip()
        if tooltip != lastTooltip {
            button.toolTip = tooltip
            lastTooltip = tooltip
        }
    }

    private func tooltip() -> String {
        var lines = [statusSummary()]
        if pausedForBattery {
            lines.append("Solo su alimentazione AC: collega il caricatore per riprendere.")
        }
        if settings.closedDisplayEngaged {
            lines.append("Sleep da coperchio disattivato (pmset disablesleep).")
        }
        lines.append("Click per le opzioni")
        return lines.joined(separator: "\n")
    }

    private var closedDisplaySuffix: String {
        settings.closedDisplayEngaged ? " · coperchio chiuso" : ""
    }

    /// One-line status used both for the tooltip and (indirectly) the popover header.
    private func statusSummary() -> String {
        if settings.mode == .off { return "Ephedrine — Off" }
        if pausedForBattery { return "Ephedrine — in pausa (batteria)" }
        if isKeepingAwake {
            let working = currentAgents.filter { $0.activity == .working }.count
            let waiting = currentAgents.count - working
            if working > 0 {
                var text = "Ephedrine — Mac sveglio (\(working) agent\(working == 1 ? "e" : "i") attiv\(working == 1 ? "o" : "i")"
                if waiting > 0 { text += ", \(waiting) in attesa" }
                return text + ")\(closedDisplaySuffix)"
            }
            if waiting > 0 { return "Ephedrine — Mac sveglio (grazia, \(waiting) in attesa)\(closedDisplaySuffix)" }
            if settings.mode == .always { return "Ephedrine — Mac sveglio (sempre attivo)\(closedDisplaySuffix)" }
            return "Ephedrine — Mac sveglio (grazia)\(closedDisplaySuffix)"
        }
        return "Ephedrine — in attesa di agent"
    }

    // MARK: - Popover model

    /// Pushes the current state into the observable model.
    /// - Parameter full: also refresh expensive sections (integration files, `pmset` state).
    ///   Only requested when the popover is visible.
    private func refreshModel(full: Bool) {
        // Scalars (differential assignment: no SwiftUI invalidation when unchanged).
        assign(\.mode, settings.mode)
        assign(\.preventDisplaySleep, settings.preventDisplaySleep)
        assign(\.preventSystemSleepOnAC, settings.preventSystemSleepOnAC)
        assign(\.simulateActivity, settings.simulateActivity)
        assign(\.onlyOnAC, settings.onlyOnAC)
        assign(\.requireCPUActivity, settings.requireCPUActivity)
        assign(\.respectSessionState, settings.respectSessionState)
        assign(\.closedDisplayMode, settings.closedDisplayMode)
        assign(\.launchAtLogin, launchAtLoginEnabled)
        assign(\.gracePeriod, settings.gracePeriod)
        assign(\.pollInterval, settings.pollInterval)
        assign(\.activityInterval, settings.activityInterval)
        assign(\.maxDuration, settings.maxDuration)
        assign(\.maxDurationElapsed, maxDurationElapsed)
        assign(\.errorMessage, power.lastError ?? closedDisplayError)

        // Monitored patterns.
        let watchItems = settings.allPatterns.map {
            MenuModel.WatchItem(id: $0, name: $0, enabled: settings.isPatternEnabled($0))
        }
        assign(\.watchItems, watchItems)

        // Aggregate detected processes per pattern (keeps the list readable: one row per agent).
        var groups: [String: (count: Int, working: Bool, cpu: Double)] = [:]
        for agent in currentAgents {
            var entry = groups[agent.pattern] ?? (0, false, 0)
            entry.count += 1
            entry.working = entry.working || agent.activity == .working
            entry.cpu += agent.cpuPercent ?? 0
            groups[agent.pattern] = entry
        }
        let agentGroups = groups
            .map { MenuModel.AgentGroup(id: $0.key, name: $0.key, count: $0.value.count, working: $0.value.working, cpuPercent: $0.value.cpu) }
            .sorted { ($0.working ? 0 : 1, $0.name) < ($1.working ? 0 : 1, $1.name) }
        assign(\.agentGroups, agentGroups)

        // Header text/symbol.
        let now = Date()
        // A stale "elapsed" flag from a previous session must not survive a fresh start.
        if maxDurationElapsed, settings.maxDuration > 0, settings.sessionStartedAt > 0,
           Date().timeIntervalSince1970 - settings.sessionStartedAt < settings.maxDuration {
            maxDurationElapsed = false
        }
        if maxDurationElapsed {
            assign(\.statusTitle, "Timer scaduto")
            assign(\.statusSubtitle, "Caffè terminato: Mac di nuovo in standby")
            assign(\.statusSymbol, "timer")
            assign(\.statusTone, MenuModel.Tone.warning)
        } else if settings.mode == .off {
            assign(\.statusTitle, "Disattivato")
            assign(\.statusSubtitle, "Nessun monitoraggio")
            assign(\.statusSymbol, "cup.and.saucer")
            assign(\.statusTone, MenuModel.Tone.off)
        } else if pausedForBattery {
            assign(\.statusTitle, "In pausa")
            assign(\.statusSubtitle, "Solo su AC: collega il caricatore")
            assign(\.statusSymbol, "powerplug")
            assign(\.statusTone, MenuModel.Tone.warning)
        } else if isKeepingAwake {
            assign(\.statusTitle, "Mac sveglio")
            assign(\.statusSymbol, "cup.and.saucer.fill")
            assign(\.statusTone, MenuModel.Tone.active)
            let workingGroups = agentGroups.filter(\.working)
            var subtitle: String
            if !workingGroups.isEmpty {
                let names = workingGroups.map(\.name)
                subtitle = names.count > 3
                    ? "\(names.count) agent al lavoro"
                    : names.joined(separator: ", ") + " al lavoro"
            } else if graceRemaining(now: now) > 0 {
                assign(\.statusSymbol, "hourglass")
                assign(\.statusTone, MenuModel.Tone.waiting)
                subtitle = "Grazia: \(Int(graceRemaining(now: now).rounded())) s"
            } else if settings.maxDuration > 0 {
                let remaining = maxDurationRemaining(now: now)
                subtitle = "Sempre attivo · restano \(Self.shortDuration(remaining))"
            } else {
                subtitle = "Sempre attivo"
            }
            if settings.closedDisplayEngaged { subtitle += " · coperchio chiuso" }
            assign(\.statusSubtitle, subtitle)
        } else {
            assign(\.statusTitle, "Standby")
            assign(\.statusSubtitle, currentAgents.isEmpty ? "In attesa di agent" : "Agent in attesa di input")
            assign(\.statusSymbol, "cup.and.saucer")
            assign(\.statusTone, MenuModel.Tone.waiting)
        }

        // Expensive sections, only while the popover is visible.
        if full {
            let integrations = Integration.allCases.map {
                MenuModel.IntegrationRow(id: $0.rawValue, title: $0.title, installed: $0.isInstalled)
            }
            assign(\.integrations, integrations)
            assign(\.sessionSummary, sessionSnapshot.summary)

            let installed = ClosedDisplayHelper.shared.isInstalled
            assign(\.closedDisplayInstalled, installed)
            if installed {
                assign(\.closedDisplayDetail, ClosedDisplayHelper.shared.systemSleepDisabled()
                    ? "Sleep da coperchio disattivato"
                    : "Sleep da coperchio normale")
            } else {
                assign(\.closedDisplayDetail, "Supporto non installato (password admin al primo uso)")
            }
        }
    }

    /// Short duration label for the header countdown ("1h 05m", "3 min").
    private static func shortDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 { return String(format: "%dh %02dm", total / 3600, (total % 3600) / 60) }
        if total >= 60 { return "\(total / 60) min" }
        return "\(total) s"
    }

    /// Assigns a model property only when the value actually changed.
    private func assign<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<MenuModel, T>, _ value: T) {
        if model[keyPath: keyPath] != value {
            model[keyPath: keyPath] = value
        }
    }

    // MARK: - Actions from the popover

    func setMode(_ mode: KeepAwakeMode) {
        settings.mode = mode
        // Any mode change starts a fresh session: the cap applies from now.
        settings.sessionStartedAt = 0
        maxDurationElapsed = false
        tick()
    }

    /// Sets (or disables with 0) the maximum duration and restarts the current session.
    func setMaxDuration(_ value: Double) {
        settings.maxDuration = value
        settings.sessionStartedAt = 0
        maxDurationElapsed = false
        tick()
    }

    func setPreventDisplaySleep(_ value: Bool) {
        settings.preventDisplaySleep = value
        tick()
    }

    func setPreventSystemSleepOnAC(_ value: Bool) {
        settings.preventSystemSleepOnAC = value
        tick()
    }

    func setSimulateActivity(_ value: Bool) {
        settings.simulateActivity = value
        tick()
    }

    func setOnlyOnAC(_ value: Bool) {
        settings.onlyOnAC = value
        tick()
    }

    func setRequireCPUActivity(_ value: Bool) {
        settings.requireCPUActivity = value
        tick()
    }

    func setRespectSessionState(_ value: Bool) {
        settings.respectSessionState = value
        tick()
    }

    func setGracePeriod(_ value: Double) {
        settings.gracePeriod = value
        tick()
    }

    func setPollInterval(_ value: Double) {
        settings.pollInterval = value
        startTimer()
        tick()
    }

    func setActivityInterval(_ value: Double) {
        settings.activityInterval = value
        tick()
    }

    /// Registers/unregisters the login item (needs the app to live in a real bundle).
    func setLaunchAtLogin(_ value: Bool) {
        do {
            if value {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            popover.performClose(nil)
            showSimpleAlert(
                title: "Avvio al login non disponibile",
                text: "\(error.localizedDescription)\n\nSposta Ephedrine.app in /Applications e riprova."
            )
        }
        tick()
    }

    func toggleWatchedAgent(_ pattern: String) {
        settings.setPattern(pattern, enabled: !settings.isPatternEnabled(pattern))
        tick()
    }

    /// Enables/disables closed-display mode; installing the helper on first use.
    func setClosedDisplayMode(_ enabled: Bool) {
        if !enabled {
            settings.closedDisplayMode = false
            tick()
            return
        }
        if !ClosedDisplayHelper.shared.isInstalled {
            popover.performClose(nil)
            guard installClosedDisplaySupport() else { return }
        }
        closedDisplayError = nil
        settings.closedDisplayMode = true
        tick()
    }

    /// Uninstalls the privileged helper and restores normal lid behaviour.
    func removeClosedDisplaySupport() {
        settings.closedDisplayMode = false
        updateClosedDisplay(wantAwake: false)

        let alert = NSAlert()
        alert.messageText = "Rimuovere il supporto coperchio chiuso?"
        alert.informativeText = "Verrà eliminato l'helper con permessi admin e riattivato lo sleep a coperchio chiuso."
        alert.addButton(withTitle: "Rimuovi")
        alert.addButton(withTitle: "Annulla")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if let error = ClosedDisplayHelper.shared.uninstall() {
            showSimpleAlert(title: "Rimozione non riuscita", text: error)
        }
        tick()
    }

    /// Installs or removes an agent integration, after a confirmation dialog.
    func toggleIntegration(_ id: String) {
        guard let integration = Integration(rawValue: id) else { return }
        popover.performClose(nil)

        if integration.isInstalled {
            let alert = NSAlert()
            alert.messageText = "Rimuovere l'integrazione \(integration.title)?"
            alert.informativeText = "Verrà ripristinato il file:\n\(integration.configPath.path)"
            alert.addButton(withTitle: "Rimuovi")
            alert.addButton(withTitle: "Annulla")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if let error = integration.uninstall() {
                showSimpleAlert(title: "Rimozione non riuscita", text: error)
            }
        } else {
            let alert = NSAlert()
            alert.messageText = "Installare l'integrazione \(integration.title)?"
            alert.informativeText = """
            Verrà modificato (con backup .ephedrine-backup):
            \(integration.configPath.path)

            L'agente segnalerà inizio e fine turno ad Ephedrine, così il Mac resta sveglio solo mentre l'LLM lavora davvero. Riavvia l'agente per applicare.
            """
            alert.addButton(withTitle: "Installa")
            alert.addButton(withTitle: "Annulla")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if let error = integration.install(executablePath: executablePath()) {
                showSimpleAlert(title: "Installazione non riuscita", text: error)
            }
        }

        tick()
    }

    /// Editor for user-defined agent patterns (comma separated).
    func editCustomAgents() {
        popover.performClose(nil)
        let alert = NSAlert()
        alert.messageText = "Altri agent da monitorare"
        alert.informativeText = "Pattern separati da virgola. Un processo viene riconosciuto se nome, percorso o command line contengono il pattern (case-insensitive). I pattern di 4 caratteri o meno devono corrispondere a una parola intera."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        field.stringValue = settings.customPatterns.joined(separator: ", ")
        field.placeholderString = "my-agent, llm-runner"
        alert.accessoryView = field
        alert.addButton(withTitle: "Salva")
        alert.addButton(withTitle: "Annulla")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        settings.customPatterns = field.stringValue
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map(String.init)
        tick()
    }

    func openStateFolder() {
        let store = SessionStateStore.shared
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(store.directory)
    }

    /// Shows `pmset -g assertions` so the user can verify what the app is holding.
    func showAssertions() {
        popover.performClose(nil)
        let alert = NSAlert()
        alert.messageText = "Power assertions attive"
        alert.informativeText = "Cerca «Ephedrine» nell'elenco: è l'assertion che tiene sveglio il Mac."
        alert.accessoryView = textViewAlertAccessory(runPMSet())
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func showAbout() {
        popover.performClose(nil)
        let alert = NSAlert()
        alert.messageText = "Ephedrine"
        alert.informativeText = """
        Tiene sveglio il Mac mentre girano agent di coding (opencode, codex, claude, …), così gli LLM non si fermano mai durante l'inattività.

        Con le integrazioni attive l'agente segnala inizio e fine turno: il Mac resta sveglio solo mentre l'LLM lavora davvero.

        Nota: con il coperchio chiuso il Mac dorme comunque, a meno di abilitare «Coperchio chiuso» o usare la modalità clamshell con display esterno e alimentazione AC.
        """
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func quit() {
        NSApp.terminate(nil)
    }

    /// Path embedded into generated hooks/plugins (must stay valid after the app is moved).
    private func executablePath() -> String {
        Bundle.main.executablePath ?? CommandLine.arguments.first ?? "Ephedrine"
    }

    /// Asks for confirmation before the one-time privileged install of the lid helper.
    @discardableResult
    private func installClosedDisplaySupport() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Installazione supporto coperchio chiuso"
        alert.informativeText = "Serve la password amministratore una sola volta: viene creato un helper con permessi limitati che disattiva lo sleep da coperchio (pmset disablesleep). L'helper viene usato solo mentre questa modalità è attiva e viene ripristinato automaticamente quando si disattiva o esci dall'app."
        alert.addButton(withTitle: "Installa")
        alert.addButton(withTitle: "Annulla")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if let error = ClosedDisplayHelper.shared.install() {
            showSimpleAlert(title: "Installazione non riuscita", text: error)
            return false
        }
        return true
    }

    private func showSimpleAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// Runs `pmset -g assertions` and returns its output.
    private func runPMSet() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "Errore nell'esecuzione di pmset: \(error.localizedDescription)"
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? "Output non decodificabile"
    }

    /// Scrollable monospaced text view used as an alert accessory.
    private func textViewAlertAccessory(_ text: String) -> NSScrollView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 300))
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.string = text
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 560, height: 300))
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        return scrollView
    }

    // MARK: - Launch at login

    private var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
