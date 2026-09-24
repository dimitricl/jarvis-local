@testable import JarvisServices
import Testing

/// Chantier 5 : client MCP. Aucun test ne requiert iMCP installé ni le réseau :
/// parsing pur, listes de garde, et dégradation gracieuse (binaire absent).
@Suite(.serialized)
struct MCPToolProviderTests {
    @Test func `Tool list parsing maps its input schema`() {
        let res: [String: Any] = ["tools": [
            ["name": "add_calendar_event", "description": "Crée un événement",
             "inputSchema": ["properties": ["title": ["type": "string", "description": "Titre"]], "required": ["title"]]]
        ]]
        let got = MCPToolProvider.parseToolsList(res, serverId: "imcp-calendar")
        #expect(got.count == 1)
        #expect(got[0].asToolDef().function.parameters.required == ["title"])
        #expect(got[0].asToolDef().function.description.contains("MCP"))
    }

    @Test func `Tool list parsing rejects malformed responses`() {
        #expect(MCPToolProvider.parseToolsList([:], serverId: "x").isEmpty)
        #expect(MCPToolProvider.parseToolsList(["tools": "nope"], serverId: "x").isEmpty)
    }

    @Test func `Native-only tools are never delegated`() {
        // Locaux/sensibles/rapides : jamais délégués à MCP.
        for t in ["sleep_mac", "applescript", "take_screenshot", "get_clipboard",
                  "set_clipboard", "search_web", "read_url", "get_system_info",
                  "remember_fact", "open_app", "get_weather"] {
            #expect(MCPToolProvider.nativeOnly.contains(t), "\(t) doit rester natif")
        }
    }

    @Test func `Only approved tools can be delegated`() {
        let config = MCPServerConfig(
            id: "test",
            command: "/bin/echo",
            args: [],
            enabled: true,
            delegatedTools: ["events_create", "applescript", "run_shell"]
        )

        #expect(MCPToolProvider.mayDelegate(tool: "events_create", configuration: config))
        #expect(!MCPToolProvider.mayDelegate(tool: "applescript", configuration: config))
        #expect(!MCPToolProvider.mayDelegate(tool: "run_shell", configuration: config))
    }

    @Test func `Unknown tools are not handled`() async {
        let p = MCPToolProvider(configs: [])
        let h = await p.handles(tool: "add_calendar_event")
        #expect(!h)
    }

    @Test func `Missing binaries leave their MCP server offline`() async {
        // Binaire inexistant : pas de throw, pas de crash — hors-ligne, natif en relais.
        let cfg = MCPServerConfig(id: "faux", command: "/chemin/inexistant/imcp-xyz", args: [], enabled: true, delegatedTools: ["x"])
        let p = MCPToolProvider(configs: [cfg])
        await p.connectAll()
        let h = await p.handles(tool: "x")
        #expect(!h)
        let defs = await p.toolDefs()
        #expect(defs.isEmpty)
    }

    @Test func `iMCP binary resolution is never empty`() {
        // La résolution ne retourne jamais "" : au pire "imcp" (PATH),
        // et le transport gère l'absence proprement.
        #expect(!MCPServerConfig.resolveIMCPBinary().isEmpty)
    }

    @Test func `iMCP defaults do not hardcode a Homebrew path`() {
        // Consigne chantier 5 : aucun /opt/homebrew codé en dur dans les defaults.
        // Le binaire vient de la résolution dynamique (env > Réglages > which > usuels).
        for cfg in MCPServerConfig.imcpDefaults() {
            #expect(!cfg.command.hasPrefix("/opt/homebrew"),
                            "\(cfg.id) : chemin Homebrew en dur interdit, utilise resolveIMCPBinary()")
            #expect(!cfg.command.isEmpty)
        }
    }

    @Test func `MCP errors have explicit descriptions`() {
        #expect(MCPError.binaryNotFound("imcp").description.contains("introuvable"))
        #expect(MCPError.offline("x").description.contains("hors-ligne"))
        #expect(MCPError.notAuthorized("run_shell").description.contains("non autorisé"))
    }

    @Test func `Delegated tools use verified iMCP names`() {
        // Régression constatée en test réel : les premiers noms délégués
        // (add_calendar_event, send_message…) étaient inventés et ne matchaient
        // RIEN côté serveur v1.4.1. Cette liste blanche = les tools réellement
        // exposés (constaté via tools/list) ; tout ajout futur doit y figurer.
        let realNames: Set<String> = [
            "calendars_list", "events_fetch", "events_create",
            "reminders_lists", "reminders_fetch", "reminders_create",
            "contacts_me", "contacts_search", "contacts_update", "contacts_create",
            "messages_fetch",
            "maps_search", "maps_directions", "maps_explore", "maps_eta", "maps_generate",
            "location_current", "location_geocode", "location_reverse-geocode",
            "weather_current", "weather_daily", "weather_hourly", "weather_minute",
            "shortcuts_list", "shortcuts_run",
            "capture_take_picture", "capture_record_audio", "capture_take_screenshot"
        ]
        for cfg in MCPServerConfig.imcpDefaults() {
            for t in cfg.delegatedTools {
                #expect(realNames.contains(t), "\(t) : nom non constaté côté iMCP — délégation vide")
                #expect(!MCPToolProvider.nativeOnly.contains(t), "\(t) : aussi dans nativeOnly, conflit")
            }
        }
    }

    @Test func `MCP messaging stays read-only`() {
        // iMCP n'expose que messages_fetch (lecture) : l'envoi reste natif.
        for cfg in MCPServerConfig.imcpDefaults() {
            #expect(!cfg.delegatedTools.contains("send_message"))
        }
        #expect(MCPToolProvider.nativeToMCP["send_message"] == nil)
    }

    @Test func `No native tool is superseded while offline`() async {
        let p = MCPToolProvider(configs: [])
        let s = await p.supersededNativeTools()
        #expect(s.isEmpty)
    }

    @Test func `An online remote tool supersedes its native counterpart`() async {
        let p = MCPToolProvider(configs: [])
        await p.registerForTests(MCPRemoteTool(serverId: "imcp", name: "events_create", description: "d", inputSchema: [:]))
        let s = await p.supersededNativeTools()
        #expect(s.contains("add_calendar_event"))
        #expect(!s.contains("send_message"))
        // La liste fusionnée masque le natif superseded mais garde send_message.
        await ToolService.shared.configureMCP(p)
        let defs = await ToolService.shared.effectiveToolDefs()
        let names = Set(defs.map { $0.function.name })
        #expect(!names.contains("add_calendar_event"))
        #expect(names.contains("events_create"))
        #expect(names.contains("send_message"))
        await ToolService.shared.configureMCP(nil)
    }
}
