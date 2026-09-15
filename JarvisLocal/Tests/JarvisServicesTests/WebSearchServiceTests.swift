@testable import JarvisServices
import XCTest
import Foundation

final class WebSearchServiceTests: XCTestCase {
    func testParseLegacyRegexParsesOldMarkup() {
        let html = #"<a class="result-link" href="https://example.com/x">Hello</a>"#
        let got = WebSearchService.parseLegacyRegex(html)
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].title, "Hello")
        XCTAssertEqual(got[0].href, "https://example.com/x")
    }

    func testParseLegacyRegexReturnsEmptyOnUnknownMarkup() {
        XCTAssertTrue(WebSearchService.parseLegacyRegex("<html><p>rien</p></html>").isEmpty)
    }

    func testParseLegacyRegexStripsInnerHTML() {
        // Le pattern nofollow capture du HTML interne : strippedHTML doit nettoyer.
        let html = #"<a rel="nofollow" href="https://example.com/y"><b>Bold</b></a>"#
        let got = WebSearchService.parseLegacyRegex(html)
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].title, "Bold")
    }

    func testParseDOMStaticNeverCrashes() {
        // Ne doit jamais throw/crasher, avec ou sans SwiftSoup.
        // Sans SwiftSoup : retourne [] et laisse le fallback regex prendre le relais.
        let html = """
        <html><body>
        <a class="result-link" href="https://example.com/a">Titre A</a>
        <a class="result-link" href="https://example.com/b">Titre B</a>
        </body></html>
        """
        let base = URL(string: "https://lite.duckduckgo.com/lite/")!
        let got = WebSearchService.parseDOMStatic(html, base: base)
        XCTAssertTrue(got.isEmpty || got.count == 2)
        if !got.isEmpty {
            XCTAssertEqual(got[0].title, "Titre A")
            XCTAssertTrue(got[0].href.contains("example.com"))
        }
    }

    func testFormatIncludesSourceURL() {
        let out = WebSearchService.format([
            (title: "T", href: "https://example.com/p", text: "Contenu"),
            (title: "V", href: "https://example.com/v", text: nil)
        ])
        XCTAssertTrue(out.contains("Source : https://example.com/p"))
        XCTAssertTrue(out.contains("--- V ---"))
        // Pas de ligne "Contenu :" pour le résultat sans texte.
        XCTAssertEqual(out.components(separatedBy: "Contenu :").count - 1, 1)
    }

    func testFormatSearchResultsAliasInToolService() {
        // Alias de compat : l'ancien entry-point reste vert pendant la migration.
        let out = ToolService.formatSearchResults([
            (title: "Exemple", href: "https://example.com/page", text: "Utile")
        ])
        XCTAssertTrue(out.contains("Source : https://example.com/page"))
    }

    func testSearchEmptyQueryReturnsGuidance() async {
        let out = await WebSearchService.shared.search(query: "   ")
        XCTAssertTrue(out.contains("Requête vide"))
    }
}
