import Foundation

/// What a studio figure wears on its head, if anything.
enum StudioAccessory: CaseIterable, Equatable, Sendable {
    case none, headphones, glasses, cap
}

/// How one session looks on the studio floor.
///
/// The hoodie is the session's colour, so the figure matches its lane, its
/// swatch and its sidebar row. Hair, skin and accessory come from other bits of
/// the same FNV-1a hash, so two sessions sharing a colour still differ.
struct StudioFigure: Equatable, Sendable {
    let hoodie: SceneRGB
    let hair: SceneRGB
    let skin: SceneRGB
    let accessory: StudioAccessory

    private static let hairs: [SceneRGB] = [
        SceneRGB(38, 28, 22), SceneRGB(92, 58, 34), SceneRGB(176, 120, 64),
        SceneRGB(222, 190, 120), SceneRGB(150, 60, 36), SceneRGB(70, 70, 78)
    ]
    private static let skins: [SceneRGB] = [
        SceneRGB(248, 214, 184), SceneRGB(232, 186, 148), SceneRGB(198, 146, 106),
        SceneRGB(150, 102, 70), SceneRGB(104, 70, 48)
    ]

    static func forSession(_ id: String) -> StudioFigure {
        let hash = SessionPalette.fnv1a(id)
        // The low bits pick the hoodie; shifting past them keeps the other
        // choices independent of it.
        let accessories = StudioAccessory.allCases
        return StudioFigure(
            hoodie: SessionPalette.forSession(id).shirt,
            hair: hairs[Int((hash >> 16) % UInt64(hairs.count))],
            skin: skins[Int((hash >> 32) % UInt64(skins.count))],
            accessory: accessories[Int((hash >> 48) % UInt64(accessories.count))]
        )
    }
}

/// One desk on the floor: one on-track session.
struct StudioDesk: Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let waiting: Bool
    let action: AgentAction
    let waitingSince: Date?
    let figure: StudioFigure
}

/// Where everything on the studio floor goes, for one canvas size and desk count.
struct StudioLayout: Equatable, Sendable {
    /// The right-hand column the waiting sessions wander in.
    let breakRoom: CGRect
    let columns: Int
    /// 1 is the mockup's 200×200 pt station.
    let deskScale: Double

    private static let station = 200.0

    /// The abstract room `BreakRoom` places its slots in. Its slots span
    /// u 1.05…4.85 and v 0.45…2.85, well inside it.
    static let breakRoomFloor = RoomRect(u0: 0, u1: 6, v0: 0, v1: 4)

    init(canvas: CGSize, deskCount: Int) {
        let roomWidth = min(250, canvas.width * 0.25)
        breakRoom = CGRect(x: canvas.width - roomWidth, y: 0, width: roomWidth, height: canvas.height)
        let floorWidth = canvas.width - roomWidth
        let count = max(1, deskCount)
        // Shrink the station until the rows fit; at each size use as many
        // columns as fit across.
        var scale = 1.0
        var cols = 1
        while true {
            let side = Self.station * scale
            cols = max(1, min(count, Int((floorWidth / side).rounded(.down))))
            let rows = (count + cols - 1) / cols
            if (Double(rows) * side <= canvas.height && Double(cols) * side <= floorWidth)
                || scale <= 0.01 { break }
            scale -= 0.01
        }
        columns = cols
        deskScale = scale
    }

    func deskRect(_ index: Int) -> CGRect {
        let side = Self.station * deskScale
        return CGRect(x: Double(index % columns) * side, y: Double(index / columns) * side,
                      width: side, height: side)
    }

    func breakRoomPoint(_ walker: Walker) -> CGPoint {
        let room = Self.breakRoomFloor
        let p = walker.position
        return CGPoint(x: breakRoom.minX + (p.u - room.u0) / (room.u1 - room.u0) * breakRoom.width,
                       y: breakRoom.minY + (p.v - room.v0) / (room.v1 - room.v0) * breakRoom.height)
    }
}

/// What the bubble over a desk says.
enum StudioBubble {
    static func text(for desk: StudioDesk, now: Date) -> String {
        guard desk.waiting else { return desk.action.text }
        return waitingText(since: desk.waitingSince ?? now, now: now)
    }

    static func waitingText(since: Date, now: Date) -> String {
        let minutes = minutes(since: since, now: now)
        return String(localized: "Waiting for you · \(minutes) min",
                      comment: "Speech bubble and sidebar row for a session waiting on the user, keep it short. Placeholder: whole minutes waited.")
    }

    static func emptyDeskText(for desk: StudioDesk, now: Date) -> String {
        let minutes = minutes(since: desk.waitingSince ?? now, now: now)
        return String(localized: "Desk empty · \(minutes) min",
                      comment: "Label on the desk of a session that walked off to the break room, keep it short. Placeholder: whole minutes away.")
    }

    private static func minutes(since: Date, now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(since) / 60))
    }
}
