//
//  MenuModel.swift
//  Ephedrine
//
//  Observable view model for the SwiftUI popover.
//
//  `AppDelegate` is the single source of truth: it refreshes this model on every monitor tick
//  (`refreshModel`) and the SwiftUI view simply renders it. Actions performed in the UI are
//  forwarded back to the delegate through the weak `delegate` reference (no retain cycle: the
//  delegate owns the model).
//
//  The nested row types are `Equatable` on purpose: `refreshModel` compares old and new values
//  and only writes when something actually changed, so SwiftUI is not invalidated on every tick.
//

import Foundation
import Observation

@MainActor
@Observable
final class MenuModel {

    /// Weak back-reference used to trigger actions; the delegate owns this model.
    weak var delegate: AppDelegate?

    /// Visual tone of the header (colour of the status symbol).
    enum Tone {
        case active
        case waiting
        case off
        case warning
    }

    /// Where the working/waiting verdict for a group came from.
    enum AgentSource {
        /// The agent integration reported a turn state (busy/idle).
        case integration
        /// No turn state: the verdict is based on CPU usage.
        case cpu
    }

    /// One row of the "Agenti" section: all processes of the same pattern, aggregated.
    struct AgentGroup: Identifiable, Equatable {
        let id: String
        let name: String
        let count: Int
        let working: Bool
        let cpuPercent: Double
        /// Which rule decided `working` (integration turn state vs CPU fallback).
        let source: AgentSource
    }

    /// One row of the "Integrazioni" section.
    struct IntegrationRow: Identifiable, Equatable {
        let id: String
        let title: String
        let installed: Bool
        /// Non-nil when the installed integration needs attention (localized explanation).
        let problem: String?
    }

    /// One checkable entry of the "Agenti monitorati" grid.
    struct WatchItem: Identifiable, Equatable {
        let id: String
        let name: String
        let enabled: Bool
    }

    // Header
    var statusTitle = "Ephedrine"
    var statusSubtitle = ""
    var statusSymbol = "cup.and.saucer"
    var statusTone: Tone = .off
    var errorMessage: String?

    // Behaviour
    var mode: KeepAwakeMode = .auto
    var agentGroups: [AgentGroup] = []

    // Options (mirrors `Settings`)
    var preventDisplaySleep = false
    var preventSystemSleepOnAC = false
    var simulateActivity = false
    var onlyOnAC = false
    var requireCPUActivity = false
    var respectSessionState = true
    var closedDisplayMode = false
    var closedDisplayInstalled = false
    var closedDisplayDetail = ""

    // Advanced (mirrors `Settings`)
    var launchAtLogin = false
    var gracePeriod: Double = 120
    var pollInterval: Double = 2
    var activityInterval: Double = 60
    /// Maximum duration in Always mode, in seconds (0 = unlimited).
    var maxDuration: Double = 0
    /// True when the cap has fired and the Mac has been released.
    var maxDurationElapsed = false

    // Collapsible sections
    var watchItems: [WatchItem] = []
    var integrations: [IntegrationRow] = []
    var sessionSummary = ""
    /// First health problem among the integrations (shown as a banner); `nil` when all is well.
    var healthWarning: String?

    /// Version shown in the footer (`dev` when running from a raw binary).
    var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    init(delegate: AppDelegate) {
        self.delegate = delegate
    }
}
