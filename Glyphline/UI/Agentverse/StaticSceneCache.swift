import CoreGraphics
import Foundation

/// What a built picture depends on, and nothing else.
///
/// Two things in here are quantised rather than exact. The canvas size is
/// rounded to whole points, because half a point of window drag is not a
/// different picture. The sun is bucketed — two degrees of elevation, five of
/// azimuth — because it moves continuously: an exact elevation would produce a
/// new key on every single frame and the cache would never hit once.
struct StaticSceneKey: Hashable, Sendable {
    let circuit: String
    let width: Int
    let height: Int
    /// Backing-store scale, so a picture built for a Retina window is not served
    /// to a one-to-one one at half the detail it was drawn with.
    let scale: Int
    let elevationBucket: Int
    let azimuthBucket: Int
    let weather: Weather

    static let elevationStep = 2.0
    static let azimuthStep = 5.0

    /// - Parameters:
    ///   - elevation: Solar elevation in degrees.
    ///   - azimuth: Solar azimuth in degrees clockwise from north.
    init(circuit: String, size: CGSize, scale: Int,
         elevation: Double, azimuth: Double, weather: Weather) {
        self.circuit = circuit
        self.width = Int(size.width.rounded())
        self.height = Int(size.height.rounded())
        self.scale = max(1, scale)
        self.elevationBucket = Self.bucket(elevation, step: Self.elevationStep)
        self.azimuthBucket = Self.bucket(azimuth, step: Self.azimuthStep)
        self.weather = weather
    }

    /// The point size the picture was framed for.
    var size: CGSize { CGSize(width: CGFloat(width), height: CGFloat(height)) }

    private static func bucket(_ value: Double, step: Double) -> Int {
        // A NaN elevation would otherwise trap on the conversion to Int, and a
        // scene is not worth a crash.
        guard value.isFinite else { return 0 }
        return Int((value / step).rounded(.down))
    }
}

/// The built pictures, kept by key.
///
/// Building one costs half a second of Debug-build CPU, so it happens off the
/// main actor: `build` runs in a detached task, and only the finished `CGImage`
/// — which Core Graphics declares `Sendable`, being immutable — comes back
/// across. Storing the `Task` rather than the image is what makes a second
/// request arriving while the first is still drawing await that same build
/// instead of starting a rival one.
///
/// Bounded, because an entry is a full-canvas bitmap: a few megabytes for every
/// window size the user has ever dragged through.
@MainActor
final class StaticSceneCache {
    static let shared = StaticSceneCache()

    private let limit: Int
    private var entries: [StaticSceneKey: Task<CGImage?, Never>] = [:]
    /// Least recently used first.
    private var order: [StaticSceneKey] = []

    init(limit: Int = 4) {
        self.limit = max(1, limit)
    }

    var count: Int { entries.count }

    func image(
        for key: StaticSceneKey,
        build: @escaping @Sendable (StaticSceneKey) async -> CGImage?
    ) async -> CGImage? {
        let task: Task<CGImage?, Never>
        if let existing = entries[key] {
            task = existing
        } else {
            task = Task.detached(priority: .userInitiated) { await build(key) }
            entries[key] = task
        }

        order.removeAll { $0 == key }
        order.append(key)
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            entries.removeValue(forKey: oldest)
        }

        return await task.value
    }
}

