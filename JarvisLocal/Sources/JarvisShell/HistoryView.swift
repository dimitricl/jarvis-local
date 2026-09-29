import SwiftUI
import JarvisKit
import JarvisAgent

/// L3 — historique : fenêtre secondaire optionnelle (menu bar), lecture des
/// transcripts persistés. En mode dégradé (serveur injoignable), l'historique
/// RESTE lisible : il ne dépend d'aucun réseau.
public struct HistoryView: View {
    var store: FileTranscriptStore
    @State private var transcripts: [TranscriptSummary] = []
    @State private var selectedID: UUID?
    @State private var detail: [Message] = []

    public init(store: FileTranscriptStore) {
        self.store = store
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selectedID) {
                ForEach(transcripts) { item in
                    VStack(alignment: .leading) {
                        Text(item.preview).lineLimit(1)
                        Text(item.date, style: .date)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(item.id)
                    .contextMenu {
                        Button("Supprimer", role: .destructive) {
                            Task { @MainActor in await delete([item.id]) }
                        }
                    }
                }
                .onDelete { offsets in
                    Task { @MainActor in await deleteOffsets(offsets) }
                }
            }
            .navigationTitle("Historique")
            .task { await reload() }
            .onChange(of: selectedID) { _, id in
                // `Task` nu = fond : muter un `@State` hors MainActor perd la
                // mise à jour (clic sans effet sur le détail).
                Task { @MainActor in await loadDetail(id: id) }
            }
            .onDeleteCommand { Task { @MainActor in await deleteSelection() } }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Supprimer la conversation", systemImage: "trash") {
                        Task { @MainActor in await deleteSelection() }
                    }
                    .disabled(selectedID == nil)
                    .help("Supprimer la conversation sélectionnée")
                }
            }
        } detail: {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(detail.indices, id: \.self) { i in
                        messageRow(detail[i])
                    }
                }
                .padding()
            }
        }
    }

    private func messageRow(_ message: Message) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(message.role.rawValue)
                .font(.caption).foregroundStyle(.secondary)
            if let content = message.content, !content.isEmpty {
                Text(content).textSelection(.enabled)
            }
            if let calls = message.toolCalls {
                ForEach(calls, id: \.id) { call in
                    Text("⚙ \(call.name)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.purple)
                }
            }
        }
        .padding(6)
    }

    private func reload() async {
        transcripts = await HistoryLoading.list(store: store)
    }

    private func loadDetail(id: UUID?) async {
        guard let id,
              let transcript = try? await store.load(id: id)
        else {
            detail = []
            return
        }
        detail = transcript.messages
    }

    private func deleteOffsets(_ offsets: IndexSet) async {
        await delete(offsets.map { transcripts[$0].id })
    }

    private func deleteSelection() async {
        guard let selectedID else { return }
        await delete([selectedID])
    }

    private func delete(_ ids: [UUID]) async {
        for id in ids { try? await store.delete(id: id) }
        transcripts.removeAll { ids.contains($0.id) }
        if let selectedID, ids.contains(selectedID) {
            self.selectedID = nil
            detail = []
        }
    }
}

public struct TranscriptSummary: Sendable, Identifiable, Hashable, Equatable {
    public var id: UUID
    public var preview: String
    public var date: Date

    public init(id: UUID, preview: String, date: Date) {
        self.id = id
        self.preview = preview
        self.date = date
    }
}

public enum HistoryLoading {
    /// Liste par lecture directe du store (I/O locale pure, pas de réseau).
    public static func list(store: FileTranscriptStore) async -> [TranscriptSummary] {
        guard let ids = try? await store.listIDs() else { return [] }
        var out: [TranscriptSummary] = []
        for id in ids.prefix(100) {
            guard let transcript = try? await store.load(id: id) else { continue }
            let first = transcript.messages.first { $0.role == .user }?.content ?? "(vide)"
            out.append(TranscriptSummary(id: id, preview: String(first.prefix(80)), date: transcript.updatedAt))
        }
        return out
    }
}
