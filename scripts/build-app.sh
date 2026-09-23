#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Ephedrine"
BUNDLE_ID="local.maurizio.Ephedrine"
VERSION="${VERSION:-1.0.0}"
CONFIG="${CONFIG:-release}"
# Optional space-separated architectures for a universal build, e.g. ARCHS="arm64 x86_64".
ARCHS="${ARCHS:-}"

# Builds the executable and prints its path on stdout (build logs go to stderr).
#
# With several architectures each one is built separately and merged with `lipo`: SwiftPM's own
# universal build routes through xcodebuild, which fails on older toolchains (e.g. Xcode 16.4 /
# Swift 6.1) with `SWIFT_VERSION '' is unsupported` when the target uses `.swiftLanguageMode(.v5)`.
build_binary() {
    if [ -z "$ARCHS" ]; then
        swift build -c "$CONFIG" --product "$APP_NAME" >&2
        echo "$(swift build -c "$CONFIG" --show-bin-path)/$APP_NAME"
        return
    fi

    if [ "$(echo $ARCHS | wc -w | tr -d ' ')" -eq 1 ]; then
        swift build -c "$CONFIG" --arch "$ARCHS" --product "$APP_NAME" >&2
        echo "$(swift build -c "$CONFIG" --arch "$ARCHS" --show-bin-path)/$APP_NAME"
        return
    fi

    local staging="build/.lipo"
    rm -rf "$staging"
    mkdir -p "$staging"
    local slices=()
    for arch in $ARCHS; do
        swift build -c "$CONFIG" --arch "$arch" --product "$APP_NAME" >&2
        local dir
        dir="$(swift build -c "$CONFIG" --arch "$arch" --show-bin-path)"
        cp "$dir/$APP_NAME" "$staging/$APP_NAME-$arch"
        slices+=("$staging/$APP_NAME-$arch")
    done
    lipo -create "${slices[@]}" -output "$staging/$APP_NAME-universal"
    echo "$staging/$APP_NAME-universal"
}

BIN="$(build_binary)"

APP_DIR="build/$APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN" "$APP_DIR/Contents/MacOS/$APP_NAME"

# Localization: SwiftPM packages the .lproj files into a resource bundle next to the binary;
# copy it into the app so `L10n.bundle` resolves at runtime.
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
for resource_bundle in "$BIN_DIR/${APP_NAME}_"*.bundle; do
    [ -d "$resource_bundle" ] || continue
    cp -R "$resource_bundle" "$APP_DIR/Contents/Resources/"
done

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>it</string>
    </array>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticTermination</key>
    <false/>
    <key>NSSupportsSuddenTermination</key>
    <false/>
</dict>
</plist>
PLIST

if codesign --force --sign - "$APP_DIR" >/dev/null 2>&1; then
    echo "Firmato ad-hoc: $APP_DIR"
else
    echo "Avviso: firma ad-hoc non riuscita (l'app funziona comunque)"
fi

echo "Costruito: $APP_DIR"
