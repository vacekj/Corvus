#!/bin/bash
# Build signal-call-tunnel from the vendored sources (release, --locked).
#
#   [CARGO_TARGET_DIR=...] signal-backend/call-tunnel/scripts/build.sh
#
# WebRTC is not compiled: ringrtc's build.rs runs third-party/ringrtc/bin/fetch-artifact, which downloads
# Signal's prebuilt static libwebrtc for this platform from build-artifacts.signal.org and checks it
# against the SHA-256 pinned in third-party/ringrtc/config/webrtc_artifact_checksums.json (see VENDOR.md).
# The archive and its extracted libraries go to $WEBRTC_OUTPUT_DIR (default: <target dir>/webrtc),
# never into the source tree. A verified archive already there is reused without network access.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
TARGET_DIR=${CARGO_TARGET_DIR:-$HERE/target}
export OUTPUT_DIR=${WEBRTC_OUTPUT_DIR:-$TARGET_DIR/webrtc}
mkdir -p "$OUTPUT_DIR"

# The target dir goes on the command line, not in the environment: cubeb-sys's build script runs a
# nested `cargo build` (cubeb-coreaudio-rs), which would inherit CARGO_TARGET_DIR and then wait
# forever for the lock the outer build holds on that directory.
env -u CARGO_TARGET_DIR cargo build --release --locked --manifest-path "$HERE/Cargo.toml" \
    --target-dir "$TARGET_DIR" "$@"
echo "$TARGET_DIR/release/signal-call-tunnel"
