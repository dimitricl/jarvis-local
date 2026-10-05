//
//  MinimalMessageBubble.swift
//  JarvisLocal
//
//  MessageBubbleView refactorisé avec design minimaliste Apple
//

import SwiftUI
import JarvisCore

struct MinimalMessageBubble: View {
    let text: String
    let role: String
    var isStreaming = false
    let timestamp: String?

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    init(message: Message) {
        self.text = message.content
        self.role = message.role
        self.isStreaming = false
        self.timestamp = Self.timeFormatter.string(from: message.createdAt)
    }

    init(text: String, role: String, isStreaming: Bool = false) {
        self.text = text
        self.role = role
        self.isStreaming = isStreaming
        self.timestamp = nil
    }

    var body: some View {
        if role == "user" {
            userMessageLayout
        } else {
            assistantMessageLayout
        }
    }

    private var userMessageLayout: some View {
        HStack {
            Spacer()
            VStack(alignment: .trailing, spacing: MinimalTheme.spacingXS) {
                userBubble
                if let ts = timestamp {
                    timestampRow(ts)
                }
            }
        }
    }

    private var assistantMessageLayout: some View {
        HStack(alignment: .top, spacing: MinimalTheme.spacingMD) {
            Image(systemName: "person.circle.fill")
                .font(.title3)
                .foregroundStyle(MinimalTheme.accent)
            VStack(alignment: .leading, spacing: MinimalTheme.spacingXS) {
                assistantBubble
                if let ts = timestamp {
                    timestampRow(ts)
                }
            }
            Spacer()
        }
    }

    private func timestampRow(_ ts: String) -> some View {
        HStack(spacing: MinimalTheme.spacingXS) {
            Text(ts)
                .font(MinimalTheme.mono(10))
                .foregroundStyle(MinimalTheme.tertiaryText)
            Button(action: { copyText(text) }) {
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(MinimalTheme.tertiaryText)
        }
    }

    private var userBubble: some View {
        Text(text)
            .font(MinimalTheme.body())
            .foregroundStyle(.white)
            .textSelection(.enabled)
            .padding(.horizontal, MinimalTheme.spacingLG)
            .padding(.vertical, MinimalTheme.spacingMD)
            .background(MinimalTheme.accent)
            .clipShape(RoundedRectangle(cornerRadius: MinimalTheme.cornerRadiusLG))
            .contextMenu {
                Button("Copier") { copyText(text) }
            }
    }

    private var assistantBubble: some View {
        HStack(alignment: .top, spacing: MinimalTheme.spacingSM) {
            AssistantRichText(text: text)
                .textSelection(.enabled)
                .foregroundStyle(MinimalTheme.text)
                .contextMenu {
                    Button("Copier") { copyText(text) }
                }
            if isStreaming {
                Text("▌")
                    .font(.body)
                    .foregroundStyle(MinimalTheme.accent)
                    .opacity(0.5)
            }
        }
        .padding(.horizontal, MinimalTheme.spacingMD)
        .padding(.vertical, MinimalTheme.spacingSM)
        .background(MinimalTheme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: MinimalTheme.cornerRadiusMD))
    }

    private func copyText(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}
