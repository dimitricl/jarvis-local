import JarvisCore
import XCTest

final class JarvisLocalToolServiceArgumentParsingTests: XCTestCase {

    func testParseToolArgumentsValidJSON() throws {
        let args = ToolArgumentParser.parse("{\"query\": \"test\", \"count\": 5}")
        XCTAssertNotNil(args)
        XCTAssertEqual(args?["query"] as? String, "test")
        XCTAssertEqual(args?["count"] as? Int, 5)
    }

    func testParseToolArgumentsWithTrailingComma() throws {
        let args = ToolArgumentParser.parse("{\"query\": \"test\",}")
        XCTAssertNotNil(args)
        XCTAssertEqual(args?["query"] as? String, "test")
    }

    func testParseToolArgumentsWithMarkdownFences() throws {
        let args = ToolArgumentParser.parse("```json\n{\"query\": \"test\"}\n```")
        XCTAssertNotNil(args)
        XCTAssertEqual(args?["query"] as? String, "test")
    }

    func testParseToolArgumentsWithSmartQuotes() throws {
        let args = ToolArgumentParser.parse("{\"query\": \"test\"}")
        XCTAssertNotNil(args)
        XCTAssertEqual(args?["query"] as? String, "test")
    }

    func testParseToolArgumentsEmptyString() throws {
        let args = ToolArgumentParser.parse("")
        XCTAssertNotNil(args)
        XCTAssertTrue(args!.isEmpty)
    }

    func testParseToolArgumentsInvalidJSONReturnsNil() throws {
        let args = ToolArgumentParser.parse("not json at all")
        XCTAssertNil(args)
    }

    func testParseToolArgumentsDoubleEncoded() throws {
        let args = ToolArgumentParser.parse("{\"app\": \"{\\\"app\\\": \\\"Safari\\\"}\"}")
        XCTAssertNotNil(args)
    }
}
