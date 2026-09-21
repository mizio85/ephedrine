//
//  App.swift
//  Ephedrine
//
//  Single executable, four roles — selected by command line arguments:
//
//    1. GUI mode        (no arguments)              → menu bar app (accessory NSApplication)
//    2. Reporter mode   (--report …)                → tiny CLI used by agent integrations
//    3. Utility mode    (--install-integration …)   → install/remove agent hooks & plugins
//    4. Diagnostics     (--dump-agents)             → print detection/state table (debugging)
//
//  Reporter and utility modes must never start the AppKit run loop: agents invoke them
//  synchronously on every turn event, so they do their job and exit immediately.
//

import AppKit
import Foundation

@main
struct EphedrineMain {

    @MainActor
    static func main() {
        let arguments = CommandLine.arguments

        // MARK: Reporter mode
        // Invoked by integrations, e.g.:
        //   Ephedrine --report busy --agent opencode
        //   Ephedrine --report idle --agent codex --idle-only
        //   Ephedrine --report idle --agent codex --passthrough /path/to/original-notify turn-ended
        if let index = arguments.firstIndex(of: "--report") {
            exit(StateReporter.run(arguments: Array(arguments[index...])))
        }

        // MARK: Integration management
        // Also available as CLI so it can be scripted/documented instead of using the popover.
        if let index = arguments.firstIndex(of: "--install-integration"), index + 1 < arguments.count {
            exit(IntegrationCommand.install(id: arguments[index + 1]))
        }
        if let index = arguments.firstIndex(of: "--uninstall-integration"), index + 1 < arguments.count {
            exit(IntegrationCommand.uninstall(id: arguments[index + 1]))
        }

        // MARK: Diagnostics
        if arguments.contains("--dump-agents") {
            exit(DiagnosticsCommand.dumpAgents())
        }

        // MARK: GUI mode
        // Menu bar only: `.accessory` hides the Dock icon and prevents a main window from
        // being created. `AppDelegate` owns the status item and the SwiftUI popover.
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
    }
}
