@testable import JarvisCore
import XCTest

/// Chantier 2 : FactExtractor pur, testé sans ViewModel ni DB.
/// Verrouille le comportement à l'identique de l'ancien code embarqué
/// (cas réel « je suis dimitri », filtre anti-bruit, élagage liaisons).
final class FactExtractorTests: XCTestCase {
    func testExtractNameJeSuis() {
        let got = FactExtractor().extract(from: "je suis Dimitri")
        XCTAssertTrue(got.contains { $0.key == "user.name" && $0.value == "Dimitri" })
    }

    func testExtractNameTrimsTrailingLinker() {
        // "je suis dimitri et toi ?" capturait "dimitri et" — on élague.
        let got = FactExtractor().extract(from: "je suis dimitri et toi ?")
        XCTAssertTrue(got.contains { $0.key == "user.name" && $0.value.lowercased() == "dimitri" })
    }

    func testExcludesNoiseStates() {
        // États / locutions : pas de popup.
        for text in ["je suis d'accord", "je suis en retard", "je suis fatigué", "je suis développeur"] {
            let got = FactExtractor().extract(from: text)
            XCTAssertFalse(got.contains { $0.key == "user.name" }, "Faux positif nom pour : \(text)")
        }
    }

    func testExtractCity() {
        let got = FactExtractor().extract(from: "j'habite à Paris")
        XCTAssertTrue(got.contains { $0.key == "user.city" && $0.value == "Paris" })
    }

    func testExtractBirthday() {
        let got = FactExtractor().extract(from: "Je suis né le 15 mai 1990")
        XCTAssertTrue(got.contains { $0.key == "user.birthday" })
    }

    func testIsExcludedNameValue() {
        XCTAssertTrue(FactExtractor.isExcludedNameValue("d'accord"))
        XCTAssertTrue(FactExtractor.isExcludedNameValue("développeur"))
        XCTAssertFalse(FactExtractor.isExcludedNameValue("Dimitri"))
    }

    func testTrimNameTrailingStoppers() {
        XCTAssertEqual(FactExtractor.trimNameTrailingStoppers("Dimitri et"), "Dimitri")
        XCTAssertEqual(FactExtractor.trimNameTrailingStoppers("Dimitri"), "Dimitri")
    }

    func testNormalizeNameToken() {
        XCTAssertEqual(FactExtractor.normalizeNameToken("D'Accord"), "daccord")
    }
}
