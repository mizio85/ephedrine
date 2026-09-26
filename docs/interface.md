# Interface

Ephedrine lives in the menu bar. Click the icon to open the popover.

## Menu bar icon

| Icon | Meaning |
|---|---|
| 🟢 Green filled cup | Keeping the Mac awake — at least one agent is working |
| 🟠 Orange hourglass | Grace period — work just finished, the Mac stays awake for the remaining seconds |
| ⚪ White outline cup | Standby — armed, but nothing is working (the Mac may sleep) |
| ⚪ Dimmed outline cup | Mode `Off` |

Hover over the icon for a one-line status (and whether lid-close sleep is currently disabled).

## The popover

![Ephedrine popover](popover.png)

From top to bottom:

### Header

Shows the current state and, when relevant, what is happening: *Mac awake*, *Standby*, *Paused*,
*Disabled*, or *Timer expired*. The subtitle lists the working agents, the grace countdown or the
remaining run-limit time.

### Mode picker

`Off` · `Auto` · `Always` — see [Modes](modes.md).

### Agents

One row per detected agent pattern, aggregated across processes (`name ×N`), with a colored dot
(green = working, orange = waiting), the CPU percentage when non-trivial, and the state.

### Options

The four primary toggles:

| Option | What it does |
|---|---|
| **Keep display awake** | Also holds `PreventUserIdleDisplaySleep`, so the screen stays on (like `caffeinate -d`). |
| **Respect turn state** | Uses the busy/idle signals from integrations. This is what makes Ephedrine smarter than a plain keep-awake. |
| **AC power only** | Never asserts anything while on battery. |
| **Lid closed** | Disables lid-close sleep while an agent works (requires the one-time helper). |

### Collapsible sections

- **Monitored agents** — a checkbox grid of every built-in and custom pattern, plus
  **Other agents…** to add your own. Disabling a pattern stops Ephedrine from watching it.
- **Turn-state integrations** — install/remove the integration for each supported agent, and open
  the state folder for debugging. Shows the last reported state.
- **Advanced** — secondary options, intervals and maintenance actions:

    | Setting | Purpose |
    |---|---|
    | Simulate user activity | Declares user activity periodically so the screensaver/lock does not engage. |
    | Prevent system sleep (AC) | Adds the `PreventSystemSleep` assertion on AC power (like `caffeinate -s`). |
    | CPU activity only | Ignores turn states and classifies agents purely by CPU usage. |
    | Launch at login | Registers the app as a login item. |
    | Grace | Seconds the Mac stays awake after the last activity. |
    | Detection | How often processes, CPU and states are checked (1–10 s). |
    | User activity | Interval between user-activity declarations. |
    | Show power assertions… | Runs `pmset -g assertions` for inspection. |
    | Remove lid-close support… | Deletes the privileged helper and restores normal lid behaviour. |

### Footer

Version, **About** and **Quit**.
