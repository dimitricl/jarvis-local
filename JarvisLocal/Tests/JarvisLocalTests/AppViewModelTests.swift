@testable import JarvisUI
@testable import JarvisServices
import JarvisCore
import XCTest

@MainActor
final class JarvisLocalAppViewModelTests: XCTestCase {

    var viewModel: AppViewModel!

    override func setUp() async throws {
        try await super.setUp()
        viewModel = AppViewModel()
        try await viewModel.db.open(path: ":memory:")
    }

    override func tearDown() async throws {
        viewModel = nil
        try await super.tearDown()
    }

    // MARK: - Conversation Management

    func testNewConversationCreatesAndSelects() async {
        await viewModel.newConversation()
        XCTAssertNotNil(viewModel.currentConversation)
        XCTAssertEqual(viewModel.conversations.count, 1)
        XCTAssertEqual(viewModel.messages.count, 0)
    }

    func testSelectConversationLoadsMessages() async {
        await viewModel.newConversation()
        let conv = viewModel.currentConversation!
        _ = try? await viewModel.db.insertMessage(role: "user", content: "Hello", conversationId: conv.id)
        _ = try? await viewModel.db.insertMessage(role: "assistant", content: "Hi", conversationId: conv.id)

        await viewModel.selectConversation(conv)
        XCTAssertEqual(viewModel.messages.count, 2)
    }

    func testDeleteConversationRemovesFromList() async {
        await viewModel.newConversation()
        let conv = viewModel.currentConversation!
        await viewModel.newConversation()
        let secondConv = viewModel.currentConversation!

        await viewModel.deleteConversation(conv)
        XCTAssertEqual(viewModel.conversations.count, 1)
        XCTAssertEqual(viewModel.currentConversation?.id, secondConv.id)
    }

    func testRenameConversationUpdatesTitle() async {
        await viewModel.newConversation()
        let conv = viewModel.currentConversation!

        await viewModel.renameConversation(id: conv.id, title: "New Title")
        XCTAssertEqual(viewModel.conversations.first?.title, "New Title")
        XCTAssertEqual(viewModel.currentConversation?.title, "New Title")
    }

    // MARK: - Fact Extraction

    func testExtractCandidateFactsName() {
        let text = "Je m'appelle Dimitri"
        let facts = viewModel.extractCandidateFacts(from: text)
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts.first?.key, "user.name")
        XCTAssertEqual(facts.first?.value, "Dimitri")
    }

    func testExtractCandidateFactsCity() {
        let text = "J'habite à Paris"
        let facts = viewModel.extractCandidateFacts(from: text)
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts.first?.key, "user.city")
        XCTAssertEqual(facts.first?.value, "Paris")
    }

    func testExtractCandidateFactsBirthday() {
        let text = "Je suis né le 15 mai 1990"
        let facts = viewModel.extractCandidateFacts(from: text)
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts.first?.key, "user.birthday")
        XCTAssertEqual(facts.first?.value, "15 mai 1990")
    }

    func testExtractCandidateFactsMultiple() {
        let text = "Je m'appelle Dimitri et j'habite à Lyon"
        let facts = viewModel.extractCandidateFacts(from: text)
        XCTAssertEqual(facts.count, 2)
        let keys = Set(facts.map { $0.key })
        XCTAssertTrue(keys.contains("user.name"))
        XCTAssertTrue(keys.contains("user.city"))
    }

    func testExtractCandidateFactsNoMatch() {
        let text = "Quel temps fait-il aujourd'hui ?"
        let facts = viewModel.extractCandidateFacts(from: text)
        XCTAssertTrue(facts.isEmpty)
    }

    func testExtractCandidateFactsCaseInsensitive() {
        let text = "JE M'APPELLE DIMITRI"
        let facts = viewModel.extractCandidateFacts(from: text)
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts.first?.value, "DIMITRI")
    }

    // MARK: - Fact Confirmation & Persistence

    func testFactConfirmationFlow() async {
        await viewModel.newConversation()

        // Test that confirmation request can be set and resolved
        let expectation = XCTestExpectation(description: "Confirmation resolved")
        viewModel.confirmationRequest = ToolConfirmationRequest(
            toolName: "memory_update",
            summary: "Test fact"
        ) { approved in
            XCTAssertTrue(approved)
            expectation.fulfill()
        }
        viewModel.confirmationRequest?.resolve(true)
        await fulfillment(of: [expectation], timeout: 1.0)
    }

    // MARK: - Tool Tracing

    func testToolTraceRecording() async {
        viewModel.toolTrace = []
        viewModel.markLastToolTrace("✓")
        XCTAssertEqual(viewModel.toolTrace.count, 0)

        viewModel.toolTrace.append(AppViewModel.ToolTraceEntry(name: "test_tool", status: "…"))
        viewModel.markLastToolTrace("✓")
        XCTAssertEqual(viewModel.toolTrace.last?.status, "✓")
    }

    // MARK: - Stop Streaming

    func testStopStreamingCancelsTask() async {
        viewModel.isStreaming = true
        viewModel.streamingText = "Test"
        viewModel.isToolRunning = true
        viewModel.currentToolName = "test_tool"

        viewModel.stopStreaming()

        XCTAssertFalse(viewModel.isStreaming)
        XCTAssertTrue(viewModel.streamingText.isEmpty)
        XCTAssertFalse(viewModel.isToolRunning)
    }

    // MARK: - Fact CRUD

    func testLoadFacts() async {
        try? await viewModel.db.upsertFact(key: "user.name", value: "Test")
        await viewModel.loadFacts()
        XCTAssertEqual(viewModel.facts.count, 1)
    }

    func testDeleteFact() async {
        try? await viewModel.db.upsertFact(key: "user.name", value: "Test")
        await viewModel.loadFacts()
        let fact = viewModel.facts.first!

        await viewModel.deleteFact(fact)
        XCTAssertEqual(viewModel.facts.count, 0)
    }

    func testClearAllFacts() async {
        try? await viewModel.db.upsertFact(key: "user.name", value: "Test")
        try? await viewModel.db.upsertFact(key: "user.city", value: "Paris")
        await viewModel.loadFacts()
        XCTAssertEqual(viewModel.facts.count, 2)

        await viewModel.clearAllFacts()
        XCTAssertEqual(viewModel.facts.count, 0)
    }

    // MARK: - Background jobs observation

    /// Arrêter l'observation doit geler le miroir : un job enqueué APRÈS
    /// stopObservingJobs() ne doit jamais apparaître dans vm.jobs.
    /// Contexte honnête : sur ce toolchain, cancel() fait déjà sortir next()
    /// (nil), donc une boucle suspendue sans élément en vol ne fuit pas au
    /// réveil — mais un élément déjà en buffer au moment du cancel réveillerait
    /// quand même la boucle, d'où le garde isCancelled exigé dans
    /// startObservingJobs. Le délai de grâce final laisse à une boucle fautive
    /// le temps de fuir : le test ne passe que si elle ne fuit pas.
    func testStopObservingJobsFreezesMirroredJobs() async {
        let registry = JobRegistry()
        let jobsVM = AppViewModel(
            db: viewModel.db,
            ollama: viewModel.ollama,
            tools: viewModel.tools,
            audio: viewModel.audio,
            stt: viewModel.stt,
            settings: viewModel.settings,
            jobsRegistry: registry
        )
        // L'init démarre l'observation : preuve qu'elle est vivante avant le stop.
        let firstId = await registry.enqueue(title: "avant-stop") { "un" }
        var sawFirst = false
        let liveDeadline = Date().addingTimeInterval(5)
        while !sawFirst, Date() < liveDeadline {
            sawFirst = jobsVM.jobs.contains { $0.id == firstId }
            if !sawFirst { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        XCTAssertTrue(sawFirst, "l'observation aurait dû miroiter le premier job avant le stop")

        jobsVM.stopObservingJobs()

        // Job enqueué APRÈS l'arrêt : le registre le termine normalement…
        let secondId = await registry.enqueue(title: "après-stop") { "deux" }
        var secondTerminal = false
        let endDeadline = Date().addingTimeInterval(5)
        while !secondTerminal, Date() < endDeadline {
            if let s = await registry.status(secondId), s.isTerminal {
                secondTerminal = true
            } else {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        XCTAssertTrue(secondTerminal, "le registre aurait dû terminer le second job")
        // …mais le réveil qu'il provoque dans la boucle annulée ne doit RIEN appliquer.
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(jobsVM.jobs.contains { $0.id == firstId }, "le job d'avant-stop doit rester visible")
        XCTAssertFalse(jobsVM.jobs.contains { $0.id == secondId }, "un job post-stop ne doit pas fuir dans le miroir")
    }
}

@MainActor
final class JarvisLocalAppViewModelConversationFlowTests: XCTestCase {

    var viewModel: AppViewModel!

    override func setUp() async throws {
        try await super.setUp()
        viewModel = AppViewModel()
        try await viewModel.db.open(path: ":memory:")
    }

    func testFullConversationCycle() async {
        await viewModel.newConversation()
        XCTAssertNotNil(viewModel.currentConversation)

        let userMsg = try? await viewModel.db.insertMessage(role: "user", content: "Bonjour", conversationId: viewModel.currentConversation!.id)
        XCTAssertNotNil(userMsg)
        viewModel.messages.append(userMsg!)

        let assistantMsg = try? await viewModel.db.insertMessage(role: "assistant", content: "Salut !", conversationId: viewModel.currentConversation!.id)
        XCTAssertNotNil(assistantMsg)
        viewModel.messages.append(assistantMsg!)

        XCTAssertEqual(viewModel.messages.count, 2)
    }

    func testMultipleConversationsSwitching() async {
        await viewModel.newConversation()
        let conv1 = viewModel.currentConversation!

        await viewModel.newConversation()
        let conv2 = viewModel.currentConversation!

        XCTAssertNotEqual(conv1.id, conv2.id)
        XCTAssertEqual(viewModel.conversations.count, 2)

        await viewModel.selectConversation(conv1)
        XCTAssertEqual(viewModel.currentConversation?.id, conv1.id)
    }
}

@MainActor
final class JarvisLocalAppViewModelFactExtractionEdgeCasesTests: XCTestCase {

    var viewModel: AppViewModel!

    override func setUp() async throws {
        try await super.setUp()
        viewModel = AppViewModel()
    }

    func testExtractFactsWithAccents() {
        let text = "J'habite à Montréal"
        let facts = viewModel.extractCandidateFacts(from: text)
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts.first?.value, "Montréal")
    }

    func testExtractFactsWithCompoundNames() {
        let text = "Je m'appelle Jean-Pierre Dubois"
        let facts = viewModel.extractCandidateFacts(from: text)
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts.first?.value, "Jean-Pierre Dubois")
    }

    func testExtractFactsWithDifferentPhrasings() {
        let texts = [
            "Je m'appelle Alice",
            "Mon nom est Bob",
            "J'habite à Lyon",
            "Je vis à Marseille",
            "Je suis né le 1er janvier 2000",
            "Mon anniversaire est le 25 décembre 1995"
        ]

        for text in texts {
            let facts = viewModel.extractCandidateFacts(from: text)
            XCTAssertFalse(facts.isEmpty, "Should extract fact from: \(text)")
        }
    }

    func testExtractFactsIgnoresPartialMatches() {
        let text = "Je m'appellerai plus tard"
        let facts = viewModel.extractCandidateFacts(from: text)
        XCTAssertTrue(facts.isEmpty)
    }

    /// Cas réel observé : "je suis dimitri et toi ?" ne matchait AUCUN pattern (seuls
    /// "je m'appelle / mon nom est" existaient) — le modèle répondait "je vais m'en
    /// souvenir" sans rien enregistrer.
    func testExtractCandidateFactsNameJeSuis() {
        let facts = viewModel.extractCandidateFacts(from: "je suis dimitri et toi ?")
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts.first?.key, "user.name")
        XCTAssertEqual(facts.first?.value, "dimitri")
    }

    func testExtractCandidateFactsNameVariants() {
        for text in ["moi c'est Dimitri", "mon prénom est Dimitri", "c'est moi Dimitri"] {
            let facts = viewModel.extractCandidateFacts(from: text)
            XCTAssertEqual(facts.count, 1, "Should extract name from: \(text)")
            XCTAssertEqual(facts.first?.key, "user.name")
        }
    }

    /// Le pattern large "je suis X" ne doit pas produire de popup pour des états,
    /// métiers ou locutions.
    func testJeSuisNonNamesAreExcluded() {
        for text in [
            "je suis d'accord",
            "je suis en retard",
            "je suis fatigué",
            "je suis développeur",
            "je suis content",
            "je suis au boulot",
            "je suis 100% d'accord"
        ] {
            let facts = viewModel.extractCandidateFacts(from: text)
            XCTAssertTrue(facts.isEmpty, "Should NOT extract name from: \(text)")
        }
    }

    /// "Je suis né le…" reste un anniversaire, pas un prénom "né".
    func testBirthdayDoesNotProduceName() {
        let facts = viewModel.extractCandidateFacts(from: "Je suis né le 15 mai 1990")
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts.first?.key, "user.birthday")
    }
}

@MainActor
final class JarvisLocalToolBatchDedupTests: XCTestCase {

    private func makeCall(id: String = UUID().uuidString, name: String, args: String) -> ToolCall {
        ToolCall(id: id, type: "function", function: ToolCallFunction(name: name, arguments: args))
    }

    func testAllFreshCallsPassThrough() {
        var seen = Set<String>()
        let calls = [
            makeCall(name: "get_weather", args: #"{"city":"Paris"}"#),
            makeCall(name: "read_url", args: #"{"url":"https://example.com"}"#)
        ]
        let (fresh, dups) = AppViewModel.partitionFreshToolCalls(calls, seen: &seen)
        XCTAssertEqual(fresh.count, 2)
        XCTAssertTrue(dups.isEmpty)
        XCTAssertEqual(seen.count, 2)
    }

    /// Non-régression du bug "batch jeté en entier" : un appel inédit batché avec un
    /// doublon doit QUAND MÊME s'exécuter — seul le doublon est écarté.
    func testFreshCallSurvivesBatchedDuplicate() {
        var seen = Set<String>()
        let first = makeCall(name: "get_weather", args: #"{"city":"Paris"}"#)
        let (fresh1, _) = AppViewModel.partitionFreshToolCalls([first], seen: &seen)
        XCTAssertEqual(fresh1.count, 1)

        let retry = makeCall(name: "get_weather", args: #"{"city":"Paris"}"#)
        let newCall = makeCall(name: "read_url", args: #"{"url":"https://example.com"}"#)
        let (fresh, dups) = AppViewModel.partitionFreshToolCalls([retry, newCall], seen: &seen)
        XCTAssertEqual(fresh.map { $0.id }, [newCall.id])
        XCTAssertEqual(dups.map { $0.id }, [retry.id])
    }

    func testAllDuplicatesYieldsEmptyFresh() {
        var seen = Set<String>()
        let call = makeCall(name: "get_weather", args: #"{"city":"Paris"}"#)
        _ = AppViewModel.partitionFreshToolCalls([call], seen: &seen)
        let again = makeCall(name: "get_weather", args: #"{"city":"Paris"}"#)
        let (fresh, dups) = AppViewModel.partitionFreshToolCalls([again], seen: &seen)
        XCTAssertTrue(fresh.isEmpty)
        XCTAssertEqual(dups.count, 1)
    }

    func testSameToolDifferentArgsIsFresh() {
        var seen = Set<String>()
        _ = AppViewModel.partitionFreshToolCalls([makeCall(name: "get_weather", args: #"{"city":"Paris"}"#)], seen: &seen)
        let (fresh, dups) = AppViewModel.partitionFreshToolCalls([makeCall(name: "get_weather", args: #"{"city":"Lyon"}"#)], seen: &seen)
        XCTAssertEqual(fresh.count, 1)
        XCTAssertTrue(dups.isEmpty)
    }
}

@MainActor
final class JarvisLocalSourcesCitationTests: XCTestCase {

    func testExtractSourceURLs() {
        let result = "--- Titre ---\nSource : https://example.com/a\nContenu : x\nSource : notaurl\nSource : https://example.com/b\n"
        XCTAssertEqual(AppViewModel.extractSourceURLs(from: result),
                       ["https://example.com/a", "https://example.com/b"])
    }

    func testAppendMissingSourcesAppendsWhenAbsent() {
        let out = AppViewModel.appendMissingSources(
            to: "L'iPhone 18 Pro coûte 1 479 €.",
            sources: ["https://a.fr/x", "https://b.fr/y", "https://a.fr/x"])
        XCTAssertTrue(out.hasPrefix("L'iPhone 18 Pro coûte 1 479 €.\n\nSources :\n"))
        XCTAssertTrue(out.contains("- https://a.fr/x"))
        XCTAssertTrue(out.contains("- https://b.fr/y"))
        // Dédupliqué : une seule occurrence.
        XCTAssertEqual(out.components(separatedBy: "https://a.fr/x").count - 1, 1)
    }

    func testAppendMissingSourcesNoOpWhenCitedOrEmpty() {
        XCTAssertEqual(
            AppViewModel.appendMissingSources(to: "Voir https://a.fr/x", sources: ["https://b.fr/y"]),
            "Voir https://a.fr/x")
        XCTAssertEqual(
            AppViewModel.appendMissingSources(to: "Texte", sources: []),
            "Texte")
        // Le mot "sources" (insensible à la casse) compte comme citation.
        XCTAssertEqual(
            AppViewModel.appendMissingSources(to: "Sources : voir ailleurs", sources: ["https://b.fr/y"]),
            "Sources : voir ailleurs")
    }

    func testArgsSummary() {
        XCTAssertEqual(AppViewModel.argsSummary(["b": "2", "a": "1"]), "a=1, b=2")
        XCTAssertEqual(AppViewModel.argsSummary([:] as [String: Any]), "")
    }
}

@MainActor
final class JarvisLocalToolRunsAuditTests: XCTestCase {

    var viewModel: AppViewModel!

    override func setUp() async throws {
        try await super.setUp()
        viewModel = AppViewModel()
        try await viewModel.db.open(path: ":memory:")
    }

    func testLogAndFetchToolRuns() async throws {
        try await viewModel.db.logToolRun(conversationId: 1, tool: "search_web",
                                          args: "query=iPhone", status: "✓", result: "Résultat : 1 479 €")
        try await viewModel.db.logToolRun(conversationId: 1, tool: "sleep_mac",
                                          args: "action=sleep", status: "refusé", result: "Refusé.")
        let runs = try await viewModel.db.getRecentToolRuns()
        XCTAssertEqual(runs.count, 2)
        // Plus récent d'abord.
        XCTAssertEqual(runs[0].tool, "sleep_mac")
        XCTAssertEqual(runs[0].status, "refusé")
        XCTAssertEqual(runs[1].tool, "search_web")
        XCTAssertEqual(runs[1].conversationId, 1)
    }

    func testLogToolRunTruncates() async throws {
        try await viewModel.db.logToolRun(conversationId: nil, tool: "read_url",
                                          args: String(repeating: "a", count: 500),
                                          status: "✓",
                                          result: String(repeating: "b", count: 2000))
        let runs = try await viewModel.db.getRecentToolRuns()
        XCTAssertEqual(runs.count, 1)
        XCTAssertLessThanOrEqual(runs[0].args.count, 200)
        XCTAssertLessThanOrEqual(runs[0].result.count, 500)
        XCTAssertNil(runs[0].conversationId)
    }

    func testLoadToolRunsPopulatesViewModel() async throws {
        try await viewModel.db.logToolRun(conversationId: nil, tool: "get_weather",
                                          args: "city=Paris", status: "✓", result: "25°C")
        await viewModel.loadToolRuns()
        XCTAssertEqual(viewModel.toolRuns.count, 1)
        XCTAssertEqual(viewModel.toolRuns.first?.tool, "get_weather")
    }
}

@MainActor
final class JarvisLocalConfirmationResolutionTests: XCTestCase {

    var viewModel: AppViewModel!

    override func setUp() async throws {
        try await super.setUp()
        viewModel = AppViewModel()
        try await viewModel.db.open(path: ":memory:")
    }

    /// Un double resolve (clic + dismiss système) ne doit reprendre qu'une fois :
    /// le second appel est ignoré au lieu de trapper la continuation.
    func testDoubleResolveResumesOnlyOnce() {
        var resolutions: [Bool] = []
        let request = ToolConfirmationRequest(toolName: "test", summary: "test") { approved in
            resolutions.append(approved)
        }
        request.resolve(true)
        request.resolve(false)
        XCTAssertEqual(resolutions, [true])
    }

    /// Stop pendant une confirmation en attente : la demande est refusée et nettoyée,
    /// le tour ne reste pas suspendu pour toujours.
    func testStopStreamingResolvesPendingConfirmation() {
        var resolutions: [Bool] = []
        viewModel.confirmationRequest = ToolConfirmationRequest(toolName: "sleep_mac", summary: "test") { approved in
            resolutions.append(approved)
        }
        viewModel.isStreaming = true

        viewModel.stopStreaming()

        XCTAssertNil(viewModel.confirmationRequest)
        XCTAssertEqual(resolutions, [false])
        XCTAssertFalse(viewModel.isStreaming)
    }
}
