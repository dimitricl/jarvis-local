import SwiftUI

/// Aide des commandes slash, ouverte via /help.
struct HelpView: View {
    @Environment(AppViewModel.self) private var vm
    @Environment(\.dismiss) private var dismiss

    private struct CommandRow: Identifiable {
        let id = UUID()
        let command: String
        let description: String
    }

    private let commands: [CommandRow] = [
        .init(command: "/help", description: "Affiche cette aide"),
        .init(command: "/clear", description: "Démarre une nouvelle conversation"),
        .init(command: "/facts", description: "Affiche/masque la mémoire de faits personnels"),
        .init(command: "/search <texte>", description: "Recherche dans toutes les conversations"),
        .init(command: "/tools", description: "Audit : ce que Jarvis a VRAIMENT exécuté comme outils"),
        .init(command: "/export md", description: "Exporte la conversation en Markdown"),
        .init(command: "/export json", description: "Exporte la conversation en JSON")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(JarvisTheme.accent)
                Text("Commandes disponibles")
                    .font(.headline)
                    .foregroundStyle(JarvisTheme.textPrimary)
                Spacer()
            }

            VStack(spacing: 0) {
                ForEach(commands) { cmd in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(cmd.command)
                            .font(JarvisTheme.mono(12, weight: .semibold))
                            .foregroundStyle(JarvisTheme.accent)
                            .frame(width: 150, alignment: .leading)
                        Text(cmd.description)
                            .font(.caption)
                            .foregroundStyle(JarvisTheme.textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    if cmd.id != commands.last?.id {
                        Rectangle().fill(JarvisTheme.divider).frame(height: 1)
                    }
                }
            }
            .background(JarvisTheme.panelElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text("Astuce : Entrée pour envoyer, Cmd+Entrée pour un saut de ligne, double-clic sur une conversation pour la renommer.")
                .font(.caption2)
                .foregroundStyle(JarvisTheme.textTertiary)

            HStack {
                Spacer()
                Button("Fermer") { dismiss() }
                    .keyboardShortcut(.escape)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(JarvisTheme.background)
    }
}
