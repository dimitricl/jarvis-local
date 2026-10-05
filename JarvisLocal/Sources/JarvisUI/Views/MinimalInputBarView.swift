//
//  MinimalInputBarView.swift
//  JarvisLocal
//
//  InputBarView refactorisé avec design minimaliste Apple
//

import SwiftUI
import UniformTypeIdentifiers
import JarvisCore

enum MinimalExportFormat {
    case markdown
    case json
}

struct MinimalInputBarView: View {
    @Environment(AppViewModel.self) private var vm
    @Binding var externalPrompt: String
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool
    @State private var editorHeight: CGFloat = 34

    init(externalPrompt: Binding<String> = .constant("")) {
        _externalPrompt = externalPrompt
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom, spacing: MinimalTheme.spacingSM) {
                micButton
                textInputField
                sendButton
            }
            .padding(.horizontal, MinimalTheme.spacingLG)
            .padding(.vertical, MinimalTheme.spacingMD)
            .background(MinimalTheme.secondaryBackground)
            .overlay(
                Rectangle()
                    .fill(MinimalTheme.separator)
                    .frame(height: 0.5),
                alignment: .top
            )

            if vm.isVoiceMode {
                voiceStatusText
                    .padding(.horizontal, MinimalTheme.spacingLG)
                    .padding(.vertical, MinimalTheme.spacingSM)
                    .background(MinimalTheme.tertiaryBackground)
            } else {
                helpText
                    .padding(.horizontal, MinimalTheme.spacingLG)
                    .padding(.vertical, MinimalTheme.spacingSM)
                    .background(MinimalTheme.tertiaryBackground)
            }
        }
        .onAppear { isInputFocused = true }
        .onChange(of: externalPrompt) { _, new in
            guard !new.isEmpty else { return }
            inputText = new
            externalPrompt = ""
            isInputFocused = true
        }
    }

    private var micButton: some View {
        Button(action: { Task { await vm.toggleVoiceMode() } }) {
            Image(systemName: vm.isVoiceMode ? "mic.fill" : "mic")
                .font(.title3)
                .foregroundStyle(vm.isListening ? MinimalTheme.accent : MinimalTheme.secondaryText)
                .frame(width: 36, height: 36)
                .background(vm.isListening ? MinimalTheme.accent.opacity(0.1) : Color.clear)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var textInputField: some View {
        AutoResizingTextView(text: $inputText, height: $editorHeight, maxHeight: 120, font: .systemFont(ofSize: NSFont.systemFontSize), onSend: submitText)
            .frame(height: editorHeight)
            .focused($isInputFocused)
            .accessibilityLabel("Message à envoyer à Jarvis")
            .background(MinimalTheme.background)
            .clipShape(RoundedRectangle(cornerRadius: MinimalTheme.cornerRadiusMD))
            .overlay(
                RoundedRectangle(cornerRadius: MinimalTheme.cornerRadiusMD)
                    .stroke(isInputFocused ? MinimalTheme.accent : MinimalTheme.border, lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                if inputText.isEmpty {
                    Text(vm.isStreaming ? "Jarvis répond..." : "Écrivez un message...")
                        .font(MinimalTheme.body())
                        .foregroundStyle(MinimalTheme.tertiaryText)
                        .padding(.top, 8)
                        .padding(.leading, 8)
                        .allowsHitTesting(false)
                }
            }
    }

    private var sendButton: some View {
        let ready = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Button(action: submitText) {
            Image(systemName: vm.isStreaming ? "stop.fill" : "arrow.up.circle.fill")
                .font(.title2)
                .foregroundStyle(ready ? MinimalTheme.accent : MinimalTheme.tertiaryText)
        }
        .buttonStyle(.plain)
        .disabled(!ready && !vm.isStreaming)
    }

    private var voiceStatusText: some View {
        HStack(spacing: MinimalTheme.spacingSM) {
            if vm.isListening {
                Circle()
                    .fill(MinimalTheme.accent)
                    .frame(width: 6, height: 6)
                Text("Je vous écoute...")
                    .font(MinimalTheme.caption())
                    .foregroundStyle(MinimalTheme.text)
            } else if vm.isStreaming {
                Circle()
                    .fill(MinimalTheme.warning)
                    .frame(width: 6, height: 6)
                Text("Jarvis réfléchit...")
                    .font(MinimalTheme.caption())
                    .foregroundStyle(MinimalTheme.text)
            } else if vm.isSpeaking {
                Circle()
                    .fill(MinimalTheme.warning)
                    .frame(width: 6, height: 6)
                Text("Jarvis parle...")
                    .font(MinimalTheme.caption())
                    .foregroundStyle(MinimalTheme.text)
            } else {
                Text("Parlez pour envoyer un message")
                    .font(MinimalTheme.caption())
                    .foregroundStyle(MinimalTheme.secondaryText)
            }
            Spacer()
            Button("Quitter") {
                Task { await vm.toggleVoiceMode() }
            }
            .font(MinimalTheme.caption())
            .foregroundStyle(MinimalTheme.danger)
        }
    }

    private var helpText: some View {
        Text("Entrée pour envoyer · Cmd+Entrée saut de ligne · /help pour les commandes")
            .font(MinimalTheme.mono(10))
            .foregroundStyle(MinimalTheme.tertiaryText)
    }

    private func submitText() {
        let raw = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

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

    private func exportConversation(format: MinimalExportFormat) {
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
}
