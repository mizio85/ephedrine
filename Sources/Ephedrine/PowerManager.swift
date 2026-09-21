//
//  PowerManager.swift
//  Ephedrine
//
//  Owns the IOKit power assertions that actually keep the Mac awake.
//
//  Assertions used
//  ---------------
//  * `PreventUserIdleSystemSleep`  — created whenever the app wants to keep the Mac awake.
//    This is the moral equivalent of `caffeinate -i` and the only assertion that is required.
//  * `PreventUserIdleDisplaySleep` — optional (`Mantieni display acceso`): the screen stays on,
//    like `caffeinate -d`.
//  * `PreventSystemSleep`          — optional, AC-only (`Impedisci sleep di sistema`), similar to
//    `caffeinate -s`; it also prevents sleep requested by the system rather than by idle timers.
//  * `IOPMAssertionDeclareUserActivity` — optional "simulate activity" feature: briefly declares
//    user activity so that screensaver/lock idle timers are reset (`caffeinate -u` equivalent).
//
//  Assertion names are user-visible (`pmset -g assertions`) and therefore kept in sync with the
//  current reason ("Ephedrine - agent attivi: opencode, codex").
//
//  The assertions disappear automatically if this process dies, so there is no risk of leaving
//  the Mac permanently awake if the app crashes.
//

import Foundation
import IOKit.ps
import IOKit.pwr_mgt

/// Creates, updates and releases the IOKit power assertions. All calls happen on the main thread.
@MainActor
final class PowerManager {

    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var deepAssertion: IOPMAssertionID = 0
    private var currentReason = ""

    /// Last IOKit failure, surfaced in the popover (`nil` when everything is fine).
    private(set) var lastError: String?

    /// True when at least the system-idle assertion is held.
    var isEngaged: Bool { systemAssertion != 0 }

    // MARK: - Power source

    private static var cachedPowerSource: (value: Bool, at: Date)?
    private static let powerSourceCacheTTL: TimeInterval = 5

    /// Whether the Mac is running on AC power. Cached for a few seconds because the monitor may
    /// ask several times per tick and each query creates an IOKit snapshot.
    static var isOnACPower: Bool {
        if let cached = cachedPowerSource, Date().timeIntervalSince(cached.at) < powerSourceCacheTTL {
            return cached.value
        }
        let value = readPowerSource()
        cachedPowerSource = (value, Date())
        return value
    }

    private static func readPowerSource() -> Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sourceType = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() as String?
        else {
            // Desktops (Mac mini/Studio/Pro) do not report a battery: assume AC.
            return true
        }
        return sourceType == (kIOPSACPowerValue as String)
    }

    // MARK: - Assertions

    /// Ensures the assertion set matches the requested configuration.
    ///
    /// Idempotent: called on every tick, it only creates/releases what actually changed.
    /// - Parameters:
    ///   - reason: user-visible name (shown by `pmset -g assertions`).
    ///   - preventDisplay: also keep the display awake.
    ///   - preventSystemSleep: also hold `PreventSystemSleep` (caller checks AC power).
    func engage(reason: String, preventDisplay: Bool, preventSystemSleep: Bool) {
        lastError = nil

        if systemAssertion == 0 {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &id
            )
            if result == kIOReturnSuccess {
                systemAssertion = id
                currentReason = reason
            } else {
                lastError = "Impossibile creare l'assertion (IOReturn \(result))"
            }
        }

        if preventDisplay {
            if displayAssertion == 0 {
                var id: IOPMAssertionID = 0
                if IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    reason as CFString,
                    &id
                ) == kIOReturnSuccess {
                    displayAssertion = id
                }
            }
        } else if displayAssertion != 0 {
            IOPMAssertionRelease(displayAssertion)
            displayAssertion = 0
        }

        if preventSystemSleep {
            if deepAssertion == 0 {
                var id: IOPMAssertionID = 0
                if IOPMAssertionCreateWithName(
                    kIOPMAssertionTypePreventSystemSleep as CFString,
                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                    reason as CFString,
                    &id
                ) == kIOReturnSuccess {
                    deepAssertion = id
                }
            }
        } else if deepAssertion != 0 {
            IOPMAssertionRelease(deepAssertion)
            deepAssertion = 0
        }
    }

    /// Renames the held assertions (cheap; only when the reason actually changed).
    func updateReason(_ reason: String) {
        guard isEngaged, reason != currentReason else { return }
        IOPMAssertionSetProperty(systemAssertion, kIOPMAssertionNameKey as CFString, reason as CFString)
        if displayAssertion != 0 {
            IOPMAssertionSetProperty(displayAssertion, kIOPMAssertionNameKey as CFString, reason as CFString)
        }
        if deepAssertion != 0 {
            IOPMAssertionSetProperty(deepAssertion, kIOPMAssertionNameKey as CFString, reason as CFString)
        }
        currentReason = reason
    }

    /// Releases every held assertion (mode Off, no agents, app termination).
    func releaseAll() {
        if systemAssertion != 0 {
            IOPMAssertionRelease(systemAssertion)
            systemAssertion = 0
        }
        if displayAssertion != 0 {
            IOPMAssertionRelease(displayAssertion)
            displayAssertion = 0
        }
        if deepAssertion != 0 {
            IOPMAssertionRelease(deepAssertion)
            deepAssertion = 0
        }
        currentReason = ""
    }

    /// Resets the user-idle timer (screensaver/lock) without keeping anything else awake.
    /// The temporary assertion is released immediately: only the side effect matters.
    func declareUserActivity(reason: String) {
        var id: IOPMAssertionID = 0
        if IOPMAssertionDeclareUserActivity(reason as CFString, kIOPMUserActiveLocal, &id) == kIOReturnSuccess {
            IOPMAssertionRelease(id)
        }
    }
}
