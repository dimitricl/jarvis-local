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

    func speak(_ text: String) async {
        let clean = normalizeForTTS(text)
        guard !clean.isEmpty else { return }

        // Ajouter à la file d'attente
        audioQueue.append(clean)
        isProcessingQueue = true
        await processAudioQueue()
    }
    
    private func processAudioQueue() async {
        guard !audioQueue.isEmpty else { return }
        
        let text = audioQueue.removeFirst()
        
        if audioQueue.isEmpty {
            isProcessingQueue = false
        }
        
        let settings = Settings.shared
        
        switch settings.ttsEngine {
        case .system:
            await speakSystemTTS(text)
        case .edgeTTS:
            await speakEdgeTTS(text)
        }
        
        // Si encore des items dans la file, continuer
        if !audioQueue.isEmpty {
            await processAudioQueue()
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

    private func findEdgeTTS() -> URL? {
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
        // Vider la file d'attente (annuler les textes en attente)
        audioQueue.removeAll()
        isProcessingQueue = false
        
        // Arrêter AVSpeechSynthesizer
        synthesizer.stopSpeaking(at: .immediate)
        speechContinuation?.resume()
        speechContinuation = nil
        
        // Arrêter AVAudioPlayer (edge-tts)
        if let player = audioPlayer {
            player.stop()
            player.currentTime = 0
            audioPlayerContinuation?.resume()
            audioPlayerContinuation = nil
            audioPlayer = nil
        }
    }

    var isSpeaking: Bool {
        synthesizer.isSpeaking || (audioPlayer?.isPlaying ?? false) || audioQueue.count > 0
    }

    private func splitIntoSentences(_ text: String) -> [String] {
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

    private func normalizeForTTS(_ text: String) -> String {
        var t = text
        t = stripMarkdown(t)
        t = stripEmojis(t)
        t = normalizeAbbreviations(t)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t
    }

    private func stripMarkdown(_ text: String) -> String {
        let regexes: [(pattern: String, replacement: String)] = [
            ( "<think>[\\s\\S]*?<\\/think>", "" ),
            ( "[`*#_~>|]", "" ),
            ( "\\n{3,}", "\n\n" ),
        ]
        var t = text
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

    private func stripEmojis(_ text: String) -> String {
        text.replacingOccurrences(of: "[\\p{So}\\p{Cn}]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private func normalizeAbbreviations(_ text: String) -> String {
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
            audioPlayerContinuation?.resume()
            audioPlayerContinuation = nil
            audioPlayer = nil
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            speechContinuation?.resume()
            speechContinuation = nil
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            speechContinuation?.resume()
            speechContinuation = nil
        }
    }
}

// MARK: - STT

final class STTService: NSObject, SFSpeechRecognizerDelegate {
    static let shared = STTService()

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "fr-FR"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var continuation: CheckedContinuation<String, Error>?
    private var silenceTimer: DispatchSourceTimer?
    private var isRecording = false
    private var restartCount = 0
    private static let maxRestarts = 3


    var onPartialResult: ((String) -> Void)?

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
            self.continuation = continuation
            startRecording()
        }
    }

    private func startRecording() {
        guard let recognizer = speechRecognizer, recognizer.isAvailable else {
            Task { @MainActor in
                self.continuation?.resume(throwing: STTError.notAvailable)
                self.continuation = nil
            }
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.requiresOnDeviceRecognition = false
        request.contextualStrings = ["Jarvis", "bonjour", "salut", "merci", "oui", "non", "stop", "arrête", "rappel", "note", "message", "calendrier", "recherche", "météo", "raccourci", "heure", "date", "au revoir", "d'accord", "super", "parfait"]
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        inputNode.installTap(onBus: 0, bufferSize: 16384, format: nil) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            Task { @MainActor in
                self.continuation?.resume(throwing: STTError.engineError(error.localizedDescription))
                self.continuation = nil
            }
            return
        }
        isRecording = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let error = error {
                let nsError = error as NSError
                if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                    self.restartRecording()
                    return
                }
                self.stopRecording()
                Task { @MainActor in
                    self.continuation?.resume(throwing: error)
                    self.continuation = nil
                }
                return
            }
            guard let result = result else { return }
            let text = result.bestTranscription.formattedString

            if !result.isFinal {
                if !text.isEmpty {
                    scheduleSilenceTimer()
                    DispatchQueue.main.async { self.onPartialResult?(text) }
                }
                return
            }

            let wordCount = text.split(separator: " ").count
            if wordCount < 1 {
                guard restartCount < Self.maxRestarts else {
                    stopRecording()
                    restartCount = 0
                    Task { @MainActor in
                        self.continuation?.resume(throwing: STTError.noSpeech)
                        self.continuation = nil
                    }
                    return
                }
                restartCount += 1
                restartRecording()
                return
            }

            restartCount = 0
            stopRecording()
            DispatchQueue.main.async { self.onPartialResult?(text) }
            Task { @MainActor in
                self.continuation?.resume(returning: text)
                self.continuation = nil
            }
        }

        scheduleSilenceTimer()
    }

    private func restartRecording() {
        stopRecording()
        DispatchQueue.main.async { [weak self] in
            self?.startRecording()
        }
    }

    private func scheduleSilenceTimer() {
        silenceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 4.0, repeating: .never)
        timer.setEventHandler { [weak self] in
            guard let self = self, isRecording else { return }
            recognitionRequest?.endAudio()
        }
        timer.activate()
        silenceTimer = timer
    }

    private func stopRecording() {
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
        restartCount = 0
        stopRecording()
        continuation?.resume(throwing: STTError.cancelled)
        continuation = nil
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
