import Foundation
@preconcurrency import AVFoundation
import Speech
import os

/// Voix système 100 % on-device (AVSpeechSynthesizer + voix FR Enhanced/Premium
/// téléchargeables depuis Réglages Système). Le fallback cloud edge-tts (process Python
/// + réseau Microsoft) a été supprimé : latence, dépendance externe et exfiltration
/// du texte lu vers un tiers pour un gain de naturalité qui ne justifie pas le coût.
final class AudioService: NSObject {
    static let shared = AudioService()

    private let log = Logger(subsystem: "com.dimitriclaverie.JarvisLocal", category: "tts")

    // AVSpeechSynthesizer est main-thread-only : tout accès (speak/stop/isSpeaking)
    // passe par MainActor (speakSystemTTS) ou par un Task @MainActor (stopSpeaking).
    // Le flag miroir _isSpeaking, lui, est lisible depuis n'importe quel thread sous
    // ttsStateLock — c'est lui que consultent speak() et isSpeaking, jamais le synthé.
    private let synthesizer = AVSpeechSynthesizer()
    private var speechContinuation: CheckedContinuation<Void, Never>?

    // État TTS partagé entre la boucle de lecture (Task héritant d'un contexte quelconque),
    // stopSpeaking()/enqueue()/speak() (MainActor, tests) et les delegates audio (hop MainActor) :
    // TOUJOURS manipulé sous ttsStateLock, jamais hors-verrou. Le verrou n'est jamais tenu
    // pendant un await (sections synchrones uniquement) et les continuations sont toujours
    // reprises HORS verrou (le code réveillé reverrouille — NSLock non réentrant).
    // Deux pièces complémentaires contre le leak "leaked its continuation" :
    // - stopRequested : signal "stop demandé", remis à false par chaque enqueue (une nouvelle
    //   parole annule le stop). Sortie immédiate de la boucle de phrases, sans attendre.
    // - speechGeneration : "époque" incrémentée à chaque stop. Une boucle ne crée des
    //   continuations que si sa génération est toujours courante. Combiné au démarrage
    //   atomique (une seule boucle vivante à la fois), UN SEUL créateur existe à tout
    //   instant → le slot partagé speechContinuation ne peut jamais être écrasé avec une
    //   continuation en vol, et stopSpeaking reprend toujours LA continuation en cours.
    //   (Constat CI : deux boucles concurrentes — item résiduel d'un tour précédent + item
    //   courant — partageaient le slot ; le stop ne reprenait que l'une des deux.)
    // NOTE : audioQueue est sous le même verrou pour fermer aussi le crash latent
    // removeFirst-sur-file-vide (stop vidait la file pendant que la boucle dépilait).
    private let ttsStateLock = NSLock()
    private var _audioQueue: [String] = []
    private var _isProcessingQueue = false
    private var _stopRequested = false
    private var _speechGeneration = 0
    /// Miroir de `synthesizer.isSpeaking` lisible hors main thread (voir le commentaire
    /// sur `synthesizer`). Mis à true avant chaque speak, à false par les delegates
    /// didFinish/didCancel et par stopSpeaking — toujours sous ttsStateLock.
    private var _isSpeaking = false

    /// Helpers verrouillés (sections synchrones, jamais d'await sous verrou).
    /// Règle : les `_vars` bruts ne sont touchés QUE dans ces helpers ou dans des blocs
    /// ttsStateLock explicites — jamais directement depuis le reste de la classe.
    /// Plafonds file TTS : sur une très longue réponse streamée, les phrases sont
    /// enfilées plus vite que le synthé ne les lit. Sans borne, la file (Strings
    /// + utterances) grossit sans limite si l'utilisateur ne coupe jamais le son.
    static let maxTTSQueueItems = 50
    static let maxTTSQueueChars = 20_000

    private func ttsQueueAppend(_ text: String) {
        ttsStateLock.lock(); defer { ttsStateLock.unlock() }
        _stopRequested = false // une nouvelle parole annule l'état "stop"
        _audioQueue.append(text)
        // Dégrade gracieusement : on jette les plus anciennes (déjà dépassées par
        // le streaming) plutôt que de laisser la file diverger en mémoire.
        while _audioQueue.count > Self.maxTTSQueueItems
                || _audioQueue.reduce(0, { $0 + $1.count }) > Self.maxTTSQueueChars {
            _audioQueue.removeFirst()
        }
    }
    private func ttsQueueIsEmpty() -> Bool {
        ttsStateLock.lock(); defer { ttsStateLock.unlock() }
        return _audioQueue.isEmpty
    }
    private func ttsQueuePop() -> String? {
        ttsStateLock.lock(); defer { ttsStateLock.unlock() }
        return _audioQueue.isEmpty ? nil : _audioQueue.removeFirst()
    }
    private func ttsQueueCount() -> Int {
        ttsStateLock.lock(); defer { ttsStateLock.unlock() }
        return _audioQueue.count
    }
    private func ttsIsProcessing() -> Bool {
        ttsStateLock.lock(); defer { ttsStateLock.unlock() }
        return _isProcessingQueue
    }
    private func ttsStopRequested() -> Bool {
        ttsStateLock.lock(); defer { ttsStateLock.unlock() }
        return _stopRequested
    }
    private func ttsIsCurrentGeneration(_ gen: Int) -> Bool {
        ttsStateLock.lock(); defer { ttsStateLock.unlock() }
        return gen == _speechGeneration
    }
    /// Lecture du miroir de parole (jamais `synthesizer.isSpeaking` hors main thread).
    private func ttsIsSpeaking() -> Bool {
        ttsStateLock.lock(); defer { ttsStateLock.unlock() }
        return _isSpeaking || !_audioQueue.isEmpty
    }
    /// Marque le début/fin de parole. Appelé sous verrou par speakSystemTTS (true),
    /// les delegates didFinish/didCancel et stopSpeaking (false).
    private func ttsSetSpeaking(_ value: Bool) {
        ttsStateLock.lock(); defer { ttsStateLock.unlock() }
        _isSpeaking = value
    }
    /// Prend la continuation en cours (take-and-clear) : garantit une reprise UNIQUE même
    /// si stopSpeaking() et un callback delegate se croisent. Reprendre HORS verrou.
    private func ttsTakeSpeechContinuation() -> CheckedContinuation<Void, Never>? {
        ttsStateLock.lock(); defer { ttsStateLock.unlock() }
        let c = speechContinuation
        speechContinuation = nil
        return c
    }
    /// Sortie de boucle processeur : efface le flag "vivant" et dit s'il reste du travail
    /// à confier à une boucle de génération courante (relauch, voir processAudioQueue).
    /// Helper synchrone dédié car NSLock.lock/unlock est interdit textuellement dans un
    /// contexte async (warning Swift 6) — le defer de processAudioQueue l'appelle.
    private func ttsFinishProcessorPass() -> Bool {
        ttsStateLock.lock(); defer { ttsStateLock.unlock() }
        _isProcessingQueue = false
        return !_audioQueue.isEmpty
    }

    private override init() {
        super.init()
        synthesizer.delegate = self
        log.info("TTS 100 % on-device (AVSpeechSynthesizer)")
    }

    // MARK: - TTS Routing

    /// Ajoute du texte à la file SANS attendre la fin de lecture. Utilisé par le mode
    /// streaming : les phrases sont poussées au fil de l'arrivée des tokens et jouées
    /// à la suite, pour que la voix démarre dès la première phrase complète.
    func enqueue(_ text: String) {
        let clean = normalizeForTTS(text)
        guard !clean.isEmpty else { return }
        // ttsQueueAppend remet aussi stopRequested à false : sans ça, un stop suivi d'un
        // enqueue rejouerait... rien (la boucle sortirait aussitôt sur le flag encore levé).
        ttsQueueAppend(clean)
        startQueueProcessorIfNeeded()
    }

    /// Enqueue puis attend que toute la file ait été lue. Comportement historique
    /// de speak(), utilisé quand l'appelant doit synchroniser sur la fin du TTS
    /// (annonces de confirmation, fin de tour en mode vocal).
    /// Activité déclarée (`idleSystemSleepDisabled`) : sans elle, le Mac peut
    /// s'endormir en pleine lecture et couper la voix au milieu d'une phrase.
    func speak(_ text: String) async {
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Lecture synthèse vocale Jarvis"
        )
        defer { ProcessInfo.processInfo.endActivity(activity) }
        enqueue(text)
        while ttsIsProcessing() || ttsIsSpeaking() {
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
    }

    private func startQueueProcessorIfNeeded() {
        // Démarrage atomique sous verrou : deux enqueue concurrents ne doivent jamais
        // lancer deux boucles (deux créateurs de continuations sur le même slot = leak).
        // La génération capturée ici est la "carte d'identité" de cette boucle.
        ttsStateLock.lock()
        guard !_isProcessingQueue else { ttsStateLock.unlock(); return }
        _isProcessingQueue = true
        let gen = _speechGeneration
        ttsStateLock.unlock()
        Task { [weak self] in
            await self?.processAudioQueue(generation: gen)
        }
    }

    private func processAudioQueue(generation gen: Int) async {
        defer {
            // Fin de boucle : file vide OU boucle périmée par un stop ultérieur. S'il reste
            // du travail, une boucle de génération courante doit prendre le relais — sinon
            // une parole enfilée pendant la fenêtre de sortie resterait sans lecteur
            // (cas réel : enqueue arrivé entre le réveil d'une boucle périmée et sa sortie,
            // avec isProcessingQueue encore à true → aucun redémarrage).
            if ttsFinishProcessorPass() { startQueueProcessorIfNeeded() }
        }
        while !ttsQueueIsEmpty() {
            // Boucle périmée par un stop ultérieur : on sort SANS dépiler ni créer de
            // continuation (le relaunch du defer confie la suite à une boucle courante).
            guard ttsIsCurrentGeneration(gen) else { break }
            guard let text = ttsQueuePop() else { break }
            await speakSystemTTS(text, generation: gen)
        }
    }

    // MARK: - System TTS (AVSpeechSynthesizer)

    private var selectedVoice: AVSpeechSynthesisVoice? {
        Settings.shared.selectedVoice
    }

    /// Lit un item de la file phrase par phrase. `generation` est la carte d'identité de la
    /// boucle processeur appelante.
    /// Protocole anti-leak, vérifié à CHAQUE itération AVANT toute création de continuation :
    /// Task non annulé + pas de stop demandé + génération toujours courante. L'enregistrement
    /// dans le slot partagé est atomique avec ce test (même verrou que le bump de génération
    /// de stopSpeaking) : soit le stop nous voit et reprend cette continuation, soit on se
    /// voit périmé avant de la créer — jamais de continuation créée après un stop sans reprise.
    /// Et si un stop passe entre l'enregistrement et le speak(), le test post-speak coupe le
    /// synthé aussitôt : le didCancel/didFinish qui suit reprend NOTRE continuation (toujours
    /// dans le slot — créateur unique). Sans ça, un speak() ignoré par le synthé après un stop
    /// laissait la continuation en vol (le warning CI).
    /// Le synthé (main-thread-only) n'est touché que via MainActor ; l'état observable
    /// (`_isSpeaking`) est maintenu sous ttsStateLock.
    private func speakSystemTTS(_ text: String, generation gen: Int? = nil) async {
        let voice = selectedVoice
        let baseRate: Float

        if voice?.quality == .enhanced || (voice?.identifier.contains("premium") ?? false) {
            baseRate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        } else {
            baseRate = AVSpeechUtteranceDefaultSpeechRate * 0.98
        }

        let sentences = splitIntoSentences(text)
        for (i, sentence) in sentences.enumerated() {
            guard !Task.isCancelled, !ttsStopRequested(), gen.map(ttsIsCurrentGeneration) ?? true else { break }

            let utterance = AVSpeechUtterance(string: sentence)
            utterance.voice = voice
            utterance.rate = baseRate

            let isQuestion = sentence.hasSuffix("?")
            utterance.pitchMultiplier = isQuestion ? 1.15 : (i % 2 == 0 ? 1.0 : 0.95)

            utterance.preUtteranceDelay = i == 0 ? 0 : 0.15

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // Enregistrement atomique : si un stop nous a périmés entre la gate et ici,
                // on reprend aussitôt cette continuation (créée pour rien) au lieu de parler
                // — retourner du body sans reprise = leak, d'où le resume explicite.
                // (Reprendre une continuation de façon synchrone dans le body est légal :
                // l'await se termine alors immédiatement.)
                ttsStateLock.lock()
                let fresh = gen.map { $0 == _speechGeneration } ?? true
                    && !_stopRequested
                if fresh { speechContinuation = continuation; _isSpeaking = true }
                ttsStateLock.unlock()
                guard fresh else {
                    continuation.resume()
                    return
                }
                // AVSpeechSynthesizer est main-thread-only : hop explicite, jamais
                // d'accès direct depuis la boucle processeur (thread de fond). Le body
                // de continuation est synchrone : fire-and-forget sérialisés dans
                // l'ordre par le MainActor (speak puis éventuel stop).
                Task { @MainActor [weak self] in self?.synthesizer.speak(utterance) }
                // Un stop a pu passer entre l'enregistrement et le speak : cette phrase est
                // déjà périmée, on coupe le synthé pour que le callback qui suit (didCancel
                // ou didFinish) reprenne cette continuation au lieu de l'abandonner.
                if ttsStopRequested() || gen.map({ !ttsIsCurrentGeneration($0) }) ?? false {
                    Task { @MainActor [weak self] in self?.synthesizer.stopSpeaking(at: .immediate) }
                }
            }
        }
    }

    func stopSpeaking() {
        // Bump de génération + reprise du slot SOUS LE MÊME verrou que l'enregistrement des
        // créateurs (ordre total) : soit ce stop voit la continuation en cours et la reprend,
        // soit le créateur concurrent se voit périmé avant de la créer — jamais de
        // continuation créée après un stop sans reprise. Reprise HORS verrou (le code
        // réveillé reverrouille). NOTE : isProcessingQueue n'est VOLONTAIREMENT plus remis
        // à false ici (voir sa déclaration) : seule la boucle elle-même constate sa sortie,
        // sinon un enqueue suivant démarre une deuxième boucle concurrente (le leak CI).
        // Le synthé (main-thread-only) est coupé via un Task @MainActor : stopSpeaking()
        // reste synchrone et ne bloque jamais l'appelant.
        ttsStateLock.lock()
        _stopRequested = true
        _speechGeneration += 1
        _audioQueue.removeAll()
        _isSpeaking = false
        let c = speechContinuation
        speechContinuation = nil
        ttsStateLock.unlock()
        Task { @MainActor [weak self] in self?.synthesizer.stopSpeaking(at: .immediate) }
        if let c { c.resume() }
    }

    /// Miroir verrouillé, jamais `synthesizer.isSpeaking` (main-thread-only).
    var isSpeaking: Bool { ttsIsSpeaking() }

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
            ( "\\n{3,}", "\n\n" )
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
            ( "/", " sur " )
        ]
        for (pattern, replacement) in replacements {
            t = t.replacingOccurrences(of: pattern, with: replacement, options: [.regularExpression, .caseInsensitive])
        }
        return t
    }
}

extension AudioService: AVSpeechSynthesizerDelegate {
    // Les delegates AVSpeechSynthesizer sont appelés depuis un thread arbitraire
    // (queue interne du framework audio). On dispatch sur MainActor (comportement
    // historique), et le take-and-clear se fait sous le même verrou que le grab de
    // stopSpeaking : une continuation n'est reprise qu'UNE fois même si les deux se
    // croisent (un 2e resume trap). Reprise hors verrou.
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.ttsSetSpeaking(false)
            if let c = self.ttsTakeSpeechContinuation() {
                c.resume()
            }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.ttsSetSpeaking(false)
            if let c = self.ttsTakeSpeechContinuation() {
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
    /// Garde-fou absolu : SFSpeechAudioBufferRecognitionRequest bufferise TOUT
    /// l'audio jusqu'à endAudio(). Sans parole continue (bruit de fond, TV),
    /// le détecteur de silence ne se déclenche jamais et la requête grossit sans
    /// limite (Go en session prolongée). Ce timer force une fin après 120s.
    private var maxDurationTimer: DispatchSourceTimer?
    static let maxRecordingDuration: TimeInterval = 120
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
        scheduleMaxDurationTimerLocked()
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

    /// Borne absolue de la prise (voir maxDurationTimer) : force endAudio() pour
    /// vider le buffer Speech même en parole/bruit continu. Le résultat final
    /// arrive alors via handleRecognitionEventLocked comme une fin normale.
    private func scheduleMaxDurationTimerLocked() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        maxDurationTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + Self.maxRecordingDuration, repeating: .never)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.isRecording else { return }
            self.recognitionRequest?.endAudio()
        }
        timer.activate()
        maxDurationTimer = timer
    }

    private func stopRecordingLocked() {
        dispatchPrecondition(condition: .onQueue(stateQueue))
        isRecording = false
        silenceTimer?.cancel()
        silenceTimer = nil
        maxDurationTimer?.cancel()
        maxDurationTimer = nil
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
