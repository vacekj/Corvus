use libsignal_service::{messagepipe::AckHandle, prelude::Content, protocol::ServiceId};

#[derive(Debug)]
pub enum Received {
    /// when the receive loop is empty, happens when opening the websocket for the first time
    /// once you're done synchronizing all pending messages for this registered client.
    QueueEmpty,

    /// Got contacts (only applies if linked to a primary device
    /// Contacts can be later queried in the store.
    ///
    /// Corvus patch: no longer yielded; the contacts sync arrives as [Received::Content] after the
    /// contacts were stored.
    Contacts,

    // Failed to receive a message from the specified service ID.
    // A session reset with the contact may fix this.
    DecryptionError(ServiceId),

    /// Corvus patch: `requester` could not decrypt our message sent at `timestamp` and asked for it
    /// again. The broken session was already replaced; the client sends the message again if it
    /// still has it ([crate::Manager::resend_message]).
    RetryRequest { requester: ServiceId, timestamp: u64 },

    /// Incoming decrypted message with metadata and content.
    ///
    /// Corvus patch: the envelope is acknowledged to the server when the [AckHandle] is dropped,
    /// so the consumer can hand the message off before the server forgets it.
    Content(Box<Content>, AckHandle),
}
