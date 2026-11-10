use futures::{
    channel::{
        mpsc::{self, Sender},
        oneshot,
    },
    prelude::*,
};
use prost::Message;

pub use crate::{
    configuration::ServiceCredentials,
    proto::{
        web_socket_message, Envelope, WebSocketMessage,
        WebSocketRequestMessage, WebSocketResponseMessage,
    },
};

use crate::{
    push_service::ServiceError,
    websocket::{self, SignalWebSocket},
};


#[derive(Debug)]
#[allow(clippy::large_enum_variant)]
pub enum Incoming {
    /// An envelope and the handle that acknowledges it to the server when dropped
    /// (Corvus patch: the server is only told once the consumer is done with it).
    Envelope(Envelope, AckHandle),
    QueueEmpty,
}

/// Acknowledges an incoming envelope to the server when dropped (or when [AckHandle::ack] is
/// called). Holding it until the envelope has been handed off means a crash before that point
/// leaves the envelope queued on the server.
pub struct AckHandle {
    responder: Option<(
        oneshot::Sender<WebSocketResponseMessage>,
        WebSocketResponseMessage,
    )>,
}

impl AckHandle {
    /// An ack handle that does nothing, for envelopes that did not come from a websocket.
    pub fn noop() -> Self {
        AckHandle { responder: None }
    }

    /// Acknowledge now.
    pub fn ack(mut self) {
        self.send();
    }

    /// Never acknowledge: the server delivers the envelope again on the next connection.
    pub fn nack(mut self) {
        self.responder.take();
    }

    fn send(&mut self) {
        if let Some((responder, response)) = self.responder.take() {
            if responder.send(response).is_err() {
                tracing::debug!("could not acknowledge envelope: websocket closed");
            }
        }
    }
}

impl Drop for AckHandle {
    fn drop(&mut self) {
        self.send();
    }
}

impl std::fmt::Debug for AckHandle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AckHandle")
            .field("pending", &self.responder.is_some())
            .finish()
    }
}

pub struct MessagePipe {
    ws: SignalWebSocket<websocket::Identified>,
}

impl MessagePipe {
    pub fn from_socket(ws: SignalWebSocket<websocket::Identified>) -> Self {
        MessagePipe { ws }
    }

    /// Return a SignalWebSocket for sending messages and other purposes beyond receiving messages.
    pub fn ws(&self) -> SignalWebSocket<websocket::Identified> {
        self.ws.clone()
    }

    /// Worker task that processes the websocket into Envelopes
    async fn run(
        mut self,
        mut sink: Sender<Result<Incoming, ServiceError>>,
    ) -> Result<(), mpsc::SendError> {
        let mut ws = self.ws.clone();
        let mut stream = ws
            .take_request_stream()
            .expect("web socket request handler not in use");

        while let Some((request, responder)) = stream.next().await {
            // WebsocketConnection::onMessage(ByteString)
            if let Some(env) =
                self.process_request(request, responder).await.transpose()
            {
                sink.send(env).await?;
            } else {
                tracing::trace!("got empty message in websocket");
            }
        }

        ws.return_request_stream(stream);

        Ok(())
    }

    async fn process_request(
        &mut self,
        request: WebSocketRequestMessage,
        responder: oneshot::Sender<WebSocketResponseMessage>,
    ) -> Result<Option<Incoming>, ServiceError> {
        // Java: MessagePipe::read
        let response = WebSocketResponseMessage::from_request(&request);

        // XXX Change the signature of this method to yield an enum of Envelope and EndOfQueue
        if request.is_signal_service_envelope() {
            let body = if let Some(body) = request.body.as_ref() {
                body
            } else {
                return Err(ServiceError::InvalidFrame {
                    reason: "request without body.",
                });
            };
            let envelope = Envelope::decode(body.as_slice())?;
            // Corvus patch: acknowledge only when the consumer drops the handle.
            return Ok(Some(Incoming::Envelope(
                envelope,
                AckHandle {
                    responder: Some((responder, response)),
                },
            )));
        }
        let result = if request.is_queue_empty() {
            Some(Incoming::QueueEmpty)
        } else {
            None
        };

        responder
            .send(response)
            .map_err(|_| ServiceError::WsClosing {
                reason: "could not respond to message pipe request",
            })?;

        Ok(result)
    }

    /// Returns the stream of `Envelope`s
    ///
    /// Envelopes are acknowledged when their [AckHandle] is dropped.
    pub fn stream(self) -> impl Stream<Item = Result<Incoming, ServiceError>> {
        let (sink, stream) = mpsc::channel(1);

        let stream = stream.map(Some);
        let runner = self.run(sink).map(|e| {
            tracing::info!("sink was closed: {:?}", e);
            None
        });

        let combined = futures::stream::select(stream, runner.into_stream());
        combined.filter_map(|x| async { x })
    }
}
