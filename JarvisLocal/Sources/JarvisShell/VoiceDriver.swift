import Foundation
import JarvisCore
import JarvisServices

/// L3 — pilote voix du HUD : push-to-talk + toggle + TTS.
///
/// Acteur : il retient les moteurs STT/TTS historiques (non-Sendable, mode
/// langage v5) comme état isolé — aucune valeur non-Sendable ne traverse.
/// - Appui hotkey : démarre la dictée (partiels → HUD). Relâcher après un
///   maintien envoie le dernier partiel (≥ 2 mots) ; appui court = toggle
///   (ré-enregistre jusqu'au prochain appui ou au silence moteur).
/// - Réponse agent : lue via TTS si activé ; tout appui pendant la parole =
///   barge-in (coupe parole + run).
/// - Seul du TEXTE transite vers le serveur : micro et synthèse restent
///   100 % locaux. Moteur STT : Apple Speech (éprouvé v0.9.1) ; benchmark
///   WhisperKit = suivi documenté (`docs/voice-engines.md`), pas bloquant.
public enum VoiceEvent: Sendable, Equatable {
    case partial(String)
    case finalInput(String)
    case cancelled
    case sttError(String)
}

public actor VoiceDriver {
    private let stt: SendableSTT
    private let tts: SendableTTS
    private let onEvent: @Sendable (VoiceEvent) -> Void
    private var recording = false
    private var partial = ""

    public init(
        stt: SendableSTT = SendableSTT.shared,
        tts: SendableTTS = SendableTTS.shared,
        onEvent: @Sendable @escaping (VoiceEvent) -> Void
    ) {
        self.stt = stt
        self.tts = tts
        self.onEvent = onEvent
    }

    public var isRecording: Bool { recording }
    public var isSpeaking: Bool { tts.isSpeaking }

    /// Démarre la dictée ; false si déjà en cours. Se termine (événement
    /// `finalInput`) au silence moteur, à `stopAndSend` ou `cancelDictation`.
    @discardableResult
    public func startDictation() -> Bool {
        guard !recording else { return false }
        recording = true
        partial = ""
        stt.onPartialResult = { [weak self] text in
            Task { await self?.handlePartial(text) }
        }
        return true
    }

    private func handlePartial(_ text: String) {
        partial = text
        onEvent(.partial(text))
    }

    /// Boucle de dictée : à attendre par l'appelant (tâche annulable).
    public func dictate() async {
        defer { recording = false }
        do {
            let text = try await stt.transcribe()
            onEvent(.finalInput(text))
        } catch {
            if let sttError = error as? STTError, sttError == .cancelled {
                onEvent(.cancelled)
            } else {
                let message = (error as? STTError)?.description ?? "\(error)"
                onEvent(.sttError(message))
            }
        }
    }

    /// Fin de dictée : envoie le dernier partiel s'il est consistant.
    public func stopAndSend(minWords: Int = 2) {
        let text = partial
        stt.cancel()
        if Self.wordCount(text) >= minWords {
            onEvent(.finalInput(text))
        } else {
            onEvent(.cancelled)
        }
    }

    public func cancelDictation() {
        stt.cancel()
    }

    public func speak(_ text: String, enabled: Bool) async {
        if enabled {
            await tts.speak(text)
        }
    }

    public func stopSpeaking() {
        tts.stopSpeaking()
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }
}
