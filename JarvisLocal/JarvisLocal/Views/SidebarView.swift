import SwiftUI

struct SidebarView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        VStack(spacing: 0) {
            header
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
            Button(action: { vm.showFacts.toggle() }) {
                Image(systemName: "brain")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(JarvisTheme.textSecondary)
            .help("Mémoire")
            Button(action: { Task { await vm.newConversation() } }) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(JarvisTheme.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(JarvisTheme.panel)
        .overlay(Rectangle().fill(JarvisTheme.divider).frame(height: 1), alignment: .bottom)
    }

    private var conversationList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
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
