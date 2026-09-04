import SwiftUI

/// Panneau de recherche plein-texte dans toutes les conversations.
struct SearchPanelView: View {
    @Environment(AppViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(JarvisTheme.accent)
                Text("Recherche")
                    .font(.headline)
                    .foregroundStyle(JarvisTheme.textPrimary)
                Spacer()
            }

            HStack(spacing: 8) {
                TextField("Rechercher dans toutes les conversations...", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await vm.search(query) } }
                Button("Chercher") { Task { await vm.search(query) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let q = vm.searchQuery as String?, !vm.searchResults.isEmpty {
                Text("\(vm.searchResults.count) résultat(s) pour « \(q) »")
                    .font(JarvisTheme.mono(10))
                    .foregroundStyle(JarvisTheme.textTertiary)
            }

            ScrollView {
                LazyVStack(spacing: 4) {
                    if vm.searchResults.isEmpty {
                        Text(vm.searchQuery.isEmpty ? "Tape ta recherche ci-dessus." : "Aucun résultat.")
                            .font(.caption2)
                            .foregroundStyle(JarvisTheme.textTertiary)
                            .padding(.top, 20)
                    }
                    ForEach(vm.searchResults) { result in
                        SearchResultRow(entry: result)
                    }
                }
            }
            .frame(minHeight: 200)

            HStack {
                Spacer()
                Button("Fermer") { dismiss() }
                    .keyboardShortcut(.escape)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(JarvisTheme.background)
        .task {
            // Pré-remplit avec la requête lancée via /search
            query = vm.searchQuery
            if !query.isEmpty && vm.searchResults.isEmpty {
                await vm.search(query)
            }
        }
    }
}

private struct SearchResultRow: View {
    @Environment(AppViewModel.self) private var vm
    let entry: AppViewModel.SearchResultEntry
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(entry.conversationTitle)
                    .font(JarvisTheme.mono(10, weight: .semibold))
                    .foregroundStyle(JarvisTheme.accent)
                Text(entry.role == "user" ? "VOUS" : "JARVIS")
                    .font(JarvisTheme.mono(9))
                    .foregroundStyle(entry.role == "user" ? JarvisTheme.amber : JarvisTheme.textSecondary)
                    .padding(.horizontal, 5)
                    .background(JarvisTheme.panelElevated)
                    .clipShape(Capsule())
                Spacer()
            }
            Text(entry.content)
                .font(.caption)
                .foregroundStyle(JarvisTheme.textPrimary)
                .lineLimit(3)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(JarvisTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            // Navigue vers la conversation contenant le résultat
            if let cid = entry.conversationId,
               let conv = vm.conversations.first(where: { $0.id == cid }) {
                Task {
                    await vm.selectConversation(conv)
                    dismiss()
                }
            }
        }
    }
}
