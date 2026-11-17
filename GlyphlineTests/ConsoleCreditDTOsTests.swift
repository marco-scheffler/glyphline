import XCTest
@testable import Glyphline

final class ConsoleCreditDTOsTests: XCTestCase {
    private let now = ConsoleCreditDTOsTests.date("2026-11-17T00:00:00Z")

    private func fixture(_ name: String) throws -> Data {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")
        return try Data(contentsOf: XCTUnwrap(url))
    }

    private static func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private func credits(_ json: String) throws -> ConsoleCreditsResponse {
        try ConsoleCreditsResponse.decode(Data(json.utf8))
    }

    private func balance(_ json: String, spend: ConsoleCurrentSpendResponse? = nil) throws -> ConsoleCreditBalance {
        try XCTUnwrap(ConsoleCreditBalance(credits: credits(json), spend: spend, now: now))
    }

    func testDecodesTheObservedShape() throws {
        let response = try ConsoleCreditsResponse.decode(fixture("console-prepaid-credits"))

        XCTAssertEqual(response.balanceMinor, 15714)
        XCTAssertEqual(response.exponent, 2)
        XCTAssertEqual(response.currency, "USD")
        XCTAssertEqual(response.tranches.count, 2)
    }

    func testFallsBackToAmountWhenBalanceIsAbsent() throws {
        let response = try credits(#"{"amount": 1200, "currency": "USD"}"#)

        XCTAssertEqual(response.balanceMinor, 1200)
        XCTAssertEqual(response.exponent, 2)
    }

    func testAMalformedTrancheCostsOnlyThatTranche() throws {
        let response = try credits("""
        {"amount": 1200, "currency": "USD", "promo_tranches": [
          {"remaining_amount_minor_units": 100, "expires_at": "soon"},
          {"remaining_amount_minor_units": 200, "expires_at": "2026-12-01T00:00:00Z"}
        ]}
        """)

        XCTAssertEqual(response.tranches.count, 2)
        XCTAssertNil(response.tranches[0].expiresAt)
        XCTAssertEqual(response.tranches[0].remainingMinor, 100)
        XCTAssertEqual(response.tranches[1].expiresAt, Self.date("2026-12-01T00:00:00Z"))
    }

    func testMissingPromoTranchesIsNotAFailure() throws {
        let response = try credits(#"{"amount": 1200, "currency": "USD", "tranches": []}"#)

        XCTAssertEqual(response.balanceMinor, 1200)
        XCTAssertTrue(response.tranches.isEmpty)
    }

    func testNextExpiryIsTheEarliestFutureTrancheWithSomethingLeft() throws {
        let response = try ConsoleCreditsResponse.decode(fixture("console-prepaid-credits"))
        let balance = try XCTUnwrap(ConsoleCreditBalance(credits: response, spend: nil, now: now))

        XCTAssertEqual(
            balance.nextExpiry,
            ConsoleCreditBalance.Expiry(at: Self.date("2026-11-29T00:00:00Z"), amountMinor: 15213)
        )
    }

    func testTranchesLapsingTogetherAreSummed() throws {
        let balance = try balance("""
        {"amount": 1200, "currency": "USD", "promo_tranches": [
          {"remaining_amount_minor_units": 100, "expires_at": "2026-12-01T00:00:00Z"},
          {"remaining_amount_minor_units": 250, "expires_at": "2026-12-01T00:00:00Z"}
        ]}
        """)

        XCTAssertEqual(balance.nextExpiry?.amountMinor, 350)
    }

    func testPastAndEmptyTranchesAreIgnored() throws {
        let balance = try balance("""
        {"amount": 1200, "currency": "USD", "promo_tranches": [
          {"remaining_amount_minor_units": 500, "expires_at": "2026-11-16T00:00:00Z"},
          {"remaining_amount_minor_units": 0, "expires_at": "2026-12-01T00:00:00Z"}
        ]}
        """)

        XCTAssertNil(balance.nextExpiry)
    }

    func testSpendIsCarriedThrough() throws {
        let spend = try ConsoleCurrentSpendResponse.decode(
            Data(#"{"amount":4579,"resets_at":"2026-12-01T00:00:00Z"}"#.utf8)
        )
        let balance = try balance(#"{"amount": 1200, "currency": "USD"}"#, spend: spend)

        XCTAssertEqual(balance.monthSpendMinor, 4579)
        XCTAssertEqual(balance.spendResetsAt, Self.date("2026-12-01T00:00:00Z"))
    }

    func testLowBalanceThresholdFollowsTheExponent() {
        var balance = ConsoleCreditBalance(
            currency: "USD", exponent: 2, balanceMinor: 0,
            nextExpiry: nil, monthSpendMinor: nil, spendResetsAt: nil
        )
        XCTAssertEqual(balance.lowBalanceThresholdMinor, 500)

        balance.exponent = 0
        XCTAssertEqual(balance.lowBalanceThresholdMinor, 5)
    }

    func testApiOrganizationsAreSelectedByCapability() throws {
        let json = """
        [
          {"uuid": "chat-org", "capabilities": ["chat", "claude_max"]},
          {"uuid": "api-1", "capabilities": ["api"]},
          {"uuid": "api-2", "capabilities": ["chat", "api"]}
        ]
        """

        let organizations = try ConsoleOrganizationsResponse.apiOrganizations(from: Data(json.utf8))

        XCTAssertEqual(organizations.map(\.id), ["api-1", "api-2"])
    }

    func testAmountFormattingFollowsCurrencyAndExponent() {
        let locale = Locale.current
        XCTAssertEqual(
            ConsoleCreditFormatting.amount(15714, exponent: 2, currency: "USD", locale: locale),
            (Decimal(15714) / 100).formatted(.currency(code: "USD").locale(locale))
        )
        XCTAssertEqual(
            ConsoleCreditFormatting.amount(500, exponent: 0, currency: "JPY", locale: locale),
            Decimal(500).formatted(.currency(code: "JPY").locale(locale))
        )
    }
}
