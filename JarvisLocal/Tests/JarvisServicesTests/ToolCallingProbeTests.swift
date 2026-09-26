@testable import JarvisServices
import JarvisCore
import XCTest

/// Sonde tool-calling : la classification est pure et testée sans réseau.
/// La sonde réseau elle-même (`probeToolCalling`) n'est pas testée unitairement
/// (requiert Ollama) — seul son verdict est couvert ici.
final class ToolCallingProbeTests: XCTestCase {
    private func okWithCalls() -> [String: Any] {
        ["choices": [["message": ["role": "assistant", "tool_calls": [
            ["id": "1", "type": "function", "function": ["name": "probe_ping", "arguments": "{\"value\":\"pong\"}"]]
        ]]]]]
    }

    func testToolCallsPresentIsSupported() {
        XCTAssertEqual(
            OllamaService.classifyProbeResult(status: 200, json: okWithCalls()),
            .supported
        )
    }

    func testTextOnlyOnExplicitOrderIsUnsupported() {
        let json: [String: Any] = ["choices": [["message": ["role": "assistant", "content": "pong"]]]]
        let got = OllamaService.classifyProbeResult(status: 200, json: json)
        guard case .unsupported(let reason) = got else {
            XCTFail("texte seul sur consigne explicite devrait valoir unsupported, obtenu : \(got)")
            return
        }
        XCTAssertFalse(reason.isEmpty)
    }

    func testEmptyToolCallsIsUnsupported() {
        let json: [String: Any] = ["choices": [["message": ["role": "assistant", "tool_calls": []]]]]
        let got = OllamaService.classifyProbeResult(status: 200, json: json)
        guard case .unsupported = got else {
            XCTFail("tool_calls vide devrait valoir unsupported, obtenu : \(got)")
            return
        }
    }

    func testToolRelatedServerErrorIsUnsupported() {
        let json: [String: Any] = ["error": "this model does not support tools"]
        let got = OllamaService.classifyProbeResult(status: 400, json: json)
        guard case .unsupported = got else {
            XCTFail("refus tools devrait valoir unsupported, obtenu : \(got)")
            return
        }
    }

    func testUnrelatedServerErrorIsUnknown() {
        let json: [String: Any] = ["error": "overloaded, try again later"]
        let got = OllamaService.classifyProbeResult(status: 503, json: json)
        guard case .unknown = got else {
            XCTFail("erreur non liée aux outils devrait valoir unknown, obtenu : \(got)")
            return
        }
    }

    func testUnreadableResponseIsUnknown() {
        let got = OllamaService.classifyProbeResult(status: 200, json: ["unexpected": true])
        guard case .unknown = got else {
            XCTFail("réponse illisible devrait valoir unknown, obtenu : \(got)")
            return
        }
    }

    func testNilJSONIsUnknown() {
        let got = OllamaService.classifyProbeResult(status: 200, json: nil)
        guard case .unknown = got else {
            XCTFail("JSON nil devrait valoir unknown, obtenu : \(got)")
            return
        }
    }
}
