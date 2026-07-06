import SwiftUI

struct SidebarView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        VStack(spacing: 0) {
            header
            conversationList
            factsPanel
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            Text("⚡ Jarvis")
                .font(.headline)
                .foregroundStyle(.green)
            Spacer()
            Button(action: { vm.showFacts.toggle() }) {
                Image(systemName: "brain")
            }
            .buttonStyle(.borderless)
            .help("Mémoire")
            Button(action: { Task { await vm.newConversation() } }) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
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
                Divider()
                VStack(spacing: 0) {
                    HStack {
                        Image(systemName: "brain")
                            .foregroundStyle(.yellow)
                        Text("Mémoire")
                            .font(.caption)
                        Spacer()
                        Button("Tout effacer") {
                            Task { await vm.clearAllFacts() }
                        }
                        .font(.caption2)
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: .controlBackgroundColor))

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if vm.facts.isEmpty {
                                Text("Aucun fait mémorisé.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(8)
                            }
                            ForEach(vm.facts) { fact in
                                HStack {
                                    Text(fact.key + " :")
                                        .font(.caption2)
                                        .foregroundStyle(.blue)
                                    Text(fact.value)
                                        .font(.caption2)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer()
                                    Button(action: { Task { await vm.deleteFact(fact) } }) {
                                        Image(systemName: "xmark")
                                            .font(.caption2)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                }
                .task { await vm.loadFacts() }
            }
        }
    }
}
