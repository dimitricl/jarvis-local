import Foundation
import ServiceManagement

/// L3 — réglages du shell (UserDefaults). Aucun hôte en dur : l'URL du
/// serveur vient d'ici (ou d'env au premier lancement).
public struct ShellSettings: Sendable {
    private static let urlKey = "shell.ollama_url"
    private static let modelKey = "shell.model"
    private static let numCtxKey = "shell.num_ctx"
    private static let hotkeyKey = "shell.hotkey_keycode"
    private static let voiceKey = "shell.voice_enabled"
    private static let ttsKey = "shell.tts_enabled"
    private static let workspaceKey = "shell.workspace"
    private static let launchKey = "shell.launch_at_login"

    public var ollamaURL: String
    public var model: String
    public var numCtx: Int
    /// Keycode du hotkey (défaut : F13 = 105, discret et rarement pris).
    public var hotkeyKeyCode: Int
    public var voiceEnabled: Bool
    public var ttsEnabled: Bool
    public var workspacePath: String
    public var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Self.launchKey)
            Self.applyLaunchAtLogin(launchAtLogin)
        }
    }

    public init(defaults: UserDefaults = .standard) {
        let env = ProcessInfo.processInfo.environment
        self.ollamaURL = defaults.string(forKey: Self.urlKey)
            ?? env["JARVIS_OLLAMA_URL"]
            ?? "http://localhost:11434"
        self.model = defaults.string(forKey: Self.modelKey)
            ?? env["JARVIS_MODEL"] ?? "gemma4:e4b"
        let savedCtx = defaults.object(forKey: Self.numCtxKey) as? Int ?? 16384
        self.numCtx = max(2048, min(savedCtx, 32768))
        self.hotkeyKeyCode = defaults.object(forKey: Self.hotkeyKey) as? Int ?? 105
        self.voiceEnabled = defaults.object(forKey: Self.voiceKey) as? Bool ?? true
        self.ttsEnabled = defaults.object(forKey: Self.ttsKey) as? Bool ?? false
        self.workspacePath = defaults.string(forKey: Self.workspaceKey)
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        self.launchAtLogin = defaults.object(forKey: Self.launchKey) as? Bool
            ?? (SMAppService.mainApp.status == .enabled)
    }

    public func save(defaults: UserDefaults = .standard) {
        defaults.set(ollamaURL, forKey: Self.urlKey)
        defaults.set(model, forKey: Self.modelKey)
        defaults.set(numCtx, forKey: Self.numCtxKey)
        defaults.set(hotkeyKeyCode, forKey: Self.hotkeyKey)
        defaults.set(voiceEnabled, forKey: Self.voiceKey)
        defaults.set(ttsEnabled, forKey: Self.ttsKey)
        defaults.set(workspacePath, forKey: Self.workspaceKey)
    }

    static func applyLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            // CI sans session Aqua : le toggle reflète la demande.
        }
    }

    /// true si l'hôte configuré sort de la machine (avertissement).
    public var isRemote: Bool {
        guard let host = URL(string: ollamaURL.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased()
        else { return true }
        if host == "localhost" || host == "::1" { return false }
        let parts = host.split(separator: ".")
        if parts.count == 4, parts[0] == "127",
           parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) { return false }
        return true
    }
}
