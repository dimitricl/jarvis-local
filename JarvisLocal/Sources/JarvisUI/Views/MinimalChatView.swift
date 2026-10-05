//
//  MinimalChatView.swift
//  JarvisLocal
//
//  ChatView refactorisé avec design minimaliste Apple
//

import SwiftUI
import JarvisCore

struct MinimalChatView: View {
    @Environment(AppViewModel.self) private var vm
    @State private var externalPrompt = ""
    @State private var scrollProxy: ScrollViewProxy?

    var body: some View {
        VStack(spacing: 0) {
            header
            if let err = vm.errorMessage {
                errorBanner(err)
            }
            messageList
            JobsView()
            MinimalInputBarView(externalPrompt: $externalPrompt)
        }
        .background(MinimalTheme.background)
    }

    private var header: some View {
        HStack(spacing: MinimalTheme.spacingSM) {
            Circle()
                .fill(activityColor)
                .frame(width: 6, height: 6)
            Text(activityLabel)
                .font(MinimalTheme.caption())
                .foregroundStyle(MinimalTheme.secondaryText)
            if let conv = vm.currentConversation {
                Text(conv.title)
                    .font(MinimalTheme.bodyEmphasized())
                    .foregroundStyle(MinimalTheme.text)
                    .lineLimit(1)
            }
            Spacer()
            if vm.isSpeaking {
                Image(systemName: "speaker.wave.2")
                    .font(.caption)
                    .foregroundStyle(MinimalTheme.accent)
            }
            if vm.isListening {
                Image(systemName: "mic.fill")
                    .font(.caption)
                    .foregroundStyle(MinimalTheme.accent)
            }
        }
        .padding(.horizontal, MinimalTheme.spacingLG)
        .padding(.vertical, MinimalTheme.spacingMD)
        .background(MinimalTheme.secondaryBackground)
        .overlay(
            Rectangle()
                .fill(MinimalTheme.separator)
                .frame(height: 0.5),
            alignment: .bottom
        )
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: MinimalTheme.spacingSM) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(MinimalTheme.danger)
            Text(message)
                .font(MinimalTheme.caption())
                .foregroundStyle(MinimalTheme.text)
            Spacer()
            Button("Fermer") { vm.errorMessage = nil }
                .font(MinimalTheme.caption())
                .foregroundStyle(MinimalTheme.secondaryText)
        }
        .padding(.horizontal, MinimalTheme.spacingLG)
        .padding(.vertical, MinimalTheme.spacingSM)
        .background(MinimalTheme.danger.opacity(0.1))
    }

    private var activityLabel: String {
        if vm.confirmationRequest != nil { return "Confirmation requise" }
        if vm.isToolRunning { return vm.currentToolName }
        if vm.isStreaming && vm.streamingText.isEmpty { return "Réflexion" }
        if vm.isStreaming { return "Réponse en cours" }
        return "Connecté"
    }

    private var activityColor: Color {
        if vm.confirmationRequest != nil { return MinimalTheme.danger }
        if vm.isToolRunning || vm.isStreaming { return MinimalTheme.warning }
        return MinimalTheme.accent
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if vm.messages.isEmpty && vm.streamingText.isEmpty {
                    emptyState
                }
                LazyVStack(spacing: MinimalTheme.spacingMD) {
                    ForEach(vm.messages) { msg in
                        MinimalMessageBubble(message: msg)
                            .id(msg.id)
                    }
                    inlineToolTrace
                    if !vm.streamingText.isEmpty {
                        MinimalMessageBubble(text: vm.streamingText, role: "assistant", isStreaming: true)
                            .id("streaming")
                    }
                    if vm.isStreaming && vm.streamingText.isEmpty {
                        HStack(spacing: MinimalTheme.spacingSM) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Jarvis réfléchit...")
                                .font(MinimalTheme.caption())
                                .foregroundStyle(MinimalTheme.tertiaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, MinimalTheme.spacingLG)
                        .padding(.vertical, MinimalTheme.spacingMD)
                        .id("typing")
                    }
                }
                .padding(.horizontal, MinimalTheme.spacingLG)
                .padding(.vertical, MinimalTheme.spacingSM)
            }
            .onChange(of: vm.messages.count) { _, _ in
                if let last = vm.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: vm.streamingText) { _, _ in
                proxy.scrollTo("streaming", anchor: .bottom)
            }
            .onChange(of: vm.isStreaming) { _, streaming in
                if !streaming, let last = vm.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: MinimalTheme.spacingXL) {
            Image(systemName: "message.circle")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(MinimalTheme.accent)
                .padding(.top, MinimalTheme.spacingXL * 2)
            Text("Jarvis")
                .font(MinimalTheme.largeTitle())
                .foregroundStyle(MinimalTheme.text)
            Text("Comment puis-je vous aider ?")
                .font(MinimalTheme.body())
                .foregroundStyle(MinimalTheme.secondaryText)
                .multilineTextAlignment(.center)
            VStack(spacing: MinimalTheme.spacingSM) {
                suggestionButton("Quelle est la météo à Paris ?")
                suggestionButton("Rappelle-moi d'appeler le dentiste")
                suggestionButton("Crée une note de courses")
                suggestionButton("Cherche la dernière actu tech")
            }
            .padding(.top, MinimalTheme.spacingMD)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var inlineToolTrace: some View {
        if !vm.toolTrace.isEmpty {
            HStack(alignment: .top, spacing: MinimalTheme.spacingSM) {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(MinimalTheme.tertiaryText)
                    .font(.caption2)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(vm.toolTrace) { entry in
                        HStack(spacing: MinimalTheme.spacingXS) {
                            Text(entry.name)
                                .font(MinimalTheme.mono(10))
                                .foregroundStyle(MinimalTheme.secondaryText)
                            Text(entry.status)
                                .font(MinimalTheme.mono(10))
                                .foregroundStyle(
                                    entry.status == "✓" ? MinimalTheme.success
                                    : entry.status == "✗" ? MinimalTheme.danger
                                    : MinimalTheme.warning
                                )
                        }
                    }
                }
                Spacer()
            }
            .padding(.leading, MinimalTheme.spacingLG)
            .padding(.vertical, MinimalTheme.spacingSM)
        }
    }

    private func suggestionButton(_ text: String) -> some View {
        Button { externalPrompt = text } label: {
            Text(text)
                .font(MinimalTheme.body())
                .foregroundStyle(MinimalTheme.text)
                .multilineTextAlignment(.center)
                .padding(.horizontal, MinimalTheme.spacingLG)
                .padding(.vertical, MinimalTheme.spacingMD)
                .frame(maxWidth: .infinity)
                .background(MinimalTheme.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: MinimalTheme.cornerRadiusMD))
        }
        .buttonStyle(.plain)
    }
}
