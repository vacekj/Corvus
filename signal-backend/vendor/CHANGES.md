# Local changes to the vendored crates

## libsignal-service-rs

- `MessageSender::send_message_to_group` sends to up to 8 members at a time instead of one after the
  other (a first message to a large group took minutes while sessions were set up device by device).
- `MessageSender::resend_message` (in `sender/repair.rs`) answers retry requests: see presage below.

## presage

- `Received::RetryRequest { requester, timestamp }`: a recipient could not decrypt our message and asked
  for it again. The session is replaced as before; the client then sends the message again with
  `Manager::resend_message` (same timestamp, profile key and disappearing-message timer, no sync
  transcript) if its send log still has it.

## presage-store-sqlite

- `SqliteStore::sticker_pack_summary`: title, author and stickers of one pack, read in SQLite.
