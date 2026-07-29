import XCTest
@testable import Glyphline

final class ClaudeOrganizationsDTOsTests: XCTestCase {
    /// Shaped like the reference account: a Max subscription and an API
    /// organisation, with the subscription deliberately *not* first.
    private let twoOrganizations = #"""
    [
      {
        "uuid": "11111111-1111-1111-1111-111111111111",
        "id": 4001,
        "name": "someone@example.com's API Organization",
        "capabilities": ["api", "api_individual"],
        "rate_limit_tier": "default_api_evaluation",
        "billing_type": "api"
      },
      {
        "uuid": "22222222-2222-2222-2222-222222222222",
        "id": 4002,
        "name": "someone@example.com's Organization",
        "capabilities": ["chat", "claude_max"],
        "rate_limit_tier": "default_claude_max_20x",
        "billing_type": "subscription",
        "settings": {
          "preview_feature_uses_parameters": null,
          "some_internal_codename": true
        }
      }
    ]
    """#

    func testSelectionIsByCapabilityNotByPosition() throws {
        // The API organisation comes first. Taking element zero would query usage
        // for figures that are not the subscription's — a wrong number rather
        // than a visible failure.
        let organizations = try ClaudeOrganizationsResponse.decode(Data(twoOrganizations.utf8))
        XCTAssertEqual(
            ClaudeOrganizationsResponse.subscriptionOrganizationID(in: organizations),
            "22222222-2222-2222-2222-222222222222"
        )
    }

    func testTheSelectedValueIsTheUUIDAndNotTheNumericID() throws {
        let organizations = try ClaudeOrganizationsResponse.decode(Data(twoOrganizations.utf8))
        let selected = ClaudeOrganizationsResponse.subscriptionOrganizationID(in: organizations)

        XCTAssertEqual(selected, "22222222-2222-2222-2222-222222222222")
        XCTAssertNotEqual(selected, "4002")
    }

    func testNoMaxOrganisationSelectsNothingRatherThanFallingBackToTheFirst() throws {
        let body = #"""
        [
          {"uuid": "aaaa", "capabilities": ["api", "api_individual"]},
          {"uuid": "bbbb", "capabilities": ["chat"]}
        ]
        """#
        let organizations = try ClaudeOrganizationsResponse.decode(Data(body.utf8))
        XCTAssertNil(ClaudeOrganizationsResponse.subscriptionOrganizationID(in: organizations))
    }

    func testAnOrganisationWithoutCapabilitiesDoesNotBreakTheResponse() throws {
        let body = #"""
        [
          {"uuid": "aaaa"},
          {"uuid": "bbbb", "capabilities": ["claude_max"]}
        ]
        """#
        let organizations = try ClaudeOrganizationsResponse.decode(Data(body.utf8))

        XCTAssertEqual(organizations.count, 2)
        XCTAssertEqual(organizations[0].capabilities, [])
        XCTAssertEqual(ClaudeOrganizationsResponse.subscriptionOrganizationID(in: organizations), "bbbb")
    }

    func testAnEmptyListSelectsNothing() throws {
        let organizations = try ClaudeOrganizationsResponse.decode(Data("[]".utf8))
        XCTAssertNil(ClaudeOrganizationsResponse.subscriptionOrganizationID(in: organizations))
    }

    // MARK: - Endpoints

    func testTheUsageURLCarriesTheOrganisationID() throws {
        let url = try XCTUnwrap(ClaudeWebEndpoints.usage(organizationID: "22222222-2222-2222-2222-222222222222"))
        XCTAssertEqual(
            url.absoluteString,
            "https://claude.ai/api/organizations/22222222-2222-2222-2222-222222222222/usage"
        )
    }

    func testAnOrganisationIDCannotSmuggleInAnotherPath() throws {
        // The id arrives from a response rather than from a constant, so a value
        // carrying a separator must not silently address a different route.
        let url = try XCTUnwrap(ClaudeWebEndpoints.usage(organizationID: "abc/../../admin"))
        XCTAssertEqual(url.pathComponents.count, 5)
        XCTAssertFalse(url.absoluteString.hasSuffix("/admin/usage"))
    }

    func testAnEmptyOrganisationIDHasNoUsageURL() {
        XCTAssertNil(ClaudeWebEndpoints.usage(organizationID: ""))
    }
}
