import JarvisCore
import XCTest

final class JarvisLocalToolServiceArgumentParsingTests: XCTestCase {

    func testParseToolArgumentsValidJSON() throws {
        let args = ToolArgumentParser.parse("{\"query\": \"test\", \"count\": 5}")
        XCTAssertNotNil(args)
        XCTAssertEqual(args?["query"] as? String, "test")
        XCTAssertEqual(args?["count"] as? Int, 5)
    }

    func testParseToolArgumentsWithTrailingComma() throws {
        let args = ToolArgumentParser.parse("{\"query\": \"test\",}")
        XCTAssertNotNil(args)
        XCTAssertEqual(args?["query"] as? String, "test")
    }

    func testParseToolArgumentsWithMarkdownFences() throws {
        let args = ToolArgumentParser.parse("```json\n{\"query\": \"test\"}\n```")
        XCTAssertNotNil(args)
        XCTAssertEqual(args?["query"] as? String, "test")
    }

    func testParseToolArgumentsWithSmartQuotes() throws {
        let args = ToolArgumentParser.parse("{\"query\": \"test\"}")
        XCTAssertNotNil(args)
        XCTAssertEqual(args?["query"] as? String, "test")
    }

    func testParseToolArgumentsEmptyString() throws {
        let args = ToolArgumentParser.parse("")
        XCTAssertNotNil(args)
        XCTAssertTrue(args!.isEmpty)
    }

    func testParseToolArgumentsInvalidJSONReturnsNil() throws {
        let args = ToolArgumentParser.parse("not json at all")
        XCTAssertNil(args)
    }

    func testParseToolArgumentsDoubleEncoded() throws {
        let args = ToolArgumentParser.parse("{\"app\": \"{\\\"app\\\": \\\"Safari\\\"}\"}")
        XCTAssertNotNil(args)
    }

    // MARK: - Pseudo-appels texte

    func testExtractPseudoCallBasic() {
        let calls = ToolArgumentParser.extractPseudoCalls(
            from: "search_web(query=\"actualités tech France\")",
            knownTools: ["search_web"])
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.function.name, "search_web")
        let args = ToolArgumentParser.parse(calls.first?.function.arguments ?? "")
        XCTAssertEqual(args?["query"] as? String, "actualités tech France")
    }

    func testExtractPseudoCallIgnoresUnknownTool() {
        XCTAssertTrue(ToolArgumentParser.extractPseudoCalls(
            from: "frobnicate(x=\"1\")", knownTools: ["search_web"]).isEmpty)
    }

    func testExtractPseudoCallIgnoresProse() {
        XCTAssertTrue(ToolArgumentParser.extractPseudoCalls(
            from: "Voici les prix relevés : 1 119 €.", knownTools: ["search_web"]).isEmpty)
    }

    func testExtractPseudoCallCommaInQuotes() {
        let calls = ToolArgumentParser.extractPseudoCalls(
            from: "create_note(title=\"A\", body=\"x, y\")", knownTools: ["create_note"])
        let args = ToolArgumentParser.parse(calls.first?.function.arguments ?? "")
        XCTAssertEqual(args?["body"] as? String, "x, y")
    }

    func testExtractPseudoCallJSONArgs() {
        let calls = ToolArgumentParser.extractPseudoCalls(
            from: "search_web({\"query\": \"z\"})", knownTools: ["search_web"])
        let args = ToolArgumentParser.parse(calls.first?.function.arguments ?? "")
        XCTAssertEqual(args?["query"] as? String, "z")
    }

    func testExtractPseudoCallSkipsUnparseable() {
        // Guillemet non fermé : pas d'exécution à l'aveugle, la relance prend le relais.
        XCTAssertTrue(ToolArgumentParser.extractPseudoCalls(
            from: "search_web(query=\"oups)", knownTools: ["search_web"]).isEmpty)
    }

    func testExtractBareCallColonForm() {
        // Forme nue enseignée par les exemples du prompt (`get_weather city: Paris`).
        let calls = ToolArgumentParser.extractPseudoCalls(
            from: "get_weather city: Paris", knownTools: ["get_weather"])
        XCTAssertEqual(calls.count, 1)
        let args = ToolArgumentParser.parse(calls.first?.function.arguments ?? "")
        XCTAssertEqual(args?["city"] as? String, "Paris")
    }

    func testExtractBareCallEqualsForm() {
        let calls = ToolArgumentParser.extractPseudoCalls(
            from: "search_web query=actus", knownTools: ["search_web"])
        let args = ToolArgumentParser.parse(calls.first?.function.arguments ?? "")
        XCTAssertEqual(args?["query"] as? String, "actus")
    }

    func testExtractBareCallSkipsProse() {
        // Nom connu mais sans arguments : prose, jamais exécuté.
        XCTAssertTrue(ToolArgumentParser.extractPseudoCalls(
            from: "search_web est rapide", knownTools: ["search_web"]).isEmpty)
        // Premier mot inconnu : jamais exécuté.
        XCTAssertTrue(ToolArgumentParser.extractPseudoCalls(
            from: "note: remember this", knownTools: ["search_web"]).isEmpty)
    }
}
