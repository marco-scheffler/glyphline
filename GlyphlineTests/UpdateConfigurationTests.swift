import Foundation
import XCTest

@testable import Glyphline

/// The two Info.plist entries the updater cannot work without.
///
/// Worth a test because both fail *quietly*. Sparkle reads them out of the
/// bundle at runtime: a missing feed URL means the app never finds an update and
/// says nothing, and a wrong public key means every signature check fails, which
/// looks from outside like a server problem rather than a typo. Neither shows up
/// in a build, and neither shows up in any other test — the app launches fine
/// without them.
///
/// They also cannot be checked by reading `Glyphline/Info.plist` as text: the
/// values there are build settings until a build expands them. This reads them
/// back out of the bundle that was actually produced.
final class UpdateConfigurationTests: XCTestCase {
    /// The app bundle rather than the test bundle — the tests are injected into
    /// the app, so any type from the app target names the right one.
    private var appBundle: Bundle { Bundle(for: AppSettingsStore.self) }

    private func value(_ key: String) throws -> String {
        try XCTUnwrap(
            appBundle.object(forInfoDictionaryKey: key) as? String,
            "\(key) is missing from the built app's Info.plist"
        )
    }

    /// There is a feed, and it is fetched over TLS.
    ///
    /// The scheme is the security property, not a style preference. Sparkle
    /// verifies a signature over the download, so plain HTTP would not let an
    /// attacker install arbitrary code — but it would let anyone on the path see
    /// and suppress the fact that an update exists, which is enough to keep a
    /// user on a version whose bugs are public.
    func testTheAppKnowsWhereToLookForUpdates() throws {
        let url = try XCTUnwrap(
            URL(string: try value("SUFeedURL")),
            "SUFeedURL is not a URL"
        )

        XCTAssertEqual(url.scheme, "https", "the update feed is fetched in the clear")
        XCTAssertNotNil(url.host, "SUFeedURL has no host")
    }

    /// And it carries the public half of the key its updates are signed with.
    ///
    /// The length is the assertion worth having: an Ed25519 public key is
    /// exactly 32 bytes, so a truncated paste, a stray newline or the private
    /// key pasted here by mistake all fail this rather than failing at a user's
    /// first update check.
    func testTheAppCarriesThePublicKeyItsUpdatesAreSignedWith() throws {
        let key = try value("SUPublicEDKey")
        let decoded = try XCTUnwrap(
            Data(base64Encoded: key),
            "SUPublicEDKey is not base64"
        )

        XCTAssertEqual(decoded.count, 32, "an Ed25519 public key is 32 bytes, this is \(decoded.count)")
    }

    /// Checked once a day. Named here so that "daily" is a decision the project
    /// made rather than whatever Sparkle's default happens to be in the version
    /// it is pinned to.
    func testTheAppChecksDaily() throws {
        let interval = try XCTUnwrap(
            appBundle.object(forInfoDictionaryKey: "SUScheduledCheckInterval") as? Int,
            "SUScheduledCheckInterval is missing from the built app's Info.plist"
        )

        XCTAssertEqual(interval, 86_400)
    }
}
