//
//  ModernInputBar.swift
//  JarvisLocal
//
//  Input bar moderne avec animations et effets de glow
//

import SwiftUI
import UniformTypeIdentifiers
import JarvisCore

struct ModernInputBar: View {
    @Environment(AppViewModel.self) private var vm
    @Binding var externalPrompt: String
    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool
    @State private var editorHeight: CGFloat = 40
    @State private var isHovered = false
    @Namespace private var morphNamespace
    
    var body: some View {
        VStack(spacing: 8) {
            // Container principal avec effet de verre
            HStack(spacing: 16) {
                // Micro button
                micButton
                
                // Input field
                inputField
                
                // Send/Stop button
                actionButton
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(JarvisPalette.surfaceElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(borderColor, lineWidth: isInputFocused ? 2 : 1)
                    )
                    .shadow(
                        color: glowColor,
                        radius: isInputFocused ? 20 : 12,
                        x: 0,
                        y: isInputFocused ? 8 : 4
                    )
            )
            .padding(.horizontal, 24)
            .scaleEffect(isHovered ? 1.01 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
            
            // Status text
            statusText
        }
        .padding(.bottom, 16)
        .onAppear { isInputFocused = true }
        .onChange(of: externalPrompt) { _, new in
            guard !new.isEmpty else { return }
            inputText = new
            externalPrompt = ""
            isInputFocused = true
        }
    }
    
    // MARK: - Mic Button
    
    private var micButton: some View {
        Button(action: { Task { await vm.toggleVoiceMode() } }) {
            ZStack {
                if vm.isListening {
                    Circle()
                        .fill(JarvisPalette.primaryGradient)
                        .frame(width: 44, height: 44)
                        .glow(color: JarvisPalette.primary, radius: 15)
                }
                
                Image(systemName: vm.isVoiceMode ? "mic.fill" : "mic")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(vm.isListening ? .white : JarvisPalette.textSecondary)
                    .frame(width: 44, height: 44)
                    .if(vm.isListening) { view in
                        view.pulse(scale: 1.1)
                    }
            }
        }
        .buttonStyle(PlainButtonStyle())
        .help("Mode vocal")
    }
    
    // MARK: - Input Field
    
    private var inputField: some View {
        ZStack(alignment: .topLeading) {
            if vm.isVoiceMode {
                voiceInputView
            } else {
                AutoResizingTextView(
                    text: $inputText,
                    height: $editorHeight,
                    maxHeight: 120,
                    font: .systemFont(ofSize: 15),
                    onSend: submitText
                )
                .frame(height: editorHeight)
                .focused($isInputFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.clear)
                
                if inputText.isEmpty {
                    Text(vm.isStreaming ? "Continuez à taper..." : "Écrivez à Jarvis...")
                        .font(JarvisTypography.body())
                        .foregroundStyle(JarvisPalette.textTertiary)
                        .padding(.top, 8)
                        .padding(.leading, 16)
                        .allowsHitTesting(false)
                }
            }
        }
    }
    
    // MARK: - Voice Input View
    
    private var voiceInputView: some View {
        HStack(spacing: 8) {
            if vm.isListening {
                WaveformAnimation(isPlaying: true)
            } else {
                Image(systemName: "waveform")
                    .foregroundStyle(JarvisPalette.textTertiary)
            }
            
            Text(vm.inputText.isEmpty ? (vm.isListening ? "Je vous écoute..." : "...") : vm.inputText)
                .font(JarvisTypography.body())
                .foregroundStyle(vm.inputText.isEmpty ? JarvisPalette.textTertiary : JarvisPalette.textPrimary)
                .lineLimit(2)
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
    
    // MARK: - Action Button

    @ViewBuilder
    private var actionButton: some View {
        let ready = !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        
        if vm.isStreaming {
            Button(action: { vm.stopStreaming() }) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(JarvisPalette.danger)
                    .clipShape(Circle())
                    .glow(color: JarvisPalette.danger, radius: 10)
            }
            .buttonStyle(PlainButtonStyle())
            .matchedGeometryEffect(id: "actionButton", in: morphNamespace)
        } else {
            Button(action: submitText) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ready ? .white : JarvisPalette.textTertiary)
                    .frame(width: 44, height: 44)
                    .background {
                        if ready {
                            JarvisPalette.primaryGradient
                        } else {
                            JarvisPalette.surfaceHighlight
                        }
                    }
                    .clipShape(Circle())
                    .if(ready) { view in
                        view.glow(color: JarvisPalette.primary, radius: 12)
                    }
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!ready)
            .matchedGeometryEffect(id: "actionButton", in: morphNamespace)
        }
    }
    
    // MARK: - Status Text
    
    private var statusText: some View {
        HStack(spacing: 8) {
            if vm.isVoiceMode {
                if vm.isListening {
                    StatusIndicator(status: .online, size: 6)
                    Text("Écoute en cours...")
                        .font(JarvisTypography.footnote())
                        .foregroundStyle(JarvisPalette.primary)
                } else if vm.isStreaming {
                    StatusIndicator(status: .connecting, size: 6)
                    Text("Jarvis réfléchit...")
                        .font(JarvisTypography.footnote())
                        .foregroundStyle(JarvisPalette.warning)
                } else if vm.isSpeaking {
                    StatusIndicator(status: .connecting, size: 6)
                    Text("Jarvis parle...")
                        .font(JarvisTypography.footnote())
                        .foregroundStyle(JarvisPalette.warning)
                } else {
                    Text("Mode vocal activé")
                        .font(JarvisTypography.footnote())
                        .foregroundStyle(JarvisPalette.textTertiary)
                }
                
                Spacer()
                
                Button("Quitter") {
                    Task { await vm.toggleVoiceMode() }
                }
                .font(JarvisTypography.footnote())
                .foregroundStyle(JarvisPalette.danger)
                .buttonStyle(.plain)
            } else {
                Text("Entrée pour envoyer · Cmd+Entrée pour saut de ligne")
                    .font(JarvisTypography.footnote())
                    .foregroundStyle(JarvisPalette.textTertiary)
            }
        }
        .padding(.horizontal, 24)
    }
    
    // MARK: - Helpers
    
    private var borderColor: Color {
        if isInputFocused {
            return JarvisPalette.primary
        }
        return JarvisPalette.border
    }
    
    private var glowColor: Color {
        if isInputFocused {
            return JarvisPalette.primaryGlow
        }
        return Color.black.opacity(0.2)
    }
    
    // MARK: - Submit
    
    private func submitText() {
        let raw = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        
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
}
