import AppKit
import SwiftUI
import XCTest
@testable import Glyphline

/// Outside the class because a default argument cannot reference a member of
/// the type it is declared in.
private let parkedSession = ParkedAgentSession(
    sessionID: "S3", cwd: "/repo/c", gitBranch: "main",
    subagentCount: 0,
    lastActivityAt: Date(timeIntervalSince1970: 1_800_000_000),
    parkedAt: Date(timeIntervalSince1970: 1_800_003_600))

private let workingSession = AgentSession(
    id: "S1", cwd: "/repo/a", gitBranch: "main", activity: .working,
    lastActivityAt: Date(timeIntervalSince1970: 1_800_000_000))

private let waitingSession = AgentSession(
    id: "S2", cwd: "/repo/b", gitBranch: "main", activity: .waitingForYou,
    lastActivityAt: Date(timeIntervalSince1970: 1_800_000_000))

/// A rendered picture, hashed. The browser mockups needed Playwright and forced
/// software rasterisation for this; `ImageRenderer` does it in-process.
///
/// The point is not the hash itself but that stages 3b and 3c can be judged from
/// their first commit. The look was designed blind for hours, and every one of
/// the four bugs found late was found by looking at output rather than by
/// reading code.
///
/// Two layers are photographed here, because the scene has two.
///
/// `ImageRenderer` never runs a `.task`, so an `AgentverseScene` rendered in a
/// test never receives its cached world image and draws the vector fallback.
/// That is the right surface for everything the canvas draws per frame — the
/// cars, the spotlight, the blink — and the wrong one for everything the sun
/// touches, because the light only ever reaches the built picture. So the
/// lighting, the terrain and the track surface are photographed through
/// `StaticSceneImage.build`, which is the very code the window's cache calls.
@MainActor
final class AgentverseSnapshotTests: XCTestCase {
    /// The scene is lit at whatever instant it is handed, and the window now
    /// hands it the real clock. A snapshot taken at "now" would be a different
    /// picture every run, so these fix the instant — 2026-06-21 15:00 UTC, an
    /// afternoon over Monaco.
    private let instant = Date(timeIntervalSince1970: 1_781_708_400)

    /// 2026-06-21 10:00 UTC — midday over Monaco, which keeps UTC+2 in June.
    private let localNoon = Date(timeIntervalSince1970: 1_781_690_400)
    /// Twelve hours after `localNoon`: the same circuit with the sun under it.
    private let localMidnight = Date(timeIntervalSince1970: 1_781_733_600)

    private let size = CGSize(width: 900, height: 600)

    private func monaco() throws -> Circuit {
        try XCTUnwrap(CircuitCatalog.bundled().circuit("monaco"))
    }

    /// Every input is fixed but the ones a caller overrides, so each test can
    /// vary exactly one thing and know that nothing else accounts for a
    /// difference in bytes.
    private func scene(sessions: [AgentSession] = [workingSession, waitingSession],
                       parked: [ParkedAgentSession] = [parkedSession],
                       hovered: String? = nil,
                       frame: Int = 600)
    throws -> AgentverseScene {
        AgentverseScene(
            circuit: try monaco(),
            sessions: sessions,
            parked: parked,
            workTokens: ["S1": 2_600_000, "S2": 540_000],
            hovered: hovered,
            frame: frame,
            instant: instant,
            weather: .clear
        )
    }

    private func render(_ view: some View) throws -> Data {
        let renderer = ImageRenderer(content: view.frame(width: size.width,
                                                         height: size.height))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.nsImage)
        return try XCTUnwrap(image.tiffRepresentation)
    }

    // MARK: - The built world

    /// The same call the window's cache makes, with the sun placed over the
    /// circuit by the same two functions the scene uses.
    private func world(instant: Date, weather: Weather = .clear) throws -> CGImage {
        let circuit = try monaco()
        let sun = SunPosition.at(latitude: circuit.lat, longitude: circuit.lon,
                                 date: instant)
        let light = SceneLight.make(elevation: sun.elevation, azimuth: sun.azimuth,
                                    mapRotation: circuit.rot, weather: weather)
        return try XCTUnwrap(StaticSceneImage.build(circuit: circuit, size: size,
                                                    scale: 1, light: light))
    }

    private func bytes(_ image: CGImage) throws -> Data {
        try XCTUnwrap(NSBitmapImageRep(cgImage: image).tiffRepresentation)
    }

    // MARK: - Purity

    func testTheSameSceneRendersTheSamePictureTwice() throws {
        let first = try render(scene())
        let second = try render(scene())

        XCTAssertEqual(first, second,
                       "the scene must be a pure function of its inputs, or no later "
                       + "stage can tell a change from noise")
    }

    func testTheSameWorldBuildsTheSamePictureTwice() throws {
        let first = try bytes(try world(instant: instant))
        let second = try bytes(try world(instant: instant))

        XCTAssertEqual(first, second,
                       "the built world must be a pure function of its key, or the "
                       + "cache would be serving a different picture than it drew")
    }

    // MARK: - The track surface

    /// Half a lap from the start/finish line, so neither the pit lane nor the
    /// start/finish stroke reaches it, sampled in the built world — where the
    /// ground is terrain and buildings rather than the window's backdrop.
    ///
    /// "Differs from the background" would therefore prove nothing. What is true
    /// of the road and of nothing else here is that it is *neutral*: the track is
    /// stroked in flat greys that the lighting never touches, while every square
    /// metre around it — Monaco's warm ground albedo, its roofs, its harbour — is
    /// tinted, because it went through `SceneLight`. A pixel with three equal
    /// channels at that point is road.
    ///
    /// The brightness bound is what a black frame cannot clear. The track is
    /// stroked from flat greys but drawn *through* the light as emissive, so the
    /// numbers move with the time of day: at this afternoon instant the 51/255
    /// surface grey lands near 44 and the racing line over it composites to 25.
    /// Both are far off a black frame and far below the kerbs.
    func testTheTrackSurfaceIsDrawnHalfALapFromTheLine() throws {
        let circuit = try monaco()
        let fit = CircuitFit(circuit: circuit, in: size)
        let count = circuit.points.count
        let point = fit.point(circuit.points[(circuit.startIdx + count / 2) % count])

        let rep = NSBitmapImageRep(cgImage: try world(instant: instant))
        let colour = try XCTUnwrap(rep.colorAt(x: Int(point.x.rounded()),
                                               y: Int(point.y.rounded())))
        let red = Int((colour.redComponent * 255).rounded())
        let green = Int((colour.greenComponent * 255).rounded())
        let blue = Int((colour.blueComponent * 255).rounded())

        XCTAssertEqual(red, green,
                       "the road is a flat grey; anything the sun lit is tinted")
        XCTAssertEqual(green, blue,
                       "the road is a flat grey; anything the sun lit is tinted")
        XCTAssertTrue((18...55).contains(red),
                      "lit, the road surface is about 44/255 at this instant and the "
                      + "racing line over it 25/255; \(red) is neither, so this pixel "
                      + "is not track")
    }

    /// The road is in the scene, not on top of it. Drawn from raw greys it was
    /// the one surface that read the same at noon and at midnight, while the
    /// night exposure lifted everything around it — a road that appeared to glow
    /// by itself. Through `emissive` it moves with the rest.
    func testTheTrackSurfaceRespondsToTheLight() throws {
        let circuit = try monaco()
        let fit = CircuitFit(circuit: circuit, in: size)
        let count = circuit.points.count
        let point = fit.point(circuit.points[(circuit.startIdx + count / 2) % count])

        func road(at instant: Date) throws -> Double {
            let rep = NSBitmapImageRep(cgImage: try world(instant: instant))
            let colour = try XCTUnwrap(rep.colorAt(x: Int(point.x.rounded()),
                                                   y: Int(point.y.rounded())))
            return Double(colour.redComponent * 255)
        }

        let noon = try road(at: localNoon)
        let midnight = try road(at: localMidnight)

        XCTAssertGreaterThan(midnight, noon + 1,
                             "the night exposure lifts the whole picture, and the road "
                             + "is part of the picture")
    }

    // MARK: - The cars

    /// The on-track loop. An extraction that dropped it would still render a
    /// perfectly plausible circuit.
    func testARunningSessionChangesThePicture() throws {
        let withCar = try render(scene(sessions: [workingSession]))
        let withoutCar = try render(scene(sessions: []))

        XCTAssertNotEqual(withCar, withoutCar,
                          "only `sessions` differs, so a car on the circuit is the "
                          + "only thing that can account for a difference")
    }

    /// The pit lane is half the point of the park rule. An extraction that took
    /// only `sessions` would drop it and still render a plausible picture.
    func testAParkedSessionChangesThePicture() throws {
        let withPit = try render(scene())
        let withoutPit = try render(scene(parked: []))

        XCTAssertNotEqual(withPit, withoutPit,
                          "only `parked` differs, so a car in the pit lane is the "
                          + "only thing that can account for a difference")
    }

    func testHoveringChangesThePicture() throws {
        XCTAssertNotEqual(try render(scene()), try render(scene(hovered: "S1")),
                          "only `hovered` differs, so the spotlight is the only "
                          + "thing that can account for a difference")
    }

    /// Two sessions identical but for their id, which is the only thing that
    /// decides the paint.
    func testTwoLiveriesRenderDifferently() throws {
        let one = AgentSession(id: "S1", cwd: "/repo/a", gitBranch: "main",
                               activity: .working,
                               lastActivityAt: Date(timeIntervalSince1970: 1_800_000_000))
        let other = AgentSession(id: "S4", cwd: "/repo/a", gitBranch: "main",
                                 activity: .working,
                                 lastActivityAt: Date(timeIntervalSince1970: 1_800_000_000))
        // Stated rather than assumed: two ids can hash to the same car, and this
        // test would then be asserting that a car differs from itself.
        XCTAssertNotEqual(CarLivery.forSession(one.id), CarLivery.forSession(other.id))

        // Neither id is in `workTokens`, so both cars stand at lap fraction zero
        // and the paint is all that is left to differ.
        let scene = { (session: AgentSession) in
            AgentverseScene(circuit: try self.monaco(), sessions: [session], parked: [],
                            workTokens: [:], hovered: nil, frame: 600,
                            instant: self.instant, weather: .clear)
        }

        XCTAssertNotEqual(try render(try scene(one)), try render(try scene(other)),
                          "two liveries must be two pictures, or the field is "
                          + "indistinguishable")
    }

    /// Frame 600 is 20 half-seconds in and frame 630 is 21: hazards on, then off.
    func testAWaitingCarDiffersBetweenBlinkPhases() throws {
        let on = try render(scene(sessions: [waitingSession], parked: [], frame: 600))
        let off = try render(scene(sessions: [waitingSession], parked: [], frame: 630))

        XCTAssertNotEqual(on, off,
                          "only `frame` differs, and nothing but the hazard blink "
                          + "reads the frame, so a waiting car must flash")
    }

    // MARK: - The light

    /// The whole reason the solar position and the lighting exist. A scene that
    /// ignored its instant would render the same picture at both.
    func testNoonAndMidnightRenderDifferently() throws {
        let noon = try bytes(try world(instant: localNoon))
        let midnight = try bytes(try world(instant: localMidnight))

        XCTAssertNotEqual(noon, midnight,
                          "only the instant differs, so the sun's own position is the "
                          + "only thing that can account for a difference")
    }

    /// The margin around the terrain used to be a fixed grey, which made it the
    /// one surface in the picture the exposure never reached: at night the
    /// terrain lifted and the frame around it stayed put. `CircuitFit` centres
    /// the terrain box with at least its own margin on every side, so the canvas
    /// corner is always outside that box and is nothing but backdrop.
    func testTheBackdropIsLitAndDiffersBetweenNoonAndMidnight() throws {
        let corner = { (image: CGImage) throws -> NSColor in
            try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x: 2, y: 2))
        }
        let noon = try corner(try world(instant: localNoon))
        let midnight = try corner(try world(instant: localMidnight))

        XCTAssertNotEqual(noon, midnight,
                          "the backdrop is sky and the sky is a light source, so a "
                          + "day and a night backdrop cannot be the same colour")

        // And it is the *scene's* sky, not some other grey that happens to move.
        let circuit = try monaco()
        let sun = SunPosition.at(latitude: circuit.lat, longitude: circuit.lon,
                                 date: localNoon)
        let sky = SceneLight.make(elevation: sun.elevation, azimuth: sun.azimuth,
                                  mapRotation: circuit.rot, weather: .clear).skySRGB
        XCTAssertEqual(Double(noon.redComponent * 255), sky.x, accuracy: 1)
        XCTAssertEqual(Double(noon.greenComponent * 255), sky.y, accuracy: 1)
        XCTAssertEqual(Double(noon.blueComponent * 255), sky.z, accuracy: 1)
    }

    func testClearAndRainRenderDifferently() throws {
        let clear = try bytes(try world(instant: instant, weather: .clear))
        let rain = try bytes(try world(instant: instant, weather: .rain))

        XCTAssertNotEqual(clear, rain,
                          "only `weather` differs, so the weather is the only thing "
                          + "that can account for a difference")
    }
}
