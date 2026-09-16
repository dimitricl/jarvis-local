@testable import JarvisServices
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
        let all: [OllamaError] = [.badStatus, .invalidResponse, .interrupted, .invalidURL, .modelError("test")]
        for e in all {
            XCTAssertFalse(e.description.isEmpty, "\(e) should have a description")
        }
    }
}
