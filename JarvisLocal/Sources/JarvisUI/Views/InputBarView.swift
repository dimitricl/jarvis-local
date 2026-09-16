import SwiftUI
import UniformTypeIdentifiers
import JarvisCore

/// Format d'export de conversation.
enum ExportFormat {
    case markdown
    case json
}

struct InputBarView: View {
    @Environment(AppViewModel.self) private var vm
    /// Prompt pré-rempli depuis l'extérieur (suggestions de l'écran d'accueil).
    @Binding var externalPrompt: String
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool
    @State private var micPulse = false
    @State private var editorHeight: CGFloat = 34

    init(externalPrompt: Binding<String> = .constant("")) {
        _externalPrompt = externalPrompt
    }

    var body: some View {
        VStack(spacing: 4) {
            // Ligne flottante : champ opaque (lisibilité du texte AppKit) +
            // boutons en styles verre système. Pas de container : ces contrôles
            // ne morphent pas entre eux (recette Apple).
            HStack(spacing: 6) {
                micButton

                if vm.isVoiceMode {
                    voiceInputField
                } else {
                    textInputField
                }

                if vm.isStreaming {
                    stopButton
                } else {
                    sendButton
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            voiceStatusText
        }
        .padding(.bottom, 2)
        .onAppear { isInputFocused = true }
        .onChange(of: externalPrompt) { _, new in
            guard !new.isEmpty else { return }
            inputText = new
            externalPrompt = ""
            isInputFocused = true
        }
    }

    @ViewBuilder
    private var micButton: some View {
        Button(action: { Task { await vm.toggleVoiceMode() } }) {
            Image(systemName: vm.isVoiceMode ? "mic.fill" : "mic")
                .foregroundStyle(vm.isListening ? JarvisTheme.accent : vm.isVoiceMode ? JarvisTheme.amber : JarvisTheme.textSecondary)
                .symbolEffect(.pulse, isActive: vm.isListening)
        }
        .buttonStyle(.glass)
        .help("Mode vocal")
        .accessibilityLabel(vm.isVoiceMode ? "Quitter le mode vocal" : "Activer le mode vocal")
    }

    @ViewBuilder
    private var voiceInputField: some View {
        HStack(spacing: 8) {
            if vm.isListening {
                PulsingDots()
                Text(vm.inputText.isEmpty ? "Je t'écoute..." : vm.inputText)
                    .font(.system(size: NSFont.systemFontSize + 1))
                    .foregroundStyle(vm.inputText.isEmpty ? JarvisTheme.textTertiary : JarvisTheme.textPrimary)
                    .lineLimit(2)
            } else {
                Image(systemName: "waveform")
                    .foregroundStyle(JarvisTheme.textTertiary)
                Text(vm.inputText.isEmpty ? "..." : vm.inputText)
                    .font(.system(size: NSFont.systemFontSize + 1))
                    .foregroundStyle(JarvisTheme.textPrimary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(JarvisTheme.panelElevated)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(vm.isListening ? JarvisTheme.accent.opacity(0.6) : Color.clear, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var textInputField: some View {
        AutoResizingTextView(text: $inputText, height: $editorHeight, maxHeight: 120, font: .systemFont(ofSize: NSFont.systemFontSize), onSend: submitText)
            .frame(height: editorHeight)
            .focused($isInputFocused)
            .accessibilityLabel("Message à envoyer à Jarvis")
            // Champ opaque (recette Apple) : le texte AppKit dense reste lisible ;
            // le verre est réservé aux contrôles (boutons), pas au contenu éditable.
            .background(JarvisTheme.panelElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            // PAS de .disabled(vm.isStreaming) ici : bloquer la saisie pendant la réponse
            // empêchait de préparer son prochain message et donnait l'impression d'un champ
            // cassé pendant tout le stream. L'envoi reste bloqué via le bouton/submitText.
            .overlay(alignment: .topLeading) {
                if inputText.isEmpty {
                    Text(vm.isStreaming ? "Jarvis répond... (tu peux taper)" : "Message...")
                        .foregroundStyle(JarvisTheme.textTertiary)
                        .padding(.top, 6)
                        .padding(.leading, 6)
                        .allowsHitTesting(false)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isInputFocused ? JarvisTheme.accent.opacity(0.35) : Color.clear, lineWidth: 1)
            )
    }

    @ViewBuilder
    private var stopButton: some View {
        Button(action: { vm.stopStreaming() }) {
            Image(systemName: "stop.fill")
                .foregroundStyle(JarvisTheme.danger)
        }
        .buttonStyle(.glass)
        .tint(JarvisTheme.danger)
        .accessibilityLabel("Arrêter la réponse en cours")
    }

    @ViewBuilder
    private var sendButton: some View {
        let ready = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if ready {
            Button(action: submitText) {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(JarvisTheme.accent)
            }
            .buttonStyle(.glassProminent)
            .tint(JarvisTheme.accent)
            .accessibilityLabel("Envoyer le message")
        } else {
            Button(action: submitText) {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(JarvisTheme.textTertiary)
            }
            .buttonStyle(.glass)
            .disabled(true)
            .accessibilityLabel("Envoyer le message")
        }
    }

    @ViewBuilder
    private var voiceStatusText: some View {
        if vm.isVoiceMode {
            HStack(spacing: 4) {
                if vm.isListening {
                    Circle().fill(JarvisTheme.accent).frame(width: 6, height: 6)
                    Text("Écoute...")
                } else if vm.isStreaming {
                    Circle().fill(JarvisTheme.amber).frame(width: 6, height: 6)
                    Text("Jarvis réfléchit...")
                } else if vm.isSpeaking {
                    Circle().fill(JarvisTheme.amber).frame(width: 6, height: 6)
                    Text("Jarvis parle...")
                } else {
                    Text("Mode vocal — parle pour envoyer un message")
                        .foregroundStyle(JarvisTheme.textTertiary)
                }
                Spacer()
                Button("Quitter") {
                    Task { await vm.toggleVoiceMode() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(JarvisTheme.danger)
                .font(.caption2)
            }
            .font(JarvisTheme.mono(10))
            .foregroundStyle(JarvisTheme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        } else {
            Text("Entrée pour envoyer · Cmd+Entrée saut de ligne · /help pour les commandes")
                .font(JarvisTheme.mono(10))
                .foregroundStyle(JarvisTheme.textTertiary)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
        }
    }

    private func exportConversation(format: ExportFormat) {
        guard let content = format == .markdown
            ? vm.exportConversationAsMarkdown()
            : vm.exportConversationAsJSON() else { return }
        let ext = format == .markdown ? "md" : "json"
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(vm.currentConversation?.title ?? "conversation").\(ext)"
        panel.allowedContentTypes = [ext == "md" ? .plainText : .json]
        if panel.runModal() == .OK, let url = panel.url {
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func submitText() {
        let raw = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        // Pas de garde sur isStreaming : sendMessage coupe la réponse en cours
        // et traite le nouveau message (avant : envoi silencieusement ignoré).
        // Commandes slash
        switch raw {
        case "/clear":
            inputText = ""
            Task { await vm.newConversation() }
            return
        case "/facts":
            inputText = ""
            vm.showFacts.toggle()
            return
        case "/tools":
            inputText = ""
            vm.showTools.toggle()
            if vm.showTools {
                Task { await vm.loadToolRuns() }
            }
            return
        case "/help":
            inputText = ""
            vm.showHelp.toggle()
            return
        case "/export md", "/export markdown":
            inputText = ""
            exportConversation(format: .markdown)
            return
        case "/export json":
            inputText = ""
            exportConversation(format: .json)
            return
        default:
            if raw.hasPrefix("/search ") {
                inputText = ""
                let query = String(raw.dropFirst("/search ".count))
                vm.searchQuery = query
                vm.showSearch.toggle()
                Task { await vm.search(query) }
                return
            }
        }

        vm.inputText = raw
        inputText = ""
        Task { await vm.sendMessage() }
    }
}

/// Trois points pulsants : feedback visuel d'écoute active en mode vocal.
private struct PulsingDots: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(JarvisTheme.accent)
                    .frame(width: 4, height: 4)
                    .scaleEffect(animating ? 1.0 : 0.45)
                    .opacity(animating ? 1.0 : 0.4)
                    .animation(
                        .easeInOut(duration: 0.55)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.18),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}
