# Lid-closed mode

Closing the lid always sleeps a MacBook unless it is in **clamshell mode** (external display +
power). No power assertion can prevent it; the only supported switch is
`pmset -a disablesleep 1`, which requires root.

Ephedrine can manage it for you: enable **Lid closed** in the popover and enter your admin password
once.

![Lid-closed option](popover.png)

## What gets installed

```
/usr/local/bin/ephedrine-display     root:wheel 0755   (on|off|status)
/etc/sudoers.d/ephedrine             root:wheel 0440   NOPASSWD for the helper only
```

From then on the app toggles `disablesleep` silently, and only while agents are working. It is
restored automatically when:

- work stops,
- the feature is turned off,
- the app quits,
- the app starts again after a crash or force quit.

The app also re-verifies the real system value periodically and after every wake, because macOS can
drop or ignore it across sleep/wake and power-source transitions.

## Removing it

**Advanced → Remove lid-close support…** deletes the helper and the sudoers rule (one admin prompt)
and restores normal lid-close sleep.

## Safety notes

!!! warning "Heat and battery"
    With `disablesleep` active the Mac really stays on with the lid closed. Watch out for heat in a
    bag and for battery drain. Enabling **AC power only** is recommended.

- The helper is owned by root and not writable by the user, so the NOPASSWD rule cannot be abused
  to run arbitrary code.
- The sudoers file is validated with `visudo -cf` before it is kept.
- Install/uninstall scripts are base64-encoded and piped straight into `bash` — no temporary files.
- Power assertions disappear automatically if the process dies, so a crash cannot leave the Mac
  awake indefinitely.

## The `disablesleep` setting itself

While this mode is engaged, the assertion name visible in `pmset -g assertions` is
`Ephedrine - …`, and the system flag is:

```bash
pmset -g | grep SleepDisabled      # prints "SleepDisabled 1" while working
```

If you get stuck with it enabled, reset it manually:

```bash
sudo pmset -a disablesleep 0
```
