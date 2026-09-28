import Foundation
import JarvisCore

/// Enveloppes Sendable des moteurs voix historiques pour les modules Swift 6.
///
/// `@unchecked` JUSTIFIÉ, invariant tenu par construction :
/// - `STTService` sérialise son état mutable interne (`stateQueue`) ;
/// - `AudioService` confine sa synthèse au main thread ;
/// - dans le shell, un seul pilote (l'acteur `VoiceDriver`) les appelle, un
///   appel à la fois — aucune concurrence réelle.
/// L'ancien pipeline (v5) n'est plus démarré en phase 3 : aucun accès
/// concurrent legacy ne peut apparaître. Sans ces enveloppes, chaque appel
/// `await` sur les existentiels non-Sendable est une erreur Swift 6.
public final class SendableSTT: @unchecked Sendable {
    public static let shared = SendableSTT()

    private init() {}

    public var onPartialResult: ((String) -> Void)? {
        get { STTService.shared.onPartialResult }
        set { STTService.shared.onPartialResult = newValue }
    }

    public func transcribe() async throws -> String {
        try await STTService.shared.transcribe()
    }

    public func cancel() {
        STTService.shared.cancel()
    }
}

public final class SendableTTS: @unchecked Sendable {
    public static let shared = SendableTTS()

    private init() {}

    public func speak(_ text: String) async {
        await AudioService.shared.speak(text)
    }

    public func enqueue(_ text: String) {
        AudioService.shared.enqueue(text)
    }

    public func stopSpeaking() {
        AudioService.shared.stopSpeaking()
    }

    public var isSpeaking: Bool { AudioService.shared.isSpeaking }
}
