#!/bin/bash
# Debug build in hidden test mode against tests/mock-signal-cli.py: no Dock or menu bar icon, never the active
# app, invisible window, private clipboard, its own data and no keychain. Drive it by appending debug commands
# (Sources/CorvusMac/DebugHooks.swift) to $DIR/cmds, inject envelopes via $DIR/inject, check with `snapshot`.
#   scripts/run-hidden.sh [DIR]      (default: a new temporary directory; prints it)
set -euo pipefail
cd "$(dirname "$0")/.."
DIR=${1:-$(mktemp -d -t corvus-hidden)}
mkdir -p "$DIR/data/signal"; : > "$DIR/cmds"; : > "$DIR/inject"
swift build -q
CORVUS_HIDDEN=1 CORVUS_DATA_DIR="$DIR/data" SIGNAL_CLI_MAC_TEST_PASSPHRASE=test-pass \
  CORVUS_SIGNAL_BIN="$PWD/../tests/mock-signal-cli.py" SIGNAL_CLI_MAC_DEBUG_COMMANDS="$DIR/cmds" \
  MOCK_INJECT="$DIR/inject" MOCK_LOG="$DIR/mock.log" nohup .build/debug/corvus > "$DIR/app.log" 2>&1 &
echo "$DIR (pid $!)"
