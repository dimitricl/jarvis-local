@testable import JarvisLocal
import XCTest

/// Chantier 5 : client MCP. Aucun test ne requiert iMCP installé ni le réseau :
/// parsing pur, listes de garde, et dégradation gracieuse (binaire absent).
final class MCPToolProviderTests: XCTestCase {
    func testParseToolsListMapsInputSchema() {
        let res: [String: Any] = ["tools": [
            ["name": "add_calendar_event", "description": "Crée un événement",
             "inputSchema": ["properties": ["title": ["type": "string", "description": "Titre"]], "required": ["title"]]],
        ]]
        let got = MCPToolProvider.parseToolsList(res, serverId: "imcp-calendar")
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].asToolDef().function.parameters.required, ["title"])
        XCTAssertTrue(got[0].asToolDef().function.description.contains("MCP"))
    }

    func testParseToolsListEmptyOnGarbage() {
        XCTAssertTrue(MCPToolProvider.parseToolsList([:], serverId: "x").isEmpty)
        XCTAssertTrue(MCPToolProvider.parseToolsList(["tools": "nope"], serverId: "x").isEmpty)
    }

    func testNativeOnlyNeverDelegated() {
        // Locaux/sensibles/rapides : jamais délégués à MCP.
        for t in ["sleep_mac", "applescript", "take_screenshot", "get_clipboard",
                  "set_clipboard", "search_web", "read_url", "get_system_info",
                  "remember_fact", "open_app", "get_weather"] {
            XCTAssertTrue(MCPToolProvider.nativeOnly.contains(t), "\(t) doit rester natif")
        }
    }

    func testHandlesUnknownToolIsFalse() async {
        let p = MCPToolProvider(configs: [])
        let h = await p.handles(tool: "add_calendar_event")
        XCTAssertFalse(h)
    }

    func testConnectAllWithMissingBinaryStaysOffline() async {
        // Binaire inexistant : pas de throw, pas de crash — hors-ligne, natif en relais.
        let cfg = MCPServerConfig(id: "faux", command: "/chemin/inexistant/imcp-xyz", args: [], enabled: true, delegatedTools: ["x"])
        let p = MCPToolProvider(configs: [cfg])
        await p.connectAll()
        let h = await p.handles(tool: "x")
        XCTAssertFalse(h)
        let defs = await p.toolDefs()
        XCTAssertTrue(defs.isEmpty)
    }

    func testResolveIMCPBinaryNeverEmpty() {
        // La résolution ne retourne jamais "" : au pire "imcp" (PATH),
        // et le transport gère l'absence proprement.
        XCTAssertFalse(MCPServerConfig.resolveIMCPBinary().isEmpty)
    }

    func testImcpDefaultsHaveNoHardcodedBrewPath() {
        // Consigne chantier 5 : aucun /opt/homebrew codé en dur dans les defaults.
        // Le binaire vient de la résolution dynamique (env > Réglages > which > usuels).
        for cfg in MCPServerConfig.imcpDefaults() {
            XCTAssertFalse(cfg.command.hasPrefix("/opt/homebrew"),
                            "\(cfg.id) : chemin Homebrew en dur interdit, utilise resolveIMCPBinary()")
            XCTAssertFalse(cfg.command.isEmpty)
        }
    }

    func testMCPErrorDescriptionsAreExplicit() {
        XCTAssertTrue(MCPError.binaryNotFound("imcp").description.contains("introuvable"))
        XCTAssertTrue(MCPError.offline("x").description.contains("hors-ligne"))
    }

    func testDelegatedToolsMatchRealIMCPNames() {
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
            "capture_take_picture", "capture_record_audio", "capture_take_screenshot",
        ]
        for cfg in MCPServerConfig.imcpDefaults() {
            for t in cfg.delegatedTools {
                XCTAssertTrue(realNames.contains(t), "\(t) : nom non constaté côté iMCP — délégation vide")
                XCTAssertFalse(MCPToolProvider.nativeOnly.contains(t), "\(t) : aussi dans nativeOnly, conflit")
            }
        }
    }

    func testNoSendDelegationMessagesIsReadOnly() {
        // iMCP n'expose que messages_fetch (lecture) : l'envoi reste natif.
        for cfg in MCPServerConfig.imcpDefaults() {
            XCTAssertFalse(cfg.delegatedTools.contains("send_message"))
        }
        XCTAssertNil(MCPToolProvider.nativeToMCP["send_message"])
    }

    func testSupersededEmptyWhenOffline() async {
        let p = MCPToolProvider(configs: [])
        let s = await p.supersededNativeTools()
        XCTAssertTrue(s.isEmpty)
    }

    func testRegisteredRemoteToolSupersedesNative() async {
        let p = MCPToolProvider(configs: [])
        await p.registerForTests(MCPRemoteTool(serverId: "imcp", name: "events_create", description: "d", inputSchema: [:]))
        let s = await p.supersededNativeTools()
        XCTAssertTrue(s.contains("add_calendar_event"))
        XCTAssertFalse(s.contains("send_message"))
        // La liste fusionnée masque le natif superseded mais garde send_message.
        await ToolService.shared.configureMCP(p)
        let defs = await ToolService.shared.effectiveToolDefs()
        let names = Set(defs.map { $0.function.name })
        XCTAssertFalse(names.contains("add_calendar_event"))
        XCTAssertTrue(names.contains("events_create"))
        XCTAssertTrue(names.contains("send_message"))
        await ToolService.shared.configureMCP(nil)
    }
}
