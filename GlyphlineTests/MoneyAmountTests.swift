import XCTest
@testable import Glyphline

final class MoneyAmountTests: XCTestCase {
    func testDollarsBecomeMicros() {
        XCTAssertEqual(MoneyAmount.micros(fromDollars: Decimal(string: "1.23")!), 1_230_000)
        XCTAssertEqual(MoneyAmount.micros(fromDollars: Decimal(string: "0.000001")!), 1)
    }

    func testCentsBecomeMicros() {
        // "123.45" cents is $1.2345, which is 1_234_500 micros.
        XCTAssertEqual(MoneyAmount.micros(fromCents: Decimal(string: "123.45")!), 1_234_500)
        XCTAssertEqual(MoneyAmount.micros(fromCents: Decimal(string: "100")!), 1_000_000)
    }

    func testCentsAndDollarsDifferByTwoOrdersOfMagnitude() {
        let value = Decimal(string: "42.5")!
        XCTAssertEqual(
            MoneyAmount.micros(fromDollars: value),
            MoneyAmount.micros(fromCents: value) * 100
        )
    }
}
