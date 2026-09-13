import Foundation

/// Config d'un serveur MCP stdio (ex. iMCP).
/// Pourquoi stdio et pas HTTP : iMCP tourne en local, stdio = pas de port,
/// pas de TLS, démarrage à la demande par Jarvis.
struct MCPServerConfig: Codable, Sendable, Equatable {
    var id: String          // "imcp"
    var command: String     // commande serveur résolue dynamiquement (jamais en dur) ; ex. "/Applications/iMCP.app/Contents/MacOS/imcp-server"
    var args: [String]      // args du serveur (vide pour imcp-server : un seul serveur multi-domaines)
    var enabled: Bool
    var delegatedTools: Set<String> // outils qu'on accepte de déléguer à ce serveur

    /// Commande serveur iMCP RÉSOLUE, jamais codée en dur.
    /// Pourquoi : iMCP s'installe comme app (`iMCP.app`, via `brew install --cask
    /// mattt/tap/iMCP` ou https://iMCP.app/download) et expose UN seul serveur stdio
    /// `imcp-server` — pas un binaire `imcp` à sous-commandes par domaine. Un chemin
    /// en dur casserait sur toute install non-Homebrew (et Homebrew diffère déjà
    /// entre Intel / Apple Silicon).
    /// Ordre de résolution : env JARVIS_IMCP_PATH > Réglages (UserDefaults
    /// "imcp_path") > bundle iMCP.app > `which imcp-server` > "imcp-server" (PATH).
    /// Si rien n'est trouvé, on retourne quand même "imcp-server" : le transport
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
        // 3. Bundle officiel iMCP.app (install Homebrew cask ou DMG).
        let bundled = "/Applications/iMCP.app/Contents/MacOS/imcp-server"
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        // 4. `which imcp-server` — couvre les installs custom dans le PATH.
        if let viaWhich = which("imcp-server") { return viaWhich }
        // 5. Fallback : laisse l'OS résoudre via PATH au spawn.
        // Le transport gère l'échec (binaire absent → hors-ligne, pas de crash).
        return "imcp-server"
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
        // UN seul serveur : `imcp-server` expose tous les domaines (calendrier,
        // rappels, contacts, messages, localisation, plans) sur une connexion
        // stdio. La commande est résolue à l'appel (pas à la compilation) pour
        // suivre un changement de Réglages sans recompiler.
        // NOTE : après install iMCP, activer chaque service dans l'app (menu bar)
        // et approuver JarvisLocal ("Always trust this client"), sinon tools/list
        // répond vide et le natif reste en relais.
        let bin = resolveIMCPBinary()
        return [
            MCPServerConfig(
                id: "imcp",
                command: bin,
                args: [],
                enabled: true,
                delegatedTools: [
                    "add_calendar_event", "get_calendars", "get_upcoming_events",
                    "add_reminder", "list_reminders",
                    "lookup_contact",
                    "send_message",
                    "search_maps",
                ]
            ),
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
