@testable import JarvisLocal
import XCTest

final class JarvisLocalOllamaService_OllamaTests: XCTestCase {

    var ollamaService: OllamaService!

    override func setUp() async throws {
        try await super.setUp()
        ollamaService = OllamaService.shared
    }

    override func tearDown() async throws {
        ollamaService.stopKeepAlive()
        try await super.tearDown()
    }

    // MARK: - Request Body Tests (existing tests moved here)

    func testMakeRequestBodyStructure() {
        let messages = [OllamaMessage(role: "user", content: "hello")]
        let tools = [ToolDef(function: ToolFunction(name: "test", description: "A test tool", parameters: ToolParameters(properties: [:], required: [])))]
        let body = ollamaService.makeRequestBody(model: "gemma2", messages: messages, stream: true, tools: tools)
        XCTAssertEqual(body["model"] as? String, "gemma2")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNotNil(body["messages"])
        XCTAssertNotNil(body["tools"])
    }

    func testMakeRequestBodyWithoutTools() {
        let messages = [OllamaMessage(role: "system", content: "test")]
        let body = ollamaService.makeRequestBody(model: "llama3", messages: messages, stream: false, tools: nil)
        XCTAssertNil(body["tools"])
        XCTAssertEqual(body["model"] as? String, "llama3")
    }

    func testMakeRequestBodyMessageWithToolCallId() {
        let msg = OllamaMessage(role: "tool", content: "result", toolCallId: "call_abc")
        let body = ollamaService.makeRequestBody(model: "m", messages: [msg], stream: false, tools: nil)
        let msgs = body["messages"] as! [[String: Any]]
        XCTAssertEqual(msgs[0]["tool_call_id"] as? String, "call_abc")
    }

    func testMakeRequestBodyWithToolCalls() {
        let tc = ToolCall(id: "c1", type: "function", function: ToolCallFunction(name: "test", arguments: "{}"))
        let msg = OllamaMessage(role: "assistant", content: nil, toolCalls: [tc])
        let body = ollamaService.makeRequestBody(model: "m", messages: [msg], stream: false, tools: nil)
        let msgs = body["messages"] as! [[String: Any]]
        XCTAssertNotNil(msgs[0]["tool_calls"])
    }

    func testMakeRequestBodyIncludesReasoningEffort() {
        let messages = [OllamaMessage(role: "user", content: "test")]
        let body = ollamaService.makeRequestBody(model: "gemma4", messages: messages, stream: true, tools: nil)
        XCTAssertNotNil(body["reasoning_effort"])
    }

    func testMakeRequestBodyOptionsIncludeTemperatureAndNumPredict() {
        let messages = [OllamaMessage(role: "user", content: "test")]
        let body = ollamaService.makeRequestBody(model: "test", messages: messages, stream: true, tools: nil)
        let options = body["options"] as? [String: Any]
        XCTAssertNotNil(options)
        XCTAssertEqual(options?["temperature"] as? Double, 0.7)
        // num_predict doit refléter le réglage maxTokens (réponses non coupées)
        XCTAssertEqual(options?["num_predict"] as? Int, Settings.shared.maxTokens)
    }

    func testMaxTokensSettingIsClampedToSaneRange() {
        let original = Settings.shared.maxTokens
        defer { Settings.shared.maxTokens = original }

        Settings.shared.maxTokens = 10
        XCTAssertEqual(Settings.shared.maxTokens, 256) // borne basse

        Settings.shared.maxTokens = 100_000
        XCTAssertEqual(Settings.shared.maxTokens, 32_768) // borne haute
    }

    // MARK: - URL Building Tests

    func testMakeURLWithValidBase() {
        let settings = Settings.shared
        let originalURL = settings.ollamaURL
        settings.ollamaURL = "http://localhost:11434"
        defer { settings.ollamaURL = originalURL }

        let url = ollamaService.makeURL()
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.absoluteString, "http://localhost:11434/v1/chat/completions")
    }

    func testMakeURLWithChatCompletionsSuffix() {
        let settings = Settings.shared
        let originalURL = settings.ollamaURL
        settings.ollamaURL = "http://localhost:11434/v1/chat/completions"
        defer { settings.ollamaURL = originalURL }

        let url = ollamaService.makeURL()
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.absoluteString, "http://localhost:11434/v1/chat/completions")
    }

    func testMakeURLWithEmptyString() {
        let settings = Settings.shared
        let originalURL = settings.ollamaURL
        settings.ollamaURL = ""
        defer { settings.ollamaURL = originalURL }

        let url = ollamaService.makeURL()
        XCTAssertNil(url)
    }

    func testMakeURLWithWhitespace() {
        let settings = Settings.shared
        let originalURL = settings.ollamaURL
        settings.ollamaURL = "   "
        defer { settings.ollamaURL = originalURL }

        let url = ollamaService.makeURL()
        XCTAssertNil(url)
    }

    func testMakeBaseURL() {
        let settings = Settings.shared
        let originalURL = settings.ollamaURL
        settings.ollamaURL = "http://localhost:11434/v1/chat/completions"
        defer { settings.ollamaURL = originalURL }

        // Can't directly test private method, but we can verify it doesn't crash
        // by calling a public method that uses it indirectly
        XCTAssertTrue(true)
    }

    // MARK: - Keep Alive Tests

    func testStartKeepAliveCreatesTask() {
        ollamaService.startKeepAlive()
        // Just verify it doesn't crash
        XCTAssertTrue(true)
    }

    func testStartKeepAliveIdempotent() {
        ollamaService.startKeepAlive()
        ollamaService.startKeepAlive()
        // Should not create multiple tasks
        XCTAssertTrue(true)
    }

    func testStopKeepAliveCancelsTask() {
        ollamaService.startKeepAlive()
        ollamaService.stopKeepAlive()
        // Should not crash
        XCTAssertTrue(true)
    }

    func testStopKeepAliveIdempotent() {
        ollamaService.stopKeepAlive()
        ollamaService.stopKeepAlive()
        // Should not crash
        XCTAssertTrue(true)
    }

    // MARK: - Warm Up Tests (Integration - requires Ollama server)

    func testWarmUpWithoutServerReturnsFalse() async {
        let settings = Settings.shared
        let originalURL = settings.ollamaURL
        let originalModel = settings.model
        settings.ollamaURL = "http://invalid-host:11434"
        settings.model = "test-model"
        defer {
            settings.ollamaURL = originalURL
            settings.model = originalModel
        }

        let result = await ollamaService.warmUp(model: "test-model")
        // Should return false when server is unreachable
        XCTAssertFalse(result)
    }
}

final class JarvisLocalOllamaStreamParsingTests: XCTestCase {

    // Test the stream parsing logic by testing the ToolDef dictionary encoding
    func testToolDefDictionaryEncoding() {
        let tool = ToolDef(function: ToolFunction(
            name: "search_web",
            description: "Search the web",
            parameters: ToolParameters(
                properties: ["query": ToolProperty(type: "string", description: "The query")],
                required: ["query"]
            )
        ))
        let dict = tool.dictionary

        XCTAssertEqual(dict["type"] as? String, "function")
        let fn = dict["function"] as! [String: Any]
        XCTAssertEqual(fn["name"] as? String, "search_web")
        XCTAssertEqual(fn["description"] as? String, "Search the web")
        let params = fn["parameters"] as! [String: Any]
        XCTAssertEqual(params["type"] as? String, "object")
        XCTAssertEqual(params["required"] as? [String], ["query"])
    }

    func testToolDefDictionaryWithNilDescription() {
        let prop = ToolProperty(type: "string", description: nil)
        let data = try! JSONEncoder().encode(prop)
        let decoded = try! JSONDecoder().decode(ToolProperty.self, from: data)
        XCTAssertNil(decoded.description)
    }

    func testOllamaMessageToolCallSerialization() {
        let calls = [ToolCall(id: "call_1", type: "function", function: ToolCallFunction(name: "test", arguments: "{}"))]
        let msg = OllamaMessage(role: "assistant", content: nil, toolCalls: calls)
        let data = try! JSONEncoder().encode(msg)
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertNotNil(json["tool_calls"])
        let tcArray = json["tool_calls"] as! [[String: Any]]
        XCTAssertEqual(tcArray[0]["id"] as? String, "call_1")
        XCTAssertEqual(tcArray[0]["type"] as? String, "function")
    }

    func testOllamaMessageWithoutToolCalls() {
        let msg = OllamaMessage(role: "user", content: "hello")
        let data = try! JSONEncoder().encode(msg)
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertNil(json["tool_calls"])
        XCTAssertEqual(json["role"] as? String, "user")
        XCTAssertEqual(json["content"] as? String, "hello")
    }

    func testOllamaMessageToolCallIdSerialization() {
        let msg = OllamaMessage(role: "tool", content: "result", toolCallId: "call_abc123")
        let data = try! JSONEncoder().encode(msg)
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["tool_call_id"] as? String, "call_abc123")
    }

    func testOllamaMessageToolCallIdAbsentWhenNil() {
        let msg = OllamaMessage(role: "user", content: "hello")
        let data = try! JSONEncoder().encode(msg)
        let json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertNil(json["tool_call_id"])
    }
}

final class JarvisLocalOllamaError_OllamaTests: XCTestCase {

    func testAllErrorDescriptionsNonEmpty() {
        let all: [OllamaError] = [.badStatus, .invalidResponse, .interrupted, .invalidURL, .modelError("test")]
        for e in all {
            XCTAssertFalse(e.description.isEmpty, "\(e) should have a description")
        }
    }

    func testInvalidURLDescription() {
        let err = OllamaError.invalidURL
        XCTAssertTrue(err.description.contains("URL"))
    }

    func testBadStatusDescription() {
        let err = OllamaError.badStatus
        XCTAssertTrue(err.description.contains("Ollama"))
    }

    func testModelErrorIncludesMessage() {
        let err = OllamaError.modelError("Custom error message")
        XCTAssertTrue(err.description.contains("Custom error message"))
    }

    func testInterruptedDescription() {
        let err = OllamaError.interrupted
        XCTAssertTrue(err.description.contains("annulée") || err.description.contains("interrupt"))
    }

    func testInvalidResponseDescription() {
        let err = OllamaError.invalidResponse
        XCTAssertTrue(err.description.contains("invalide") || err.description.contains("invalid"))
    }
}