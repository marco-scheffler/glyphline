import SwiftUI
import XCTest
@testable import Glyphline

final class CarShapeTests: XCTestCase {
    /// 4.57 m long and 1.90 m wide is a real GT3 RS. The car is drawn far larger
    /// than scale — at Monaco's fit a real one would be 1.8 pt long and invisible
    /// — but the proportion is what makes the shape read as a car, so that is
    /// what is kept.
    func testTheCarHasTheProportionsOfARealOne() {
        XCTAssertEqual(CarShape.aspectRatio, 4.57 / 1.90, accuracy: 0.01)
    }

    func testTheBodyIsOneUnitLongAndCentredOnTheOrigin() {
        let box = CarShape.body.boundingRect

        XCTAssertEqual(box.width, 1, accuracy: 0.001)
        XCTAssertEqual(box.midX, 0, accuracy: 0.001)
        XCTAssertEqual(box.midY, 0, accuracy: 0.001)
    }

    /// A body as wide as it is long would be a blob, whatever else is drawn on
    /// top of it.
    func testTheBodyIsAsNarrowAsTheProportionSays() {
        let box = CarShape.body.boundingRect

        XCTAssertEqual(box.height, 1 / CarShape.aspectRatio, accuracy: 0.02)
    }

    /// The wing is the one feature separating a GT3 RS from any other car seen
    /// from above, and it stands proud of the tail rather than sitting inside
    /// the outline.
    func testTheWingIsWiderThanTheTailAndBehindIt() {
        let wing = CarShape.wing.boundingRect
        let body = CarShape.body.boundingRect

        XCTAssertGreaterThan(wing.width, 0)
        XCTAssertEqual(wing.minX, body.minX, accuracy: 0.001)
        XCTAssertGreaterThan(wing.height, 0.9 * body.height)
    }

    /// Four of them: a car with three corners lit is not showing hazards, and
    /// the bounding box alone cannot tell the difference — drop any one marker
    /// and the remaining three still span both columns and both rows. So the
    /// markers are counted as well as placed: `addRect` opens each rectangle
    /// with a `.move`, so the `.move` elements are the markers.
    func testThereAreFourHazardMarkers() {
        let box = CarShape.hazards.boundingRect

        var corners = 0
        CarShape.hazards.forEach { element in
            if case .move = element { corners += 1 }
        }
        XCTAssertEqual(corners, 4)

        XCTAssertFalse(CarShape.hazards.isEmpty)
        XCTAssertGreaterThan(box.width, 0.5)
        XCTAssertGreaterThan(box.height, 0.2)
    }

    /// A bound, not containment. The markers are meant to sit slightly proud of
    /// the body — 0.0110 units, 0.13 pt on a 12 pt car — because a light that
    /// grazes the outline reads as sitting on the corner. Pinning them inside an
    /// outline they were never meant to respect would be wrong; what this stops
    /// is a later edit growing them into a halo around the car.
    func testTheHazardsDoNotGrowIntoAHaloAroundTheCar() {
        XCTAssertLessThan(CarShape.hazards.boundingRect.height,
                          1.10 * CarShape.body.boundingRect.height)
    }

    func testTheStripeRunsAlongTheCarRatherThanAcrossIt() {
        let stripe = CarShape.stripe.boundingRect

        XCTAssertGreaterThan(stripe.width, stripe.height)
        XCTAssertEqual(stripe.midY, 0, accuracy: 0.001)
    }
}
