# Advanced options and settings

Preferences live in the `local.maurizio.Ephedrine` domain and are also editable from the shell.
Values are read on every monitor tick, so `defaults write` changes are picked up within a few
seconds without restarting the app.

## Reference

| Key | Default | Meaning |
|---|---|---|
| `mode` | `auto` | `off` / `auto` / `always` |
| `maxDuration` | `0` | Seconds cap for `always` mode (`0` = unlimited) |
| `respectSessionState` | `true` | Use busy/idle state from integrations |
| `requireCPUActivity` | `false` | Explicit CPU-only classification |
| `preventDisplaySleep` | `false` | Keep the display awake too |
| `preventSystemSleepOnAC` | `false` | Also hold `PreventSystemSleep` on AC |
| `simulateActivity` | `false` | Reset screensaver/lock idle timers |
| `activityInterval` | `60` | Seconds between activity declarations |
| `gracePeriod` | `120` | Seconds of keep-awake after the last activity |
| `onlyOnAC` | `false` | Do nothing while on battery |
| `pollInterval` | `2` | Seconds between monitor ticks (min 1) |
| `customPatterns` | `[]` | Extra process patterns |
| `disabledPatterns` | `[]` | Built-in patterns turned off |
| `closedDisplayMode` | `false` | Closed-display mode enabled |
| `closedDisplayEngaged` | `false` | Internal: `disablesleep` currently set by the app |
| `sessionStartedAt` | `0` | Internal: start of the current `always` session (epoch s) |

## Examples

```bash
# A longer grace window
defaults write local.maurizio.Ephedrine gracePeriod -float 300

# A 1-hour run limit in Always mode
defaults write local.maurizio.Ephedrine maxDuration -float 3600

# Never keep the Mac awake on battery
defaults write local.maurizio.Ephedrine onlyOnAC -bool true

# Watch an extra agent
defaults write local.maurizio.Ephedrine customPatterns -array "my-agent"

# Switch mode from a script
defaults write local.maurizio.Ephedrine mode -string auto
```

Reset everything by deleting the domain (the app will recreate defaults on next launch):

```bash
defaults delete local.maurizio.Ephedrine
```

## Power assertions used

| Assertion | When |
|---|---|
| `PreventUserIdleSystemSleep` | Always while the Mac must stay awake (like `caffeinate -i`). |
| `PreventUserIdleDisplaySleep` | Only with **Keep display awake** (`caffeinate -d`). |
| `PreventSystemSleep` | Only with **Prevent system sleep (AC)**, on AC power (`caffeinate -s`). |
| `IOPMAssertionDeclareUserActivity` | Only with **Simulate user activity** (`caffeinate -u`). |

The assertions are named after the current reason, e.g. `Ephedrine - agents working: opencode, codex`,
and are owned by the process — a crash can never leave the Mac permanently awake.
