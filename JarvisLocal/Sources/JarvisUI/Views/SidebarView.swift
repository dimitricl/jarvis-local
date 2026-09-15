import SwiftUI
import JarvisCore

struct SidebarView: View {
    @Environment(AppViewModel.self) private var vm
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            quickActions
            conversationList
            factsPanel
        }
        .background(JarvisTheme.background)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bolt.fill")
                .font(.caption)
                .foregroundStyle(JarvisTheme.accent)
            Text("JARVIS")
                .font(JarvisTheme.mono(13, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(JarvisTheme.textPrimary)
            Spacer()
            Button(action: { vm.showSearch.toggle() }) {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(JarvisTheme.textSecondary)
            .help("Rechercher dans les conversations (/search)")
            .accessibilityLabel("Rechercher dans les conversations")
            Button(action: { vm.showHelp.toggle() }) {
                Image(systemName: "questionmark.circle")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(JarvisTheme.textSecondary)
            .help("Aide des commandes (/help)")
            .accessibilityLabel("Aide des commandes")
            Button(action: { vm.showFacts.toggle() }) {
                Image(systemName: "brain")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(JarvisTheme.textSecondary)
            .help("Mémoire")
            .accessibilityLabel("Afficher la mémoire des faits")
            Button(action: { Task { await vm.newConversation() } }) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(JarvisTheme.textSecondary)
            .accessibilityLabel("Nouvelle conversation")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(JarvisTheme.panel)
        .overlay(Rectangle().fill(JarvisTheme.divider).frame(height: 1), alignment: .bottom)
    }

    private var quickActions: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(JarvisTheme.textTertiary)
                TextField("Rechercher…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(JarvisTheme.textPrimary)
                    .accessibilityLabel("Rechercher dans les conversations")
                    .onSubmit {
                        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !q.isEmpty else { return }
                        vm.searchQuery = q
                        vm.showSearch.toggle()
                        Task { await vm.search(q) }
                    }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(JarvisTheme.panelElevated)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Button(action: { Task { await vm.newConversation() } }) {
                Label("Nouvelle conversation", systemImage: "plus")
                    .font(.caption)
                    .foregroundStyle(JarvisTheme.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(JarvisTheme.accent.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(JarvisTheme.accent.opacity(0.3), lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var conversationList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if vm.conversations.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .foregroundStyle(JarvisTheme.textTertiary)
                        Text("Aucune conversation")
                            .font(.caption)
                            .foregroundStyle(JarvisTheme.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 30)
                }
                ForEach(vm.conversations) { conv in
                    ConversationRowView(conversation: conv)
                        .contentShape(Rectangle())
                        .onTapGesture { Task { await vm.selectConversation(conv) } }
                }
            }
        }
    }

    private var factsPanel: some View {
        Group {
            if vm.showFacts {
                Rectangle().fill(JarvisTheme.divider).frame(height: 1)
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "brain")
                            .foregroundStyle(JarvisTheme.amber)
                        Text("MÉMOIRE")
                            .font(JarvisTheme.mono(10, weight: .semibold))
                            .tracking(0.5)
                            .foregroundStyle(JarvisTheme.textSecondary)
                        Spacer()
                        Button("Tout effacer") {
                            Task { await vm.clearAllFacts() }
                        }
                        .font(.caption2)
                        .buttonStyle(.plain)
                        .foregroundStyle(JarvisTheme.danger)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(JarvisTheme.panel)

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if vm.facts.isEmpty {
                                Text("Aucun fait mémorisé.")
                                    .font(.caption2)
                                    .foregroundStyle(JarvisTheme.textTertiary)
                                    .padding(8)
                            }
                            ForEach(vm.facts) { fact in
                                HStack {
                                    Text(fact.key + " :")
                                        .font(JarvisTheme.mono(11))
                                        .foregroundStyle(JarvisTheme.accent)
                                    Text(fact.value)
                                        .font(.caption2)
                                        .foregroundStyle(JarvisTheme.textPrimary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer()
                                    Button(action: { Task { await vm.deleteFact(fact) } }) {
                                        Image(systemName: "xmark")
                                            .font(.caption2)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(JarvisTheme.textTertiary)
                                    .accessibilityLabel("Oublier le fait \(fact.key)")
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 3)
                            }
                        }
                    }
                    .background(JarvisTheme.background)
                    .frame(maxHeight: 150)
                }
                .task { await vm.loadFacts() }
            }
        }
    }
}
