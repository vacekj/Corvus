#!/bin/bash
# Re-create the vendored signal-call-tunnel tree (this directory) from the pinned upstream commits.
#
#   signal-backend/call-tunnel/scripts/vendor.sh
#
# Replaces Cargo.toml, Cargo.lock, src/ and third-party/ringrtc/ in this directory with fresh copies
# from upstream, then applies the Corvus patches in patches/. Run it to bump the pins (edit the
# variables below) or to check that the vendored tree has not drifted (`git diff` should be empty
# afterwards). Needs git and network access to github.com; nothing is built.
set -euo pipefail

TUNNEL_REPO=https://github.com/visigoth/signal-call-tunnel.git
TUNNEL_REV=02c84e9bfbb45e6872956ac2168adcc0b1e7a8ba   # main, 2026-03-18 "Fail audio test when BlackHole loopback is broken"
RINGRTC_REPO=https://github.com/signalapp/ringrtc.git
RINGRTC_REV=a86f8a6832cec291ef4f77e4ee9b941e5b91a01f  # v2.65.1 (the tunnel's submodule pin), WebRTC 7444f

HERE=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fetch() { # repo rev dir
    git init -q "$3"
    git -C "$3" fetch -q --depth 1 "$1" "$2"
    git -C "$3" checkout -q FETCH_HEAD
}

fetch "$TUNNEL_REPO" "$TUNNEL_REV" "$WORK/tunnel"
fetch "$RINGRTC_REPO" "$RINGRTC_REV" "$WORK/ringrtc"

# Tunnel crate. build.rs is dropped: it only ran `git apply` on the ringrtc submodule, and the vendored
# ringrtc below already has that patch applied.
rm -rf "$HERE/src" "$HERE/third-party"
cp "$WORK/tunnel/signal-call-tunnel/Cargo.toml" "$WORK/tunnel/signal-call-tunnel/Cargo.lock" "$HERE/"
cp -R "$WORK/tunnel/signal-call-tunnel/src" "$HERE/src"
cp "$WORK/tunnel/docs/CALL_TUNNEL_IMPL.md" "$HERE/UPSTREAM-CALL_TUNNEL_IMPL.md"

# RingRTC: the Cargo workspace (all members, so its manifest stays unmodified), the WebRTC prebuilt
# fetcher with its pinned checksums, and the BlackHole setup script. Platform bindings for
# Android/iOS/Node, Gradle and CocoaPods files and acknowledgments are left out.
R="$HERE/third-party/ringrtc"
mkdir -p "$R/bin" "$R/src"
cp "$WORK/ringrtc/Cargo.toml" "$WORK/ringrtc/Cargo.lock" "$WORK/ringrtc/LICENSE" "$WORK/ringrtc/README.md" \
   "$WORK/ringrtc/rust-toolchain" "$R/"
cp -R "$WORK/ringrtc/config" "$WORK/ringrtc/call_sim" "$WORK/ringrtc/mrp" "$WORK/ringrtc/protobuf" \
      "$WORK/ringrtc/webrtc-sys" "$R/"
cp -R "$WORK/ringrtc/src/rust" "$R/src/rust"
cp "$WORK/ringrtc/bin/env.sh" "$WORK/ringrtc/bin/fetch-artifact" "$WORK/ringrtc/bin/fetch-artifact.py" \
   "$WORK/ringrtc/bin/virtual_audio.sh" "$R/bin/"

# Corvus patches, in order.
(cd "$R" && patch -s -p1 < "$HERE/patches/ringrtc-disable-vpio.patch")
(cd "$HERE" && patch -s -p1 < "$HERE/patches/tunnel-vendored-layout.patch")
(cd "$HERE" && patch -s -p1 < "$HERE/patches/tunnel-signaling-device-ids.patch")

echo "vendored signal-call-tunnel $TUNNEL_REV with ringrtc $RINGRTC_REV into $HERE"
