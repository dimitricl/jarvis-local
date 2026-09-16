import Foundation
import JarvisCore
import Observation
import AVFoundation
import ServiceManagement
import os

/// Configuration applicative persistée (UserDefaults + SMAppService).
/// Implémentation concrète du protocol AppSettingsProtocol (JarvisCore) :
/// I/O persistante = vit dans JarvisServices, comme DatabaseService.
/// L'UI ne retient que `any AppSettingsProtocol`.
@Observable
public final class Settings: AppSettingsProtocol {
    public static let shared = Settings()

    public var ollamaURL: String {
        didSet { UserDefaults.standard.set(ollamaURL, forKey: "ollama_url") }
    }
    public var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "model") }
    }
    public var fastModel: String {
        didSet { UserDefaults.standard.set(fastModel, forKey: "fast_model") }
    }
    /// Effort de raisonnement envoyé à Ollama ("none", "low", "medium", "high").
    /// "none" par défaut : le raisonnement caché de gemma4 ajoutait 20-30s de latence
    /// invisible par tour (et par itération de tools), sans gain perceptible pour un assistant.
    public var reasoningEffort: String {
        didSet { UserDefaults.standard.set(reasoningEffort, forKey: "reasoning_effort") }
    }
    /// Fenêtre de contexte envoyée à Ollama (options.num_ctx). Une valeur énorme gonfle le
    /// KV-cache côté serveur et ralentit chaque tour ; 16384 correspond au plafond réel que le
    /// serveur distant peut allouer (vérifié via ollama ps — tout ce qui est demandé au-delà
    /// est silencieusement tronqué).
    public var numCtx: Int {
        didSet {
            let clamped = max(2048, min(numCtx, 32768))
            if clamped != numCtx { numCtx = clamped; return }
            UserDefaults.standard.set(numCtx, forKey: "num_ctx")
        }
    }
    /// Nombre max de tokens générés par réponse (num_predict côté Ollama).
    /// AVANT : 2048 codé en dur — en français (~0.7 mot/token) une réponse longue était
    /// coupée en pleine phrase sans aucun message d'erreur. Réglable depuis les paramètres.
    public var maxTokens: Int {
        didSet {
            // Clamp défensif : une valeur absurde (0, négatif, énorme) ne doit jamais
            // partir vers Ollama ni se persistée telle quelle.
            let clamped = max(256, min(maxTokens, 32768))
            if clamped != maxTokens { maxTokens = clamped; return }
            UserDefaults.standard.set(maxTokens, forKey: "max_tokens")
        }
    }
    /// Température d'échantillonnage (0.0–2.0). 0.7 par défaut (comportement historique).
    /// Baisser (~0.2) rend les réponses factuelles plus fidèles (moins de chiffres brodés
    /// type "43 h / +80 %"), au prix d'une personnalité plus plate ; monter rend Jarvis
    /// plus créatif mais plus confabulateur. Réglable depuis les paramètres.
    public var temperature: Double {
        didSet {
            let clamped = max(0, min(temperature, 2))
            if clamped != temperature { temperature = clamped; return }
            UserDefaults.standard.set(temperature, forKey: "temperature")
        }
    }
    /// Budget anti-boucle (étape 4) : nombre max d'invocations d'UN MÊME outil par
    /// tour de conversation. Le filtre exact existant (mêmes args) ne coupe pas un
    /// modèle qui reformule sa requête en boucle avec des args toujours différents —
    /// ce compteur par nom, si. 4 par défaut : les enchaînements légitimes
    /// (recherche → lecture → note…) n'appellent jamais 4× le même outil dans un
    /// tour, une boucle si.
    public var maxToolCallsPerTurn: Int {
        didSet {
            let clamped = max(1, min(maxToolCallsPerTurn, 10))
            if clamped != maxToolCallsPerTurn { maxToolCallsPerTurn = clamped; return }
            UserDefaults.standard.set(maxToolCallsPerTurn, forKey: "max_tool_calls_per_turn")
        }
    }
    public var ttsEnabled: Bool {
        didSet { UserDefaults.standard.set(ttsEnabled, forKey: "tts_enabled") }
    }
    /// Lancement à l'ouverture de session (SMAppService, macOS 13+).
    /// Lu depuis le vrai statut au démarrage (l'utilisateur a pu le changer dans
    /// Réglages Système sans passer par l'app) ; appliqué à chaque bascule.
    public var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: "launch_at_login")
            Self.applyLaunchAtLogin(launchAtLogin)
        }
    }

    /// NOTE : `internal`/`static` pour les tests d'aucune sorte (API système,
    /// pas de logique) — exposée pour que l'App et les Réglages partagent le point d'appel.
    nonisolated static func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Échec silencieux volontaire (ex. CI sans session Aqua) : le toggle
            // reflète la demande, ré-appliquée au prochain lancement via l'init.
        }
    }
    public var voiceEnabled: Bool {
        didSet { UserDefaults.standard.set(voiceEnabled, forKey: "voice_enabled") }
    }
    public var ttsVoiceIdentifier: String {
        didSet { UserDefaults.standard.set(ttsVoiceIdentifier, forKey: "tts_voice") }
    }

    /// Coupe-circuit pour le barge-in. À désactiver si le Mac n'a pas de casque et que le micro
    /// capte sa propre sortie audio (pas d'AEC fiable sur haut-parleurs internes selon le device) :
    /// symptôme observable = Jarvis se coupe la parole tout seul en permanence.
    public var bargeInEnabled: Bool {
        didSet { UserDefaults.standard.set(bargeInEnabled, forKey: "barge_in_enabled") }
    }

    /// Active la délégation MCP (chantier 5 : iMCP pour Calendrier/Rappels/Contacts/Messages).
    /// Désactivé par défaut : sans iMCP installé, le provider resterait hors-ligne de toute
    /// façon, mais le flag évite même de spawner des process pour rien au démarrage.
    public var mcpEnabled: Bool {
        didSet { UserDefaults.standard.set(mcpEnabled, forKey: "mcp_enabled") }
    }
    /// Chemin du binaire iMCP (Réglages > MCP). Vide = résolution automatique
    /// (env JARVIS_IMCP_PATH > `which imcp` > /opt/homebrew/bin, /usr/local/bin…).
    /// Pourquoi un champ plutôt qu'une constante : le chemin Homebrew diffère
    /// entre Mac Intel (/usr/local) et Apple Silicon (/opt/homebrew).
    public var imcpPath: String {
        didSet { UserDefaults.standard.set(imcpPath, forKey: "imcp_path") }
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

    /// Version données pures de availableFrenchVoices pour le protocol
    /// AppSettingsProtocol (JarvisCore ne connaît pas AVFoundation).
    /// Libellés identiques à ceux affichés historiquement dans les Réglages.
    public var frenchVoiceOptions: [VoiceOption] {
        availableFrenchVoices.map { voice in
            VoiceOption(
                identifier: voice.identifier,
                name: voice.name,
                language: voice.language,
                qualityLabel: voice.quality == .premium ? "Premium"
                    : voice.quality == .enhanced ? "Enhanced" : "Compact"
            )
        }
    }

    public var updateAvailable = false
    public var updateCheckError: String?
    public var isCheckingUpdate = false
    var lastCheckDate: Date?

    public var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// Vérifie si une nouvelle version est disponible sur GitHub Releases.
    /// Configurez `repoOwner` et `repoName` pour votre dépôt.
    public func checkForUpdates(repoOwner: String = "dimitricl", repoName: String = "jarvis-local") async {
        // Throttling : ne vérifie pas plus souvent qu'une fois par jour
        if let lastCheck = lastCheckDate,
           abs(Date().timeIntervalSince(lastCheck)) < 86400 {
            isCheckingUpdate = false
            return
        }
        lastCheckDate = Date()
        isCheckingUpdate = true
        updateCheckError = nil
        updateAvailable = false
        do {
            let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
            var req = URLRequest(url: url)
            req.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 10
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                updateCheckError = "Impossible de contacter GitHub."
                isCheckingUpdate = false
                return
            }
            guard http.statusCode == 200 else {
                if http.statusCode == 404 {
                    updateCheckError = "Aucune release trouvée sur GitHub. Crée un tag (ex: v1.0) pour activer la vérification."
                } else if http.statusCode == 403 {
                    updateCheckError = "Limite de requêtes GitHub dépassée. Réessaie plus tard."
                } else {
                    updateCheckError = "GitHub a répondu avec le code \(http.statusCode)."
                }
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
            let cleanLatest = latest.lowercased().hasPrefix("v") ? String(latest.dropFirst()) : latest
            updateAvailable = cleanLatest.compare(currentVersion, options: .numeric) == .orderedDescending
            if !updateAvailable {
                updateCheckError = "Vous avez la dernière version (\(currentVersion))."
            }
        } catch {
            updateCheckError = "Erreur : \(error.localizedDescription)"
        }
        // Sauvegarde de la date de dernière vérification
        UserDefaults.standard.set(lastCheckDate?.timeIntervalSince1970, forKey: "last_check_date")
        isCheckingUpdate = false
    }

private init() {
        let defaults = UserDefaults.standard
        self.ollamaURL = defaults.string(forKey: "ollama_url") ?? "http://localhost:11434"
        self.model = defaults.string(forKey: "model") ?? "gemma4:e4b"
        self.fastModel = defaults.string(forKey: "fast_model") ?? "gemma4:e2b"
        self.reasoningEffort = defaults.string(forKey: "reasoning_effort") ?? "none"
        let savedNumCtx = defaults.object(forKey: "num_ctx") as? Int ?? 16384
        self.numCtx = max(2048, min(savedNumCtx, 32768))
        // 32768 (et non 8192) : absorbe un finish_reason=length transitoire observé
        // en usage réel sur un tour post-tool ; deux sondes statiques (stream:false)
        // avec le même contexte n'ont pas reproduit de raisonnement caché — la cause
        // précise reste non identifiée, possiblement spécifique au streaming ; si le
        // problème récidive, envisager la migration vers /api/chat natif avec
        // think:false explicite plutôt que remonter encore le plafond.
        let savedMaxTokens = defaults.object(forKey: "max_tokens") as? Int ?? 32768
        self.maxTokens = max(256, min(savedMaxTokens, 32768))
        let savedToolBudget = defaults.object(forKey: "max_tool_calls_per_turn") as? Int ?? 4
        self.maxToolCallsPerTurn = max(1, min(savedToolBudget, 10))
        let savedTemp = defaults.object(forKey: "temperature") as? Double ?? 0.7
        self.temperature = max(0, min(savedTemp, 2))
        self.ttsEnabled = defaults.bool(forKey: "tts_enabled")
        // Statut réel plutôt que préférence mémorisée (cf. commentaire propriété).
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.voiceEnabled = defaults.bool(forKey: "voice_enabled")
        self.ttsVoiceIdentifier = defaults.string(forKey: "tts_voice") ?? ""
        // Remis à true par défaut : le déclencheur est maintenant protégé par une fenêtre de grâce
        // de 600ms + un debounce (2 partials consécutifs requis) côté AppViewModel, ce qui devrait
        // éliminer la plupart des faux positifs qui avaient probablement motivé le passage à false.
        // Si ça se déclenche encore tout seul sur haut-parleurs internes, repasse ce flag à false
        // depuis les Réglages plutôt que de retoucher le code.
        self.bargeInEnabled = defaults.object(forKey: "barge_in_enabled") as? Bool ?? true
        self.mcpEnabled = defaults.object(forKey: "mcp_enabled") as? Bool ?? false
        self.imcpPath = defaults.string(forKey: "imcp_path") ?? ""

        // Restore last check date for update throttling
        let savedLastCheck = defaults.object(forKey: "last_check_date") as? Double
        self.lastCheckDate = savedLastCheck.map { Date(timeIntervalSince1970: $0) }
    }

    /// true si l'hôte Ollama configuré est local (localhost, 127.x, ::1).
    /// Utilisé par les Réglages pour avertir qu'une URL distante envoie
    /// l'historique et les faits hors de la machine (souvent en clair).
    public var ollamaHostIsLocal: Bool {
        guard let host = URL(string: ollamaURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else {
            return false
        }
        return Self.isLocalHostname(host)
    }

    /// NOTE : `internal`/`static` pour les tests — fonction pure.
    nonisolated static func isLocalHostname(_ host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" || host == "::1" { return true }
        // 127.0.0.0/8 en entier (127.0.0.2, 127.1…).
        let parts = host.split(separator: ".")
        if parts.count == 4, parts[0] == "127", parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return true }
        return false
    }
}
