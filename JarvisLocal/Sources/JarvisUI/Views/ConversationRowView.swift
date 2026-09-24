import SwiftUI
import JarvisCore

/// Ligne de conversation en style système : dans une `List` sidebar native, la
/// sélection, le survol et l'adaptation clair/sombre viennent du système.
/// Aucune couleur/typo custom ici — c'est du chrome, pas du contenu.
struct ConversationRowView: View {
    @Environment(AppViewModel.self) private var vm
    let conversation: Conversation
    @State private var isEditing = false
    @State private var editTitle = ""

    var body: some View {
        // Barre d'accent de sélection (2.5pt) : List reste le conteneur natif
        // (clavier / VoiceOver / highlight système conservés) — la barre est
        // le marqueur distinctif, pas un remplacement du comportement natif.
        // Contenu (titre) inchangé, barre décorative ignorée par VoiceOver.
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.25)
                .fill(isSelected ? JarvisTheme.accent : Color.clear)
                .frame(width: 2.5)
                .accessibilityHidden(true)
            rowContent
        }
    }

    private var rowContent: some View {
        HStack {
            if isEditing {
                TextField("Titre", text: $editTitle)
                    .textFieldStyle(.plain)
                    .onSubmit(commitRename)
                    .onExitCommand { isEditing = false }
            } else {
                Text(conversation.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
        }
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

    private var isSelected: Bool {
        vm.currentConversation?.id == conversation.id
    }

    private func commitRename() {
        let title = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            Task { await vm.renameConversation(id: conversation.id, title: title) }
        }
        isEditing = false
    }
}
