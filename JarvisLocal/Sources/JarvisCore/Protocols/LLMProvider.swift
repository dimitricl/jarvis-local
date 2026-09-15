import Foundation

/// L0 — contrat de completion LLM (streaming + tool calling).
///
/// Étape 1 (découpage) : débranche le couplage dur AppViewModel → OllamaService.
/// Le ViewModel ne retient qu'un `any LLMProvider`.
/// Étape 2 : factory + retrait des accès directs restants (warm-up, keep-alive).
///
/// OllamaService (JarvisServices) n'est qu'une implémentation parmi d'autres :
/// aucun second provider ajouté ici, juste la frontière.
public protocol LLMProvider: Sendable {
    func streamChat(messages: [OllamaMessage], tools: [ToolDef]?) -> AsyncThrowingStream<OllamaStreamEvent, Error>
}

/// Famille de provider. Un seul cas aujourd'hui (Ollama) — l'enum est le point
/// d'extension : ajouter un cas + sa branche dans LLMProviderFactory (Services)
/// suffit à brancher un second provider, sans toucher ni Core ni l'UI.
public enum LLMProviderKind: String, Sendable, CaseIterable {
    case ollama

    public var displayName: String {
        switch self {
        case .ollama: return "Ollama"
        }
    }
}
