@testable import JarvisUI
import JarvisCore
import XCTest

/// Tests du ConversationTurnRunner (découpage AppViewModel, étape 3).
/// Fakes de FakeInjectionTests (aucun import JarvisServices) + hôte enregistreur.
@MainActor
final class ConversationTurnRunnerTests: XCTestCase {

    final class Host: @unchecked Sendable {
        var messages: [Message] = []
        var isStreaming = false
        var streamingText = ""
        var trace: [String] = []
        var errors: [String] = []
        var facts: [Fact] = []
        var notified: [Date] = []
        var spoken: [String] = []
    }

    private func makeRunner(
        store: FakeStore = FakeStore(),
        host: Host = Host(),
        approveMemory: Bool = true
    ) -> ConversationTurnRunner {
        let facts = FactsExtractionCoordinator(
            db: store,
            requestConfirmation: { _ in approveMemory },
            didUpdateFacts: { host.facts = $0 },
            reportError: { host.errors.append($0) }
        )
        return ConversationTurnRunner(
            db: store,
            llm: FakeLLM(),
            tools: FakeTools(),
            settings: FakeSettings(),
            facts: facts,
            sensitiveTools: ["sleep_mac"],
            cb: TurnCallbacks(
                appendTrace: { host.trace.append($0) },
                speak: { host.spoken.append($0) },
                notifyFinished: { host.notified.append($0) },
                auditTool: { _, _, _, _, _ in }
            ),
            ui: TurnUI(
                ensureDBOpen: {},
                ensureConversationId: { [store] in
                    if store.conversations.isEmpty {
                        let c = try? await store.createConversation(title: "Test")
                        return c?.id
                    }
                    return store.conversations.first?.id
                },
                appendMessage: { host.messages.append($0) },
                setStreaming: { host.isStreaming = $0 },
                setStreamingText: { host.streamingText = $0 },
                resetTrace: { host.trace = [] },
                reportError: { host.errors.append($0) },
                setFacts: { host.facts = $0 }
            )
        )
    }

    func testSimpleTurnSavesUserAndAssistant() async {
        let store = FakeStore()
        let host = Host()
        let runner = makeRunner(store: store, host: host)
        await runner.run(userText: "hello")
        XCTAssertFalse(host.isStreaming)
        XCTAssertTrue(host.errors.isEmpty)
        let stored = (try? await store.getMessages(conversationId: 1)) ?? []
        XCTAssertEqual(stored.map { $0.role }, ["user", "assistant"])
        XCTAssertEqual(stored.first?.content, "hello")
        XCTAssertTrue(stored.last?.content.contains("Bonjour (fake)") ?? false)
        XCTAssertEqual(host.messages.count, 2)
        XCTAssertEqual(host.notified.count, 1)
    }

    func testFactsExtractedWhenApproved() async {
        let store = FakeStore()
        let host = Host()
        let runner = makeRunner(store: store, host: host, approveMemory: true)
        await runner.run(userText: "Je m'appelle Dimitri")
        XCTAssertEqual(store.facts.first(where: { $0.key == "user.name" })?.value, "Dimitri")
        XCTAssertEqual(host.facts.first(where: { $0.key == "user.name" })?.value, "Dimitri")
    }

    func testFactsSkippedWhenRefused() async {
        let store = FakeStore()
        let host = Host()
        let runner = makeRunner(store: store, host: host, approveMemory: false)
        await runner.run(userText: "Je m'appelle Dimitri")
        XCTAssertTrue(store.facts.isEmpty)
        // Le tour se termine quand même normalement.
        XCTAssertFalse(host.isStreaming)
        XCTAssertTrue(host.errors.isEmpty)
    }

    func testSystemPromptBuilderStable() {
        let prompt = ConversationTurnRunner.buildSystemPrompt(dateStr: "24/09/2026", factsContext: "")
        XCTAssertTrue(prompt.contains("Tu es Jarvis"))
        XCTAssertTrue(prompt.contains("24/09/2026"))
        // Intent mappings conservés (exemples), mais plus de dump de la doc
        // des outils — le modèle le recopiat au lieu d'appeler.
        XCTAssertTrue(prompt.contains("search_web"))
        XCTAssertFalse(prompt.contains("(requis:"))
    }

    /// LLM scriptable : première réponse = écho de la liste d'outils (cas réel),
    /// puis réponse normale après la relance anti-écho.
    final class ScriptLLM: LLMProvider, @unchecked Sendable {
        var script: [String]
        private var index = 0
        init(script: [String]) { self.script = script }
        func streamChat(messages: [OllamaMessage], tools: [ToolDef]?) -> AsyncThrowingStream<OllamaStreamEvent, Error> {
            let text = script[min(index, script.count - 1)]
            index += 1
            return AsyncThrowingStream { continuation in
                continuation.yield(.delta(text))
                continuation.yield(.finished(truncated: false))
                continuation.finish()
            }
        }
    }

    private func makeScriptedRunner(
        store: FakeStore = FakeStore(),
        host: Host = Host(),
        script: [String],
        tools: any ToolExecutor = FakeTools()
    ) -> ConversationTurnRunner {
        let facts = FactsExtractionCoordinator(
            db: store,
            requestConfirmation: { _ in true },
            didUpdateFacts: { host.facts = $0 },
            reportError: { host.errors.append($0) }
        )
        return ConversationTurnRunner(
            db: store,
            llm: ScriptLLM(script: script),
            tools: tools,
            settings: FakeSettings(),
            facts: facts,
            sensitiveTools: ["sleep_mac"],
            cb: TurnCallbacks(
                appendTrace: { host.trace.append($0) },
                speak: { host.spoken.append($0) },
                notifyFinished: { host.notified.append($0) },
                auditTool: { _, _, _, _, _ in }
            ),
            ui: TurnUI(
                ensureDBOpen: {},
                ensureConversationId: { [store] in
                    if store.conversations.isEmpty {
                        let c = try? await store.createConversation(title: "Test")
                        return c?.id
                    }
                    return store.conversations.first?.id
                },
                appendMessage: { host.messages.append($0) },
                setStreaming: { host.isStreaming = $0 },
                setStreamingText: { host.streamingText = $0 },
                resetTrace: { host.trace = [] },
                reportError: { host.errors.append($0) },
                setFacts: { host.facts = $0 }
            )
        )
    }

    func testToolListEchoRetriedThenAnswered() async {
        // Tour 1 : écho → relance anti-écho → vraie réponse persistée, pas l'écho.
        let store = FakeStore()
        let host = Host()
        let runner = makeScriptedRunner(store: store, host: host, script: [
            "search_web → Recherche sur le web. (requis: query)",
            "Voici la réponse."
        ])
        await runner.run(userText: "cherche l'actu")
        let stored = (try? await store.getMessages(conversationId: 1)) ?? []
        let assistants = stored.filter { $0.role == "assistant" }
        XCTAssertFalse(assistants.isEmpty)
        XCTAssertTrue(assistants.allSatisfy { !$0.content.contains("(requis:") },
                      "l'écho ne doit jamais être persisté : \(assistants.map(\.content))")
        XCTAssertTrue(assistants.last?.content.contains("Voici la réponse.") ?? false)
    }

    func testPersistentEchoSavedAsFallback() async {
        // Écho à chaque itération : budget épuisé → aveu neutre persisté, pas l'écho.
        let store = FakeStore()
        let host = Host()
        let runner = makeScriptedRunner(store: store, host: host, script: [
            "search_web → Recherche sur le web. (requis: query)"
        ])
        await runner.run(userText: "cherche l'actu")
        let stored = (try? await store.getMessages(conversationId: 1)) ?? []
        let assistants = stored.filter { $0.role == "assistant" }
        XCTAssertFalse(assistants.isEmpty)
        XCTAssertTrue(assistants.allSatisfy { !$0.content.contains("(requis:") })
        XCTAssertTrue(assistants.last?.content.contains("Reformule") ?? false)
    }

    /// Outils scriptés avec définitions : la récupération des pseudo-appels
    /// a besoin des noms valides (FakeTools de base n'en expose aucun).
    final class FakeToolsWithDefs: ToolExecutor, @unchecked Sendable {
        var executed: [String] = []
        func execute(name: String, args: [String: Any]) async throws -> String {
            executed.append(name)
            return "fake-result:\(name)"
        }
        func effectiveToolDefs() async -> [ToolDef] {
            [ToolDef(function: ToolFunction(
                name: "search_web",
                description: "Recherche sur le web.",
                parameters: ToolParameters(
                    properties: ["query": ToolProperty(type: "string", description: "Requête")],
                    required: ["query"])))]
        }
    }

    func testPseudoCallRecoveredAndExecuted() async {
        // Cas réel : le modèle écrit `search_web(query="…")` au lieu d'appeler.
        // Attendu : exécuté comme un vrai appel, écho jamais persisté.
        let store = FakeStore()
        let host = Host()
        let tools = FakeToolsWithDefs()
        let runner = makeScriptedRunner(store: store, host: host, script: [
            "search_web(query=\"actu tech\")",
            "Voici les résultats."
        ], tools: tools)
        await runner.run(userText: "cherche l'actu")
        XCTAssertTrue(tools.executed.contains("search_web"), "le pseudo-appel doit être exécuté")
        XCTAssertTrue(host.trace.contains("search_web"))
        let stored = (try? await store.getMessages(conversationId: 1)) ?? []
        let assistants = stored.filter { $0.role == "assistant" }
        XCTAssertTrue(assistants.allSatisfy { !$0.content.contains("search_web(query=") },
                      "l'écho ne doit jamais être persisté : \(assistants.map(\.content))")
        XCTAssertTrue(assistants.last?.content.contains("Voici les résultats.") ?? false)
    }

    func testBareCallRecoveredAndExecuted() async {
        // Forme nue (`get_weather city: Paris`, miroir des exemples du prompt).
        let store = FakeStore()
        let host = Host()
        let tools = FakeToolsWithDefs()
        let runner = makeScriptedRunner(store: store, host: host, script: [
            "search_web query: actu tech",
            "Voici les résultats."
        ], tools: tools)
        await runner.run(userText: "cherche l'actu")
        XCTAssertTrue(tools.executed.contains("search_web"))
        let stored = (try? await store.getMessages(conversationId: 1)) ?? []
        XCTAssertTrue(stored.filter { $0.role == "assistant" }
            .allSatisfy { !$0.content.contains("search_web query:") })
    }
}
