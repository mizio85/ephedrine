//
//  Integrations.swift
//  Ephedrine
//
//  Per-agent integrations that make an agent report its turn lifecycle (busy/idle) to
//  Ephedrine. Every integration writes to its own native extension point and is reversible:
//
//   * opencode      → plugin in  ~/.config/opencode/plugin/ephedrine.ts
//                     subscribes to the server event bus (`session.status`, `session.idle`, …)
//
//   * Claude Code   → hooks in   ~/.claude/settings.json
//                     `UserPromptSubmit` → busy, `Stop` → idle
//
//   * Codex         → `notify` in ~/.codex/config.toml
//                     fires only at end of turn (`agent-turn-complete`) → idle + `--idle-only`.
//                     If the user already has a `notify` program (e.g. computer-use helpers), the
//                     new command wraps it with `--passthrough`, so the original program keeps
//                     receiving its arguments unchanged.
//
//  All file writes are done defensively:
//   * a one-time backup `<file>.ephedrine-backup` is created before the first modification;
//   * the original Codex notify line is preserved in a comment and restored on uninstall;
//   * JSON files are parsed and re-serialized (never string-patched) so formatting stays valid.
//

import Foundation

/// Identifier of a supported agent integration.
enum Integration: String, CaseIterable {
    case codex
    case claude
    case opencode
    case pi

    /// Marker used to recognise our own entries in foreign config files.
    static let marker = "Ephedrine"

    var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude Code"
        case .opencode: return "opencode"
        case .pi: return "pi"
        }
    }

    /// File that gets created/modified by the integration.
    var configPath: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .codex:
            return home.appendingPathComponent(".codex/config.toml")
        case .claude:
            return home.appendingPathComponent(".claude/settings.json")
        case .opencode:
            // Respect XDG_CONFIG_HOME when the user relocated their config.
            let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".config")
            return base.appendingPathComponent("opencode/plugin/ephedrine.ts")
        case .pi:
            return home.appendingPathComponent(".pi/agent/extensions/ephedrine.ts")
        }
    }

    /// Whether our marker is already present in the target file.
    var isInstalled: Bool {
        switch self {
        case .codex, .opencode, .pi:
            guard let content = try? String(contentsOf: configPath, encoding: .utf8) else { return false }
            return content.contains(Self.marker)
        case .claude:
            guard let root = Self.readJSON(configPath) else { return false }
            return Self.claudeCommands(in: root).contains { $0.contains(Self.marker) }
        }
    }

    /// Installs the integration. `executablePath` is embedded into the generated hook/plugin.
    /// - Returns: an error message, or `nil` on success.
    func install(executablePath: String) -> String? {
        switch self {
        case .codex: return installCodex(executablePath: executablePath)
        case .claude: return installClaude(executablePath: executablePath)
        case .opencode: return installOpencode(executablePath: executablePath)
        case .pi: return installPi(executablePath: executablePath)
        }
    }

    /// Removes the integration, restoring the original configuration where possible.
    /// - Returns: an error message, or `nil` on success.
    func uninstall() -> String? {
        switch self {
        case .codex: return uninstallCodex()
        case .claude: return uninstallClaude()
        case .opencode: return uninstallOpencode()
        case .pi: return uninstallPi()
        }
    }

    // MARK: - Codex (config.toml `notify`)

    /// Comment written next to the generated `notify` line so uninstall can restore the original.
    private static let codexOriginalNotifyMarker = "# ephedrine-original-notify:"

    private func installCodex(executablePath: String) -> String? {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return error.localizedDescription
        }

        var lines = ((try? String(contentsOf: configPath, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        backupIfNeeded(configPath)

        // Drop any previously generated entry first so the install stays idempotent and we never
        // wrap our own command as if it were a foreign one. `stripCodexEntries` restores the
        // original foreign `notify` (if any), which is then wrapped again below.
        if lines.contains(where: { Self.isOurCodexLine($0) }) {
            lines = Self.stripCodexEntries(lines)
        }

        if let index = lines.firstIndex(where: {
            let trimmed = $0.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("notify") && trimmed.contains("=")
        }) {
            // A foreign notify exists (e.g. Codex Computer Use): wrap it instead of replacing it.
            let originalLine = lines[index]
            let originalArguments = Self.quotedStrings(in: originalLine)
            guard !originalArguments.isEmpty else {
                return L("integration.unrecognizedNotify")
            }
            lines[index] = Self.codexNotifyLine(executablePath: executablePath, passthrough: originalArguments)
            lines.insert(Self.codexOriginalNotifyMarker + " " + originalLine.trimmingCharacters(in: .whitespaces), at: index + 1)
        } else {
            // No notify configured: append ours at the end of the file.
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            lines.append(Self.codexNotifyLine(executablePath: executablePath, passthrough: []))
        }

        return writeLines(lines, to: configPath)
    }

    private func uninstallCodex() -> String? {
        guard let content = try? String(contentsOf: configPath, encoding: .utf8) else { return nil }
        let lines = content.components(separatedBy: "\n")
        guard lines.contains(where: { Self.isOurCodexLine($0) }) else { return nil }
        return writeLines(Self.stripCodexEntries(lines), to: configPath)
    }

    /// True for a `notify` line generated by us, or for the `# …-original-notify:` comment that
    /// records a wrapped foreign program.
    private static func isOurCodexLine(_ line: String) -> Bool {
        if line.contains(marker), line.contains("notify") { return true }
        return line.trimmingCharacters(in: .whitespaces).hasPrefix(codexOriginalNotifyMarker)
    }

    /// Removes our generated `notify` line and restores the original foreign `notify` recorded at
    /// install time.
    private static func stripCodexEntries(_ lines: [String]) -> [String] {
        var restored = false
        var output: [String] = []
        for line in lines {
            if isOurCodexLine(line) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix(codexOriginalNotifyMarker) {
                    let original = trimmed.replacingOccurrences(of: codexOriginalNotifyMarker, with: "")
                        .trimmingCharacters(in: .whitespaces)
                    if !original.isEmpty, !restored {
                        output.append(original)
                        restored = true
                    }
                }
                continue
            }
            output.append(line)
        }
        return output
    }

    /// Builds the TOML `notify` line, optionally chaining the previous program via `--passthrough`.
    private static func codexNotifyLine(executablePath: String, passthrough: [String]) -> String {
        var parts = [executablePath, "--report", "idle", "--agent", "codex", "--idle-only"]
        if !passthrough.isEmpty {
            parts.append("--passthrough")
            parts.append(contentsOf: passthrough)
        }
        return "notify = [" + parts.map(tomlString).joined(separator: ", ") + "]"
    }

    // MARK: - Claude Code (settings.json hooks)

    private func installClaude(executablePath: String) -> String? {
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: configPath.path) {
            guard let parsed = Self.readJSON(configPath) else {
                return L("integration.invalidClaudeSettings")
            }
            root = parsed
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        // Drop any entries from the current or previous name before re-adding, so a rename cannot
        // leave duplicate hooks pointing at a stale binary path.
        Self.removeClaudeHooks(&hooks)
        Self.addClaudeHook(
            event: "UserPromptSubmit",
            command: "\(executablePath) --report busy --agent claude",
            hooks: &hooks
        )
        Self.addClaudeHook(
            event: "Stop",
            command: "\(executablePath) --report idle --agent claude",
            hooks: &hooks
        )
        root["hooks"] = hooks
        backupIfNeeded(configPath)
        return writeJSON(root, to: configPath)
    }

    private func uninstallClaude() -> String? {
        guard var root = Self.readJSON(configPath), var hooks = root["hooks"] as? [String: Any] else { return nil }

        // Remove only our hook entries; leave every other hook untouched.
        Self.removeClaudeHooks(&hooks)

        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        return writeJSON(root, to: configPath)
    }

    /// True for a hook command generated by us.
    private static func isOurClaudeCommand(_ command: String) -> Bool {
        command.contains(marker)
    }

    /// Removes every hook entry we generated, leaving foreign hooks.
    private static func removeClaudeHooks(_ hooks: inout [String: Any]) {
        for event in Array(hooks.keys) {
            guard var entries = hooks[event] as? [[String: Any]] else { continue }
            entries = entries.filter { entry in
                let inner = entry["hooks"] as? [[String: Any]] ?? []
                return !inner.contains { isOurClaudeCommand($0["command"] as? String ?? "") }
            }
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }
    }

    private static func addClaudeHook(event: String, command: String, hooks: inout [String: Any]) {
        var entries = hooks[event] as? [[String: Any]] ?? []
        let alreadyPresent = entries.contains { entry in
            let inner = entry["hooks"] as? [[String: Any]] ?? []
            return inner.contains { isOurClaudeCommand($0["command"] as? String ?? "") }
        }
        if !alreadyPresent {
            entries.append(["hooks": [["type": "command", "command": command]]])
        }
        hooks[event] = entries
    }

    private static func claudeCommands(in root: [String: Any]) -> [String] {
        guard let hooks = root["hooks"] as? [String: Any] else { return [] }
        var commands: [String] = []
        for value in hooks.values {
            guard let entries = value as? [[String: Any]] else { continue }
            for entry in entries {
                let inner = entry["hooks"] as? [[String: Any]] ?? []
                for hook in inner {
                    if let command = hook["command"] as? String {
                        commands.append(command)
                    }
                }
            }
        }
        return commands
    }

    // MARK: - opencode (plugin)

    private func installOpencode(executablePath: String) -> String? {
        do {
            try FileManager.default.createDirectory(at: configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return error.localizedDescription
        }
        backupIfNeeded(configPath)
        do {
            try Self.opencodePlugin(executablePath: executablePath).write(to: configPath, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func uninstallOpencode() -> String? {
        guard FileManager.default.fileExists(atPath: configPath.path) else { return nil }
        do {
            try FileManager.default.removeItem(at: configPath)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Generates the opencode plugin source, with the reporter binary path baked in.
    ///
    /// Event mapping (opencode ≥ 1.15):
    ///  * `session.status` `busy`/`retry` → busy; `idle` → idle (authoritative signal).
    ///  * `session.idle` → idle (older/newer alias, kept for compatibility).
    ///  * `message.part.delta` / `message.part.updated` → busy (streaming tokens).
    ///  * `message.updated` → busy **only** for assistant messages without `time.completed`,
    ///    because late updates (titles, user messages) also arrive *after* `session.idle` and
    ///    would otherwise leave the agent marked as busy forever.
    ///
    /// Busy sessions are tracked in a set: with multiple parallel sessions the agent is reported
    /// idle only when the last one finishes. All errors are swallowed so a broken reporter can
    /// never break the agent.
    private static func opencodePlugin(executablePath: String) -> String {
        let escaped = executablePath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        // Ephedrine: segnala turni busy/idle cosi il Mac resta sveglio solo mentre l'agente lavora.
        import { spawn } from "node:child_process"

        const BINARY = "\(escaped)"

        export const Ephedrine = async () => {
          const busySessions = new Set<string>()

          const report = (state: "busy" | "idle") => {
            try {
              const child = spawn(BINARY, ["--report", state, "--agent", "opencode", "--pid", String(process.pid)], {
                detached: true,
                stdio: "ignore",
              })
              child.unref()
            } catch {
              // non deve mai bloccare l'agente
            }
          }

          const markBusy = (sessionID?: string) => {
            if (sessionID) busySessions.add(sessionID)
            report("busy")
          }

          const markIdle = (sessionID?: string) => {
            if (sessionID) busySessions.delete(sessionID)
            if (busySessions.size === 0) report("idle")
          }

          return {
            event: async ({ event }: { event?: { type?: string; properties?: any } }) => {
              try {
                const type = event?.type
                if (!type) return
                const properties = event?.properties ?? {}
                const sessionID =
                  properties.sessionID ??
                  properties.info?.sessionID ??
                  properties.part?.sessionID

                if (type === "session.status") {
                  if (properties.status?.type === "idle") markIdle(sessionID)
                  else markBusy(sessionID)
                } else if (type === "session.idle") {
                  markIdle(sessionID)
                } else if (type === "session.deleted") {
                  if (sessionID) busySessions.delete(sessionID)
                } else if (type === "message.part.delta" || type === "message.part.updated") {
                  markBusy(sessionID)
                } else if (type === "message.updated") {
                  const info = properties.info
                  if (info?.role === "assistant" && !info?.time?.completed) markBusy(sessionID)
                }
              } catch {
                // non deve mai bloccare l'agente
              }
            },
          }
        }
        """
    }

    // MARK: - pi (extension)

    private func installPi(executablePath: String) -> String? {
        do {
            try FileManager.default.createDirectory(at: configPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return error.localizedDescription
        }
        backupIfNeeded(configPath)
        do {
            try Self.piExtension(executablePath: executablePath).write(to: configPath, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func uninstallPi() -> String? {
        guard FileManager.default.fileExists(atPath: configPath.path) else { return nil }
        do {
            try FileManager.default.removeItem(at: configPath)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Generates the pi extension that reports the turn lifecycle to Ephedrine.
    ///
    /// pi's `agent_start` fires when a run begins and `agent_settled` fires when pi will not
    /// continue automatically (after retries, compaction and queued follow-ups) — exactly the
    /// busy/idle signal Ephedrine needs. Both transitions are reported, so `reports_busy` is true
    /// and CPU activity is not needed to detect the start of a turn.
    private static func piExtension(executablePath: String) -> String {
        let escaped = executablePath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        // Ephedrine: segnala turni busy/idle cosi il Mac resta sveglio solo mentre l'agente lavora.
        import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
        import { spawn } from "node:child_process";

        const BINARY = "\(escaped)";

        export default function (pi: ExtensionAPI) {
          const report = (state: "busy" | "idle") => {
            try {
              const child = spawn(BINARY, ["--report", state, "--agent", "pi", "--pid", String(process.pid)], {
                detached: true,
                stdio: "ignore",
              });
              child.unref();
            } catch {
              // non deve mai bloccare l'agente
            }
          };

          pi.on("agent_start", async () => report("busy"));
          pi.on("agent_settled", async () => report("idle"));
          pi.on("session_start", async () => report("idle"));
          pi.on("session_shutdown", async () => report("idle"));
        }
        """
    }

    // MARK: - Helpers

    /// Creates `<file>.ephedrine-backup` before the first modification.
    private func backupIfNeeded(_ url: URL) {
        let fileManager = FileManager.default
        let backup = url.appendingPathExtension("ephedrine-backup")
        guard fileManager.fileExists(atPath: url.path), !fileManager.fileExists(atPath: backup.path) else { return }
        try? fileManager.copyItem(at: url, to: backup)
    }

    private func writeLines(_ lines: [String], to url: URL) -> String? {
        var text = lines.joined(separator: "\n")
        if !text.hasSuffix("\n") { text += "\n" }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func writeJSON(_ object: [String: Any], to url: URL) -> String? {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            data.append(0x0A) // trailing newline
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Quotes a value for a TOML basic string.
    private static func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Extracts every double-quoted string from a line, honouring backslash escapes.
    /// Used to read the program/arguments out of an existing TOML `notify` array.
    private static func quotedStrings(in line: String) -> [String] {
        var results: [String] = []
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
                    results.append(current)
                    current = ""
                    inString = false
                } else {
                    current.append(character)
                }
            } else if character == "\"" {
                inString = true
            }
        }
        return results
    }
}

/// CLI implementation of `--install-integration` / `--uninstall-integration`.
enum IntegrationCommand {

    static func install(id: String) -> Int32 {
        guard let integration = Integration(rawValue: id) else {
            print(Lf("cli.unknownIntegration", id))
            return 64
        }
        let executable = Bundle.main.executablePath ?? CommandLine.arguments.first ?? "Ephedrine"
        if let error = integration.install(executablePath: executable) {
            print(Lf("cli.error", error))
            return 1
        }
        print(Lf("cli.integrationInstalled", integration.title, integration.configPath.path))
        return 0
    }

    static func uninstall(id: String) -> Int32 {
        guard let integration = Integration(rawValue: id) else {
            print(Lf("cli.unknownIntegration", id))
            return 64
        }
        if let error = integration.uninstall() {
            print(Lf("cli.error", error))
            return 1
        }
        print(Lf("cli.integrationRemoved", integration.title, integration.configPath.path))
        return 0
    }
}
