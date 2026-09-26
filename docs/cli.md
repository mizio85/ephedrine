# CLI

The same binary is both the menu bar app and a small CLI. Reporter and utility modes never start the
AppKit run loop: agents invoke them synchronously on every turn event, so they do their job and exit
immediately.

| Command | Description |
|---|---|
| `Ephedrine` | Starts the menu bar app |
| `Ephedrine --report busy\|idle --agent <name> [--pid N] [--idle-only] [--passthrough <prog> <args…>]` | Writes a state file for the invoking agent (used by integrations) |
| `Ephedrine --install-integration <codex\|claude\|opencode\|pi>` | Installs the integration |
| `Ephedrine --uninstall-integration <codex\|claude\|opencode\|pi>` | Removes the integration |
| `Ephedrine --dump-agents` | Prints detected processes, CPU and session states (debugging) |

## `--report`

```bash
Ephedrine --report busy  --agent opencode
Ephedrine --report idle  --agent codex --idle-only
Ephedrine --report idle  --agent codex --passthrough /path/to/original-notify turn-ended
```

- `--agent <name>` — the agent name used as the state key.
- `--pid N` — optional. When omitted, Ephedrine walks the parent process chain looking for a process
  whose name matches `--agent`, falling back to the direct parent.
- `--idle-only` — marks the reporter as unable to signal the start of a turn (Codex `notify`), so
  Ephedrine combines it with the CPU heuristic.
- `--passthrough <prog> <args…>` — after writing the state, re-executes another program with the
  given arguments (used to wrap an existing `notify` command without breaking it).

Exit code `64` (`EX_USAGE`) when no status is supplied.

## `--install-integration` / `--uninstall-integration`

```bash
/Applications/Ephedrine.app/Contents/MacOS/Ephedrine --install-integration opencode
/Applications/Ephedrine.app/Contents/MacOS/Ephedrine --uninstall-integration opencode
```

The path of the running binary is embedded into the generated hook/plugin, so run it from the
location where the app actually lives.

## `--dump-agents`

Prints what the detector sees, for debugging:

```
mode=auto respectSessionState=true cpuOnly=false pattern=19
states received: opencode=busy
  pattern=opencode pid=98373 name=node cpu=0.412 state=busy path=…/node
  pattern=pi       pid=14315 name=node cpu=0.000 state=idle path=…/node
```

- `state=-` means "no integration" → the CPU fallback applies.
- `cpu` is a fraction of one core.

It performs a couple of extra sampling passes (a few seconds) so the CPU column is meaningful.
