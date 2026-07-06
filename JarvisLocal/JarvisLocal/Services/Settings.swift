import Foundation
import Observation
import AVFoundation
import os.log

@Observable
final class Settings {
    static let shared = Settings()

    var ollamaURL: String {
        didSet { UserDefaults.standard.set(ollamaURL, forKey: "ollama_url") }
    }
    var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "model") }
    }
    var fastModel: String {
        didSet { UserDefaults.standard.set(fastModel, forKey: "fast_model") }
    }
    var ttsEnabled: Bool {
        didSet { UserDefaults.standard.set(ttsEnabled, forKey: "tts_enabled") }
    }
    var voiceEnabled: Bool {
        didSet { UserDefaults.standard.set(voiceEnabled, forKey: "voice_enabled") }
    }
    var ttsVoiceIdentifier: String {
        didSet { UserDefaults.standard.set(ttsVoiceIdentifier, forKey: "tts_voice") }
    }
    var ttsEngine: TTSEngine {
        didSet { UserDefaults.standard.set(ttsEngine.rawValue, forKey: "tts_engine") }
    }
    var edgeTTSVoice: String {
        didSet { UserDefaults.standard.set(edgeTTSVoice, forKey: "edge_tts_voice") }
    }
    private(set) var edgeTTSAvailable = false

    func refreshEdgeTTSAvailability() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["edge-tts"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        edgeTTSAvailable = task.terminationStatus == 0
    }

    /// Coupe-circuit pour le barge-in. À désactiver si le Mac n'a pas de casque et que le micro
    /// capte sa propre sortie audio (pas d'AEC fiable sur haut-parleurs internes selon le device) :
    /// symptôme observable = Jarvis se coupe la parole tout seul en permanence.
    var bargeInEnabled: Bool {
        didSet { UserDefaults.standard.set(bargeInEnabled, forKey: "barge_in_enabled") }
    }

    /// Retourne toutes les voix françaises disponibles
    var availableFrenchVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("fr-") }
            .sorted { a, b in a.quality.rawValue > b.quality.rawValue }
    }

    /// Retourne la voix sélectionnée, ou la meilleure disponible
    var selectedVoice: AVSpeechSynthesisVoice? {
        if let id = ttsVoiceIdentifier.isEmpty ? nil : ttsVoiceIdentifier,
           let voice = availableFrenchVoices.first(where: { $0.identifier == id }) {
            return voice
        }
        return availableFrenchVoices.first
    }

    var updateAvailable = false
    var updateCheckError: String?
    var isCheckingUpdate = false

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// Vérifie si une nouvelle version est disponible sur GitHub Releases.
    /// Configurez `repoOwner` et `repoName` pour votre dépôt.
    func checkForUpdates(repoOwner: String = "dimitricl", repoName: String = "jarvis-local") async {
        isCheckingUpdate = true
        updateCheckError = nil
        updateAvailable = false
        do {
            let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
            var req = URLRequest(url: url)
            req.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 10
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                updateCheckError = "Impossible de contacter GitHub."
                isCheckingUpdate = false
                return
            }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let latest = json?["tag_name"] as? String ?? ""
            guard !latest.isEmpty else {
                updateCheckError = "Aucune release trouvée."
                isCheckingUpdate = false
                return
            }
            let cleanLatest = latest.hasPrefix("v") ? String(latest.dropFirst()) : latest
            updateAvailable = cleanLatest.compare(currentVersion, options: .numeric) == .orderedDescending
            if !updateAvailable {
                updateCheckError = "Vous avez la dernière version (\(currentVersion))."
            }
        } catch {
            updateCheckError = "Erreur : \(error.localizedDescription)"
        }
        isCheckingUpdate = false
    }

    private init() {
        let defaults = UserDefaults.standard
        self.ollamaURL = defaults.string(forKey: "ollama_url") ?? "http://localhost:11434"
        self.model = defaults.string(forKey: "model") ?? "gemma4:e4b"
        self.fastModel = defaults.string(forKey: "fast_model") ?? "gemma4:e2b"
        self.ttsEnabled = defaults.bool(forKey: "tts_enabled")
        self.voiceEnabled = defaults.bool(forKey: "voice_enabled")
        self.ttsVoiceIdentifier = defaults.string(forKey: "tts_voice") ?? ""
        self.ttsEngine = TTSEngine(rawValue: defaults.string(forKey: "tts_engine") ?? "") ?? .system
        self.edgeTTSVoice = defaults.string(forKey: "edge_tts_voice") ?? "fr-FR-HenriNeural"
        self.bargeInEnabled = defaults.object(forKey: "barge_in_enabled") as? Bool ?? true

        refreshEdgeTTSAvailability()
    }
}

enum TTSEngine: String, CaseIterable, Hashable {
    case system
    case edgeTTS

    var label: String {
        switch self {
        case .system:   "Synthèse macOS"
        case .edgeTTS:  "Edge TTS (en ligne)"
        }
    }
}
