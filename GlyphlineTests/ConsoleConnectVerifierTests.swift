import XCTest
@testable import Glyphline

final class ConsoleConnectVerifierTests: XCTestCase {
    private static let organizations = URL(string: "https://platform.claude.com/api/organizations")!

    private static func credits(_ id: String) -> URL {
        URL(string: "https://platform.claude.com/api/organizations/\(id)/prepaid/credits")!
    }

    /// A scripted fetch: answers by URL, ignoring the classifier.
    private func verify(
        _ answers: [URL: Result<Data, RateWindowSourceError>]
    ) async -> Result<[ConsoleOrganization], RateWindowSourceError> {
        await ConsoleConnectVerifier.verify { url, _ in
            answers[url] ?? .failure(.transportFailure)
        }
    }

    private static func orgList(_ entries: String) -> Result<Data, RateWindowSourceError> {
        .success(Data(entries.utf8))
    }

    func testKeepsEveryApiOrganizationWhoseCreditsLoad() async {
        let result = await verify([
            Self.organizations: Self.orgList("""
            [{"uuid": "chat", "capabilities": ["chat"]},
             {"uuid": "api-1", "capabilities": ["api"]},
             {"uuid": "api-2", "capabilities": ["chat", "api"]}]
            """),
            Self.credits("api-1"): .success(Data("{}".utf8)),
            Self.credits("api-2"): .success(Data("{}".utf8)),
        ])
        XCTAssertEqual(result, .success([ConsoleOrganization(id: "api-1"), ConsoleOrganization(id: "api-2")]))
    }

    func testDropsAnOrganizationWithoutBillingAccess() async {
        let result = await verify([
            Self.organizations: Self.orgList("""
            [{"uuid": "team", "capabilities": ["api"]},
             {"uuid": "own", "capabilities": ["api"]}]
            """),
            Self.credits("team"): .failure(.notAvailable),
            Self.credits("own"): .success(Data("{}".utf8)),
        ])
        XCTAssertEqual(result, .success([ConsoleOrganization(id: "own")]))
    }

    func testNoApiOrganizationIsNotAvailable() async {
        let result = await verify([
            Self.organizations: Self.orgList("""
            [{"uuid": "chat", "capabilities": ["chat", "claude_max"]}]
            """),
        ])
        XCTAssertEqual(result, .failure(.notAvailable))
    }

    func testEveryOrganizationDeniedIsNotAvailable() async {
        let result = await verify([
            Self.organizations: Self.orgList("""
            [{"uuid": "a", "capabilities": ["api"]},
             {"uuid": "b", "capabilities": ["api"]}]
            """),
            Self.credits("a"): .failure(.notAvailable),
            Self.credits("b"): .failure(.notAvailable),
        ])
        XCTAssertEqual(result, .failure(.notAvailable))
    }

    func testAnExpiredSessionIsReportedAsSuch() async {
        let result = await verify([
            Self.organizations: .failure(.sessionExpired),
        ])
        XCTAssertEqual(result, .failure(.sessionExpired))
    }
}
