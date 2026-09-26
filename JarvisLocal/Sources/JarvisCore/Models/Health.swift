import Foundation

/// Gravité d'un point de santé au démarrage. L'UI affiche un bandeau
/// (jamais un blocage) : un `warning` n'empêche pas de chatter.
public enum HealthIssueKind: String, Sendable, Equatable {
    /// Ollama injoignable (sonde = unknown avec message réseau).
    case ollamaUnreachable
    /// Le modèle n'émet pas de tool_calls (sonde = unsupported).
    case modelNoTools
    /// URL Ollama distante : historique + faits envoyés hors machine.
    case ollamaRemote
    /// MCP activé dans les Réglages mais aucun serveur en ligne.
    case mcpOffline
}

/// Un point de santé constaté au démarrage. Donnée pure (Core) : la collecte
/// réseau vit dans les Services / la composition root, l'affichage dans l'UI.
public struct HealthIssue: Sendable, Equatable, Identifiable {
    public let kind: HealthIssueKind
    public let message: String
    public var id: String { kind.rawValue }

    public init(kind: HealthIssueKind, message: String) {
        self.kind = kind
        self.message = message
    }
}
