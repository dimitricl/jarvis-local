@testable import JarvisCore
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
        let raw = """
        {"id": 3, "role": "user", "content": "test", "conversation_id": 5, "created_at": 1700000000}
        """
        let json = Data(raw.utf8)
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
        let raw = """
        {"id": 2, "key": "user.city", "value": "Paris", "updated_at": 1700000000}
        """
        let json = Data(raw.utf8)
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
