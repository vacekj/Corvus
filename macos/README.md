# Corvus

| Light | Dark |
| --- | --- |
| ![Light](../docs/screenshots/corvus_macOS_Light.png) | ![Dark](../docs/screenshots/corvus_macOS_Dark.png) |

This directory contains a native macOS version of Corvus, written in Swift / SwiftUI (macOS 14 or newer). It has the
same features and talks the same JSON-RPC protocol, but to its own bundled Signal backend, `corvus-signal`
(`../signal-backend`, built on presage), instead of signal-cli.

The chat history is an encrypted SQLite database (SQLCipher), `history.db`: one row per message
(`Sources/CorvusCore/HistoryDB.swift`). It is read in one pass at startup; afterwards only what changes is
written, and a deleted or expired message is one deleted row. With keychain protection the database key is
derived from the keychain entry (the same entry as before); with a passphrase it is a random key wrapped under
the passphrase (Argon2id) in `history.key`. A `history.corvus` file of an earlier version or of the Qt app is
moved into the database on the first start and kept as `history.corvus.bak` for 14 days. The Qt app does not
read the database: the two no longer share a history.

| Part | Job |
|------|-----|
| `Sources/CorvusCore` | UI-free logic: backend process / JSON-RPC, envelope parsing, history records, chat model, keychain |
| `Sources/CorvusMac` | SwiftUI app: window, chat view, composer, settings, notifications, menu bar icon |
| `Sources/CHistoryStore` | module map for `history-store/include/history_store.h` (reading a `history.corvus` file, wrapping the database key) |
| `Sources/CSQLCipher` | the SQLCipher amalgamation (SQLite 3.50.4, SQLCipher 4.10.0, on CommonCrypto) |

Requirements: Xcode (its toolchain provides the SwiftUI macros; the Command Line Tools alone are not
enough) and Rust with cargo.

```sh
scripts/build-app.sh            # Rust store + corvus-signal + Swift release build -> build/Corvus.app
open "build/Corvus.app"
swift test                      # unit tests (envelopes, records, Rust store round trip, mock backend)
```

The backend runs as `Contents/MacOS/corvus-signal --config ~/Library/Application Support/corvus/signal
--store-key-stdin …`; the key of its encrypted store is kept in the login keychain (service `corvus-signal`) and
written as the first line of its stdin. `CORVUS_SIGNAL_BIN` points a `swift run` build at another binary. On first
use, attachments and avatars of a former signal-cli installation (`~/.local/share/signal-cli`) are copied into the
new data directory so the media of the existing history keeps working; the old directory is left as it is.

If `xcode-select` points to the Command Line Tools, the script uses `/Applications/Xcode.app`
automatically; for `swift build`/`swift test` set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

Differences from the Qt app:

- The tray icon is a menu bar icon with the unread count, and the Dock icon shows a badge.
- Notifications use the macOS notification centre. One notification per chat; clicking it opens the chat.
- Settings live in the standard Settings window (⌘,).
- The QR code for linking is drawn by the app itself, so `qrencode` is not needed.
- The composer is multi-line: Return sends, Shift+Return or Option+Return starts a new line.
- Outgoing messages show one bare check when sent, two muted checks when delivered, and two brighter checks when read.
  Hover over the checks for the localized read date and time. Group chats list each known recipient's state and read
  time, with delivered/read totals. New group sends retain their audience for totals after a restart; older messages
  without that audience show recorded receipts only. Missing read timestamps are shown as unavailable.
- Clicking an attachment follows fixed rules (`Sources/CorvusCore/AttachmentPolicy.swift`). File name *and* content type
  are checked, and the stricter result wins:
  - images, audio and video are shown or played inside the app
  - files that can run code (`.sh`, `.command`, `.terminal`, `.app`, `.pkg`, scripts, files without an extension, …)
    are never opened, only saved
  - everything else is opened in the default app only after a confirmation dialog

  Every file Corvus writes from an attachment is marked as downloaded (quarantine), so Gatekeeper checks it before it runs.
  The app quarantines all files it creates (`LSFileQuarantineEnabled`); the backend inherits that for the attachments
  it writes.
- The history is stored in `~/Library/Application Support/corvus/corvus/` (`history.db`).

The release workflow (`.github/workflows/release.yml`) builds and tests the app and attaches
`corvus-macos-arm64.zip` (Apple silicon) to every release. It is signed ad hoc only, so on
first launch open it with right-click → *Open*.

`CORVUS_BENCH=1 swift test -c release -Xswiftc -enable-testing --filter 'PerfBench|testBenchLoadAndSync'` measures
loading and saving a synthetic history of 90,000 messages (database and former history file).

Debug builds (`swift build`) accept `SIGNAL_CLI_MAC_TEST_PASSPHRASE` and `SIGNAL_CLI_MAC_DEBUG_COMMANDS`
for unattended runs against `tests/mock-signal-cli.py` (see `Sources/CorvusMac/DebugHooks.swift`).
