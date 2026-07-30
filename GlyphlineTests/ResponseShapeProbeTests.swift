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

    // MARK: - Nested usage windows

    func testNestedUsageWindowReportsItsKeysAndTypes() {
        let summary = ResponseShapeProbe.describe(
            #"{"five_hour":{"utilization":12.5,"resets_at":null},"seven_day":{"utilization":null,"resets_at":"2026-07-30T10:00:00Z"}}"#
        )

        XCTAssertTrue(summary.contains("five_hour{resets_at: null, utilization: number}"), summary)
        XCTAssertTrue(summary.contains("seven_day{resets_at: string, utilization: null}"), summary)
    }

    func testAbsentUsageWindowIsSaidPlainly() {
        let summary = ResponseShapeProbe.describe(#"{"seven_day":{"utilization":1}}"#)

        XCTAssertTrue(summary.contains("five_hour absent"), summary)
        XCTAssertTrue(summary.contains("seven_day{utilization: number}"), summary)
    }

    func testNullUsageWindowIsSaidPlainly() {
        let summary = ResponseShapeProbe.describe(#"{"five_hour":null}"#)

        XCTAssertTrue(summary.contains("five_hour is null"), summary)
    }

    func testNonObjectUsageWindowIsSaidPlainly() {
        let summary = ResponseShapeProbe.describe(#"{"five_hour":[1,2],"seven_day":"soon"}"#)

        XCTAssertTrue(summary.contains("five_hour is not an object"), summary)
        XCTAssertTrue(summary.contains("seven_day is not an object"), summary)
    }

    /// The load-bearing one, extended: descending one level must not leak the
    /// values found down there either.
    func testNestedValuesNeverAppearInTheSummary() {
        let summary = ResponseShapeProbe.describe(
            """
            {"five_hour":{"utilization":98765.4321,"resets_at":"SECRET-VALUE-1234","label":"someone@example.com"},\
            "seven_day":{"utilization":13579,"resets_at":"SECRET-VALUE-5678","org":"34cf885c-nope"}}
            """
        )

        XCTAssertFalse(summary.contains("SECRET-VALUE-1234"), summary)
        XCTAssertFalse(summary.contains("SECRET-VALUE-5678"), summary)
        XCTAssertFalse(summary.contains("someone@example.com"), summary)
        XCTAssertFalse(summary.contains("34cf885c"), summary)
        XCTAssertFalse(summary.contains("98765"), summary)
        XCTAssertFalse(summary.contains("13579"), summary)
        XCTAssertTrue(
            summary.contains("five_hour{label: string, resets_at: string, utilization: number}"),
            summary
        )
        XCTAssertTrue(
            summary.contains("seven_day{org: string, resets_at: string, utilization: number}"),
            summary
        )
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

// TEMPORARY DIAGNOSTIC — added 2026-07-30. Remove together with
// `ResponseShapeProbe` and its polling call site.
@MainActor
final class ClaudeWebQuotaSourceEmptyWindowProbeTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_770_000_000)

    private func result(body: String) throws -> RateWindowResult {
        let response = try ClaudeUsageResponse.decode(Data(body.utf8))
        return ClaudeWebQuotaSource.result(from: response, body: body, observedAt: observedAt)
    }

    func testZeroWindowsCarriesTheStructuralSummary() throws {
        let body = #"{"five_hour":{"utilization":0,"resets_at":null},"seven_day":null}"#

        let result = try result(body: body)

        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.dataQuality, .exact)
        let message = try XCTUnwrap(result.message)
        XCTAssertTrue(
            message.hasPrefix("claude.ai reported no active limits for this subscription. ("),
            message
        )
        XCTAssertTrue(message.contains("five_hour{resets_at: null, utilization: number}"), message)
        XCTAssertTrue(message.contains("seven_day is null"), message)
        XCTAssertTrue(message.hasSuffix(")"), message)
    }

    func testAtLeastOneWindowCarriesNoDiagnostic() throws {
        let body = #"{"five_hour":{"utilization":42,"resets_at":"2026-07-30T10:00:00Z"},"seven_day":null}"#

        let result = try result(body: body)

        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.dataQuality, .exact)
        XCTAssertNil(result.message)
    }

    func testTheDiagnosticNeverCarriesAValue() throws {
        let body = #"{"five_hour":{"utilization":98765,"resets_at":"SECRET-VALUE-1234"},"account":"someone@example.com"}"#

        let message = try XCTUnwrap(result(body: body).message)

        XCTAssertFalse(message.contains("SECRET-VALUE-1234"), message)
        XCTAssertFalse(message.contains("someone@example.com"), message)
        XCTAssertFalse(message.contains("98765"), message)
    }
}
