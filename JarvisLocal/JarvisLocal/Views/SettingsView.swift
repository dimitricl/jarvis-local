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
