@testable import JarvisUI
@testable import JarvisServices
import JarvisCore
import XCTest

/// Tests du FactsExtractionCoordinator (découpage AppViewModel, étape 1).
/// Même style que AppViewModelTests : vraie DB `:memory:`, confirmations simulées.
@MainActor
final class FactsExtractionCoordinatorTests: XCTestCase {

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

    private func makeCoordinator(
        confirm: @escaping (String) async -> Bool = { _ in true },
        announced: (any Actor)? = nil,
        updated: Box<[Fact]>? = nil,
        errors: Box<[String]>? = nil
    ) -> FactsExtractionCoordinator {
        FactsExtractionCoordinator(
            db: viewModel.db,
            requestConfirmation: confirm,
            announceVoice: {},
            didUpdateFacts: { updated?.value = $0 },
            reportError: { errors?.value.append($0) }
        )
    }
    func testCoordinatorExtractsNameLikeViewModel() {
        let c = makeCoordinator()
        let found = c.extractCandidateFacts(from: "Je m'appelle Dimitri")
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.key, "user.name")
        XCTAssertEqual(found.first?.value, "Dimitri")
        // Parité avec le forwarder historique du ViewModel.
        let legacy = viewModel.extractCandidateFacts(from: "Je m'appelle Dimitri")
        XCTAssertEqual(found.map { $0.key }, legacy.map { $0.key })
        XCTAssertEqual(found.map { $0.value }, legacy.map { $0.value })
    }

    func testConfirmPersistsFact() async {
        let box = Box<[Fact]>([])
        let c = makeCoordinator(updated: box)
        await c.extractAndConfirmFacts(from: "Je m'appelle Dimitri")
        let stored = try? await viewModel.db.getAllFacts()
        XCTAssertEqual(stored?.first(where: { $0.key == "user.name" })?.value, "Dimitri")
        XCTAssertEqual(box.value.first(where: { $0.key == "user.name" })?.value, "Dimitri")
    }

    func testRefusalPersistsNothing() async {
        let c = makeCoordinator(confirm: { _ in false })
        await c.extractAndConfirmFacts(from: "Je m'appelle Dimitri")
        let stored = try? await viewModel.db.getAllFacts()
        XCTAssertTrue(stored?.isEmpty ?? false)
    }

    func testKnownFactNotReasked() async {
        try? await viewModel.db.upsertFact(key: "user.name", value: "Dimitri")
        var asked = 0
        let c = makeCoordinator(confirm: { _ in asked += 1; return true })
        await c.extractAndConfirmFacts(from: "Je m'appelle Dimitri")
        XCTAssertEqual(asked, 0)
    }

    func testNoCandidateNoConfirmation() async {
        var asked = 0
        let c = makeCoordinator(confirm: { _ in asked += 1; return true })
        await c.extractAndConfirmFacts(from: "quel temps fait-il ?")
        XCTAssertEqual(asked, 0)
    }

    func testLoadFactsReturnsStored() async {
        try? await viewModel.db.upsertFact(key: "user.city", value: "Paris")
        let c = makeCoordinator()
        let facts = await c.loadFacts()
        XCTAssertEqual(facts.first(where: { $0.key == "user.city" })?.value, "Paris")
    }

    func testDeleteFactRemovesAndReports() async {
        try? await viewModel.db.upsertFact(key: "user.city", value: "Paris")
        let box = Box<[Fact]>([])
        let c = makeCoordinator(updated: box)
        let stored = try? await viewModel.db.getAllFacts()
        guard let fact = stored?.first(where: { $0.key == "user.city" }) else {
            XCTFail("fait non inséré"); return
        }
        await c.deleteFact(fact)
        let after = try? await viewModel.db.getAllFacts()
        XCTAssertTrue(after?.isEmpty ?? false)
        XCTAssertTrue(box.value.isEmpty)
    }

    func testClearAllFactsEmpties() async {
        try? await viewModel.db.upsertFact(key: "user.city", value: "Paris")
        try? await viewModel.db.upsertFact(key: "user.name", value: "Dimitri")
        let box = Box<[Fact]>([Fact(id: -1, key: "x", value: "y", updatedAt: Date())])
        let c = makeCoordinator(updated: box)
        await c.clearAllFacts()
        let after = try? await viewModel.db.getAllFacts()
        XCTAssertTrue(after?.isEmpty ?? false)
        XCTAssertTrue(box.value.isEmpty)
    }
}

/// Mini boîte mutable pour capturer les callbacks dans les tests.
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
