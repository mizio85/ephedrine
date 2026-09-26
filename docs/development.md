# Development

## Build and run

```bash
swift build                 # debug build
swift build -c release      # release build
./.build/debug/Ephedrine --dump-agents    # inspect detection without the GUI
make app                    # build/Ephedrine.app
make dist                   # universal .app + release zip
```

## Project layout

```
Sources/Ephedrine/
  App.swift               CLI/GUI entry point (reporter, utilities, menu bar app)
  AppDelegate.swift       Monitor loop, decision logic, status item, popover actions
  MenuModel.swift         Observable view model for the popover
  MenuView.swift          SwiftUI popover UI
  AgentDetector.swift     Process scanning, pattern matching, CPU sampling
  SessionState.swift      Turn-state files (store, reader, reporter CLI, diagnostics)
  Integrations.swift      opencode / Claude / Codex / pi integration install & uninstall
  PowerManager.swift      IOKit power assertions + AC detection
  ClosedDisplayHelper.swift  Privileged helper for lid-close sleep (pmset disablesleep)
  Settings.swift          Typed UserDefaults access
  Localization.swift      Bundle.module lookup + L()/Lf() helpers
  Resources/<lang>.lproj/Localizable.strings
scripts/build-app.sh      Builds the .app bundle (Info.plist, ad-hoc signature)
```

## Data flow

```
agent (opencode/codex/claude/pi) ──hook/plugin──▶ Ephedrine --report ──▶ state/*.json
                                                                          │
   tick (2 s) ──▶ detect processes + read states ◀────────────────────────┘
               ──▶ classify (busy/idle/CPU) ──▶ power assertions (IOKit)
                                            └─▶ lid-close sleep (pmset)
```

The monitor loop runs one `tick()` every `pollInterval` seconds:

1. read settings,
2. read session-state files,
3. scan the process table and sample CPU,
4. classify each process as working/waiting,
5. decide whether to hold the assertions (mode, grace, AC-only),
6. engage/release assertions, toggle lid-close sleep, refresh icon and popover.

## Localization

Translations live in standard `.lproj/Localizable.strings` files:

```
Sources/Ephedrine/Resources/en.lproj/Localizable.strings   # base (English)
Sources/Ephedrine/Resources/it.lproj/Localizable.strings   # Italian
…
```

In code, use `L("key")` for plain strings and `Lf("key", args…)` for formatted ones. The helper
resolves the SwiftPM resource bundle at runtime; `scripts/build-app.sh` copies it into
`Ephedrine.app/Contents/Resources`.

To add a language:

1. copy `en.lproj/Localizable.strings` to a new `<lang>.lproj/` folder,
2. translate the values (keep the `%d` / `%@` placeholders),
3. add the code to `CFBundleLocalizations` in `scripts/build-app.sh`.
4. (optional) update the language list in `README.md` and this guide.

## Continuous integration

`.github/workflows/release.yml` builds a **universal** (arm64 + x86_64) `.app` on every `v*` tag,
uploads it as a run artifact and attaches the zip to the GitHub Release. Localization resources are
bundled automatically.

## Contributing

Issues and pull requests are welcome. The code and comments are in English; the UI is localized.
Please keep the `Localizable.strings` files in sync (same keys, same placeholders) when changing
user-facing strings.
