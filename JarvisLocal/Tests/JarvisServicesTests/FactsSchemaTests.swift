@testable import JarvisServices
import XCTest

/// Étape 3 : migration v3 des faits (source, confidence, created_at, status,
/// superseded_by) + non-régression des chemins historiques.
/// FactExtractor n'est PAS touché par cette étape (cadrage).
final class FactsSchemaTests: XCTestCase {
    private func freshDB() async throws -> DatabaseService {
        let db = DatabaseService.shared
        try await db.open(path: ":memory:")
        return db
    }

    func testMigrationReachesVersion3() async throws {
        let db = try await freshDB()
        let version = try await db.userVersion()
        XCTAssertEqual(version, 3)
    }

    func testV3ColumnsExist() async throws {
        let db = try await freshDB()
        for col in ["source_message_id", "confidence", "created_at", "status", "superseded_by"] {
            let exists = try await db.hasColumn(table: "facts", column: col)
            XCTAssertTrue(exists, "colonne manquante : \(col)")
        }
    }

    /// Chemin historique : upsertFact(key:value:) sans les nouveaux champs —
    /// défauts sains, created_at renseigné par unixepoch() (jamais 1970).
    func testLegacyUpsertGetsSaneDefaults() async throws {
        let db = try await freshDB()
        try await db.upsertFact(key: "user.name", value: "Dimitri")
        let fact = try await db.getFact(key: "user.name")!
        XCTAssertEqual(fact.value, "Dimitri")
        XCTAssertNil(fact.sourceMessageId)
        XCTAssertEqual(fact.confidence, 1.0)
        XCTAssertEqual(fact.status, .active)
        XCTAssertNil(fact.supersededBy)
        XCTAssertGreaterThan(fact.createdAt.timeIntervalSince1970, 1_700_000_000)
    }

    func testSourceAndConfidenceRoundTrip() async throws {
        let db = try await freshDB()
        let conv = try await db.createConversation(title: "T")
        let msg = try await db.insertMessage(role: "user", content: "Je m'appelle Dimitri", conversationId: conv.id)
        try await db.upsertFact(key: "user.name", value: "Dimitri", sourceMessageId: msg.id, confidence: 0.7)
        let fact = try await db.getFact(key: "user.name")!
        XCTAssertEqual(fact.sourceMessageId, msg.id)
        XCTAssertEqual(fact.confidence, 0.7, accuracy: 1e-9)
    }

    func testConfidenceClampedToUnitRange() async throws {
        let db = try await freshDB()
        try await db.upsertFact(key: "a", value: "1", sourceMessageId: nil, confidence: 2.5)
        try await db.upsertFact(key: "b", value: "2", sourceMessageId: nil, confidence: -0.3)
        let high = try await db.getFact(key: "a")!
        let low = try await db.getFact(key: "b")!
        XCTAssertEqual(high.confidence, 1.0, accuracy: 1e-9)
        XCTAssertEqual(low.confidence, 0.0, accuracy: 1e-9)
    }

    func testSupersedeFlow() async throws {
        let db = try await freshDB()
        try await db.upsertFact(key: "user.city", value: "Paris")
        try await db.upsertFact(key: "user.city.new", value: "Lyon")
        let newer = try await db.getFact(key: "user.city.new")!
        try await db.supersedeFact(key: "user.city", byFactId: newer.id)
        let old = try await db.getFact(key: "user.city")!
        XCTAssertEqual(old.status, .superseded)
        XCTAssertEqual(old.supersededBy, newer.id)
        XCTAssertEqual(newer.status, .active)
        // getAllFacts voit les deux : l'exclusion du contexte est de
        // l'exploitation, pas du stockage.
        let all = try await db.getAllFacts()
        XCTAssertEqual(all.count, 2)
    }

    /// Un upsert EST une réaffirmation : il ressuscite un fait superseded en active.
    func testUpsertReaffirmsSupersededFact() async throws {
        let db = try await freshDB()
        try await db.upsertFact(key: "k", value: "v1")
        let first = try await db.getFact(key: "k")!
        try await db.supersedeFact(key: "k", byFactId: first.id)
        try await db.upsertFact(key: "k", value: "v2")
        let reaffirmed = try await db.getFact(key: "k")!
        XCTAssertEqual(reaffirmed.status, .active)
        XCTAssertNil(reaffirmed.supersededBy)
        XCTAssertEqual(reaffirmed.value, "v2")
    }

    func testGetFactUnknownKeyReturnsNil() async throws {
        let db = try await freshDB()
        let missing = try await db.getFact(key: "nope")
        XCTAssertNil(missing)
    }
}
