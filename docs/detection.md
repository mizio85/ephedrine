# Agent detection

Every **poll interval** (1–10 s, default **2 s**) Ephedrine scans the process table using read-only
syscalls and classifies each monitored agent as **working** or **waiting**. There are no
subprocesses and no special privileges; a full scan of a typical process table takes a few
milliseconds.

## Two-phase matching (case-insensitive)

1. **Name + executable path** — `proc_name()` (truncated to 15 characters) and `proc_pidpath()`.
   Long patterns are matched as substrings of the process name or of any path component.
2. **Command line** — for known wrapper interpreters (`node`, `bun`, `python3`, `npm`, …), the full
   argv is read via `KERN_PROCARGS2` and matched against every argument's basename. This is how
   agents shipped as Node/Bun/Python programs (the common case) are found even when the process
   name is just `node`.

Short patterns (4 characters or fewer, e.g. `amp`, `pi`) must match a **whole token**, to avoid
false positives such as `amp` inside `example`.

Utility processes whose command lines frequently contain these strings are ignored entirely:
`grep`, `rg`, `ps`, `awk`, `sed`, `vim`, `find`, `tail`, `cat`, … Any process whose path contains
`Ephedrine` (the app itself) is skipped.

## Built-in patterns

```
opencode  codex  claude  aider  gemini  cursor-agent
goose  amp  gptme  qwen  crush  droid  openhands
plandex  continue  copilot  windsurf  cody  pi
```

Each can be toggled off in **Monitored agents**.

## Custom agents

Add comma-separated patterns in **Monitored agents → Other agents…**. A process matches when its
name, path or command line contains a pattern (case-insensitive). The same short/long rule applies.

## CPU accounting

CPU usage per process comes from `proc_pid_rusage` deltas between two scans. The counters are
expressed in **mach timebase units** (not nanoseconds) on Apple Silicon, so they are converted with
`mach_timebase_info` — a classic bug that otherwise under-reports CPU by ~42×.

The first sample after a process appears has no previous value, so it is treated as unknown and
assumed to be working for one tick (to avoid a "waiting" flicker).

## Classification rules

In priority order:

| Situation | Classification |
|---|---|
| Session state `busy` | working |
| Session state `idle`, integration reports busy too | waiting (authoritative) |
| Session state `idle`, integration reports idle-only (Codex) | CPU ≥ 5 % ⇒ working, else waiting |
| No state, **Respect turn state** on | CPU ≥ 5 % ⇒ working, else waiting |
| No state, **CPU activity only** on | CPU ≥ 3 % ⇒ working, else waiting |
| No state, both off | process presence ⇒ always working |

The session state comes from the [integrations](integrations.md). The CPU fallback thresholds are
5 % (busy override) and 3 % (CPU-only mode), measured as a fraction of one core.

## Settings

```bash
# Detection interval in seconds (clamped to a minimum of 1)
defaults write local.maurizio.Ephedrine pollInterval -float 5

# Extra patterns
defaults write local.maurizio.Ephedrine customPatterns -array "my-agent" "llm-runner"
```
