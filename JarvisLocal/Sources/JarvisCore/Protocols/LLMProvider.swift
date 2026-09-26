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
    /// Sonde tool-calling (défaut : indéterminé). OllamaService la surcharge
    /// avec une vraie sonde réseau ; un futur provider sans sonde garde ce
    /// défaut au lieu de casser la compilation — le Health Check affichera
    /// simplement l'indéterminé non-réseau (aucun bandeau).
    func probeToolCalling() async -> ToolCallingSupport
}

public extension LLMProvider {
    func probeToolCalling() async -> ToolCallingSupport {
        .unknown("Sonde non supportée par ce provider.")
    }
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
