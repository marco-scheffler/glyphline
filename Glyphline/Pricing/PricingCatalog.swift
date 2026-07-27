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
        return entries.first { $0.providerID == providerID && $0.model == model }
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
