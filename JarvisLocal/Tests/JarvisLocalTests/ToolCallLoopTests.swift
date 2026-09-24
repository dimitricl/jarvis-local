@testable import JarvisUI
import JarvisCore
import XCTest

/// Tests du ToolCallLoop (découpage AppViewModel, étape 2).
/// Callbacks fakes : aucune DB, aucun LLM, aucun ViewModel.
@MainActor
final class ToolCallLoopTests: XCTestCase {

    final class Probe: @unchecked Sendable {
        var traces: [String] = []
        var marks: [String] = []
        var audits: [(tool: String, status: String)] = []
        var sources: [String] = []
        var factsNotes = 0
        var confirmations: [String] = []
    }

    private func makeLoop(
        probe: Probe,
        approve: Bool = true,
        results: [String: String] = [:],
        failures: Set<String> = []
    ) -> ToolCallLoop {
        let cb = ToolLoopCallbacks(
            requestConfirmation: { tool, _ in probe.confirmations.append(tool); return approve },
            execute: { name, _ in
                if failures.contains(name) { throw NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"]) }
                return results[name] ?? "ok-\(name)"
            },
            appendTrace: { probe.traces.append($0) },
            markTrace: { probe.marks.append($0) },
            audit: { tool, _, status, _ in probe.audits.append((tool, status)) },
            noteFactsChanged: { probe.factsNotes += 1 },
            collectSources: { probe.sources.append(contentsOf: $0) }
        )
        return ToolCallLoop(sensitiveTools: ["sleep_mac", "send_message"], budget: 2, cb: cb)
    }

    private func call(_ name: String, args: String = "{}", id: String = UUID().uuidString) -> ToolCall {
        ToolCall(id: id, type: "function", function: ToolCallFunction(name: name, arguments: args))
    }

    func testPureForwardersMatchCore() {
        XCTAssertEqual(ToolCallLoop.argsSummary(["a": "1"]), ToolCallPartitioning.argsSummary(["a": "1"]))
        XCTAssertNotNil(ToolCallLoop.parseToolArguments(#"{"q":"x"}"#))
        XCTAssertNil(ToolCallLoop.parseToolArguments("pas du json{{{"))
        XCTAssertEqual(ToolCallLoop.confirmationKey(for: "sleep_mac", sensitive: ["sleep_mac"]), "sleep_mac")
        XCTAssertNil(ToolCallLoop.confirmationKey(for: "search_web", sensitive: ["sleep_mac"]))
    }

    func testSimpleCallExecutesAndWraps() async throws {
        let probe = Probe()
        let loop = makeLoop(probe: probe)
        var seen = Set<String>(); var counts = [String: Int]()
        let (msgs, nudge) = try await loop.runBatch([call("search_web", args: #"{"query":"x"}"#)], conversationId: nil, seen: &seen, counts: &counts)
        XCTAssertNil(nudge)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertTrue(msgs[0].content?.contains("DONNÉES EXTERNES") ?? false)
        XCTAssertEqual(probe.traces, ["search_web"])
        XCTAssertEqual(probe.marks, ["✓"])
        XCTAssertEqual(probe.audits.map { $0.status }, ["✓"])
    }

    func testDuplicateFilteredNotExecuted() async throws {
        let probe = Probe()
        let loop = makeLoop(probe: probe)
        var seen = Set<String>(); var counts = [String: Int]()
        let c = call("get_weather", args: #"{"city":"Paris"}"#)
        _ = try await loop.runBatch([c], conversationId: nil, seen: &seen, counts: &counts)
        let (msgs, nudge) = try await loop.runBatch([c], conversationId: nil, seen: &seen, counts: &counts)
        XCTAssertEqual(nudge, "Même outil déjà appelé. Réponds maintenant avec les résultats déjà obtenus.")
        XCTAssertTrue(msgs[0].content?.contains("déjà été appelé") ?? false)
        XCTAssertEqual(probe.traces, ["get_weather"]) // exécuté une seule fois
        XCTAssertTrue(probe.audits.contains(where: { $0.status == "ignoré" }))
    }

    func testBudgetRefused() async throws {
        let probe = Probe()
        let loop = makeLoop(probe: probe)
        var seen = Set<String>(); var counts = [String: Int]()
        let batch = [call("search_web", args: #"{"q":"1"}"#), call("search_web", args: #"{"q":"2"}"#), call("search_web", args: #"{"q":"3"}"#)]
        let (msgs, _) = try await loop.runBatch(batch, conversationId: nil, seen: &seen, counts: &counts)
        XCTAssertEqual(msgs.count, 3)
        XCTAssertTrue(probe.audits.contains(where: { $0.status == "budget" }))
        XCTAssertEqual(probe.traces.count, 2) // budget 2
    }

    func testBadJSONFormatError() async throws {
        let probe = Probe()
        let loop = makeLoop(probe: probe)
        var seen = Set<String>(); var counts = [String: Int]()
        let (msgs, _) = try await loop.runBatch([call("search_web", args: "n'importe quoi{{{")], conversationId: nil, seen: &seen, counts: &counts)
        XCTAssertTrue(msgs[0].content?.contains("ERREUR DE FORMAT") ?? false)
        XCTAssertTrue(probe.traces.isEmpty)
        XCTAssertTrue(probe.audits.contains(where: { $0.status == "format" }))
    }

    func testSensitiveRefused() async throws {
        let probe = Probe()
        let loop = makeLoop(probe: probe, approve: false)
        var seen = Set<String>(); var counts = [String: Int]()
        let (msgs, _) = try await loop.runBatch([call("sleep_mac", args: #"{"action":"lock"}"#)], conversationId: nil, seen: &seen, counts: &counts)
        XCTAssertTrue(msgs[0].content?.contains("REFUSÉE") ?? false)
        XCTAssertEqual(probe.confirmations, ["sleep_mac"])
        XCTAssertTrue(probe.traces.isEmpty)
    }

    func testToolFailureIsolated() async throws {
        let probe = Probe()
        let loop = makeLoop(probe: probe, failures: ["get_weather"])
        var seen = Set<String>(); var counts = [String: Int]()
        let (msgs, _) = try await loop.runBatch([call("get_weather")], conversationId: nil, seen: &seen, counts: &counts)
        XCTAssertTrue(msgs[0].content?.contains("n'a PAS été effectuée") ?? false)
        XCTAssertEqual(probe.marks, ["✗"])
    }

    func testRememberFactNotifies() async throws {
        let probe = Probe()
        let loop = makeLoop(probe: probe, approve: true)
        var seen = Set<String>(); var counts = [String: Int]()
        // remember_fact n'est pas dans les sensibles du loop de test -> direct
        _ = try await loop.runBatch([call("remember_fact", args: #"{"key":"user.name","value":"Dimitri"}"#)], conversationId: nil, seen: &seen, counts: &counts)
        XCTAssertEqual(probe.factsNotes, 1)
    }
}
