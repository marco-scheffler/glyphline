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
    /// The right-hand column the waiting sessions stand in.
    let breakRoom: CGRect
    let columns: Int
    /// 1 is the mockup's 200×200 pt station.
    let deskScale: Double

    private static let station = 200.0

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

}

/// Where the waiting sessions stand in the break room.
///
/// Fixed spots on a grid rather than the office's wandering walkers: on the
/// reference machine ten of thirteen sessions were waiting at once, and walkers
/// sharing eight slots piled into one heap of figures and bubbles. Each spot
/// owns a cell — the bubble at its top, the figure under it — and no two cells
/// overlap. The figures shrink and the grid gains a column before anyone is
/// left out; only then does a "+N" badge take the bottom of the room.
struct StudioBreakRoomLayout: Equatable, Sendable {
    struct Spot: Equatable, Sendable {
        /// The whole cell; the bubble and the figure stay inside it.
        let cell: CGRect
        /// Where the figure's own origin goes (the middle of its face).
        let figure: CGPoint
        /// The top of the bubble at rest, low enough for its bob to stay in the cell.
        let bubbleTop: Double
    }

    /// One per figure shown, in the order the figures were given.
    let spots: [Spot]
    let figureScale: Double
    /// Waiting sessions that did not fit.
    let overflow: Int
    let overflowBadge: CGRect?

    /// The figure at scale 1, cap and headphones included: 70 × 96 pt, with its
    /// origin 34 pt below the top.
    static let figureSize = CGSize(width: 70, height: 96)
    static let figureTop = 34.0
    /// The bubble, its tail and the bob above the figure.
    static let bubbleBand = 3.0 + 20 + 5 + 3
    static let minimumFigureScale = 0.45
    /// Narrowest cell whose bubble still holds "· 123 min" whole.
    static let minimumCellWidth = 90.0
    static let badgeHeight = 22.0
    private static let spacing = 6.0

    static func cellHeight(scale: Double) -> Double {
        bubbleBand + figureSize.height * scale + spacing
    }

    init(room: CGRect, count: Int, maximumScale: Double = 1) {
        let inner = room.insetBy(dx: 12, dy: 12)
        let maxColumns = max(1, Int((inner.width / Self.minimumCellWidth).rounded(.down)))
        let largest = max(Self.minimumFigureScale, min(1, maximumScale))

        func capacity(scale: Double, columns: Int, height: Double) -> Int {
            guard Self.figureSize.width * scale <= inner.width / Double(columns) else { return 0 }
            return columns * max(0, Int((height / Self.cellHeight(scale: scale)).rounded(.down)))
        }

        // The largest figures that fit everybody, at the fewest columns.
        var choice: (scale: Double, columns: Int)?
        var step = 0
        search: while true {
            let scale = largest - Double(step) * 0.05
            if scale < Self.minimumFigureScale - 0.0001 { break }
            for columns in 1...maxColumns where capacity(scale: scale, columns: columns,
                                                          height: inner.height) >= count {
                choice = (scale, columns)
                break search
            }
            step += 1
        }

        let scale = choice?.scale ?? Self.minimumFigureScale
        let columns = choice?.columns ?? maxColumns
        let usable = choice == nil ? inner.height - Self.badgeHeight - Self.spacing : inner.height
        let shown = min(count, capacity(scale: scale, columns: columns, height: usable))
        let cellWidth = inner.width / Double(columns)
        let cellHeight = Self.cellHeight(scale: scale)

        spots = (0..<shown).map { index in
            let cell = CGRect(x: inner.minX + Double(index % columns) * cellWidth,
                              y: inner.minY + Double(index / columns) * cellHeight,
                              width: cellWidth, height: cellHeight)
            return Spot(cell: cell,
                        figure: CGPoint(x: cell.midX,
                                        y: cell.minY + Self.bubbleBand + Self.figureTop * scale),
                        bubbleTop: cell.minY + 3)
        }
        figureScale = scale
        overflow = count - shown
        overflowBadge = overflow > 0
            ? CGRect(x: inner.minX, y: inner.maxY - Self.badgeHeight,
                     width: inner.width, height: Self.badgeHeight)
            : nil
    }

    /// Who stands first: the longest wait, because that is the one most worth
    /// answering. Ties fall back to the id so the order never flickers.
    static func ordered(_ waiting: [StudioDesk]) -> [StudioDesk] {
        waiting.sorted { a, b in
            switch (a.waitingSince, b.waitingSince) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.id < b.id
            }
        }
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
