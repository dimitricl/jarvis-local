import XCTest
@testable import JarvisKit

final class JSONValueTests: XCTestCase {
    func testCodableRoundTrip() throws {
        let value = JSONValue.object([
            "name": JSONValue("x"),
            "n": JSONValue(3),
            "f": JSONValue(1.5),
            "b": JSONValue(true),
            "z": JSONValue.null,
            "a": JSONValue([JSONValue(1), JSONValue("deux")])
        ])
        let data = try JSONEncoder().encode(value)
        let back = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(back, value)
    }

    func testFromJSONObjectKeepsInts() throws {
        let v = try JSONValue(jsonObject: ["a": 3, "b": 1.5, "c": true, "d": NSNull(), "e": [1, "x"]] as [String: Any])
        XCTAssertEqual(v["a"], .int(3))
        XCTAssertEqual(v["b"], .double(1.5))
        XCTAssertEqual(v["c"], .bool(true))
        XCTAssertTrue(v["d"].isNull)
        XCTAssertEqual(v["e"].array?.count, 2)
    }

    func testUnsupportedTypeThrows() {
        XCTAssertThrowsError(try JSONValue(jsonObject: Date()))
    }

    func testAccessors() {
        XCTAssertEqual(JSONValue("s").string, "s")
        XCTAssertNil(JSONValue(1).string)
        XCTAssertEqual(JSONValue(2).double, 2.0)
        XCTAssertEqual(JSONValue(2.0).int, 2)
        XCTAssertNil(JSONValue("x").int)
        XCTAssertEqual(JSONValue.bool(true).bool, true)
        XCTAssertTrue(JSONValue.null["anything"].isNull)
    }

    func testPreviewTruncates() {
        let long = JSONValue(String(repeating: "a", count: 500))
        XCTAssertTrue(long.preview(maxChars: 10).hasSuffix("…"))
        XCTAssertFalse(JSONValue("court").preview().hasSuffix("…"))
    }
}

final class MessageTests: XCTestCase {
    func testTranscriptRoundTripWithToolCalls() throws {
        let messages = [
            Message(role: .system, content: "sys"),
            Message(role: .user, content: "fais X"),
            Message(role: .assistant, toolCalls: [
                ToolCallRef(id: "c1", name: "read_file", arguments: .object(["path": .string("a.txt")]))
            ]),
            Message(role: .tool, content: "{\"ok\": true}", toolCallId: "c1", name: "read_file"),
            Message(role: .assistant, content: "fait")
        ]
        let data = try JSONEncoder().encode(messages)
        let back = try JSONDecoder().decode([Message].self, from: data)
        XCTAssertEqual(back, messages)
        // Le contexte des actes est persisté : tool_calls + tool présents.
        XCTAssertEqual(back[2].toolCalls?.first?.name, "read_file")
        XCTAssertEqual(back[3].toolCallId, "c1")
    }

    func testApproxCharsCountsTools() {
        let plain = Message(role: .user, content: "hello")
        let withTools = Message(role: .assistant, toolCalls: [
            ToolCallRef(id: "id", name: "tool", arguments: .object(["a": .string("b")]))
        ])
        XCTAssertGreaterThan(withTools.approxChars, plain.approxChars)
    }

    func testToolResultJSON() throws {
        let ok = ToolResult.success(JSONValue("alu"))
        XCTAssertTrue(ok.ok)
        let data = try ok.toJSON().encoded()
        let back = try JSONValue.decode(data)
        XCTAssertEqual(back["ok"], .bool(true))
        XCTAssertEqual(back["data"], .string("alu"))

        let ko = ToolResult.failure(code: "nope", message: "raté", hint: "réessaie")
        XCTAssertEqual(ko.error?.code, "nope")
    }

    func testToolSpecBudgetCounts() {
        let spec = ToolSpec(name: "n", description: "d", parameters: .object(["type": .string("object")]))
        XCTAssertGreaterThan(spec.approxChars, 0)
    }
}
