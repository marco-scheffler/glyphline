import XCTest

@testable import Glyphline

// TEMPORARY DIAGNOSTIC — added 2026-07-30. Remove together with
// `ResponseShapeProbe`.
final class ResponseShapeProbeTests: XCTestCase {
    func testArrayOfObjectsReportsCountAndKeyNames() {
        let summary = ResponseShapeProbe.describe(
            #"[{"uuid":"a","capabilities":["claude_max"]},{"uuid":"b","capabilities":[]}]"#
        )

        XCTAssertTrue(summary.contains("JSON array"), summary)
        XCTAssertTrue(summary.contains("2 elements"), summary)
        XCTAssertTrue(summary.contains("first element keys: capabilities: array, uuid: string"), summary)
    }

    func testTopLevelObjectReportsItsKeyNames() {
        let summary = ResponseShapeProbe.describe(#"{"type":"error","detail":"nope"}"#)

        XCTAssertTrue(summary.contains("JSON object"), summary)
        XCTAssertTrue(summary.contains("keys: detail: string, type: string"), summary)
    }

    func testNonJSONBodyIsReportedAsNotParsing() {
        let summary = ResponseShapeProbe.describe("not json at all")

        XCTAssertTrue(summary.contains("does not parse as JSON"), summary)
        XCTAssertTrue(summary.contains("starts 'n'"), summary)
    }

    /// The load-bearing one: no value from the body may reach the summary.
    func testValuesNeverAppearInTheSummary() {
        let body = """
        [{"uuid":"SECRET-VALUE-1234","name":"someone@example.com","capabilities":["claude_max"]}]
        """

        let summary = ResponseShapeProbe.describe(body)

        XCTAssertFalse(summary.contains("SECRET-VALUE-1234"), summary)
        XCTAssertFalse(summary.contains("someone@example.com"), summary)
        XCTAssertFalse(summary.contains("claude_max"), summary)
        XCTAssertTrue(
            summary.contains("first element keys: capabilities: array, name: string, uuid: string"),
            summary
        )
    }

    func testErrorEnvelopeValuesNeverAppearInTheSummary() {
        let summary = ResponseShapeProbe.describe(
            #"{"detail":"SECRET-VALUE-1234","type":"someone@example.com"}"#
        )

        XCTAssertFalse(summary.contains("SECRET-VALUE-1234"), summary)
        XCTAssertFalse(summary.contains("someone@example.com"), summary)
    }

    /// Value types are reported; the values behind them are not.
    func testValueTypesAreReportedForEveryKey() {
        let summary = ResponseShapeProbe.describe(
            #"{"five_hour":{},"spend":17,"tangelo":null,"ok":true,"name":"x","list":[]}"#
        )

        XCTAssertTrue(summary.contains("five_hour: object"), summary)
        XCTAssertTrue(summary.contains("list: array"), summary)
        XCTAssertTrue(summary.contains("name: string"), summary)
        XCTAssertTrue(summary.contains("ok: bool"), summary)
        XCTAssertTrue(summary.contains("spend: number"), summary)
        XCTAssertTrue(summary.contains("tangelo: null"), summary)
    }

    /// The type report must not leak the values it describes.
    func testTypeReportingNeverLeaksValues() {
        let summary = ResponseShapeProbe.describe(
            #"{"a":"SECRET-VALUE-1234","b":98765.4321,"c":{"d":"someone@example.com"},"e":[false]}"#
        )

        XCTAssertFalse(summary.contains("SECRET-VALUE-1234"), summary)
        XCTAssertFalse(summary.contains("someone@example.com"), summary)
        XCTAssertFalse(summary.contains("98765"), summary)
        // Nested keys are not descended into either, so `d` stays unmentioned.
        XCTAssertFalse(summary.contains("d:"), summary)
        XCTAssertTrue(summary.contains("a: string, b: number, c: object, e: array"), summary)
    }

    func testEmptyBody() {
        XCTAssertEqual(ResponseShapeProbe.describe(""), "0 bytes, empty")
    }

    func testWhitespaceOnlyBody() {
        XCTAssertEqual(ResponseShapeProbe.describe("  \n\t "), "5 bytes, whitespace only")
    }

    func testByteLengthIsReported() {
        XCTAssertTrue(ResponseShapeProbe.describe("[]").hasPrefix("2 bytes, starts '['"))
    }
}
