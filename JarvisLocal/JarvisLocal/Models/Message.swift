import Foundation

struct Message: Codable, Identifiable, Hashable {
    let id: Int
    let role: String
    let content: String
    let conversationId: Int?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, role, content
        case conversationId = "conversation_id"
        case createdAt = "created_at"
    }
}

struct OllamaMessage: Codable {
    var role: String
    var content: String?
    var toolCalls: [ToolCall]?
    /// ID du tool_call auquel ce message (role "tool") répond. Sans ce champ, un backend
    /// OpenAI-compatible ne peut pas associer un résultat à l'appel qui l'a produit dès que
    /// plusieurs tools sont appelés dans le même tour : ordre non garanti, et certains backends
    /// (llama.cpp, vLLM) rejettent purement et simplement le message "tool" sans tool_call_id.
    var toolCallId: String?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }

    init(role: String, content: String?, toolCalls: [ToolCall]? = nil, toolCallId: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }
}

struct OllamaRequest: Codable {
    let model: String
    let messages: [OllamaMessage]
    let stream: Bool
    let options: [String: Double]
    let tools: [ToolDef]?
}

struct OllamaResponse: Codable {
    let model: String
    let createdAt: String?
    let message: OllamaResponseMessage?
    let done: Bool?

    enum CodingKeys: String, CodingKey {
        case model
        case createdAt = "created_at"
        case message, done
    }
}

struct OllamaResponseMessage: Codable {
    let role: String?
    let content: String?
    let toolCalls: [ToolCall]?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
    }
}

struct OllamaStreamChunk: Codable {
    let model: String?
    let createdAt: String?
    let message: OllamaStreamMessage?
    let done: Bool?

    enum CodingKeys: String, CodingKey {
        case model
        case createdAt = "created_at"
        case message, done
    }
}

struct OllamaStreamMessage: Codable {
    let role: String?
    let content: String?
}
