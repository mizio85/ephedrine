# Agent integrations

An *integration* teaches an agent to tell Ephedrine when a **turn** starts and ends. Without it,
Ephedrine still detects the process, but classifies it by CPU; with it, an idle agent releases the
Mac immediately and a busy agent holds it even when the work is network-bound and CPU usage is low.

Install and remove them from the popover (**Turn-state integrations**) or via the [CLI](cli.md):

```bash
/Applications/Ephedrine.app/Contents/MacOS/Ephedrine --install-integration opencode
/Applications/Ephedrine.app/Contents/MacOS/Ephedrine --uninstall-integration opencode
```

Every integration creates a `.ephedrine-backup` copy of the modified file the first time, and
uninstall restores the previous state (for Codex the original `notify` line is preserved verbatim
in a comment and restored on removal).

!!! warning "Moving the app"
    The **path of the running binary is embedded** in the generated hook/plugin. If you move the app
    (e.g. from `build/` to `/Applications`), reinstall the integration from the new location.

## How turn state is transmitted

Integrations write small JSON files to:

```
~/Library/Application Support/Ephedrine/state/
```

```json
{ "agent": "opencode", "pid": 98373, "state": "busy", "reports_busy": true, "updated": 1789673906 }
```

- Files older than **30 minutes** are deleted automatically.
- Files whose pid is gone are excluded from pid-level matching but kept as an **agent-level
  fallback** (up to 30 minutes), so a `busy` state survives an agent/helper restart mid-turn.
- The `reports_busy` flag tells Ephedrine whether the integration reports **both** transitions
  (opencode, Claude Code, pi) or **only the end of a turn** (Codex `notify`).

The same binary writes these files: `Ephedrine --report …`.

## opencode

- **File:** `~/.config/opencode/plugin/ephedrine.ts` (respects `XDG_CONFIG_HOME`).
- **Mechanism:** an official plugin subscribed to the server event bus.
- **Events used:**
    - `session.status` (`busy` / `idle` / `retry`) — authoritative state;
    - `session.idle` — end-of-turn alias;
    - `message.part.delta` / `message.part.updated` — streaming tokens ⇒ busy;
    - `message.updated` — busy only for assistant messages without `time.completed` (late updates
      arrive *after* `session.idle` and must not resurrect the busy state).
- Parallel sessions are tracked individually: the agent is reported idle only when the last session
  finishes.
- Restart opencode (or the OpenCode desktop app) after installing so the plugin is loaded.

## Claude Code

- **File:** `~/.claude/settings.json`.
- **Hooks added:** `UserPromptSubmit` → `--report busy`, `Stop` → `--report idle`. Existing hooks are
  preserved.

## Codex

- **File:** `~/.codex/config.toml`.
- Codex can only notify at the **end** of a turn (`agent-turn-complete`), so the integration installs

    ```toml
    notify = ["…/Ephedrine", "--report", "idle", "--agent", "codex", "--idle-only"]
    ```

    and Ephedrine combines it with the CPU heuristic to detect the start of the next turn.
- If a `notify` program is already configured (for example Codex Computer Use), it is **wrapped,
  not replaced**: Ephedrine writes the state and then re-executes the original program with its
  arguments via `--passthrough`, so nothing breaks.

## pi

- **File:** `~/.pi/agent/extensions/ephedrine.ts`.
- **Mechanism:** a pi extension subscribed to the agent lifecycle.
- **Events used:** `agent_start` → busy, `agent_settled` → idle. `agent_settled` fires only when pi
  will not continue automatically, so auto-retry, compaction and queued follow-ups keep the Mac
  awake; `session_start` / `session_shutdown` report idle.
- Both transitions are reported, so the CPU heuristic is not needed.
- Run `/reload` or restart pi after installing so the extension is loaded.

## Other agents

Add one or more patterns in **Monitored agents → Other agents…**. Without an integration the agent
is classified by CPU activity; if you want the classic "as long as the app is open" behaviour,
disable **Respect turn state**.

You can also report state yourself from any script or daemon:

```bash
"/Applications/Ephedrine.app/Contents/MacOS/Ephedrine" --report busy --agent my-agent
"/Applications/Ephedrine.app/Contents/MacOS/Ephedrine" --report idle --agent my-agent
```

## Debugging

```bash
# Show every detected process, its CPU and its session state
/Applications/Ephedrine.app/Contents/MacOS/Ephedrine --dump-agents

# Inspect the raw state files
ls ~/Library/Application\ Support/Ephedrine/state/
```
