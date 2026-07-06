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
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                    Button("✕") { vm.errorMessage = nil }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.red.opacity(0.08))
            }
            messageList
            toolIndicator
            InputBarView()
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        HStack {
            Circle()
                .fill(vm.isStreaming ? Color.orange : Color.green)
                .frame(width: 8, height: 8)
            Text(vm.isStreaming ? "Streaming..." : "Connecté")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let conv = vm.currentConversation {
                Text(conv.title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .padding(.leading, 4)
            }
            Spacer()
            if vm.isSpeaking {
                Image(systemName: "speaker.wave.2")
                    .foregroundStyle(.yellow)
                    .font(.caption)
            }
            if vm.isListening {
                Image(systemName: "mic")
                    .foregroundStyle(.blue)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
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
                        HStack {
                            Text("Jarvis réfléchit")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ProgressView()
                                .scaleEffect(0.5)
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
            HStack {
                Image(systemName: "wrench")
                    .foregroundStyle(.yellow)
                Text("Outil : \(vm.currentToolName)")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                Spacer()
                ProgressView()
                    .scaleEffect(0.5)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color.yellow.opacity(0.05))
        }
    }
}
