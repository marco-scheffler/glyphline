import AppKit
import SwiftUI
import XCTest

@testable import Glyphline

/// The bar on an account's quota card, read back as pixels.
///
/// What this holds is which end of the track carries paint. The card's figure
/// says "33 % free" and the bar beside it used to fill up as the window was
/// spent — so the number counted down while the bar counted up, and a window
/// with nothing left was drawn as a full bar. That is the one thing about this
/// view a structural test cannot see: the fill is a `Capsule` inside a
/// `GeometryReader`, and its width is only real once something has laid it out.
///
/// The menu bar panel's rows already drained (`QuotaBarRowView`), so this is
/// also what makes the two surfaces agree.
///
/// Rendered off screen through `NSHostingView` over an opaque backing, the same
/// technique `DashboardBackgroundTests` uses.
@MainActor
final class QuotaBarTests: XCTestCase {
    private let size = NSSize(width: 200, height: 9)

    // MARK: Fixtures

    /// A card with exactly the numbers a test names. `QuotaCardModel.make`
    /// derives these from a `RateWindow`; building one directly keeps a bar test
    /// from also depending on how a window is read.
    private func card(
        used: Double,
        pace: Double? = nil,
        state: QuotaCardState = .ok
    ) -> QuotaCardModel {
        QuotaCardModel(
            kind: .rollingFiveHours,
            usedFraction: used,
            headroomFraction: 1 - used,
            usedPercent: Int((used * 100).rounded()),
            headroomPercent: Int(((1 - used) * 100).rounded()),
            usageText: "\(Int((used * 100).rounded()))% used",
            headroomText: "\(Int(((1 - used) * 100).rounded()))% left",
            pacePosition: pace,
            paceText: nil,
            state: state
        )
    }

    /// One pixel of the rendered bar, in sRGB, 0…255 per channel.
    ///
    /// `x` is the position along the track in 0…1; the sample is taken at the
    /// track's vertical centre. The bar is drawn over black so that the
    /// translucent `.quaternary` track composites against something opaque —
    /// sampled over nothing it comes back as an almost transparent pixel whose
    /// channels say more about the alpha than about the paint.
    private func pixel(
        at x: Double,
        of card: QuotaCardModel
    ) throws -> (red: Double, green: Double, blue: Double) {
        let view = ZStack {
            Color.black
            QuotaBar(card: card)
        }
        .frame(width: size.width, height: size.height)

        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(origin: .zero, size: size)
        // Pinned so the render does not depend on the appearance of whichever
        // machine runs the suite: `.quaternary` and `.green` both resolve
        // differently in light aqua.
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(
            host.bitmapImageRepForCachingDisplay(in: host.bounds),
            "the hosting view gave no bitmap to render into"
        )
        host.cacheDisplay(in: host.bounds, to: rep)

        let column = Int((Double(rep.pixelsWide) - 1) * x)
        let row = rep.pixelsHigh / 2
        let raw = try XCTUnwrap(rep.colorAt(x: column, y: row), "no pixel at \(column)/\(row)")
        let color = try XCTUnwrap(
            raw.usingColorSpace(.sRGB),
            "the sampled pixel could not be expressed in sRGB"
        )

        return (
            red: Double(color.redComponent) * 255,
            green: Double(color.greenComponent) * 255,
            blue: Double(color.blueComponent) * 255
        )
    }

    /// How far a pixel leans towards the green the `.ok` tint is drawn in. The
    /// empty track is a neutral grey, so a green lead is what separates "painted"
    /// from "track", at any brightness the appearance happens to give either one.
    private func greenLead(
        _ pixel: (red: Double, green: Double, blue: Double)
    ) -> Double {
        pixel.green - pixel.red
    }

    private func luminance(
        _ pixel: (red: Double, green: Double, blue: Double)
    ) -> Double {
        0.2126 * pixel.red + 0.7152 * pixel.green + 0.0722 * pixel.blue
    }

    // MARK: What the bar means

    /// The assertion the change is for: a window with 20 % left paints a fifth of
    /// its track, not four fifths of it.
    ///
    /// The middle of the track is what decides it. Both readings paint the left
    /// end and leave the right end bare, so only a point between 0.2 and 0.8 can
    /// tell "what is left" from "what is spent" apart.
    func testTheBarPaintsWhatIsLeftRatherThanWhatIsSpent() throws {
        let spentFourFifths = card(used: 0.8)

        XCTAssertGreaterThan(
            greenLead(try pixel(at: 0.1, of: spentFourFifths)),
            30,
            "the leading fifth of the track carries no paint"
        )
        XCTAssertLessThan(
            greenLead(try pixel(at: 0.5, of: spentFourFifths)),
            20,
            "the middle of the track is painted, so the bar is still drawing what was spent"
        )
        XCTAssertLessThan(
            greenLead(try pixel(at: 0.9, of: spentFourFifths)),
            20,
            "the far end of the track is painted with only 20% left"
        )
    }

    /// An untouched window is a full bar — the reading that makes the bar a fuel
    /// gauge rather than an odometer.
    func testAnUntouchedWindowPaintsTheWholeTrack() throws {
        XCTAssertGreaterThan(
            greenLead(try pixel(at: 0.95, of: card(used: 0))),
            30,
            "a window with everything left does not reach the end of its track"
        )
    }

    /// And a spent one is an empty bar. This is the visible cost of the change:
    /// 0 % left draws no paint at all, so the row's coloured dot and its
    /// "0% left" text are what carry the state — which is how the menu bar
    /// panel's rows have always read.
    func testASpentWindowLeavesTheTrackEmpty() throws {
        let spent = card(used: 1, state: .spent)
        let sample = try pixel(at: 0.1, of: spent)

        XCTAssertLessThan(
            sample.red - sample.green,
            20,
            "a spent window still paints its track red"
        )
    }

    // MARK: The pace marker

    /// The marker mirrors with the bar. It marks where an even burn would have
    /// left the bar's edge by now, so on a draining bar it counts down too:
    /// four fifths through the window, an even burn leaves a fifth.
    ///
    /// Kept as arithmetic rather than pixels because the position is exact and a
    /// two-point line is not what a probe reads reliably.
    func testThePaceMarkerMirrorsTheBar() {
        XCTAssertEqual(QuotaBar(card: card(used: 0.5, pace: 0.8)).markerPosition ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertEqual(QuotaBar(card: card(used: 0.5, pace: 0)).markerPosition ?? -1, 1, accuracy: 0.0001)
        XCTAssertEqual(QuotaBar(card: card(used: 0.5, pace: 1)).markerPosition ?? -1, 0, accuracy: 0.0001)
        XCTAssertNil(
            QuotaBar(card: card(used: 0.5, pace: nil)).markerPosition,
            "a window with no pace to draw got a marker anyway"
        )
    }

    /// And the view draws it where that says. An exhausted window leaves the
    /// track bare, which makes the marker the only bright thing on it — so its
    /// side of the bar is the one a probe can find.
    func testTheMarkerIsDrawnAtTheMirroredPosition() throws {
        let spent = card(used: 1, pace: 0.75, state: .spent)

        XCTAssertGreaterThan(
            luminance(try pixel(at: 0.25, of: spent))
                - luminance(try pixel(at: 0.75, of: spent)),
            25,
            "the marker is not on the side the mirrored position puts it"
        )
    }

    /// The bar reads the same way its card's own figure does: the fill and the
    /// "% free" number over it are one quantity, not two that happen to add up.
    func testTheFillIsTheSameFigureTheCardPrints() {
        let sample = card(used: 0.67)

        XCTAssertEqual(QuotaBar(card: sample).fillFraction, sample.headroomFraction, accuracy: 0.0001)
    }
}
