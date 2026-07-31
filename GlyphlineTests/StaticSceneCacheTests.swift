import CoreGraphics
import XCTest
@testable import Glyphline

/// Counts builds from inside a detached build closure, which is why it is an
/// actor rather than a captured `var`: the closure is `@Sendable` and runs off
/// the main actor.
private actor BuildCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

/// A fresh one-pixel image per call. Freshness is the point: the tests below
/// distinguish "served from the cache" from "built again" by object identity,
/// which only works if two builds cannot hand back the same instance by
/// accident. At file scope because it is called from inside a `@Sendable` build
/// closure, which may not capture the test case.
private func freshImage() -> CGImage? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
              data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
          )
    else { return nil }
    return context.makeImage()
}

@MainActor
final class StaticSceneCacheTests: XCTestCase {
    private func key(circuit: String = "monaco",
                     size: CGSize = CGSize(width: 800, height: 600),
                     scale: Int = 1,
                     elevation: Double = 30,
                     azimuth: Double = 250,
                     weather: Weather = .clear) -> StaticSceneKey {
        StaticSceneKey(circuit: circuit, size: size, scale: scale,
                       elevation: elevation, azimuth: azimuth, weather: weather)
    }

    // MARK: - Hits

    func testTheSameKeyIsServedWithoutBuildingAgain() async throws {
        let cache = StaticSceneCache(limit: 4)
        let counter = BuildCounter()
        let target = self.key()

        let first = await cache.image(for: target) { _ in
            await counter.record()
            return freshImage()
        }
        let second = await cache.image(for: target) { _ in
            await counter.record()
            return freshImage()
        }

        let built = await counter.count
        XCTAssertEqual(built, 1, "a second request for the same key must not rebuild")
        XCTAssertTrue(first === second, "the cached image must be the very same object")
    }

    /// Every field of the key must actually take part in the key. A field that
    /// is stored but not hashed would leave the scene showing the old circuit
    /// after a switch — a bug that looks like a stale view, not like a cache.
    func testEveryFieldOfTheKeySeparatesEntries() async throws {
        let variants: [StaticSceneKey] = [
            key(),
            key(circuit: "spa"),
            key(size: CGSize(width: 801, height: 600)),
            key(scale: 2),
            key(elevation: 60),
            key(azimuth: 120),
            key(weather: .rain),
        ]

        let cache = StaticSceneCache(limit: variants.count)
        let counter = BuildCounter()
        for variant in variants {
            _ = await cache.image(for: variant) { _ in
                await counter.record()
                return freshImage()
            }
        }

        let built = await counter.count
        XCTAssertEqual(built, variants.count,
                       "each of circuit, size, scale, elevation, azimuth and weather "
                       + "must produce a key of its own")
    }

    // MARK: - Buckets

    /// The sun moves continuously. Without quantisation every frame would carry
    /// a new key and the cache would never hit once.
    func testElevationsInsideOneBucketShareAKey() {
        XCTAssertEqual(key(elevation: 30.0), key(elevation: 31.9))
        XCTAssertNotEqual(key(elevation: 30.0), key(elevation: 32.0))
    }

    func testAzimuthsInsideOneBucketShareAKey() {
        XCTAssertEqual(key(azimuth: 250.0), key(azimuth: 254.9))
        XCTAssertNotEqual(key(azimuth: 250.0), key(azimuth: 255.0))
    }

    /// Rounding, not truncation: a canvas that grows by half a point is the same
    /// picture, and the two directions must not be treated differently.
    func testCanvasSizeIsRounded() {
        XCTAssertEqual(key(size: CGSize(width: 800.2, height: 600.4)),
                       key(size: CGSize(width: 799.8, height: 599.6)))
    }

    // MARK: - Bound

    /// Each entry is a full-canvas bitmap — several megabytes. A cache that only
    /// ever grows would hold one per window size the user ever dragged through.
    func testTheCacheEvictsRatherThanGrowing() async throws {
        let cache = StaticSceneCache(limit: 2)
        let counter = BuildCounter()

        func request(_ circuit: String) async {
            _ = await cache.image(for: key(circuit: circuit)) { _ in
                await counter.record()
                return freshImage()
            }
        }

        await request("monaco")
        await request("spa")
        await request("suzuka")

        XCTAssertEqual(cache.count, 2, "the cache must not grow past its limit")

        // Monaco was the least recently used of the three, so it is the one that
        // went. Asking for it again has to build.
        await request("monaco")
        let built = await counter.count
        XCTAssertEqual(built, 4, "the evicted entry must be rebuilt, not served stale")

        // Spa was evicted in turn by monaco's return; suzuka is still resident.
        await request("suzuka")
        let afterHit = await counter.count
        XCTAssertEqual(afterHit, 4, "a resident entry must still hit after an eviction")
    }

    // MARK: - Corner names

    /// Monaco and Las Vegas are the two circuits the picker opens on and the two
    /// OpenStreetMap names no corner on. Anything that assumed at least one
    /// label would fail on exactly the default circuit and nowhere else.
    func testACircuitWithoutNamedCornersDrawsNoLabelsAndStillBuilds() throws {
        let catalog = try CircuitCatalog.bundled()
        let size = CGSize(width: 400, height: 300)
        let light = SceneLight.make(elevation: 30, azimuth: 250,
                                    mapRotation: 0, weather: .clear)

        for key in ["monaco", "vegas"] {
            let circuit = try XCTUnwrap(catalog.circuit(key))
            XCTAssertTrue(circuit.corners.isEmpty, "\(key) is expected to carry no corners")
            XCTAssertTrue(
                StaticSceneImage.cornerLabels(for: circuit,
                                              fit: CircuitFit(circuit: circuit, in: size)).isEmpty,
                "\(key): a circuit with no named corners must produce no labels"
            )
            XCTAssertNotNil(
                StaticSceneImage.build(circuit: circuit, size: size, scale: 1, light: light),
                "\(key): the picture must still build with nothing to label"
            )
        }
    }

    /// The other side of it: a circuit that has names must place them, off the
    /// road and somewhere finite, or the labels would be drawn at NaN and vanish.
    func testANamedCornerIsPlacedClearOfItsPoint() throws {
        let catalog = try CircuitCatalog.bundled()
        let circuit = try XCTUnwrap(catalog.circuit("spa"))
        let fit = CircuitFit(circuit: circuit, in: CGSize(width: 800, height: 600))
        let labels = StaticSceneImage.cornerLabels(for: circuit, fit: fit)

        XCTAssertEqual(labels.count, circuit.corners.count)
        for (label, corner) in zip(labels, circuit.corners) {
            XCTAssertEqual(label.name, corner.name)
            XCTAssertTrue(label.at.x.isFinite && label.at.y.isFinite)
            let point = fit.point(circuit.points[corner.idx])
            XCTAssertGreaterThan(hypot(label.at.x - point.x, label.at.y - point.y),
                                 fit.width(metres: 19, atLeast: 9) / 2,
                                 "\(corner.name): the caption sits on the road")
        }
    }
}
