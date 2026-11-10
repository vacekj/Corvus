# corvus-signal: Corvus's Signal backend (replaces signal-cli)

A single Rust binary built on presage (vendored in `vendor/`). Corvus starts it as a child process and
talks to it with the same JSON-RPC 2.0 protocol, method names, parameter shapes and notification
payloads that signal-cli's `jsonRpc` mode uses. The contract is what Corvus actually uses today,
written down in `docs/corvus-rpc-spec.md` (copied from the survey). Where that spec and signal-cli
disagree, the spec wins.

## Command line (argv-compatible with what Corvus runs today)

    corvus-signal --version                          -> prints "corvus-signal <version>" and exits 0
    corvus-signal [--config DIR] -o json listAccounts -> JSON array: [{"number": "+...", "uuid": "..."}]
    corvus-signal [--config DIR] link -n NAME        -> prints the sgnl://linkdevice?... URI on its own
                                                         stdout line, exits 0 once linked, non-zero on failure
    corvus-signal [--config DIR] -a ACCOUNT jsonRpc  -> JSON-RPC over stdin/stdout until stdin closes
    corvus-signal [--config DIR] -a ACCOUNT deleteLocalAccountData [--ignore-registered]

Global options: `--config DIR` (default `~/Library/Application Support/corvus/signal`),
`--store-key-stdin` (see below), `--tls-proxy URL` (Signal TLS proxy; may be a no-op until implemented).

## Data directory (`--config DIR`)

    DIR/store.db              presage sqlite store, SQLCipher-encrypted (protocol state, contacts, groups,
                              profiles, sticker packs). Message bodies are NOT stored: Corvus keeps history.
    DIR/attachments/<id>      received attachments, downloaded and decrypted on receipt (as signal-cli does);
                              <id> is the `id` field of the attachment in the envelope JSON
    DIR/avatars/contact-<number or uuid>, profile-<number or uuid>, group-<base64url group id>
    DIR/stickers/<packId>/<stickerId>
    DIR/accounts.json         [{"number","uuid","deviceId"}] (Corvus reads deviceId from here)
    DIR/corvus-signal.log     diagnostic log (rotated at 5 MB, never message content or numbers)

## Store key

The store is encrypted with a key Corvus keeps in the macOS keychain. With `--store-key-stdin` the
first line read from stdin is the key (64 hex chars); JSON-RPC starts on the next line. Without it the
store is unencrypted (tests only). Never pass the key in argv or the environment.

## Rules

- stdout carries only JSON-RPC (and the link URI / listAccounts output for those commands). Nothing on
  stderr in normal operation: Corvus shows any stderr line in its status bar.
- Request ids: echo the id exactly. Unknown method -> JSON-RPC error -32601. Failures -> error with a
  human-readable message.
- Incoming envelopes are written to stdout (as `receive` notifications) before they are acknowledged
  to the server.
- Never send anything on the network that the user did not ask for, beyond what Signal Desktop does
  (delivery receipts, sync messages). No link-preview fetching in the backend.

## Layout

    corvus-signal/src/main.rs        argv parsing, subcommands
    corvus-signal/src/rpc.rs         JSON-RPC framing, dispatch table, error type
    corvus-signal/src/manager.rs     presage Manager lifecycle, reconnect, send queue
    corvus-signal/src/receive.rs     receive loop -> envelope JSON, attachment download
    corvus-signal/src/envelope.rs    Content (protobuf) -> signal-cli envelope JSON
    corvus-signal/src/files.rs       data dir layout (attachments, avatars, stickers, accounts.json)
    corvus-signal/src/methods/       one file per area: messaging, contacts, groups, profile,
                                     stickers, identities, account, calls
