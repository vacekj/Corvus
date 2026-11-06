import AppKit
import CorvusCore
import SwiftUI

/// The @mention suggestions of the composer (groups only). The message field updates it while typing;
/// ↑/↓ move, Return or Tab insert "@Name", Esc hides the list. Sending turns every "@Name" of a member
/// into a Signal mention (`resolveMentions`, signal-cli `mention` "start:length:recipient").
@MainActor @Observable
final class MentionAutocomplete {
    static let shared = MentionAutocomplete()

    private(set) var suggestions: [MentionCandidate] = []
    private(set) var index = 0
    @ObservationIgnored private(set) var range: NSRange?
    @ObservationIgnored private var dismissedAt: Int?      // Esc: stays hidden for this "@"
    @ObservationIgnored var insert: ((MentionCandidate) -> Void)?

    var active: Bool { !suggestions.isEmpty }
    var selected: MentionCandidate? { suggestions.indices.contains(index) ? suggestions[index] : nil }

    func show(range r: NSRange, _ list: [MentionCandidate]) {
        range = r
        if dismissedAt == r.location { return }
        dismissedAt = nil
        if list != suggestions {
            suggestions = list
            if index != 0 { index = 0 }
        }
    }

    func hide() {
        range = nil
        dismissedAt = nil
        if !suggestions.isEmpty { suggestions = [] }
        if index != 0 { index = 0 }
    }

    func dismiss() {
        let at = range?.location
        hide()
        dismissedAt = at
    }

    func move(_ step: Int) {
        guard !suggestions.isEmpty else { return }
        index = (index + step + suggestions.count) % suggestions.count
    }
}

extension AppModel {
    /// Members of a group who can be mentioned (not ourselves; people known only by their UUID are left out).
    func mentionCandidates(_ key: String) -> [MentionCandidate] {
        guard let g = roster.groups[key] else { return [] }
        return g.members.compactMap { m in
            guard !isSelf(m.id) else { return nil }
            let name = memberName(m.id)
            if name == m.uuid || name.isEmpty { return nil }
            return MentionCandidate(name: name, id: m.uuid.isEmpty ? m.number : m.uuid)
        }
    }
}

/// The member list above the composer while an "@…" is typed.
struct MentionSuggestionList: View {
    @Environment(AppModel.self) private var model
    private let ac = MentionAutocomplete.shared

    var body: some View {
        if ac.active {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(ac.suggestions.enumerated()), id: \.element.id) { i, c in
                    HStack(spacing: 8) {
                        AvatarView(image: avatar(c), size: 22)
                        Text(c.name).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(i == ac.index ? Theme.signalBlue.opacity(0.22) : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { ac.insert?(c) }
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field))
            .accessibilityLabel("Mention suggestions")
        }
    }

    private func avatar(_ c: MentionCandidate) -> NSImage {
        let key = model.chats.resolveKey(c.id)
        return model.avatars[key] ?? Media.placeholderAvatar(key: key, title: c.name)
    }
}
