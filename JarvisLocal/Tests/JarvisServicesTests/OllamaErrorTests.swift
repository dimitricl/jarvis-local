@testable import JarvisServices
import Foundation
import XCTest

// MARK: - OllamaError
final class JarvisLocalOllamaErrorTests: XCTestCase {
    func testInvalidURLDescription() {
        let err = OllamaError.invalidURL
        XCTAssertTrue(err.description.contains("URL"))
        XCTAssertFalse(err.description.isEmpty)
    }

    func testBadStatusDescription() {
        let err = OllamaError.badStatus
        XCTAssertTrue(err.description.contains("Ollama"))
    }

    func testErrorDescriptionsAreNonEmpty() {
        let all: [OllamaError] = [.badStatus, .invalidResponse, .interrupted, .invalidURL, .timeout, .modelError("test")]
        for e in all {
            XCTAssertFalse(e.description.isEmpty, "\(e) should have a description")
        }
    }

    func testTimeoutDescriptionIsActionable() {
        let err = OllamaError.timeout
        XCTAssertTrue(err.description.contains("délai"), "le message doit mentionner le délai : \(err.description)")
    }

    func testLocalizedDescriptionShowsFrenchText() {
        // Régression constatée : l'UI affiche `error.localizedDescription`, qui
        // rendait « L'opération n'a pas pu s'achever. (… erreur 4.) » au lieu
        // du texte français — l'utilisateur ne pouvait pas diagnostiquer.
        let err = OllamaError.timeout
        XCTAssertTrue(err.localizedDescription.contains("délai"), "localisé : \(err.localizedDescription)")
        XCTAssertFalse(err.localizedDescription.contains("n'a pas pu s'achever"))
    }

    func testMapStreamErrorMapsURLTimeout() {
        let mapped = OllamaService.mapStreamError(URLError(.timedOut))
        guard case OllamaError.timeout = mapped as? OllamaError ?? OllamaError.badStatus else {
            XCTFail("URLError.timedOut devrait devenir OllamaError.timeout, obtenu : \(mapped)")
            return
        }
    }

    func testMapStreamErrorKeepsCancellation() {
        let mapped = OllamaService.mapStreamError(CancellationError())
        XCTAssertTrue(mapped is CancellationError, "l'annulation ne doit pas être déguisée en timeout")
    }

    func testMapStreamErrorPassesThroughOtherErrors() {
        struct Other: Error {}
        let mapped = OllamaService.mapStreamError(Other())
        XCTAssertTrue(mapped is Other, "les erreurs non-timeout passent intactes")
    }
}
