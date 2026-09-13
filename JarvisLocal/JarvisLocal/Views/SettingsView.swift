import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Settings.self) private var settings

    var body: some View {
        Form {
            Section("Ollama") {
                TextField("URL :", text: Bindable(settings).ollamaURL)
                    .textFieldStyle(.roundedBorder)
                TextField("Modèle principal :", text: Bindable(settings).model)
                    .textFieldStyle(.roundedBorder)
                TextField("Modèle rapide :", text: Bindable(settings).fastModel)
                    .textFieldStyle(.roundedBorder)
                Picker("Effort de raisonnement :", selection: Bindable(settings).reasoningEffort) {
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
                    Slider(value: Bindable(settings).temperature, in: 0...2, step: 0.1)
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
                Toggle("Synthèse vocale (TTS)", isOn: Bindable(settings).ttsEnabled)
                Toggle("Reconnaissance vocale (STT)", isOn: Bindable(settings).voiceEnabled)

                if settings.ttsEnabled {
                    Picker("Moteur", selection: Bindable(settings).ttsEngine) {
                        ForEach(TTSEngine.allCases, id: \.self) { engine in
                            Text(engine.label).tag(engine)
                        }
                    }
                    .pickerStyle(.menu)

                    switch settings.ttsEngine {
                    case .system:
                        Picker("Voix TTS", selection: Bindable(settings).ttsVoiceIdentifier) {
                            Text("Auto (meilleure dispo)").tag("")
                            ForEach(settings.availableFrenchVoices, id: \.identifier) { voice in
                                Text("\(voice.name) (\(voice.quality == .premium ? "Premium" : voice.quality == .enhanced ? "Enhanced" : "Compact")) — \(voice.language)")
                                    .tag(voice.identifier)
                            }
                        }
                        .pickerStyle(.menu)
                    case .edgeTTS:
                        TextField("Voix edge-tts :", text: Bindable(settings).edgeTTSVoice)
                            .textFieldStyle(.roundedBorder)
                        HStack(spacing: 4) {
                            Circle()
                                .fill(settings.edgeTTSAvailable ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                            Text(settings.edgeTTSAvailable ? "edge-tts détecté" : "edge-tts introuvable — installer avec `pip install edge-tts`")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text("Ex : fr-FR-VivienneMultilingualNeural, fr-FR-HenriNeural, fr-FR-DeniseNeural. Liste complète : `edge-tts --list-voices` dans un terminal.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("MCP (iMCP, optionnel)") {
                // Délégation Calendrier/Rappels/Contacts/Messages à iMCP via MCP.
                // Désactivé par défaut : sans iMCP installé, le natif fait déjà le travail.
                Toggle("Activer MCP (redémarre l'app)", isOn: Bindable(settings).mcpEnabled)
                TextField("Chemin iMCP (vide = auto) :", text: Bindable(settings).imcpPath)
                    .textFieldStyle(.roundedBorder)
                    .font(JarvisTheme.mono(10))
                Text("Vide = résolution auto (JARVIS_IMCP_PATH > `which imcp` > /opt/homebrew, /usr/local…). Ex. Mac Intel : /usr/local/bin/imcp.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
