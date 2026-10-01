//
//  ModernMessageBubble.swift
//  JarvisLocal
//
//  Bulles de messages modernes avec animations
//

import SwiftUI
import JarvisCore

struct ModernMessageBubble: View {
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
        HStack(spacing: 16) {
            if role == "user" { Spacer(minLength: 80) }
            
            if role == "user" {
                userBubble
            } else {
                assistantBubble
            }
            
            if role == "assistant" { Spacer(minLength: 80) }
        }
    }
    
    // MARK: - User Bubble
    
    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Text(text)
                    .font(JarvisTypography.body())
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .background(JarvisPalette.primaryGradient)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: JarvisPalette.primaryGlow, radius: 8, x: 0, y: 4)
                
                if let ts = timestamp {
                    Text(ts)
                        .font(JarvisTypography.footnote())
                        .foregroundStyle(JarvisPalette.textTertiary)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: 600, alignment: .trailing)
        }
    }
    
    // MARK: - Assistant Bubble
    
    private var assistantBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 16) {
                // Avatar Jarvis
                ZStack {
                    Circle()
                        .fill(JarvisPalette.surfaceHighlight)
                        .frame(width: 36, height: 36)
                    
                    Image(systemName: "cpu")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(JarvisPalette.primary)
                }
                
                // Contenu
                VStack(alignment: .leading, spacing: 8) {
                    // Carte de message
                    ModernCard(style: .flat) {
                        VStack(alignment: .leading, spacing: 8) {
                            AssistantRichText(text: text)
                                .textSelection(.enabled)
                                .font(JarvisTypography.body())
                                .foregroundStyle(JarvisPalette.textPrimary)
                            
                            if isStreaming {
                                HStack(spacing: 4) {
                                    Text("▌")
                                        .font(JarvisTypography.body())
                                        .foregroundStyle(JarvisPalette.primary)
                                }
                                .transition(.opacity)
                            }
                        }
                        .frame(maxWidth: 700, alignment: .leading)
                    }
                    
                    // Timestamp et actions
                    if let ts = timestamp {
                        HStack(spacing: 8) {
                            Text(ts)
                                .font(JarvisTypography.footnote())
                                .foregroundStyle(JarvisPalette.textTertiary)
                            
                            Button(action: { copyText(text) }) {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(JarvisPalette.textTertiary)
                            .help("Copier")
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    // MARK: - Copy
    
    private func copyText(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}


