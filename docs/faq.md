# FAQ

**Does Ephedrine run a background service or daemon?**
No. It is a single menu bar (accessory) app. There is no helper daemon, no launch agent, and no
kernel extension. The only privileged component is the optional lid-closed helper, which is a tiny
shell script invoked through `sudo -n`.

**Does it need permissions or an account?**
No. It has no telemetry, makes no network calls, and requires no login. The lid-closed helper is
optional and installed with a single admin prompt.

**How is it different from Caffeine / Amphetamine?**
Those keep the Mac awake for as long as they are on. Ephedrine keeps it awake **only while an agent
is actually working**, using the agent's turn lifecycle, so it neither sleeps mid-run nor stays
awake while the agent waits for you.

**Will it keep my Mac awake all night?**
Not in `Auto` mode (the default): when every agent is waiting, the assertions are released after the
grace period. In `Always` mode you can set a run limit.

**How does it know an agent is "working" vs "waiting"?**
Through native integrations (opencode plugin, Claude Code hooks, Codex `notify`, pi extension) that
report turn start/end. Agents without an integration fall back to CPU usage. See
[Agent integrations](integrations.md).

**Does it work with several agents at once?**
Yes. One agent working is enough to keep the Mac awake; each pattern is tracked separately.

**Does it work on battery?**
Yes. Enable **AC power only** if you want it to stand down while unplugged.

**Which languages are supported?**
14: English (base), Italian, Spanish, French, German, Portuguese, Dutch, Polish, Russian, Turkish,
Chinese Simplified & Traditional, Japanese and Korean. The app follows the system language and falls
back to English.

**Is my data sent anywhere?**
No. All state is local files under `~/Library/Application Support/Ephedrine/`.

**Can I use it without any agent integration?**
Yes. It still detects processes and classifies them by CPU. Disable **Respect turn state** for the
classic "keep awake while the app is open" behaviour.

**What happens if the app crashes?**
Power assertions are owned by the process and disappear with it, so the Mac can always sleep. The
lid-closed flag is restored on the next launch.

**Is it free?**
Yes, MIT licensed.
