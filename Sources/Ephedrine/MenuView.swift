//
//  MenuView.swift
//  Ephedrine
//
//  SwiftUI content of the menu bar popover.
//
//  Layout (fixed 320 pt wide):
//
//    ┌ header — status symbol + title + subtitle ────────────────┐
//    │ Off | Auto | Sempre          (segmented mode picker)      │
//    │ AGENTI       rows: name ×N, cpu, working/waiting          │
//    │ OPZIONI      4 primary toggles                            │
//    │ ▸ AGENTI MONITORATI   checkbox grid + custom patterns     │
//    │ ▸ INTEGRAZIONI        install/remove per agent            │
//    │ ▸ AVANZATE            secondary options, intervals, links │
//    └ footer — version · Informazioni · Esci ───────────────────┘
//
//  The three disclosure sections live inside a ScrollView capped at `maxDisclosureHeight`
//  so the popover never becomes taller than the screen; the height is measured with a
//  `PreferenceKey` and applied only when at least one section is expanded.
//
//  All controls use small control sizes and icon+label rows to keep the panel minimal.
//

import SwiftUI

struct MenuView: View {
    let model: MenuModel

    @State private var showWatch = false
    @State private var showIntegrations = false
    @State private var showAdvanced = false
    /// Measured height of the disclosure stack (used to size the ScrollView when expanded).
    @State private var disclosureHeight: CGFloat = 0

    /// Never let the collapsible area push the popover off-screen.
    private let maxDisclosureHeight: CGFloat = 430

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                modePicker
                if model.mode == .always { maxDurationSection }
                if !model.agentGroups.isEmpty { agentsSection }
                optionsSection
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)

            Divider()

            disclosureBlock

            Divider()

            footer
        }
        .frame(width: 320)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.statusSymbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(toneColor)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.statusTitle)
                    .font(.system(size: 13, weight: .semibold))
                if !model.statusSubtitle.isEmpty {
                    Text(model.statusSubtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var toneColor: Color {
        switch model.statusTone {
        case .active: return .green
        case .waiting: return .orange
        case .warning: return .yellow
        case .off: return .secondary
        }
    }

    // MARK: - Mode

    private var modePicker: some View {
        Picker("", selection: Binding(
            get: { model.mode },
            set: { model.delegate?.setMode($0) }
        )) {
            Text(L("mode.off")).tag(KeepAwakeMode.off)
            Text(L("mode.auto")).tag(KeepAwakeMode.auto)
            Text(L("mode.always")).tag(KeepAwakeMode.always)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - Max duration (Always mode)

    private var maxDurationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(L("maxDuration.title"))
                    .font(.system(size: 12))
                helpHint(L("maxDuration.help"))
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { model.maxDuration },
                    set: { model.delegate?.setMaxDuration($0) }
                )) {
                    Text(L("maxDuration.unlimited")).tag(0.0)
                    Text(L("maxDuration.15min")).tag(900.0)
                    Text(L("maxDuration.30min")).tag(1800.0)
                    Text(L("maxDuration.1h")).tag(3600.0)
                    Text(L("maxDuration.2h")).tag(7200.0)
                    Text(L("maxDuration.4h")).tag(14400.0)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }
            if model.maxDurationElapsed {
                Label(L("maxDuration.elapsed"), systemImage: "timer")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .padding(.leading, 0)
            }
        }
    }

    // MARK: - Agents

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(L("section.agents"))
            ForEach(model.agentGroups) { group in
                HStack(spacing: 8) {
                    Circle()
                        .fill(group.working ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(group.name)
                        .font(.system(size: 12, weight: .medium))
                    if group.count > 1 {
                        Text("×\(group.count)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    if group.cpuPercent > 0.005 {
                        Text(String(format: "%.0f%%", group.cpuPercent * 100))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Text(group.working ? L("agents.working") : L("agents.waiting"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Options

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(L("section.options"))
            toggleRow(L("options.preventDisplay"), icon: "sun.max",
                      help: L("options.preventDisplay.help"),
                      get: { model.preventDisplaySleep },
                      set: { model.delegate?.setPreventDisplaySleep($0) })
            toggleRow(L("options.respectSession"), icon: "arrow.triangle.2.circlepath",
                      help: L("options.respectSession.help"),
                      get: { model.respectSessionState },
                      set: { model.delegate?.setRespectSessionState($0) })
            toggleRow(L("options.onlyOnAC"), icon: "powerplug",
                      help: L("options.onlyOnAC.help"),
                      get: { model.onlyOnAC },
                      set: { model.delegate?.setOnlyOnAC($0) })
            toggleRow(L("options.closedDisplay"), icon: "laptopcomputer",
                      help: L("options.closedDisplay.help"),
                      get: { model.closedDisplayMode },
                      set: { model.delegate?.setClosedDisplayMode($0) })
            if !model.closedDisplayDetail.isEmpty {
                Text(model.closedDisplayDetail)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 22)
            }
        }
    }

    // MARK: - Collapsible sections

    private var anyDisclosureExpanded: Bool {
        showWatch || showIntegrations || showAdvanced
    }

    private var disclosures: some View {
        VStack(alignment: .leading, spacing: 10) {
            watchSection
            integrationsSection
            advancedSection
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// Plain stack while collapsed; scrollable and height-capped when something is expanded.
    @ViewBuilder
    private var disclosureBlock: some View {
        if anyDisclosureExpanded {
            ScrollView(.vertical, showsIndicators: true) {
                disclosures.background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: DisclosureHeightKey.self, value: proxy.size.height)
                    }
                )
            }
            .frame(height: min(disclosureHeight, maxDisclosureHeight))
            .onPreferenceChange(DisclosureHeightKey.self) { disclosureHeight = $0 }
        } else {
            disclosures
        }
    }

    private var watchSection: some View {
        DisclosureGroup(isExpanded: $showWatch) {
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(
                    columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                    alignment: .leading,
                    spacing: 6
                ) {
                    ForEach(model.watchItems) { item in
                        Toggle(item.name, isOn: Binding(
                            get: { item.enabled },
                            set: { _ in model.delegate?.toggleWatchedAgent(item.name) }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    }
                }
                Button(L("watch.others")) { model.delegate?.editCustomAgents() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    .help(L("watch.others.help"))
            }
            .padding(.top, 8)
        } label: {
            sectionLabel(L("section.watch"))
        }
    }

    private var integrationsSection: some View {
        DisclosureGroup(isExpanded: $showIntegrations) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.integrations) { row in
                    HStack {
                        Text(row.title)
                            .font(.system(size: 12))
                        Spacer()
                        Button(row.installed ? L("integrations.remove") : L("integrations.install")) {
                            model.delegate?.toggleIntegration(row.id)
                        }
                        .help(row.installed
                              ? L("integrations.remove.help")
                              : L("integrations.install.help"))
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(row.installed ? Color.red : Color.accentColor)
                    }
                }
                if !model.sessionSummary.isEmpty {
                    Text(Lf("integrations.lastState", model.sessionSummary))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Button(L("integrations.openFolder")) { model.delegate?.openStateFolder() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            .padding(.top, 8)
        } label: {
            sectionLabel(L("section.integrations"))
        }
    }

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 8) {
                toggleRow(L("advanced.simulateActivity"), icon: "hand.tap",
                          help: L("advanced.simulateActivity.help"),
                          get: { model.simulateActivity },
                          set: { model.delegate?.setSimulateActivity($0) })
                toggleRow(L("advanced.preventSystemSleep"), icon: "moon.zzz",
                          help: L("advanced.preventSystemSleep.help"),
                          get: { model.preventSystemSleepOnAC },
                          set: { model.delegate?.setPreventSystemSleepOnAC($0) })
                toggleRow(L("advanced.cpuOnly"), icon: "cpu",
                          help: L("advanced.cpuOnly.help"),
                          get: { model.requireCPUActivity },
                          set: { model.delegate?.setRequireCPUActivity($0) })
                toggleRow(L("advanced.launchAtLogin"), icon: "arrow.up.forward.app",
                          help: L("advanced.launchAtLogin.help"),
                          get: { model.launchAtLogin },
                          set: { model.delegate?.setLaunchAtLogin($0) })

                Divider().padding(.vertical, 2)

                durationRow(L("advanced.grace"), help: L("advanced.grace.help"), value: Binding(
                    get: { model.gracePeriod },
                    set: { model.delegate?.setGracePeriod($0) }
                ), options: [0, 30, 60, 120, 300, 600])
                durationRow(L("advanced.poll"), help: L("advanced.poll.help"), value: Binding(
                    get: { model.pollInterval },
                    set: { model.delegate?.setPollInterval($0) }
                ), options: [1, 2, 5, 10])
                durationRow(L("advanced.activity"), help: L("advanced.activity.help"), value: Binding(
                    get: { model.activityInterval },
                    set: { model.delegate?.setActivityInterval($0) }
                ), options: [30, 60, 120, 300])

                Button(L("advanced.showAssertions")) { model.delegate?.showAssertions() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                if model.closedDisplayInstalled {
                    Button(L("advanced.removeClosedSupport")) { model.delegate?.removeClosedDisplaySupport() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .help(L("advanced.removeClosedSupport.help"))
                }
            }
            .padding(.top, 8)
        } label: {
            sectionLabel(L("section.advanced"))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text("v\(model.version)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Button(L("footer.about")) { model.delegate?.showAbout() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button(L("footer.quit")) { model.delegate?.quit() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Building blocks

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .kerning(0.5)
            .foregroundStyle(.tertiary)
    }

    /// Label + optional "?" hint on the left, switch aligned to the trailing edge.
    private func toggleRow(_ title: String, icon: String, help: String? = nil, get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 6) {
            Label(title, systemImage: icon)
                .font(.system(size: 12))
            helpHint(help)
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: get, set: set))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }

    /// Label + optional "?" hint on the left, menu picker aligned to the trailing edge.
    private func durationRow(_ title: String, help: String? = nil, value: Binding<Double>, options: [Double]) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12))
            helpHint(help)
            Spacer(minLength: 8)
            Picker("", selection: value) {
                ForEach(options, id: \.self) { option in
                    Text(durationLabel(option)).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()
        }
    }

    /// Small "?" that explains an option on hover.
    @ViewBuilder
    private func helpHint(_ text: String?) -> some View {
        if let text {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .help(text)
        }
    }

    private func durationLabel(_ seconds: Double) -> String {
        if seconds <= 0 { return L("duration.off") }
        if seconds < 60 { return Lf("duration.seconds", Int(seconds)) }
        return Lf("duration.minutes", Int(seconds / 60))
    }
}

/// Sizes the disclosure ScrollView to its content (and no more than the cap in `MenuView`).
private struct DisclosureHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
