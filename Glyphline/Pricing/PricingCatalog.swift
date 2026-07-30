import Foundation

struct PricingEntry: Codable, Equatable, Sendable {
    var providerID: ProviderID
    var model: String
    var inputMicrosPerMillionTokens: Int64
    var outputMicrosPerMillionTokens: Int64
    /// Absent entries fall back to a ratio of the input price.
    var cacheCreationMicrosPerMillionTokens: Int64?
    /// Absent entries fall back to a ratio of the input price.
    var cacheReadMicrosPerMillionTokens: Int64?
    var currency: String
    var effectiveDate: String
    var source: String

    var effectiveCacheCreationMicrosPerMillionTokens: Int64 {
        cacheCreationMicrosPerMillionTokens ?? inputMicrosPerMillionTokens * 5 / 4
    }

    var effectiveCacheReadMicrosPerMillionTokens: Int64 {
        cacheReadMicrosPerMillionTokens ?? inputMicrosPerMillionTokens / 10
    }
}

struct PricingCatalog: Sendable {
    let entries: [PricingEntry]

    func entry(providerID: ProviderID, model: String?) -> PricingEntry? {
        guard let model else { return nil }

        if let exact = entries.first(where: { $0.providerID == providerID && $0.model == model }) {
            return exact
        }

        guard let alias = Self.aliasDroppingDateSuffix(from: model) else { return nil }
        return entries.first { $0.providerID == providerID && $0.model == alias }
    }

    /// `claude-haiku-4-5-20251001` → `claude-haiku-4-5`, and nil for anything
    /// that does not end in a dated snapshot suffix.
    ///
    /// Every model is addressable both by its alias and by a dated snapshot id
    /// that is the alias plus `-YYYYMMDD`, and a transcript records whichever the
    /// caller used. Both name the same model at the same price, so a catalog
    /// keyed by alias has to answer for the snapshot too — otherwise a model
    /// reads as unpriced purely because of how it happened to be addressed.
    ///
    /// Only ever a fallback: the exact match above runs first, so a snapshot that
    /// is priced explicitly still wins over its alias.
    private static func aliasDroppingDateSuffix(from model: String) -> String? {
        // -1 for the separator, -8 for the date.
        guard let separator = model.index(model.endIndex, offsetBy: -9, limitedBy: model.startIndex),
              separator > model.startIndex,
              model[separator] == "-"
        else {
            return nil
        }

        let digits = model[model.index(after: separator)...]
        guard digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }

        return String(model[..<separator])
    }

    static func bundled(in bundle: Bundle = .main) throws -> PricingCatalog {
        let resourceURL = bundle.url(forResource: "pricing-v1", withExtension: "json", subdirectory: "Resources")
            ?? bundle.url(forResource: "pricing-v1", withExtension: "json")

        guard let resourceURL else {
            throw PricingCatalogError.missingResource(name: "pricing-v1", extension: "json")
        }

        let data = try Data(contentsOf: resourceURL)
        return try JSONDecoder().decode([PricingEntry].self, from: data).asCatalog()
    }
}

enum PricingCatalogError: Error, Equatable {
    case missingResource(name: String, extension: String)
}

private extension Array where Element == PricingEntry {
    func asCatalog() -> PricingCatalog {
        PricingCatalog(entries: self)
    }
}
