import SwiftUI
import JarvisCore

/// Sidebar native (recette Apple) : `List` style sidebar — le système fournit le
/// verre, la surbrillance de sélection et l'adaptation au mode clair/sombre.
/// Aucun fond custom, aucune pastille manuelle : le chrome vient du système,
/// le contenu (chat) garde l'identité HUD.
/// Les actions (recherche, mémoire, aide, nouvelle conversation) vivent dans la
/// toolbar (ContentView) ; les sheets aussi.
struct SidebarView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        List(selection: selection) {
            Section("Conversations") {
                if vm.conversations.isEmpty {
                    Text("Aucune conversation")
                        .foregroundStyle(.secondary)
                }
                ForEach(vm.conversations) { conv in
                    ConversationRowView(conversation: conv)
                        .tag(conv.id)
                }
            }
            if vm.showFacts {
                Section {
                    if vm.facts.isEmpty {
                        Text("Aucun fait mémorisé.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(vm.facts) { fact in
                        HStack {
                            Text(fact.key + " :")
                                .font(JarvisTheme.mono(11))
                                .foregroundStyle(JarvisTheme.accent)
                            Text(fact.value)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            Button(action: { Task { await vm.deleteFact(fact) } }) {
                                Image(systemName: "xmark")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Oublier le fait \(fact.key)")
                        }
                    }
                } header: {
                    HStack {
                        Text("Mémoire")
                        Spacer()
                        Button("Tout effacer") {
                            Task { await vm.clearAllFacts() }
                        }
                        .font(.caption2)
                        .foregroundStyle(JarvisTheme.danger)
                    }
                }
                .task { await vm.loadFacts() }
            }
        }
        .listStyle(.sidebar)
    }

    /// Sélection native : le highlight vient du système, pas d'un fond custom.
    private var selection: Binding<Int?> {
        Binding(
            get: { vm.currentConversation?.id },
            set: { id in
                guard let id, let conv = vm.conversations.first(where: { $0.id == id }) else { return }
                Task { await vm.selectConversation(conv) }
            }
        )
    }
}
