//
//  Localization.swift
//  Ephedrine
//
//  Thin wrapper around the SwiftPM resource bundle so the UI can be localized.
//
//  The `.lproj/Localizable.strings` files live in `Resources/` and are processed into
//  `Ephedrine_Ephedrine.bundle`. `scripts/build-app.sh` copies that bundle into
//  `Ephedrine.app/Contents/Resources` so it resolves at runtime; when running the raw binary
//  SwiftPM keeps the bundle next to the executable.
//
//  `L("key")` returns a plain localized string, `Lf("key", args…)` formats it.
//  The base localization is English; unsupported system languages fall back to it.
//

import Foundation

enum L10n {
    /// The bundle holding the compiled `.lproj` resources. Falls back to `.main` (which returns
    /// the keys untranslated) instead of the `Bundle.module` fatal error if it is ever missing.
    static let bundle: Bundle = {
        let name = "Ephedrine_Ephedrine.bundle"
        let candidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle(for: BundleToken.self).resourceURL,
        ]
        for case let url? in candidates {
            if let bundle = Bundle(url: url.appendingPathComponent(name)) {
                return bundle
            }
        }
        return .main
    }()

    static func t(_ key: String) -> String {
        NSLocalizedString(key, bundle: bundle, comment: "")
    }

    static func f(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), arguments: arguments)
    }
}

private final class BundleToken {}

/// Localized string without arguments.
func L(_ key: String) -> String { L10n.t(key) }

/// Localized format string, e.g. `Lf("header.working", count)`.
func Lf(_ key: String, _ arguments: CVarArg...) -> String { L10n.f(key, arguments) }
