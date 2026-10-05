//
//  MinimalSidebarView.swift
//  JarvisLocal
//
//  SidebarView refactorisé avec design minimaliste Apple
//

import SwiftUI
import JarvisCore

struct MinimalSidebarView: View {
    @Environment(AppViewModel.self) private var vm

    var body: some View {
        List(selection: selection) {
            Section("Conversations") {
                if vm.conversations.isEmpty {
                    Text("Aucune conversation")
                        .foregroundStyle(MinimalTheme.secondaryText)
                        .font(MinimalTheme.caption())
                }
                ForEach(vm.conversations) { conv in
                    MinimalConversationRow(conversation: conv)
                        .tag(conv.id)
                }
            }
            if vm.showFacts {
                Section {
                    if vm.facts.isEmpty {
                        Text("Aucun fait mémorisé")
                            .foregroundStyle(MinimalTheme.secondaryText)
                            .font(MinimalTheme.caption())
                    }
                    ForEach(vm.facts) { fact in
                        HStack(spacing: MinimalTheme.spacingSM) {
                            Text(fact.key + " :")
                                .font(MinimalTheme.mono(11))
                                .foregroundStyle(MinimalTheme.accent)
                            Text(fact.value)
                                .font(MinimalTheme.body())
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer()
                            Button(action: { Task { await vm.deleteFact(fact) } }) {
                                Image(systemName: "xmark")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(MinimalTheme.secondaryText)
                        }
                    }
                } header: {
                    HStack {
                        Text("Mémoire")
                            .font(MinimalTheme.bodyEmphasized())
                        Spacer()
                        Button("Tout effacer") {
                            Task { await vm.clearAllFacts() }
                        }
                        .font(MinimalTheme.caption())
                        .foregroundStyle(MinimalTheme.danger)
                    }
                }
                .task { await vm.loadFacts() }
            }
        }
        .listStyle(.sidebar)
    }

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

struct MinimalConversationRow: View {
    @Environment(AppViewModel.self) private var vm
    let conversation: Conversation

    var body: some View {
        HStack(spacing: MinimalTheme.spacingSM) {
            Text(conversation.title)
                .font(MinimalTheme.body())
                .foregroundStyle(MinimalTheme.text)
                .lineLimit(1)
            Spacer()
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Supprimer", role: .destructive) {
                Task { await vm.deleteConversation(conversation) }
            }
        }
    }
}
