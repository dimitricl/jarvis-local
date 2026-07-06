import SwiftUI

struct ChatView: View {
    @Environment(AppViewModel.self) private var vm
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
            InputBarView()
        }
        .background(JarvisTheme.background)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(vm.isStreaming ? JarvisTheme.amber : JarvisTheme.accent)
                .frame(width: 6, height: 6)
                .shadow(color: (vm.isStreaming ? JarvisTheme.amber : JarvisTheme.accent).opacity(0.7), radius: 3)
            Text(vm.isStreaming ? "STREAMING" : "CONNECTÉ")
                .font(JarvisTheme.mono(10, weight: .semibold))
                .foregroundStyle(JarvisTheme.textSecondary)
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
                withAnimation { proxy.scrollTo("streaming", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private var toolIndicator: some View {
        if vm.isToolRunning {
            HStack(spacing: 6) {
                Image(systemName: "wrench.fill")
                    .foregroundStyle(JarvisTheme.amber)
                    .font(.caption2)
                Text("OUTIL · \(vm.currentToolName)")
                    .font(JarvisTheme.mono(10, weight: .medium))
                    .foregroundStyle(JarvisTheme.amber)
                Spacer()
                ProgressView()
                    .scaleEffect(0.5)
                    .tint(JarvisTheme.amber)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(JarvisTheme.amber.opacity(0.08))
        }
    }
}
