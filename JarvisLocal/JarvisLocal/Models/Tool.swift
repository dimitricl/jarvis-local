import Foundation

struct ToolDef: Codable {
    let type: String
    let function: ToolFunction

    init(function: ToolFunction) {
        self.type = "function"
        self.function = function
    }
}

struct ToolFunction: Codable {
    let name: String
    let description: String
    let parameters: ToolParameters
}

struct ToolParameters: Codable {
    let type: String
    let properties: [String: ToolProperty]
    let required: [String]

    init(properties: [String: ToolProperty], required: [String]) {
        self.type = "object"
        self.properties = properties
        self.required = required
    }
}

struct ToolProperty: Codable {
    let type: String
    let description: String?
}

struct ToolCall: Codable {
    let id: String
    let type: String?
    let function: ToolCallFunction
}

struct ToolCallFunction: Codable {
    let name: String
    let arguments: String
}

struct ToolResult {
    let toolCallId: String
    let content: String
}

/// Une exécution d'outil persistée : qui, quoi, avec quels arguments, quel statut,
/// quel résultat (tronqué). Alimente la commande /tools — la réponse à "est-ce qu'il
/// l'a VRAIMENT fait ?" ne doit plus dépendre de la mémoire du modèle.
struct ToolRun: Identifiable, Hashable {
    let id: Int
    let tool: String
    let args: String
    let status: String
    let result: String
    let conversationId: Int?
    let createdAt: Date
}
