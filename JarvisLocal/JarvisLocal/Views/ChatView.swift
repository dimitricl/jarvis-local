import SwiftUI

struct ChatView: View {
    @Environment(AppViewModel.self) private var vm
    @State private var externalPrompt = ""
    @State private var scrollProxy: ScrollViewProxy?

    var body: some View {
        VStack(spacing: 0) {
            header
            if let err = vm.errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(JarvisTheme.danger)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(JarvisTheme.danger)
                    Spacer()
                    Button("✕") { vm.errorMessage = nil }
                        .buttonStyle(.plain)
                        .foregroundStyle(JarvisTheme.danger)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(JarvisTheme.danger.opacity(0.1))
            }
            messageList
            toolIndicator
            InputBarView(externalPrompt: $externalPrompt)
        }
        .background(JarvisTheme.background)
        .sheet(isPresented: Bindable(vm).showHelp) {
            HelpView()
        }
        .sheet(isPresented: Bindable(vm).showSearch) {
            SearchPanelView()
        }
        .sheet(isPresented: Bindable(vm).showTools) {
            ToolRunsPanel()
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(vm.isStreaming ? JarvisTheme.amber : JarvisTheme.accent)
                .frame(width: 6, height: 6)
                .shadow(color: (vm.isStreaming ? JarvisTheme.amber : JarvisTheme.accent).opacity(0.7), radius: 3)
            Text(vm.isStreaming ? "STREAMING" : "CONNECTÉ")
                .font(JarvisTheme.mono(10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(JarvisTheme.textSecondary)
            // Badge modèle : sait toujours quel modèle répond sans ouvrir les réglages.
            Text(Settings.shared.model)
                .font(JarvisTheme.mono(9))
                .foregroundStyle(JarvisTheme.textTertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(JarvisTheme.panelElevated)
                .clipShape(Capsule())
                .tracking(0.5)
            if let conv = vm.currentConversation {
                Text(conv.title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(JarvisTheme.textPrimary)
                    .lineLimit(1)
                    .padding(.leading, 6)
            }
            Spacer()
            if vm.isSpeaking {
                Label("PARLE", systemImage: "waveform")
                    .font(JarvisTheme.mono(10, weight: .semibold))
                    .foregroundStyle(JarvisTheme.amber)
            }
            if vm.isListening {
                Label("ÉCOUTE", systemImage: "mic.fill")
                    .font(JarvisTheme.mono(10, weight: .semibold))
                    .foregroundStyle(JarvisTheme.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(JarvisTheme.panel)
        .overlay(Rectangle().fill(JarvisTheme.divider).frame(height: 1), alignment: .bottom)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // État d'accueil quand la conversation est vide : l'app ne démarre plus
                // sur un écran noir silencieux.
                if vm.messages.isEmpty && vm.streamingText.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "bolt.circle")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(JarvisTheme.accent)
                            .padding(.top, 56)
                        Text("JARVIS EN LIGNE")
                            .font(JarvisTheme.mono(11, weight: .semibold))
                            .tracking(1.2)
                            .foregroundStyle(JarvisTheme.textSecondary)
                        Text("Demande-moi la météo, un rappel, une recherche web, ou tape /facts pour voir ma mémoire.")
                            .font(.caption)
                            .foregroundStyle(JarvisTheme.textTertiary)
                            .multilineTextAlignment(.center)
                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                            suggestionChip("Quelle est la météo à Paris aujourd'hui ?")
                            suggestionChip("Rappelle-moi d'appeler le dentiste demain à 10h")
                            suggestionChip("Crée une note avec ma liste de courses")
                            suggestionChip("Cherche la dernière actu tech en français")
                        }
                        .padding(.horizontal, 40)
                        .padding(.top, 6)
                    }
                    .frame(maxWidth: .infinity)
                }
                LazyVStack(spacing: 6) {
                    ForEach(vm.messages) { msg in
                        MessageBubbleView(message: msg)
                            .id(msg.id)
                    }
                    if !vm.streamingText.isEmpty {
                        MessageBubbleView(text: vm.streamingText, role: "assistant", isStreaming: true)
                            .id("streaming")
                    }
                    if vm.isStreaming && vm.streamingText.isEmpty {
                        HStack(spacing: 6) {
                            Text("JARVIS RÉFLÉCHIT")
                                .font(JarvisTheme.mono(10, weight: .medium))
                                .foregroundStyle(JarvisTheme.textTertiary)
                            ProgressView()
                                .scaleEffect(0.5)
                                .tint(JarvisTheme.accent)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .id("typing")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .onChange(of: vm.messages.count) { _, _ in
                if let last = vm.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: vm.streamingText) { _, _ in
                // Sans animation pendant le stream : withAnimation à chaque delta rendait
                // le scroll saccadé et retardait l'affichage des nouveaux tokens.
                proxy.scrollTo("streaming", anchor: .bottom)
            }
            .onChange(of: vm.isStreaming) { _, streaming in
                if !streaming, let last = vm.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private var toolIndicator: some View {
        if !vm.toolTrace.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(JarvisTheme.amber)
                    .font(.caption2)
                ForEach(vm.toolTrace) { entry in
                    HStack(spacing: 2) {
                        Text(entry.name)
                            .font(JarvisTheme.mono(10, weight: .medium))
                            .foregroundStyle(JarvisTheme.textSecondary)
                        Text(entry.status)
                            .font(JarvisTheme.mono(10))
                            .foregroundStyle(
                                entry.status == "✓" ? JarvisTheme.accent
                                : entry.status == "✗" ? JarvisTheme.danger
                                : JarvisTheme.amber
                            )
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(JarvisTheme.panelElevated)
                    .clipShape(Capsule())
                }
                Spacer()
                if vm.isToolRunning {
                    ProgressView()
                        .scaleEffect(0.5)
                        .tint(JarvisTheme.amber)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(JarvisTheme.amber.opacity(0.06))
        }
    }

    private func suggestionChip(_ text: String) -> some View {
        Button { externalPrompt = text } label: {
            Text(text)
                .font(.caption)
                .foregroundStyle(JarvisTheme.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(JarvisTheme.panelElevated)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(JarvisTheme.divider, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Panneau d'audit des outils (commande /tools) : la preuve persistée de ce que Jarvis
/// a VRAIMENT exécuté — nom, arguments, statut, extrait du résultat, horodatage.
private struct ToolRunsPanel: View {
    @Environment(AppViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .foregroundStyle(JarvisTheme.amber)
                Text("Outils exécutés")
                    .font(.headline)
                    .foregroundStyle(JarvisTheme.textPrimary)
                Spacer()
                Button("Actualiser") { Task { await vm.loadToolRuns() } }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(JarvisTheme.accent)
            }

            if vm.toolRuns.isEmpty {
                Text("Aucun outil exécuté pour l'instant. Les appels (réussis, refusés, échoués) apparaîtront ici.")
                    .font(.caption)
                    .foregroundStyle(JarvisTheme.textTertiary)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(vm.toolRuns) { run in
                            runRow(run)
                        }
                    }
                }
                .frame(minHeight: 200, maxHeight: 420)
            }

            HStack {
                Spacer()
                Button("Fermer") { dismiss() }
                    .keyboardShortcut(.escape)
            }
        }
        .padding(16)
        .frame(width: 560)
        .background(JarvisTheme.background)
        .task { await vm.loadToolRuns() }
    }

    private func runRow(_ run: ToolRun) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(run.tool)
                    .font(JarvisTheme.mono(12, weight: .semibold))
                    .foregroundStyle(JarvisTheme.textPrimary)
                Text(run.status)
                    .font(JarvisTheme.mono(11, weight: .bold))
                    .foregroundStyle(statusColor(run.status))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(statusColor(run.status).opacity(0.12))
                    .clipShape(Capsule())
                Spacer()
                Text(Self.timestamp(run.createdAt))
                    .font(JarvisTheme.mono(10))
                    .foregroundStyle(JarvisTheme.textTertiary)
            }
            if !run.args.isEmpty {
                Text(run.args)
                    .font(JarvisTheme.mono(10))
                    .foregroundStyle(JarvisTheme.textSecondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            if !run.result.isEmpty {
                Text(run.result)
                    .font(.caption2)
                    .foregroundStyle(JarvisTheme.textTertiary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(JarvisTheme.panelElevated)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "✓": JarvisTheme.accent
        case "✗": JarvisTheme.danger
        case "refusé": JarvisTheme.amber
        default: JarvisTheme.textSecondary
        }
    }

    private static func timestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "dd/MM HH:mm"
        return f.string(from: date)
    }
}
