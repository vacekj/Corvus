# Corvus

Corvus is a desktop client for Signal with an encrypted local chat history. It runs on [corvus-cli](https://github.com/ada-h00k/corvus-cli) (recommended) or, optionally, on [signal-cli](https://github.com/AsamK/signal-cli). The Qt app runs on Linux, Windows and macOS; macOS also has a native SwiftUI app.

### Linux and Windows (Qt)

| Breeze Light | Breeze Dark |
|---|---|
| ![Corvus Qt in light theme](docs/screenshots/Corvus_BreezeLight.png) | ![Corvus Qt in dark theme](docs/screenshots/Corvus_BreezeDark.png) |

### macOS (Swift / SwiftUI)

| Light theme | Dark theme |
|---|---|
| ![Corvus for macOS in light theme](docs/screenshots/Corvus_macOS_Light.png) | ![Corvus for macOS in dark theme](docs/screenshots/Corvus_macOS_Dark.png) |

## Features

- Link Corvus to your Signal account with `corvus-cli` (recommended) or `signal-cli`.
- Read and send messages, including group chats, replies and reactions.
- Send and receive files, images, video and audio.
- Edit or delete messages, manage archived chats and disappearing messages.
- Desktop notifications, notification sounds and a tray/menu-bar icon.
- Encrypted local chat history, protected by the system keychain or a passphrase.
- View a contact's safety number (with QR code) and mark the contact as verified.
- Record and send voice messages (needs signal-cli 0.14.2 or newer, or corvus-cli, to arrive as a voice note).
- Send and receive Signal View Once photos and videos (select exactly one image or video and press **1×**; requires signal-cli 0.13.18 or newer, or corvus-cli).
- Forward messages and attachments to up to five chats at once (right-click a message → **Forward…**).
- Delivery and read receipts, text formatting (bold, italic, strikethrough, monospace, spoilers) and mentions, link previews.
- Group management (create, rename, members and admins, invite links, leave), blocking, and message requests.
- macOS (SwiftUI) only: stickers (send, receive, add packs from signal.art links), polls (create, vote, end), stories (view, reply, react, post), a per-chat media gallery and 1:1 voice calls.
- macOS (SwiftUI) only: import the history of Signal Desktop on the same Mac (File → Import from Signal Desktop …), including attachments. Messages Corvus already has are skipped, so the import can be repeated.
- Customisable chat colours and appearance.

Corvus is a graphical client; the connection to Signal is made by a separate backend program linked to your Signal account.

- **[corvus-cli](https://github.com/ada-h00k/corvus-cli) (recommended)** is a single native executable written in Rust (built on [presage](https://github.com/whisperfish/presage)). It needs no Java. The Flatpak and the Windows setup include it, so there is nothing else to install there.
- **[signal-cli](https://github.com/AsamK/signal-cli) (optional alternative)** is the Java original. Corvus works with it as well; install it yourself and select it under **Settings → Advanced → Choose …** if you prefer it or already use it.

Both speak the same JSON-RPC interface, but each has its own device link and its own account data: switching the backend means linking the computer with your phone again (the chat history in Corvus is kept).

### Voice calls (macOS)

signal-cli relays call audio through [signal-call-tunnel](https://github.com/visigoth/signal-call-tunnel) and two virtual audio devices. Corvus bridges them to your microphone and speakers. To enable calls:

```sh
git clone --recurse-submodules https://github.com/visigoth/signal-call-tunnel.git
cargo install --path signal-call-tunnel/signal-call-tunnel
cd signal-call-tunnel/third-party/ringrtc
sudo bin/virtual_audio.sh --setup --input-source signal_input --output-sink signal_output
```

Corvus finds the tunnel in `~/.cargo/bin` or on `PATH`. Then choose File → Reconnect.

Video calls and history transfer from a phone are not supported: signal-cli does not implement them. To get older history, link Signal Desktop (which can transfer it from the phone) and then use the Signal Desktop import.

### Signal Desktop import (macOS)

The import reads Signal Desktop's database with its key from the "Signal Safe Storage" keychain item (macOS asks once; choose *Always Allow*). Signal Desktop's data is not changed. Attachments are copied still encrypted with their Signal Desktop keys into `imported-attachments/` in the Corvus data folder and are decrypted only when shown. A count-only `import-report.json` (messages per chat, no content) is written for checking the result. Disappearing-timer notices are not imported; shared contact cards become text messages.

Builds signed ad hoc look like a new app to the keychain after every rebuild. Set `CORVUS_SIGN_IDENTITY` to your signing identity when running `macos/scripts/build-app.sh` to keep keychain approvals across rebuilds.

## Install

Download the appropriate package from the [latest GitHub release](https://github.com/ada-h00k/Corvus/releases/latest).

### Linux (Qt, x86_64)

1. Download `corvus-linux-x86_64-installer.tar.gz` from the release.
2. Extract it and run the installer:

   ```sh
   tar -xzf corvus-linux-x86_64-installer.tar.gz
   ./install.sh
   ```

The installer is per-user, does not need `sudo`, and adds Corvus to your application menu. Run it again to update; run `./install.sh --uninstall` to remove it.

The prebuilt executable is dynamically linked and does not include Qt libraries. You need a compatible Qt 6 runtime (the release is built with Qt 6.12), QtKeychain 0.14 or newer, and a desktop keyring such as GNOME Keyring or KWallet. Install a backend separately and make sure it is available on your `PATH`: download `corvus-cli-linux-x86_64` from the [corvus-cli releases](https://github.com/ada-h00k/corvus-cli/releases/latest), rename it to `corvus-cli` and make it executable (`chmod +x`); or use `signal-cli` as the alternative.

**Arch Linux:** download the `corvus-*.pkg.tar.zst` package from the release and install it with:

```sh
sudo pacman -U ./corvus-*.pkg.tar.zst
```

Install a backend separately: `corvus-cli` from the [corvus-cli releases](https://github.com/ada-h00k/corvus-cli/releases/latest) (see above), or `signal-cli` as the alternative, for example from the AUR.

**Flatpak (x86_64):** download `corvus-linux-x86_64.flatpak` from the release and install it with:

```sh
flatpak install --user ./corvus-linux-x86_64.flatpak
flatpak run io.github.ada_h00k.Corvus
```

To get updates automatically, add the signed Flatpak repository instead (it is published to GitHub Pages together with every build) and update with `flatpak update`:

```sh
flatpak remote-add --user --if-not-exists corvus https://ada-h00k.github.io/Corvus/corvus.flatpakrepo
flatpak install --user corvus io.github.ada_h00k.Corvus
```

The Flatpak includes [`corvus-cli`](https://github.com/ada-h00k/corvus-cli) (the Signal backend that replaces `signal-cli`, no Java needed) and `qrencode`, so nothing else has to be installed. It runs in a sandbox with these permissions only: network, Wayland/X11, audio, GPU (video player), notifications, tray icon and the Secret Service (history key). It has **no** file system access; attachments are chosen and saved through the file chooser portal. Because of the sandbox, the Flatpak keeps its own data in `~/.var/app/io.github.ada_h00k.Corvus/` and does not see an existing `signal-cli` installation or chat history. `corvus-cli` has its own device link as well: link it to your Signal account as a new device on first start.

### Windows (Qt, x86_64)

1. Download and run `corvus-windows-x64-setup.exe` from the release.
2. Follow the setup wizard. It installs the Qt runtime, `qrencode` (used to show the QR code when linking a device) and [`corvus-cli`](https://github.com/ada-h00k/corvus-cli) with Corvus. `corvus-cli` is the Signal backend that replaces `signal-cli`; there is no Java and nothing to download.
3. On first start, Corvus finds `corvus-cli` by itself and offers to link the computer with your phone as a new device. If you want to keep using an existing `signal-cli`, select it under **Settings → Advanced → Choose …**.

The installer is for Windows 10 or newer. It does not require administrator rights for a per-user installation. The setup is not code-signed, so Windows SmartScreen may show a warning.

**Portable version:** download `corvus-windows-x64-portable.zip`, extract it, and run `corvus.exe` (`qrencode.exe` and `corvus-cli` are included).

### macOS (recommended: Homebrew)

Corvus has two macOS versions. Install the one you prefer:

- **Swift / SwiftUI** — native macOS interface; requires macOS 14 or newer.
- **Qt** — the same cross-platform interface used on Linux and Windows.

First add the Corvus tap and install **corvus-cli**, the recommended Signal backend. The Homebrew cask downloads the latest Apple-silicon binary and makes it available as `corvus-cli` on your `PATH`. You do not need Java or a separate manual download.

```sh
brew tap ada-h00k/corvus
brew install --cask corvus-cli
```

Then install **one** version of Corvus:

```sh
brew install --cask corvus-swift
```

Or, for the Qt version:

```sh
brew install --cask corvus-qt
```

You can also download `corvus-macos-arm64.zip` (Swift) or `corvus-qt-macos-arm64.zip` (Qt) from the [latest release](https://github.com/ada-h00k/Corvus/releases/latest). Prebuilt macOS releases are for Apple silicon (arm64).

The release apps are ad-hoc signed rather than notarised. Depending on your macOS security settings, the first launch may require opening the app from Finder using **right-click → Open**. Only bypass a warning if you trust the source of the app.

The Swift version keeps its history in its own database. On its first start it takes over an existing history of the Qt version; from then on the two histories are separate.

## First launch

Corvus starts `corvus-cli` or `signal-cli` as a separate program. On a first start it looks for the bundled `corvus-cli` (Windows), then for `corvus-cli` and then `signal-cli` on your `PATH`; an executable you chose is always kept. If it cannot find one, open **Settings → Advanced → Choose …** and select the executable. Follow Corvus's account-linking prompt if you have not linked this installation to Signal yet.

The Windows builds and the Flatpak include `corvus-cli`. On Linux, get it from the [corvus-cli releases](https://github.com/ada-h00k/corvus-cli/releases/latest); for the `signal-cli` alternative use your distribution's package instructions or the [official signal-cli releases](https://github.com/AsamK/signal-cli/releases). On macOS, install the recommended `corvus-cli` backend with `brew install --cask corvus-cli` as shown above. You can still use `signal-cli` as an alternative: install it separately and select it under **Settings → Advanced → Choose …**.

**Updates of the backend:** **Help → Check for backend update** (also in Settings → Advanced) checks the backend you use: `signal-cli` is compared by version number, `corvus-cli` by build (it reports its commit in `--version`, and the latest [corvus-cli release](https://github.com/ada-h00k/corvus-cli/releases/latest) is compared with it). The Flatpak and the Windows setup bring a new `corvus-cli` with the next Corvus update.

**macOS: prefer the Java build of signal-cli.** The native (GraalVM) build that Homebrew installs for 0.14.9 can crash shortly after start (a `StackOverflowError` while reporting a contact-discovery error from libsignal, exit code 134). Corvus then shows itself as disconnected and the composer stays disabled. Corvus reconnects automatically (after 3, 10, 30 and 60 seconds), but if the crash repeats, download the Java release from the [signal-cli releases](https://github.com/AsamK/signal-cli/releases), install a Java runtime (`brew install openjdk`) and point **Settings → Path to signal-cli** at its `bin/signal-cli`.

**Startup (macOS):** Corvus starts signal-cli while it unlocks the history, skips the extra `--version` / `listAccounts` runs when nothing changed, reads profile pictures from signal-cli's files and shows the names from the previous run (kept encrypted with the history key in `roster-cache.bin`) until signal-cli answers. For the Java build it keeps a JVM class-data-sharing archive (about 40 MB) in `~/Library/Caches/io.github.corvus.mac`; delete it any time, or set `CORVUS_NO_CDS=1` to turn this off.

## Local data and encryption

Corvus stores its chat history in an encrypted `history.corvus` file (the macOS SwiftUI app: an encrypted `history.db` database). By default, the history key is stored in your operating system's keychain; you can switch to passphrase protection in **Settings → History protection**.

- Linux: `~/.local/share/corvus/corvus/`
- macOS: `~/Library/Application Support/corvus/corvus/`
- Windows: `%APPDATA%\corvus`

`corvus-cli` keeps its own account data in `~/.local/share/corvus-cli/` (Windows: `%USERPROFILE%\.local\share\corvus-cli`; in the Flatpak below `~/.var/app/io.github.ada_h00k.Corvus/data/corvus-cli/`).

**Upgrading from Wren:** Corvus was called Wren before (and signal-cli Qt before that). On first start it moves the existing chat history, settings and keychain entries (history key, GIPHY API key) over automatically; nothing is deleted. If the old version is still running, close it first. The Linux installer and the Arch package replace an existing Wren installation; on macOS you can delete the old `Wren.app`, and macOS may ask once for permission to read the old keychain entries.

**Important:** Corvus's encryption protects its local chat history. It does not encrypt the account data of `signal-cli` or `corvus-cli`, sessions, contacts or attachments. Protect your home directory or disk with your operating system's disk-encryption feature. A forgotten history passphrase cannot be recovered.

## Build from source

The Qt app requires a C++17 compiler, CMake 3.16 or newer, Qt 6 (Widgets, Network, Multimedia, MultimediaWidgets and Svg), QtKeychain 0.14 or newer, and Rust with Cargo.

On Debian/Ubuntu, install the build dependencies and compile:

```sh
sudo apt update
sudo apt install build-essential cmake ninja-build qt6-base-dev qt6-multimedia-dev qt6-svg-dev qtkeychain-qt6-dev cargo rustc

cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
./build/corvus
```

For the native Swift app, install Xcode and Rust, then run:

```sh
cd macos
./scripts/build-app.sh
open build/Corvus.app
```

The Swift app requires macOS 14 or newer. See [`macos/README.md`](macos/README.md) for Swift-specific development notes.

## License

Corvus is licensed under the [GNU Affero General Public License v3.0](LICENSE). `corvus-cli` and `signal-cli` are separate projects and are distributed under their own licenses (`corvus-cli`: AGPL-3.0, `signal-cli`: GPL-3.0).
