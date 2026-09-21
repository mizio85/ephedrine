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
            Text("Off").tag(KeepAwakeMode.off)
            Text("Auto").tag(KeepAwakeMode.auto)
            Text("Sempre").tag(KeepAwakeMode.always)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - Max duration (Always mode)

    private var maxDurationSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Limite di funzionamento")
                    .font(.system(size: 12))
                helpHint("Spegne il caffè dopo il tempo scelto, così il Mac non resta acceso all'infinito.")
                Spacer(minLength: 8)
                Picker("", selection: Binding(
                    get: { model.maxDuration },
                    set: { model.delegate?.setMaxDuration($0) }
                )) {
                    Text("Illimitato").tag(0.0)
                    Text("15 min").tag(900.0)
                    Text("30 min").tag(1800.0)
                    Text("1 ora").tag(3600.0)
                    Text("2 ore").tag(7200.0)
                    Text("4 ore").tag(14400.0)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }
            if model.maxDurationElapsed {
                Label("Timer scaduto: Mac rilasciato", systemImage: "timer")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .padding(.leading, 0)
            }
        }
    }

    // MARK: - Agents

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Agenti")
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
                    Text(group.working ? "attivo" : "in attesa")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Options

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Opzioni")
            toggleRow("Mantieni display acceso", icon: "sun.max",
                      help: "Impedisce lo spegnimento del display finché un agent sta lavorando (equivale a caffeinate -d).",
                      get: { model.preventDisplaySleep },
                      set: { model.delegate?.setPreventDisplaySleep($0) })
            toggleRow("Rispetta stato dei turni", icon: "arrow.triangle.2.circlepath",
                      help: "Usa i segnali busy/idle delle integrazioni: il Mac resta sveglio solo mentre l'LLM genera davvero.",
                      get: { model.respectSessionState },
                      set: { model.delegate?.setRespectSessionState($0) })
            toggleRow("Solo su alimentazione AC", icon: "powerplug",
                      help: "Non tiene sveglio il Mac quando è alimentato a batteria.",
                      get: { model.onlyOnAC },
                      set: { model.delegate?.setOnlyOnAC($0) })
            toggleRow("Coperchio chiuso", icon: "laptopcomputer",
                      help: "Disattiva lo sleep da coperchio chiuso (pmset disablesleep) mentre un agent lavora. Richiede la password admin al primo uso.",
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
                Button("Altri agent…") { model.delegate?.editCustomAgents() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                    .help("Aggiungi pattern di processi da monitorare, separati da virgola.")
            }
            .padding(.top, 8)
        } label: {
            sectionLabel("Agenti monitorati")
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
                        Button(row.installed ? "Rimuovi" : "Installa") {
                            model.delegate?.toggleIntegration(row.id)
                        }
                        .help(row.installed
                              ? "Rimuove l'integrazione e ripristina il file di configurazione originale."
                              : "Modifica la configurazione dell'agente (con backup) perché segnali inizio e fine turno.")
                        .buttonStyle(.borderless)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(row.installed ? Color.red : Color.accentColor)
                    }
                }
                if !model.sessionSummary.isEmpty {
                    Text("Ultimo stato: \(model.sessionSummary)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Button("Apri cartella stato") { model.delegate?.openStateFolder() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            .padding(.top, 8)
        } label: {
            sectionLabel("Integrazioni stato turni")
        }
    }

    private var advancedSection: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 8) {
                toggleRow("Simula attività utente", icon: "hand.tap",
                          help: "Dichiara attività utente a intervalli regolari per evitare screensaver e blocco automatico.",
                          get: { model.simulateActivity },
                          set: { model.delegate?.setSimulateActivity($0) })
                toggleRow("Impedisci sleep di sistema (AC)", icon: "moon.zzz",
                          help: "Aggiunge l'assertion PreventSystemSleep (come caffeinate -s). Attiva solo con alimentatore collegato.",
                          get: { model.preventSystemSleepOnAC },
                          set: { model.delegate?.setPreventSystemSleepOnAC($0) })
                toggleRow("Solo con CPU attiva", icon: "cpu",
                          help: "Ignora gli stati di turno e classifica gli agent solo in base all'uso di CPU (≥3%).",
                          get: { model.requireCPUActivity },
                          set: { model.delegate?.setRequireCPUActivity($0) })
                toggleRow("Avvia al login", icon: "arrow.up.forward.app",
                          help: "Avvia Ephedrine automaticamente all'accesso. Richiede l'app in /Applications.",
                          get: { model.launchAtLogin },
                          set: { model.delegate?.setLaunchAtLogin($0) })

                Divider().padding(.vertical, 2)

                durationRow("Grazia", help: "Per quanto il Mac resta sveglio dopo l'ultimo lavoro, per coprire pause brevi (LLM che ragiona, tool che riparte).", value: Binding(
                    get: { model.gracePeriod },
                    set: { model.delegate?.setGracePeriod($0) }
                ), options: [0, 30, 60, 120, 300, 600])
                durationRow("Rilevamento", help: "Ogni quanto l'app controlla processi, CPU e stati di turno.", value: Binding(
                    get: { model.pollInterval },
                    set: { model.delegate?.setPollInterval($0) }
                ), options: [1, 2, 5, 10])
                durationRow("Attività utente", help: "Intervallo tra due dichiarazioni di attività utente (usato con «Simula attività utente»).", value: Binding(
                    get: { model.activityInterval },
                    set: { model.delegate?.setActivityInterval($0) }
                ), options: [30, 60, 120, 300])

                Button("Mostra power assertions…") { model.delegate?.showAssertions() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                if model.closedDisplayInstalled {
                    Button("Rimuovi supporto coperchio chiuso…") { model.delegate?.removeClosedDisplaySupport() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                        .help("Elimina l'helper con permessi admin e riattiva lo sleep da coperchio chiuso.")
                }
            }
            .padding(.top, 8)
        } label: {
            sectionLabel("Avanzate")
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Text("v\(model.version)")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Informazioni") { model.delegate?.showAbout() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("Esci") { model.delegate?.quit() }
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
        if seconds <= 0 { return "Off" }
        if seconds < 60 { return "\(Int(seconds)) s" }
        return "\(Int(seconds / 60)) min"
    }
}

/// Sizes the disclosure ScrollView to its content (and no more than the cap in `MenuView`).
private struct DisclosureHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
