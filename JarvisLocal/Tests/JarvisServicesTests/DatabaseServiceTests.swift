@testable import JarvisServices
import XCTest

// MARK: - DatabaseService
final class JarvisLocalDatabaseServiceTests: XCTestCase {
    func testOpenInMemory() async throws {
        let db = DatabaseService.shared
        try await db.open(path: ":memory:")
    }

    /// Les migrations versionnées (PRAGMA user_version) atteignent le schéma courant
    /// sur une base neuve, seed "Général" inclus.
    func testMigrationsReachCurrentVersion() async throws {
        let db = DatabaseService.shared
        try await db.open(path: ":memory:")
        let version = try await db.userVersion()
        XCTAssertEqual(version, 3)
        let convs = try await db.getAllConversations()
        XCTAssertFalse(convs.isEmpty)
    }

    /// Non-régression : une conversation avec activité d'outils (tool_runs) doit
    /// se supprimer sans erreur FOREIGN KEY (foreign_keys=ON + anciennes bases
    /// sans ON DELETE CASCADE). Le journal part avec la conversation.
    func testDeleteConversationWithToolRuns() async throws {
        let db = DatabaseService.shared
        try await db.open(path: ":memory:")
        let conv = try await db.createConversation(title: "À supprimer")
        try await db.logToolRun(conversationId: conv.id, tool: "search_web", args: "q=test", status: "✓", result: "ok")
        try await db.deleteConversation(id: conv.id)
        let fetched = try await db.getConversation(id: conv.id)
        XCTAssertNil(fetched)
        let runs = try await db.getRecentToolRuns()
        XCTAssertTrue(runs.isEmpty)
    }

    func testCreateAndGetConversation() async throws {
        let db = DatabaseService.shared
        try await db.open(path: ":memory:")
        let conv = try await db.createConversation(title: "Test")
        XCTAssertEqual(conv.title, "Test")
        XCTAssertGreaterThan(conv.id, 0)
        let fetched = try await db.getConversation(id: conv.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.title, "Test")
    }

    func testInsertAndGetMessages() async throws {
        let db = DatabaseService.shared
        try await db.open(path: ":memory:")
        let conv = try await db.createConversation(title: "Test")
        let msg = try await db.insertMessage(role: "user", content: "Bonjour", conversationId: conv.id)
        XCTAssertEqual(msg.role, "user")
        XCTAssertEqual(msg.content, "Bonjour")
        let msgs = try await db.getMessages(conversationId: conv.id)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs.first?.content, "Bonjour")
    }

    func testFactsCRUD() async throws {
        let db = DatabaseService.shared
        try await db.open(path: ":memory:")
        try await db.upsertFact(key: "user.name", value: "Dimitri")
        let facts = try await db.getAllFacts()
        XCTAssertEqual(facts.count, 1)
        XCTAssertEqual(facts.first?.key, "user.name")
        XCTAssertEqual(facts.first?.value, "Dimitri")
        try await db.deleteFact(key: "user.name")
        let after = try await db.getAllFacts()
        XCTAssertTrue(after.isEmpty)
    }

    func testDeleteConversationCascadesMessages() async throws {
        let db = DatabaseService.shared
        try await db.open(path: ":memory:")
        let conv = try await db.createConversation(title: "A Supprimer")
        _ = try await db.insertMessage(role: "user", content: "msg", conversationId: conv.id)
        try await db.deleteConversation(id: conv.id)
        let fetched = try await db.getConversation(id: conv.id)
        XCTAssertNil(fetched)
        let msgs = try await db.getMessages(conversationId: conv.id)
        XCTAssertTrue(msgs.isEmpty)
    }

    /// Non-régression SQLITE_TRANSIENT : une chaîne longue + unicode écrite puis relue
    /// immédiatement doit revenir à l'identique. Avec l'ancien bind en SQLITE_STATIC (nil)
    /// sur un pointeur NSString temporaire, le contenu pouvait être corrompu entre le bind
    /// et le step — ce test écrit et relit dans la foulée pour l'exposer.
    func testLongUnicodeStringRoundTripNoCorruption() async throws {
        let db = DatabaseService.shared
        try await db.open(path: ":memory:")
        let conv = try await db.createConversation(title: "Unicode 🇫🇷 café — 日本語テスト 🎉")
        // Chaîne longue (> quelques Ko, multi-plans unicode : emojis, CJK, accents, ZWJ).
        let chunk = "Héllo wörld 🌍🚀 café — 日本語テスト 👨‍👩‍👧‍👦 ñ€ü "
        let longContent = String(repeating: chunk, count: 300)
        XCTAssertGreaterThan(longContent.count, 5000)
        let inserted = try await db.insertMessage(role: "user", content: longContent, conversationId: conv.id)
        XCTAssertEqual(inserted.content, longContent)
        // Relecture immédiate : sans SQLITE_TRANSIENT, le buffer temporaire pouvait déjà
        // avoir été réutilisé/libéré au moment du step, et le contenu relu divergeait.
        let msgs = try await db.getMessages(conversationId: conv.id)
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs.first?.content, longContent)
        // Même vérification via les facts (autre chemin d'exec avec params).
        try await db.upsertFact(key: "test.unicode", value: longContent)
        let facts = try await db.getAllFacts()
        XCTAssertEqual(facts.first(where: { $0.key == "test.unicode" })?.value, longContent)
    }
}
