import CorvusCore
import SwiftUI

/// "Choose a new admin": the only admin leaving a group picks who takes over.
struct SuccessorSheet: View {
    @Environment(AppModel.self) private var model
    let pick: SuccessorPick
    @State private var filter = ""
    @State private var selected: String?

    var body: some View {
        let people = People.sortedMembers(pick.candidates, isSelf: { _ in false }, name: { model.memberName($0.id) })
            .map { (member: $0, person: model.memberPerson($0)) }
            .filter { People.matches(filter, name: $0.person.title, detail: $0.person.detail, number: $0.member.number) }
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a new admin").font(.title3.weight(.semibold))
            Text("You are the only admin. Who should take over?").foregroundStyle(.secondary)
            SearchField(text: $filter, prompt: "Search members")
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(people, id: \.member) { p in
                        PickerRow(person: p.person, checked: selected == p.member.id)
                            .onTapGesture { selected = p.member.id }
                    }
                }
            }
            .frame(height: 300)
            .overlay {
                if people.isEmpty { Text("No one matches “\(filter)”").foregroundStyle(.secondary) }
            }
            HStack {
                Spacer()
                Button("Cancel") { model.finishSuccessorPick(nil) }.keyboardShortcut(.cancelAction)
                Button("Leave group", role: .destructive) { model.finishSuccessorPick(selected) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
