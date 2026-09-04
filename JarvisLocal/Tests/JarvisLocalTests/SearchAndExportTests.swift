@testable import JarvisLocal
import XCTest

@MainActor
final class JarvisLocalSearchAndExportTests: XCTestCase {

    var viewModel: AppViewModel!

    override func setUp() async throws {
        try await super.setUp()
        viewModel = AppViewModel()
        try await viewModel.db.open(path: ":memory:")
        // Empêche ensureDBOpen() de rouvrir la base fichier par défaut à la place de :memory:
        viewModel.didOpenDB = true
    }

    // MARK: - Recherche

    func testSearchFindsMessageAcrossConversations() async {
        let conv = try! await viewModel.db.createConversation(title: "Météo")
        _ = try? await viewModel.db.insertMessage(role: "user", content: "Quel temps fait-il à Toulouse ?", conversationId: conv.id)
        _ = try? await viewModel.db.insertMessage(role: "assistant", content: "Il fait beau.", conversationId: conv.id)

        await viewModel.search("Toulouse")
        XCTAssertEqual(viewModel.searchResults.count, 1)
        XCTAssertEqual(viewModel.searchResults.first?.conversationTitle, "Météo")
        XCTAssertTrue(viewModel.searchResults.first?.content.contains("Toulouse") == true)
    }

    func testSearchEmptyQueryClearsResults() async {
        await viewModel.search("")
        XCTAssertTrue(viewModel.searchResults.isEmpty)
    }

    func testSearchNoResults() async {
        await viewModel.search("motintrouvablexyz123")
        XCTAssertTrue(viewModel.searchResults.isEmpty)
    }

    // MARK: - Export Markdown

    func testExportMarkdownContainsTitleAndMessages() async {
        let conv = try! await viewModel.db.createConversation(title: "Test export")
        _ = try? await viewModel.db.insertMessage(role: "user", content: "Bonjour", conversationId: conv.id)
        _ = try? await viewModel.db.insertMessage(role: "assistant", content: "Salut !", conversationId: conv.id)

        await viewModel.selectConversation(conv)

        let md = viewModel.exportConversationAsMarkdown()
        XCTAssertNotNil(md)
        XCTAssertTrue(md!.contains("# Test export"))
        XCTAssertTrue(md!.contains("Bonjour"))
        XCTAssertTrue(md!.contains("Salut !"))
        XCTAssertTrue(md!.contains("**Vous**"))
        XCTAssertTrue(md!.contains("**Jarvis**"))
    }

    func testExportMarkdownReturnsNilForEmptyConversation() {
        XCTAssertNil(viewModel.exportConversationAsMarkdown())
    }

    // MARK: - Export JSON

    func testExportJSONIsValid() async {
        let conv = try! await viewModel.db.createConversation(title: "JSON test")
        _ = try? await viewModel.db.insertMessage(role: "user", content: "Premier message", conversationId: conv.id)

        await viewModel.selectConversation(conv)

        let json = viewModel.exportConversationAsJSON()
        XCTAssertNotNil(json)

        let data = json!.data(using: .utf8)!
        let parsed = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(parsed["title"] as? String, "JSON test")
        let msgs = parsed["messages"] as! [[String: Any]]
        XCTAssertEqual(msgs.count, 1)
        XCTAssertEqual(msgs[0]["role"] as? String, "user")
        XCTAssertEqual(msgs[0]["content"] as? String, "Premier message")
    }

    func testExportJSONReturnsNilForEmptyConversation() {
        XCTAssertNil(viewModel.exportConversationAsJSON())
    }
}
