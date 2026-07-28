import Foundation

enum ProviderID: String, CaseIterable, Codable, Sendable {
    case openAI
    case cursor
    case claude

    var displayName: String {
        switch self {
        case .openAI:
            "OpenAI"
        case .cursor:
            "Cursor"
        case .claude:
            "Claude"
        }
    }
}
