import Foundation
import JarvisCore

/// Points d'accès publics aux singletons de production, exposés UNIQUEMENT
/// sous leurs protocols Core.
///
/// Pourquoi des factories plutôt que des types publics : les concrets
/// (DatabaseService, AudioService, STTService...) restent `internal` —
/// hors de JarvisServices, impossible de les nommer, de les instancier ou
/// d'élargir leur API. L'exécutable assemble via ces existentiels ; les tests
/// historiques utilisent le câblage test de JarvisLocalTests.
///
/// NOTE : le provider LLM n'y figure PAS — son cycle de vie (instance retenue
/// par l'app, keep-alive) passe par LLMProviderFactory (étape 2).
public enum ServiceHosts {
    public static var store: any PersistentStore { DatabaseService.shared }
    public static var tools: any ToolExecutor { ToolService.shared }
    public static var tts: any TTSEngine { AudioService.shared }
    public static var stt: any STTEngine { STTService.shared }
    /// Socle jobs d'arrière-plan (itération agents) : exposé sous le protocol
    /// Core, comme les autres singletons — l'UI ne nomme jamais JobRegistry.
    public static var jobs: any BackgroundJobRegistry { JobRegistry.shared }
}
