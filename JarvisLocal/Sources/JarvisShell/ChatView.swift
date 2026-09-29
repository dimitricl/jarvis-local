import SwiftUI

/// L3 — fenêtre Discussion : vrai chat multi-tours avec mémoire.
///
/// Branchée sur le coordinator (mêmes runs que le HUD, `runActive` partagé) :
/// envoi désactivé pendant un run, confirmations d'outils inline,
/// interruption, nouvelle discussion. L'historique fichier reste lisible
/// via la fenêtre Historique (même store).
public struct ChatView: View {
    @ObservedObject var coordinator: ShellCoordinator

    public init(coordinator: ShellCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(coordinator.chatMessages) { message in
                            messageRow(message)
                        }
                        if coordinator.chatBusy {
                            Text("…")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                }
                .onChange(of: coordinator.chatMessages.count) { _, _ in
                    if let last = coordinator.chatMessages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            if let confirm = coordinator.chatConfirm {
                confirmCard(confirm)
            }
            Divider()
            HStack(spacing: 8) {
                TextField(
                    "Écris un message… (Entrée = envoyer)",
                    text: $coordinator.chatInput,
                    onCommit: { coordinator.sendChat() }
                )
                .textFieldStyle(.roundedBorder)
                .disabled(coordinator.chatBusy)
                Button("Envoyer") { coordinator.sendChat() }
                    .buttonStyle(.glassProminent)
                    .disabled(sendDisabled)
                if coordinator.chatBusy {
                    Button("Stop") { coordinator.interrupt() }
                        .buttonStyle(.glass)
                }
            }
            .padding(10)
        }
        .frame(minWidth: 480, minHeight: 500)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Nouvelle discussion", systemImage: "square.and.pencil") {
                    coordinator.newChat()
                }
                .disabled(coordinator.chatBusy)
                .help("Nouvelle discussion (l'actuelle reste dans l'historique)")
            }
        }
    }

    private var sendDisabled: Bool {
        coordinator.chatBusy
            || coordinator.chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private func messageRow(_ message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.system(size: 13))
                    .padding(8)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
            }
        case .assistant:
            Text(message.text)
                .font(.system(size: 13))
                .textSelection(.enabled)
        case .note:
            Text(message.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private func confirmCard(_ confirm: ChatConfirm) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("? \(confirm.tool) — \(confirm.reason)")
                .font(.system(size: 12, weight: .medium))
            HStack {
                Button("Autoriser ⏎") { coordinator.answerConfirm(allowed: true, always: false) }
                    .buttonStyle(.glassProminent)
                Button("Refuser") { coordinator.answerConfirm(allowed: false, always: false) }
                Button("Toujours") { coordinator.answerConfirm(allowed: true, always: true) }
                    .help("Crée une règle allow dans permissions.json")
            }
            .font(.system(size: 12))
            .buttonStyle(.glass)
        }
        .padding(10)
    }
}
