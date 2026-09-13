import Foundation

/// Fournisseur MCP : connecte les serveurs configurés au démarrage,
/// fusionne leurs tools pour Ollama, route `execute()` vers stdio.
/// Pourquoi un actor : les connexions (démarrage app, toggle Réglages) et les
/// `tools/call` concurrents du tour ne doivent pas se marcher dessus.
/// Dégradation gracieuse : un serveur qui échoue (binaire absent, iMCP non
/// installé) est marqué hors-ligne et le natif prend le relais — jamais de crash.
actor MCPToolProvider {
    private let configs: [MCPServerConfig]
    private var transports: [String: MCPStdioTransport] = [:]
    private var remoteTools: [String: MCPRemoteTool] = [:] // nom outil → outil
    private var online: Set<String> = []

    /// Outils qui RESTENT natifs même si un serveur MCP les propose.
    /// Pourquoi : locaux/sensibles/rapides — pas de round-trip externe,
    /// pas de permission tierce, audit direct. Tant qu'aucun serveur MCP de
    /// recherche web équivalent n'est en place, search_web reste natif.
    static let nativeOnly: Set<String> = [
        "sleep_mac", "applescript", "take_screenshot",
        "get_clipboard", "set_clipboard", "search_web", "read_url",
        "get_system_info", "file_search", "run_shortcut", "remember_fact",
        "open_app", "create_note", "edit_note", "run_routine", "get_weather",
    ]

    init(configs: [MCPServerConfig]? = nil) {
        // Résolu à l'init (pas à la compilation) : un changement de Réglages
        // (imcp_path) est pris en compte à la prochaine création du provider.
        self.configs = configs ?? MCPServerConfig.imcpDefaults()
    }

    /// Connexion au démarrage (appelée depuis JarvisLocalApp, en Task de fond :
    /// le spawn de plusieurs process prend ~1s et ne doit pas retarder l'UI).
    /// Un serveur qui échoue est simplement marqué hors-ligne.
    func connectAll() async {
        for cfg in configs where cfg.enabled {
            let t = MCPStdioTransport()
            do {
                try await t.start(command: cfg.command, args: cfg.args)
                // Handshake MCP minimal : initialize PUIS notifications/initialized
                // (sans cette notification, iMCP retient tools/list en file et le
                // premier appel timeout une fois sur deux — constaté en test réel).
                _ = try await t.request(method: "initialize", params: [
                    "protocolVersion": "2024-11-05",
                    "capabilities": [:] as [String: Any],
                    "clientInfo": ["name": "JarvisLocal", "version": "0.4.0"],
                ])
                try await t.notify(method: "notifications/initialized")
                // Settle : iMCP relaie vers l'app via Bonjour de façon asynchrone ;
                // envoyer tools/list dans la même milliseconde que le handshake la fait
                // tomber dans un vide (relais pas encore établi → réponse après 20s+
                // voire jamais). 1s d'attente rend la connexion déterministe.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let res = try await t.request(method: "tools/list")
                transports[cfg.id] = t
                online.insert(cfg.id)
                for tool in Self.parseToolsList(res, serverId: cfg.id) {
                    // Ne délègue que ce qui est explicitement autorisé, et jamais
                    // un outil de la liste nativeOnly (garde-fou anti-délégation
                    // accidentelle si un serveur expose "applescript" ou autre).
                    guard cfg.delegatedTools.contains(tool.name),
                          !Self.nativeOnly.contains(tool.name)
                    else { continue }
                    remoteTools[tool.name] = tool
                }
            } catch {
                // Hors-ligne : on ne stocke pas le transport, le natif reste.
                continue
            }
        }
    }

    func disconnectAll() async {
        for t in transports.values { await t.stop() }
        transports = [:]; remoteTools = [:]; online = []
    }

    func handles(tool name: String) -> Bool { remoteTools[name] != nil }

    /// Correspondance outil natif → outil MCP qui le remplace quand le serveur
    /// est en ligne. Pourquoi : le modèle ne doit voir qu'UN outil par action —
    /// exposer `add_calendar_event` ET `events_create` = confusion + double schema.
    /// Le natif reste exécutable en fallback direct via `execute()` (jamais supprimé).
    /// Noms MCP vérifiés en test réel (serveur v1.4.1) ; `send_message` n'y figure
    /// PAS (iMCP = lecture seule sur Messages) et reste donc toujours natif.
    nonisolated static let nativeToMCP: [String: String] = [
        "add_calendar_event": "events_create",
        "get_calendars": "calendars_list",
        "get_upcoming_events": "events_fetch",
        "add_reminder": "reminders_create",
        "list_reminders": "reminders_fetch",
    ]

    /// Noms natifs masqués de la liste Ollama car couverts par MCP en ligne.
    func supersededNativeTools() -> Set<String> {
        Set(Self.nativeToMCP.filter { remoteTools[$0.value] != nil }.keys)
    }

    /// Injection pour tests (sans serveur) : simule un outil distant en ligne.
    /// `internal` pour les tests — le chemin réel reste connectAll().
    func registerForTests(_ tool: MCPRemoteTool) { remoteTools[tool.name] = tool }

    func toolDefs() -> [ToolDef] {
        remoteTools.values.map { $0.asToolDef() }.sorted { $0.function.name < $1.function.name }
    }

    func call(tool name: String, args: [String: Any]) async throws -> String {
        guard let rt = remoteTools[name],
              let t = transports[rt.serverId]
        else { throw MCPError.offline(name) }
        let res = try await t.request(method: "tools/call", params: ["name": name, "arguments": args])
        // Format MCP : {content:[{type:"text",text:"..."}]}.
        if let content = res["content"] as? [[String: Any]] {
            let texts = content.compactMap { $0["text"] as? String }
            if !texts.isEmpty { return texts.joined(separator: "\n") }
        }
        if let s = res["result"] as? String { return s }
        return "Outil MCP \(name) exécuté (réponse vide)."
    }

    nonisolated static func parseToolsList(_ res: [String: Any], serverId: String) -> [MCPRemoteTool] {
        guard let tools = res["tools"] as? [[String: Any]] else { return [] }
        return tools.compactMap { t in
            guard let n = t["name"] as? String else { return nil }
            return MCPRemoteTool(serverId: serverId, name: n,
                                 description: t["description"] as? String ?? "",
                                 inputSchema: t["inputSchema"] as? [String: Any] ?? [:])
        }
    }
}
