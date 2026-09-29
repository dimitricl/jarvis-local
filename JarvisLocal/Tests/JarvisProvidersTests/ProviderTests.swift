import XCTest
@testable import JarvisProviders
@testable import JarvisKit

final class OllamaHostPolicyTests: XCTestCase {
    func testLocalhostHTTPAllowed() throws {
        XCTAssertNotNil(try OllamaHostPolicy.validateBaseURL("http://localhost:11434"))
        XCTAssertNotNil(try OllamaHostPolicy.validateBaseURL("http://127.0.0.1:11434"))
    }

    func testTailscaleHTTPAllowed() throws {
        XCTAssertNotNil(try OllamaHostPolicy.validateBaseURL("http://100.87.1.2:11434"))
        XCTAssertNotNil(try OllamaHostPolicy.validateBaseURL("http://macmini.tailabcd.ts.net:11434"))
    }

    func testPublicHTTPRefused() {
        XCTAssertThrowsError(try OllamaHostPolicy.validateBaseURL("http://93.184.216.34:11434")) { error in
            XCTAssertEqual(error as? OllamaHostPolicy.ValidationError,
                           .insecureRemoteHost(host: "93.184.216.34"))
        }
        XCTAssertThrowsError(try OllamaHostPolicy.validateBaseURL("http://example.com:11434"))
    }

    func testPublicHTTPSAllowed() throws {
        XCTAssertNotNil(try OllamaHostPolicy.validateBaseURL("https://example.com:11434"))
    }

    func testEmptyAndMalformed() {
        XCTAssertThrowsError(try OllamaHostPolicy.validateBaseURL("   "))
        XCTAssertThrowsError(try OllamaHostPolicy.validateBaseURL("gopher://x"))
    }
}

final class OllamaMappingTests: XCTestCase {
    func testRequestBodyToolsAndOptions() throws {
        let tools = [ToolSpec(name: "read_file", description: "Lit.",
                              parameters: .object(["type": .string("object")]))]
        let messages = [
            Message(role: .system, content: "sys"),
            Message(role: .assistant, toolCalls: [
                ToolCallRef(id: "c1", name: "read_file", arguments: .object(["path": .string("a")]))
            ]),
            Message(role: .tool, content: "ok", toolCallId: "c1", name: "read_file")
        ]
        let data = try OllamaProvider.requestBody(
            model: "m", messages: messages, tools: tools, numCtx: 16384, temperature: 0.2)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["model"] as? String, "m")
        XCTAssertEqual(json?["stream"] as? Bool, true)
        let options = json?["options"] as? [String: Any]
        XCTAssertEqual(options?["num_ctx"] as? Int, 16384)
        let toolsJSON = json?["tools"] as? [[String: Any]]
        XCTAssertEqual(toolsJSON?.first?["type"] as? String, "function")
        let sent = json?["messages"] as? [[String: Any]]
        XCTAssertEqual(sent?.count, 3)
        XCTAssertNotNil(sent?[1]["tool_calls"])
        XCTAssertEqual(sent?[2]["tool_call_id"] as? String, "c1")
    }

    func testRequestBodyWithoutToolsOmitsKey() throws {
        let data = try OllamaProvider.requestBody(
            model: "m", messages: [Message(role: .user, content: "hi")],
            tools: [], numCtx: 4096, temperature: 0)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNil(json?["tools"])
    }

    func testRequestBodyDisablesThinkingByDefault() throws {
        // gemma4 est thinking : reasoning_effort none évite 20-30 s de
        // raisonnement invisible par tour (mesuré 32 s → 4 s).
        let data = try OllamaProvider.requestBody(
            model: "m", messages: [Message(role: .user, content: "hi")],
            tools: [], numCtx: 4096, temperature: 0)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["reasoning_effort"] as? String, "none")
    }

    func testRequestBodyKeepsModelResident() throws {
        // Sans keep_alive, Ollama décharge après 5 min et chaque session
        // repaie le chargement à froid (qui tuait le stream en -1001).
        let data = try OllamaProvider.requestBody(
            model: "m", messages: [Message(role: .user, content: "hi")],
            tools: [], numCtx: 4096, temperature: 0)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["keep_alive"] as? String, "24h")
    }

    func testApplySSELineAccumulatesFragments() {
        var state = OllamaProvider.SseState()
        var metrics: LLMMetrics?
        let e1 = OllamaProvider.applySSELine(
            "data: {\"choices\": [{\"delta\": {\"tool_calls\": [{\"index\": 0, \"id\": \"c1\", \"function\": {\"name\": \"write_\", \"arguments\": \"{\\\"pa\"}}]}, \"finish_reason\": null}]}",
            state: &state, metrics: &metrics)
        XCTAssertTrue(e1.textDeltas.isEmpty)
        XCTAssertFalse(e1.finished)
        let e2 = OllamaProvider.applySSELine(
            "data: {\"choices\": [{\"delta\": {\"tool_calls\": [{\"index\": 0, \"function\": {\"name\": \"file\", \"arguments\": \"th\\\": 1}\"}}]}, \"finish_reason\": null}]}",
            state: &state, metrics: &metrics)
        XCTAssertFalse(e2.finished)
        // Fragments bout à bout : "write_" + "file", sans duplication.
        let e3 = OllamaProvider.applySSELine(
            "data: {\"choices\": [{\"delta\": {}, \"finish_reason\": \"tool_calls\"}], \"usage\": {\"prompt_tokens\": 40, \"completion_tokens\": 10}}",
            state: &state, metrics: &metrics)
        XCTAssertTrue(e3.finished)
        XCTAssertEqual(state.calls.count, 1)
        XCTAssertEqual(state.calls.first?.name, "write_file")
        XCTAssertEqual(state.calls.first?.arguments["path"], .int(1))
        XCTAssertEqual(metrics?.promptEvalCount, 40)
        let e4 = OllamaProvider.applySSELine("data: [DONE]", state: &state, metrics: &metrics)
        XCTAssertTrue(e4.finished)
        // Lignes non-SSE ignorées.
        var state2 = OllamaProvider.SseState()
        var metrics2: LLMMetrics?
        let e5 = OllamaProvider.applySSELine(": ping", state: &state2, metrics: &metrics2)
        XCTAssertFalse(e5.finished)
        XCTAssertNil(metrics2)
    }

    func testApplySSELineSkipsRepeatedFullName() {
        // Certains serveurs renvoient le nom COMPLET à chaque chunk :
        // pas de concaténation "write_filewrite_file".
        var state = OllamaProvider.SseState()
        var metrics: LLMMetrics?
        for _ in 0..<3 {
            _ = OllamaProvider.applySSELine(
                "data: {\"choices\": [{\"delta\": {\"tool_calls\": [{\"index\": 0, \"id\": \"c1\", \"function\": {\"name\": \"write_file\", \"arguments\": \"\"}}]}, \"finish_reason\": null}]}",
                state: &state, metrics: &metrics)
        }
        _ = OllamaProvider.applySSELine(
            "data: {\"choices\": [{\"delta\": {}, \"finish_reason\": \"tool_calls\"}]}",
            state: &state, metrics: &metrics)
        XCTAssertEqual(state.calls.first?.name, "write_file")
    }

    func testFlushFragmentsIgnoresNameless() {        XCTAssertTrue(OllamaProvider.flushFragments([0: (id: "x", name: "", arguments: "")]).isEmpty)
    }

    func testFlushFragmentsRepairsInvalidJSON() {
        let calls = OllamaProvider.flushFragments([0: (id: "c1", name: "f", arguments: "{cassé")])
        XCTAssertEqual(calls.count, 1)
        XCTAssertNotNil(calls.first?.arguments["_unparseable"])
    }
}
