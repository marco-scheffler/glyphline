import XCTest
@testable import Glyphline

/// The one decision in the loader that can be asked without a web view. The
/// loader itself has no automated coverage by construction — driving it would
/// open a browser process and reach claude.ai.
final class ClaudeWebPageLoaderTests: XCTestCase {
    /// The status code decides `sessionExpired` against `transportFailure`, so
    /// only the document's own response may record it — never a subframe that
    /// answered after it.
    func testOnlyTheMainFrameSpeaksForThePage() {
        XCTAssertEqual(ClaudeWebPageLoader.responseDecision(isForMainFrame: true, canShowMIMEType: true), .allow)
        XCTAssertEqual(ClaudeWebPageLoader.responseDecision(isForMainFrame: false, canShowMIMEType: true), .allowSubframe)
    }

    /// An unrenderable document fails the fetch rather than becoming a download
    /// that never finishes. An unrenderable subframe is only cancelled: the page
    /// it sits in may still be the JSON the fetch came for.
    func testAnUnrenderableResponseFailsTheFetchOnlyInTheMainFrame() {
        XCTAssertEqual(
            ClaudeWebPageLoader.responseDecision(isForMainFrame: true, canShowMIMEType: false),
            .failUnreadable
        )
        XCTAssertEqual(
            ClaudeWebPageLoader.responseDecision(isForMainFrame: false, canShowMIMEType: false),
            .cancelSubframe
        )
    }
}
