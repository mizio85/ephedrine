//
//  IntegrationHealth.swift
//  Ephedrine
//
//  Automatic health check for the installed agent integrations.
//
//  Why a health check?
//  -------------------
//  An integration is a file written by Ephedrine into the agent's config (a Codex `notify`, a
//  Claude hook, an opencode plugin, a pi extension). It can silently stop working:
//
//    * the app was moved after installing, so the binary path baked into the hook/plugin no
//      longer exists;
//    * the file is present but the agent does not load it (API drift, syntax error, wrong file);
//    * the user removed the app and the hook now points nowhere.
//
//  In all those cases the agent keeps running, Ephedrine keeps detecting the process, but the
//  busy/idle signal never arrives — and the Mac may sleep while the LLM is still working.
//
//  What is checked, and at what cost
//  ---------------------------------
//  1. Static (file-based) checks — binary path exists and is executable.
//     * Throttled to at most one pass every `staticCheckInterval` (30 s).
//     * Only runs when there is a reason to look: an agent is running or the popover is open.
//     * Each config file is re-read only when its (mtime, size) signature changed, so the
//       steady-state cost is a handful of `stat` calls.
//  2. Runtime check — "busy but silent".
//     * Reuses the process scan and the session snapshot that the monitor tick already collects;
//       it only touches two in-memory dictionaries, with zero extra syscalls.
//     * Applies only to integrations that report *both* transitions (Claude, opencode, pi). For
//       those, an agent that is working by CPU for `reportingGrace` seconds without a single
//       state file means the hook/plugin never ran. Codex only reports the end of a turn, so it
//       is intentionally excluded.
//
//  Nothing here spawns a process, opens a socket or schedules a timer: the checks ride along the
//  existing 1–10 s monitor loop.
//

import Foundation

/// Result of the health check for one integration.
enum IntegrationHealth: Equatable {
    /// No config file / our marker is absent.
    case notInstalled
    /// Installed and the embedded binary is valid (problems below are runtime-only).
    case ok
    /// The executable baked into the hook/plugin does not exist (usually: the app was moved).
    case binaryMissing(String)
    /// The path exists but is not executable.
    case binaryNotExecutable(String)
    /// Installed and the agent is working, but no turn state has ever been reported.
    case notReporting

    /// True when the user should be warned.
    var isProblem: Bool {
        switch self {
        case .notInstalled, .ok: return false
        case .binaryMissing, .binaryNotExecutable, .notReporting: return true
        }
    }

    /// Localized, user-facing explanation; `nil` when there is nothing to report.
    var message: String? {
        switch self {
        case .notInstalled, .ok:
            return nil
        case .binaryMissing(let path):
            return Lf("integrations.health.binaryMissing", path)
        case .binaryNotExecutable(let path):
            return Lf("integrations.health.notExecutable", path)
        case .notReporting:
            return L("integrations.health.notReporting")
        }
    }
}

extension Integration {

    /// Whether the integration can report the *start* of a turn as well as its end.
    /// Codex only fires `notify` at the end of a turn, so it cannot be checked for silence.
    var reportsBusyTransitions: Bool { self != .codex }

    /// Maps a detected process pattern to its integration (used for the runtime check).
    static func matching(pattern: String) -> Integration? {
        let lowered = pattern.lowercased()
        return allCases.first { $0.rawValue == lowered }
    }

    /// Parses the executable path baked into the generated config/plugin.
    ///
    /// Returns `nil` when the path cannot be determined (for example an unrecognized Codex
    /// `notify` that was hand-edited): callers then treat the integration as healthy rather
    /// than raising a false alarm.
    func embeddedExecutablePath(in content: String) -> String? {
        switch self {
        case .codex:
            // notify = ["/path/Ephedrine", "--report", …]
            for line in content.split(separator: "\n") {
                let text = String(line)
                guard text.contains(Self.marker), text.contains("notify") else { continue }
                if let path = Self.firstQuotedString(in: text) { return path }
            }
            return nil
        case .claude:
            // hooks → … → {"type":"command","command":"/path/Ephedrine --report busy --agent claude"}
            guard let data = content.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hooks = root["hooks"] as? [String: Any] else { return nil }
            for value in hooks.values {
                guard let entries = value as? [[String: Any]] else { continue }
                for entry in entries {
                    let inner = entry["hooks"] as? [[String: Any]] ?? []
                    for hook in inner {
                        guard let command = hook["command"] as? String, command.contains(Self.marker) else { continue }
                        return command.split(separator: " ").first.map(String.init)
                    }
                }
            }
            return nil
        case .opencode, .pi:
            // const BINARY = "/path/Ephedrine";
            for line in content.split(separator: "\n") {
                let text = line.trimmingCharacters(in: .whitespaces)
                guard text.hasPrefix("const BINARY") else { continue }
                return Self.firstQuotedString(in: text)
            }
            return nil
        }
    }

    /// First double-quoted string on a line, honouring backslash escapes.
    private static func firstQuotedString(in line: String) -> String? {
        var current = ""
        var inString = false
        var escaped = false
        for character in line {
            if inString {
                if escaped {
                    current.append(character)
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    return current
                } else {
                    current.append(character)
                }
            } else if character == "\"" {
                inString = true
            }
        }
        return nil
    }
}

/// Tracks the health of every integration. Thread-affine: used only from the main actor and from
/// the one-shot CLI commands, never concurrently.
final class IntegrationHealthMonitor {

    static let shared = IntegrationHealthMonitor()

    /// Minimum delay between two file-based passes.
    static let staticCheckInterval: TimeInterval = 30

    /// How long an agent may be busy (by CPU) without reporting before its integration is
    /// considered broken. Deliberately generous so a slow first token never raises a warning.
    static let reportingGrace: TimeInterval = 20

    private var staticHealth: [Integration: IntegrationHealth] = [:]
    /// Runtime-only flag, layered on top of `.ok` static health.
    private var notReporting: Set<Integration> = []
    private var lastStaticCheck: Date?
    /// Cheap (mtime, size) fingerprint per config file, so unchanged files are not re-read.
    private var fingerprints: [Integration: String] = [:]
    /// When each integration first went silent while its agent was working.
    private var silentSince: [Integration: Date] = [:]

    private init() {}

    // MARK: - Queries

    /// Current health, combining the static file check with the runtime "busy but silent" flag.
    func health(of integration: Integration) -> IntegrationHealth {
        switch staticHealth[integration] ?? .notInstalled {
        case .ok:
            return notReporting.contains(integration) ? .notReporting : .ok
        case let other:
            return other
        }
    }

    /// True when at least one integration needs attention.
    var hasProblem: Bool {
        Integration.allCases.contains { health(of: $0).isProblem }
    }

    /// Titles (or "Title (reason)") of the integrations that need attention, for the tooltip.
    func problemSummaries() -> [String] {
        Integration.allCases.compactMap { integration in
            guard let message = health(of: integration).message else { return nil }
            return "\(integration.title): \(message)"
        }
    }

    // MARK: - Static checks (file-based)

    /// Refreshes the file-based checks.
    /// - Parameters:
    ///   - force: bypass the 30 s throttle (used on install/uninstall and when the popover opens).
    ///   - now: injectable clock, for tests.
    func refreshStatic(force: Bool = false, now: Date = Date()) {
        if !force, let last = lastStaticCheck, now.timeIntervalSince(last) < Self.staticCheckInterval {
            return
        }
        lastStaticCheck = now

        var updated: [Integration: IntegrationHealth] = [:]
        for integration in Integration.allCases {
            let path = integration.configPath
            guard FileManager.default.fileExists(atPath: path.path) else {
                updated[integration] = .notInstalled
                fingerprints[integration] = nil
                continue
            }

            let fingerprint = Self.fingerprint(path)
            if !force, fingerprints[integration] == fingerprint, let cached = staticHealth[integration] {
                updated[integration] = cached
                continue
            }

            guard let content = try? String(contentsOf: path, encoding: .utf8),
                  integration.isInstalled(in: content) else {
                updated[integration] = .notInstalled
                fingerprints[integration] = fingerprint
                continue
            }

            updated[integration] = Self.health(forBinaryPath: integration.embeddedExecutablePath(in: content))
            fingerprints[integration] = fingerprint
        }

        staticHealth = updated

        // The runtime flag only makes sense while the static check is clean: a broken binary
        // supersedes (and is more actionable than) a missing report.
        if !notReporting.isEmpty {
            notReporting = notReporting.filter { updated[$0] == .ok }
        }
    }

    /// Maps the embedded executable path to a health value.
    private static func health(forBinaryPath path: String?) -> IntegrationHealth {
        guard let path, !path.isEmpty else { return .ok } // unparseable: do not warn
        if !FileManager.default.fileExists(atPath: path) { return .binaryMissing(path) }
        if !FileManager.default.isExecutableFile(atPath: path) { return .binaryNotExecutable(path) }
        return .ok
    }

    /// Cheap change detector for a config file: modification time + size.
    private static func fingerprint(_ url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values?.fileSize ?? -1
        return "\(mtime)-\(size)"
    }

    // MARK: - Runtime checks (busy but silent)

    /// Consumes the data the monitor tick already collected. No I/O, no syscalls.
    /// - Parameters:
    ///   - agents: freshly classified processes.
    ///   - snapshot: session states read this tick.
    ///   - active: false disables the check entirely (mode Off or turn states ignored).
    ///   - now: injectable clock, for tests.
    func observe(agents: [DetectedAgent], snapshot: SessionStateSnapshot, active: Bool, now: Date = Date()) {
        guard active else {
            silentSince.removeAll()
            notReporting.removeAll()
            return
        }

        var silent: Set<Integration> = []
        for agent in agents where agent.activity == .working {
            guard let integration = Integration.matching(pattern: agent.pattern),
                  integration.reportsBusyTransitions,
                  staticHealth[integration] == .ok else { continue }

            if snapshot.state(for: agent) == nil {
                // Busy by CPU, integration installed, yet nothing was ever reported.
                silent.insert(integration)
                if silentSince[integration] == nil { silentSince[integration] = now }
            } else {
                silentSince[integration] = nil
            }
        }

        // Forget integrations that are no longer silent (idle, gone, or reporting again).
        silentSince = silentSince.filter { silent.contains($0.key) }

        for (integration, start) in silentSince where now.timeIntervalSince(start) >= Self.reportingGrace {
            notReporting.insert(integration)
        }
        if !notReporting.isEmpty {
            notReporting = notReporting.filter { silent.contains($0) }
        }
    }
}

/// CLI implementation of `--check-integrations`: prints the health table and exits non-zero when
/// something needs attention (so it can be used from scripts).
enum IntegrationHealthCommand {

    static func run() -> Int32 {
        let monitor = IntegrationHealthMonitor.shared
        monitor.refreshStatic(force: true)

        var problems = 0
        for integration in Integration.allCases {
            let health = monitor.health(of: integration)
            let status: String
            switch health {
            case .notInstalled: status = "not installed"
            case .ok: status = "ok"
            case .binaryMissing, .binaryNotExecutable, .notReporting:
                status = health.message ?? "needs attention"
            }
            if health.isProblem { problems += 1 }
            print("\(integration.title): \(status)")
        }
        return problems == 0 ? 0 : 1
    }
}
