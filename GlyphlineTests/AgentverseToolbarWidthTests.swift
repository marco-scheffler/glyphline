import AppKit
import XCTest
@testable import Glyphline

/// Does the toolbar fit?
///
/// The circuit control collapsed into the overflow chevron once before, which is
/// what a toolbar does when its items do not fit and is how the five circuits
/// became unreachable. Tabs are wider than a menu, so this measures the labels
/// rather than assuming — with real text metrics, no window and no clicking.
///
/// The numbers below are AppKit's own: a segmented control's segment is its
/// label plus horizontal padding, and the toolbar spans the whole window, whose
/// minimum is 900 points.
final class AgentverseToolbarWidthTests: XCTestCase {
    /// Both controls are `.segmented`, which is the small system font.
    private let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    /// Per segment, either side of the label. Measured generously on purpose:
    /// an estimate that flatters the layout is worth nothing here.
    private let segmentPadding: CGFloat = 26
    private let windowMinimum: CGFloat = 900

    private func width(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    private func segmented(_ labels: [String]) -> CGFloat {
        labels.reduce(0) { $0 + width($1) + segmentPadding }
    }

    func testTheToolbarFitsAtTheWindowsMinimumWidth() throws {
        let circuits = try XCTUnwrap(try? CircuitCatalog.bundled())
            .entriesInPickerOrder.map(\.short)
        let weather = WeatherChoice.allCases.map(\.label)

        let circuitTabs = segmented(circuits)
        let weatherTabs = segmented(weather)
        // The rest of the toolbar, as the window declares it: the time slider,
        // the local-time readout at its declared minimum, the "Now" button and
        // the refresh button, plus the spacing between the seven items.
        let slider: CGFloat = 120
        let clock: CGFloat = 62
        let nowButton = width("Now") + 24
        let refreshButton: CGFloat = 32
        let spacing: CGFloat = 8 * 7

        let total = circuitTabs + weatherTabs + slider + clock + nowButton
            + refreshButton + spacing

        XCTAssertLessThanOrEqual(
            total, windowMinimum,
            "the toolbar wants \(Int(total.rounded())) points at a window minimum of "
            + "\(Int(windowMinimum)); circuits \(Int(circuitTabs.rounded())), weather "
            + "\(Int(weatherTabs.rounded())) — over the minimum the toolbar drops "
            + "items into the overflow chevron, which is the bug this replaced")
    }

    /// The one segment that used to be twice the width of its neighbours.
    func testNoWeatherSegmentIsMuchWiderThanTheOthers() {
        let widths = WeatherChoice.allCases.map { width($0.label) }
        let widest = try? XCTUnwrap(widths.max())
        let narrowest = try? XCTUnwrap(widths.min())

        XCTAssertLessThan((widest ?? 0) / (narrowest ?? 1), 2,
                          "a segment twice its neighbours' width is what pushed the "
                          + "circuit control into the overflow menu")
    }
}
