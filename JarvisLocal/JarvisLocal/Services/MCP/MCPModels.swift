import Foundation

/// Config d'un serveur MCP stdio (ex. iMCP).
/// Pourquoi stdio et pas HTTP : iMCP tourne en local, stdio = pas de port,
/// pas de TLS, démarrage à la demande par Jarvis.
struct MCPServerConfig: Codable, Sendable, Equatable {
    var id: String          // "imcp-calendar"
    var command: String     // binaire résolu dynamiquement (jamais codé en dur)
    var args: [String]      // ["calendar"] — un process par domaine iMCP
    var enabled: Bool
    var delegatedTools: Set<String> // outils qu'on accepte de déléguer à ce serveur

    /// Binaires par défaut : le chemin est RÉSOLU, pas codé en dur.
    /// Pourquoi : `/opt/homebrew/bin/imcp` n'existe que sur Mac Apple Silicon
    /// avec Homebrew — sur Intel c'est `/usr/local/bin`, et iMCP peut aussi
    /// être installé ailleurs (cargo, make install…). Un chemin en dur casse
    /// au premier Mac différent (cf. consigne chantier 5).
    /// Ordre de résolution : env JARVIS_IMCP_PATH > Réglages (UserDefaults
    /// "imcp_path") > `which imcp` > chemins usuels > "imcp" (PATH).
    /// Si rien n'est trouvé, on retourne quand même "imcp" : le transport
    /// échouera proprement et le serveur sera marqué hors-ligne (natif en relais).
    static func resolveIMCPBinary() -> String {
        // 1. Variable d'environnement (CI, debug, install custom).
        if let env = ProcessInfo.processInfo.environment["JARVIS_IMCP_PATH"],
           !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        // 2. Champ Réglages (l'utilisateur colle son chemin une fois).
        if let saved = UserDefaults.standard.string(forKey: "imcp_path"),
           !saved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if FileManager.default.isExecutableFile(atPath: saved) { return saved }
            // Chemin invalide sauvegardé : on continue la résolution au lieu
            // de casser (l'utilisateur a peut-être désinstallé/déplacé iMCP).
        }
        // 3. `which imcp` — couvre Homebrew (arm64 + Intel), MacPorts, cargo…
        if let viaWhich = which("imcp") { return viaWhich }
        // 4. Chemins usuels en dernier recours (pas de which dispo en sandbox).
        for candidate in ["/opt/homebrew/bin/imcp", "/usr/local/bin/imcp", "/opt/local/bin/imcp"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        // 5. Fallback : laisse l'OS résoudre via PATH au spawn.
        // Le transport gère l'échec (binaire absent → hors-ligne, pas de crash).
        return "imcp"
    }

    /// `which` synchrone, timeout court. Utilisé au démarrage uniquement,
    /// jamais pendant un tour de conversation (ne doit pas ajouter de latence).
    static func which(_ bin: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = [bin]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return out.isEmpty ? nil : out
    }

    static func imcpDefaults() -> [MCPServerConfig] {
        // iMCP expose un binaire avec un sous-domaine en argument ; le binaire
        // est résolu à l'appel (pas à la compilation) pour suivre un changement
        // de Réglages sans recompiler.
        let bin = resolveIMCPBinary()
        return [
            MCPServerConfig(id: "imcp-calendar", command: bin, args: ["calendar"], enabled: true, delegatedTools: ["add_calendar_event", "get_calendars", "get_upcoming_events"]),
            MCPServerConfig(id: "imcp-reminders", command: bin, args: ["reminders"], enabled: true, delegatedTools: ["add_reminder", "list_reminders"]),
            MCPServerConfig(id: "imcp-contacts", command: bin, args: ["contacts"], enabled: true, delegatedTools: ["lookup_contact"]),
            MCPServerConfig(id: "imcp-messages", command: bin, args: ["messages"], enabled: true, delegatedTools: ["send_message"]),
            MCPServerConfig(id: "imcp-location", command: bin, args: ["location"], enabled: false, delegatedTools: ["search_maps"]),
        ]
    }
}

/// Tool MCP distant normalisé vers ToolDef Ollama.
/// Pourquoi normaliser : Ollama attend `{type,function:{name,description,parameters}}` ;
/// MCP envoie `inputSchema` JSON-Schema — mapping direct.
struct MCPRemoteTool: Sendable {
    let serverId: String
    let name: String
    let description: String
    let inputSchema: [String: Any]

    func asToolDef() -> ToolDef {
        var props: [String: ToolProperty] = [:]
        if let ps = inputSchema["properties"] as? [String: [String: String]] {
            for (k, v) in ps { props[k] = ToolProperty(type: v["type"] ?? "string", description: v["description"]) }
        }
        let req = inputSchema["required"] as? [String] ?? []
        return ToolDef(function: ToolFunction(name: name, description: "[MCP:\(serverId)] \(description)", parameters: ToolParameters(properties: props, required: req)))
    }
}
