import Foundation
import XCTest
@testable import TrailMeshReports

final class StrictJSONTests: XCTestCase {
    private func parse(_ text: String) throws -> ReportJSON {
        var parser = try StrictReportJSONParser(Data(text.utf8))
        return try parser.parse()
    }

    func testRejectsDuplicateDecodedKeysAndInvalidScalars() throws {
        XCTAssertThrowsError(try parse(#"{"name":1,"na\u006de":2}"#))
        XCTAssertThrowsError(try parse(#"{"name":"\ud800"}"#))
        XCTAssertThrowsError(try parse(#"{"name":"\udc00"}"#))
    }

    func testRejectsNumbersAndValuesOutsideTheProfile() throws {
        for text in ["1.0", "1e0", "true", "false", "9007199254740992", "01", "[0,]", "{\"a\":1,}"] {
            XCTAssertThrowsError(try parse(text), text)
        }
        XCTAssertThrowsError(try StrictReportJSONParser(Data(repeating: 0x20, count: 8193)))
        XCTAssertThrowsError(try StrictReportJSONParser(Data([0xff])))
    }

    func testCanonicalizationUsesUtf16OrderAndPreservesUnicode() throws {
        let value = try parse("{\"\\u20ac\":\"e\\u0301\",\"\\r\":\"x\\n\",\"\\ud83d\\ude00\":0,\"a\":null}")
        XCTAssertEqual(value.canonical(), "{\"\\r\":\"x\\n\",\"a\":null,\"\u{20ac}\":\"e\u{301}\",\"\u{1f600}\":0}")
    }
}
