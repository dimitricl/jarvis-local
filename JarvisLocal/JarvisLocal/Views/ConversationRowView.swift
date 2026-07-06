import SwiftUI

struct ConversationRowView: View {
    @Environment(AppViewModel.self) private var vm
    let conversation: Conversation
    @State private var isEditing = false
    @State private var editTitle = ""

    var body: some View {
        HStack {
            if isEditing {
                TextField("Titre", text: $editTitle)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(JarvisTheme.textPrimary)
                    .onSubmit(commitRename)
                    .onExitCommand { isEditing = false }
            } else {
                Text(conversation.title)
                    .font(.caption)
                    .foregroundStyle(JarvisTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            if conversation.id == vm.currentConversation?.id {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(JarvisTheme.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(conversation.id == vm.currentConversation?.id ? JarvisTheme.accent.opacity(0.12) : Color.clear)
        .onTapGesture(count: 2) {
            editTitle = conversation.title
            isEditing = true
        }
        .contextMenu {
            Button("Renommer") {
                editTitle = conversation.title
                isEditing = true
            }
            Button("Supprimer", role: .destructive) {
                Task { await vm.deleteConversation(conversation) }
            }
        }
    }

    private func commitRename() {
        let title = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            Task { await vm.renameConversation(id: conversation.id, title: title) }
        }
        isEditing = false
    }
}
