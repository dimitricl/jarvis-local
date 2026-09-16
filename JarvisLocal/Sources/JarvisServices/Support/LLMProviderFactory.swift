import Foundation
import JarvisCore

/// Sélection du provider LLM. Point d'extension : ajouter un cas à
/// LLMProviderKind (Core) + sa branche ici suffit à brancher un second
/// provider — ni Core, ni l'UI, ni la composition root ne changent de forme
/// (seul le `kind` passé à `makeDefault` évolue, ex. via un futur réglage).
///
/// Pas de second provider réel à ce stade (cadrage étape 2) : l'enjeu est de
/// débrancher le couplage dur — plus aucun `OllamaService.shared` dans le
/// chemin de production, configuration injectée via protocol.
public enum LLMProviderFactory {
    /// Construit le provider demandé. Chaque appel produit une instance
    /// configurée sur `settings` — pas de singleton caché (le cycle de vie
    /// keep-alive appartient à l'instance que l'app retient).
    public static func make(kind: LLMProviderKind, settings: any AppSettingsProtocol) -> any LLMProvider {
        switch kind {
        case .ollama:
            return OllamaService(settings: settings)
        }
    }

    /// Chemin de production : le `kind` sera lu des réglages quand un second
    /// provider existera. En attendant, Ollama est le seul choix — explicite
    /// ici plutôt que dispersé en `OllamaService.shared` dans l'app.
    public static func makeDefault(settings: any AppSettingsProtocol) -> any LLMProvider {
        make(kind: .ollama, settings: settings)
    }

    /// Accès au cycle de vie keep-alive (spécifique Ollama : l'endpoint /v1 ne
    /// supporte pas keep_alive, le ping passe par l'API native /api/generate).
    /// Volontairement hors protocol LLMProvider : un provider HTTP distant
    /// n'aurait pas ce concept. La composition root l'appelle sur le concret.
    public static func makeOllama(settings: any AppSettingsProtocol) -> OllamaService {
        OllamaService(settings: settings)
    }
}
