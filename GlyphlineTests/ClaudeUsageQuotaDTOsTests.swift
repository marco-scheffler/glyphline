import XCTest
@testable import Glyphline

final class ClaudeUsageQuotaDTOsTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func fixture(_ name: String) throws -> Data {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")
        return try Data(contentsOf: XCTUnwrap(url))
    }

    func testUtilizationBecomesAFractionAndNotAPercentage() throws {
        let response = try ClaudeUsageResponse.decode(fixture("claude-usage"))
        let windows = response.rateWindows(observedAt: observedAt)

        let fiveHour = try XCTUnwrap(windows.first { $0.kind == .rollingFiveHours })
        // 4.0 percent must become 0.04, not 4.0 — the latter is rejected by
        // isPlausible and would surface as a permanently grey account.
        XCTAssertEqual(try XCTUnwrap(fiveHour.usedFraction), 0.04, accuracy: 0.0001)

        let weekly = try XCTUnwrap(windows.first { $0.kind == .weekly })
        XCTAssertEqual(try XCTUnwrap(weekly.usedFraction), 0.03, accuracy: 0.0001)
    }

    func testBothWindowsAreProducedWithTheirResetInstants() throws {
        let response = try ClaudeUsageResponse.decode(fixture("claude-usage"))
        let windows = response.rateWindows(observedAt: observedAt)

        XCTAssertEqual(Set(windows.map(\.kind)), [.rollingFiveHours, .weekly])
        XCTAssertTrue(windows.allSatisfy { $0.observedAt == observedAt })

        let fiveHour = try XCTUnwrap(windows.first { $0.kind == .rollingFiveHours })
        // 2026-07-29T10:30:00.695306+00:00 — microsecond precision must parse.
        XCTAssertEqual(
            try XCTUnwrap(fiveHour.resetAt).timeIntervalSince1970,
            1_785_321_000.695306,
            accuracy: 0.001
        )
    }

    func testDecodingSurvivesWithEveryCodenameFieldRemoved() throws {
        // tangelo, nimbus_quill and friends are internal and unstable. Nothing
        // may depend on them; their absence must not break decoding.
        let response = try ClaudeUsageResponse.decode(fixture("claude-usage-minimal"))
        let windows = response.rateWindows(observedAt: observedAt)

        XCTAssertEqual(Set(windows.map(\.kind)), [.rollingFiveHours, .weekly])
        XCTAssertEqual(try XCTUnwrap(windows.first { $0.kind == .rollingFiveHours }.map(\.usedFraction)), 1.0)
    }

    func testAWindowMissingFromTheResponseIsSimplyAbsent() throws {
        let json = Data("""
            {"five_hour": {"utilization": 12.0, "resets_at": "2026-07-29T10:30:00Z"}}
            """.utf8)
        let windows = try ClaudeUsageResponse.decode(json).rateWindows(observedAt: observedAt)

        XCTAssertEqual(windows.map(\.kind), [.rollingFiveHours])
    }

    /// The full production key list, so the fixture matches what the endpoint
    /// really sends. Every value here is invented.
    private func productionShaped(fiveHour: String, sevenDay: String) -> Data {
        Data("""
            {
              "five_hour": \(fiveHour),
              "seven_day": \(sevenDay),
              "seven_day_opus": null,
              "seven_day_sonnet": null,
              "seven_day_cowork": null,
              "seven_day_oauth_apps": null,
              "seven_day_omelette": null,
              "omelette_promotional": null,
              "amber_ladder": null,
              "cinder_cove": null,
              "iguana_necktie": null,
              "nimbus_quill": null,
              "tangelo": null,
              "spend": 0,
              "extra_usage": null,
              "limits": {},
              "member_dashboard_available": false
            }
            """.utf8)
    }

    private static let completeWindow = #"{"utilization": 7.0, "resets_at": "2026-08-03T22:59:59.695335+00:00"}"#

    /// A null `resets_at` used to take the whole window with it, including the
    /// `utilization` beside it. The fraction is the useful half of the reading
    /// and it is reported correctly, so it must survive on its own.
    func testAWindowWithoutAResetInstantKeepsItsFractionAndTheSiblingSurvives() throws {
        let json = productionShaped(
            fiveHour: #"{"utilization": 12.0, "resets_at": null}"#,
            sevenDay: Self.completeWindow
        )

        let windows = try ClaudeUsageResponse.decode(json).rateWindows(observedAt: observedAt)

        XCTAssertEqual(windows.map(\.kind), [.rollingFiveHours, .weekly])

        let fiveHour = try XCTUnwrap(windows.first { $0.kind == .rollingFiveHours })
        XCTAssertNil(fiveHour.resetAt, "a null resets_at is no instant, not an invented one")
        XCTAssertEqual(try XCTUnwrap(fiveHour.usedFraction), 0.12, accuracy: 0.0001)

        let weekly = try XCTUnwrap(windows.first { $0.kind == .weekly })
        XCTAssertNotNil(weekly.resetAt, "the sibling's own instant is untouched")
        XCTAssertEqual(try XCTUnwrap(weekly.usedFraction), 0.07, accuracy: 0.0001)
    }

    /// The exact shape a freshly added subscription returns: both windows
    /// present, both `resets_at` null, both `utilization` a real number. A
    /// rolling window only starts on first use, so there is genuinely nothing to
    /// reset — and "0% consumed" is the most useful thing the endpoint ever
    /// says. This response used to yield no windows at all and the account
    /// showed nothing.
    func testAnUnusedSubscriptionYieldsBothWindowsWithNoResetInstant() throws {
        let json = productionShaped(
            fiveHour: #"{"limit_dollars": null, "remaining_dollars": null, "resets_at": null, "used_dollars": null, "utilization": 0}"#,
            sevenDay: #"{"limit_dollars": null, "remaining_dollars": null, "resets_at": null, "used_dollars": null, "utilization": 0}"#
        )

        let windows = try ClaudeUsageResponse.decode(json).rateWindows(observedAt: observedAt)

        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(Set(windows.map(\.kind)), [.rollingFiveHours, .weekly])
        XCTAssertTrue(windows.allSatisfy { $0.resetAt == nil })
        // Zero, and present — distinct from the nil that means "usage unknown".
        for window in windows {
            XCTAssertEqual(try XCTUnwrap(window.usedFraction), 0, accuracy: 1e-12)
        }
        // And the ledger must accept them, or the decode fix changes nothing.
        XCTAssertTrue(windows.allSatisfy { $0.isPlausible(now: observedAt) })
    }

    func testAWindowWithoutUtilizationKeepsItsResetInstantAndReportsUsageAsUnknown() throws {
        let json = productionShaped(
            fiveHour: #"{"utilization": null, "resets_at": "2026-07-29T10:30:00Z"}"#,
            sevenDay: "null"
        )

        let windows = try ClaudeUsageResponse.decode(json).rateWindows(observedAt: observedAt)

        XCTAssertEqual(windows.map(\.kind), [.rollingFiveHours])
        // Nil, not 0 — "unknown" must not be rendered as "nothing used".
        XCTAssertNil(windows[0].usedFraction)
    }

    func testBothWindowsCompleteStillYieldBoth() throws {
        let json = productionShaped(
            fiveHour: #"{"utilization": 12.0, "resets_at": "2026-07-29T10:30:00Z"}"#,
            sevenDay: Self.completeWindow
        )

        let windows = try ClaudeUsageResponse.decode(json).rateWindows(observedAt: observedAt)

        XCTAssertEqual(Set(windows.map(\.kind)), [.rollingFiveHours, .weekly])
        let fiveHour = try XCTUnwrap(windows.first { $0.kind == .rollingFiveHours })
        XCTAssertEqual(try XCTUnwrap(fiveHour.usedFraction), 0.12, accuracy: 0.0001)
    }

    /// A timestamp we cannot parse costs that window its instant and nothing
    /// else — not the fraction beside it, and above all not the sibling window,
    /// which decodes through the same date strategy.
    func testAMalformedResetInstantCostsOnlyThatWindowsInstant() throws {
        let json = productionShaped(
            fiveHour: #"{"utilization": 12.0, "resets_at": "not-a-timestamp"}"#,
            sevenDay: Self.completeWindow
        )

        let windows = try ClaudeUsageResponse.decode(json).rateWindows(observedAt: observedAt)

        XCTAssertEqual(windows.map(\.kind), [.rollingFiveHours, .weekly])

        let fiveHour = try XCTUnwrap(windows.first { $0.kind == .rollingFiveHours })
        XCTAssertNil(fiveHour.resetAt)
        XCTAssertEqual(try XCTUnwrap(fiveHour.usedFraction), 0.12, accuracy: 0.0001)

        XCTAssertNotNil(try XCTUnwrap(windows.first { $0.kind == .weekly }).resetAt)
    }

    func testAWholeWindowValueBeingNullStaysTolerated() throws {
        let json = productionShaped(fiveHour: "null", sevenDay: Self.completeWindow)

        let windows = try ClaudeUsageResponse.decode(json).rateWindows(observedAt: observedAt)

        XCTAssertEqual(windows.map(\.kind), [.weekly])
    }

    func testTheCodenameAndBillingFieldsAreIgnoredButDoNotBreakDecoding() throws {
        let json = productionShaped(
            fiveHour: #"{"utilization": 12.0, "resets_at": "2026-07-29T10:30:00Z"}"#,
            sevenDay: Self.completeWindow
        )

        let response = try ClaudeUsageResponse.decode(json)

        XCTAssertNotNil(response.fiveHour)
        XCTAssertNotNil(response.sevenDay)
        XCTAssertEqual(response.rateWindows(observedAt: observedAt).count, 2)
    }

    // MARK: - Limits confined to one model

    /// What a Max 20x account returned on 2026-10-31, the day after the plans
    /// were renamed, with only the whitespace changed. The Fable allowance is in
    /// `limits` and nowhere else: no `seven_day_*` field carries it.
    private static let responseWithAModelLimit = Data(#"""
        {"five_hour":{"utilization":0.0,"resets_at":null,"limit_dollars":null,"used_dollars":null,"remaining_dollars":null,"locked_reason":null},
         "seven_day":{"utilization":0.0,"resets_at":"2026-11-02T22:59:59.890814+00:00","limit_dollars":null,"used_dollars":null,"remaining_dollars":null,"locked_reason":null},
         "seven_day_oauth_apps":null,"seven_day_opus":null,"seven_day_sonnet":null,"seven_day_cowork":null,"seven_day_omelette":null,
         "tangelo":null,"iguana_necktie":null,"omelette_promotional":null,"nimbus_quill":null,"cinder_cove":null,"copper_kite":null,
         "brass_thimble":null,"harbor_lantern":null,"wattle_ember":null,"promo_credits":null,"amber_ladder":null,"granite_teacup":null,
         "amber_cistern":null,"amber_cistern_offer":null,"juniper_tide":null,"cedar_ember":null,"starry_waterfall":null,"amber_gauge":null,"pace":null,
         "extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,"utilization":null,"currency":null,"decimal_places":null,"disabled_reason":null,"user_disabled":true,"spend_limit_reached":false,"credits_ever_enabled":true,"daily":null,"weekly":null},
         "limits":[
           {"kind":"session","group":"session","percent":0,"severity":"normal","resets_at":null,"scope":null,"is_active":true},
           {"kind":"weekly_all","group":"weekly","percent":0,"severity":"normal","resets_at":"2026-11-02T22:59:59.890814+00:00","scope":null,"is_active":false},
           {"kind":"weekly_scoped","group":"weekly","percent":0,"severity":"normal","resets_at":"2026-11-02T23:00:00+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}
         ],
         "spend":{"used":{"amount_minor":0,"currency":"USD","exponent":2},"limit":null,"percent":0,"severity":"normal","enabled":false,"disabled_reason":null,"cap":null,"balance":null,"auto_reload":null,"disclaimer":"Usage credits cover you when you hit your plan limits. [Learn more](https://support.claude.com/articles/12429409)","can_purchase_credits":true,"can_toggle":true},
         "member_dashboard_available":false,"seven_day_breakdown":null,
         "weekly_scoped_shares":[{"limit_index":2,"used_percent_of_weekly":0,"allowance_percent_of_weekly":50}]}
        """#.utf8)

    private func limits(_ entries: String) -> Data {
        Data("""
            {"five_hour": {"utilization": 12.0, "resets_at": null},
             "seven_day": \(Self.completeWindow),
             "limits": \(entries)}
            """.utf8)
    }

    func testAWeeklyLimitConfinedToOneModelBecomesAWindowOfItsOwn() throws {
        let windows = try ClaudeUsageResponse.decode(Self.responseWithAModelLimit)
            .rateWindows(observedAt: observedAt)

        XCTAssertEqual(windows.count, 3)
        let fable = try XCTUnwrap(windows.first { $0.model == "Fable" })
        XCTAssertEqual(fable.kind, .weekly)
        XCTAssertEqual(try XCTUnwrap(fable.usedFraction), 0, accuracy: 1e-12)
        // 2026-11-02T23:00:00Z — its own instant, not the overall weekly one.
        XCTAssertEqual(try XCTUnwrap(fable.resetAt).timeIntervalSince1970, 1_793_660_400, accuracy: 0.001)

        XCTAssertEqual(
            windows.filter { $0.model == nil }.map(\.kind), [.rollingFiveHours, .weekly],
            "the two windows on the whole subscription are untouched"
        )
    }

    func testAModelLimitsPercentageBecomesAFraction() throws {
        let windows = try ClaudeUsageResponse.decode(limits("""
            [{"kind":"weekly_scoped","percent":37,"resets_at":"2026-11-02T23:00:00+00:00",
              "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}]
            """)).rateWindows(observedAt: observedAt)

        let fable = try XCTUnwrap(windows.first { $0.model == "Fable" })
        XCTAssertEqual(try XCTUnwrap(fable.usedFraction), 0.37, accuracy: 0.0001)
    }

    /// `session` and `weekly_all` repeat `five_hour` and `seven_day`, and a
    /// scope that names no model is nothing this app can label. None of them
    /// may add a window.
    func testOnlyLimitsConfinedToANamedModelAddWindows() throws {
        let windows = try ClaudeUsageResponse.decode(limits("""
            [{"kind":"session","percent":12,"resets_at":null,"scope":null},
             {"kind":"weekly_all","percent":7,"resets_at":"2026-08-03T22:59:59Z","scope":null},
             {"kind":"weekly_scoped","percent":5,"resets_at":"2026-08-03T23:00:00Z","scope":{"model":null,"surface":{"id":"code"}}},
             {"kind":"weekly_scoped","percent":5,"resets_at":"2026-08-03T23:00:00Z","scope":{"model":{"id":null,"display_name":"  "}}}]
            """)).rateWindows(observedAt: observedAt)

        XCTAssertEqual(windows.map(\.kind), [.rollingFiveHours, .weekly])
        XCTAssertTrue(windows.allSatisfy { $0.model == nil })
    }

    /// `limits` is the newest part of the response and has already been seen as
    /// an empty object. A shape we do not recognise costs the model windows and
    /// nothing else.
    func testALimitsValueOfAnotherShapeCostsOnlyTheModelWindows() throws {
        for entries in [#"{}"#, #"["x"]"#, #"null"#] {
            let windows = try ClaudeUsageResponse.decode(limits(entries)).rateWindows(observedAt: observedAt)
            XCTAssertEqual(windows.map(\.kind), [.rollingFiveHours, .weekly], entries)
        }
    }

    func testAnUnparseableBodyThrows() {
        XCTAssertThrowsError(try ClaudeUsageResponse.decode(Data("<html>sign in</html>".utf8)))
    }
}
