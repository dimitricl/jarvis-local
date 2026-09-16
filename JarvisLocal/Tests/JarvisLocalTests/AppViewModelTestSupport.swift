@testable import JarvisServices
import JarvisCore
import JarvisUI

/// Câblage test des singletons partagés.
///
/// `AppViewModel()` sans argument n'existe ni dans JarvisUI (qui ne connaît que
/// les protocols Core) ni dans JarvisServices (qui ne connaît pas JarvisUI —
/// dépendance inversée interdite). Il vit donc ici, dans la target de tests,
/// seule à voir les deux côtés.
///
/// Sémantique préservée : les tests historiques partagent les mêmes singletons
/// qu'avant le découpage — dont DatabaseService.shared, ouvert en `:memory:`
/// par chaque setUp.
@MainActor
extension AppViewModel {
    convenience init() {
        self.init(
            db: DatabaseService.shared,
            ollama: OllamaService.shared,
            tools: ToolService.shared,
            audio: AudioService.shared,
            stt: STTService.shared,
            settings: Settings.shared
        )
    }
}
