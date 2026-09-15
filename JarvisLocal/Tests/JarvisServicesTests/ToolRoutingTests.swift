@testable import JarvisServices
import XCTest

/// Chantier 2 : la façade garde un point d'entrée unique qui route vers
/// les sous-services. Ces tests verrouillent le routage sans permission
/// système (outils inconnus, validation pure, normalisation téléphone).
final class ToolRoutingTests: XCTestCase {
    func testUnknownToolReturnsError() async throws {
        let result = try await ToolService.shared.execute(name: "unknown_tool_xyz", args: [:])
        XCTAssertEqual(result, "Outil inconnu : unknown_tool_xyz")
    }

    func testToolDefsNamesAreUnique() async {
        let defs = await ToolService.shared.toolDefs
        let names = defs.map { $0.function.name }
        XCTAssertEqual(names.count, Set(names).count, "Les noms d'outils doivent être uniques")
    }

    func testAllToolsHaveDescriptions() async {
        let defs = await ToolService.shared.toolDefs
        for def in defs {
            XCTAssertFalse(def.function.description.isEmpty)
            XCTAssertGreaterThan(def.function.description.count, 10)
        }
    }

    func testRequiredParametersMatchProperties() async {
        let defs = await ToolService.shared.toolDefs
        for def in defs {
            for required in def.function.parameters.required {
                XCTAssertNotNil(def.function.parameters.properties[required],
                                "Paramètre requis '\(required)' manquant dans properties pour \(def.function.name)")
            }
        }
    }

    func testEffectiveToolDefsWithoutMCPIsNativeList() async {
        // Sans MCP configuré : la liste fusionnée = la liste native.
        await ToolService.shared.configureMCP(nil)
        let effective = await ToolService.shared.effectiveToolDefs()
        let native = await ToolService.shared.toolDefs
        XCTAssertEqual(effective.map { $0.function.name }, native.map { $0.function.name })
    }

    func testMessagingPhoneNormalizationKeepsInternationalPrefix() {
        // Régression historique : les numéros +32/+41 perdaient leur indicatif.
        XCTAssertEqual(MessagingTools.normalizePhone("+32470123456"), "+32470123456")
        XCTAssertEqual(MessagingTools.normalizePhone("+41791234567"), "+41791234567")
    }

    func testMessagingPhoneNormalizationAddsFrenchPrefix() {
        XCTAssertEqual(MessagingTools.normalizePhone("06 12 34 56 78"), "+33612345678")
        XCTAssertEqual(MessagingTools.normalizePhone("0612345678"), "+33612345678")
    }

    func testSearchWebFormatAliasDelegatesToWebSearchService() {
        let viaAlias = ToolService.formatSearchResults([
            (title: "T", href: "https://example.com/a", text: "Texte")
        ])
        let viaService = WebSearchService.format([
            (title: "T", href: "https://example.com/a", text: "Texte")
        ])
        XCTAssertEqual(viaAlias, viaService)
    }

    func testRememberFactRequiresKeyAndValue() async throws {
        let result = try await ToolService.shared.execute(name: "remember_fact", args: ["key": "", "value": ""])
        XCTAssertTrue(result.contains("Erreur"))
    }

    func testSleepMacUnknownAction() async throws {
        let result = try await ToolService.shared.execute(name: "sleep_mac", args: ["action": "nope"])
        XCTAssertTrue(result.contains("inconnue"))
    }
}
