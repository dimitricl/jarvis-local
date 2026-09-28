import Foundation

/// L0 — messages de conversation persistés tels quels.
///
/// Contrairement au pipeline v0.9.1 (qui ne persistait que du texte
/// user/assistant et faisait perdre au modèle le contexte de ses actes),
/// `assistant.tool_calls` et les messages `tool` font partie du transcript :
/// au tour suivant, le modèle voit ce qu'il a fait.
public enum Role: String, Sendable, Codable, Equatable, Hashable {
    case system
    case user
    case assistant
    case tool
}

public struct ToolCallRef: Sendable, Codable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let arguments: JSONValue

    public init(id: String, name: String, arguments: JSONValue) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct Message: Sendable, Codable, Equatable {
    public var role: Role
    public var content: String?
    public var toolCalls: [ToolCallRef]?
    /// Renseigné pour `role == .tool` : appariement appel ↔ résultat.
    public var toolCallId: String?
    public var name: String?

    public init(
        role: Role,
        content: String? = nil,
        toolCalls: [ToolCallRef]? = nil,
        toolCallId: String? = nil,
        name: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.name = name
    }

    /// Taille approximative en caractères (budget de contexte).
    public var approxChars: Int {
        var n = content?.count ?? 0
        if let calls = toolCalls {
            for c in calls { n += c.id.count + c.name.count + c.arguments.preview(maxChars: 4000).count }
        }
        n += (toolCallId?.count ?? 0) + (name?.count ?? 0) + 16
        return n
    }
}
