import CoreGraphics
import Foundation

/// Which of the two label columns a plate lives in.
enum MarginColumn: Equatable, Sendable {
    case left, right
}

/// Where one session's figure stands on screen. A named pair rather than a
/// tuple, because it is asserted on: a tuple carries no key paths.
struct WorkerAnchor: Equatable, Sendable {
    let id: String
    let point: CGPoint
}

/// One plate asking to be placed: who it names, where on screen the *person* it
/// names stands, and how big the plate wants to be.
///
/// The width is what the text measured to; `place` is free to clip it to the
/// column, because the column is the promise the room's fit was made against.
struct MarginLabelRequest: Equatable, Sendable {
    let id: String
    /// The worker, in canvas coordinates — not the desk. The desk is furniture;
    /// the person is the thing the reader is trying to find.
    let worker: CGPoint
    let width: Double
    let height: Double
}

/// A plate after placement: its rectangle in the margin, and where its leader
/// line starts and ends.
struct MarginLabel: Equatable, Sendable {
    let id: String
    let rect: CGRect
    let column: MarginColumn
    let worker: CGPoint

    /// The inner edge of the plate — the side facing the room, so the leader
    /// line never runs back across its own text.
    var leaderStart: CGPoint {
        switch column {
        case .left: CGPoint(x: rect.maxX, y: rect.midY)
        case .right: CGPoint(x: rect.minX, y: rect.midY)
        }
    }
}

/// Cutting a string to a *width* rather than to a character count.
///
/// The column is a fraction of the pane, so its width is a variable; a character
/// limit is a constant in a different unit and can only ever be right at one
/// window size. Thirty-eight characters of a proportional 12.5 pt title measure
/// well past the 240 pt the column ever offers, which is how plates ended up
/// wider than the space reserved for them.
///
/// The measurement is injected rather than done here: production hands in the
/// same `GraphicsContext.resolve(_:).measure(in:)` that sizes the plate, so the
/// string is cut against exactly the metrics it will be drawn with.
enum LabelFit {
    /// The longest prefix of `text` that measures within `maxWidth`, with an
    /// ellipsis in place of what was dropped. Cut at the *end*: a title's
    /// distinguishing words are usually its first ones.
    static func truncated(_ text: String,
                          to maxWidth: Double,
                          measure: (String) -> Double) -> String {
        guard maxWidth > 0 else { return "" }
        guard measure(text) > maxWidth else { return text }
        let characters = Array(text)
        // Binary search on the prefix length. The measure is monotone in it, so
        // this lands on the same answer a linear walk would, in log steps.
        var low = 0, high = max(0, characters.count - 1)
        while low < high {
            let mid = (low + high + 1) / 2
            if measure(String(characters.prefix(mid)) + "…") <= maxWidth {
                low = mid
            } else {
                high = mid - 1
            }
        }
        let candidate = String(characters.prefix(low)) + "…"
        // Even the ellipsis alone can be too wide for a hairline column; an
        // empty plate is better than one that overflows it.
        return measure(candidate) <= maxWidth ? candidate : ""
    }
}

/// Callouts in the margin with leader lines — the cartographer's answer to a map
/// whose labels cover the terrain they name.
///
/// Everything here is a pure function of the requests and the canvas, so that
/// "no plate touches the room" is a property that can be asserted rather than
/// eyeballed. The room's own fit reserves exactly `columnWidth` on each side
/// (`IsoLayout.labelColumnWidth`), and this layout never leaves that reservation.
enum MarginLabelLayout {
    /// Air between a plate and the pane's edge, and between the plate and the
    /// column's inner boundary.
    static let padding: Double = 8
    /// The gap between two stacked plates. Enough that two dark plates read as
    /// two, not as one tall one.
    static let stackGap: Double = 6

    static func place(_ requests: [MarginLabelRequest],
                      canvas: CGSize,
                      columnWidth: Double,
                      roomCentreX: Double) -> [MarginLabel] {
        guard !requests.isEmpty, canvas.width > 0, canvas.height > 0, columnWidth > 0 else {
            return []
        }
        let (left, right) = split(requests, roomCentreX: roomCentreX)
        return stack(left, column: .left, canvas: canvas, columnWidth: columnWidth)
            + stack(right, column: .right, canvas: canvas, columnWidth: columnWidth)
    }

    /// Each plate to its nearer margin, then balanced: with the requests sorted
    /// by the worker's x, a split point is a side assignment that is still
    /// "nearer margin" for everything except the few in the middle that had to
    /// cross. Clamping the split to half the set is what keeps one crowded side
    /// from running out of column while the other stands empty.
    private static func split(_ requests: [MarginLabelRequest], roomCentreX: Double)
        -> ([MarginLabelRequest], [MarginLabelRequest]) {
        let sorted = requests.sorted { a, b in
            a.worker.x == b.worker.x ? a.id < b.id : a.worker.x < b.worker.x
        }
        let n = sorted.count
        let cap = (n + 1) / 2
        let natural = sorted.filter { $0.worker.x < roomCentreX }.count
        let leftCount = max(n - cap, min(natural, cap))
        return (Array(sorted.prefix(leftCount)), Array(sorted.dropFirst(leftCount)))
    }

    /// Stack one column, ordered by the screen height of what each plate points
    /// at, so the leader lines run roughly parallel and do not cross.
    private static func stack(_ requests: [MarginLabelRequest],
                              column: MarginColumn,
                              canvas: CGSize,
                              columnWidth: Double) -> [MarginLabel] {
        guard !requests.isEmpty else { return [] }
        let ordered = requests.sorted { a, b in
            a.worker.y == b.worker.y ? a.id < b.id : a.worker.y < b.worker.y
        }
        let height = ordered.map(\.height).max() ?? 0
        let top = padding
        let bottom = canvas.height - padding
        // What the column can hold at all. Beyond it the plates would be pushed
        // off the bottom of the pane by the relaxation below, so the overflow is
        // dropped instead: a label half off-screen names nobody, and the crystal
        // over the figure still says what state it is in.
        let capacity = height > 0
            ? max(0, Int(((bottom - top) + stackGap) / (height + stackGap)))
            : ordered.count
        let kept = Array(ordered.prefix(capacity))
        guard !kept.isEmpty else { return [] }

        // Wanted position first, then two sweeps: down to separate, up to pull
        // the tail back inside the pane. Two sweeps are enough because the
        // capacity check above guarantees the stack fits.
        var ys = kept.map { min(max($0.worker.y - $0.height / 2, top), bottom - $0.height) }
        for i in 1..<kept.count {
            ys[i] = max(ys[i], ys[i - 1] + kept[i - 1].height + stackGap)
        }
        if let last = ys.last, last + kept[kept.count - 1].height > bottom {
            ys[kept.count - 1] = bottom - kept[kept.count - 1].height
            for i in stride(from: kept.count - 2, through: 0, by: -1) {
                ys[i] = min(ys[i], ys[i + 1] - kept[i].height - stackGap)
            }
        }

        let inner = max(0, columnWidth - 2 * padding)
        return kept.enumerated().map { i, request in
            let width = min(request.width, inner)
            let x = column == .left
                ? padding
                : canvas.width - padding - width
            return MarginLabel(id: request.id,
                               rect: clamped(CGRect(x: x, y: ys[i],
                                                    width: width, height: request.height),
                                             in: canvas),
                               column: column,
                               worker: request.worker)
        }
    }

    /// The structural backstop: whatever the text measured to and wherever the
    /// relaxation put it, a plate cannot leave the pane. Correct truncation
    /// should already make this a no-op — but "should" is not a property, and a
    /// plate hanging off the edge is the one failure a reader cannot work around.
    private static func clamped(_ rect: CGRect, in canvas: CGSize) -> CGRect {
        let width = min(rect.width, canvas.width)
        let height = min(rect.height, canvas.height)
        return CGRect(x: min(max(rect.minX, 0), canvas.width - width),
                      y: min(max(rect.minY, 0), canvas.height - height),
                      width: width, height: height)
    }
}
