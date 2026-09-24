import Foundation

/// L0 — contrat d'exécution d'outils vu par l'orchestration (ViewModel).
/// Implémentation : ToolService (JarvisServices, actor). Le ViewModel ne retient
/// qu'un `any ToolExecutor` — jamais le type concret.
public protocol ToolExecutor: Sendable {
    func execute(name: String, args: [String: Any]) async throws -> String
    func effectiveToolDefs() async -> [ToolDef]
}
