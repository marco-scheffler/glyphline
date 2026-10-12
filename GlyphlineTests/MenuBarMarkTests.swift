import AppKit
import XCTest
@testable import Glyphline

final class MenuBarMarkTests: XCTestCase {
    /// A template image is what lets the menu bar tint it for light, dark and
    /// the pressed highlight. A non-template mark is black on a dark menu bar.
    func testTheMarkIsATemplateOfMenuBarSize() {
        let image = MenuBarMark.image()
        XCTAssertTrue(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
    }

    func testTheMarkDrawsSomething() throws {
        let image = MenuBarMark.image()
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 36, height: 36))
        NSGraphicsContext.restoreGraphicsState()

        var inked = 0
        for x in 0..<36 { for y in 0..<36 where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { inked += 1 } }
        XCTAssertGreaterThan(inked, 60, "arc, needle and hub should cover a visible share of the square")
        XCTAssertLessThan(inked, 36 * 36 / 2, "a mark, not a filled square")
    }
}
