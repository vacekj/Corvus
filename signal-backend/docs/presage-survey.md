# presage feasibility and gap survey for Corvus (replacing signal-cli)

Date: 2026-11-09. Nothing was linked or registered, and no Signal server was contacted. The build used only crates.io and GitHub.

## 1. Versions surveyed

| Component | Pin |
|---|---|
| presage | `main` @ `4b81740610c301cbd54d95f4dbd4cadd692af95e` (2026-11-05, "Bump libsignal-service-rs (#496)"), crate version 0.8.0-dev, AGPL-3.0-only |
| libsignal-service-rs | git rev `7a7526741dfd9ad4c4894717f22651eb0506fb7e` (2026-11-05, also current `main`) |
| libsignal (signalapp) | tag `v0.99.0` = `439f035d9cfd7efe5435cbea0294591c9ed17232` (libsignal-protocol, -core, -account-keys, zkgroup, usernames, signal-crypto, libsignal-net/-net-infra with `cdsi`) |
| boring (cdsi only) | signalapp/boring tag `signal-v5.0.2` |
| libsqlite3-sys | patched to whisperfish/rusqlite rev `2a42b3354c9194700d08aa070f70a131a470e7dc` (bundled SQLCipher) |
| Protobufs | Signal-Android v8.17.3 / Signal-Desktop v8.17.0. These include polls, pin/unpin, admin delete, member labels and CallLogEvent. |

For comparison, signal-cli 0.14.10 ships `libsignal-client-0.106.1`. presage is 7 libsignal minor versions behind, and the upgrade PR (lss #502, to 0.106.2) is still open.

Checkouts are in `scratchpad/presage/repo` (presage) and `scratchpad/presage/lss` (libsignal-service-rs at the pinned rev).

## 2. Build on this Mac (M1 Max, 10 cores, macOS 27 / Xcode 27.2, rustc 1.97.1)

- **Prerequisites:** protoc 36.2 and cmake 4.4.5 were already installed from Homebrew. `cdsi` needs cmake because it builds BoringSSL. Go was not needed.
- **The plain `cargo build --release -p presage-cli` fails on macOS 27.** rustc dlopens the `sqlx-macros` proc-macro dylib and dyld refuses it:
  `mis-aligned LINKEDIT string pool`.
  Cause: the dylib's string table offset is only 4-byte aligned, because the indirect-symbol table before it has an odd number of entries (287). Xcode 27's ld (ld-27106.1) and Homebrew lld 23.1.5 both produce this layout, and macOS 27's dyld rejects it. It is a toolchain/OS problem, not a presage one. Any dylib with an odd number of indirect symbols will hit it. The `-ld_classic` linker is gone in Xcode 27.
  - **Workaround used:** `CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_OPT_LEVEL=1`. Proc-macros then compile differently, the symbol counts change, and the dylib comes out 8-byte aligned. This works by luck, not by design. Pin it in the helper's `Cargo.toml` (`[profile.release.build-override] opt-level = 1`). Also add a CI check that dlopens the proc-macro dylibs or runs the final binary. The final executables and the dozens of build-script binaries all loaded fine.
  - I ran `brew install lld` while testing. It did not help and can be removed with `brew uninstall lld`.
- **Build times** (warm cargo registry and git caches, 10 cores):
  - Full release rebuild without `cdsi`: **98.7 s wall** (723 s user).
  - Adding `--features cdsi` on top of that: 80 s.
  - The first, failing attempt took 129 s including downloads.
- **Binaries:**
  - `presage-cli` without `cdsi`: 24.6 MB, 19.9 MB stripped. Copy kept at `scratchpad/presage/presage-cli.nocdsi`.
  - `presage-cli` with `--features cdsi` (BoringSSL plus libsignal-net): 31.1 MB. This is the one now at `repo/target/release/presage-cli`.
  - Both link only system frameworks: Security, CoreFoundation, SystemConfiguration, Foundation, plus AppKit pulled in by presage-cli's `notify-rust`. A helper of our own would not need AppKit.
  - SQLCipher uses CommonCrypto/Security.framework on macOS, so OpenSSL is not needed.
  - The JRE plus jars signal-cli uses today come to about 250 MB.
- **`target/` is 3.9 GB** and was kept as asked. It holds three build flavors: the default, the useless lld one, and cdsi. The `~/.cargo` git checkout of libsignal adds 61 MB.

## 3. How Corvus uses signal-cli today

Corvus runs one `signal-cli -a <acct> jsonRpc` process per account over stdio. It also runs `signal-cli [--tls-proxy …] link -n <name>` as a one-off command.

RPC methods called from Swift:

- **Messaging:** send, sendReaction, sendTyping, sendReceipt, remoteDelete, sendPinMessage, sendUnpinMessage, sendPollCreate, sendPollVote, sendPollTerminate.
- **Groups:** listGroups, updateGroup (create, title/description, avatar, add/remove members, admin, ban/unban, permissions, link state, member label), quitGroup, joinGroup.
- **Contacts and account:** listContacts, updateContact, removeContact, block, unblock, sendMessageRequestResponse, updateAccount, updateProfile, listIdentities, trust.
- **Media and stickers:** getAttachment, getAvatar, getSticker, listStickerPacks, addStickerPack, uploadStickerPack.
- **Calls:** subscribeCallEvents, startCall, acceptCall, rejectCall, hangupCall.
- **Out of scope:** sendStory.

The Rust helper must reproduce these methods and the `receive` notification envelope JSON. That JSON mapping is a large share of the work regardless of backend.

## 4. Feature matrix

Legend:

- **P** = supported by presage's API
- **P-raw** = presage hands us the decoded protobuf `Content` and we map it ourselves; nothing is missing at the protocol level
- **L** = available in libsignal-service-rs (lss) but not wrapped by presage
- **M** = missing in both

Effort is in focused engineer-days and does not include the signal-cli JSON mapping.

### 4.1 Linking and initial sync

| Feature | Status | Notes / what to build |
|---|---|---|
| Link as secondary (QR provisioning URI) | P | `Manager::link_secondary_device(store, SignalServers::Production, device_name, oneshot<Url>)` yields the `sgnl://linkdevice?uuid=…&pub_key=…` URL. Uses `/v1/websocket/provisioning/` then `PUT /v1/devices/link`. Open issue #426 reports `Service error: Not found` / "no provisioning message received" for some users; Flare maintainers cannot reproduce it. |
| Device name | P | Set at link time. `update_device_name()` (`PUT /v1/accounts/name`) is also available. |
| Unlink self / list devices | P | `unlink_self()`, `devices()` |
| Keys (AEP / master key) | P | Handles `SyncMessage.Keys`. It auto-requests keys on the first `QueueEmpty` if missing. |
| Groups initial sync | P | Reads `GroupV2Record` entries from the Storage Service on link and on `FetchLatest(StorageManifest)` (merged #469). Then fetches each group (`GET /v1/groups/`). |
| Contacts initial sync | partial P / M | presage handles only the **legacy** contact-sync attachment (`SyncMessage.Contacts`, requested via `request_contacts()`). Current phones keep contacts, names, nicknames, notes, profile keys, blocked flags and hidden state in the Storage Service as `ContactRecord`. presage ignores those records. lss can read and decrypt them (`StorageService::manifest/read_items`, `decrypt_item`, `/v1/storage/manifest`, `/v1/storage/read`). **Needs:** parse `ContactRecord`, `AccountRecord` and `GroupV2Record.blocked` into our store. 3-4 d. |
| Blocked list | M (raw sync only) | Incoming `SyncMessage.Blocked` reaches us as P-raw. presage does not persist it and answers Blocked requests with an empty list. The authoritative source is the Storage Service (`ContactRecord.blocked`, `GroupV2Record.blocked`). 1 d on top of the contacts work. |
| Configuration (read receipts, typing, previews, sealed-sender indicators) | P-raw | `SyncMessage.Configuration` and `AccountRecord` fields. We store them ourselves. 0.5 d. |
| Message history transfer at link | M | Only the ephemeral backup key is surfaced (#442). There is no backup import. Not needed, since Corvus imports its own history. |

### 4.2 Receive

| Feature | Status | Notes |
|---|---|---|
| Receive loop | P (with caveats) | `receive_messages()` returns a `Stream<Received>`: `Content`, `QueueEmpty`, `Contacts`, `DecryptionError`. Caveats: (1) it uses `tokio::task::spawn_local`, so it must run inside a `LocalSet`; (2) the stream **ends** when the websocket closes, and the caller must call `receive_messages()` again with backoff; (3) lss acks an envelope as soon as the pipe yields it, before decryption and store commit, so a crash at the wrong moment loses that message (open PRs lss #442/#489, presage #476); (4) it sends `X-Signal-Receive-Stories: false`, so stories never arrive, which suits us. |
| Text, quotes, mentions, body ranges/styles, reactions, remote delete, edit, sticker, link preview, view-once, expiration timer update, contact cards, payments (display only), gift badge | P-raw | All fields are in `DataMessage` / `EditMessage`. Edits and deletes are stored by presage (#408, #411) but not interpreted; we resolve them by target timestamp. |
| Attachments download/decrypt | P | `get_attachment(&AttachmentPointer)` uses the CDN, checks the SHA-256 digest and does AES-CBC+HMAC in memory, off-thread above 100 KB. It does not stream to disk and has no incremental-MAC playback; fine for us. |
| Typing, receipts (delivery/read/viewed) | P-raw | `TypingMessage`, `ReceiptMessage`. presage stores receipts as thread messages (#409, open bug #497). |
| Sync messages (sent transcripts, read, viewed, viewOnceOpen, blocked, messageRequestResponse, contacts, sticker ops, CallEvent, DeleteForMe) | P-raw / P | Sent transcripts carry a group master key, which triggers a group upsert. Sticker install/remove syncs are applied by presage. Everything else is passed through raw. |
| Call messages (offer/answer/ICE/hangup/busy/opaque) | P-raw | `ContentBody::CallMessage`. See §6. |
| Pin/unpin, polls (create/vote/terminate), admin delete | P-raw | Present in the protos (`pinMessage` 27, `unpinMessage` 28, `pollCreate` 24, `pollTerminate` 25, `pollVote` 26, `adminDelete` 29). |
| Group v2 updates | P (state only) | When a message carries a newer revision, presage fetches the whole group again (`upsert_group`). It does **not** decrypt the `groupChange` or read the change log, so "who changed what" is unavailable. Open PRs presage #493, lss #496/#497 add `GET /v2/groups/logs/{from}`. signal-cli only reports `groupInfo.type=UPDATE`, so this is enough for parity. |
| Delivery receipts | M (trivial) | presage never sends them; signal-cli does automatically. We send `ReceiptMessage{type:DELIVERY}` when `metadata.needs_receipt`. 0.5 d. |
| Decryption-error recovery | M | The `DecryptionErrorMessage` / retry-receipt path only logs. It does not archive sessions or resend, so peers can get stuck (#399; lss PR #484 is open). We archive the session, send a null message and handle the sender-key DEM. 2 d. |

### 4.3 Send

| Feature | Status | Notes |
|---|---|---|
| Text + attachments, quotes, mentions, styles, previews, stickers, reactions, remote delete, edit, view-once, expiration timer | P (build the proto) | `send_message(recipient, ContentBody, ts)`, `send_message_to_group(master_key, …)` and `upload_attachments()` (`/v4/attachments/form/upload`, then CDN). The expire timer and its version are filled in automatically. **Trap:** presage auto-fetches a link preview for any outgoing URL unless `preview` is already set. That fetch exposes the helper's IP to the linked site, and it cannot be turned off (PR #478 adds a toggle). Patch it or send through lss `MessageSender` directly. |
| Typing | L | `send_message` hard-codes `online=false` and stores the message in presage's history. Typing must go out online-only, so call lss `MessageSender::send_message(..., online=true)` directly. 0.5 d. |
| Read/viewed receipts, read sync | P / L | Use a `ReceiptMessage` to the sender plus `send_sync_message(SyncMessage.Read/Viewed)` to own devices. |
| 1:1 and groups v2 | P | Group sends are **fan-out per member** (one sealed-sender message each). Sender keys (`PUT /v1/messages/multi_recipient`) are not implemented; lss PRs #453/#472 are open. This is correct but slower, with more requests and rate-limit risk, in large groups. Receiving sender-key messages (SKDM) works. |
| Sealed sender | P | Used when the recipient's profile key is known. Otherwise the send is identified. Sender certificate is refreshed automatically. |
| Sync transcripts to own devices | P | Automatic in lss `MessageSender` when multi-device, which is always the case for a linked device. |
| Note to Self | P | Sent as a sync transcript only. |
| PNI signature | M | Always `include_pni_signature=false` (#252). This matters when replying to someone who found us by phone number. 1 d. |
| Send to a phone number / getUserStatus | P with `--features cdsi` | `discover_contacts_by_phone_number()` (CDSI over libsignal-net). Built and tested to compile. |
| Message request response | L | lss `MessageSender::send_message_request_response()` (a sync message). Needs wrapping plus local state. 0.5 d. |
| Pin/unpin, polls | P (build the proto) | Plain `DataMessage` fields. |

### 4.4 Groups v2

| Feature | Status | Notes |
|---|---|---|
| List with members/admins/pending/requesting, permissions, description, avatar, timer, invite-link password, member labels | P | `presage::model::groups::Group`. Labels and label emoji are present. **Banned members** are decoded by lss (`BannedMember`) but dropped by presage's model; trivial to add. |
| Invite link (get) | P (derive) | Build `https://signal.group/#…` from master key + `invite_link_password` (`GroupInviteLink` proto). 0.5 d. |
| Create, update title/description/avatar/timer/permissions, add/remove members, promote/demote admins, ban/unban, member labels, reset/enable link, approval toggle, approve/deny requests, quit, join via link | **M** | Released lss only does `GET /v1/groups/` (read). Needed endpoints:<br>- `PUT /v2/groups` (create)<br>- `PATCH /v2/groups` (`GroupChange.Actions`; 409 conflict means refetch and retry)<br>- `GET /v2/groups/join/{inviteLinkPassword}` (`GroupJoinInfo`)<br>- `GET /v2/groups/avatar/form` + CDN upload<br>- `GET /v2/groups/logs/{from}`<br>Adding members also needs **expiring profile-key credentials** (`GET /v1/profile/{aci}/{version}/{credentialRequest}?credentialType=expiringProfileKey`), which are not in lss (PR #426). After each change, send a `DataMessage.groupV2` carrying `groupChange` to the members. lss has building blocks (`build_add_member_action`, `encrypt_title`, `encrypt_group_with_credentials`). **Open PRs:** lss #473 "create and change groups" (+620 lines, title/description/timer/members/roles/avatar, join via link or request, tested against a self-hosted server) and presage #448. Building on those: 4-6 d. From scratch: 2-3 weeks. |

### 4.5 Profiles, account, contacts, identities

| Feature | Status | Notes |
|---|---|---|
| Fetch others' profiles and avatars | P | `retrieve_profile_by_uuid(aci, profile_key)`, `retrieve_profile_avatar_by_uuid`, `retrieve_group_avatar`. The cache never refreshes; PR #487 is open. 0.5 d to bypass. |
| Set own name/about/emoji | P | `update_profile()` (versioned profile, keeps the avatar). |
| Set own avatar | L | lss `AccountManager::upload_versioned_profile(.., AvatarWrite::NewAvatar)`. 0.5 d. |
| Phone-number sharing | M | The profile write lacks `phoneNumberSharing`, and `AccountRecord.phoneNumberSharingMode` needs a Storage Service write. 1 d plus the storage-write work. |
| Discoverability | M (L for primaries only) | `PUT /v1/accounts/attributes` exists, but presage hard-codes `discoverable_by_phone_number: true` on every receive start. For a linked device the source of truth is `AccountRecord.unlistedPhoneNumber` in the Storage Service. Patch the presage default, then do the storage write. |
| Usernames | lookup P; link L; set/delete **M** | `lookup_username()` (`/v1/accounts/username_hash/{hash}`) and lss `set_username_link` / `look_up_username_link` exist. Missing: `PUT /v1/accounts/username_hash/reserve`, `PUT /v1/accounts/username_hash/confirm` (with the zk proof from libsignal's `usernames` crate, already a dependency) and `DELETE /v1/accounts/username_hash`, then sync `AccountRecord.username`. 2-3 d. |
| Contact names/nickname/note editing and Storage Service sync | **M (write side)** | lss reads the Storage Service and has `encrypt_item`/`encrypt_manifest`, but there is no `PUT /v1/storage` (WriteOperation). Doing it properly takes 1.5-2 weeks for contacts, account, blocked and group records: manifest versioning, 409 conflict merge, `recordIkm` key derivation, keeping unknown fields, sending a `FetchLatest` sync to other devices. Without it, edits stay local to Corvus, and blocked state is synced only by `SyncMessage.Blocked`. |
| Block/unblock | partial | Send `SyncMessage.Blocked` via `send_sync_message` (L). Local blocked state is ours to store. Full parity needs the storage write. 1 d without it. |
| Identities, safety numbers, trust | partial | Identities are stored, but trust is a **global** policy (`OnNewIdentity::Trust/Reject`). There is no per-identity verified/untrusted state, no listing API, and `SyncMessage.Verified` is not handled. Safety numbers come from libsignal-protocol's `Fingerprint` (available). **Needs:** a wrapper or own store table for trust levels, `listIdentities`/`trust` semantics, and identity-change events. Open PRs #449/#450 cover parts. 2-3 d. |

### 4.6 Stickers

| Feature | Status | Notes |
|---|---|---|
| Install, list, get sticker files | P | `install_sticker_pack(pack_id, key)` downloads and decrypts the manifest and every sticker, stores the bytes, and syncs to other devices. `sticker_packs()` / `sticker_pack()` / `sticker_metadata()` are available, and `remove_sticker_pack()`. Installs synced from other devices are applied automatically. Corvus also calls `uploadStickerPack`; pack creation is **M** (you said it is not needed). |

### 4.7 Other

| Item | Status | Notes |
|---|---|---|
| Signal TLS proxy (`https://signal.tube/#host`) | **M** | lss builds one reqwest client: HTTP/1, Signal CA only, 10 s connect, 65 s read timeouts. Standard HTTP(S)/SOCKS proxies from env or system settings work via reqwest's `system-proxy` feature. A Signal TLS proxy needs TLS-in-TLS: outer TLS to the proxy host, inner TLS to `chat.signal.org`/CDN/storage. Simplest design: a local forwarder task that terminates nothing, wraps each TCP connection in outer TLS to the proxy, and a `reqwest::ClientBuilder::resolve()` override pointing Signal hostnames at it. libsignal-net already has TLS-proxy code, but only for CDSI. 2-4 d plus a small lss patch to inject the client builder. |
| Websocket keepalive / reconnect | P (basic) | lss sends `/v1/keepalive` every 55 s, first one delayed by one interval, and closes the socket when one goes unanswered. Nothing reconnects automatically: the receive stream ends, and the next send opens a new socket. Open fixes: lss #494 (30 s keepalive, which matches the official clients and libsignal-net's 31 s idle limit), #481 (don't kill healthy sockets after sleep), #482, presage #464 (retry a send once on socket close). We must add a reconnect supervisor with backoff and sleep/wake handling. 1-2 d. |
| Multiple accounts | P | One `Manager` per `SqliteStore` file. Running one helper process per account matches Corvus's current per-account `jsonRpc` processes. |
| Concurrency | P | `Manager` is `Clone`; sends can run on a clone while the receive stream runs. Methods take `&mut self`. `Store` is not `Send`, so use a `LocalSet` / current-thread runtime. |

## 5. Local storage (presage-store-sqlite)

- **Engine:** sqlx 0.9 + SQLCipher (bundled, CommonCrypto). `SqliteStore::open_with_passphrase(url, Some(pass), OnNewIdentity)` sets `PRAGMA key`. WAL mode, at most 3 connections, 2 MB cache each. Migrations run automatically (8 so far).
- **Tables:** `kv` (registration data, master key, AEP, sender certificate), `identities`, `new_identities`, `contacts_verification_state`, `sessions`, `pre_keys`, `signed_pre_keys`, `kyber_pre_keys`, `base_keys_seen`, `sender_keys`, `profile_keys`, `profiles`, `profile_avatars`, `contacts`, `groups`, `group_avatars`, `left_groups`, `sticker_packs`, `threads`, `thread_messages`.
- **Message history: yes, it keeps all of it.** `thread_messages` stores the full serialized `ContentBody` of every received and sent message, including receipts, with no expiry. Corvus keeps its own encrypted history, so wrap the `Store` trait and make `save_message` a no-op, or keep only a short tail of message timestamps for edit/delete/quote lookups. Note that `save_message` also drives expire-timer bookkeeping. Alternatively, call `clear_messages()` periodically. 1 d.
- **Passphrase:** keep it in the Keychain and pass it from Swift through an environment variable or fd. Do not put it on the command line; `presage-cli -p` does that.

## 6. Voice calls (1:1)

**How signal-cli 0.14.10 does it** (checked against `~/.local/share/signal-cli-jvm/signal-cli-0.14.10/lib`):

- No jar bundles RingRTC or WebRTC. The only native library is `libsignal_jni_aarch64.dylib`, inside `libsignal-client-0.106.1.jar`.
- `org.asamk.signal.manager.helper.CallManager`, in `libsignal-cli-0.14.10.jar`, spawns a **separate process per call: `signal-call-tunnel`**. It finds the binary via `SIGNAL_CALL_TUNNEL_BIN`, then `<install>/bin/signal-call-tunnel`, then `PATH`. It talks to the process with newline-delimited JSON over stdin/stdout (documented in upstream `docs/CALL_TUNNEL.md`):
  - **Config line:** `call_id`, `is_outgoing`, `local_device_id`, device names.
  - **Commands to the tunnel:** `createOutgoingCall`, `proceed{iceServers,hideIp}`, `receivedOffer`, `receivedAnswer`, `receivedIce`, `accept`, `hangup`.
  - **Events from the tunnel:** `ready`, `sendOffer`, `sendAnswer`, `sendIce`, `sendHangup`, `sendBusy`, `stateChange`, `error`.
- signal-cli itself only relays `CallMessage` signaling, fetches TURN servers (`GET /v2/calling/relays`), runs the state machine and 60 s ring timeouts, and emits `callEvent` notifications.
- On this Mac the tunnel is `~/.cargo/bin/signal-call-tunnel` (15.6 MB). It is a Rust binary built on Nov 5 from `~/Programming/signal-call-tunnel` with a vendored `third-party/ringrtc` and **cubeb** for CoreAudio I/O.
  - The **source directory no longer exists**. Upstream keeps the tunnel with signal-cli; it arrived in PR #1932, and issue #2155 says no prebuilt binaries are published.
  - Re-vendor the source before relying on it.

**What it takes in Rust:**

- **Recommended:** keep the tunnel as a subprocess, unchanged, and port `CallManager` into the Rust helper.
  - presage already has `calling_relays()` (TURN), `send_call_event()` (CallEvent sync), and raw `CallMessage` receive and send.
  - Remaining work:
    - Relay offer, answer, ICE, hangup and busy as `CallMessage` (urgent, online).
    - Pass raw 32-byte identity keys.
    - Filter multi-device hangup types.
    - Defer `accept` until the tunnel reports `Ringing`.
    - Add the ring timeout, call log, and the `startCall`/`acceptCall`/`rejectCall`/`hangupCall`/`subscribeCallEvents` RPCs.
  - **Estimate: 4-6 d.** Crash isolation is kept, and the helper stays free of WebRTC.
- **In-process RingRTC:**
  - `ringrtc` is not on crates.io. You build it from `signalapp/ringrtc` together with Signal's WebRTC fork.
  - A source build needs depot_tools, gn/ninja, Chromium's toolchain, more than 20 GB and 1-2 h per clean build.
  - RingRTC's build scripts can download Signal's prebuilt WebRTC static libraries for desktop targets (`build-artifacts.signal.org`). I did not verify a current macOS arm64 artifact.
  - You also need an audio device module: cubeb as in the existing tunnel, or ringrtc's file/virtual ADM.
  - **Estimate: 2-4 weeks**, with an ongoing cost of following ringrtc and WebRTC version bumps.
  - Not recommended unless the subprocess becomes a problem.

## 7. Project health and server-compatibility risks

- **Activity:**
  - presage: 44 commits since 2026-05-09 (main maintainer Schmiddiii) and 73 commits in 2026.
  - libsignal-service-rs: 75 commits in the same period (mostly rubdos).
  - The project is active, but the **review backlog is large**: 38 open presage PRs (27 from one contributor, barafael) and 33 open lss PRs. Many are exactly the parts we need: group create/change, change log, sender keys, multi-recipient sends, 30 s keepalive, ack handles, session locking, pre-key rework, libsignal 0.106.2, link-preview toggle, identity pinning.
- **Open issues relevant to us:**
  - #426: linking fails for some users with `Not found` or "no provisioning message".
  - #439 and #414: a *primary* device cannot send or receive. This does not affect us, because we link as a secondary.
  - #399: decryption-error loop.
  - #497: receipts stored as messages.
  - #396: no history transfer at link.
  - Recently fixed: PNI first-contact decryption (#395, #440) and primary registration (#424).
- **libsignal lag:** v0.99 against signal-cli's 0.106.1. lss #502 brings 0.106.2 and changes the pre-key decrypt API. Signal servers eventually reject or degrade old clients, so expect to track libsignal bumps yourself if upstream review is slow.
- **Correctness gaps that affect users:**
  - Ack-before-commit can lose messages.
  - No delivery receipts.
  - No DEM-driven session repair.
  - Fan-out group sends.
  - Contacts come only from the legacy sync blob, not the Storage Service.
- **License:** presage and lss are AGPL-3.0-only. Corvus is already AGPL-3.0, so linking them in, in-process or as a helper, raises no license conflict.

## 8. Recommendation

1. **Depend on presage as a library, pinned to our own fork, and call lss directly where presage is too opinionated.** Do not drop down to lss alone.
   - presage's receive loop, linking, Storage Service group sync, profile, sticker and attachment plumbing, sender-certificate handling and SQLCipher protocol store are worth keeping. Each is about a week of careful work to redo.
   - presage re-exports lss as `presage::libsignal_service`, so bypassing it per call (typing, receipts, message-request response, avatar upload, storage reads) costs nothing.
   - Cherry-pick the pending PRs we need into the fork: lss #473 groups, #494/#481 keepalive, #484 retry receipts, #442/#489 ack handle, #502 libsignal 0.106.2; presage #448/#493 groups, #478 previews toggle, #450/#449 identities. Upstream fixes as they merge.
2. **Wrap the `Store`:** keep the protocol store and drop message history; add tables for trust levels, blocked list, configuration and Storage Service records.
3. **Keep `signal-call-tunnel` as a subprocess** and port only the signaling `CallManager`. Recover the tunnel's source first.
4. **Order of work:**
   - JSON-RPC shell and envelope mapping.
   - Link, receive, send for 1:1 and groups.
   - Delivery receipts, decryption-error repair, reconnect supervisor.
   - Storage Service read for contacts and blocked.
   - Groups write (from the PRs).
   - Profile avatar, usernames, identities/trust.
   - Calls.
   - TLS proxy.
   - Storage Service write.
5. **Rough total for signal-cli parity on Corvus's RPC surface:** about 8-11 engineer-weeks.
   - About 3 weeks of that is the JSON-RPC and envelope compatibility layer.
   - About 2 weeks is Storage Service write.
   - The rest is spread over the gaps above.
   - A usable first version for messaging and groups is about 4-5 weeks.
