#!/bin/sh
# Builds "Corvus.app" into macos/build/.
#   1. the Rust history store (static library, shared with the Qt app)
#   2. the Swift package (release)
#   3. the app bundle: executable, resources, Info.plist, icon, signal-cli helper, ad-hoc signature
set -eu

cd "$(dirname "$0")/.."
MACOS_DIR=$(pwd)
REPO_DIR=$(cd .. && pwd)

# The SwiftUI macros ship with Xcode, not with the Command Line Tools.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

VERSION=$(sed -n 's/^project(corvus VERSION \([0-9.]*\).*/\1/p' "$REPO_DIR/CMakeLists.txt")
VERSION=${VERSION:-0.0.0}
# The commit is compared with the release tags ("build-<sha>") by the app's update check.
COMMIT=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null || true)

# Code signature: ad hoc by default. With an ad-hoc signature every build is a "new" app for the
# keychain, so macOS asks again for the history key. Set CORVUS_SIGN_IDENTITY to a signing identity
# (e.g. from `security find-identity -v -p codesigning`) to keep "Always Allow" across rebuilds.
SIGN_ID=${CORVUS_SIGN_IDENTITY:--}

echo "==> Building Rust history store"
cargo build --release --locked --manifest-path "$REPO_DIR/history-store/Cargo.toml"

echo "==> Building Swift package"
swift build -c release --package-path "$MACOS_DIR"
BIN=$(swift build -c release --package-path "$MACOS_DIR" --show-bin-path)

APP="$MACOS_DIR/build/Corvus.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/corvus" "$APP/Contents/MacOS/"
# SwiftPM resource bundle (sound) and the emoji data shared with the Qt app.
cp -R "$BIN/CorvusMac_CorvusMac.bundle" "$APP/Contents/Resources/"
cp "$REPO_DIR/resources/emoji-catalog.json" "$REPO_DIR/resources/emoji-names.json" "$APP/Contents/Resources/"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@COMMIT@/$COMMIT/g" "$MACOS_DIR/Support/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Icon from the shared SVG (Quick Look renders SVG; sips/iconutil build the .icns).
ICONSET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$ICONSET"
if qlmanage -t -s 1024 -o "$(dirname "$ICONSET")" "$REPO_DIR/packaging/corvus.svg" >/dev/null 2>&1; then
    SRC="$(dirname "$ICONSET")/corvus.svg.png"
    for size in 16 32 128 256 512; do
        sips -z $size $size "$SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        sips -z $((size * 2)) $((size * 2)) "$SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" || echo "warning: icon could not be created"
else
    echo "warning: icon could not be rendered, the app uses the generic icon"
fi

# signal-cli runs through this helper app (src/SignalCliHelper.cpp, shared with the Qt app).
echo "==> Building signal-cli helper"
HELPER="$APP/Contents/Helpers/corvus-signal-cli.app"
mkdir -p "$HELPER/Contents/MacOS"
xcrun clang++ -std=c++17 -O2 -mmacosx-version-min=14.0 "$REPO_DIR/src/SignalCliHelper.cpp" \
    -o "$HELPER/Contents/MacOS/corvus-signal-cli"
sed "s/@PROJECT_VERSION@/$VERSION/g" "$REPO_DIR/packaging/macos/SignalCliHelper.plist.in" > "$HELPER/Contents/Info.plist"

# Signal Desktop history import (tools/signal-desktop-import).
echo "==> Building Signal Desktop import helper"
cargo build --release --locked --manifest-path "$REPO_DIR/tools/signal-desktop-import/Cargo.toml"
cp "$REPO_DIR/tools/signal-desktop-import/target/release/corvus-signal-import" "$APP/Contents/Helpers/"
codesign --force --sign "$SIGN_ID" --timestamp=none "$APP/Contents/Helpers/corvus-signal-import"

echo "==> Signing ($SIGN_ID)"
codesign --force --sign "$SIGN_ID" --timestamp=none "$HELPER"
codesign --force --sign "$SIGN_ID" --timestamp=none "$APP"

echo "Done: $APP"
