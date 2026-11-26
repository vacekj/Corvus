use crate::{
    push_service::response::error_mapper,
    sender::{OutgoingPushMessages, SendMessageResponse},
    unidentified_access::UnidentifiedAccess,
    utils::BASE64_RELAXED,
};

use super::*;
use base64::Engine;

// Signal-Server: controllers/MessageController.java:198
// (PUT /v1/messages/{destination})
error_mapper! {
    put_messages_errors:
        // 409: mismatched devices, MessageController.java:426
        CONFLICT => MismatchedDevicesException(crate::push_service::MismatchedDevices),
        // 410: stale devices, MessageController.java:421
        GONE => StaleDevices(crate::push_service::StaleDevices),
        // 413: message too large, MessageController.java:433
        PAYLOAD_TOO_LARGE => MessageTooLarge,
        // 404: unregistered recipient, MessageController.java:316
        NOT_FOUND => UnregisteredRecipient,
        // 428: proof required, MessageController.java:365
        PRECONDITION_REQUIRED => ProofRequiredError(crate::push_service::ProofRequired),
}

// Signal-Server: controllers/MessageController.java:466
// (PUT /v1/messages/multi_recipient)
error_mapper! {
    put_multi_recipient_messages_errors:
        // 409: mismatched devices, MessageController.java:670
        CONFLICT => MultiRecipientMismatchedDevices(Vec<crate::push_service::AccountMismatchedDevices>),
        // 410: stale devices, MessageController.java:685
        GONE => MultiRecipientStaleDevices(Vec<crate::push_service::AccountStaleDevices>),
        // 413: message too large, MessageController.java:660
        PAYLOAD_TOO_LARGE => MessageTooLarge,
        // 428: proof required, MessageController.java:638
        PRECONDITION_REQUIRED => ProofRequiredError(crate::push_service::ProofRequired),
}

/// Corvus: the answer to a multi-recipient send.
#[derive(Debug, Default, serde::Deserialize)]
pub struct SendMultiRecipientResponse {
    /// Recipients that are not registered (any more); nothing was delivered to them.
    #[serde(default)]
    pub uuids404: Vec<String>,
}

impl SignalWebSocket<Unidentified> {
    /// Corvus: sends one sealed-sender multi-recipient message (as made by libsignal's
    /// `sealed_sender_multi_recipient_encrypt`) to all its recipients, authorized with the XOR
    /// of their unidentified access keys.
    pub async fn send_multi_recipient_message(
        &mut self,
        payload: Vec<u8>,
        combined_access_key: &[u8],
        timestamp: u64,
        online: bool,
    ) -> Result<SendMultiRecipientResponse, ServiceError> {
        let mut request = WebSocketRequestMessage::new(Method::PUT)
            .path(format!(
                "/v1/messages/multi_recipient?ts={timestamp}&online={online}&urgent=true&story=false"
            ))
            .header(
                "Unidentified-Access-Key",
                BASE64_RELAXED.encode(combined_access_key),
            )
            .header("content-type", "application/vnd.signal-messenger.mrm")
            .build();
        request.body = Some(payload);
        self.request_json_with(request, put_multi_recipient_messages_errors)
            .await
    }
}

impl<C: WebSocketType> SignalWebSocket<C> {
    pub async fn send_messages(
        &mut self,
        messages: OutgoingPushMessages,
    ) -> Result<SendMessageResponse, ServiceError> {
        let request = WebSocketRequestMessage::new(Method::PUT)
            .path(format!(
                "/v1/messages/{}",
                messages.destination.service_id_string()
            ))
            .json(&messages)?;
        self.request_json_with(request, put_messages_errors).await
    }

    pub async fn send_messages_unidentified(
        &mut self,
        messages: OutgoingPushMessages,
        access: &UnidentifiedAccess,
    ) -> Result<SendMessageResponse, ServiceError> {
        let request = WebSocketRequestMessage::new(Method::PUT)
            .path(format!(
                "/v1/messages/{}",
                messages.destination.service_id_string()
            ))
            .header(
                "Unidentified-Access-Key",
                BASE64_RELAXED.encode(&access.key),
            )
            .json(&messages)?;
        self.request_json_with(request, put_messages_errors).await
    }
}
