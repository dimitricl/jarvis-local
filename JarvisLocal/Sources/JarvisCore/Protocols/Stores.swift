import Foundation

/// L0 — contrats de persistance. Zéro SQLite ici : ces protocols décrivent CE QUE
/// l'UI attend du stockage, pas COMMENT c'est stocké.
///
/// Implémentation concrète : DatabaseService (JarvisServices), seul module
/// autorisé à importer SQLite3. DatabaseService est `internal` à JarvisServices :
/// JarvisUI ne peut donc le nommer que via ces protocols — toute tentative
/// d'accès direct casse à la compilation.
///
/// `open(path:)` expose un chemin optionnel (nil = emplacement par défaut).
/// Ce n'est pas un détail de test : choisir l'emplacement du stockage (base
/// par défaut, :memory:, export) est une capacité légitime du store.

public struct MessageSearchResult: Sendable, Hashable {
    public let message: Message
    public let conversationTitle: String

    public init(message: Message, conversationTitle: String) {
        self.message = message
        self.conversationTitle = conversationTitle
    }
}

public protocol ConversationStore {
    func open(path: String?) async throws
    func getAllConversations() async throws -> [Conversation]
    func getConversation(id: Int) async throws -> Conversation?
    func createConversation(title: String) async throws -> Conversation
    func updateConversationTitle(id: Int, title: String) async throws
    func deleteConversation(id: Int) async throws
    func getMessages(conversationId: Int, limit: Int) async throws -> [Message]
    func insertMessage(role: String, content: String, conversationId: Int?) async throws -> Message
}

public extension ConversationStore {
    func createConversation() async throws -> Conversation {
        try await createConversation(title: "Nouvelle conversation")
    }

    func getMessages(conversationId: Int) async throws -> [Message] {
        try await getMessages(conversationId: conversationId, limit: 50)
    }
}

public protocol FactsStore {
    func getAllFacts() async throws -> [Fact]
    func upsertFact(key: String, value: String) async throws
    func deleteFact(key: String) async throws
    func deleteAllFacts() async throws
}

public protocol ToolRunStore {
    func logToolRun(conversationId: Int?, tool: String, args: String, status: String, result: String) async throws
    func getRecentToolRuns(limit: Int) async throws -> [ToolRun]
}

public extension ToolRunStore {
    func getRecentToolRuns() async throws -> [ToolRun] {
        try await getRecentToolRuns(limit: 100)
    }
}

public protocol MessageSearchStore {
    func searchMessages(_ query: String) async throws -> [MessageSearchResult]
}

/// Composition : le ViewModel ne retient qu'UNE dépendance de persistance,
/// typée par ces contrats — jamais par un type concret de JarvisServices.
public typealias PersistentStore = ConversationStore & FactsStore & ToolRunStore & MessageSearchStore
