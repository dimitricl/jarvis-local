import SwiftUI

/// L3 — réglages shell : endpoint distant (jamais en dur), modèle, contexte,
/// hotkey, voix, workspace. L'URL distante affiche son avertissement
/// (historique et faits y transitent, souvent en clair).
public struct ShellSettingsView: View {
    @Binding var settings: ShellSettings
    @ObservedObject var coordinator: ShellCoordinator
    @State private var availableModels: [String] = []
    @State private var isLoadingModels = false

    public init(settings: Binding<ShellSettings>, coordinator: ShellCoordinator) {
        self._settings = settings
        self.coordinator = coordinator
    }

    public var body: some View {
        Form {
            Section("Serveur d'inférence") {
                HStack {
                    TextField("URL Ollama :", text: $settings.ollamaURL)
                        .textFieldStyle(.roundedBorder)
                    
                    Button(action: { testConnection() }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(isLoadingModels)
                }
                
                if settings.isRemote {
                    Label("URL distante Tailscale : l'historique et les faits sont envoyés via tunnel sécurisé.", systemImage: "checkmark.shield")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
                
                Picker("Modèle :", selection: $settings.model) {
                    if isLoadingModels {
                        Text("Chargement...").tag("loading")
                    } else if availableModels.isEmpty {
                        Text(settings.model).tag(settings.model)
                    } else {
                        ForEach(availableModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }
                .pickerStyle(.menu)
                
                Stepper(value: $settings.numCtx, in: 2048...32768, step: 1024) {
                    Text("Contexte : \(settings.numCtx) tokens")
                }
            }
            
            Section("Hotkey global") {
                Stepper(value: $settings.hotkeyKeyCode, in: 0...126) {
                    Text("Keycode : \(settings.hotkeyKeyCode) (\(HotkeyNames.name(for: settings.hotkeyKeyCode)))")
                }
                Text("Appui court = afficher le HUD. Maintenir = dicter, relâcher = envoyer. Échap = refuser / interrompre (×2).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            
            Section("Voix") {
                Toggle("Dictée vocale", isOn: $settings.voiceEnabled)
                Toggle("Réponse parlée (TTS local)", isOn: $settings.ttsEnabled)
            }
            
            Section("Système") {
                TextField("Workspace :", text: $settings.workspacePath)
                    .textFieldStyle(.roundedBorder)
                Toggle("Lancement à l'ouverture de session", isOn: $settings.launchAtLogin)
            }
            
            Section("Informations") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text(getAppVersion())
                        .foregroundStyle(.secondary)
                }
                
                HStack {
                    Text("Statut connexion")
                    Spacer()
                    ConnectionIndicator(status: coordinator.connectionStatus)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 450)
        .navigationTitle("Réglages Jarvis")
        .onAppear {
            loadAvailableModels()
        }
        .onDisappear { settings.save() }
    }
    
    private func loadAvailableModels() {
        isLoadingModels = true
        Task {
            do {
                let models = try await fetchAvailableModels()
                availableModels = models
                isLoadingModels = false
            } catch {
                isLoadingModels = false
            }
        }
    }
    
    private func fetchAvailableModels() async throws -> [String] {
        guard let url = URL(string: "\(settings.ollamaURL.trimmingCharacters(in: .whitespacesAndNewlines))/api/tags") else {
            return []
        }
        
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            return []
        }
        
        return models.compactMap { $0["name"] as? String }
    }
    
    private func testConnection() {
        isLoadingModels = true
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // Délai artificiel pour feedback
            loadAvailableModels()
        }
    }
    
    private func getAppVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Inconnue"
    }
}

public enum HotkeyNames {
    public static func name(for keyCode: Int) -> String {
        switch keyCode {
        case 53: return "Échap"
        case 105: return "F13"
        case 107: return "F14"
        case 113: return "F15"
        case 49: return "Espace"
        case 36: return "Entrée"
        default: return "touche \(keyCode)"
        }
    }
}

/// L3 — onboarding : vérifie les permissions requises (micro, surveillance
/// de l'entrée pour le hotkey, capture d'écran à l'usage) avec un bouton de
/// test et l'ouverture directe des panneaux Système.
public struct OnboardingView: View {
    var onTestHotkey: () -> Void
    @State private var hotkeySeen = false

    public init(onTestHotkey: @escaping () -> Void) {
        self.onTestHotkey = onTestHotkey
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bienvenue dans Jarvis").font(.title2)
            permissionRow(
                title: "Micro",
                detail: "Dictée locale (Speech). Autoriser à la première dictée.",
                action: nil, actionLabel: "")
            permissionRow(
                title: "Surveillance de l'entrée",
                detail: "Hotkey global même quand une autre app est active. Réglages Système > Confidentialité > Surveillance de l'entrée.",
                action: HotkeyManager.openInputMonitoringSettings, actionLabel: "Ouvrir")
            permissionRow(
                title: "Capture d'écran",
                detail: "Demandée à la première capture uniquement (outil screenshot).",
                action: nil, actionLabel: "")
            HStack {
                Button(hotkeySeen ? "Hotkey détecté ✓" : "Tester le hotkey") { onTestHotkey() }
                    .buttonStyle(.glassProminent)
                    .disabled(hotkeySeen)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func permissionRow(title: String, detail: String, action: (() -> Void)?, actionLabel: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let action {
                Button(actionLabel, action: action).buttonStyle(.glass)
            }
        }
    }
}
