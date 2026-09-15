@testable import JarvisServices
import JarvisCore
import XCTest

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
