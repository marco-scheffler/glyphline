import SwiftUI

/// The drawing, separated from where its inputs come from.
///
/// `frame` replaces the clock: the window passes the running frame number, a test
/// passes a fixed one. Without that the picture depends on when it was taken and
/// no two renders could be compared.
///
/// The world under the cars — ground, city, shadows, track — is not drawn here
/// per frame but fetched as one cached bitmap. It costs half a second to build,
/// which is why the build happens off the main actor and the canvas keeps the
/// bare vector track to draw until the first picture arrives.
struct AgentverseScene: View {
    let circuit: Circuit
    let sessions: [AgentSession]
    let parked: [ParkedAgentSession]
    let workTokens: [String: Int64]
    let hovered: String?
    let frame: Int
    /// The UTC instant the world is lit at. Handed in rather than read from a
    /// clock in here for the same reason `frame` is: the picture has to be a pure
    /// function of its inputs or no two renders can be compared.
    let instant: Date
    let weather: Weather

    @Environment(\.displayScale) private var displayScale
    @State private var world: CGImage?

    var body: some View {
        GeometryReader { proxy in
            let key = sceneKey(size: proxy.size)
            canvas(world: world, scale: displayScale)
                .task(id: key) { await buildWorld(key) }
        }
        // The same sky the built picture fills its margin with, for the frames
        // before that picture exists and for whatever the canvas does not cover.
        .background(light.skyColor)
    }

    // MARK: - The static world

    /// In degrees, and with no scene rotation applied — that is `SceneLight`'s
    /// job, and the key wants the unrotated numbers so its buckets mean the same
    /// thing on every circuit.
    ///
    /// `instant` is a UTC instant; the circuit's own zone decided which one, up
    /// in the window. Latitude and longitude then place the sun over the circuit
    /// rather than over the viewer.
    private var sun: (elevation: Double, azimuth: Double) {
        SunPosition.at(latitude: circuit.lat, longitude: circuit.lon, date: instant)
    }

    /// `SceneLight` wants elevation and azimuth in degrees and `mapRotation` in
    /// radians, which is what `Circuit.rot` already is.
    private var light: SceneLight {
        SceneLight.make(elevation: sun.elevation, azimuth: sun.azimuth,
                        mapRotation: circuit.rot, weather: weather)
    }

    private func sceneKey(size: CGSize) -> StaticSceneKey {
        let sun = sun
        return StaticSceneKey(circuit: circuit.key, size: size,
                              scale: Int(displayScale.rounded()),
                              elevation: sun.elevation, azimuth: sun.azimuth,
                              weather: weather)
    }

    private func buildWorld(_ key: StaticSceneKey) async {
        guard key.width > 0, key.height > 0 else { return }
        // Read out of the view before the closure: everything the build touches
        // has to be a `Sendable` value, because it runs off this actor.
        let circuit = circuit
        let light = light
        world = await StaticSceneCache.shared.image(for: key) { key in
            StaticSceneImage.build(circuit: circuit, size: key.size,
                                   scale: key.scale, light: light)
        }
    }

    // MARK: - The frame

    /// `world` and the display scale are read out here rather than inside the
    /// drawing closure, which is nonisolated and may not reach into the view's
    /// state or its environment.
    private func canvas(world: CGImage?, scale: CGFloat) -> some View {
        Canvas { context, size in
            let fit = CircuitFit(circuit: circuit, in: size)
            if let world {
                context.draw(Image(decorative: world, scale: scale),
                             in: CGRect(origin: .zero, size: size))
            } else {
                drawBareTrack(in: context, fit: fit)
            }

            // Tied to the road it drives on rather than to a nominal length in
            // metres: measured against the track surface stroke, a car that
            // came out shorter than the road is wide could not read as a car at
            // all. 1.6 road widths is deliberately over-scaled — to scale a GT3
            // would be a third of the road's width long, which is a speck — and
            // the floor keeps it legible on a small window.
            let carLength = max(14, fit.width(metres: 13, atLeast: 6) * 1.6)

            func drawCar(at point: CGPoint, heading: Double, livery: CarLivery,
                         hazardsOn: Bool, opacity: Double) {
                let placement = CGAffineTransform(translationX: point.x, y: point.y)
                    .rotated(by: heading)
                    .scaledBy(x: carLength, y: carLength)

                context.fill(CarShape.body.applying(placement),
                             with: .color(livery.body.opacity(opacity)))
                context.fill(CarShape.stripe.applying(placement),
                             with: .color(livery.accent.opacity(opacity)))
                context.fill(CarShape.wing.applying(placement),
                             with: .color(livery.accent.opacity(opacity)))
                if hazardsOn {
                    context.fill(CarShape.hazards.applying(placement),
                                 with: .color(Color.orange.opacity(opacity)))
                }
            }

            // A function rather than a mutation of `context.opacity`: a
            // reset missed on one path would silently fade everything
            // drawn after it.
            //
            // Dimmed rather than nearly gone: the ask was "slightly greyed", and
            // 0.18 read as switched off.
            func spotlight(_ id: String) -> Double {
                guard let hovered else { return 1 }
                return hovered == id ? 1 : 0.35
            }

            // The pit lane first, so a car rejoining never appears to sit
            // on top of the field it is behind.
            for (index, session) in parked.enumerated() {
                let slot = CarPosition.pitSlot(index: index, count: parked.count)
                guard let along = CarPosition.pitPointIndex(slot: slot,
                                                            count: circuit.pit.count)
                else { continue }
                // The lane is not a loop: its first point has no predecessor.
                let heading = CarPosition.heading(points: circuit.pit, index: along,
                                                  closed: false, fit: fit) ?? 0
                let livery = CarLivery.forSession(session.sessionID)
                drawCar(at: fit.point(circuit.pit[along]), heading: heading,
                        livery: livery, hazardsOn: false,
                        opacity: 0.55 * spotlight(session.sessionID))
            }

            // Half a second on, half a second off at the window's 60 frames a
            // second — the rate the clock-derived blink had.
            let blinkOn = frame / 30 % 2 == 0
            for session in sessions {
                let tokens = workTokens[session.id] ?? 0
                let fraction = CarPosition.lapFraction(workTokens: tokens)
                let index = CarPosition.pointIndex(fraction: fraction,
                                                   startIdx: circuit.startIdx,
                                                   count: circuit.points.count)
                guard circuit.points.indices.contains(index) else { continue }
                let heading = CarPosition.heading(points: circuit.points, index: index,
                                                  closed: true, fit: fit) ?? 0
                let livery = CarLivery.forSession(session.id)
                let waiting = session.activity == .waitingForYou

                drawCar(at: fit.point(circuit.points[index]), heading: heading,
                        livery: livery, hazardsOn: waiting && blinkOn,
                        opacity: spotlight(session.id))
            }
        }
    }

    /// What the canvas shows while the first picture is still being built, and
    /// the same strokes the picture itself bakes in — bar the corner names,
    /// which are text and belong to the picture alone.
    private func drawBareTrack(in context: GraphicsContext, fit: CircuitFit) {
        // Verge first, then surface: one stroke over another is cheaper
        // than building two outlines, and the difference is invisible.
        context.stroke(
            CircuitTrackShape.centreline(for: circuit, fit: fit),
            with: .color(.white.opacity(0.18)),
            style: StrokeStyle(lineWidth: fit.width(metres: 19, atLeast: 9),
                               lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            CircuitTrackShape.centreline(for: circuit, fit: fit),
            with: .color(Color(white: 0.20)),
            style: StrokeStyle(lineWidth: fit.width(metres: 13, atLeast: 6),
                               lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            CircuitTrackShape.racingLine(for: circuit, fit: fit),
            with: .color(Color(white: 0.13).opacity(0.85)),
            style: StrokeStyle(lineWidth: fit.width(metres: 6, atLeast: 3),
                               lineCap: .round, lineJoin: .round)
        )
        // Butt caps: round ones on both ends of every block would close the gaps
        // the red-and-white alternation is made of.
        for (block, red) in CircuitTrackShape.kerbs(for: circuit, fit: fit) {
            context.stroke(
                block,
                with: .color(red ? Color(red: 0.77, green: 0.19, blue: 0.17)
                                 : Color(white: 0.89)),
                style: StrokeStyle(lineWidth: fit.width(metres: 2.5, atLeast: 2),
                                   lineCap: .butt)
            )
        }
        context.stroke(
            CircuitTrackShape.pitLane(for: circuit, fit: fit),
            with: .color(Color(white: 0.16)),
            style: StrokeStyle(lineWidth: fit.width(metres: 12, atLeast: 5),
                               lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            CircuitTrackShape.startFinish(for: circuit, fit: fit),
            with: .color(Color(white: 0.85)),
            lineWidth: 2
        )
    }
}
