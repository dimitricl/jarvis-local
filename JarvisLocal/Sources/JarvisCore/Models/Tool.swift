import Foundation

public struct ToolDef: Codable {
    public let type: String
    public let function: ToolFunction

    public init(function: ToolFunction) {
        self.type = "function"
        self.function = function
    }
}

public struct ToolFunction: Codable {
    public let name: String
    public let description: String
    public let parameters: ToolParameters

    public init(name: String, description: String, parameters: ToolParameters) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct ToolParameters: Codable {
    public let type: String
    public let properties: [String: ToolProperty]
    public let required: [String]

    public init(properties: [String: ToolProperty], required: [String]) {
        self.type = "object"
        self.properties = properties
        self.required = required
    }
}

public struct ToolProperty: Codable {
    public let type: String
    public let description: String?

    public init(type: String, description: String?) {
        self.type = type
        self.description = description
    }
}

public struct ToolCall: Codable {
    public let id: String
    public let type: String?
    public let function: ToolCallFunction

    public init(id: String, type: String?, function: ToolCallFunction) {
        self.id = id
        self.type = type
        self.function = function
    }
}

public struct ToolCallFunction: Codable {
    public let name: String
    public let arguments: String

    public init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }
}

public struct ToolResult {
    public let toolCallId: String
    public let content: String

    public init(toolCallId: String, content: String) {
        self.toolCallId = toolCallId
        self.content = content
    }
}

/// Une exécution d'outil persistée : qui, quoi, avec quels arguments, quel statut,
/// quel résultat (tronqué). Alimente la commande /tools — la réponse à "est-ce qu'il
/// l'a VRAIMENT fait ?" ne doit plus dépendre de la mémoire du modèle.
public struct ToolRun: Identifiable, Hashable {
    public let id: Int
    public let tool: String
    public let args: String
    public let status: String
    public let result: String
    public let conversationId: Int?
    public let createdAt: Date

    public init(id: Int, tool: String, args: String, status: String, result: String, conversationId: Int?, createdAt: Date) {
        self.id = id
        self.tool = tool
        self.args = args
        self.status = status
        self.result = result
        self.conversationId = conversationId
        self.createdAt = createdAt
    }
}
