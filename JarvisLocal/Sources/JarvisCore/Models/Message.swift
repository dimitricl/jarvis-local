import Foundation

public struct Message: Codable, Identifiable, Hashable, Sendable {
    public let id: Int
    public let role: String
    public let content: String
    public let conversationId: Int?
    public let createdAt: Date

    public init(id: Int, role: String, content: String, conversationId: Int?, createdAt: Date) {
        self.id = id
        self.role = role
        self.content = content
        self.conversationId = conversationId
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, role, content
        case conversationId = "conversation_id"
        case createdAt = "created_at"
    }
}

public struct OllamaMessage: Codable, Sendable {
    public var role: String
    public var content: String?
    public var toolCalls: [ToolCall]?
    /// ID du tool_call auquel ce message (role "tool") répond. Sans ce champ, un backend
    /// OpenAI-compatible ne peut pas associer un résultat à l'appel qui l'a produit dès que
    /// plusieurs tools sont appelés dans le même tour : ordre non garanti, et certains backends
    /// (llama.cpp, vLLM) rejettent purement et simplement le message "tool" sans tool_call_id.
    public var toolCallId: String?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
    }

    public init(role: String, content: String?, toolCalls: [ToolCall]? = nil, toolCallId: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
    }
}

public struct OllamaRequest: Codable, Sendable {
    public let model: String
    public let messages: [OllamaMessage]
    public let stream: Bool
    public let options: [String: Double]
    public let tools: [ToolDef]?
}

public struct OllamaResponse: Codable, Sendable {
    public let model: String
    public let createdAt: String?
    public let message: OllamaResponseMessage?
    public let done: Bool?

    enum CodingKeys: String, CodingKey {
        case model
        case createdAt = "created_at"
        case message, done
    }
}

public struct OllamaResponseMessage: Codable, Sendable {
    public let role: String?
    public let content: String?
    public let toolCalls: [ToolCall]?

    enum CodingKeys: String, CodingKey {
        case role, content
        case toolCalls = "tool_calls"
    }
}

public struct OllamaStreamChunk: Codable, Sendable {
    public let model: String?
    public let createdAt: String?
    public let message: OllamaStreamMessage?
    public let done: Bool?

    enum CodingKeys: String, CodingKey {
        case model
        case createdAt = "created_at"
        case message, done
    }
}

public struct OllamaStreamMessage: Codable, Sendable {
    public let role: String?
    public let content: String?
}
