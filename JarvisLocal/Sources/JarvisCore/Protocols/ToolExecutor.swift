import Foundation

/// L0 — contrat d'exécution d'outils vu par l'orchestration (ViewModel).
/// Implémentation : ToolService (JarvisServices, actor). Le ViewModel ne retient
/// qu'un `any ToolExecutor` — jamais le type concret.
public protocol ToolExecutor: Sendable {
    func execute(name: String, args: [String: Any]) async throws -> String
    func effectiveToolDefs() async -> [ToolDef]
    /// État MCP : nil = MCP non configuré (rien à signaler), true = au moins
    /// un serveur en ligne, false = activé mais hors-ligne (bandeau Health
    /// Check). Défaut nil pour ne pas casser les fakes de tests existants.
    func mcpOnline() async -> Bool?
    /// Tentative de reconnexion des serveurs MCP (iMCP démarré hors-app).
    func reconnectAll() async
}

public extension ToolExecutor {
    func mcpOnline() async -> Bool? { nil }
    func reconnectAll() async {}
}
