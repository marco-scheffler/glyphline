import CoreGraphics
import SwiftUI
import XCTest
@testable import Glyphline

/// Outside the class because a default argument cannot reference a member of
/// the type it is declared in.
private let workingSession = AgentSession(
    id: "S1", cwd: "/repo/a", gitBranch: "main", activity: .working,
    lastActivityAt: Date(timeIntervalSince1970: 1_800_000_000))

private let waitingSession = AgentSession(
    id: "S1", cwd: "/repo/a", gitBranch: "main", activity: .waitingForYou,
    lastActivityAt: Date(timeIntervalSince1970: 1_800_000_000))

private let parkedSession = ParkedAgentSession(
    sessionID: "S3", cwd: "/repo/c", gitBranch: "main",
    subagentCount: 0,
    lastActivityAt: Date(timeIntervalSince1970: 1_800_000_000),
    parkedAt: Date(timeIntervalSince1970: 1_800_003_600))

/// A rendered picture, compared byte for byte.
///
/// This file exists because the look of both Agentverse views was designed
/// blind: the only way to know that a refactor dropped the people, the break
/// room or the sun is to look at the output. Reading the code never once caught
/// one of those.
///
/// Two rules hold everywhere below, and both were paid for.
///
/// * **One variable per assertion.** An earlier version of this file compared a
///   full scene against an empty one while varying three inputs at once, so a
///   red run could not say what was missing.
/// * **No `.task`, no clock, no network.** `ImageRenderer` never runs a SwiftUI
///   `.task`, and an earlier version of this file therefore compared two
///   identical *fallback* renders and passed forever. Both scenes here are pure
///   `Canvas` views over their stored inputs — the sun, the weather and the
///   frame number all enter as values — so what `ImageRenderer` produces is the
///   picture the window draws.
@MainActor
final class AgentverseSnapshotTests: XCTestCase {
    /// 2026-06-21 15:00 UTC, an afternoon over Berlin. Fixed rather than "now",
    /// because a snapshot taken at "now" is a different picture every run.
    private let instant = Date(timeIntervalSince1970: 1_781_708_400)
    /// 2026-06-21 10:00 UTC — midday over Berlin, which keeps UTC+2 in June.
    private let localNoon = Date(timeIntervalSince1970: 1_781_690_400)
    /// Twelve hours after `localNoon`: the same office with the sun under it.
    private let localMidnight = Date(timeIntervalSince1970: 1_781_733_600)

    private let berlin = UserPlace.Coordinates(latitude: 52.52, longitude: 13.405,
                                               source: .table)

    private let size = CGSize(width: 900, height: 600)

    private func lighting(at date: Date, weather: Weather = .clear) -> OfficeLighting {
        OfficeLighting.at(date: date, place: berlin, weather: weather)
    }

    /// Every input is fixed but the ones a caller overrides, so each test can
    /// vary exactly one thing and know that nothing else accounts for a
    /// difference in bytes.
    private func scene(sessions: [AgentSession] = [workingSession],
                       parked: [ParkedAgentSession] = [parkedSession],
                       workTokens: [String: Int64] = ["S1": 120_000, "S3": 40_000],
                       hovered: String? = nil,
                       frame: Int = 0,
                       date: Date? = nil,
                       weather: Weather = .clear,
                       view: AgentverseView = .office) -> AgentverseScene {
        AgentverseScene(sessions: sessions,
                        parked: parked,
                        workTokens: workTokens,
                        hovered: hovered,
                        frame: frame,
                        lighting: lighting(at: date ?? instant, weather: weather),
                        view: view)
    }

    private func image(_ view: some View) throws -> CGImage {
        let renderer = ImageRenderer(content: view.frame(width: size.width,
                                                         height: size.height))
        // Scale 1 so that a canvas point is a bitmap pixel and the rectangles
        // computed below in scene coordinates address the pixels they name.
        renderer.scale = 1
        return try XCTUnwrap(renderer.cgImage)
    }

    /// How often the same bytes have to come back before a render counts as
    /// settled, and how many renders that is allowed to take.
    private static let settledRepeats = 5
    private static let settleAttempts = 24

    private enum RenderError: Error, CustomStringConvertible {
        case neverSettled(attempts: Int)
        var description: String {
            switch self {
            case .neverSettled(let attempts):
                return "the same view still rendered differently after \(attempts) "
                    + "renders — this is no longer a cache warming up"
            }
        }
    }

    /// The first renders of a scene in a process are *not* the renders that
    /// follow it, and this is not a bug in the scene.
    ///
    /// Measured, not assumed: rendering `scene()` twice back to back and
    /// diffing the buffers, 200 times in one process, differs exactly once —
    /// on the first pair — in about 300 of 540 000 pixels, isolated single
    /// pixels scattered over the drawn figures rather than any contiguous
    /// region or displaced shape. Keeping the first twelve buffers and
    /// comparing each to the last shows the office settling after three or
    /// four renders and the datastream after two, and then never moving again
    /// over another 800 renders. That is a lazily populated global cache
    /// filling up — CoreText glyph rasterisation and CG gradient caches, the
    /// only global mutable state on this path — and it is per drawn content,
    /// which is why the datastream still needed its own warm-up after a dozen
    /// office renders.
    ///
    /// So: throw the warm-up renders away and compare what comes after. This
    /// deliberately does **not** loosen the comparison — every assertion below
    /// still compares bytes exactly, and if a scene ever stops settling this
    /// throws instead of quietly tolerating a difference.
    ///
    /// Note the settle rule is "the same bytes `settledRepeats` times running",
    /// not "twice running": two and even three consecutive renders were
    /// measured to agree with each other while both still differed from the
    /// settled picture, so a shorter rule stops too early.
    private func settledImage(_ view: some View) throws -> CGImage {
        var previous: Data?
        var repeats = 0
        for _ in 0..<Self.settleAttempts {
            let image = try image(view)
            let bytes = try pixels(image)
            repeats = bytes == previous ? repeats + 1 : 0
            previous = bytes
            if repeats >= Self.settledRepeats { return image }
        }
        throw RenderError.neverSettled(attempts: Self.settleAttempts)
    }

    /// The raw pixels, not a TIFF. An encoded representation carries metadata
    /// that says nothing about the picture, and comparing it would let a change
    /// of container read as a change of drawing — or the other way round.
    private func pixels(_ image: CGImage) throws -> Data {
        Data(try XCTUnwrap(image.dataProvider?.data) as Data)
    }

    private func render(_ view: some View) throws -> Data {
        try pixels(try settledImage(view))
    }

    /// The bytes of one part of a picture, so that an assertion can name *where*
    /// it expects a change rather than only that there was one somewhere.
    ///
    /// The rows are cut out of the full buffer by hand rather than with
    /// `CGImage.cropping(to:)`, because a cropped `CGImage` shares its parent's
    /// data provider: reading the provider back would hand out the whole
    /// picture again, and this would silently become a full-frame comparison.
    private func render(_ view: some View, in rect: CGRect) throws -> Data {
        let image = try settledImage(view)
        let all = try pixels(image)
        let bytesPerPixel = image.bitsPerPixel / 8
        let x = Int(rect.minX), y = Int(rect.minY)
        let width = Int(rect.width), height = Int(rect.height)
        XCTAssertTrue(x >= 0 && y >= 0 && width > 0 && height > 0
                      && x + width <= image.width && y + height <= image.height,
                      "the sampled rectangle has to be inside the picture")

        var region = Data()
        for row in y..<(y + height) {
            let start = row * image.bytesPerRow + x * bytesPerPixel
            region.append(all[start..<(start + width * bytesPerPixel)])
        }
        return region
    }

    // MARK: - Purity

    /// The premise of every other assertion here. If the picture depended on the
    /// wall clock, on dictionary ordering or on anything else outside its
    /// inputs, none of the inequalities below would mean what they say.
    func testTheSameInputsRenderTheSameOfficeTwice() throws {
        XCTAssertEqual(try render(scene()), try render(scene()),
                       "the office must be a pure function of its inputs, or no "
                       + "assertion here can tell a change from noise")
    }

    func testTheSameInputsRenderTheSameDatastreamTwice() throws {
        XCTAssertEqual(try render(scene(view: .datastream)),
                       try render(scene(view: .datastream)),
                       "the datastream must be a pure function of its inputs, or no "
                       + "assertion here can tell a change from noise")
    }

    // MARK: - The sessions

    /// A refactor that dropped the desk loop would still render a perfectly
    /// plausible empty office.
    func testAWorkingSessionChangesTheOffice() throws {
        XCTAssertNotEqual(try render(scene(sessions: [workingSession])),
                          try render(scene(sessions: [])),
                          "only `sessions` differs, so a desk with somebody at it is "
                          + "the only thing that can account for a difference")
    }

    func testAWorkingSessionChangesTheDatastream() throws {
        XCTAssertNotEqual(try render(scene(sessions: [workingSession], view: .datastream)),
                          try render(scene(sessions: [], view: .datastream)),
                          "only `sessions` differs, so a lane is the only thing that "
                          + "can account for a difference")
    }

    /// Where a waiting session goes in the office: out of its chair and into the
    /// break room. The two scenes differ in the session's `activity` and in
    /// nothing else — same id, same colour, same desk count, so the same layout.
    ///
    /// Sampled at the break room's own furniture rather than over the whole
    /// canvas, because the whole canvas would also change if only the desk went
    /// dark and nobody ever got up. The rectangle is the figure-sized box around
    /// the place `BreakRoom` itself says this agent occupies at frame 0 — its
    /// start slot, sat still, which is what the wander is defined to do there.
    func testAWaitingSessionPutsSomebodyInTheBreakRoom() throws {
        let layout = IsoLayout.fit(sessionCount: 1, canvas: size)
        let room = BreakRoom(room: layout.breakRoom)
        let walker = room.walker(for: 0, seed: workingSession.id, frame: 0)
        let s = layout.zoom
        // The renderer raises a sitting figure onto the furniture by 9 * scale,
        // and a person reaches roughly 55 * scale above its feet.
        let feet = layout.projection.point(u: walker.position.u, v: walker.position.v,
                                           h: walker.slot.sitting ? 9 * s : 0)
        let box = CGRect(x: feet.x - 11 * s, y: feet.y - 60 * s,
                         width: 22 * s, height: 63 * s).integral

        // Stated rather than assumed: nothing on the office floor reaches into
        // this box, so a change inside it is the break room's doing. The one
        // desk's rug is the widest part of it.
        let desk = try XCTUnwrap(layout.desks.first)
        let deskCorners = [(-1.0, -1.0), (-1.0, 1.0), (1.0, -1.0), (1.0, 1.0)].map {
            layout.projection.point(u: desk.u + $0.0 * IsoLayout.deskFootprint,
                                    v: desk.v + $0.1 * IsoLayout.deskFootprint)
        }
        XCTAssertLessThan(deskCorners.map(\.x).max() ?? 0, box.minX,
                          "the sampled box has to be clear of the desk, or a change "
                          + "inside it would not prove anybody walked anywhere")

        XCTAssertNotEqual(try render(scene(sessions: [waitingSession]), in: box),
                          try render(scene(sessions: [workingSession]), in: box),
                          "only `activity` differs, and this box is the break room "
                          + "seat the wander puts that session in, so a session "
                          + "waiting on you must be sitting in it")
    }

    func testAWaitingSessionChangesTheDatastream() throws {
        XCTAssertNotEqual(try render(scene(sessions: [waitingSession], view: .datastream)),
                          try render(scene(sessions: [workingSession], view: .datastream)),
                          "only `activity` differs, so a waiting lane must not look "
                          + "like a working one")
    }

    // MARK: - The hover

    func testHoveringChangesTheOffice() throws {
        XCTAssertNotEqual(try render(scene(sessions: [workingSession, waitingHelper])),
                          try render(scene(sessions: [workingSession, waitingHelper],
                                           hovered: "S1")),
                          "only `hovered` differs, so the highlight is the only thing "
                          + "that can account for a difference")
    }

    func testHoveringChangesTheDatastream() throws {
        XCTAssertNotEqual(try render(scene(sessions: [workingSession, waitingHelper],
                                           view: .datastream)),
                          try render(scene(sessions: [workingSession, waitingHelper],
                                           hovered: "S1", view: .datastream)),
                          "only `hovered` differs, so the highlight is the only thing "
                          + "that can account for a difference")
    }

    /// A second session, so that hovering has something to single one out from.
    private let waitingHelper = AgentSession(
        id: "S2", cwd: "/repo/b", gitBranch: "main", activity: .waitingForYou,
        lastActivityAt: Date(timeIntervalSince1970: 1_800_000_000))

    // MARK: - The light

    /// The whole reason `SunPosition` and `SceneLight` survived the circuit. An
    /// office that ignored its lighting would render the same picture at both.
    func testNoonAndMidnightRenderDifferently() throws {
        XCTAssertNotEqual(try render(scene(date: localNoon)),
                          try render(scene(date: localMidnight)),
                          "only the instant differs, and the same place is under both, "
                          + "so the sun's own position is the only thing that can "
                          + "account for a difference")
    }

    /// At one instant, so the sun is in exactly the same place in both and only
    /// what the sky does with it differs.
    func testClearAndRainRenderDifferently() throws {
        XCTAssertNotEqual(try render(scene(weather: .clear)),
                          try render(scene(weather: .rain)),
                          "only `weather` differs, so the weather is the only thing "
                          + "that can account for a difference")
    }

    // MARK: - The two views

    /// The switch is the feature. A scene that ignored `view` would show one
    /// picture under both names.
    func testTheOfficeAndTheDatastreamRenderDifferently() throws {
        XCTAssertNotEqual(try render(scene(view: .office)),
                          try render(scene(view: .datastream)),
                          "only `view` differs, so which of the two pictures is drawn "
                          + "is the only thing that can account for a difference")
    }
}
