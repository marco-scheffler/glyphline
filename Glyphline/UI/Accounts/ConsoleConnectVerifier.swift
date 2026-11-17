import Foundation

/// Decides which Console organisations an account can connect, by doing the
/// thing: the organisation list, then the credit balance of every API
/// organisation in it.
///
/// Pure — the navigation is passed in — so the rules can be tested without a
/// browser. The sign-in window hands in its own `fetch(_:classify:)`; main-actor
/// isolated so that method can be passed without being sent across actors.
///
/// An organisation whose billing the user may not read (a team org, 403
/// `permission_denied`) is dropped rather than failing the connect; only when
/// nothing is left does the connect fail.
@MainActor
enum ConsoleConnectVerifier {
    static func verify(
        fetch: (URL, (String, Int?) -> Result<Data, RateWindowSourceError>) async -> Result<Data, RateWindowSourceError>
    ) async -> Result<[ConsoleOrganization], RateWindowSourceError> {
        let candidates: [ConsoleOrganization]
        switch await fetch(ClaudeWebEndpoints.consoleOrganizations, ClaudeWebResponseClassifier.classifyConsoleOrganizations) {
        case .failure(let error):
            return .failure(error)
        case .success(let data):
            guard let decoded = try? ConsoleOrganizationsResponse.apiOrganizations(from: data) else {
                return .failure(.unexpectedResponseShape)
            }
            candidates = decoded
        }

        var connected: [ConsoleOrganization] = []
        var firstOtherError: RateWindowSourceError?
        for organization in candidates {
            guard let url = ClaudeWebEndpoints.consoleCredits(organizationID: organization.id) else { continue }
            switch await fetch(url, ClaudeWebResponseClassifier.classifyConsoleCredits) {
            case .success:
                connected.append(organization)
            case .failure(.notAvailable):
                continue
            case .failure(let error):
                if firstOtherError == nil { firstOtherError = error }
            }
        }

        if !connected.isEmpty { return .success(connected) }
        return .failure(firstOtherError ?? .notAvailable)
    }
}
