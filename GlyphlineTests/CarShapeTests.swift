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

    /// Four of them: a car with three corners lit is not showing hazards.
    func testThereAreFourHazardMarkers() {
        let box = CarShape.hazards.boundingRect

        XCTAssertFalse(CarShape.hazards.isEmpty)
        XCTAssertGreaterThan(box.width, 0.5)
        XCTAssertGreaterThan(box.height, 0.2)
    }

    func testTheStripeRunsAlongTheCarRatherThanAcrossIt() {
        let stripe = CarShape.stripe.boundingRect

        XCTAssertGreaterThan(stripe.width, stripe.height)
        XCTAssertEqual(stripe.midY, 0, accuracy: 0.001)
    }
}
