import Foundation

/// One entry of `GET https://claude.ai/api/organizations`.
///
/// Deliberately partial, and each omission is a decision rather than an oversight:
///
/// - `name` carries the user's email address. This app has no use for it, so it
///   is never decoded, never stored and never rendered.
/// - `settings` is a large object of internal feature flags, several carrying
///   codenames, all irrelevant here and all liable to change. Same discipline as
///   the usage response's codename fields.
/// - the numeric `id` is *not* what the usage path wants. `uuid` is.
struct ClaudeOrganization: Decodable, Equatable, Sendable {
    /// The value the usage endpoint's path is built from.
    var uuid: String
    /// What the organisation is entitled to. The only thing selection looks at.
    var capabilities: [String]

    private enum CodingKeys: String, CodingKey {
        case uuid
        case capabilities
    }

    init(uuid: String, capabilities: [String]) {
        self.uuid = uuid
        self.capabilities = capabilities
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try container.decode(String.self, forKey: .uuid)
        // An organisation with no capabilities list is simply not the
        // subscription; that is not a reason to fail the whole response.
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
    }
}

/// Decodes the organisations list and picks the subscription out of it.
///
/// **The response is an array, and one login can carry several organisations of
/// which only one is the subscription.** The reference account has two: a Max
/// subscription, and an API organisation that has nothing to do with
/// subscription rate windows.
enum ClaudeOrganizationsResponse {
    /// The capability that marks the subscription whose quota this app reads.
    static let subscriptionCapability = "claude_max"

    static func decode(_ data: Data) throws -> [ClaudeOrganization] {
        try JSONDecoder().decode([ClaudeOrganization].self, from: data)
    }

    /// Selection is **by capability, never by position.**
    ///
    /// Taking the first element happened to be correct on the reference account,
    /// but nothing guarantees the ordering, and querying usage for the API
    /// organisation would return figures that are not the subscription's — a
    /// wrong-number failure rather than a visible one, which is the class this
    /// project works hardest to avoid.
    ///
    /// `nil` means the login has no Max subscription. That is reported as
    /// `notAvailable` rather than guessed around: there is no correct
    /// organisation to fall back to.
    ///
    /// Several matches would mean several Max subscriptions under one login,
    /// which is out of scope for this design — one app account maps to one web
    /// session maps to one organisation — so the first match is taken.
    static func subscriptionOrganizationID(in organizations: [ClaudeOrganization]) -> String? {
        organizations.first { $0.capabilities.contains(subscriptionCapability) }?.uuid
    }
}
