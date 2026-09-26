# Modes

The mode picker at the top of the popover decides the overall behaviour. Internally the mode is
stored as `mode` = `off` | `auto` | `always`.

## `Auto` (default)

Keep the Mac awake **only while at least one monitored agent is working**, plus the
[grace period](#grace-period) after the last activity. When every agent is waiting (or no agent is
detected), the assertions are released and the Mac may sleep normally.

This is the recommended mode for coding agents: no mid-run sleep, no all-night wake.

## `Always`

Classic "Caffeine" behaviour: the Mac is kept awake unconditionally until you switch mode. Useful
when you want a manual keep-awake toggle.

### Run limit

In `Always` mode an optional **run limit** caps how long the Mac may stay awake (the
**Run limit** selector, shown only in `Always`). Options: *Unlimited* (default), *15 min*, *30 min*,
*1 hour*, *2 hours*, *4 hours*.

When the cap expires the assertions are released and the header shows **Timer expired** until you
change mode. The cap applies per session: switching mode restarts the countdown. The setting is
persisted (`maxDuration`, in seconds), so it survives restarts.

```bash
defaults write local.maurizio.Ephedrine maxDuration -float 3600   # 1 hour
```

## `Off`

Nothing is monitored and every assertion is released. Ephedrine stops scanning the process table
entirely, so it costs essentially nothing. Use it when you want the app installed but inactive.

## Grace period

Applies to `Auto` mode. After the last "working" observation the assertions stay engaged for the
**grace period** (default **120 s**). This covers LLM thinking time, tool restarts and brief gaps,
so the Mac does not fall asleep in the middle of a run.

```bash
defaults write local.maurizio.Ephedrine gracePeriod -float 300   # 5 minutes
```

The grace period is shown in the header as a countdown ("Grace: 42 s") while the icon shows the
hourglass.

## Decision summary

| Situation | Result in `Auto` |
|---|---|
| At least one agent working | Mac kept awake |
| No agent working, within grace | Mac kept awake (countdown) |
| No agent working, grace expired | Released — Mac may sleep |
| Mode `Off` | Released, no monitoring |
| On battery with **AC power only** on | Released, header shows *Paused* |
