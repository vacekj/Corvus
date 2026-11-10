#!/bin/sh
# Builds "Corvus.app" into macos/build/.
#   1. the Rust library: the Signal backend, the history key wrapping and SQLCipher (../signal-backend, corvus-core)
#   2. the voice call tunnel (signal-call-tunnel)
#   3. the Swift package (release)
#   4. the app bundle: executable, backend, resources, Info.plist, icon, ad-hoc signature
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

BACKEND_MANIFEST="$REPO_DIR/signal-backend/Cargo.toml"
if [ ! -f "$BACKEND_MANIFEST" ]; then
    echo "error: $BACKEND_MANIFEST not found." >&2
    echo "       Corvus needs its Signal backend from signal-backend/ to build the app." >&2
    exit 1
fi

echo "==> Building the Rust library (Signal backend, history key wrapping, SQLCipher)"
# One static library, linked into the app by the Swift package (Package.swift).
cargo build --release --locked --manifest-path "$BACKEND_MANIFEST" -p corvus-core
CORE_LIB="${CARGO_TARGET_DIR:-$REPO_DIR/signal-backend/target}/release/libcorvus_core.a"
if [ ! -f "$CORE_LIB" ]; then
    echo "error: $CORE_LIB was not built." >&2
    exit 1
fi

echo "==> Building signal-call-tunnel (voice calls)"
# Its own workspace (RingRTC + Signal's prebuilt, checksum-pinned WebRTC); see call-tunnel/scripts/build.sh.
TUNNEL_TARGET="${CARGO_TARGET_DIR:-$REPO_DIR/signal-backend/target}/call-tunnel"
TUNNEL_BIN=$(CARGO_TARGET_DIR="$TUNNEL_TARGET" "$REPO_DIR/signal-backend/call-tunnel/scripts/build.sh" | tail -1)

echo "==> Building Swift package"
swift build -c release --package-path "$MACOS_DIR"
BIN=$(swift build -c release --package-path "$MACOS_DIR" --show-bin-path)

APP="$MACOS_DIR/build/Corvus.app"
echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN/corvus" "$APP/Contents/MacOS/"
# The backend (inside the app's executable) starts one tunnel per call from the executable's directory.
cp "$TUNNEL_BIN" "$APP/Contents/MacOS/signal-call-tunnel"
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

# Signal Desktop history import (tools/signal-desktop-import).
echo "==> Building Signal Desktop import helper"
cargo build --release --locked --manifest-path "$REPO_DIR/tools/signal-desktop-import/Cargo.toml"
cp "$REPO_DIR/tools/signal-desktop-import/target/release/corvus-signal-import" "$APP/Contents/Helpers/"
codesign --force --sign "$SIGN_ID" --timestamp=none "$APP/Contents/Helpers/corvus-signal-import"

echo "==> Signing ($SIGN_ID)"
codesign --force --options runtime --sign "$SIGN_ID" --timestamp=none "$APP/Contents/MacOS/signal-call-tunnel"
codesign --force --sign "$SIGN_ID" --timestamp=none "$APP"

echo "Done: $APP"
