import Foundation

/// The chat list line of a chat with an unsent draft ("Draft: …").
public enum DraftPreview {
    public static func text(_ draft: String, attachments: Int = 0) -> String? {
        let t = draft.prefix(200).replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { return "Draft: " + t }
        if attachments > 0 { return attachments == 1 ? "Draft: 📎 Attachment" : "Draft: 📎 \(attachments) attachments" }
        return nil
    }
}
