@testable import JarvisUI
import XCTest

/// Phase 0 : le contrat de mémorisation du rendu riche — l'égalité porte sur le
/// seul texte, c'est ce qui fait sauter le re-parse des bulles figées.
final class RichTextCacheTests: XCTestCase {
    func testEqualTextsAreEqual() {
        XCTAssertEqual(AssistantRichText(text: "hello"), AssistantRichText(text: "hello"))
    }

    func testDifferentTextsAreNotEqual() {
        XCTAssertNotEqual(AssistantRichText(text: "a"), AssistantRichText(text: "b"))
    }
}
