import XCTest
@testable import JarvisServices

final class SystemToolsTests: XCTestCase {
    func testSafariBundleID() async throws {
        let system = SystemTools()
        let result = try await system.openApp("safari", url: nil)
        print("Test Safari result: \(result)")
        XCTAssertTrue(result.contains("Safari") || result.contains("ouvert"))
    }

    func testMailBundleID() async throws {
        let system = SystemTools()
        let result = try await system.openApp("mail", url: nil)
        print("Test Mail result: \(result)")
        XCTAssertTrue(result.contains("Mail") || result.contains("ouvert"))
    }
}
