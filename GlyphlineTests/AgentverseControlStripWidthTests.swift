import AppKit
import XCTest
@testable import Glyphline

/// Does the control strip fit?
///
/// The controls used to live in the toolbar, where they shared a row with the
/// window title and drew on top of one another. They now have a full-width strip
/// of their own, which is what this measures — with real text metrics, no window
/// and no clicking. The arithmetic that said the toolbar fitted by 10 points was
/// wrong because it left the title out; the strip has no title in its row, so
/// the window's 900 point minimum really is the budget here.
final class AgentverseControlStripWidthTests: XCTestCase {
    /// Both pickers are `.segmented`, which is the small system font.
    private let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    /// The strip's group captions, as `AgentverseControlStrip.caption` styles
    /// them: 9.5 point semibold, plus 1.4 points of kerning per character.
    private let captionFont = NSFont.systemFont(ofSize: 9.5, weight: .semibold)
    private let captionKerning: CGFloat = 1.4
    /// Per segment, either side of the label. Measured generously on purpose:
    /// an estimate that flatters the layout is worth nothing here.
    private let segmentPadding: CGFloat = 26
    private let windowMinimum: CGFloat = 900

    private func width(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    private func captionWidth(_ text: String) -> CGFloat {
        (text.uppercased() as NSString).size(withAttributes: [.font: captionFont]).width
            + captionKerning * CGFloat(text.count)
    }

    private func segmented(_ labels: [String]) -> CGFloat {
        labels.reduce(0) { $0 + width($1) + segmentPadding }
    }

    /// The two picker groups side by side, plus the strip's own padding: the
    /// first row of the wrapped layout, and the part of the one-row layout that
    /// cannot give.
    private func pickerRowWidth() throws -> CGFloat {
        let circuits = try XCTUnwrap(try? CircuitCatalog.bundled())
            .entriesInPickerOrder.map(\.short)
        let weather = WeatherChoice.allCases.map(\.label)
        // One gap of 14 between the groups, 7 inside each, 13 of padding either
        // end of the strip.
        let spacing: CGFloat = 14 + 7 * 2 + 13 * 2

        return segmented(circuits) + segmented(weather)
            + captionWidth("Circuit") + captionWidth("Weather") + spacing
    }

    /// The time group: caption, slider, clock and the way back to now.
    private func timeRowWidth(slider: CGFloat) -> CGFloat {
        // Three gaps of 9 inside the group and 13 of padding either end.
        let spacing: CGFloat = 9 * 3 + 13 * 2
        return captionWidth("Local time") + slider + 62 + width("Now") + 24 + spacing
    }

    /// Each row of the wrapped layout fits the window's minimum — which is the
    /// claim that matters, because at the minimum the strip wraps.
    func testEachControlRowFitsAtTheWindowsMinimumWidth() throws {
        let pickers = try pickerRowWidth()
        let time = timeRowWidth(slider: 120)

        XCTAssertLessThanOrEqual(
            pickers, windowMinimum,
            "the circuit and weather tabs want \(Int(pickers.rounded())) points at a "
            + "window minimum of \(Int(windowMinimum)); over the minimum they overlap, "
            + "which is the bug this replaced")
        XCTAssertLessThanOrEqual(
            time, windowMinimum,
            "the time controls want \(Int(time.rounded())) points at a window minimum "
            + "of \(Int(windowMinimum))")
    }

    /// Why the strip wraps at all: all three groups on one row do not fit the
    /// window's minimum, even with the slider held to the 160 points the one-row
    /// layout gives it. This is the measurement the toolbar version got wrong.
    func testAllThreeGroupsOnOneRowDoNotFitTheWindowsMinimum() throws {
        // The rows measured separately double-count the strip's padding, so it
        // comes off once.
        let oneRow = try pickerRowWidth() + timeRowWidth(slider: 160) + 14 - 13 * 2

        XCTAssertGreaterThan(
            oneRow, windowMinimum,
            "one row now fits \(Int(oneRow.rounded())) points into "
            + "\(Int(windowMinimum)); if that is real, the wrapped fallback is dead "
            + "code and the strip should simply be one row")
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

    /// Short labels, and distinct ones: the strip shows nothing else about a
    /// circuit, so two circuits that read the same are two unusable tabs.
    func testCircuitTabLabelsAreShortAndUnique() throws {
        let shorts = try XCTUnwrap(try? CircuitCatalog.bundled())
            .entriesInPickerOrder.map(\.short)

        XCTAssertEqual(shorts.count, 5)
        XCTAssertEqual(Set(shorts).count, shorts.count, "two tabs read the same")
        for short in shorts {
            XCTAssertLessThanOrEqual(short.count, 10, "\(short) is not a short name")
        }
    }

    /// What the weather picker offers, spelled out: `allCases` is synthesised
    /// from `Weather`, so a new sky would silently appear as a sixth segment.
    func testWeatherPickerOffersTheFiveKnownSkies() {
        XCTAssertEqual(WeatherChoice.allCases.map(\.label),
                       ["Auto", "Clear", "Cloud", "Rain", "Fog"])
    }
}
