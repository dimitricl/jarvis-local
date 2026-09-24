import Foundation
import Observation
import AppKit // NSApp.isActive (notification seulement si l'app est en arrière-plan)
import UserNotifications
import JarvisCore

@MainActor
@Observable
public final class AppViewModel {
    var conversations: [Conversation] = []
    var currentConversation: Conversation?
    var messages: [Message] = []
    var streamingText = ""
    var isStreaming = false
    var isToolRunning = false
    var currentToolName = ""
    /// Trace des outils appelés pendant le tour en cours, affichée dans le chat :
    /// "get_weather ✓" / "add_reminder ✗". Rend le tool calling observable au lieu d'un
    /// trou noir entre la question et la réponse.
    struct ToolTraceEntry: Identifiable, Equatable {
        let id = UUID()
        let name: String
        var status: String // "…", "✓", "✗"
    }
    var toolTrace: [ToolTraceEntry] = []
    var errorMessage: String?
    var facts: [Fact] = []
    /// Coordinateur d'extraction (étape 1 du découpage). Optionnel stocké
    /// (pas `lazy` : incompatible avec la macro @Observable) construit à la demande.
    private var _factsCoordinator: FactsExtractionCoordinator?
    private var factsCoordinator: FactsExtractionCoordinator {
        if let c = _factsCoordinator { return c }
        let c = FactsExtractionCoordinator(
            db: db,
            requestConfirmation: { [weak self] summary in
                guard let self else { return false }
                return await self.requestFactsConfirmation(summary: summary)
            },
            announceVoice: { [weak self] in
                guard let self, self.isVoiceMode else { return }
                await self.audio.speak("J'ai repéré une information à mémoriser, confirmation à l'écran.")
            },
            didUpdateFacts: { [weak self] updated in
                self?.facts = updated
            },
            reportError: { [weak self] msg in
                self?.errorMessage = msg
            }
        )
        _factsCoordinator = c
        return c
    }
    /// Orchestrateur de tour (étape 3 du découpage). Même pattern que ci-dessus.
    /// `internal` pour les tests (vérifient le câblage via des tours sur fakes).
    var _turnRunner: ConversationTurnRunner?
    var turnRunner: ConversationTurnRunner {
        if let r = _turnRunner { return r }
        let r = ConversationTurnRunner(
            db: db,
            llm: ollama,
            tools: tools,
            settings: settings,
            facts: factsCoordinator,
            sensitiveTools: sensitiveTools,
            cb: TurnCallbacks(
                appendTrace: { [weak self] name in
                    guard let self else { return }
                    self.isToolRunning = true
                    self.currentToolName = name
                    self.toolTrace.append(ToolTraceEntry(name: name, status: "…"))
                },
                markTrace: { [weak self] status in self?.markLastToolTrace(status) },
                requestConfirmation: { [weak self] tool, args in
                    guard let self else { return false }
                    return await self.requestConfirmation(tool: tool, args: args)
                },
                speak: { [weak self] text in
                    guard let self else { return }
                    await self.audio.speak(text)
                },
                notifyFinished: { [weak self] startedAt in
                    self?.notifyTurnFinishedIfBackground(startedAt: startedAt)
                },
                auditTool: { [weak self] cid, tool, args, status, result in
                    guard let self else { return }
                    await self.auditTool(conversationId: cid, tool: tool, args: args, status: status, result: result)
                }
            ),
            ui: TurnUI(
                ensureDBOpen: { [weak self] in await self?.ensureDBOpen() },
                ensureConversationId: { [weak self] in
                    guard let self else { return nil }
                    if self.currentConversation == nil {
                        await self.newConversation()
                    }
                    return self.currentConversation?.id
                },
                appendMessage: { [weak self] msg in self?.messages.append(msg) },
                setStreaming: { [weak self] active in self?.isStreaming = active },
                setStreamingText: { [weak self] text in self?.streamingText = text },
                resetTrace: { [weak self] in self?.toolTrace = [] },
                reportError: { [weak self] msg in self?.errorMessage = msg },
                setSpeaking: { [weak self] active in self?.isSpeaking = active },
                noteSpeechStarted: { [weak self] in self?.speechStartedAt = ContinuousClock.now },
                enqueueSentence: { [weak self] sentence in self?.audio.enqueue(sentence) },
                setFacts: { [weak self] updated in self?.facts = updated }
            )
        )
        _turnRunner = r
        return r
    }
    var showFacts = false
    var showSettings = false
    /// Aide contextuelle des commandes slash, affichée via /help.
    var showHelp = false
    /// Panneau de recherche dans toutes les conversations.
    var showSearch = false
    var searchQuery = ""
    var inputText = ""
    /// Exposées publiquement : lues par l'exécutable (composition root, barre de menu).
    public var isVoiceMode = false
    var isListening = false
    var isSpeaking = false
    /// Horodatage du début du TTS courant. Sert de fenêtre de grâce pour le barge-in : le tout
    /// début d'une phrase est le moment où un écho acoustique mal annulé a le plus de chances de se
    /// faire passer pour de la parole utilisateur (attaque/relâche du haut-parleur). On ignore les
    /// déclencheurs de barge-in dans les ~600ms qui suivent.
    private var speechStartedAt: ContinuousClock.Instant?
    /// Nombre de résultats partiels consécutifs non-vides reçus pendant que Jarvis parle. On exige
    /// 2 occurrences avant de couper le TTS, pour ne pas réagir à un unique artefact ponctuel
    /// (souffle, écho d'un seul mot) — un vrai barge-in humain produit plusieurs partials de suite.
    private var bargeInStreak = 0
    var confirmationRequest: ToolConfirmationRequest?

    // Dépendances injectées, typées par les protocols JarvisCore — jamais par les
    // types concrets de JarvisServices. En production, le câblage vers les singletons
    // passe par ServiceHosts (JarvisServices) dans l'exécutable (composition root) ;
    // en tests, par AppViewModelTestSupport ou des fakes.
    // NOTE : `internal` pour les tests — permet d'inspecter l'état interne sans
    // casser l'encapsulation en prod.
    let db: any PersistentStore
    let ollama: any LLMProvider
    let tools: any ToolExecutor
    let audio: any TTSEngine
    let stt: any STTEngine
    let settings: any AppSettingsProtocol
    /// Socle jobs d'arrière-plan (itération agents) : typé par le protocol Core,
    /// jamais par le concret de JarvisServices (frontière L2, voir ModuleBoundaryTests).
    /// Optionnel + défaut nil : les call-sites historiques (6 args) continuent
    /// de compiler, seule la composition root injecte le vrai registre.
    let jobsRegistry: (any BackgroundJobRegistry)?

    /// Miroir observable des jobs (actifs + récents), alimenté par le flux du
    /// registre. L'UI lit ÇA, jamais l'actor directement.
    var jobs: [JobRecord] = []
    private var jobsObservationTask: Task<Void, Never>?

    public init(
        db: any PersistentStore,
        ollama: any LLMProvider,
        tools: any ToolExecutor,
        audio: any TTSEngine,
        stt: any STTEngine,
        settings: any AppSettingsProtocol,
        jobsRegistry: (any BackgroundJobRegistry)? = nil
    ) {
        self.db = db
        self.ollama = ollama
        self.tools = tools
        self.audio = audio
        self.stt = stt
        self.settings = settings
        self.jobsRegistry = jobsRegistry
        // Démarrage auto si un registre est injecté : la composition root n'a
        // rien d'autre à appeler. Méthode idempotente (garde sur la Task).
        startObservingJobs()
    }

    // MARK: - Background jobs (socle agents, itération suivante : brancher les tool calls)

    /// Borne du miroir UI : on garde les actifs + un historique récent, pas
    /// tout depuis le lancement (le registre, lui, borne à 100).
    static let maxMirroredJobs = 50

    /// Souscrit au flux du registre et maintient `jobs` à jour. Idempotente.
    /// POURQUOI une Task stockée plutôt qu'un .task SwiftUI : l'abonnement vit
    /// aussi longtemps que le ViewModel (pas que la vue), survit aux
    /// recompositions, et se coupe proprement via stopObservingJobs().
    /// La boucle fait `for await` (suspension, JAMAIS de blocage du main thread :
    /// chaque réveil ne fait qu'un upsert synchrone) et ne duplique AUCUNE
    /// logique de concurrence — l'actor reste seul ordonnanceur, ici on miroite.
    func startObservingJobs() {
        guard jobsObservationTask == nil, let registry = jobsRegistry else { return }
        jobsObservationTask = Task { [weak self] in
            // Photo initiale : l'UI affiche l'existant sans attendre la
            // première transition (un job fini avant l'abonnement sinon invisible).
            let initial = await registry.snapshot()
            guard let strongSelf = self else { return }
            strongSelf.jobs = Array(initial.suffix(Self.maxMirroredJobs))
            for await record in await registry.updates() {
                // Garde exigée EN PLUS du guard let self en tête de Task : cancel()
                // fait sortir next() (nil) quand la boucle est suspendue sans élément
                // en vol, MAIS un élément déjà en buffer au moment du cancel réveille
                // quand même la boucle — sans ce garde, la transition serait appliquée
                // malgré stopObservingJobs() (fuite d'observation). Ici on sort sans
                // appliquer ; la sortie libère l'itérateur et le onTermination côté
                // registre retire l'abonnement.
                guard !Task.isCancelled else { break }
                guard let strongSelf = self else { return }
                strongSelf.applyJobUpdate(record)
            }
        }
    }

    /// NOTE : `internal` pour les tests.
    func stopObservingJobs() {
        jobsObservationTask?.cancel()
        jobsObservationTask = nil
    }

    /// Upsert synchrone MainActor (le ViewModel est @MainActor) : remplace le
    /// record du même id ou l'ajoute, trié par création, historique borné.
    /// Fonction de pure miroiterie — aucune décision de concurrence ici.
    /// NOTE : `internal` pour les tests.
    func applyJobUpdate(_ record: JobRecord) {
        if let idx = jobs.firstIndex(where: { $0.id == record.id }) {
            jobs[idx] = record
        } else {
            jobs.append(record)
        }
        jobs.sort { $0.createdAt < $1.createdAt }
        if jobs.count > Self.maxMirroredJobs {
            jobs = Array(jobs.suffix(Self.maxMirroredJobs))
        }
    }

    /// Passthrough fin : un futur appelant (itération "un tool call devient un
    /// job") n'aura qu'à fournir le `work`. Retourne nil sans registre (tests
    /// sans injection) au lieu de crasher.
    func enqueueJob(
        title: String,
        timeout: TimeInterval? = nil,
        work: @escaping @Sendable () async throws -> String
    ) async -> JobID? {
        guard let registry = jobsRegistry else { return nil }
        return await registry.enqueue(title: title, timeout: timeout, work: work)
    }

    /// Annulation non-bloquante : on délègue à l'actor et on rend la main
    /// aussitôt, le nouveau statut arrivera via le flux (pas d'attente ici).
    func cancelJob(_ id: JobID) {
        guard let registry = jobsRegistry else { return }
        Task { await registry.cancel(id) }
    }

    /// Nom du modèle courant, exposé aux vues (badge ChatView) sans leur donner Settings.
    var modelName: String { settings.model }
    /// Marque la DB comme déjà ouverte. Internal pour les tests : après injection d'une
    /// DB :memory:, il faut empêcher ensureDBOpen() de rouvrir la base fichier par défaut.
    var didOpenDB = false

    /// Tools qui modifient l'état réel (système, messages, notes, automatisations) et qui doivent
    /// être confirmés avant exécution, car un petit modèle local peut halluciner un appel non désiré
    /// — ou être manipulé par une injection indirecte cachée dans un résultat de search_web.
    /// run_shortcut est inclus : un Raccourci macOS peut chaîner des actions arbitraires
    /// (exécution shell, réseau, contrôle d'autres apps) au même titre qu'un AppleScript.
    /// take_screenshot aussi : une capture lit TOUT l'écran (onglets bancaires, messages privés,
    /// mots de passe affichés) et écrit un fichier PNG qu'elle ouvre aussitôt — effet sensible
    /// au même titre que set_clipboard, qui expose lui aussi du contenu potentiellement privé.
    /// create_note/open_app/get_clipboard sont sensibles : écrire sans validation, ouvrir une
    /// URL/app arbitraire (phishing, file://) ou lire le presse-papiers (mots de passe) ne sont
    /// pas des lectures anodines. L'outil générique `applescript` n'existe plus (supprimé :
    /// RCE triviale par concaténation — voir SystemTools) ; les templates internes figés
    /// (Messages, Notes, Plans) restent couverts via leurs outils dédiés ci-dessous.
    /// NOTE : visibilité `internal` (pas `private`) volontaire — c'est la seule façon pour les tests
    /// de lire la VRAIE liste via @testable import au lieu d'en recopier une à la main qui finit
    /// forcément par diverger du code réel sans jamais faire échouer aucun test.
    let sensitiveTools: Set<String> = ["sleep_mac", "send_message", "create_note", "open_app", "get_clipboard", "edit_note", "run_shortcut", "remember_fact", "search_maps", "add_calendar_event", "add_reminder", "set_clipboard", "take_screenshot", "complete_reminder", "delete_reminder", "edit_calendar_event", "delete_calendar_event"]

    /// Résout la clé de confirmation d'un outil : le nom lui-même s'il est sensible,
    /// sinon l'équivalent natif quand un outil MCP distant le remplace (events_create →
    /// add_calendar_event via `nativeToMCP` inversée). Sans ça, toute écriture
    /// Calendrier/Rappels via iMCP contournait la confirmation (les noms MCP ne sont
    /// pas dans `sensitiveTools`). Retourne nil si aucune confirmation requise.
    /// Fonction pure — `internal` pour les tests.
    nonisolated static func confirmationKey(for tool: String, sensitive: Set<String>) -> String? {
        ToolCallLoop.confirmationKey(for: tool, sensitive: sensitive)
    }

    private var streamTask: Task<Void, Never>?
    private var voiceTask: Task<Void, Never>?

    // MARK: - Conversations

    func ensureDBOpen() async {
        if !didOpenDB {
            try? await db.open(path: nil)
            didOpenDB = true
        }
    }

    /// Appelée par l'exécutable au démarrage.
    public func loadConversations() async {
        await ensureDBOpen()
        do {
            conversations = try await db.getAllConversations()
            if currentConversation == nil, let first = conversations.first {
                await selectConversation(first)
            }
        } catch {
            errorMessage = "Erreur chargement conversations : \(error.localizedDescription)"
        }
    }

    func selectConversation(_ conv: Conversation) async {
        currentConversation = conv
        await loadMessages()
    }

    func newConversation() async {
        do {
            let conv = try await db.createConversation()
            conversations.insert(conv, at: 0)
            await selectConversation(conv)
        } catch {
            errorMessage = "Erreur création conversation : \(error.localizedDescription)"
        }
    }

    func deleteConversation(_ conv: Conversation) async {
        do {
            try await db.deleteConversation(id: conv.id)
            conversations.removeAll { $0.id == conv.id }
            if currentConversation?.id == conv.id {
                currentConversation = conversations.first
                await loadMessages()
            }
        } catch {
            errorMessage = "Erreur suppression : \(error.localizedDescription)"
        }
    }

    func renameConversation(id: Int, title: String) async {
        do {
            try await db.updateConversationTitle(id: id, title: title)
            if let idx = conversations.firstIndex(where: { $0.id == id }) {
                conversations[idx].title = title
            }
            if currentConversation?.id == id {
                currentConversation?.title = title
            }
        } catch {
            errorMessage = "Erreur renommage : \(error.localizedDescription)"
        }
    }

    // MARK: - Messages

    func loadMessages() async {
        guard let cid = currentConversation?.id else {
            messages = []
            return
        }
        do {
            messages = try await db.getMessages(conversationId: cid)
        } catch {
            errorMessage = "Erreur chargement messages : \(error.localizedDescription)"
        }
    }

    /// Point d'entrée appelé depuis l'UI. Crée un Task annulable et stocké dans streamTask,
    /// pour que stopStreaming() puisse réellement interrompre l'envoi en cours.
    func sendMessage() async {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        // AVANT : un message envoyé pendant que Jarvis répondait était silencieusement jeté
        // (guard !isStreaming) — l'utilisateur voyait son message disparaître sans réponse.
        // Maintenant on coupe la réponse en cours et on traite le nouveau message.
        if isStreaming {
            stopStreaming()
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        inputText = ""

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runConversationTurn(userText: text)
        }
        streamTask = task
        await task.value
        streamTask = nil
    }

    private func runConversationTurn(userText: String) async {
        // Découpage étape 3 : orchestration déléguée à ConversationTurnRunner
        // (comportement identique, callbacks/tests inchangés). Le corps historique
        // (~350 lignes) vit désormais dans Conversation/ConversationTurnRunner.swift.
        await turnRunner.run(userText: userText)
    }

    /// NOTE : `internal` pour les tests — permet de vérifier la mise à jour du tool trace
    func markLastToolTrace(_ status: String) {
        if let idx = toolTrace.indices.last {
            toolTrace[idx].status = status
        }
    }

    /// Notifie la fin d'un tour SI l'app est en arrière-plan ET que le tour a duré
    /// (seuil : l'utilisateur a eu le temps de changer de fenêtre — un tour instantané
    /// ne mérite pas un ping). L'autorisation est demandée paresseusement, une seule
    /// fois (le système ne re-prompt pas ensuite). Pas de notification en cas
    /// d'annulation : l'utilisateur qui a cliqué Stop sait ce qu'il a fait.
    /// NOTE : `internal` pour les tests (le seuil est une fonction pure testée).
    func notifyTurnFinishedIfBackground(startedAt: Date) {
        guard Self.shouldNotifyTurnFinished(startedAt: startedAt, isActive: NSApp.isActive) else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = "Jarvis a terminé"
            content.body = "Ta réponse est prête."
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    /// NOTE : `internal`/`static` pour les tests — fonction pure.
    nonisolated static func shouldNotifyTurnFinished(startedAt: Date, isActive: Bool, now: Date = Date(), threshold: TimeInterval = 8) -> Bool {
        AnswerGuards.shouldNotifyTurnFinished(startedAt: startedAt, isActive: isActive, now: now, threshold: threshold)
    }
    /// si le log échoue, on continue sans bruit.
    private func auditTool(conversationId: Int?, tool: String, args: String, status: String, result: String) async {
        try? await db.logToolRun(conversationId: conversationId, tool: tool, args: args, status: status, result: result)
    }

    /// Résumé compact d'arguments pour le journal (clé=valeur, valeurs coupées).
    /// Fonction pure — `internal` pour les tests.
    nonisolated static func argsSummary(_ args: [String: Any]) -> String {
        ToolCallLoop.argsSummary(args)
    }

    // MARK: - Audit des outils (/tools)

    /// Panneau d'audit : la preuve persistée de ce qui a VRAIMENT été exécuté.
    var showTools = false
    var toolRuns: [ToolRun] = []

    func loadToolRuns() async {
        do {
            toolRuns = try await db.getRecentToolRuns()
        } catch {
            errorMessage = "Erreur chargement audit outils : \(error.localizedDescription)"
        }
    }

    /// Extrait les lignes "Source : <url>" d'un résultat search_web/read_url.
    /// Fonction pure — `internal` pour les tests.
    nonisolated static func extractSourceURLs(from toolResult: String) -> [String] {
        ToolCallLoop.extractSourceURLs(from: toolResult)
    }

    /// Ajoute un bloc "Sources :" si le texte n'en cite aucune (ni URL ni mention).
    /// Déduplique en préservant l'ordre. Fonction pure — `internal` pour les tests.
    nonisolated static func appendMissingSources(to text: String, sources: [String]) -> String {
        ToolCallLoop.appendMissingSources(to: text, sources: sources)
    }

    /// Filtre anti-boucle par appel (et non par batch) : sépare les appels inédits de ce tour
    /// de ceux déjà exécutés avec exactement les mêmes arguments. Les inédits sont marqués
    /// vus et retournés dans `fresh`, les doublons dans `duplicates` SANS toucher `seen`.
    /// Fonction pure — `internal` pour les tests.
    nonisolated static func partitionFreshToolCalls(_ calls: [ToolCall], seen: inout Set<String>) -> (fresh: [ToolCall], duplicates: [ToolCall]) {
        ToolCallLoop.partitionFreshToolCalls(calls, seen: &seen)
    }

    /// Coupe-circuit par NOM de tool (étape 4) : borne le nombre d'invocations d'un
    /// même outil par tour de conversation. Couvre le trou du filtre exact
    /// ci-dessus : un modèle qui rappelle search_web avec des args TOUJOURS
    /// différents (boucle de reformulation) passait au travers, maxLoops seul
    /// pouvant laisser passer maxLoops × batchSize invocations.
    /// Seuls les autorisés incrémentent `counts` ; les refusés reçoivent quand même
    /// un message "tool" côté appelant (pas d'exécution, pas de tool_call_id orphelin).
    /// Fonction pure — `internal` pour les tests.
    nonisolated static func partitionBudgetedToolCalls(_ calls: [ToolCall], counts: inout [String: Int], budget: Int) -> (allowed: [ToolCall], refused: [ToolCall]) {
        ToolCallLoop.partitionBudgetedToolCalls(calls, counts: &counts, budget: budget)
    }

    /// Parse les arguments d'un tool call. L'implémentation pure vit dans JarvisCore
    /// (ToolArgumentParser) — forwarder conservé pour les call-sites existants
    /// (boucle de tools, tests).
    /// NOTE : `internal` (pas `private`) pour que les tests puissent valider la logique de parsing
    /// sans avoir à dupliquer le code.
    nonisolated static func parseToolArguments(_ raw: String) -> [String: Any]? {
        ToolCallLoop.parseToolArguments(raw)
    }

    /// Retire le trailer "Sources :" auto-ajouté (appendMissingSources) d'une réponse
    /// passée avant de l'envoyer au modèle : ces URL appartiennent à un ancien tour,
    /// le modèle ne doit plus pouvoir les citer comme fraîches. Précis : ne coupe
    /// qu'au DERNIER marqueur "\n\nSources :\n" et seulement si tout ce qui suit
    /// est une liste de lignes "- http…" (une mention "source" dans le corps du
    /// texte est conservée, ainsi que les URL inline du corps).
    /// Fonction pure — `internal` pour les tests.
    nonisolated static func stripSavedSourcesTrailer(from text: String) -> String {
        ToolCallLoop.stripSavedSourcesTrailer(from: text)
    }

    /// Borne anti-boucle de la reprise auto sur réponse tronquée : on ne reprend
    /// que si le serveur a signalé `finish_reason == "length"` ET que le budget
    /// de reprises du tour n'est pas épuisé. Fonction pure — `internal` pour les tests.
    nonisolated static func shouldContinueAfterTruncation(truncated: Bool, used: Int, max: Int = 2) -> Bool {
        AnswerGuards.shouldContinueAfterTruncation(truncated: truncated, used: used, max: max)
    }

    /// Détecte une réponse finale « vide de substance » alors que des résultats web
    /// existent : courte, sans URL, alors que search_web/read_url ont rapporté des
    /// sources. Le petit modèle a ignoré les tools (phrase générique + Sources
    /// auto-ajoutées). Une seule relance avec consigne explicite — un modèle qui
    /// ne sait pas utiliser les résultats échouera pareil à la 2e tentative, inutile
    /// d'insister. Fonction pure — `internal` pour les tests.
    nonisolated static func shouldRetryVacuousAnswer(finalText: String, hasWebSources: Bool, used: Int, max: Int = 1, minChars: Int = 300) -> Bool {
        AnswerGuards.shouldRetryVacuousAnswer(finalText: finalText, hasWebSources: hasWebSources, used: used, max: max, minChars: minChars)
    }

    /// true si le texte est un refus déguisé ("je ne peux pas…", "dépasse mes
    /// capacités…") alors que des outils couvrent la demande. Les petits modèles
    /// confabulent leurs propres limites (cas réel : read_url décrit comme "lit et
    /// résume" → le modèle a décrété qu'extraire des prix était impossible sans
    /// jamais appeler l'outil). Une relance avec injonction d'appeler suffit
    /// souvent ; sinon on sauvegarde tel quel (budget unique partagé avec
    /// shouldRetryVacuousAnswer). Fonction pure — `internal` pour les tests.
    nonisolated static func isRefusalAnswer(_ finalText: String) -> Bool {
        AnswerGuards.isRefusalAnswer(finalText)
    }

    /// true si le texte, une fois retirés le bloc "Sources :" et les URL inline,
    /// ne contient presque rien (< minChars) : que des liens, pas de contenu.
    /// Fonction pure — `internal` pour les tests.
    nonisolated static func isSourcesOnlyAnswer(_ finalText: String, minChars: Int = 100) -> Bool {
        AnswerGuards.isSourcesOnlyAnswer(finalText, minChars: minChars)
    }

    /// Affiche une demande de confirmation dans l'UI et suspend jusqu'à la réponse de l'utilisateur.
    /// En mode voix, l'utilisateur n'a pas forcément les yeux sur l'écran : on annonce vocalement
    /// qu'une confirmation est nécessaire, sinon la conversation semble juste s'arrêter sans raison.
    private func requestConfirmation(tool: String, args: [String: Any]) async -> Bool {
        // Dédupe mémoire : si le modèle redemande exactement un fait déjà stocké (cas courant
        // après la confirmation heuristique de extractAndConfirmFacts sur le même message),
        // on approuve sans re-popper une sheet — sinon l'utilisateur, qui vient déjà de
        // valider, ignore/annule le doublon et le modèle croit à tort avoir mémorisé.
        if tool == "remember_fact",
           let key = args["key"] as? String,
           let value = args["value"] as? String,
           let known = try? await db.getAllFacts(),
           known.first(where: { $0.key == key })?.value == value {
            return true
        }
        let summary = confirmationSummary(tool: tool, args: args)
        if isVoiceMode {
            await audio.speak("J'ai besoin d'une confirmation à l'écran avant de continuer.")
        }
        return await withCheckedContinuation { continuation in
            confirmationRequest = ToolConfirmationRequest(toolName: tool, summary: summary) { approved in
                continuation.resume(returning: approved)
            }
        }
    }

    private func confirmationSummary(tool: String, args: [String: Any]) -> String {
        switch tool {
        case "sleep_mac":
            return "Jarvis veut exécuter : \(args["action"] as? String ?? "action système") sur le Mac."
        case "send_message":
            return "Jarvis veut envoyer un message à \(args["contact"] as? String ?? "?") : « \(args["message"] as? String ?? "") »"
        case "create_note":
            let noteBody = (args["body"] as? String ?? "")
            let noteTruncated = noteBody.count > 200 ? String(noteBody.prefix(200)) + "…" : noteBody
            return "Jarvis veut créer la note « \(args["title"] as? String ?? "?") » avec :\n\n\(noteTruncated)"
        case "open_app":
            let target = (args["app"] as? String ?? "?")
            if let u = args["url"] as? String, !u.isEmpty {
                return "Jarvis veut ouvrir \(target) sur « \(u) »."
            }
            return "Jarvis veut ouvrir l'application \(target)."
        case "get_clipboard":
            return "Jarvis veut LIRE le presse-papiers (peut contenir des mots de passe ou données privées — ce contenu sera envoyé au modèle)."
        case "edit_note":
            let body = (args["body"] as? String ?? "")
            let truncated = body.count > 200 ? String(body.prefix(200)) + "…" : body
            return "Jarvis veut modifier la note « \(args["search_title"] as? String ?? "?") » avec :\n\n\(truncated)"
        case "take_screenshot":
            // Capture plein écran : l'image peut contenir des infos privées visibles à ce
            // moment-là (messages, onglets, documents). On le dit explicitement pour que
            // l'utilisateur jette un œil à son écran avant de valider, comme pour set_clipboard.
            return "Jarvis veut prendre une capture de TOUT l'écran (le contenu actuellement affiché — messages, onglets, documents — sera enregistré dans un fichier PNG et ouvert dans Aperçu)."
        case "add_reminder":
            return "Jarvis veut créer le rappel « \(args["title"] as? String ?? "?") »."
        case "complete_reminder":
            return "Jarvis veut marquer le rappel [id: \(args["id"] as? String ?? "?")] comme terminé."
        case "delete_reminder":
            return "Jarvis veut SUPPRIMER le rappel [id: \(args["id"] as? String ?? "?")]."
        case "add_calendar_event":
            return "Jarvis veut créer l'événement « \(args["title"] as? String ?? "?") » le \(args["date"] as? String ?? "?")."
        case "edit_calendar_event":
            return "Jarvis veut MODIFIER l'événement [id: \(args["id"] as? String ?? "?")]."
        case "delete_calendar_event":
            return "Jarvis veut SUPPRIMER l'événement [id: \(args["id"] as? String ?? "?")]."
        case "remember_fact":
            // Ajouté par toi, mais sans passer par la confirmation : le modèle pouvait écrire
            // n'importe quelle clé/valeur en mémoire long-terme (réinjectée dans CHAQUE prompt système
            // futur via factsContext) sans qu'un humain ne valide jamais rien. Une donnée web piégée
            // aurait pu suffire à empoisonner la mémoire de façon persistante. Même traitement que
            // l'extraction heuristique existante : confirmation obligatoire avant écriture.
            return "Jarvis veut mémoriser : \(args["key"] as? String ?? "?") = \(args["value"] as? String ?? "?")"
        default:
            return "Jarvis veut exécuter l'action « \(tool) »."
        }
    }

    /// Annule réellement l'envoi en cours (requête réseau + boucle de tools),
    /// contrairement à l'ancienne version où streamTask n'était jamais assigné.
    func stopStreaming() {
        streamTask?.cancel()
        streamTask = nil
        isStreaming = false
        isToolRunning = false
        streamingText = ""
        // AVANT : une confirmation en attente (withCheckedContinuation, non annulable par
        // Task.cancel) survivait au Stop — le tour restait suspendu pour toujours et la
        // suite semblait "ne plus fonctionner". Résoudre en refus débloque la boucle, qui
        // constate ensuite l'annulation au prochain Task.checkCancellation.
        if let pending = confirmationRequest {
            confirmationRequest = nil
            pending.resolve(false)
        }
        audio.stopSpeaking()
        stt.cancel()
    }

    // MARK: - Facts

    /// Logique d'extraction extraite dans `FactExtractor` (chantier 2) : struct pure,
    /// testable sans instancier le ViewModel ni sa DB. Les méthodes ci-dessous
    /// délèguent à l'identique pour garder les tests existants verts.
    nonisolated static func normalizeNameToken(_ token: some StringProtocol) -> String {
        FactsExtractionCoordinator.normalizeNameToken(token)
    }

    /// NOTE : `internal` pour les tests.
    nonisolated static func isExcludedNameValue(_ value: String) -> Bool {
        FactsExtractionCoordinator.isExcludedNameValue(value)
    }

    /// Retire les mots de liaison finaux ("Dimitri et" → "Dimitri"). NOTE : `internal` pour les tests.
    nonisolated static func trimNameTrailingStoppers(_ value: String) -> String {
        FactsExtractionCoordinator.trimNameTrailingStoppers(value)
    }

    /// NOTE : `internal` pour les tests — permet de valider l'extraction heuristique sans passer par le flux complet
    func extractCandidateFacts(from text: String) -> [(key: String, value: String)] {
        factsCoordinator.extractCandidateFacts(from: text)
    }

    /// Détecte des faits potentiels dans le message utilisateur et demande confirmation avant
    /// d'écrire quoi que ce soit en base. Délègue au FactsExtractionCoordinator
    /// (découpage étape 1) — comportement identique, signature inchangée.
    private func extractAndConfirmFacts(from text: String) async {
        await factsCoordinator.extractAndConfirmFacts(from: text)
    }

    /// Sheet de confirmation mémoire (propriété de l'UI : reste dans le ViewModel,
    /// le coordinator ne fait que l'appeler via closure).
    private func requestFactsConfirmation(summary: String) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            confirmationRequest = ToolConfirmationRequest(toolName: "memory_update", summary: summary) { approved in
                continuation.resume(returning: approved)
            }
        }
    }

    func loadFacts() async {
        await factsCoordinator.loadFactsReporting()
    }

    func deleteFact(_ fact: Fact) async {
        await factsCoordinator.deleteFact(fact)
    }

    func clearAllFacts() async {
        await factsCoordinator.clearAllFacts()
    }

    // MARK: - Export & Recherche

    /// Recherche plein-texte dans toutes les conversations.
    struct SearchResultEntry: Identifiable, Equatable {
        let id: Int
        let role: String
        let content: String
        let conversationTitle: String
        let conversationId: Int?
    }
    var searchResults: [SearchResultEntry] = []
    var isSearching = false

    func search(_ query: String) async {
        await ensureDBOpen()
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            return
        }
        do {
            let results = try await db.searchMessages(query)
            searchResults = results.map { r in
                SearchResultEntry(id: r.message.id, role: r.message.role,
                                  content: r.message.content,
                                  conversationTitle: r.conversationTitle,
                                  conversationId: r.message.conversationId)
            }
        } catch {
            errorMessage = "Erreur recherche : \(error.localizedDescription)"
        }
    }

    /// Exporte la conversation courante en Markdown. Retourne le contenu ou nil si vide/erreur.
    func exportConversationAsMarkdown() -> String? {
        guard let conv = currentConversation, !messages.isEmpty else { return nil }
        let df = DateFormatter()
        df.dateFormat = "dd/MM/yyyy HH:mm"
        var out = "# \(conv.title)\n\n"
        for msg in messages {
            let who = msg.role == "user" ? "Vous" : "Jarvis"
            out += "**\(who)** — \(df.string(from: msg.createdAt))\n\n\(msg.content)\n\n---\n\n"
        }
        return out
    }

    /// Exporte la conversation courante en JSON (format structuré, réimportable).
    func exportConversationAsJSON() -> String? {
        guard let conv = currentConversation, !messages.isEmpty else { return nil }
        let df = ISO8601DateFormatter()
        let payload: [String: Any] = [
            "title": conv.title,
            "exported_at": df.string(from: Date()),
            "messages": messages.map { m in
                ["role": m.role, "content": m.content, "created_at": df.string(from: m.createdAt)]
            }
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    // MARK: - Voice

    /// Appelée par l'exécutable (barre de menu).
    public func toggleVoiceMode() async {
        if isVoiceMode {
            isVoiceMode = false
            isListening = false
            stt.cancel()
            voiceTask?.cancel()
            voiceTask = nil
            stopStreaming()
        } else {
            isVoiceMode = true
            voiceTask = Task {
                defer {
                    voiceTask = nil
                    stt.onPartialResult = nil
                }

                while isVoiceMode && !Task.isCancelled {
                    do {
                        stt.onPartialResult = { [weak self] text in
                            guard let self = self else { return }
                            guard !text.isEmpty else { return }
                            self.inputText = text

                            // Barge-in durci après le premier essai (bargeInEnabled désactivé par
                            // défaut par la version précédente, probablement parce que sans annulation
                            // d'écho fiable, Jarvis se coupait la parole tout seul en boucle). Deux
                            // garde-fous ajoutés au lieu d'un seuil brut sur la longueur du texte :
                            // 1) fenêtre de grâce de 600ms après le début du TTS, où l'écho de
                            //    l'attaque du haut-parleur est le plus probable ;
                            // 2) exiger 2 partials consécutifs non-vides (debounce), pas un seul —
                            //    un artefact ponctuel ne suffit plus, une vraie interruption humaine
                            //    produit un flux continu de partials.
                            guard settings.bargeInEnabled, self.audio.isSpeaking else {
                                self.bargeInStreak = 0
                                return
                            }
                            if let started = self.speechStartedAt,
                               ContinuousClock.now - started < .milliseconds(600) {
                                return
                            }
                            self.bargeInStreak += 1
                            if self.bargeInStreak >= 2 {
                                self.audio.stopSpeaking()
                                self.bargeInStreak = 0
                            }
                        }

                        isListening = true
                        inputText = ""
                        bargeInStreak = 0
                        let text = try await stt.transcribe()
                        isListening = false
                        stt.onPartialResult = nil

                        guard !text.isEmpty else { continue }

                        // Filtre anti-bruit : ignore les transcriptions de 2 caractères ou moins
                        // ("euh", "ah", souffle mal transcrit) tout en laissant passer les commandes
                        // courtes mais réelles ("stop", "oui").
                        guard text.count > 2 else { continue }

                        // Délai réduit : 200ms d'attente artificielle avant chaque tour
                        // donnait une impression de latence en mode vocal.
                        try? await Task.sleep(nanoseconds: 100_000_000)

                        await runConversationTurn(userText: text)

                        // Retry une fois si Ollama n'a pas répondu
                        if errorMessage?.contains("Pas de réponse") == true {
                            errorMessage = nil
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            await runConversationTurn(userText: text)
                        }

                        // Attend la fin du TTS avant de rouvrir le micro — évite que le micro capte
                        // la propre voix de Jarvis et relance une transcription en boucle.
                        while isSpeaking && isVoiceMode && !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 60_000_000)
                        }
                    } catch {
                        isListening = false
                        if let sttErr = error as? STTError, sttErr == .cancelled { break }
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
                isVoiceMode = false
                isListening = false
                inputText = ""
            }
        }
    }
}
