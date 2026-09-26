# Troubleshooting

## The Mac still sleeps while an agent is working

The Mac stays awake only while Ephedrine holds an assertion, so two things matter:

1. **The system sleep timer** — `pmset -g custom | grep sleep`. Values are in minutes; `sleep 1`
   means the Mac sleeps **one minute** after any release. If your timer is that aggressive, consider
   `sudo pmset -a sleep 10`, or raise the [grace period](modes.md#grace-period).
2. **The turn-state signal** — run `Ephedrine --dump-agents` while the agent is working; its process
   should report `state=busy`. State files survive helper restarts and dead pids (agent-level
   fallback, up to 30 minutes), so a long network-bound inference is not mistaken for idleness when
   an integration is installed.

## The icon never changes

Check that the agent actually reports state: `Ephedrine --dump-agents` shows a `state=` column.
`-` means "no integration" and the CPU fallback applies — an idle agent at ~0 % CPU keeps nothing
awake, by design.

Also check the agent is enabled in **Monitored agents** and that the mode is not `Off`.

## An agent is not detected at all

- Open **Monitored agents** and confirm the pattern is enabled.
- Add a custom pattern in **Other agents…** (comma separated).
- Some agents run behind a wrapper (`node`, `bun`, …): Ephedrine reads the command line for those,
  but you can help it by matching a distinctive token, e.g. `cursor-agent`.

## The Mac still sleeps with the lid closed

Lid-closed mode must be enabled and the helper installed. Verify:

```bash
pmset -g | grep SleepDisabled                          # 1 while working
pmset -g assertions | grep Ephedrine
```

Closing the lid also always sleeps unless the helper is active — a power assertion alone cannot
prevent it.

## A stale `disablesleep 1`

```bash
sudo pmset -a disablesleep 0
```

Or remove and reinstall the support from the popover; the app also repairs this automatically at
launch.

## Integrations stopped working after moving the app

Reinstall them: the hook/plugin contains the absolute path of the binary. Use the popover or the
[CLI](cli.md).

## "Ephedrine is damaged and can't be opened"

That is Gatekeeper on a not-notarized app. See
[Installation → First launch](installation.md#first-launch-and-gatekeeper).

## Inspect what the app holds

```bash
pmset -g assertions | grep -A2 Ephedrine
ls ~/Library/Application\ Support/Ephedrine/state/
```
