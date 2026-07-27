import Foundation

/// Converts provider cost figures into the ledger's micro-unit representation.
///
/// Providers disagree on units: OpenAI reports dollars, Anthropic and Cursor
/// report the lowest currency unit. Naming the unit at the call site keeps a
/// hundredfold error from reaching the dashboard.
enum MoneyAmount {
    static func micros(fromDollars dollars: Decimal) -> Int64 {
        scale(dollars, byPowerOfTen: 6)
    }

    static func micros(fromCents cents: Decimal) -> Int64 {
        scale(cents, byPowerOfTen: 4)
    }

    private static func scale(_ value: Decimal, byPowerOfTen power: Int16) -> Int64 {
        var input = value
        var scaled = Decimal()
        NSDecimalMultiplyByPowerOf10(&scaled, &input, power, .plain)
        return NSDecimalNumber(decimal: scaled).int64Value
    }
}
