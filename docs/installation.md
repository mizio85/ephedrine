# Installation

## Requirements

- macOS **14 (Sonoma)** or later — Apple Silicon or Intel.
- Optional: an agent with a supported integration (opencode / Claude Code / Codex / pi).
- To build from source: Xcode Command Line Tools (Swift 5.9+, developed with Swift 6.x).

## Download a prebuilt build

Prebuilt **universal** binaries (Apple Silicon + Intel) are published on the
[Releases page](https://github.com/mizio85/ephedrine/releases).

1. Download `Ephedrine-<version>.zip`, unzip it and drag `Ephedrine.app` into `/Applications`.
2. Open it once (see the Gatekeeper note below).

### First launch and Gatekeeper

The app is **ad-hoc signed and not notarized**, so macOS blocks it with *"Ephedrine is damaged and
can't be opened"* or *"cannot verify the developer"*. Open it once with either:

- **Terminal (recommended):**

    ```bash
    xattr -dr com.apple.quarantine /Applications/Ephedrine.app
    ```

- **Finder:** right-click `Ephedrine.app` → **Open** → **Open**, or go to
  System Settings → **Privacy & Security** → **Open Anyway**.

After the first launch it starts normally.

!!! info "Why the warning?"
    Smooth, warning-free distribution requires a paid Apple Developer account with a *Developer ID
    Application* certificate plus notarization. Until then the build stays ad-hoc and the
    workaround above is needed.

## Build from source

```bash
git clone https://github.com/mizio85/ephedrine
cd ephedrine

make app        # builds build/Ephedrine.app (release, ad-hoc signed)
make run        # builds and launches it
make install    # copies the app to /Applications and launches it
```

Manual equivalent:

```bash
swift build -c release
CONFIG=release ./scripts/build-app.sh   # wraps the binary into Ephedrine.app + Info.plist
open build/Ephedrine.app
```

A universal (arm64 + x86_64) build plus a release zip:

```bash
make dist       # build/Ephedrine.app + build/Ephedrine-<version>.zip
```

## Start at login

Ephedrine is a menu bar accessory: after launching you will find the **cup icon** in the status bar.
To start it automatically, enable **Launch at login** in the popover. This uses the system login item
and requires the app to live in `/Applications`.

![Ephedrine expanded panels](panels.png)

!!! tip "Moving the app"
    The absolute path of the binary is embedded in every generated integration. If you move the app
    (for example from `build/` to `/Applications`), **reinstall the integrations** from the popover.
