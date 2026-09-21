//
//  SessionState.swift
//  Ephedrine
//
//  "Session state" is how an agent tells Ephedrine what it is doing right now:
//  generating a response (`busy`) or waiting for the user (`idle`).
//
//  Transport: small JSON files in
//      ~/Library/Application Support/Ephedrine/state/
//      e.g. opencode-98373.json → {"agent":"opencode","pid":98373,"state":"busy","reports_busy":true,...}
//
//  Why files instead of sockets/notifications?
//   * Any agent can write them with a one-line hook/plugin (no daemon, no ports, no permissions).
//   * They survive crashes and app restarts and are trivially inspectable (`--dump-agents`).
//   * Staleness is easy to reason about: a file older than `maxAge` is deleted automatically,
//     while a file whose pid is gone is excluded from pid-level matching but kept as an
//     agent-level fallback until `maxAge` (a mid-turn helper restart must not lose `busy`).
//
//  `reports_busy` distinguishes two classes of integrations:
//   * true  (opencode plugin, Claude Code hooks): the agent reports both transitions, so an
//     `idle` file is authoritative and CPU activity is ignored.
//   * false (Codex `notify`, which only fires at end of turn): the `idle` file must be combined
//     with a CPU heuristic to detect the *start* of the next turn.
//
//  The same binary acts as the writer: `Ephedrine --report …` (see `StateReporter`).
//

import Darwin
import Foundation

/// State reported by one agent process.
struct AgentSessionState {
    enum Status: String {
        case busy
        case idle
    }

    let agent: String
    let pid: pid_t?
    /// False when the reporting process no longer exists (state kept for agent-level matching).
    let pidAlive: Bool
    let status: Status
    /// Whether the integration also reports the start of a turn (see file header).
    let reportsBusy: Bool
    let updated: Date
}

/// Immutable view of the state directory at a point in time.
struct SessionStateSnapshot {
    /// All valid states, newest last.
    let states: [AgentSessionState]

    /// Lookup by concrete pid (`nil` entries are absent).
    private let byPid: [pid_t: AgentSessionState]
    /// Fallback lookup by agent name: one state file covers every process of that agent.
    private let byAgent: [String: AgentSessionState]

    init(states: [AgentSessionState]) {
        self.states = states
        var pidMap: [pid_t: AgentSessionState] = [:]
        var agentMap: [String: AgentSessionState] = [:]
        // Sort by age first so that the most recent file wins for both maps.
        for state in states.sorted(by: { $0.updated < $1.updated }) {
            // Pid-level matching requires a live process: a file left behind by a dead helper
            // must never override the state of the process that replaced it.
            if let pid = state.pid, state.pidAlive {
                pidMap[pid] = state
            }
            // Agent-level matching keeps working after the reporting process disappears (helper
            // restarts, app restarts). This is what bridges the gap while an agent is mid-turn.
            agentMap[state.agent.lowercased()] = state
        }
        byPid = pidMap
        byAgent = agentMap
    }

    /// State for a detected process: exact pid first, then agent-name fallback.
    func state(for agent: DetectedAgent) -> AgentSessionState? {
        byPid[agent.pid] ?? byAgent[agent.pattern.lowercased()]
    }

    /// Short human-readable summary for the popover ("opencode=busy, codex=idle").
    var summary: String {
        guard !states.isEmpty else { return "nessuno stato ricevuto" }
        var seen = Set<String>()
        var parts: [String] = []
        for state in states.sorted(by: { $0.updated > $1.updated }) {
            guard seen.insert(state.agent.lowercased()).inserted else { continue }
            parts.append("\(state.agent)=\(state.status.rawValue)")
        }
        return parts.joined(separator: ", ")
    }
}

/// Reads and writes the state directory.
final class SessionStateStore {

    static let shared = SessionStateStore()

    /// State files older than this are considered stale (and deleted).
    static let maxAge: TimeInterval = 30 * 60

    /// `~/Library/Application Support/Ephedrine/state`.
    var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ephedrine/state", isDirectory: true)
    }

    /// Writes (atomically) the state file for `agent`/`pid`.
    func write(agent: String, pid: pid_t, status: AgentSessionState.Status, reportsBusy: Bool = true) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileName = "\(sanitize(agent))-\(pid).json"
        let url = directory.appendingPathComponent(fileName)
        let payload: [String: Any] = [
            "agent": agent,
            "pid": Int(pid),
            "state": status.rawValue,
            "reports_busy": reportsBusy,
            "updated": Date().timeIntervalSince1970
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Reads every valid state file; invalid/stale/dead entries are skipped and cleaned up.
    func snapshot() -> SessionStateSnapshot {
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return SessionStateSnapshot(states: [])
        }

        let oldest = Date().addingTimeInterval(-Self.maxAge)
        var states: [AgentSessionState] = []

        for url in urls where url.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: url),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let agent = object["agent"] as? String,
                let rawStatus = object["state"] as? String,
                let status = AgentSessionState.Status(rawValue: rawStatus)
            else { continue }

            // mtime is used as "updated": the writer touches the file on every change.
            let updated = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
            if updated < oldest {
                try? fileManager.removeItem(at: url) // stale: clean up
                continue
            }

            // Dead-pid files are kept until `maxAge` instead of being deleted immediately: if an
            // Electron/helper process restarts mid-turn, the last "busy" must survive the gap.
            // `SessionStateSnapshot.init` excludes them from pid-level matching, so they cannot
            // override the state of the process that replaced them.
            let pid = (object["pid"] as? Int).map { pid_t($0) }
            let pidAlive = pid.map { SessionStateStore.isAlive(pid: $0) } ?? false

            let reportsBusy = (object["reports_busy"] as? Bool) ?? true
            states.append(AgentSessionState(agent: agent, pid: pid, pidAlive: pidAlive, status: status, reportsBusy: reportsBusy, updated: updated))
        }

        return SessionStateSnapshot(states: states)
    }

    /// Lowercases a name and replaces anything unsafe for a filename.
    private func sanitize(_ name: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let scalars = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(scalars).lowercased()
    }

    /// `kill(pid, 0)` existence probe; EPERM means "alive but not ours".
    private static func isAlive(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

/// CLI implementation of `--report`: writes the state file for the invoking agent.
///
/// Usage:
/// ```
/// Ephedrine --report busy|idle --agent <name> [--pid N] [--idle-only]
///              [--passthrough <program> <args…>]
/// ```
///
/// * `--pid` is optional: when omitted, the nearest ancestor process whose name contains
///   `<name>` is used, falling back to the direct parent.
/// * `--idle-only` marks the reporter as unable to signal the start of a turn (Codex).
/// * `--passthrough` re-executes another program after writing the state; this lets Ephedrine
///   wrap an existing `notify` command without breaking it (see `Integration.installCodex`).
enum StateReporter {

    static func run(arguments: [String]) -> Int32 {
        var status: AgentSessionState.Status?
        var agent = "unknown"
        var explicitPid: pid_t?
        var reportsBusy = true
        var passthrough: [String] = []
        var index = 0

        while index < arguments.count {
            switch arguments[index] {
            case "--report":
                if index + 1 < arguments.count,
                   let parsed = AgentSessionState.Status(rawValue: arguments[index + 1].lowercased()) {
                    status = parsed
                    index += 1
                }
            case "--agent":
                if index + 1 < arguments.count {
                    agent = arguments[index + 1]
                    index += 1
                }
            case "--idle-only":
                reportsBusy = false
            case "--pid":
                if index + 1 < arguments.count, let value = pid_t(arguments[index + 1]) {
                    explicitPid = value
                    index += 1
                }
            case "--passthrough":
                // Everything after this flag belongs to the wrapped program.
                if index + 1 < arguments.count {
                    passthrough = Array(arguments[(index + 1)...])
                    index = arguments.count
                }
            default:
                break
            }
            index += 1
        }

        // Without a status there is nothing to report: exit code 64 (EX_USAGE).
        guard let status else { return 64 }

        let pid = explicitPid ?? ProcessScanner.ancestorPID(matching: agent) ?? getppid()
        SessionStateStore.shared.write(agent: agent, pid: pid, status: status, reportsBusy: reportsBusy)

        // Wrap mode: hand over to the original notification program (e.g. Codex notify).
        if !passthrough.isEmpty {
            execPassthrough(program: passthrough[0], arguments: Array(passthrough.dropFirst()))
        }

        return 0
    }

    /// `execv` the wrapped program so the caller observes exactly the same process behaviour.
    private static func execPassthrough(program: String, arguments: [String]) {
        var argv: [UnsafeMutablePointer<CChar>?] = ([program] + arguments).map { strdup($0) }
        argv.append(nil)
        execv(program, argv)
        // If execv fails we simply return: the state has already been written.
    }
}

/// CLI implementation of `--dump-agents`: prints what the detector sees, for debugging.
enum DiagnosticsCommand {

    static func dumpAgents() -> Int32 {
        let settings = Settings.shared
        let snapshot = SessionStateStore.shared.snapshot()
        let detector = AgentDetector()

        print("mode=\(settings.mode.rawValue) respectSessionState=\(settings.respectSessionState) cpuOnly=\(settings.requireCPUActivity) pattern=\(settings.enabledPatterns.count)")
        print("state ricevuti: \(snapshot.summary)")

        // Two extra passes: CPU fractions need a previous sample to be meaningful.
        var agents = detector.detect(patterns: settings.enabledPatterns)
        for _ in 0..<2 {
            Thread.sleep(forTimeInterval: 2.0)
            agents = detector.detect(patterns: settings.enabledPatterns)
        }

        for agent in agents {
            let state = snapshot.state(for: agent)
            let cpu = agent.cpuPercent.map { String(format: "%.3f", $0) } ?? "nil"
            print("  pattern=\(agent.pattern) pid=\(agent.pid) name=\(agent.name) cpu=\(cpu) state=\(state?.status.rawValue ?? "-") path=\(agent.path)")
        }
        return 0
    }
}
