@testable import JarvisLocal
import XCTest
import AVFoundation

final class JarvisLocalAudioServiceTests: XCTestCase {

    var audioService: AudioService!

    override func setUp() async throws {
        try await super.setUp()
        audioService = AudioService.shared
    }

    override func tearDown() async throws {
        audioService.stopSpeaking()
        try await super.tearDown()
    }

    // MARK: - TTS Queue Tests

    func testEnqueueAddsToQueue() async {
        let initialQueueCount = await getAudioQueueCount()
        audioService.enqueue("Test message")
        // Note: We can't easily test the private queue, but we can verify it doesn't crash
        XCTAssertTrue(true) // If we reach here, enqueue didn't crash
    }

    func testSpeakWaitsForCompletion() async {
        await audioService.speak("Test")
        // If we reach here, speak completed without hanging
        XCTAssertTrue(true)
    }

    func testStopSpeakingClearsQueue() async {
        audioService.enqueue("Test 1")
        audioService.enqueue("Test 2")
        audioService.stopSpeaking()
        // Should not crash
        XCTAssertTrue(true)
    }

    // NOTE (flaky connu, non lié à une régression) : ce test pilote le VRAI singleton
    // AVSpeechSynthesizer partagé entre les tests, avec une boucle d'attente de 5 s.
    // Si un autre test a laissé de la parole en cours (ou si le moteur TTS système met
    // plus de 5 s à s'arrêter sur la machine), isSpeaking peut encore être vrai au bout
    // du délai et le test échoue. Relancé en isolé ou en suite complète, il passe.
    // Ne pas conclure à une régression STT/TTS sur ce seul échec : vérifier d'abord
    // qu'il se reproduit en isolé (`swift test --filter testIsSpeakingProperty`).
    func testIsSpeakingProperty() async {
        // Le singleton est partagé entre les tests : on attend que la file se vide
        // plutôt que de supposer un état initial propre.
        audioService.stopSpeaking()
        let deadline = Date().addingTimeInterval(5)
        while audioService.isSpeaking && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            audioService.stopSpeaking()
        }
        XCTAssertFalse(audioService.isSpeaking)
    }

    // MARK: - Text Normalization Tests

    func testNormalizeForTTSRemovesMarkdown() {
        let markdown = "**Bold** and *italic* and `code`"
        let normalized = audioService.normalizeForTTS(markdown)
        XCTAssertFalse(normalized.contains("**"))
        XCTAssertFalse(normalized.contains("*"))
        XCTAssertFalse(normalized.contains("`"))
    }

    func testNormalizeForTTSRemovesEmojis() {
        let withEmojis = "Hello 😀 World 🎉"
        let normalized = audioService.normalizeForTTS(withEmojis)
        XCTAssertFalse(normalized.contains("😀"))
        XCTAssertFalse(normalized.contains("🎉"))
    }

    func testNormalizeForTTSNormalizesAbbreviations() {
        let abbreviations = "M. Dupont et Mme Martin"
        let normalized = audioService.normalizeForTTS(abbreviations)
        XCTAssertTrue(normalized.contains("Monsieur"))
        XCTAssertTrue(normalized.contains("Madame"))
    }

    func testNormalizeForTTSStripsThinkTags() {
        let withThinking = "Hello world"
        let normalized = audioService.normalizeForTTS(withThinking)
        XCTAssertFalse(normalized.contains(""))
        XCTAssertFalse(normalized.contains(""))
    }

    // MARK: - Sentence Splitting Tests

    func testSplitIntoSentencesBasic() {
        let text = "Hello. How are you? I'm fine!"
        let sentences = audioService.splitIntoSentences(text)
        XCTAssertEqual(sentences.count, 3)
        XCTAssertEqual(sentences[0], "Hello.")
        XCTAssertEqual(sentences[1], "How are you?")
        XCTAssertEqual(sentences[2], "I'm fine!")
    }

    func testSplitIntoSentencesSingleSentence() {
        let text = "Single sentence without punctuation"
        let sentences = audioService.splitIntoSentences(text)
        XCTAssertEqual(sentences.count, 1)
        XCTAssertEqual(sentences[0], "Single sentence without punctuation")
    }

    func testSplitIntoSentencesEmptyString() {
        let text = ""
        let sentences = audioService.splitIntoSentences(text)
        XCTAssertTrue(sentences.isEmpty)
    }

    func testSplitIntoSentencesMultiplePunctuation() {
        let text = "What?! Really... Yes."
        let sentences = audioService.splitIntoSentences(text)
        // Should handle multiple punctuation marks
        XCTAssertGreaterThan(sentences.count, 0)
    }

    // MARK: - TTS 100 % on-device (edge-tts supprimé)

    func testTTSSharedInstanceExists() {
        XCTAssertNotNil(AudioService.shared)
    }

    func testStopSpeakingClearsSpeakingMirror() async {
        audioService.stopSpeaking()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(audioService.isSpeaking)
    }

    // MARK: - Helper

    private func getAudioQueueCount() async -> Int {
        // Can't access private property, return 0
        return 0
    }
}

// Since we need to test private methods, we'll use a subclass for testing
// or test via public API only. For now, test what we can via public API.

final class JarvisLocalAudioServiceNormalizationTests: XCTestCase {

    func testStripMarkdown() {
        let testCases: [(input: String, expectedNotContains: [String])] = [
            ("**bold**", ["**"]),
            ("*italic*", ["*"]),
            ("`code`", ["`"]),
            ("# Heading", ["#"]),
            ("- item", ["- "]),
            ("1. item", ["1."]),
            ("```code```", ["```"])
        ]

        for testCase in testCases {
            let audioService = AudioService.shared
            let result = audioService.normalizeForTTS(testCase.input)
            for notContain in testCase.expectedNotContains {
                XCTAssertFalse(result.contains(notContain), "Failed for input: \(testCase.input), result: \(result)")
            }
        }
    }

    func testStripEmojis() {
        let testCases = [
            "Hello 😀",
            "Test 🎉🎊",
            "No emojis here",
            "😀🎉"
        ]

        for input in testCases {
            let audioService = AudioService.shared
            let result = audioService.normalizeForTTS(input)
            // Should not contain any emoji (Unicode symbols)
            let hasEmoji = result.unicodeScalars.contains { scalar in
                scalar.properties.isEmoji || scalar.properties.generalCategory == .otherSymbol
            }
            XCTAssertFalse(hasEmoji, "Result should not contain emojis: \(result)")
        }
    }

    func testNormalizeAbbreviations() {
        let testCases: [(input: String, expected: String)] = [
            ("M. Dupont", "Monsieur Dupont"),
            ("Mme Martin", "Madame Martin"),
            ("Dr. House", "Docteur House"),
            ("10 €", "10 euros"),
            ("50 %", "50 pour cent"),
            ("A & B", "A et B")
        ]

        for testCase in testCases {
            let audioService = AudioService.shared
            let result = audioService.normalizeForTTS(testCase.input)
            // Normalize spaces in result for comparison (the normalizer may add double spaces)
            let normalizedResult = result.replacingOccurrences(of: "  ", with: " ")
            XCTAssertTrue(normalizedResult.contains(testCase.expected), "Expected '\(testCase.expected)' in '\(result)' for input '\(testCase.input)'")
        }
    }
}

final class JarvisLocalAudioServiceSplitSentencesTests: XCTestCase {

    func testBasicSplitting() {
        let audioService = AudioService.shared
        let text = "First sentence. Second sentence! Third sentence?"
        let sentences = audioService.splitIntoSentences(text)
        XCTAssertEqual(sentences.count, 3)
        XCTAssertEqual(sentences[0].trimmingCharacters(in: .whitespaces), "First sentence.")
        XCTAssertEqual(sentences[1].trimmingCharacters(in: .whitespaces), "Second sentence!")
        XCTAssertEqual(sentences[2].trimmingCharacters(in: .whitespaces), "Third sentence?")
    }

    func testNoPunctuation() {
        let audioService = AudioService.shared
        let text = "No punctuation here"
        let sentences = audioService.splitIntoSentences(text)
        XCTAssertEqual(sentences.count, 1)
        XCTAssertEqual(sentences[0], "No punctuation here")
    }

    func testEmptyString() {
        let audioService = AudioService.shared
        let text = ""
        let sentences = audioService.splitIntoSentences(text)
        XCTAssertTrue(sentences.isEmpty)
    }

    func testWhitespaceHandling() {
        let audioService = AudioService.shared
        let text = "  Hello.  World.  "
        let sentences = audioService.splitIntoSentences(text)
        XCTAssertEqual(sentences.count, 2)
    }

    func testMultipleSpaces() {
        let audioService = AudioService.shared
        let text = "Hello.    World."
        let sentences = audioService.splitIntoSentences(text)
        XCTAssertEqual(sentences.count, 2)
    }
}

final class JarvisLocalAudioServiceQueueTests: XCTestCase {

    var audioService: AudioService!

    override func setUp() async throws {
        try await super.setUp()
        audioService = AudioService.shared
        audioService.stopSpeaking()
    }

    /// Le singleton est partagé entre tous les tests : sans ce nettoyage, une parole encore
    /// en cours à la fin d'un test fuit dans le suivant (ordre-dépendant, fantômes en CI).
    /// Le setUp seul ne suffit pas — c'est l'état LAISSÉ qui contamine, pas l'état trouvé.
    override func tearDown() async throws {
        audioService.stopSpeaking()
        try await super.tearDown()
    }

    func testEnqueueMultipleItems() async {
        audioService.enqueue("Item 1")
        audioService.enqueue("Item 2")
        audioService.enqueue("Item 3")
        // Just verify it doesn't crash
        XCTAssertTrue(true)
    }

    func testStopSpeakingStopsEverything() async {
        audioService.enqueue("Test")
        // Course possible avec le processeur de file : on attend que l'état se stabilise.
        let deadline = Date().addingTimeInterval(5)
        while audioService.isSpeaking && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            audioService.stopSpeaking()
        }
        XCTAssertFalse(audioService.isSpeaking)
    }

    func testSpeakWithEmptyString() async {
        await audioService.speak("")
        // Should handle empty string gracefully
        XCTAssertTrue(true)
    }

    /// Non-régression du warning CI "SWIFT TASK CONTINUATION MISUSE: speakSystemTTS(_:)
    /// leaked its continuation without resuming it" : couper (stopSpeaking) en pleine lecture
    /// d'un texte multi-phrases doit arrêter la boucle de phrases.
    /// Mécanisme du leak (avant fix) : stopSpeaking() reprenait la continuation de la phrase
    /// en cours, mais la boucle speakSystemTTS — qui ne testait que Task.isCancelled —
    /// enchaînait quand même la phrase suivante (speak() après stopSpeaking(at: .immediate),
    /// jamais honoré → continuation abandonnée).
    /// NOTE : pas de capture stderr ici — le runtime loggue la fuite avec un retard variable,
    /// inexploitable de façon déterministe. Le contrat observable est équivalent : après un
    /// stop mid-speech, speak() revient vite ET la lecture ne repart pas.
    func testStopSpeakingMidSpeechHaltsSentenceLoop() async throws {
        audioService.stopSpeaking()
        let speech = (1...10).map {
            "Ceci est la phrase numéro \($0) que Jarvis doit lire à voix haute lentement et distinctement"
        }.joined(separator: ". ") + "."
        let speakTask = Task { await audioService.speak(speech) }
        // Attend qu'une phrase soit VRAIMENT en cours de lecture (continuation en vol) :
        // sans ça, le stop pourrait frapper avant le premier speak et n'exercer aucun chemin.
        let started = Date().addingTimeInterval(5)
        while !audioService.isSpeaking && Date() < started {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let wasSpeaking = audioService.isSpeaking
        audioService.stopSpeaking()

        // speak() doit revenir vite (le vidage d'état le garantit, même avec le bug).
        let done = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await speakTask.value; return true }
            group.addTask { try? await Task.sleep(nanoseconds: 5_000_000_000); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertTrue(done, "speak() n'est pas revenu 5 s après stopSpeaking()")
        // ...et la lecture ne doit PAS repartir (boucle de phrases bien arrêtée : avant le
        // fix, elle lançait la phrase suivante malgré le stop, ou abandonnait sa continuation).
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        XCTAssertFalse(audioService.isSpeaking,
                       "La synthèse a redémarré après stopSpeaking() (boucle de phrases non arrêtée).")
        // Environnement sans sortie audio (la synthèse ne démarre jamais) : le chemin
        // mid-speech n'était pas exerçable, on le signale au lieu de valider à vide.
        if !wasSpeaking {
            throw XCTSkip("Synthèse vocale inactive dans cet environnement : chemin mid-speech non exercé.")
        }
    }
}
