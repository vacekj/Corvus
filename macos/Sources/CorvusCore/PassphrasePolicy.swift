import Foundation

/// Rules for the passphrase of the encrypted chat history (shared by the unlock dialogs and Settings).
public enum PassphrasePolicy {
    public static let minLength = 8

    /// Why a new passphrase cannot be used yet, or nil when it is acceptable. An empty repeat field is
    /// not reported as a mismatch (the user has not typed it yet) but still blocks.
    public static func problem(new: String, repeated: String) -> String? {
        if new.isEmpty { return "" }
        if new.count < minLength { return "Use at least \(minLength) characters." }
        if repeated.isEmpty { return "" }
        if repeated != new { return "The passphrases do not match." }
        return nil
    }

    public static func isAcceptable(new: String, repeated: String) -> Bool { problem(new: new, repeated: repeated) == nil }
}
