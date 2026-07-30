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

    // MARK: - Cost-shaped keys

    func testSpendReportsBothLevelsOfKeysAndTypes() {
        let summary = ResponseShapeProbe.describe(
            #"{"spend":{"current":{"amount_dollars":9.5,"currency":"USD"},"limit_dollars":null,"enabled":true}}"#
        )

        XCTAssertTrue(
            summary.contains("spend{current: object, enabled: bool, limit_dollars: null}"),
            summary
        )
        XCTAssertTrue(summary.contains("spend.current{amount_dollars: number, currency: string}"), summary)
    }

    func testSpendDescendsIntoEveryObjectValuedKey() {
        let summary = ResponseShapeProbe.describe(
            #"{"spend":{"a":{"x":1},"b":{"y":"z"}}}"#
        )

        XCTAssertTrue(summary.contains("spend.a{x: number}"), summary)
        XCTAssertTrue(summary.contains("spend.b{y: string}"), summary)
    }

    func testLimitsReportsCountAndFirstElementShape() {
        let summary = ResponseShapeProbe.describe(
            #"{"limits":[{"type":"five_hour","limit_dollars":null},{"type":"seven_day"}]}"#
        )

        XCTAssertTrue(summary.contains("limits: 2 elements, first element keys: limit_dollars: null, type: string"), summary)
    }

    func testEmptyLimitsArrayIsSaidPlainly() {
        let summary = ResponseShapeProbe.describe(#"{"limits":[]}"#)

        XCTAssertTrue(summary.contains("limits: 0 elements"), summary)
    }

    func testLimitsOfNonObjectsIsSaidPlainly() {
        let summary = ResponseShapeProbe.describe(#"{"limits":["five_hour"]}"#)

        XCTAssertTrue(summary.contains("limits: 1 elements, first element is not an object"), summary)
    }

    func testExtraUsageReportsItsKeysAndTypes() {
        let summary = ResponseShapeProbe.describe(#"{"extra_usage":{"enabled":false,"used_dollars":null}}"#)

        XCTAssertTrue(summary.contains("extra_usage{enabled: bool, used_dollars: null}"), summary)
    }

    func testAbsentCostKeysAreSaidPlainly() {
        let summary = ResponseShapeProbe.describe(#"{"five_hour":null}"#)

        XCTAssertTrue(summary.contains("spend absent"), summary)
        XCTAssertTrue(summary.contains("limits absent"), summary)
        XCTAssertTrue(summary.contains("extra_usage absent"), summary)
    }

    func testNullOrMistypedCostKeysAreSaidPlainly() {
        let summary = ResponseShapeProbe.describe(#"{"spend":null,"limits":{},"extra_usage":7}"#)

        XCTAssertTrue(summary.contains("spend is null"), summary)
        XCTAssertTrue(summary.contains("limits is not an array"), summary)
        XCTAssertTrue(summary.contains("extra_usage is not an object"), summary)
    }

    /// The load-bearing one, extended to the cost keys — including values two
    /// levels down inside `spend` and inside a `limits` element.
    func testCostKeyValuesNeverAppearInTheSummary() {
        let summary = ResponseShapeProbe.describe(
            """
            {"spend":{"total_dollars":98765.4321,"note":"SECRET-VALUE-1234",\
            "current":{"amount_dollars":13579.11,"invoice":"SECRET-VALUE-5678","who":"someone@example.com"}},\
            "limits":[{"limit_dollars":24680.13,"org":"34cf885c-nope","label":"SECRET-VALUE-9012"}],\
            "extra_usage":{"used_dollars":11223.344,"receipt":"SECRET-VALUE-3456"}}
            """
        )

        for secret in [
            "SECRET-VALUE-1234", "SECRET-VALUE-5678", "SECRET-VALUE-9012", "SECRET-VALUE-3456",
            "someone@example.com", "34cf885c", "98765", "13579", "24680", "11223",
        ] {
            XCTAssertFalse(summary.contains(secret), "\(secret) leaked: \(summary)")
        }

        XCTAssertTrue(summary.contains("spend{current: object, note: string, total_dollars: number}"), summary)
        XCTAssertTrue(
            summary.contains("spend.current{amount_dollars: number, invoice: string, who: string}"),
            summary
        )
        XCTAssertTrue(
            summary.contains("limits: 1 elements, first element keys: label: string, limit_dollars: number, org: string"),
            summary
        )
        XCTAssertTrue(summary.contains("extra_usage{receipt: string, used_dollars: number}"), summary)
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
        // Both window objects genuinely absent — the only shape that still
        // yields nothing at all now that a null `resets_at` keeps its window.
        let body = #"{"five_hour":null,"seven_day":null}"#

        let result = try result(body: body)

        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertEqual(result.dataQuality, .exact)
        let message = try XCTUnwrap(result.message)
        XCTAssertTrue(
            message.hasPrefix(
                "claude.ai reported no active limits for this subscription. "
                    + "Measuring which cost fields claude.ai reports — this line is temporary. ("
            ),
            message
        )
        XCTAssertTrue(message.contains("five_hour is null"), message)
        XCTAssertTrue(message.contains("seven_day is null"), message)
        XCTAssertTrue(message.hasSuffix(")"), message)
    }

    /// The shape this whole change exists for: a window that is present but has
    /// no reset instant is a *reported* window now, so the "no active limits"
    /// diagnostic must not fire over it. It used to — that message is exactly
    /// what the user saw in place of "100% left".
    func testAWindowWithoutAResetInstantIsNotTreatedAsNoWindowAtAll() throws {
        let body = #"{"five_hour":{"utilization":0,"resets_at":null},"seven_day":{"utilization":0,"resets_at":null}}"#

        let result = try result(body: body)

        XCTAssertEqual(result.windows.count, 2)
        XCTAssertTrue(result.windows.allSatisfy { $0.resetAt == nil })
        let message = try XCTUnwrap(result.message)
        XCTAssertFalse(message.contains("no active limits"), message)
        XCTAssertTrue(
            message.hasPrefix("Measuring which cost fields claude.ai reports — this line is temporary. ("),
            message
        )
    }

    /// The point of the extension: an account that produces windows carries the
    /// measurement too, and still does not read as broken.
    func testAWindowCarriesTheMeasurementAndStaysExact() throws {
        let body = """
        {"five_hour":{"utilization":42,"resets_at":"2026-07-30T10:00:00Z","used_dollars":1.25},"seven_day":null,\
        "spend":{"current":{"amount_dollars":9.5}},"limits":[{"kind":"five_hour"}],"extra_usage":{"enabled":true}}
        """

        let result = try result(body: body)

        XCTAssertEqual(result.windows.count, 1)
        XCTAssertEqual(result.dataQuality, .exact)
        let message = try XCTUnwrap(result.message)
        XCTAssertTrue(
            message.hasPrefix("Measuring which cost fields claude.ai reports — this line is temporary. ("),
            message
        )
        XCTAssertTrue(message.contains("spend{current: object}"), message)
        XCTAssertTrue(message.contains("spend.current{amount_dollars: number}"), message)
        XCTAssertTrue(message.contains("limits: 1 elements, first element keys: kind: string"), message)
        XCTAssertTrue(message.contains("extra_usage{enabled: bool}"), message)
        XCTAssertFalse(message.contains("9.5"), message)
        XCTAssertFalse(message.contains("1.25"), message)
    }

    func testTheDiagnosticNeverCarriesAValue() throws {
        // No window object at all, so the diagnostic fires — while the body
        // still carries the values that must not reach the message.
        let body = #"{"five_hour":null,"seven_day":null,"utilization":98765,"session":"SECRET-VALUE-1234","account":"someone@example.com"}"#

        let message = try XCTUnwrap(result(body: body).message)

        XCTAssertFalse(message.contains("SECRET-VALUE-1234"), message)
        XCTAssertFalse(message.contains("someone@example.com"), message)
        XCTAssertFalse(message.contains("98765"), message)
    }
}
