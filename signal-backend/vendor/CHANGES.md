# Local changes to the vendored crates

## libsignal-service-rs

- `MessageSender::send_message_to_group` sends to up to 16 members at a time instead of one after the
  other (a first message to a large group took minutes while sessions were set up device by device).
- Sender keys for group messages (`sender/sender_key.rs`): `send_message_to_group_with_sender_key`
  encrypts once with our sender key and sends one sealed-sender multi-recipient request
  (`PUT /v1/messages/multi_recipient`, authorized with the XOR of the members' access keys) to the
  members with an access key; members get the key first in a 1:1 sender key distribution message
  (`distribute_sender_key`, also usable ahead of a message). Members it cannot reach, changed devices
  (409/410) and refused requests fall back to the per-member send. `try_send_content` sends an
  encoded `Content` (the distribution message has no body).
- `MessageSender::resend_message` (in `sender/repair.rs`) answers retry requests: see presage below.

## presage

- `Received::RetryRequest { requester, timestamp }`: a recipient could not decrypt our message and asked
  for it again. The session is replaced as before; the client then sends the message again with
  `Manager::resend_message` (same timestamp, profile key and disappearing-message timer, no sync
  transcript) if its send log still has it.
- `Manager::send_message_to_group_sender_key` and `Manager::prepare_group_sender_key`: group sends
  with the client's `SenderKeyState` (distribution id, devices that have the key).

## presage-store-sqlite

- `SqliteStore::sticker_pack_summary`: title, author and stickers of one pack, read in SQLite.
- A new database file is switched to WAL on one connection before the pool opens its three
  (connections switching the journal mode together failed with "database is locked").
