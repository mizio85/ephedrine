//
//  Settings.swift
//  Ephedrine
//
//  Thin, typed wrapper around `UserDefaults` for every user preference.
//
//  Design notes
//  ------------
//  * Values are read lazily from `UserDefaults.standard` on each access. NSUserDefaults keeps
//    an in-process cache, so this is cheap; it also means external changes (e.g. `defaults
//    write local.maurizio.Ephedrine mode always`) are picked up without restarting the app.
//  * No observation/KVO: the polling timer re-reads settings on every tick (default 2 s), which
//    is more than fast enough for this kind of utility and keeps the state model simple.
//  * The defaults domain equals the bundle identifier (`local.maurizio.Ephedrine`) when the
//    app runs from its bundle; when run from a raw binary the process name is used instead.
//

import Foundation

/// Global behaviour: when should the Mac be kept awake?
enum KeepAwakeMode: String, CaseIterable {
    /// Nothing is monitored; all assertions are released.
    case off
    /// Keep awake only while at least one monitored agent is actually working.
    case auto
    /// Keep awake unconditionally (classic "Caffeine" behaviour).
    case always
}

/// All `UserDefaults` keys in one place, so they are greppable and typo-safe.
private enum Key: String {
    case mode
    case preventDisplaySleep
    case preventSystemSleepOnAC
    case simulateActivity
    case activityInterval
    case gracePeriod
    case onlyOnAC
    case requireCPUActivity
    case pollInterval
    case disabledPatterns
    case customPatterns
    case closedDisplayMode
    case closedDisplayEngaged
    case respectSessionState
    case maxDuration
    case sessionStartedAt
}

/// Typed access to the persisted preferences.
final class Settings {

    /// Process-wide singleton; `AppDelegate` and the reporter share it.
    static let shared = Settings()

    /// CPU fraction (0…1) above which an agent without session state is considered "working"
    /// when the user explicitly enables the CPU-only mode.
    static let cpuThreshold: Double = 0.03

    /// CPU fraction (0…1) above which an agent is considered "working" despite a reported
    /// `idle` state (used by integrations that cannot report the start of a turn, e.g. Codex's
    /// `notify` hook, and by the CPU fallback for agents with no integration at all).
    static let busyOverrideThreshold: Double = 0.05

    /// Default process patterns. Long names are matched as substrings of process/path tokens
    /// (so `cursor-agent` matches `cursor-agent.js`), while patterns of 4 characters or fewer
    /// must match a whole token to avoid false positives (e.g. `amp` inside `example`).
    static let builtInPatterns: [String] = [
        "opencode", "codex", "claude", "aider", "gemini", "cursor-agent",
        "goose", "amp", "gptme", "qwen", "crush", "droid", "openhands",
        "plandex", "continue", "copilot", "windsurf", "cody",
        "pi"
    ]

    private let defaults = UserDefaults.standard

    private init() {
        // Registered defaults are used only when the user (or a previous run) did not write a
        // value explicitly; they do NOT persist.
        defaults.register(defaults: [
            Key.mode.rawValue: KeepAwakeMode.auto.rawValue,
            Key.preventDisplaySleep.rawValue: false,
            Key.preventSystemSleepOnAC.rawValue: false,
            Key.simulateActivity.rawValue: false,
            Key.activityInterval.rawValue: 60.0,
            Key.gracePeriod.rawValue: 120.0,
            Key.onlyOnAC.rawValue: false,
            Key.requireCPUActivity.rawValue: false,
            Key.pollInterval.rawValue: 2.0,
            Key.disabledPatterns.rawValue: [String](),
            Key.customPatterns.rawValue: [String](),
            Key.closedDisplayMode.rawValue: false,
            Key.closedDisplayEngaged.rawValue: false,
            Key.respectSessionState.rawValue: true,
            Key.maxDuration.rawValue: 0.0,
            Key.sessionStartedAt.rawValue: 0.0
        ])
    }

    // MARK: Core behaviour

    var mode: KeepAwakeMode {
        get { KeepAwakeMode(rawValue: defaults.string(forKey: Key.mode.rawValue) ?? "") ?? .auto }
        set { defaults.set(newValue.rawValue, forKey: Key.mode.rawValue) }
    }

    /// Also create a `PreventUserIdleDisplaySleep` assertion (screen stays on).
    var preventDisplaySleep: Bool {
        get { defaults.bool(forKey: Key.preventDisplaySleep.rawValue) }
        set { defaults.set(newValue, forKey: Key.preventDisplaySleep.rawValue) }
    }

    /// Also create a `PreventSystemSleep` assertion while on AC power (same as `caffeinate -s`).
    var preventSystemSleepOnAC: Bool {
        get { defaults.bool(forKey: Key.preventSystemSleepOnAC.rawValue) }
        set { defaults.set(newValue, forKey: Key.preventSystemSleepOnAC.rawValue) }
    }

    /// Periodically declare user activity so screen saver / lock do not engage.
    var simulateActivity: Bool {
        get { defaults.bool(forKey: Key.simulateActivity.rawValue) }
        set { defaults.set(newValue, forKey: Key.simulateActivity.rawValue) }
    }

    /// Interval between two "user activity" declarations, in seconds.
    var activityInterval: Double {
        get { defaults.double(forKey: Key.activityInterval.rawValue) }
        set { defaults.set(newValue, forKey: Key.activityInterval.rawValue) }
    }

    /// How long the Mac stays awake after the last agent stopped working, in seconds.
    var gracePeriod: Double {
        get { defaults.double(forKey: Key.gracePeriod.rawValue) }
        set { defaults.set(newValue, forKey: Key.gracePeriod.rawValue) }
    }

    /// Never assert anything while on battery power.
    var onlyOnAC: Bool {
        get { defaults.bool(forKey: Key.onlyOnAC.rawValue) }
        set { defaults.set(newValue, forKey: Key.onlyOnAC.rawValue) }
    }

    /// Legacy/explicit CPU-only mode: ignore session state entirely and classify agents by CPU.
    var requireCPUActivity: Bool {
        get { defaults.bool(forKey: Key.requireCPUActivity.rawValue) }
        set { defaults.set(newValue, forKey: Key.requireCPUActivity.rawValue) }
    }

    /// How often the monitor re-scans processes and re-evaluates the assertions, in seconds.
    var pollInterval: Double {
        get { max(1.0, defaults.double(forKey: Key.pollInterval.rawValue)) } // never below 1 s
        set { defaults.set(newValue, forKey: Key.pollInterval.rawValue) }
    }

    /// Consume session state files produced by agent integrations (hooks/plugins).
    var respectSessionState: Bool {
        get { defaults.bool(forKey: Key.respectSessionState.rawValue) }
        set { defaults.set(newValue, forKey: Key.respectSessionState.rawValue) }
    }

    // MARK: Maximum duration ("coffee" mode)

    /// Hard cap, in seconds, on how long the Mac may be kept awake in Always mode.
    /// `0` means no limit (classic Caffeine behaviour).
    var maxDuration: Double {
        get { max(0, defaults.double(forKey: Key.maxDuration.rawValue)) }
        set { defaults.set(newValue, forKey: Key.maxDuration.rawValue) }
    }

    /// When the current "keep awake" session in Always mode started (epoch seconds, 0 = none).
    /// Persisted so the limit also survives an app restart.
    var sessionStartedAt: Double {
        get { defaults.double(forKey: Key.sessionStartedAt.rawValue) }
        set { defaults.set(newValue, forKey: Key.sessionStartedAt.rawValue) }
    }

    // MARK: Closed-display mode

    /// User preference: also disable lid-close sleep while keeping the Mac awake.
    var closedDisplayMode: Bool {
        get { defaults.bool(forKey: Key.closedDisplayMode.rawValue) }
        set { defaults.set(newValue, forKey: Key.closedDisplayMode.rawValue) }
    }

    /// Internal bookkeeping flag: `pmset disablesleep` is currently set to 1 by this app.
    /// Persisted so a crash/kill can be detected and repaired on the next launch.
    var closedDisplayEngaged: Bool {
        get { defaults.bool(forKey: Key.closedDisplayEngaged.rawValue) }
        set { defaults.set(newValue, forKey: Key.closedDisplayEngaged.rawValue) }
    }

    // MARK: Agent patterns

    /// Extra patterns entered by the user (comma separated in the UI).
    var customPatterns: [String] {
        get { defaults.stringArray(forKey: Key.customPatterns.rawValue) ?? [] }
        set {
            let cleaned = newValue
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            defaults.set(cleaned, forKey: Key.customPatterns.rawValue)
        }
    }

    /// Built-in patterns disabled by the user (stored lowercased).
    var disabledPatterns: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.disabledPatterns.rawValue) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: Key.disabledPatterns.rawValue) }
    }

    /// Built-ins + custom patterns, de-duplicated case-insensitively, original order preserved.
    var allPatterns: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for pattern in Settings.builtInPatterns + customPatterns where seen.insert(pattern.lowercased()).inserted {
            result.append(pattern)
        }
        return result
    }

    /// Patterns the detector should currently look for.
    var enabledPatterns: [String] {
        allPatterns.filter { isPatternEnabled($0) }
    }

    func isPatternEnabled(_ pattern: String) -> Bool {
        !disabledPatterns.contains(pattern.lowercased())
    }

    /// Toggle a single pattern on/off (used by the checkbox grid in the popover).
    func setPattern(_ pattern: String, enabled: Bool) {
        var disabled = disabledPatterns
        if enabled {
            disabled.remove(pattern.lowercased())
        } else {
            disabled.insert(pattern.lowercased())
        }
        disabledPatterns = disabled
    }
}
