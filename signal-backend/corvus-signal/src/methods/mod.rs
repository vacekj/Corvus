//! JSON-RPC methods, one file per area. Each file exports `METHODS`, a dispatch table; adding a
//! method means adding a `method!("name", file::function)` line there (and, for a new file, its
//! table below).

pub mod account;
pub mod calls;
pub mod common;
pub mod contacts;
pub mod group_list;
pub mod groups;
pub mod identities;
pub mod messaging;
pub mod profile;
pub mod stickers;
pub mod storage;
pub mod usernames;

use crate::rpc::Dispatcher;

pub fn dispatcher() -> Dispatcher {
    Dispatcher::new(&[
        messaging::METHODS,
        contacts::METHODS,
        group_list::METHODS,
        groups::METHODS,
        identities::METHODS,
        profile::METHODS,
        stickers::METHODS,
        account::METHODS,
        usernames::METHODS,
        storage::METHODS,
        calls::METHODS,
    ])
}

#[cfg(test)]
mod tests {
    #[test]
    fn every_method_corvus_calls_is_dispatched() {
        // docs/corvus-rpc-spec.md section 3.7
        let spec = [
            "listContacts", "updateContact", "removeContact", "block", "unblock",
            "sendMessageRequestResponse", "listIdentities", "trust", "getAvatar", "listGroups",
            "updateGroup", "quitGroup", "joinGroup", "send", "sendReaction", "remoteDelete",
            "sendTyping", "sendReceipt", "sendPinMessage", "sendUnpinMessage", "sendPollCreate",
            "sendPollVote", "sendPollTerminate", "sendStory", "getAttachment", "listStickerPacks",
            "getSticker", "addStickerPack", "uploadStickerPack", "updateProfile", "updateAccount",
            "subscribeCallEvents", "startCall", "acceptCall", "rejectCall", "hangupCall",
        ];
        let names = super::dispatcher().names();
        for m in spec {
            assert!(names.contains(&m), "{m} is not dispatched");
        }
    }
}
