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
        let prompt = ConversationTurnRunner.buildSystemPrompt(dateStr: "24/09/2026", toolList: "• search_web → cherche", factsContext: "")
        XCTAssertTrue(prompt.contains("Tu es Jarvis"))
        XCTAssertTrue(prompt.contains("24/09/2026"))
        XCTAssertTrue(prompt.contains("search_web"))
    }
}
