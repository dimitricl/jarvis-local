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
}
