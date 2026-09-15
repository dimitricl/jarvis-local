import SwiftUI
import JarvisCore

/// Panneau Réglages. Générique sur le settings (protocol) : les bindings
/// exigent des key paths concrets, impossibles sur existentiel — d'où `S`.
/// La composition root injecte Settings (Services) ; previews/tests un fake.
struct SettingsView<S: AppSettingsProtocol>: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var settings: S

    var body: some View {
        Form {
            Section("Général") {
                Toggle("Lancer au démarrage", isOn: $settings.launchAtLogin)
                    .accessibilityLabel("Lancer Jarvis au démarrage de la session")
                Text("Jarvis reste accessible depuis la barre de menu (icône waveform) même sans fenêtre ouverte. Une notification prévient quand une réponse longue se termine en arrière-plan.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Ollama") {
                TextField("URL :", text: $settings.ollamaURL)
                    .textFieldStyle(.roundedBorder)
                if !settings.ollamaHostIsLocal {
                    Text("⚠ Serveur distant : l'historique, les faits et les résultats d'outils sont envoyés à cet hôte (souvent en clair en http). Local par défaut : http://localhost:11434.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                TextField("Modèle principal :", text: $settings.model)
                    .textFieldStyle(.roundedBorder)
                TextField("Modèle rapide :", text: $settings.fastModel)
                    .textFieldStyle(.roundedBorder)
                Picker("Effort de raisonnement :", selection: $settings.reasoningEffort) {
                    Text("Aucun (rapide)").tag("none")
                    Text("Faible").tag("low")
                    Text("Moyen").tag("medium")
                    Text("Élevé").tag("high")
                }
                .pickerStyle(.menu)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Fenêtre de contexte (num_ctx) :")
                        Spacer()
                        Text("\(settings.numCtx) tokens")
                            .font(JarvisTheme.mono(10))
                            .foregroundStyle(JarvisTheme.textSecondary)
                    }
                    Slider(value: Binding(
                        get: { Double(settings.numCtx) },
                        set: { settings.numCtx = Int($0) }
                    ), in: 2048...32768, step: 1024)
                    Text("Borné à ce que le serveur peut réellement allouer : au-delà, Ollama tronque silencieusement l'historique.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Température (créativité) :")
                        Spacer()
                        Text(String(format: "%.1f", settings.temperature))
                            .font(JarvisTheme.mono(10))
                            .foregroundStyle(JarvisTheme.textSecondary)
                    }
                    Slider(value: $settings.temperature, in: 0...2, step: 0.1)
                    Text("Bas (~0,2) = factuel et fidèle (recommandé contre les chiffres inventés). Haut = plus créatif mais plus confabulateur.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Longueur max de réponse :")
                        Spacer()
                        Text("\(settings.maxTokens) tokens (~\(settings.maxTokens * 3 / 4) mots)")
                            .font(JarvisTheme.mono(10))
                            .foregroundStyle(JarvisTheme.textSecondary)
                    }
                    Slider(value: Binding(
                        get: { Double(settings.maxTokens) },
                        set: { settings.maxTokens = Int($0) }
                    ), in: 512...32768, step: 512)
                    Text("Augmente cette valeur si les réponses sont coupées en pleine phrase.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Audio") {
                Toggle("Synthèse vocale (TTS)", isOn: $settings.ttsEnabled)
                Toggle("Reconnaissance vocale (STT)", isOn: $settings.voiceEnabled)

                if settings.ttsEnabled {
                    // 100 % on-device (AVSpeechSynthesizer). L'ancien moteur cloud edge-tts
                    // (process Python + réseau Microsoft) a été supprimé : pour une meilleure
                    // voix FR, télécharge une voix Enhanced/Premium dans Réglages Système
                    // → Accessibilité → Contenu énoncé → Voix système.
                    Picker("Voix TTS", selection: $settings.ttsVoiceIdentifier) {
                        Text("Auto (meilleure dispo)").tag("")
                        ForEach(settings.frenchVoiceOptions, id: \.identifier) { voice in
                            Text("\(voice.name) (\(voice.qualityLabel)) — \(voice.language)")
                                .tag(voice.identifier)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            Section("MCP (iMCP, optionnel)") {
                // Délégation Calendrier/Rappels/Contacts/Messages à iMCP via MCP.
                // Désactivé par défaut : sans iMCP installé, le natif fait déjà le travail.
                Toggle("Activer MCP (redémarre l'app)", isOn: $settings.mcpEnabled)
                TextField("Chemin iMCP (vide = auto) :", text: $settings.imcpPath)
                    .textFieldStyle(.roundedBorder)
                    .font(JarvisTheme.mono(10))
                Text("Vide = auto (JARVIS_IMCP_PATH > iMCP.app > `which imcp-server`). Défaut : /Applications/iMCP.app/Contents/MacOS/imcp-server. Après install : activer les services dans iMCP + approuver JarvisLocal.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section("Boucle d'outils") {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Max d'appels par outil et par tour :")
                        Spacer()
                        Text("\(settings.maxToolCallsPerTurn)")
                            .font(JarvisTheme.mono(10))
                            .foregroundStyle(JarvisTheme.textSecondary)
                    }
                    Slider(value: Binding(
                        get: { Double(settings.maxToolCallsPerTurn) },
                        set: { settings.maxToolCallsPerTurn = Int($0) }
                    ), in: 1...10, step: 1)
                    Text("Coupe-circuit anti-boucle : un modèle qui rappelle search_web en boucle (requêtes reformulées) est stoppé après N invocations du même outil dans le même tour.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Mise à jour") {
                HStack {
                    Text("Version \(settings.currentVersion)")
                    Spacer()
                    if settings.isCheckingUpdate {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Button(settings.updateAvailable ? "Mise à jour disponible !" : "Vérifier les mises à jour") {
                            Task { await settings.checkForUpdates() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(settings.updateAvailable ? .orange : nil)
                    }
                }
                if let err = settings.updateCheckError {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Fermer") { dismiss() }
                    .keyboardShortcut(.escape)
            }
            .padding(.top)
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .padding()
    }
}
