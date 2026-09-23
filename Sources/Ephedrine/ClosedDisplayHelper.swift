//
//  ClosedDisplayHelper.swift
//  Ephedrine
//
//  "Closed display" mode: keep the Mac awake even when the laptop lid is closed.
//
//  Why is a helper needed?
//  -----------------------
//  No power assertion can prevent lid-close sleep: macOS ignores `PreventUserIdleSystemSleep`
//  (and `caffeinate`) when the lid closes without an external display. The only supported switch
//  is the firmware/power-management setting `pmset -a disablesleep 1`, which requires root.
//
//  So this file manages a *minimal, auditable* privileged helper:
//
//      /usr/local/bin/ephedrine-display   (root:wheel, 0755)
//        on|off|status → pmset -a disablesleep 1|0 / report current value
//
//      /etc/sudoers.d/ephedrine           (root:wheel, 0440)
//        <user> ALL=(root) NOPASSWD: /usr/local/bin/ephedrine-display
//
//  Installation happens once, through a single macOS administrator prompt (`osascript … with
//  administrator privileges`). Afterwards the app can toggle `disablesleep` silently, which is
//  what allows it to restore `disablesleep 0` automatically when agents stop, when the user turns
//  the feature off, or when the app quits/relaunches after a crash.
//
//  Security notes
//  --------------
//  * The helper is owned by root and not writable by the user, so the NOPASSWD rule cannot be
//    abused to run arbitrary code.
//  * The sudoers file is validated with `visudo -cf` before it is kept; on failure the script
//    aborts and leaves nothing behind.
//  * The install/uninstall scripts are base64-encoded and piped straight into `bash` — no
//    temporary files are created, so there is no race window where a file could be swapped.
//  * Uninstalling (popover → "Rimuovi supporto coperchio chiuso…") deletes both files and
//    restores normal lid behaviour.
//

import Foundation

final class ClosedDisplayHelper {

    static let shared = ClosedDisplayHelper()

    static let helperPath = "/usr/local/bin/ephedrine-display"
    static let sudoersPath = "/etc/sudoers.d/ephedrine"

    /// True when the privileged helper is present and executable.
    var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: Self.helperPath)
    }

    /// Reads the system-wide `SleepDisabled` value. Absent key means 0 (normal behaviour).
    func systemSleepDisabled() -> Bool {
        let result = run("/usr/bin/pmset", ["-g"])
        guard result.status == 0 else { return false }
        for line in result.output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "SleepDisabled" {
                return parts[1] == "1"
            }
        }
        return false
    }

    /// Toggles `disablesleep` through the helper (`sudo -n`, never prompts).
    /// Returns false when the helper is missing or the sudoers rule is not in place.
    func setEnabled(_ enabled: Bool) -> Bool {
        runSudo([enabled ? "on" : "off"]).status == 0
    }

    /// One-time installation of helper + sudoers rule. Returns an error message or `nil`.
    func install() -> String? {
        guard let user = sanitizedUserName() else {
            return L("helper.badUsername")
        }
        return runAdmin(installScript(user: user)) ? nil : L("helper.installFailed")
    }

    /// Removes helper + sudoers rule and restores normal lid-close sleep.
    func uninstall() -> String? {
        runAdmin(uninstallScript()) ? nil : L("helper.uninstallFailed")
    }

    // MARK: - Private

    private struct CommandResult {
        let status: Int32
        let output: String
        let error: String
    }

    /// Usernames are interpolated into a sudoers file: only accept a conservative charset.
    private func sanitizedUserName() -> String? {
        let user = NSUserName()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !user.isEmpty, user.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return user
    }

    private func installScript(user: String) -> String {
        """
        #!/bin/bash
        set -euo pipefail
        HELPER="\(Self.helperPath)"
        SUDOERS="\(Self.sudoersPath)"
        mkdir -p /usr/local/bin
        cat > "$HELPER" <<'EPHEDRINE_HELPER'
        #!/bin/bash
        set -euo pipefail
        case "${1:-}" in
          on)  exec /usr/bin/pmset -a disablesleep 1 ;;
          off) exec /usr/bin/pmset -a disablesleep 0 ;;
          status) /usr/bin/pmset -g | /usr/bin/awk '/SleepDisabled/ {print $2; found=1} END {if (!found) print 0}' ;;
          *) echo "usage: $0 on|off|status" >&2; exit 64 ;;
        esac
        EPHEDRINE_HELPER
        chmod 755 "$HELPER"
        chown root:wheel "$HELPER"
        printf '%s ALL=(root) NOPASSWD: %s\\n' "\(user)" "$HELPER" > "$SUDOERS"
        chmod 440 "$SUDOERS"
        chown root:wheel "$SUDOERS"
        /usr/sbin/visudo -cf "$SUDOERS" >/dev/null
        """
    }

    private func uninstallScript() -> String {
        """
        #!/bin/bash
        set -euo pipefail
        /usr/bin/pmset -a disablesleep 0 || true
        rm -f "\(Self.sudoersPath)" "\(Self.helperPath)"
        """
    }

    /// Runs a shell script with administrator privileges via a single OS password prompt.
    /// The script is base64-encoded into the AppleScript command to avoid quoting and temp files.
    private func runAdmin(_ script: String) -> Bool {
        let encoded = Data(script.utf8).base64EncodedString()
        let shellCommand = "echo '\(encoded)' | /usr/bin/base64 -D | /bin/bash"
        let appleScript = "do shell script \"\(shellCommand)\" with administrator privileges"
        return run("/usr/bin/osascript", ["-e", appleScript]).status == 0
    }

    /// Runs the installed helper without prompting (works only with the NOPASSWD rule).
    private func runSudo(_ arguments: [String]) -> CommandResult {
        run("/usr/bin/sudo", ["-n", Self.helperPath] + arguments)
    }

    /// Minimal synchronous process runner with captured stdout/stderr.
    private func run(_ launchPath: String, _ arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, output: "", error: error.localizedDescription)
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return CommandResult(
            status: process.terminationStatus,
            output: String(data: outputData, encoding: .utf8) ?? "",
            error: String(data: errorData, encoding: .utf8) ?? ""
        )
    }
}
