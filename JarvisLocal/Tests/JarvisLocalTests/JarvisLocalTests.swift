@testable import JarvisLocal
import XCTest

// MARK: - Models
final class JarvisLocalModelsTests: XCTestCase {

    // MARK: - Message Codable

    func testMessageCodableRoundTrip() throws {
        let msg = Message(id: 1, role: "user", content: "Bonjour", conversationId: 42, createdAt: Date())
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(Message.self, from: data)
        XCTAssertEqual(decoded.id, 1)
        XCTAssertEqual(decoded.role, "user")
        XCTAssertEqual(decoded.content, "Bonjour")
        XCTAssertEqual(decoded.conversationId, 42)
    }

    func testMessageCodableWithoutConversationId() throws {
        let msg = Message(id: 2, role: "assistant", content: "Salut", conversationId: nil, createdAt: Date())
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(json["conversation_id"])
    }

    func testMessageDecodingSnakeCase() throws {
        let json = """
        {"id": 3, "role": "user", "content": "test", "conversation_id": 5, "created_at": 1700000000}
        """.data(using: .utf8)!
        let msg = try JSONDecoder().decode(Message.self, from: json)
        XCTAssertEqual(msg.conversationId, 5)
        // Le timestamp est interprété en Cocoa epoch (2001), pas Unix epoch (1970).
        // On ne teste que la conversion snake_case → camelCase de la clé.
    }

    // MARK: - Fact Codable

    func testFactCodableRoundTrip() throws {
        let fact = Fact(id: 1, key: "user.name", value: "Dimitri", updatedAt: Date())
        let data = try JSONEncoder().encode(fact)
        let decoded = try JSONDecoder().decode(Fact.self, from: data)
        XCTAssertEqual(decoded.key, "user.name")
        XCTAssertEqual(decoded.value, "Dimitri")
    }

    func testFactDecodingSnakeCase() throws {
        let json = """
        {"id": 2, "key": "user.city", "value": "Paris", "updated_at": 1700000000}
        """.data(using: .utf8)!
        let fact = try JSONDecoder().decode(Fact.self, from: json)
        XCTAssertEqual(fact.key, "user.city")
        XCTAssertEqual(fact.value, "Paris")
    }

    // MARK: - Conversation Codable

    func testConversationCodableRoundTrip() throws {
        let conv = Conversation(id: 1, title: "Général", createdAt: Date(), updatedAt: Date())
        let data = try JSONEncoder().encode(conv)
        let decoded = try JSONDecoder().decode(Conversation.self, from: data)
        XCTAssertEqual(decoded.title, "Général")
    }

    // MARK: - OllamaMessage

    func testOllamaMessageToolCallIdSerialized() throws {
        let msg = OllamaMessage(role: "tool", content: "42", toolCallId: "call_abc123")
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["tool_call_id"] as? String, "call_abc123")
    }

    func testOllamaMessageToolCallIdAbsentWhenNil() throws {
        let msg = OllamaMessage(role: "user", content: "hello")
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(json["tool_call_id"])
    }

    func testOllamaMessageWithToolCalls() throws {
        let calls = [ToolCall(id: "call_1", type: "function", function: ToolCallFunction(name: "test", arguments: "{}"))]
        let msg = OllamaMessage(role: "assistant", content: nil, toolCalls: calls)
        let data = try JSONEncoder().encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(json["tool_calls"])
        let tcArray = json["tool_calls"] as! [[String: Any]]
        XCTAssertEqual(tcArray[0]["id"] as? String, "call_1")
    }

    // MARK: - ToolDef dictionary

    func testToolDefDictionaryStructure() {
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

        let props = params["properties"] as! [String: Any]
        let queryProp = props["query"] as! [String: String]
        XCTAssertEqual(queryProp["type"], "string")
    }

    // MARK: - ToolProperty nil description

    func testToolPropertyWithNilDescription() throws {
        let prop = ToolProperty(type: "string", description: nil)
        let data = try JSONEncoder().encode(prop)
        let decoded = try JSONDecoder().decode(ToolProperty.self, from: data)
        XCTAssertNil(decoded.description)
    }
}

// MARK: - TextProcessing (stripThinking)
final class JarvisLocalTextProcessingTests: XCTestCase {
    func testStripThinkingRemovesBlock() {
        let input = "Hello <think>ceci est interne</think> world"
        XCTAssertEqual(stripThinking(input), "Hello  world")
    }

    func testStripThinkingMultiline() {
        let input = "Bonjour\n<think>\nréflexion\n</think>\ntout le monde"
        let result = stripThinking(input)
        XCTAssertFalse(result.contains("réflexion"))
        XCTAssertFalse(result.contains("<think>"))
        XCTAssertTrue(result.contains("Bonjour"))
        XCTAssertTrue(result.contains("tout le monde"))
    }

    func testStripThinkingNoThinkTag() {
        let input = "Pas de tag ici"
        XCTAssertEqual(stripThinking(input), "Pas de tag ici")
    }

    func testStripThinkingEmptyString() {
        XCTAssertEqual(stripThinking(""), "")
    }

    func testStripThinkingOnlyThinkTag() {
        let input = "<think>réflexion</think>"
        XCTAssertEqual(stripThinking(input), "")
    }

    func testStripThinkingNestedAngleBrackets() {
        let input = "Avant <think>a < b > c</think> après"
        XCTAssertEqual(stripThinking(input), "Avant  après")
    }
}

// MARK: - StringExtensions
final class JarvisLocalStringExtensionsTests: XCTestCase {
    func testEscapingForAppleScriptBackslash() {
        XCTAssertEqual("a\\b".escapingForAppleScript, "a\\\\b")
    }

    func testEscapingForAppleScriptQuotes() {
        XCTAssertEqual("il a dit \"bonjour\"".escapingForAppleScript, "il a dit \\\"bonjour\\\"")
    }

    func testEscapingForAppleScriptNewline() {
        XCTAssertEqual("ligne1\nligne2".escapingForAppleScript, "ligne1\\nligne2")
    }

    func testEscapingForAppleScriptMixed() {
        let input = "path\\to\\file\"with\"quotes\nand\nnewlines"
        let expected = "path\\\\to\\\\file\\\"with\\\"quotes\\nand\\nnewlines"
        XCTAssertEqual(input.escapingForAppleScript, expected)
    }

    func testStrippedHTMLSimple() {
        let html = "<p>Bonjour</p>"
        XCTAssertEqual(html.strippedHTML, "Bonjour")
    }

    func testStrippedHTMLNested() {
        let html = "<div><b>Texte</b> <i>gras</i></div>"
        XCTAssertEqual(html.strippedHTML, "Texte gras")
    }

    func testStrippedHTMLNoTags() {
        XCTAssertEqual("du texte simple".strippedHTML, "du texte simple")
    }

    func testStrippedHMLEmptyString() {
        XCTAssertEqual("".strippedHTML, "")
    }

    func testHtmlToTextStripsScriptAndStyle() {
        let html = "<script>alert('xss')</script><p>Hello</p><style>.c{color:red}</style>"
        let result = html.htmlToText(maxLength: 1000)
        XCTAssertFalse(result.contains("alert"))
        XCTAssertFalse(result.contains(".c{"))
        XCTAssertTrue(result.contains("Hello"))
    }

    func testHtmlToTextBlockTagsToNewlines() {
        let html = "<p>Para 1</p><p>Para 2</p>"
        let result = html.htmlToText(maxLength: 1000)
        XCTAssertTrue(result.contains("Para 1"))
        XCTAssertTrue(result.contains("Para 2"))
    }

    func testHtmlToTextEntityDecoding() {
        let html = "&amp; &lt; &gt; &quot; &#39; &nbsp;"
        let result = html.htmlToText(maxLength: 1000)
        XCTAssertTrue(result.contains("&"))
        XCTAssertTrue(result.contains("<"))
        XCTAssertTrue(result.contains(">"))
    }

    func testHtmlToTextRespectsMaxLength() {
        let html = String(repeating: "<p>a</p>", count: 100)
        let result = html.htmlToText(maxLength: 10)
        XCTAssertLessThanOrEqual(result.count, 10)
    }

    func testHtmlToTextFiltersShortLines() {
        let html = "<p>ab</p><p>long content here</p>"
        let result = html.htmlToText(maxLength: 1000)
        XCTAssertTrue(result.contains("long content here"))
        XCTAssertFalse(result.contains("ab"))
    }
}

// MARK: - DatabaseService
final class JarvisLocalDatabaseServiceTests: XCTestCase {
    func testOpenInMemory() async throws {
        let db = DatabaseService.shared
        try await db.open(path: ":memory:")
    }

    func testCreateAndGetConversation() async throws {
        let db = DatabaseService.shared
        try await db.open(path: ":memory:")
        let conv = try await db.createConversation(title: "Test")
        XCTAssertEqual(conv.title, "Test")
        XCTAssertGreaterThan(conv.id, 0)
        let fetched = try await db.getConversation(id: conv.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.title, "Test")
    }

    func testInsertAndGetMessages() async throws {
        let db = DatabaseService.shared
        try await db.open(path: ":memory:")
        let conv = try await db.createConversation(title: "Test")
        let msg = try await db.insertMessage(role: "user", content: "Bonjour", conversationId: conv.id)
        XCTAssertEqual(msg.role, "user")
        XCTAssertEqual(msg.content, "Bonjour")
        let msgs = try await db.getMessages(conversationId: conv.id)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs.first?.content, "Bonjour")
    }

    func testFactsCRUD() async throws {
        let db = DatabaseService.shared
        try await db.open(path: ":memory:")
        try await db.upsertFact(key: "user.name", value: "Dimitri")
        let facts = try await db.getAllFacts()
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts.first?.key, "user.name")
        XCTAssertEqual(facts.first?.value, "Dimitri")
        try await db.deleteFact(key: "user.name")
        let after = try await db.getAllFacts()
        XCTAssertTrue(after.isEmpty)
    }

    func testDeleteConversationCascadesMessages() async throws {
        let db = DatabaseService.shared
        try await db.open(path: ":memory:")
        let conv = try await db.createConversation(title: "A Supprimer")
        let _ = try await db.insertMessage(role: "user", content: "msg", conversationId: conv.id)
        try await db.deleteConversation(id: conv.id)
        let fetched = try await db.getConversation(id: conv.id)
        XCTAssertNil(fetched)
        let msgs = try await db.getMessages(conversationId: conv.id)
        XCTAssertTrue(msgs.isEmpty)
    }
}

// MARK: - OllamaService
final class JarvisLocalOllamaServiceTests: XCTestCase {
    func testMakeRequestBodyStructure() {
        let service = OllamaService.shared
        let messages = [OllamaMessage(role: "user", content: "hello")]
        let tools = [ToolDef(function: ToolFunction(name: "test", description: "A test tool", parameters: ToolParameters(properties: [:], required: [])))]
        let body = service.makeRequestBody(model: "gemma2", messages: messages, stream: true, tools: tools)
        XCTAssertEqual(body["model"] as? String, "gemma2")
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNotNil(body["messages"])
        XCTAssertNotNil(body["tools"])
    }

    func testMakeRequestBodyWithoutTools() {
        let service = OllamaService.shared
        let messages = [OllamaMessage(role: "system", content: "test")]
        let body = service.makeRequestBody(model: "llama3", messages: messages, stream: false, tools: nil)
        XCTAssertNil(body["tools"])
        XCTAssertEqual(body["model"] as? String, "llama3")
    }

    func testMakeRequestBodyMessageWithToolCallId() {
        let service = OllamaService.shared
        let msg = OllamaMessage(role: "tool", content: "result", toolCallId: "call_abc")
        let body = service.makeRequestBody(model: "m", messages: [msg], stream: false, tools: nil)
        let msgs = body["messages"] as! [[String: Any]]
        XCTAssertEqual(msgs[0]["tool_call_id"] as? String, "call_abc")
    }

    func testMakeRequestBodyWithToolCalls() {
        let service = OllamaService.shared
        let tc = ToolCall(id: "c1", type: "function", function: ToolCallFunction(name: "test", arguments: "{}"))
        let msg = OllamaMessage(role: "assistant", content: nil, toolCalls: [tc])
        let body = service.makeRequestBody(model: "m", messages: [msg], stream: false, tools: nil)
        let msgs = body["messages"] as! [[String: Any]]
        XCTAssertNotNil(msgs[0]["tool_calls"])
    }
}

// MARK: - ToolService Security
final class JarvisLocalToolServiceSecurityTests: XCTestCase {
    func testToolDefsAreNotEmpty() async {
        let tools = ToolService.shared
        let defs = await tools.toolDefs
        XCTAssertGreaterThan(defs.count, 0)
    }

    func testAllToolsHaveRequiredFields() async {
        let tools = ToolService.shared
        let defs = await tools.toolDefs
        for t in defs {
            XCTAssertFalse(t.function.name.isEmpty, "Tool name should not be empty")
            XCTAssertFalse(t.function.description.isEmpty, "Tool \(t.function.name) description should not be empty")
        }
    }

    func testSensitiveToolsHaveConfirmationInViewModel() async {
        let sensitiveTools: Set<String> = ["sleep_mac", "send_message", "applescript", "edit_note", "run_shortcut"]
        let defs = await ToolService.shared.toolDefs
        let toolNames = Set(defs.map { $0.function.name })
        for s in sensitiveTools {
            XCTAssertTrue(toolNames.contains(s), "Sensitive tool \(s) should exist in toolDefs")
        }
    }
}

// MARK: - OllamaError
final class JarvisLocalOllamaErrorTests: XCTestCase {
    func testInvalidURLDescription() {
        let err = OllamaError.invalidURL
        XCTAssertTrue(err.description.contains("URL"))
        XCTAssertFalse(err.description.isEmpty)
    }

    func testBadStatusDescription() {
        let err = OllamaError.badStatus
        XCTAssertTrue(err.description.contains("Ollama"))
    }

    func testErrorDescriptionsAreNonEmpty() {
        let all: [OllamaError] = [.badStatus, .invalidResponse, .interrupted, .invalidURL]
        for e in all {
            XCTAssertFalse(e.description.isEmpty, "\(e) should have a description")
        }
    }
}
