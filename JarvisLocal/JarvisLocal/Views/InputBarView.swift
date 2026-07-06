import SwiftUI

struct InputBarView: View {
    @Environment(AppViewModel.self) private var vm
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool
    @State private var micPulse = false

    var body: some View {
        VStack(spacing: 4) {
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
        .background(JarvisTheme.panel)
        .overlay(Rectangle().fill(JarvisTheme.divider).frame(height: 1), alignment: .top)
        .onAppear { isInputFocused = true }
    }

    @ViewBuilder
    private var micButton: some View {
        Button(action: { Task { await vm.toggleVoiceMode() } }) {
            Image(systemName: vm.isVoiceMode ? "mic.fill" : "mic")
                .foregroundStyle(vm.isListening ? JarvisTheme.accent : vm.isVoiceMode ? JarvisTheme.amber : JarvisTheme.textSecondary)
                .symbolEffect(.pulse, isActive: vm.isListening)
        }
        .buttonStyle(.borderless)
        .help("Mode vocal")
    }

    @ViewBuilder
    private var voiceInputField: some View {
        HStack {
            if vm.isListening {
                HStack(spacing: 4) {
                    Image(systemName: "waveform")
                        .foregroundStyle(JarvisTheme.accent)
                        .symbolEffect(.variableColor.reversing, isActive: vm.isListening)
                    Text(vm.inputText.isEmpty ? "Parle..." : vm.inputText)
                        .foregroundStyle(vm.inputText.isEmpty ? JarvisTheme.textTertiary : JarvisTheme.textPrimary)
                        .lineLimit(1)
                }
            } else {
                Text(vm.inputText.isEmpty ? "..." : vm.inputText)
                    .foregroundStyle(JarvisTheme.textPrimary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(JarvisTheme.panelElevated)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(vm.isListening ? JarvisTheme.accent.opacity(0.6) : Color.clear, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var textInputField: some View {
        TextEditor(text: $inputText)
            .font(.body)
            .foregroundStyle(JarvisTheme.textPrimary)
            .focused($isInputFocused)
            .scrollContentBackground(.hidden)
            .frame(maxHeight: 120)
            .background(JarvisTheme.panelElevated)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .disabled(vm.isStreaming)
            .overlay(alignment: .topLeading) {
                if inputText.isEmpty {
                    Text("Message…")
                        .foregroundStyle(JarvisTheme.textTertiary)
                        .padding(.top, 2)
                        .padding(.leading, 2)
                        .allowsHitTesting(false)
                }
            }

    }

    @ViewBuilder
    private var stopButton: some View {
        Button(action: { vm.stopStreaming() }) {
            Image(systemName: "stop.fill")
                .foregroundStyle(JarvisTheme.danger)
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder
    private var sendButton: some View {
        Button(action: submitText) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.title2)
                .foregroundStyle(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? JarvisTheme.textTertiary : JarvisTheme.accent)
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(KeyEquivalent.return, modifiers: .command)
        .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
            Text("Cmd+Entrée pour envoyer · /facts · /clear")
                .font(JarvisTheme.mono(10))
                .foregroundStyle(JarvisTheme.textTertiary)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
        }
    }

    private func submitText() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        vm.inputText = text
        inputText = ""
        Task { await vm.sendMessage() }
    }
}
