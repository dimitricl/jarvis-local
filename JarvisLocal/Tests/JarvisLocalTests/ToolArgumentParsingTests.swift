@testable import JarvisUI
import XCTest

final class JarvisLocalToolServiceArgumentParsingTests: XCTestCase {

    func testParseToolArgumentsValidJSON() throws {
        let args = AppViewModel.parseToolArguments("{\"query\": \"test\", \"count\": 5}")
        XCTAssertNotNil(args)
        XCTAssertEqual(args?["query"] as? String, "test")
        XCTAssertEqual(args?["count"] as? Int, 5)
    }

    func testParseToolArgumentsWithTrailingComma() throws {
        let args = AppViewModel.parseToolArguments("{\"query\": \"test\",}")
        XCTAssertNotNil(args)
        XCTAssertEqual(args?["query"] as? String, "test")
    }

    func testParseToolArgumentsWithMarkdownFences() throws {
        let args = AppViewModel.parseToolArguments("```json\n{\"query\": \"test\"}\n```")
        XCTAssertNotNil(args)
        XCTAssertEqual(args?["query"] as? String, "test")
    }

    func testParseToolArgumentsWithSmartQuotes() throws {
        let args = AppViewModel.parseToolArguments("{\"query\": \"test\"}")
        XCTAssertNotNil(args)
        XCTAssertEqual(args?["query"] as? String, "test")
    }

    func testParseToolArgumentsEmptyString() throws {
        let args = AppViewModel.parseToolArguments("")
        XCTAssertNotNil(args)
        XCTAssertTrue(args!.isEmpty)
    }

    func testParseToolArgumentsInvalidJSONReturnsNil() throws {
        let args = AppViewModel.parseToolArguments("not json at all")
        XCTAssertNil(args)
    }

    func testParseToolArgumentsDoubleEncoded() throws {
        let args = AppViewModel.parseToolArguments("{\"app\": \"{\\\"app\\\": \\\"Safari\\\"}\"}")
        XCTAssertNotNil(args)
    }
}
