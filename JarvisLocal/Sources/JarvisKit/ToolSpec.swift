import Foundation

/// L0 — spécification d'outil exposée au modèle.
///
/// Les schémas passent par le paramètre `tools` de l'appel LLM, jamais
/// recopiés dans le prompt système. Ils sont COMPTÉS dans le budget de
/// contexte (`approxChars`) : chaque outil exposé coûte du contexte réel.
public struct ToolSpec: Sendable, Codable, Equatable {
    public let name: String
    public let description: String
    /// Schéma JSON des arguments (objet JSON Schema).
    public let parameters: JSONValue

    public init(name: String, description: String, parameters: JSONValue) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }

    public var approxChars: Int {
        name.count + description.count + parameters.preview(maxChars: 4000).count + 16
    }
}

/// L0 — résultat d'outil STRUCTURÉ.
///
/// `{ok, data | error{code,message,hint}}` : le modèle reçoit des erreurs
/// actionnables, pas des phrases de rappel à l'ordre.
public struct ToolError: Sendable, Codable, Equatable {
    public let code: String
    public let message: String
    public let hint: String

    public init(code: String, message: String, hint: String) {
        self.code = code
        self.message = message
        self.hint = hint
    }
}

public struct ToolResult: Sendable, Codable, Equatable {
    public let ok: Bool
    public let data: JSONValue?
    public let error: ToolError?

    public init(ok: Bool, data: JSONValue? = nil, error: ToolError? = nil) {
        self.ok = ok
        self.data = data
        self.error = error
    }

    public static func success(_ data: JSONValue) -> ToolResult {
        ToolResult(ok: true, data: data)
    }

    public static func failure(code: String, message: String, hint: String) -> ToolResult {
        ToolResult(ok: false, error: ToolError(code: code, message: message, hint: hint))
    }

    public func toJSON() -> JSONValue {
        var o: [String: JSONValue] = ["ok": JSONValue(ok)]
        if let data { o["data"] = data }
        if let error {
            o["error"] = .object([
                "code": JSONValue(error.code),
                "message": JSONValue(error.message),
                "hint": JSONValue(error.hint),
            ])
        }
        return .object(o)
    }
}

/// L0 — décision de permission.
public enum PermissionDecision: String, Sendable, Codable, Equatable {
    case allow
    case ask
    case deny
}

/// L0 — usage mesuré d'un tour (tokens calibrés quand le provider les donne).
public struct TokenUsage: Sendable, Codable, Equatable {
    public var promptTokens: Int
    public var calibrated: Bool

    public init(promptTokens: Int, calibrated: Bool) {
        self.promptTokens = promptTokens
        self.calibrated = calibrated
    }
}
