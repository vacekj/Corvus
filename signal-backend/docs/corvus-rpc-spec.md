# Corvus ⇄ signal-cli interface contract (what the macOS app actually uses)

Source of truth: `macos/` at `main` (clean tree, 2026-11-09).
All paths below are relative to `macos/` unless they start with `src/`, `tests/`, `packaging/` (repo root).
This document lists only what Corvus **sends** and what it **reads**. Fields signal-cli emits but Corvus
ignores are called out where it matters. A Rust/presage backend that satisfies this file can be dropped in
behind `SignalCli.swift` with no Swift changes beyond the launcher (section 6).

Cross-reference: `tests/mock-signal-cli.py` is a mock signal-cli that the Swift tests and debug UI runs talk to; its response
shapes match what is listed here and make a good first conformance fixture.

---

## 0. JSON value conventions (important for the Rust serializer)

Swift helpers (`Sources/CorvusCore/Model.swift:6-18`) are lenient in one direction only:

| helper | accepts | anything else becomes |
|---|---|---|
| `jsonString` | JSON string only | `""` (a number is **not** stringified) |
| `jsonInt64` / `jsonInt` | JSON number, or a decimal string | `0` |
| `jsonBool` | JSON `true/false` (NSNumber) only | `false` (the string `"true"` is false) |
| `jsonObject` | JSON object | `{}` |
| `jsonArray` | JSON array | `[]` |

Rules that follow:
- IDs that Corvus treats as strings (attachment `id`, group `id`, `packId`, `uuid`, `number`) **must be JSON strings**.
- Timestamps (ms since epoch), `callId`, sizes, and counts are JSON numbers (Int64). Strings work but avoid them.
- Absent and `null` are treated the same as empty/false/0.
- Defaults that differ from "falsy": `isMember` absent ⇒ **true** (groups); `allowsReplies` absent ⇒ **true** (stories);
  `allowMultiple` absent ⇒ **true** (polls).

Recipient identifiers: Corvus addresses people by **E.164 number** when it knows one, else by **ACI UUID**
(`chats.resolveKey`, alias map built from `listContacts` `number`↔`uuid`). The backend must accept either form
anywhere a recipient/author is passed. Groups are addressed by the **base64 group id** exactly as `listGroups`
returns it in `id` (Corvus prefixes `g:` internally, never on the wire). Corvus also turns the group id into
URL-safe base64 only for the avatar file name (section 5).

---

## 1. Transport

### 1.1 Executable discovery and launch

- Path: `UserDefaults` key `executable`; if missing or nonexistent, `SignalCli.autodetect()`
  (`Sources/CorvusCore/SignalCli.swift:65`) searches `$PATH`, `/opt/homebrew/bin`, `/usr/local/bin`,
  `/opt/signal-cli/bin`, `~/.local/bin`, `~/bin` for a file named `signal-cli`. If still not found, a dialog offers
  "Choose path …" / download page (`Sources/CorvusMac/AppModel.swift:304-321`).
- **Helper indirection** (`SignalCli.configure`, `SignalCli.swift:77-88`): if
  `Corvus.app/Contents/Helpers/corvus-signal-cli.app/Contents/MacOS/corvus-signal-cli` exists **and** the
  configured executable exists, the process is the helper with argv `[<signal-cli path>, <args…>]`; otherwise the
  executable is started directly. The helper (`src/SignalCliHelper.cpp`) re-launches itself via Launch Services so
  the child does not inherit the app's `LSFileQuarantineEnabled` (signal-cli unpacks native libs to `$TMPDIR`). It
  relays stdin/stdout/stderr, signals (TERM/INT/HUP) and the exit status.
- Environment (`childEnvironment`, `SignalCli.swift:92-102`): the app's environment with `PATH` extended by
  `/opt/homebrew/bin`, `/usr/local/bin`, `~/.cargo/bin` (the last for `signal-call-tunnel`).
  For the long-running process only, `javaEnvironment` (`SignalCli.swift:114-127`) appends to `JAVA_OPTS`:
  `-Xlog:disable -XX:+AutoCreateSharedArchive -XX:SharedArchiveFile=~/Library/Caches/io.github.corvus.mac/signal-cli-<fnv64 of path, base36>.jsa`
  when the executable starts with `#!` (Java launcher) and `CORVUS_NO_CDS` is unset.
- QoS `.userInitiated`; while connected the app holds a `ProcessInfo.beginActivity(.userInitiatedAllowingIdleSystemSleep)`
  to keep App Nap away (`SignalCli.swift:289`).
- **No `--config`/data-dir option is ever passed.** signal-cli's default data dir is used
  (`$XDG_DATA_HOME/signal-cli` or `~/.local/share/signal-cli`). See section 5 for direct reads of it.

### 1.2 Global options

`cli.globalOptions` is set from the TLS proxy setting at startup (`Sources/CorvusMac/AppChrome.swift:60`) and when
saved (`Sources/CorvusMac/AppChromeSettings.swift:105`): `["--tls-proxy", "<host>[:port]"]` or `[]`
(`SignalProxy.arguments`, `Sources/CorvusCore/SignalCliAccount.swift:67`). Input accepts `host`, `host:port`,
or `https://signal.tube/#host` and is normalized to lowercase `host[:port]`. UserDefaults key `signalCli.tlsProxy`.
Global options are prepended to every invocation **except** `--version` (`SignalCli.swift:178`). Changing the proxy
triggers `reconnect()`.

### 1.3 Process invocations (argv after the executable)

| # | argv | where | timeout | success criterion / output parsing |
|---|---|---|---|---|
| A | `--version` | `SignalCli.swift:237` (`queryVersion`) called from `AppModel.swift:409`; also `versionLine` `SignalCli.swift:230` from `SignalCliUpdater.swift:155` | 60 s (90 s for updater) | exit 0. First stdout line trimmed; **last space-separated token** = version (`AppModel.swift:415`), shown as "Connected · signal-cli <version>" and compared to GitHub releases. |
| B | `[global] -o json listAccounts` | `SignalCli.swift:243`, called `AppModel.swift:418` | 60 s | stdout parsed by `parseAccounts` (`SignalCli.swift:136`): JSON array whose items are either strings or objects with `number` (string). Fallback (non-JSON): every regex match `\+\d{5,}`. Dedup, order kept. `!ok && accounts.isEmpty` ⇒ error dialog; `ok && empty` ⇒ "No account, link now?"; non-zero exit **with** parsed accounts is accepted. **UUID-only accounts are not supported** (objects need `number`). |
| C | `[global] -a <account> jsonRpc` | `SignalCli.swift:253` (`start`) | none | long-running; see 1.4 |
| D | `[--tls-proxy …] link -n <device name>` | `Sources/CorvusMac/LinkView.swift:80-81` | none (user cancels) | see section 2 |
| E | `[global] -a <account> deleteLocalAccountData --ignore-registered` | `Sources/CorvusMac/AppChromeSettings.swift:183` | 120 s | exit 0; on failure shows stderr (or startError). Runs after `cli.stop()`. |

One-shot calls (A, B, E) run with stdin = `/dev/null`, both pipes drained concurrently, SIGTERM on timeout then
SIGKILL after 1 s (`SignalCli.runBlocking`, `SignalCli.swift:182-227`). Every run is logged to the app's stderr with
phone numbers masked (`maskNumbers`).

### 1.4 JSON-RPC framing (process C)

- **Requests** (`SignalCli.call`, `SignalCli.swift:317-334`): one compact JSON object per line on stdin, `\n`-terminated:
  `{"jsonrpc":"2.0","method":"<name>","id":<Int>}` plus `"params":{…}` **only when params is non-empty**.
  Encoded with `JSONSerialization` (note: it escapes `/` as `\/` in strings; Bools are `true/false`; Int64 are numbers).
  `id` is a sequential integer starting at 1 per `SignalCli` instance and **not reset** on restart.
  Requests are fired concurrently from many tasks: several requests are in flight at once (e.g. up to 4 `getAvatar`,
  sticker fetches, sends). Responses may come back in any order. No `account` param is ever sent (single-account mode via `-a`).
- **Stdout parsing** (`onStdout` / `handleLine`, `SignalCli.swift:336-395`): split on `\n`; leading spaces/`\r`
  stripped; empty lines skipped.
  - Line not parseable as a JSON object ⇒ passed to `onLogLine` ⇒ **shown as a 5 s status-bar flash in the UI**
    (`AppModel.swift:213`). So stdout must carry JSON only.
  - Object with numeric `id` (NSNumber) **and no `method` key** ⇒ response. Unknown ids are dropped silently.
    If `error` is present: throws `RpcError(error.message as String ?? "Unknown error")` (code ignored);
    else resolves with `result` (or `NSNull` if absent). **String ids are not matched: the caller would hang forever.**
  - `method == "receive"` ⇒ envelope = `params.envelope`, else `params.result.envelope`; dispatched if non-empty.
    (Other keys in `params`, e.g. `account`, are ignored.)
  - `method == "callEvent"` ⇒ event = `params.result` (signal-cli shape `{"subscription":n,"result":{…}}`); dispatched if non-empty.
  - Any other notification method is ignored.
- **Stderr**: every non-blank line is (a) logged masked to the app's stderr, (b) remembered as `lastErrLine`, and
  (c) passed to `onLogLine` ⇒ **flashed in the UI for 5 s** (`SignalCli.swift:347-354`, `AppModel.swift:213`).
  A chatty backend logger on stderr will spam the status bar. Either log to a file or quiet stderr.
- **Timeouts**: none for RPC calls. A request without a response waits until the process exits (then all pending
  calls fail with the exit reason) or `stop()` (fails with "Disconnected").
- **Receiving**: Corvus never calls `subscribeReceive`/`receive`; it relies on signal-cli's single-account `jsonRpc`
  mode starting the receive loop automatically and pushing `receive` notifications. The backend must start receiving
  as soon as it starts.
- **Echo of own sends**: Corvus tolerates a `syncMessage.sentMessage` envelope for its own send arriving before or
  after the `send` response (`AppModel.swift:1245-1251`, `ChatState.pendingSendMatching` matches on conversation +
  identical text + attachment count). Emitting it or not are both fine.

### 1.5 Stop / exit / restart

- `stop()` (`SignalCli.swift:298-313`): close stdin, SIGTERM, SIGKILL after 3 s if still running; pending calls fail
  "Disconnected". The backend should exit promptly on stdin EOF or SIGTERM.
- Unexpected exit (`onExit`, `SignalCli.swift:356-365`): reason `"signal-cli exited (exit code N): <lastErrLine>"`;
  pending calls fail with it; `onStopped` fires ⇒ `setConnected(false, reason)` and `scheduleAutoReconnect()`.
- Auto-reconnect (`AppModel.swift:353-367`): delays 3, 10, 30, 60 s (max 4 attempts); counter resets if the previous
  auto-reconnect was >120 s ago; only when an account is known. If the process died within 30 s of a quick start, or an
  early start was in effect, the next connect does a full check (`fullCheckNext`, `AppModel.swift:206-211`).
- Manual: menu File → Reconnect, status bar "Reconnect", Settings → "Reconnect" (`reconnect()`, `AppModel.swift:369`).

### 1.6 Startup sequence and "account known" detection

1. `startCliEarly` (`AppModel.swift:257-267`): if UserDefaults `executable` and `account` exist, the file is executable
   and a cached version exists under key `cliVersion.<path>.<mtime-seconds>` (`executableStamp`, `AppModel.swift:348`),
   launch C immediately (before the history is unlocked). Envelopes that arrive before the history is loaded are
   buffered (`earlyEnvelopes`) and replayed.
2. After history unlock: `ensureExecutable()` then `connectAccount()` (`AppModel.swift:378-454`):
   - **Quick start**: if not `fullCheckNext`, `account` saved, and `cliVersion.<stamp>` cached ⇒ reuse/start C with the
     saved account, `didStartCli()`, done. (Replacing the binary changes mtime ⇒ full check.)
   - **Full check**: run A (version, cached under the stamp), then B. Zero accounts ⇒ link dialog (section 2).
     Saved account not in list ⇒ the only account, or a picker dialog; saved to UserDefaults `account`.
     Then start C.
   - "Connected" is declared as soon as the process **started** (`cli.isRunning`), not on any handshake.
3. `didStartCli()` (`AppModel.swift:456-462`): `setConnected(true)`, then in parallel: `listContacts`, `listGroups`,
   `subscribeCallEvents`, `listStickerPacks`, and the signal-cli updater's 12-hourly check. Avatars load via
   `fetchMissingAvatars` (section 5 / 3.2).
4. Every 15 min avatars are re-read (`AppModel.swift:228-233`). Expiring messages are handled locally (1 s timer).

---

## 2. Linking flow

- Entry points: "No account" dialog after B (`AppModel.swift:425-431`), menu "Link device …" (`Sources/CorvusMac/App.swift:198`).
  `linkDevice()` (`AppModel.swift:486-500`) stops C and shows `LinkView` (`Sources/CorvusMac/ContentView.swift:74`).
- `LinkView` (`Sources/CorvusMac/LinkView.swift`) starts process D on appear:
  `[--tls-proxy H] link -n "<name>"`, name default `corvus (<Host.current().localizedName ?? "Mac">)`, user-editable;
  "Restart" kills the running process (SIGTERM) and starts again with the new name. stdin = `/dev/null`.
- **URI detection**: stdout is accumulated; every line (trimmed) is scanned, and the **first line starting with
  `sgnl://` or `tsdevice:`** becomes the URI (replaced if a later read yields a different first match). Rendered as a QR
  code (CoreImage, correction level M) and shown in a copyable text field. Other stdout (e.g. "Associated with: …")
  is ignored.
- **Completion**: process exit code **0** ⇒ `onFinish(true)`. Non-zero ⇒ status text
  `"Linking failed (exit code N).\n<entire stderr>"` and the sheet stays open. Cancel ⇒ SIGTERM + `onFinish(false)`.
- After success: UserDefaults `account` is removed and `connectAccount()` runs the **full check** (A + B) to discover the
  newly linked number, then starts C. There is no RPC-based linking (`startLink`/`finishLink` are not used).

Implication for the Rust backend: a `link -n <name>` CLI subcommand printing the provisioning URL as its own stdout
line (`sgnl://linkdevice?uuid=…&pub_key=…`) and exiting 0 once provisioning and the initial sync are stored, plus
`--version` and `-o json listAccounts`, keeps the Swift side unchanged.

---

## 3. JSON-RPC methods Corvus calls (36 distinct)

Notation: `?` optional (key omitted when not applicable), `R` = recipient block appended by `addRecipient`
(`AppModel.swift:1323`):
- 1:1 chat: `"recipient": [String]` (one-element array, number or UUID)
- group: `"groupId": String`

"Result: ignored" means only success/error matters. Errors are shown to the user as `error.message`.

### 3.1 Contacts, identities, blocking, message requests

**`listContacts`**
- `AppModel.swift:517` — no params. Also cached verbatim (encrypted) in `roster-cache.bin` and re-parsed at next start
  (`Sources/CorvusMac/RosterCache.swift`), so the shape must stay stable.
- `Sources/CorvusMac/ProfileEditor.swift:11` — `{"recipients": [<own account>]}`.
- Result: array of objects. Fields read:

| field | type | used for |
|---|---|---|
| `number` | String | key (preferred) |
| `uuid` | String | key if no number; alias uuid→number |
| `name` | String | contact (address-book) name; title |
| `profileName` | String | fallback title when `name` empty |
| `isArchived` | Bool | chat archive state; a contact is only shown as a chat if it has local history **or** `isArchived` |
| `isHidden` | Bool | hidden = message request; skipped from the chat list |
| `isBlocked` | Bool | block set |
| `messageExpirationTime` | Int (seconds) | disappearing timer |
| `nickGivenName`, `nickFamilyName`, `note` | String | Signal nickname / note (`Sources/CorvusCore/MessageRequests.swift:51-56`) |
| `username` | String | own profile (ProfileEditor) |
| `profile.givenName`, `profile.familyName`, `profile.about`, `profile.aboutEmoji` | String | own profile (`Sources/CorvusCore/Profile.swift:23-28`) |
| `profile.hasAvatar` | Bool | own profile |

Note: upstream signal-cli's `JsonContact` may not emit `profileName`/`isArchived` in all versions; Corvus reads them if present.
Entries with neither `number` nor `uuid` are dropped. The list should include every known recipient (Corvus filters).

**`updateContact`** (result ignored)
- `AppModel.swift:917` — `{"recipient": String, "expiration": Int}` (seconds, 0 = off) — note `recipient` is a **plain string** here.
- `Sources/CorvusMac/ContactDetails.swift:44` — `{"recipient": String, "nickGivenName": String, "nickFamilyName": String}` (empty = clear).
- `Sources/CorvusMac/ContactDetails.swift:58` — `{"recipient": String, "note": String}` (empty = clear).

**`removeContact`** — `Sources/CorvusMac/MessageRequests.swift:80` — `{"recipient": String}`. Result ignored, error ignored.
Semantics expected: clears the contact's hidden state (accepting a hidden "message request").

**`block` / `unblock`** — `MessageRequests.swift:149` (block), `:182` (block or unblock) — params from
`RequestParams.block` (`Sources/CorvusCore/MessageRequests.swift:13-15`): person `{"recipient": [String]}`,
group `{"groupId": [String]}` (**array** here). Result ignored.

**`sendMessageRequestResponse`** — `MessageRequests.swift:104`, retry at `:109` —
`{"type": "accept"|"delete", "recipient": [String]}` or `{"type": …, "groupId": String}`. If the error message
(lowercased) contains `type`, `convert` or `enum`, it retries once with `"ACCEPT"`/`"DELETE"`. Result ignored.

**`listIdentities`** — `Sources/CorvusMac/Features.swift:285` — `{"number": String}` (number **or UUID** despite the key
name). Result: array; picks the first item with non-empty `safetyNumber` (else the first):

| field | type |
|---|---|
| `safetyNumber` | String (60 digits; non-digits ignored, shown in 12 blocks of 5) |
| `scannableSafetyNumber` | String (base64 of the scannable fingerprint protobuf, rendered as QR) |
| `trustLevel` | String: `UNTRUSTED` / `TRUSTED_UNVERIFIED` / `TRUSTED_VERIFIED` (only `TRUSTED_VERIFIED` is tested) |
| `addedTimestamp` | Int64 ms |

Errors ⇒ no identity shown.

**`trust`** (result ignored)
- `Features.swift:295` — `{"recipient": String, "verifiedSafetyNumber": String}` (the 60-digit number as listed).
- `Features.swift:307` — `{"recipient": String, "trustAllKnownKeys": true}`.

**`getAvatar`** → `{"data": String}` (base64 image bytes; empty/invalid ⇒ no avatar; error ⇒ no avatar)
- `AppModel.swift:1959` — one of `{"groupId": String}`, `{"contact": String}`, then fallback `{"profile": String}`.
- `AppModel.swift:2009` — `{"profile": <own account>}`.
- **Only used when `~/.local/share/signal-cli/avatars/` does not exist** (section 5). Max 4 in flight.

### 3.2 Groups

**`listGroups`**
- `AppModel.swift:527` — no params (cached verbatim in `roster-cache.bin` like contacts).
- `Sources/CorvusMac/Groups.swift:46` — `{"groupId": [String]}` (array; expects the matching group in the result).
- Result: array of objects (`GroupInfo.init(json:)`, `Sources/CorvusCore/Groups.swift:122-144`):

| field | type | notes |
|---|---|---|
| `id` | String (base64) | required; entries without it are dropped |
| `name` | String | empty ⇒ "Group" |
| `description` | String | |
| `isMember` | Bool | **absent ⇒ true**; `false` + self in `pendingMembers` = invitation (message request) |
| `isBlocked` | Bool | |
| `isTerminated` | Bool | |
| `messageExpirationTime` | Int seconds | |
| `members` | `[{number, uuid, isAdmin: Bool, label, labelEmoji}]` **or** `[String]` | string: `+…` = number else uuid |
| `pendingMembers`, `requestingMembers`, `banned` | same member shapes | `isAdmin` forced false |
| `admins` | member shapes | only used if no member has `isAdmin` |
| `permissionAddMember`, `permissionEditDetails`, `permissionSendMessage` | String | `ONLY_ADMINS` (also `only-admins`, `onlyAdmins`) else every member |
| `groupInviteLink` | String | empty = link disabled |

The "link needs approval" flag is not read from signal-cli (kept locally).

**`updateGroup`** — result ignored except on create.
- `AppModel.swift:915` — `{"groupId": String, "expiration": Int}`.
- `MessageRequests.swift:73` — `{"groupId": String}` only: **accept a group invitation** (join as pending member).
- `Groups.swift:63` (all edits, via `GroupParams`, `Sources/CorvusCore/Groups.swift:206-263`) — `{"groupId": String}` plus
  any of the following (call sites: `GroupViews.swift:139,175,185,186,226,228,230,232,251,282`,
  `GroupSettings.swift:53,69,80,94,104`, `GroupSettingsViews.swift:165,200`):

| key | type | meaning |
|---|---|---|
| `name` | String | rename (only sent when changed, non-empty) |
| `description` | String | (empty allowed = clear) |
| `member` | [String] | add members / approve join request |
| `removeMember` | [String] | remove / cancel invite / deny request |
| `admin` | [String] | promote |
| `removeAdmin` | [String] | demote |
| `ban` | [String] | ban (sent **together with** `removeMember` in one call, `GroupViews.swift:232`) |
| `unban` | [String] | |
| `link` | `"disabled"` / `"enabled"` / `"enabled-with-approval"` | invite link mode |
| `resetLink` | `true` | new invite link |
| `avatar` | String | path to an image file (staged copy, see 6.4) |
| `setPermissionAddMember`, `setPermissionEditDetails`, `setPermissionSendMessages` | `"every-member"` / `"only-admins"` | |
| `memberLabel`, `memberLabelEmoji` | String | own member label; both empty = clear (always sent together) |

- `Groups.swift:76` — **create**: no `groupId`; `{"name": String, "description"?: String, "member"?: [String], "expiration"?: Int}`.
  Result **must** contain `{"groupId": String}` (else "did not report the id of the new group").
  After every successful update Corvus calls `listGroups {"groupId":[id]}`.

**`quitGroup`** — `Groups.swift:104`, `MessageRequests.swift:125`, `:156` —
`{"groupId": String, "admin"?: [String]}` (`admin` = successor when the only admin leaves; Corvus checks this itself).
Also used to **decline an invitation**. `delete` is never sent. Result ignored.

**`joinGroup`** — `Sources/CorvusMac/GroupSettings.swift:124` — `{"uri": "https://signal.group/#<code>"}` (always the https form).
Result: `{"groupId": String, "onlyRequested": Bool}` (`Sources/CorvusCore/GroupInviteLink.swift:60-63`).
`onlyRequested` true ⇒ "admin must approve". Empty `groupId` ⇒ generic "Joined" message.

### 3.3 Messaging

**`send`** → result `{"timestamp": Int64}` (sent timestamp; missing/≤0 ⇒ Corvus uses local now). `results` is not read.
Recognized params (all call sites combined):

| key | type | meaning |
|---|---|---|
| `message` | String | body; mentions are already expanded (no U+FFFC) |
| `textStyle` | [String] `"start:length:STYLE"` | UTF-16 offsets; STYLE ∈ BOLD, ITALIC, STRIKETHROUGH, MONOSPACE, SPOILER (unknown strings pass through) |
| `mention` | [String] `"start:length:<uuid-or-number>"` | UTF-16 offsets over the `@Name` text in `message` |
| `attachments` | [String] | absolute file paths (staged copies; possibly re-encoded JPEG/PNG) |
| `voiceNote` | Bool true | voice note flag on the attachment |
| `viewOnce` | Bool true | |
| `sticker` | String `"<packIdHex>:<stickerId>"` | |
| `quoteTimestamp` | Int64 | quoted message's (latest) sent ts |
| `quoteAuthor` | String | number or UUID |
| `quoteMessage` | String | quoted text |
| `previewUrl`, `previewTitle` | String | link preview (URL also present in `message`) |
| `previewDescription` | String? | |
| `previewImage` | String? | path to image file |
| `editTimestamp` | Int64 | edit: target = the latest revision's ts |
| `storyTimestamp` | Int64 | story reply |
| `storyAuthor` | String | story reply |
| `recipient` / `groupId` | `R` | |

Call sites:
- `AppModel.swift:1443` composer send (message?, textStyle?, mention? (groups only), attachments?, voiceNote?, viewOnce?, sticker?, quote*?, preview*?, R).
- `AppModel.swift:1552` edit (message, editTimestamp, textStyle?, mention?, quote*?, preview*?, R). Result `timestamp` becomes the edit's new ts.
- `Sources/CorvusMac/Features.swift:366` forward (message?, textStyle?, sticker?, attachments?, R).
- `Features.swift:448` story reply (message, storyTimestamp, storyAuthor, `recipient: [author]` or `groupId`).
- `Sources/CorvusMac/MessageActions.swift:94` retry failed send (`RetrySend.params`, `Sources/CorvusCore/MessageActions.swift:73-87`: message?, textStyle?, mention?, sticker?, viewOnce?, quote*?; plus attachments?, preview*?, R).
- `Sources/CorvusMac/QuickSend.swift:65` notification reply / popup window (message, textStyle?, mention?, quote*?, R).

Any error = send failed (bubble marked failed, Retry/Delete). E.g. untrusted identity errors surface verbatim.

**`sendReaction`** (result ignored)
- `AppModel.swift:1581` — `{"emoji": String, "targetAuthor": String, "targetTimestamp": Int64, "remove": Bool, R}`.
- `Features.swift:475` (story) — `{"emoji", "targetAuthor", "targetTimestamp": <story ts>, "story": true, R}`.

**`remoteDelete`** (result ignored) — `AppModel.swift:1610`, `MessageActions.swift:166` —
`{"targetTimestamp": Int64, "recipients": [String]}` or `{"targetTimestamp": Int64, "groupIds": [String]}`
— note the **plural keys** here (not `R`). Uses the original `ts`, not the latest edit ts.

**`sendTyping`** (result & errors ignored) — `Sources/CorvusMac/TypingIndicators.swift:110` — `{"stop": Bool, R}`.

**`sendReceipt`** (result & errors ignored) — `Sources/CorvusMac/Privacy.swift:30` —
`{"recipient": String, "targetTimestamp": [Int64], "type": "read"}` — `recipient` is a **plain string**; one call per author.
Only "read" receipts are ever sent (no "viewed"). Delivery receipts are expected to be sent automatically by the backend.

**`sendPinMessage`** (result ignored) — `MessageActions.swift:26` —
`{"targetAuthor": String, "targetTimestamp": Int64, "pinDuration": Int, R}`; `pinDuration` seconds: 86400, 604800, 2592000, or **-1 = forever**.

**`sendUnpinMessage`** (result ignored) — `MessageActions.swift:44` — `{"targetAuthor": String, "targetTimestamp": Int64, R}`.

**`sendPollCreate`** — `Features.swift:114` — `{"question": String, "options": [String] (2…10), "noMulti": Bool, R}` → `{"timestamp": Int64}`.

**`sendPollVote`** (result ignored) — `Features.swift:144` —
`{"pollAuthor": String, "pollTimestamp": Int64, "options": [Int] (indexes; empty = retract), "voteCount": Int (monotonic per voter), R}`.

**`sendPollTerminate`** (result ignored) — `Features.swift:161` — `{"pollTimestamp": Int64, R}`.

**`sendStory`** — `Features.swift:498` — `{"attachment": String (path), "noReplies"?: true, "groupId"?: String}`
(no groupId = "My Story") → `{"timestamp": Int64}`. Only photo/video stories are posted (no text stories).

**`getAttachment`** → `{"data": String}` (base64 file bytes)
- `AppModel.swift:1723` — `{"id": String, R}` — fallback only when the local file `~/.local/share/signal-cli/attachments/<id>`
  is not readable (section 5). Used for opening, saving, forwarding, inline images, GIFs, voice notes, long text, view-once.
- `Features.swift:436` (story media) — `{"id": String, "groupId": String}` or `{"id", "recipient": [author]}` — always RPC.
- `Sources/CorvusMac/LinkPreviewActions.swift:50` (incoming link-preview image) — `{"id": String, R}` — always RPC;
  retried up to 3 times (2, 4, 6 s) because the attachment may still be downloading.

### 3.4 Stickers

**`listStickerPacks`** — `Features.swift:44` — no params. Result: array of
`{"packId": String (hex), "title": String, "author": String, "installed": Bool, "stickers": [{"id": Int, "emoji": String}]}`.
Only `installed == true` packs with stickers are shown.

**`getSticker`** — `Features.swift:67` — `{"packId": String, "stickerId": Int}` → `{"data": String}` (base64 webp/png/apng).
Up to 3 attempts (2, 4, 6 s back-off) for packs still downloading. Used for both picker and received stickers.

**`addStickerPack`** (result ignored) — `Features.swift:91` — `{"uri": "https://signal.art/addstickers/#pack_id=<32hex>&pack_key=<64hex>"}`.
Afterwards `listStickerPacks` is called again.

**`uploadStickerPack`** — `Sources/CorvusMac/StickerCreator.swift:24` — `{"path": "<dir>/manifest.json"}`.
Manifest (`Sources/CorvusCore/StickerPackCreator.swift:75-88`):
`{"title", "author", "stickers": [{"file": "<name in same dir>", "emoji", "contentType": "image/png"}], "cover": {same entry}}`;
files are 512×512 PNG/APNG ≤300 KB. Result: either a **String** containing the link or `{"url": String}`; the link must be a
`https://signal.art/addstickers/#pack_id=…&pack_key=…` (or `sgnl://addstickers/?…`) URL (`StickerUploadResult.link`, `:96-101`).

### 3.5 Own account and profile

**`updateProfile`** (result ignored) — `ProfileEditor.swift:16`. Params are exactly one of:
- any subset of `{"givenName": String, "familyName": String, "about": String, "aboutEmoji": String}` (only changed fields;
  empty string clears; givenName never empty) — `ProfileEditor.swift:247`
- `{"avatar": String (path)}` — `ProfileEditor.swift:275`
- `{"removeAvatar": true}` — `ProfileEditor.swift:291`

**`updateAccount`**
- `ProfileEditor.swift:23` — `{"username": String}` (nickname with or without `.NN` discriminator; backend picks a free
  discriminator if absent) → `{"username": String (with discriminator), "usernameLink": String ("https://signal.me/#eu/…")}`.
- `ProfileEditor.swift:32` — `{"deleteUsername": true}` (result ignored).
- `Sources/CorvusMac/PrivacyAccount.swift:72` — `{"numberSharing": Bool, "discoverableByNumber"?: Bool}` or
  `{"discoverableByNumber": Bool}` (result ignored). Current values are never read back.

### 3.6 Voice calls

**`subscribeCallEvents`** — `Sources/CorvusMac/Calls.swift:262` — no params. Result ignored; **success means "calls supported"**,
error means unsupported (UI then says "needs signal-cli 0.14.2"). Called after every (re)connect.

**`startCall`** — `Calls.swift:307` — `{"recipient": String}` (plain string, 1:1 only) →
`{"callId": Int64, "state": String, "inputDeviceName"?: String, "outputDeviceName"?: String}` (state default `RINGING_OUTGOING`;
device names default `signal_input`/`signal_output`).

**`acceptCall`** — `Calls.swift:333` — `{"callId": Int64}` → `{"state"?: String}`.

**`rejectCall`** — `Calls.swift:343` — `{"callId": Int64}` (result & errors ignored).

**`hangupCall`** — `Calls.swift:349` — `{"callId": Int64}` (result & errors ignored).

Audio path assumption: the backend (signal-cli spawns `signal-call-tunnel`/RingRTC) plays/records through two CoreAudio
devices named `signal_input` (Corvus writes mic audio into it) and `signal_output` (Corvus plays it to the speakers),
bridged by `CallAudioBridge` (`Calls.swift:108-214`) when state becomes `CONNECTED`. Video is unsupported.

### 3.7 Method index (36)

listContacts, updateContact, removeContact, block, unblock, sendMessageRequestResponse, listIdentities, trust, getAvatar,
listGroups, updateGroup, quitGroup, joinGroup,
send, sendReaction, remoteDelete, sendTyping, sendReceipt, sendPinMessage, sendUnpinMessage, sendPollCreate, sendPollVote,
sendPollTerminate, sendStory, getAttachment,
listStickerPacks, getSticker, addStickerPack, uploadStickerPack,
updateProfile, updateAccount,
subscribeCallEvents, startCall, acceptCall, rejectCall, hangupCall.

Plus non-RPC CLI: `--version`, `-o json listAccounts`, `-a X jsonRpc`, `link -n NAME`, `-a X deleteLocalAccountData --ignore-registered`.

Responses whose `result` Corvus reads: listContacts, listGroups, listIdentities, listStickerPacks, getAvatar.data,
getAttachment.data, getSticker.data, send.timestamp, sendPollCreate.timestamp, sendStory.timestamp,
updateGroup(create).groupId, joinGroup.{groupId,onlyRequested}, updateAccount(username).{username,usernameLink},
uploadStickerPack.url|String, startCall.{callId,state,inputDeviceName,outputDeviceName}, acceptCall.state.

---

## 4. Incoming notifications

### 4.1 `receive` → envelope dispatch

Dispatcher `AppModel.onEnvelope` (`AppModel.swift:1161-1263`), in this order:
1. `parseReceipt(env)` (`Sources/CorvusCore/Receipts.swift:32-44`) — if `receiptMessage` present and effective.
2. `parseTyping(env)` (`Sources/CorvusCore/Typing.swift:20-32`) — if `typingMessage` present.
3. `parseEnvelope(env)` (`Sources/CorvusCore/Envelope.swift:345-396`), first match wins:
   `dataMessage` → `editMessage` → `storyMessage` → `syncMessage.sentStoryMessage` → `syncMessage.sentMessage`.
   Anything else is dropped (`kind == .none`).

**Envelope top level** (`$` = `params.envelope`):

| path | type | use |
|---|---|---|
| `$.sourceNumber` | String | sender (preferred) |
| `$.sourceUuid` | String | sender fallback |
| `$.source` | String | sender fallback |
| `$.sourceName` | String | sender profile name; learned as contact name for 1:1 |
| `$.timestamp` | Int64 | fallback message ts; story ts; receipt time |
| `$.dataMessage` | object | incoming content (4.2) |
| `$.editMessage` | object | incoming edit (4.3) |
| `$.storyMessage` | object | incoming story (4.4) |
| `$.syncMessage.sentMessage` | object | own message from another device (4.5) |
| `$.syncMessage.sentStoryMessage` | object | own story from another device (4.4) |
| `$.receiptMessage` | object | 4.6 |
| `$.typingMessage` | object | 4.7 |

**Not read at all** (the backend may omit them): `sourceDevice`, `serverReceivedTimestamp`, `serverDeliveredTimestamp`,
`callMessage` (calls use `callEvent`), `syncMessage.readMessages`, `syncMessage.viewedMessages`, `syncMessage.viewOnceOpen`,
`syncMessage.blockedNumbers/blockedGroupIds`, `syncMessage.contacts/groups`, `syncMessage.messageRequestResponse`,
`syncMessage.type`, `dataMessage.groupInfo.revision/name`, `dataMessage.groupCallUpdate` (presence only), `dataMessage.isProfileKeyUpdate`,
`dataMessage.endSession`, `receiptMessage` beyond the fields below. Consequence: reads on the phone do not clear unread
counts in Corvus; contact/group changes are picked up only via `listContacts`/`listGroups` on (re)connect or when group info opens.

Conversation key: group if `groupInfo.groupId` non-empty (`g:<id>`), else outgoing ⇒ destination, incoming ⇒ source.

### 4.2 `dataMessage` (also the body of `syncMessage.sentMessage`) — `parseBody`, `Envelope.swift:183-322`

Let `D` = `$.dataMessage` (or `$.syncMessage.sentMessage`). Evaluated in this precedence order:

1. **Timer change** if `D.isExpirationUpdate == true`, or "timer-only group update": `D.groupInfo.type == "UPDATE"` and
   `D.expiresInSeconds > 0` and none of these keys is non-empty: `message, attachments, reaction, sticker, contacts, payment,
   remoteDelete, pollCreate, pollVote, pollTerminate, quote, storyContext, groupCallUpdate`. Uses `D.expiresInSeconds`, `D.timestamp`.
2. **Story reaction**: `D.reaction` and `D.storyContext` both present and `reaction.isRemove != true` ⇒ shown as a message
   in the 1:1 chat with text = `reaction.emoji`, quote → story (`storyContext.sentTimestamp`, `authorNumber`/`authorUuid`).
3. **Reaction**: `D.reaction.{emoji: String, isRemove: Bool, targetAuthorNumber | targetAuthor: String, targetAuthorUuid: String, targetSentTimestamp: Int64}`.
4. **Remote delete**: `D.remoteDelete.timestamp: Int64` (target sent ts; only honored if sender == original author).
5. **Pin / unpin**: `D.pinMessage.{targetAuthorNumber | targetAuthor, targetAuthorUuid, targetSentTimestamp: Int64, pinDurationSeconds: Int (≤0 = forever)}`;
   `D.unpinMessage` same without duration. Pin time = `D.timestamp`.
6. **Poll vote**: `D.pollVote.{authorNumber | author, authorUuid (poll author), targetSentTimestamp: Int64, optionIndexes: [Int], voteCount: Int}`.
7. **Poll end**: `D.pollTerminate.targetSentTimestamp: Int64` (only honored from the poll author).
8. **Normal message** (dropped if both text and attachments end up empty):

| path | type | notes |
|---|---|---|
| `D.timestamp` | Int64 | message id (sent ts); fallback `$.timestamp`, then now |
| `D.message` | String | body; mentions are U+FFFC placeholders |
| `D.expiresInSeconds` | Int | disappearing timer of this message |
| `D.viewOnce` | Bool | |
| `D.groupInfo.groupId` | String | base64 group id |
| `D.groupInfo.type` | String | only `"UPDATE"` is tested (rule 1) |
| `D.textStyles[]` | `{style: String, start: Int, length: Int}` | preferred; `D.textStyle[]` as `"start:length:STYLE"` strings also accepted (`Sources/CorvusCore/Formatting.swift:78-92`) |
| `D.mentions[]` | `{start: Int, length: Int, number: String, uuid: String, name: String}` | UTF-16 offsets |
| `D.attachments[]` | `{id: String, contentType: String, filename: String, size: Int64, width: Int, height: Int}` | `id` must be a string, ideally matching `^[A-Za-z0-9_.-]+$` (5) |
| `D.previews[]` | `{url, title, description: String, image: {id, contentType, filename: String, size: Int64}}` | first valid one wins (https URL with a host and a non-empty title); ignored for viewOnce (`Sources/CorvusCore/LinkPreviewRecords.swift:47-61`) |
| `D.sticker` | `{packId (or packID): String hex, stickerId (or id): Int}` | replaces attachments with a sticker reference |
| `D.pollCreate` | `{question: String, allowMultiple: Bool (absent=true), options: [String]}` | text fallback "📊 question" |
| `D.quote` | `{id: Int64, authorNumber \| authorUuid \| author: String, text: String, attachments: [{contentType: String}]}` | only first attachment's contentType is used |
| `D.storyContext` | `{authorNumber \| authorUuid: String, sentTimestamp: Int64}` | story reply (when no quote) |
| `D.contacts[]` | shared contact (below) | |
| `D.payment` | `{note: String}` | presence = payment notice (must be a JSON object) |

Shared contact (`Sources/CorvusCore/MessageContent.swift:67-98`):
`name.{given, family, middle, prefix, suffix, nickname | display}: String`, `organization: String`,
`phone[]` / `email[]`: `{value, type (HOME|MOBILE|WORK|CUSTOM), label}`,
`address[]`: `{street, pobox, neighborhood, postcode, city, region, country}` or a String,
`avatar.attachment.id: String` (the picture is read **only** from the local attachments dir, never via RPC).

Corvus persists `attachments[].id`, `previews[].image.id` and contact `avatar.attachment.id` in its encrypted history and
later resolves them with `getAttachment {id}` / the attachments dir. **Old histories therefore contain signal-cli attachment ids.**

### 4.3 Edits — `parseEdit`, `Envelope.swift:327-343`

`$.editMessage` (incoming) or `$.syncMessage.sentMessage.editMessage` (own other device):
`{targetSentTimestamp: Int64, dataMessage: {timestamp: Int64, message: String (required, non-empty), textStyles|textStyle, mentions, groupInfo.groupId}}`.
Only text/styles/mentions are applied; attachments/previews of edits are ignored. Applied only to a message from the same author.

### 4.4 Stories — `parseStory`, `Envelope.swift:65-95`

`$.storyMessage` (incoming; author = source) or `$.syncMessage.sentStoryMessage` (own). Story ts = **`$.timestamp`**.

| path | type |
|---|---|
| `allowsReplies` | Bool (absent = true) |
| `groupId` | String (group story) |
| `fileAttachment.{id, contentType, filename, size, width, height}` | as attachments |
| `textAttachment.text` | String |
| `textAttachment.textForegroundColor` | String color |
| `textAttachment.backgroundColor` (fallback `textBackgroundColor`) | String color |
| `textAttachment.backgroundGradient.colors[]` (fallback `startColor`/`endColor`) | String colors |
| `textAttachment.preview.url` | String |

Valid if ts > 0 and (fileAttachment or non-empty text). Kept in memory only (24 h). Story media fetched with `getAttachment`.

### 4.5 Sync sent message

`$.syncMessage.sentMessage` = `D` fields (4.2) **flattened into the sentMessage object** (signal-cli's `JsonSyncDataMessage`
shape), plus `destinationNumber` → `destination` → `destinationUuid` (String, first non-empty) for 1:1 chats, plus optional
`editMessage` (4.3). Marked outgoing; author = own account.

### 4.6 `receiptMessage` — `Receipts.swift:32-44`

`$.receiptMessage.{when: Int64, isDelivery: Bool, isRead: Bool, isViewed: Bool, timestamps: [Int64]}`; sender from
`$.sourceNumber|sourceUuid|source`; time = `$.timestamp` (fallback `when`). Read or viewed ⇒ status 2, delivery ⇒ 1;
ignored if status 0, no sender or no timestamps.

### 4.7 `typingMessage` — `Typing.swift:20-32`

`$.typingMessage.{action: "STARTED"|"STOPPED" (case-insensitive), timestamp: Int64, groupId?: String}`; sender as above.
A STARTED without STOPPED expires after 15 s locally.

### 4.8 `callEvent` notification — `Calls.swift:359-410`

`params.result`:

| field | type | notes |
|---|---|---|
| `callId` | Int64 | |
| `state` | String | `IDLE`, `RINGING_INCOMING`, `RINGING_OUTGOING`, `CONNECTING`, `CONNECTED`, `RECONNECTING`, `ENDED`; unknown ⇒ event ignored |
| `number` | String | peer (preferred) |
| `uuid` | String | peer fallback |
| `isOutgoing` | Bool | |
| `inputDeviceName`, `outputDeviceName` | String? | override `signal_input`/`signal_output` |
| `reason` | String | on `ENDED` (stored in call history; "busy", "declined", "hangup" are Corvus-local) |

A new `callId` is only accepted in state `RINGING_INCOMING`. `CONNECTED` starts the audio bridge; `ENDED` tears down.

---

## 5. Files Corvus reads directly from signal-cli's data directory

| path | read where | purpose | notes |
|---|---|---|---|
| `~/.local/share/signal-cli/avatars/` (directory existence) | `AppModel.swift:1874`, `:1941`, `signalCliAvatarDir` `:1887-1889` | **mode switch**: if the dir exists, avatars are read from files only and `getAvatar` is never called | hard-coded `~/.local/share`, **ignores `$XDG_DATA_HOME`** |
| `…/avatars/contact-<number\|uuid>` then `…/avatars/profile-<number\|uuid>` | `AppModel.swift:1893-1936` | contact avatar | key = conversation key; file absent ⇒ placeholder |
| `…/avatars/group-<groupId with + → -, / → _>` | same | group avatar | URL-safe base64, padding kept |
| `…/avatars/profile-<own account>` | `AppModel.swift:2007` | own avatar (Settings → Profile), then `getAvatar {profile}` fallback | |
| `~/.local/share/signal-cli/attachments/<id>` | `MediaDisplay.swift:154-160` (`signalCliAttachmentURL`), used by `AppModel.fetchAttachmentData` `:1718`, `videoFile` `MediaDisplay.swift:140`, contact-card avatar `MessageContentViews.swift:248` | received attachments read in place (no base64 over RPC); videos are played directly from this file | id must match `^[A-Za-z0-9_.-]+$`, not start with `.`; hard-coded path, ignores XDG. Contact-card avatars have **no RPC fallback**. |
| `$XDG_DATA_HOME/signal-cli` or `~/.local/share/signal-cli` → `data/accounts.json` | `Sources/CorvusCore/SignalCliAccount.swift:6-34`, used `AppChromeSettings.swift:156` | `{"accounts":[{"number","uuid","path"}]}` → `data/<path>` JSON `{"deviceId": Int}` | "Delete all data" refuses on primary device (`deviceId == 1`) or when unknown (nil) |
| `~/Library/Caches/io.github.corvus.mac/signal-cli-*.jsa` | written by the JVM via `JAVA_OPTS` | CDS archive | not read by Swift |

Stickers are never read from disk (always `getSticker`). The Rust backend should either keep this exact on-disk layout
(attachments stored as `<dataDir>/attachments/<id>` with filename-safe ids; avatars as `contact-/profile-/group-` files under
`<dataDir>/avatars`) or the Swift paths above must be changed (preferably to a backend-reported data dir, or RPC-only).
Note the avatars **directory existence** toggles behavior: if the new backend has no such dir, `getAvatar` must work.

---

## 6. signal-cli-specific code to delete or replace

### 6.1 Updater (delete)
- `Sources/CorvusMac/SignalCliUpdater.swift` (whole file: GitHub release check, tarball install, `brew upgrade`, 12 h loop).
- `Sources/CorvusCore/SignalCliUpdate.swift` and `Tests/CorvusCoreTests/SignalCliUpdateTests.swift`.
- `AppModel.swift:74` `updateHint`, `:76` `updatingCli`, `:77` `updateChecksStarted`; `:461` `startUpdateChecks()` call;
  `AppModel.swift:2070-2078` `compareVersions` (only if no other user).
- `Sources/CorvusMac/ContentView.swift:710-715` "signal-cli X available" link.
- `Sources/CorvusMac/SettingsView.swift:28` (`@AppStorage(AppModel.autoUpdateKey)`), `:34-48` (Section "signal-cli": path,
  version, Choose/Reconnect/Check for update, auto-update toggle; keep a Reconnect button somewhere).
- `Sources/CorvusMac/App.swift:245-247` menu items "Check for signal-cli update", "Voice call setup …" (if calls change),
  "signal-cli on GitHub".
- UserDefaults keys: `signalCliAutoUpdate`.

### 6.2 Process launch / executable management (replace)
- `Sources/CorvusCore/SignalCli.swift`: `autodetect` (65), `configure` helper indirection (77-88), `childEnvironment`
  (92-102, keep PATH logic only if still needed), `isJavaLauncher` (105), `javaEnvironment`/CDS (114-127),
  `run`/`runBlocking`/`versionLine`/`queryVersion`/`queryAccounts`/`parseAccounts` (136-246, unless the Rust binary keeps
  `--version` / `-o json listAccounts`), App Nap comment (53-55). The JSON-RPC core (`start`/`call`/`handleLine`) can stay.
  Class/strings named "signal-cli" ("signal-cli is not running", "signal-cli exited …", `CliResult.describe`).
- `Sources/CorvusMac/AppModel.swift`: `startCliEarly` (257-267, JVM-motivated; still useful), `ensureExecutable` /
  `pickExecutable` / `chooseExecutable` (304-338) and UserDefaults `executable`, `executableStamp` + keys
  `cliVersion.<path>.<mtime>` (348-351), quick-start vs full check in `connectAccount` (378-454, Java start-up cost was the
  reason), `showCliProblem` text about Java (464-474), `setConnected` status "Connected · signal-cli <version>" (480),
  `showAbout` text (2080-2087).
- `Sources/CorvusMac/LinkView.swift`: process-based `link` (70-128) — keep if the Rust binary offers `link -n`, otherwise
  switch to RPC (`startLink`/`finishLink`-style).
- `Sources/CorvusMac/AppChromeSettings.swift`: `ProxySetting` key `signalCli.tlsProxy` (52-61) and the "not supported by
  signal-cli" caption (90); `deleteAllLocalData` (153-206) uses `deleteLocalAccountData --ignore-registered` and
  `SignalCliAccountData.deviceId`; `explainUnlink` text (138-148).
- `Sources/CorvusCore/SignalCliAccount.swift`: `SignalCliAccountData` (whole enum); `SignalProxy` (keep if `--tls-proxy` stays).
  Tests: `AppChromeTests.swift:188-230`.
- `Sources/CorvusMac/Media.swift:53-71` `stageForSignalCli` (copies files to `$TMPDIR/corvus-<pid>/send-<uuid>/<i>/<name>`
  because the helper app may lack TCC access to Desktop/Documents). A direct child process shares the app's TCC
  responsibility, so staging can go, but it is harmless; callers: `AppModel.swift:1388`, `MessageActions.swift:81`,
  `Features.swift:362,490`, `GroupSettings.swift:67`, `ProfileEditor.swift:271`.
- `Sources/CorvusMac/MediaDisplay.swift:152-160` `signalCliAttachmentURL` and `AppModel.swift:1887-1899`
  `signalCliAvatarDir`/`avatarFileNames` (hard-coded `~/.local/share/signal-cli`, see section 5).
- `Sources/CorvusMac/Calls.swift:32-75` `CallSetup` (finds `signal-call-tunnel` next to the signal-cli executable, via
  `$SIGNAL_CALL_TUNNEL_BIN` or PATH; BlackHole setup instructions; "needs signal-cli 0.14.2" strings at 276-278, 297, 427).
- `Sources/CorvusMac/RosterCache.swift` comments only (format = raw listContacts/listGroups; keep shapes stable or bump cache).

### 6.3 Helper app and build (delete for the macOS Swift build; `src/SignalCliHelper.cpp` is shared with the Qt app)
- `src/SignalCliHelper.cpp`, `packaging/macos/SignalCliHelper.plist.in`, `packaging/macos/check-signal-cli-helper.sh`.
- `macos/scripts/build-app.sh:3` (comment), `:59-65` (build helper into `Contents/Helpers/corvus-signal-cli.app`),
  `:74` (sign helper). Add instead: `cargo build --release` of the Rust backend and copy it into
  `Contents/Helpers/` (or `Contents/MacOS/`), sign it like `corvus-signal-import` (`:67-71`).
- `CMakeLists.txt:170-191` (Qt build embeds the same helper; only if the Qt app also drops signal-cli).
- `macos/Support/Info.plist:30-33` comment about the helper; `LSFileQuarantineEnabled` itself: if the Rust backend is
  launched as a direct child it **inherits quarantine**, so every attachment/avatar file it writes gets the
  `com.apple.quarantine` xattr. That is fine for data files (arguably desirable) but would break loading unsigned dylibs;
  a statically linked Rust binary is unaffected. `:41` copyright string "signal-cli is a separate program".
- `macos/README.md` lines 8, 13, 18, 23, 48-49, 58.

### 6.4 Tests and mock
- `tests/mock-signal-cli.py` (use as the conformance fixture for the Rust backend, then retarget).
- `Tests/CorvusCoreTests/CoreTests.swift:92-101` (`SignalCliHelperTests`: parseAccounts, maskNumbers),
  `:401+` (`SignalCliProcessTests` against the mock), `:1341+` (group/block/request methods against the mock).
- Debug env vars: `SIGNAL_CLI_MAC_TEST_PASSPHRASE` (`AppModel.swift:635`), `SIGNAL_CLI_MAC_DEBUG_COMMANDS`
  (`Sources/CorvusMac/DebugHooks.swift:15`), `CORVUS_NO_CDS`, `SIGNAL_CALL_TUNNEL_BIN`.

### 6.5 User-visible strings mentioning signal-cli (rename)
`QuickSend.swift:11`, `MessageActions.swift:71`, `AppModel.swift:1351`, `ChatPopup.swift:165` ("Not connected to signal-cli"),
`ContactDetails.swift:167`, `ProfileEditor.swift:79`, `GroupViews.swift:107`, `Groups.swift:80,109`, `StickerCreator.swift:28`,
`AppModel.swift:308-314,412,427,466-468`, `AppChromeSettings.swift:90,159,175,186`, `Calls.swift:63-73,276,278,297,427`,
`LinkView.swift:77,126`.

---

## 7. Gotchas for the Rust implementation (summary)

1. Numeric JSON-RPC ids only; responses must not contain `method`; error must have a string `message`.
2. Stdout = JSON lines only; stderr lines become UI toasts. Never print logs there in normal operation.
3. Start receiving immediately after `-a X jsonRpc`; push `{"jsonrpc":"2.0","method":"receive","params":{"envelope":{…}}}`.
4. Parameter shape inconsistencies to reproduce exactly: `recipient` is an **array** for `send`, `sendReaction`, `sendTyping`,
   `sendPinMessage`, `sendUnpinMessage`, polls, `getAttachment`, `block`/`unblock`, `sendMessageRequestResponse`; a **string**
   for `updateContact`, `removeContact`, `trust`, `sendReceipt`, `startCall`; `listIdentities` uses `number`.
   `groupId` is a **string** in `R`, `updateGroup`, `quitGroup`, `sendStory`, `getAvatar`, `sendMessageRequestResponse`; an
   **array** for `block`/`unblock` and `listGroups`. `remoteDelete` uses `recipients`/`groupIds` (arrays).
5. All offsets (`textStyle`, `mention`, `mentions`, `textStyles`) are UTF-16 code units.
6. Attachment ids are opaque strings that Corvus stores forever; keep them filename-safe and resolvable by `getAttachment`
   (including ids created by signal-cli in existing histories, or accept that those become unavailable).
7. `listContacts` should include `isArchived`, `isHidden`, `profileName`/`name`, `messageExpirationTime`, nickname/note fields
   and, for the own account, `username` + `profile.*`.
8. `listGroups` `isMember:false` + self in `pendingMembers` drives group invitations; `updateGroup {groupId}` must accept them.
9. `subscribeCallEvents` succeeding is the only feature flag for calls; return an error if calls are not implemented.
10. `--version` first line's last token is the displayed version; `-o json listAccounts` must print `[{"number":"+…"}]`.
