import SwiftUI
import JarvisCore

struct MessageBubbleView: View {
    let text: String
    let role: String
    var isStreaming = false
    let timestamp: String?

    /// Un seul formateur partagé : DateFormatter est coûteux à créer et cette init
    /// tourne à chaque bulle. Non thread-safe — confinement main (vues) garanti.
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
        HStack(spacing: 0) {
            if role == "user" { Spacer(minLength: 60) }
            if role == "user" {
                userBubble
            } else {
                assistantBubble(text)
            }
            if role == "assistant" { Spacer(minLength: 60) }
        }
        .padding(.horizontal, 8)
    }

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(text)
                .font(.body)
                .foregroundStyle(JarvisTheme.textPrimary)
                // Sans ça, les messages utilisateur n'étaient pas sélectionnables du tout
                // (seule la bulle assistant avait .textSelection) : copier-coller impossible.
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(JarvisTheme.accent.opacity(0.14))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(JarvisTheme.accent.opacity(0.25), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
                // La sélection SwiftUI reste fragmentée par Text : le menu contextuel
                // garantit la copie du message ENTIER dans tous les cas.
                .contextMenu {
                    Button("Copier") { copyText(text) }
                }
            if let ts = timestamp {
                HStack(spacing: 6) {
                    Text(ts).font(JarvisTheme.mono(10)).foregroundStyle(JarvisTheme.textTertiary)
                    Button(action: { copyText(text) }) {
                        Image(systemName: "doc.on.doc").font(.caption2)
                    }
                    .buttonStyle(.plain).foregroundStyle(JarvisTheme.textTertiary)
                    .help("Copier le message")
                    .accessibilityLabel("Copier le message")
                }
            }
        }
        .frame(maxWidth: 560, alignment: .trailing)
    }

    private func assistantBubble(_ displayText: String) -> some View {
        // Panneau type entrée de log/console (liseré d'accent à gauche + avatar J) plutôt qu'une bulle
        // de chat classique : plus cohérent avec un assistant système qu'avec une messagerie.
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 7) {
                assistantAvatar
                VStack(alignment: .leading, spacing: 4) {
                    assistantPanel(displayText)
                    if let ts = timestamp {
                        HStack(spacing: 6) {
                            Text(ts).font(JarvisTheme.mono(10)).foregroundStyle(JarvisTheme.textTertiary)
                            Button(action: { copyText(displayText) }) {
                                Image(systemName: "doc.on.doc").font(.caption2)
                            }
                            .buttonStyle(.plain).foregroundStyle(JarvisTheme.textTertiary)
                            .help("Copier le message")
                            .accessibilityLabel("Copier le message")
                        }
                        .padding(.leading, 2)
                    }
                }
            }
        }
    }

    private var assistantAvatar: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(JarvisTheme.panelElevated)
                .frame(width: 24, height: 24)
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(JarvisTheme.accent.opacity(0.35), lineWidth: 1))
            Image(systemName: "bolt.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(JarvisTheme.accent)
        }
    }

    private func assistantPanel(_ displayText: String) -> some View {
            HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(isStreaming ? JarvisTheme.accent : JarvisTheme.textTertiary.opacity(0.45))
                .frame(width: 2)
            // Equatable : ne re-parse le markdown que si le texte a changé —
            // les bulles figées ne coûtent plus rien pendant le streaming.
            AssistantRichText(text: displayText)
                .textSelection(.enabled)
                .contextMenu {
                    Button("Copier le message") { copyText(displayText) }
                }
                .foregroundStyle(JarvisTheme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            if isStreaming {
                BlinkingCursor()
                    .padding(.top, 10)
                    .padding(.trailing, 8)
            }
        }
        .background(JarvisTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 780, alignment: .leading)
    }

    /// Copie intégrale, indépendante de la sélection SwiftUI : le rendu riche découpe
    /// le message en N vues Text (paragraphes, listes, code) entre lesquelles la sélection
    /// ne traverse pas — sans ça, Cmd+C ne copiait qu'un seul bloc.
    private func copyText(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

/// Curseur de streaming pulsant, façon terminal : «▌».
private struct BlinkingCursor: View {
    @State private var visible = true

    var body: some View {
        Text("▌")
            .font(.body)
            .foregroundStyle(JarvisTheme.accent)
            .opacity(visible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    visible.toggle()
                }
            }
    }
}
