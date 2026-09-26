import Foundation
import JarvisCore

/// Coordinateur de gestion du mode vocal (extraits d'AppViewModel).
/// Responsabilité unique : boucle STT/TTS, barge-in, gestion voiceTask.
/// L'état observable reste dans AppViewModel ; ce coordinateur opère via callbacks.
@MainActor
public final class VoiceCoordinator {
    // MARK: - Dépendances

    private let audio: any TTSEngine
    private let stt: any STTEngine
    private let settings: any AppSettingsProtocol
    private let messageCoordinator: MessageCoordinator
    private let conversationCoordinator: ConversationCoordinator
    private let factsCoordinator: FactsExtractionCoordinator
    private let onError: (String) -> Void
    private let getInputText: () -> String
    private let setInputText: (String) -> Void
    private let getErrorMessage: () -> String?

    // Callbacks vers AppViewModel pour l'état observable
    private let onSetVoiceMode: (Bool) -> Void
    private let onSetListening: (Bool) -> Void
    private let onSetSpeaking: (Bool) -> Void
    private let onSetSpeechStartedAt: (ContinuousClock.Instant?) -> Void
    private let onIncrementBargeInStreak: () -> Void
    private let onResetBargeInStreak: () -> Void
    private let getBargeInStreak: () -> Int
    private let getSpeechStartedAt: () -> ContinuousClock.Instant?
    private let getIsVoiceMode: () -> Bool

    /// Crée le coordinateur.
    init(
        audio: any TTSEngine,
        stt: any STTEngine,
        settings: any AppSettingsProtocol,
        messageCoordinator: MessageCoordinator,
        conversationCoordinator: ConversationCoordinator,
        factsCoordinator: FactsExtractionCoordinator,
        onError: @escaping (String) -> Void,
        getInputText: @escaping () -> String,
        setInputText: @escaping (String) -> Void,
        getErrorMessage: @escaping () -> String?,
        onSetVoiceMode: @escaping (Bool) -> Void,
        onSetListening: @escaping (Bool) -> Void,
        onSetSpeaking: @escaping (Bool) -> Void,
        onSetSpeechStartedAt: @escaping (ContinuousClock.Instant?) -> Void,
        onIncrementBargeInStreak: @escaping () -> Void,
        onResetBargeInStreak: @escaping () -> Void,
        getBargeInStreak: @escaping () -> Int,
        getSpeechStartedAt: @escaping () -> ContinuousClock.Instant?,
        getIsVoiceMode: @escaping () -> Bool
    ) {
        self.audio = audio
        self.stt = stt
        self.settings = settings
        self.messageCoordinator = messageCoordinator
        self.conversationCoordinator = conversationCoordinator
        self.factsCoordinator = factsCoordinator
        self.onError = onError
        self.getInputText = getInputText
        self.setInputText = setInputText
        self.getErrorMessage = getErrorMessage
        self.onSetVoiceMode = onSetVoiceMode
        self.onSetListening = onSetListening
        self.onSetSpeaking = onSetSpeaking
        self.onSetSpeechStartedAt = onSetSpeechStartedAt
        self.onIncrementBargeInStreak = onIncrementBargeInStreak
        self.onResetBargeInStreak = onResetBargeInStreak
        self.getBargeInStreak = getBargeInStreak
        self.getSpeechStartedAt = getSpeechStartedAt
        self.getIsVoiceMode = getIsVoiceMode
    }

    private var voiceTask: Task<Void, Never>?

    // MARK: - Mode vocal

    /// Bascule le mode vocal (appelée par l'exécutable / barre de menu).
    public func toggleVoiceMode() async {
        if getIsVoiceMode() {
            await stopVoiceMode()
        } else {
            await startVoiceMode()
        }
    }

    /// Démarre le mode vocal.
    private func startVoiceMode() async {
        onSetVoiceMode(true)
        voiceTask = Task {
            defer {
                voiceTask = nil
                stt.onPartialResult = nil
            }

            while getIsVoiceMode() && !Task.isCancelled {
                do {
                    stt.onPartialResult = { [weak self] text in
                        guard let self = self else { return }
                        guard !text.isEmpty else { return }
                        setInputText(text)

                        // Barge-in durci : deux garde-fous
                        // 1) fenêtre de grâce 600ms après début TTS
                        // 2) 2 partials consécutifs non-vides (debounce)
                        guard settings.bargeInEnabled, audio.isSpeaking else {
                            onResetBargeInStreak()
                            return
                        }
                        if let started = getSpeechStartedAt(),
                           ContinuousClock.now - started < .milliseconds(600) {
                            return
                        }
                        onIncrementBargeInStreak()
                        if getBargeInStreak() >= 2 {
                            audio.stopSpeaking()
                            onResetBargeInStreak()
                        }
                    }

                    onSetListening(true)
                    setInputText("")
                    onResetBargeInStreak()
                    let text = try await stt.transcribe()
                    onSetListening(false)
                    stt.onPartialResult = nil

                    guard !text.isEmpty else { continue }

                    // Filtre anti-bruit : ignore transcriptions ≤ 2 caractères
                    guard text.count > 2 else { continue }

                    // Délai réduit pour éviter impression de latence
                    try? await Task.sleep(nanoseconds: 100_000_000)

                    await runConversationTurn(userText: text)

                    // Retry une fois si Ollama n'a pas répondu
                    if let err = getErrorMessage(), err.contains("Pas de réponse") {
                        onError("") // clear error
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        await runConversationTurn(userText: text)
                    }

                    // Attend la fin du TTS avant de rouvrir le micro
                    while audio.isSpeaking && getIsVoiceMode() && !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 60_000_000)
                    }
                } catch {
                    onSetListening(false)
                    if let sttErr = error as? STTError, sttErr == .cancelled { break }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            onSetVoiceMode(false)
            onSetListening(false)
            setInputText("")
        }
    }

    /// Arrête le mode vocal.
    private func stopVoiceMode() async {
        onSetVoiceMode(false)
        onSetListening(false)
        stt.cancel()
        voiceTask?.cancel()
        voiceTask = nil
        await messageCoordinator.stopStreaming()
    }

    /// Exécute un tour de conversation (délègue au messageCoordinator).
    private func runConversationTurn(userText: String) async {
        await messageCoordinator.sendMessage()
    }
}