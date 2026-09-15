@testable import JarvisUI
import JarvisCore
import Observation
import XCTest

// NOTE : ce fichier n'importe PAS JarvisServices — volontairement.
// C'est la preuve checklist de l'étape 1 : JarvisUI s'instancie et fonctionne
// sur les seuls contrats Core, avec des fakes écrits en quelques lignes.

// MARK: - Fakes

final class FakeStore: ConversationStore, FactsStore, ToolRunStore, MessageSearchStore {
    var conversations: [Conversation] = [
        Conversation(id: 1, title: "Général", createdAt: Date(), updatedAt: Date())
    ]
    var messagesByConversation: [Int: [Message]] = [:]
    var facts: [Fact] = []
    var toolRuns: [ToolRun] = []
    var nextId = 100

    func open(path: String?) async throws {}
    func getAllConversations() async throws -> [Conversation] { conversations }
    func getConversation(id: Int) async throws -> Conversation? {
        conversations.first { $0.id == id }
    }
    func createConversation(title: String) async throws -> Conversation {
        nextId += 1
        let conv = Conversation(id: nextId, title: title, createdAt: Date(), updatedAt: Date())
        conversations.insert(conv, at: 0)
        return conv
    }
    func updateConversationTitle(id: Int, title: String) async throws {
        if let i = conversations.firstIndex(where: { $0.id == id }) { conversations[i].title = title }
    }
    func deleteConversation(id: Int) async throws {
        conversations.removeAll { $0.id == id }
        messagesByConversation[id] = nil
    }
    func getMessages(conversationId: Int, limit: Int) async throws -> [Message] {
        Array((messagesByConversation[conversationId] ?? []).suffix(limit))
    }
    func insertMessage(role: String, content: String, conversationId: Int?) async throws -> Message {
        nextId += 1
        let msg = Message(id: nextId, role: role, content: content, conversationId: conversationId, createdAt: Date())
        if let cid = conversationId { messagesByConversation[cid, default: []].append(msg) }
        return msg
    }
    func getAllFacts() async throws -> [Fact] { facts }
    func upsertFact(key: String, value: String) async throws {
        nextId += 1
        facts.removeAll { $0.key == key }
        facts.append(Fact(id: nextId, key: key, value: value, updatedAt: Date()))
    }
    func deleteFact(key: String) async throws { facts.removeAll { $0.key == key } }
    func deleteAllFacts() async throws { facts = [] }
    func logToolRun(conversationId: Int?, tool: String, args: String, status: String, result: String) async throws {
        nextId += 1
        toolRuns.append(ToolRun(id: nextId, tool: tool, args: args, status: status,
                                result: result, conversationId: conversationId, createdAt: Date()))
    }
    func getRecentToolRuns(limit: Int) async throws -> [ToolRun] {
        Array(toolRuns.suffix(limit).reversed())
    }
    func searchMessages(_ query: String) async throws -> [MessageSearchResult] {
        guard !query.isEmpty else { return [] }
        var out: [MessageSearchResult] = []
        for conv in conversations {
            for msg in messagesByConversation[conv.id] ?? [] where msg.content.contains(query) {
                out.append(MessageSearchResult(message: msg, conversationTitle: conv.title))
            }
        }
        return out
    }
}

struct FakeLLM: LLMProvider {
    func streamChat(messages: [OllamaMessage], tools: [ToolDef]?) -> AsyncThrowingStream<OllamaStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.delta("Bonjour (fake)"))
            continuation.yield(.finished(truncated: false))
            continuation.finish()
        }
    }
}

struct FakeTools: ToolExecutor {
    func execute(name: String, args: [String: Any]) async throws -> String { "fake:\(name)" }
    func effectiveToolDefs() async -> [ToolDef] { [] }
}

struct FakeTTS: TTSEngine {
    func speak(_ text: String) async {}
    func enqueue(_ text: String) {}
    func stopSpeaking() {}
    var isSpeaking: Bool { false }
}

final class FakeSTT: STTEngine {
    var onPartialResult: ((String) -> Void)?
    func transcribe() async throws -> String { "transcription fake" }
    func cancel() {}
}

@Observable
final class FakeSettings: AppSettingsProtocol {
    var ollamaURL = "http://localhost:11434"
    var model = "fake-model"
    var fastModel = "fake-fast"
    var reasoningEffort = "none"
    var numCtx = 16384
    var maxTokens = 4096
    var temperature = 0.7
    var ttsEnabled = false
    var voiceEnabled = false
    var ttsVoiceIdentifier = ""
    var bargeInEnabled = false
    var mcpEnabled = false
    var imcpPath = ""
    var launchAtLogin = false
    var isCheckingUpdate = false
    var updateCheckError: String?
    var updateAvailable = false
    var ollamaHostIsLocal: Bool { true }
    var currentVersion: String { "test" }
    var frenchVoiceOptions: [VoiceOption] { [] }
    func checkForUpdates(repoOwner: String, repoName: String) async {}
}

// MARK: - Preuve d'injection

@MainActor
final class FakeInjectionTests: XCTestCase {
    private func makeViewModel(store: FakeStore = FakeStore()) -> (AppViewModel, FakeStore) {
        let vm = AppViewModel(
            db: store,
            ollama: FakeLLM(),
            tools: FakeTools(),
            audio: FakeTTS(),
            stt: FakeSTT(),
            settings: FakeSettings()
        )
        vm.didOpenDB = true
        return (vm, store)
    }

    func testConversationsFlowOnFakeStore() async {
        let (vm, _) = makeViewModel()
        await vm.loadConversations()
        XCTAssertEqual(vm.conversations.count, 1)
        await vm.newConversation()
        XCTAssertEqual(vm.conversations.count, 2)
        XCTAssertNotNil(vm.currentConversation)
    }

    func testFactsFlowOnFakeStore() async {
        let (vm, store) = makeViewModel()
        try? await store.upsertFact(key: "user.name", value: "Fake")
        await vm.loadFacts()
        XCTAssertEqual(vm.facts.count, 1)
        XCTAssertEqual(vm.facts.first?.value, "Fake")
    }

    func testSearchFlowOnFakeStore() async {
        let (vm, store) = makeViewModel()
        let conv = try! await store.createConversation(title: "Météo")
        _ = try? await store.insertMessage(role: "user", content: "Quel temps à Toulouse ?", conversationId: conv.id)
        await vm.search("Toulouse")
        XCTAssertEqual(vm.searchResults.count, 1)
        XCTAssertEqual(vm.searchResults.first?.conversationTitle, "Météo")
    }

    func testSettingsInjectedThroughProtocol() async {
        let (vm, _) = makeViewModel()
        XCTAssertEqual(vm.modelName, "fake-model")
    }
}
