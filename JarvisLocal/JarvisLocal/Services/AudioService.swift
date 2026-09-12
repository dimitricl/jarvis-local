import Foundation
@preconcurrency import AVFoundation
import Speech
import os.log

final class AudioService: NSObject {
    static let shared = AudioService()

    // swiftlint:ignore next line
    nonisolated(unsafe) private let synthesizer = AVSpeechSynthesizer()
    private var speechContinuation: CheckedContinuation<Void, Never>?
    private var audioPlayerContinuation: CheckedContinuation<Void, Never>?
    private var audioPlayer: AVAudioPlayer?
    
    // File d'attente pour éviter les conflits TTS
    private var audioQueue: [String] = []
    private var isProcessingQueue = false

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - TTS Routing

    /// Ajoute du texte à la file SANS attendre la fin de lecture. Utilisé par le mode
    /// streaming : les phrases sont poussées au fil de l'arrivée des tokens et jouées
    /// à la suite, pour que la voix démarre dès la première phrase complète.
    func enqueue(_ text: String) {
        let clean = normalizeForTTS(text)
        guard !clean.isEmpty else { return }
        audioQueue.append(clean)
        startQueueProcessorIfNeeded()
    }

    /// Enqueue puis attend que toute la file ait été lue. Comportement historique
    /// de speak(), utilisé quand l'appelant doit synchroniser sur la fin du TTS
    /// (annonces de confirmation, fin de tour en mode vocal).
    func speak(_ text: String) async {
        enqueue(text)
        while isProcessingQueue || !audioQueue.isEmpty
                || synthesizer.isSpeaking || (audioPlayer?.isPlaying ?? false) {
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
    }

    private func startQueueProcessorIfNeeded() {
        guard !isProcessingQueue else { return }
        isProcessingQueue = true
        Task { [weak self] in
            await self?.processAudioQueue()
        }
    }

    private func processAudioQueue() async {
        defer { isProcessingQueue = false }
        while !audioQueue.isEmpty {
            let text = audioQueue.removeFirst()
            let settings = Settings.shared

            switch settings.ttsEngine {
            case .system:
                await speakSystemTTS(text)
            case .edgeTTS:
                await speakEdgeTTS(text)
            }
        }
    }

    // MARK: - System TTS (AVSpeechSynthesizer)

    private var selectedVoice: AVSpeechSynthesisVoice? {
        Settings.shared.selectedVoice
    }

    private func speakSystemTTS(_ text: String) async {
        let voice = selectedVoice
        let baseRate: Float

        if voice?.quality == .enhanced || (voice?.identifier.contains("premium") ?? false) {
            baseRate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        } else {
            baseRate = AVSpeechUtteranceDefaultSpeechRate * 0.98
        }

        let sentences = splitIntoSentences(text)
        for (i, sentence) in sentences.enumerated() {
            guard !Task.isCancelled else { break }

            let utterance = AVSpeechUtterance(string: sentence)
            utterance.voice = voice
            utterance.rate = baseRate

            let isQuestion = sentence.hasSuffix("?")
            utterance.pitchMultiplier = isQuestion ? 1.15 : (i % 2 == 0 ? 1.0 : 0.95)

            utterance.preUtteranceDelay = i == 0 ? 0 : 0.15

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                speechContinuation = continuation
                synthesizer.speak(utterance)
            }
        }
    }

    // MARK: - Edge TTS

    private func speakEdgeTTS(_ text: String) async {
        guard let edgeTTSPath = findEdgeTTS() else {
            os_log("edge-tts introuvable, fallback sur la synthèse macOS")
            await speakSystemTTS(text)
            return
        }

        let voice = Settings.shared.edgeTTSVoice
        guard !voice.isEmpty else {
            await speakSystemTTS(text)
            return
        }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("jarvis_\(UUID().uuidString).mp3")

        defer { try? FileManager.default.removeItem(at: tempURL) }

        let process = Process()
        process.executableURL = edgeTTSPath
        process.arguments = ["--voice", voice, "--text", text, "--write-media", tempURL.path]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            os_log("Échec edge-tts : \(error.localizedDescription), fallback macOS")
            await speakSystemTTS(text)
            return
        }

        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: tempURL.path) else {
            os_log("edge-tts status \(process.terminationStatus), fallback macOS")
            await speakSystemTTS(text)
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: tempURL)
            player.delegate = self
            self.audioPlayer = player

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                audioPlayerContinuation = continuation
                player.play()
            }
        } catch {
            os_log("Échec lecture audio edge-tts : \(error.localizedDescription), fallback macOS")
            await speakSystemTTS(text)
        }
    }

    /// NOTE : `internal` pour les tests
    func findEdgeTTS() -> URL? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["edge-tts"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        guard task.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    func stopSpeaking() {
        audioQueue.removeAll()
        isProcessingQueue = false
        synthesizer.stopSpeaking(at: .immediate)
        if let c = speechContinuation {
            speechContinuation = nil
            c.resume()
        }
        if let player = audioPlayer {
            player.stop()
            player.currentTime = 0
            if let c2 = audioPlayerContinuation {
                audioPlayerContinuation = nil
                c2.resume()
            }
            audioPlayer = nil
        } else if let c2 = audioPlayerContinuation {
            audioPlayerContinuation = nil
            c2.resume()
        }
    }

    var isSpeaking: Bool {
        synthesizer.isSpeaking || (audioPlayer?.isPlaying ?? false) || audioQueue.count > 0
    }

    /// NOTE : `internal` pour les tests
    func splitIntoSentences(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var result: [String] = []
        var current = ""
        for char in trimmed {
            current.append(char)
            if char == "." || char == "?" || char == "!" {
                let sentence = current.trimmingCharacters(in: .whitespaces)
                if !sentence.isEmpty { result.append(sentence) }
                current = ""
            }
        }
        let remaining = current.trimmingCharacters(in: .whitespaces)
        if !remaining.isEmpty { result.append(remaining) }

        return result.isEmpty ? [trimmed] : result
    }

    /// NOTE : `internal` pour les tests
    func normalizeForTTS(_ text: String) -> String {
        var t = text
        t = stripMarkdown(t)
        t = stripEmojis(t)
        t = normalizeAbbreviations(t)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t
    }

    /// NOTE : `internal` pour les tests
    func stripMarkdown(_ text: String) -> String {
        var t = text
        if let rx = try? NSRegularExpression(pattern: "<think>[\\s\\S]*?<\\/think>", options: [.dotMatchesLineSeparators]) {
            t = rx.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "")
        }
        let regexes: [(pattern: String, replacement: String)] = [
            ( "[`*#_~>|]", "" ),
            ( "\\n{3,}", "\n\n" ),
        ]
        for (pattern, replacement) in regexes {
            t = t.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        // Remove list markers per line
        t = t.split(separator: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                return String(trimmed.dropFirst(2))
            }
            if trimmed.range(of: "^\\d+\\.\\s+", options: .regularExpression) != nil {
                if let range = trimmed.range(of: "^\\d+\\.\\s+", options: .regularExpression) {
                    return String(trimmed[range.upperBound...])
                }
            }
            return String(line)
        }.joined(separator: "\n")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// NOTE : `internal` pour les tests
    func stripEmojis(_ text: String) -> String {
        text.replacingOccurrences(of: "[\\p{So}\\p{Cn}]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// NOTE : `internal` pour les tests
    func normalizeAbbreviations(_ text: String) -> String {
        var t = text
        let replacements: [(String, String)] = [
            ( "M\\. ", "Monsieur " ),
            ( "Mme ", "Madame " ),
            ( "Mlles? ", "Mademoiselle " ),
            ( "Dr\\.? ", "Docteur " ),
            ( "Pr\\.? ", "Professeur " ),
            ( "n°\\s*", "numéro " ),
            ( "€", " euros" ),
            ( "%", " pour cent" ),
            ( "&", " et" ),
            ( "\\+", " plus" ),
            ( "/", " sur " ),
        ]
        for (pattern, replacement) in replacements {
            t = t.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        return t
    }
}

extension AudioService: AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    // Les delegates AVSpeechSynthesizer et AVAudioPlayer sont appelés depuis un thread
    // arbitraire (queue interne du framework audio). Les continuations sont des checked
    // continuations qui peuvent être reprises depuis n'importe quel thread, mais stopSpeaking()
    // les lit aussi depuis MainActor. On dispatch sur MainActor pour éviter la race.
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            if let c = self.audioPlayerContinuation {
                self.audioPlayerContinuation = nil
                c.resume()
            }
            self.audioPlayer = nil
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if let c = self.speechContinuation {
                self.speechContinuation = nil
                c.resume()
            }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if let c = self.speechContinuation {
                self.speechContinuation = nil
                c.resume()
            }
        }
    }
}

// MARK: - STT

final class STTService: NSObject, SFSpeechRecognizerDelegate {
    static let shared = STTService()

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "fr-FR"))
    private let audioEngine = AVAudioEngine()
    static let maxRestarts = 3

    // THREAD-SAFETY : tout l'état mutable ci-dessous n'est lu/modifié que sur stateQueue,
    // une file sérielle unique. La closure de recognitionTask tourne sur un thread arbitraire
    // (queue interne du framework Speech), transcribe()/cancel() sont appelés depuis MainActor
    // (AppViewModel), le silenceTimer tire sur .main : avant, isRecording, recognitionRequest,
    // silenceTimer, restartCount et continuation étaient touchés depuis ces trois contextes sans
    // synchronisation (data race : double resume de continuation, timer annulé après réarmement,
    // restartCount incrémenté en concurrence). Chaque point d'entrée y redirige son travail
    // (stateQueue.async/sync) et les méthodes suffixées Locked supposent qu'on y est déjà.
    private let stateQueue = DispatchQueue(label: "com.jarvislocal.stt-state")
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<String, Error>?
    private var silenceTimer: DispatchSourceTimer?
    private var isRecording = false
    private var restartCountValue = 0
    private var partialHandler: ((String) -> Void)?

    // NOTE : `internal` pour les tests — accès synchronisé sur stateQueue pour rester
    // thread-safe malgré l'exposition.
    var restartCount: Int {
        get { stateQueue.sync { restartCountValue } }
        set { stateQueue.sync { restartCountValue = newValue } }
    }

    /// Callback de transcript partiel. Posé/lu depuis MainActor (AppViewModel) mais INVOQUÉ
    /// depuis la closure de recognitionTask : le getter/setter passent par stateQueue et
    /// l'invocation se fait sur une copie capturée, dispatchée sur .main (comportement
    /// historique : l'UI met à jour inputText).
    var onPartialResult: ((String) -> Void)? {
        get { stateQueue.sync { partialHandler } }
        set { stateQueue.sync { partialHandler = newValue } }
    }

    private override init() {
        super.init()
        speechRecognizer?.delegate = self
    }

    func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func transcribe() async throws -> String {
        let authorized = await requestAuthorization()
        guard authorized else { throw STTError.notAuthorized }
        return try await withCheckedThrowingContinuation { continuation in
            // La continuation est stockée sur stateQueue avec le démarrage : poser l'une
            // sans l'autre depuis deux threads aurait permis un resume sur nil ou un double
            // démarrage concurrent.
            stateQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: STTError.cancelled)
                    return
                }
                self.continuation = continuation
                self.startRecordingLocked()
            }
        }
    }

    private func startRecording() {
        stateQueue.async { [weak self] in self?.startRecordingLocked() }
    }

    private func startRecordingLocked() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            resumeLocked(throwing: STTError.notAvailable)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = false
        // Ponctuation automatique : le texte affiché (et l'analyse des phrases pour le TTS)
        // gagne en qualité sans coût perceptible.
        request.addsPunctuation = true
        request.contextualStrings = ["Jarvis", "bonjour", "salut", "merci", "oui", "non", "stop", "arrête", "rappel", "note", "message", "calendrier", "recherche", "météo", "raccourci", "heure", "date", "au revoir", "d'accord", "super", "parfait"]
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        // 4096 frames (~0.26s à 16 kHz) au lieu de 16384 : les résultats partiels arrivent
        // ~3x plus souvent → transcript live plus fluide et barge-in plus réactif.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            let message = error.localizedDescription
            resumeLocked(throwing: STTError.engineError(message))
            return
        }
        isRecording = true

        // NOTE : cette closure est invoquée sur un thread arbitraire du framework Speech.
        // On rebascule immédiatement sur stateQueue : tout ce qui suit (restartCount,
        // stop, timer, continuation) s'exécute sous exclusion mutuelle avec transcribe(),
        // cancel() et le silenceTimer.
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            // Copie locale : result/error sont des objets du callback, sûrs à transférer
            // vers stateQueue (un seul hop, pas de lecture différée depuis l'autre thread).
            let capturedResult = result
            let capturedError = error
            self.stateQueue.async {
                self.handleRecognitionEventLocked(result: capturedResult, error: capturedError)
            }
        }

        scheduleSilenceTimerLocked()
    }

    /// Traite un événement de recognitionTask. Appelé UNIQUEMENT sur stateQueue
    /// (voir le hop dans startRecordingLocked) — restartCountValue, isRecording,
    /// continuation et le timer y sont donc manipulés sans concurrence.
    private func handleRecognitionEventLocked(
        result: SFSpeechRecognitionResult?,
        error: Error?
    ) {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        if let error {
            let nsError = error as NSError
            if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                restartRecordingLocked()
                return
            }
            stopRecordingLocked()
            resumeLocked(throwing: error)
            return
        }
        guard let result else { return }
        let text = result.bestTranscription.formattedString

        if !result.isFinal {
            if !text.isEmpty {
                scheduleSilenceTimerLocked()
                emitPartialLocked(text)
            }
            return
        }

        let wordCount = text.split(separator: " ").count
        if wordCount < 1 {
            guard restartCountValue < Self.maxRestarts else {
                stopRecordingLocked()
                restartCountValue = 0
                resumeLocked(throwing: STTError.noSpeech)
                return
            }
            restartCountValue += 1
            restartRecordingLocked()
            return
        }

        restartCountValue = 0
        stopRecordingLocked()
        emitPartialLocked(text)
        resumeLocked(returning: text)
    }

    /// Reprend la continuation en attente (exactement une fois : take-and-clear sous
    /// stateQueue) puis effectue le resume HORS queue — le code réveillé (boucle vocale)
    /// peut rappeler cancel(), et on ne veut pas de réentrance sur stateQueue.
    private func resumeLocked(returning value: String) {
        let cont = takeContinuationLocked()
        resumeOnMain(cont) { $0.resume(returning: value) }
    }

    private func resumeLocked(throwing error: Error) {
        let cont = takeContinuationLocked()
        resumeOnMain(cont) { $0.resume(throwing: error) }
    }

    private func takeContinuationLocked() -> CheckedContinuation<String, Error>? {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        let cont = continuation
        continuation = nil
        return cont
    }

    private func resumeOnMain(
        _ cont: CheckedContinuation<String, Error>?,
        _ body: @escaping (CheckedContinuation<String, Error>) -> Void
    ) {
        guard let cont else { return }
        Task { @MainActor in body(cont) }
    }

    /// Invoque le handler de partiels sur une copie capturée sous stateQueue, dispatchée
    /// sur .main (l'UI met à jour inputText — comportement historique inchangé).
    private func emitPartialLocked(_ text: String) {
        let handler = partialHandler
        DispatchQueue.main.async { handler?(text) }
    }

    private func restartRecordingLocked() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        stopRecordingLocked()
        // Le redémarrage repasse par .main puis startRecording() : AVAudioEngine
        // (installTap/start) était historiquement démarré depuis ce contexte, on garde
        // l'ordre stop-puis-start sans changer le threading du moteur audio.
        DispatchQueue.main.async { [weak self] in
            self?.startRecording()
        }
    }

    private func scheduleSilenceTimerLocked() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        silenceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // 5s après le dernier résultat partiel : à 4s Jarvis coupait souvent en plein
        // milieu d'une hésitation ou d'une respiration longue. Le timer est réarmé à
        // chaque partiel, donc c'est bien un détecteur de fin de parole, pas une
        // durée d'enregistrement fixe.
        timer.schedule(deadline: .now() + 5.0, repeating: .never)
        timer.setEventHandler { [weak self] in
            // Le timer tire sur .main : on rebascule sur stateQueue avant de lire
            // isRecording/recognitionRequest (ancien code les lisait ici en race).
            guard let self else { return }
            self.stateQueue.async {
                guard self.isRecording else { return }
                self.recognitionRequest?.endAudio()
            }
        }
        timer.activate()
        silenceTimer = timer
    }

    private func stopRecordingLocked() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        isRecording = false
        silenceTimer?.cancel()
        silenceTimer = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    func cancel() {
        // Synchrone (comportement historique : stopStreaming() suppose l'arrêt immédiat
        // au retour). Le resume de la continuation se fait hors queue via take-and-clear
        // pour ne jamais reprendre deux fois ni se réengager sur stateQueue.
        let cont: CheckedContinuation<String, Error>? = stateQueue.sync {
            restartCountValue = 0
            stopRecordingLocked()
            return takeContinuationLocked()
        }
        resumeOnMain(cont) { $0.resume(throwing: STTError.cancelled) }
    }
}

enum STTError: Error, CustomStringConvertible, Equatable {
    case notAuthorized
    case cancelled
    case noSpeech
    case notAvailable
    case engineError(String)

    var description: String {
        switch self {
        case .notAuthorized: return "Permission micro refusée"
        case .cancelled: return "Annulé"
        case .noSpeech: return "Aucune parole détectée"
        case .notAvailable: return "Reconnaissance vocale indisponible"
        case .engineError(let s): return "Erreur moteur audio : \(s)"
        }
    }
}
