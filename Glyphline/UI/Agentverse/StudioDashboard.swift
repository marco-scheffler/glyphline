import SwiftUI

/// The Studio's own night palette for the chrome around the floor. Always dark:
/// the Studio is a night scene whatever the system appearance.
enum StudioChrome {
    static let background = Color(red: 7 / 255, green: 6 / 255, blue: 15 / 255)
    static let panelTop = Color(red: 24 / 255, green: 20 / 255, blue: 51 / 255)
    static let panelBottom = Color(red: 18 / 255, green: 15 / 255, blue: 36 / 255)
    static let line = Color(red: 44 / 255, green: 37 / 255, blue: 88 / 255)
    static let text = Color(red: 236 / 255, green: 232 / 255, blue: 1)
    static let dim = Color(red: 143 / 255, green: 134 / 255, blue: 196 / 255)
    static let cyan = Color(red: 46 / 255, green: 214 / 255, blue: 206 / 255)
    static let violet = Color(red: 166 / 255, green: 107 / 255, blue: 1)
    static let waveLine = Color(red: 195 / 255, green: 155 / 255, blue: 1)
    static let amber = Color(red: 1, green: 176 / 255, blue: 32 / 255)
}

private struct StudioPanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                LinearGradient(colors: [StudioChrome.panelTop, StudioChrome.panelBottom],
                               startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(StudioChrome.line))
    }
}

private struct PanelTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(StudioChrome.dim)
            .lineLimit(1)
    }
}

/// The four tiles above the floor.
struct StudioKPIRow: View {
    let tiles: [StudioTile]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                StudioTileView(tile: tile)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct StudioTileView: View {
    let tile: StudioTile

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PanelTitle(text: tile.title)
            HStack(alignment: .bottom, spacing: 8) {
                Text(tile.value)
                    .font(.system(size: 24, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(StudioChrome.text)
                    .lineLimit(1)
                    // Shrinks rather than widening the tile: a fixed size here
                    // would cancel the scale factor.
                    .minimumScaleFactor(0.6)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                if tile.sparkline.count > 1 {
                    Sparkline(values: tile.sparkline)
                        .stroke(StudioChrome.cyan, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                        .shadow(color: StudioChrome.cyan.opacity(0.7), radius: 3)
                        .frame(minWidth: 24, maxWidth: 72)
                        .frame(height: 26)
                }
            }
            if let bar = tile.bar {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.08))
                        Capsule().fill(bar >= 0.8 ? StudioChrome.amber : StudioChrome.violet)
                            .frame(width: proxy.size.width * min(max(bar, 0), 1))
                            .shadow(color: StudioChrome.violet.opacity(0.8), radius: 4)
                    }
                }
                .frame(height: 4)
            }
            if let caption = tile.caption {
                Text(caption)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(StudioChrome.dim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .modifier(StudioPanel())
    }
}

/// A line through `values`, scaled to the rect, oldest on the left.
private struct Sparkline: Shape {
    let values: [Double]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1, let top = values.max() else { return path }
        let peak = max(top, 1)
        for (index, value) in values.enumerated() {
            let point = CGPoint(x: rect.minX + rect.width * Double(index) / Double(values.count - 1),
                                y: rect.maxY - rect.height * value / peak)
            index == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        return path
    }
}

/// The wave and the feed beneath the floor.
struct StudioBottomRow: View {
    let log: StudioActivityLog
    let now: Date
    static let feedRows = 5

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                PanelTitle(text: String(localized: "Tokens per minute",
                                        comment: "Studio panel title over the live tokens-per-minute wave. Drawn in capitals; keep it short."))
                wave
            }
            .modifier(StudioPanel())
            .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                PanelTitle(text: String(localized: "Recent",
                                        comment: "Studio panel title over the feed of what the sessions did most recently. Drawn in capitals; keep it short."))
                feed
            }
            .modifier(StudioPanel())
            .frame(maxWidth: .infinity)
        }
        .frame(height: 132)
    }

    /// 22:59 on the reference day: two-digit hours and minutes, and the
    /// evening marker where the locale has one.
    private static var widestTime: String {
        let day = Date(timeIntervalSinceReferenceDate: 0)
        let sample = Calendar.current.date(bySettingHour: 22, minute: 59, second: 0, of: day) ?? day
        return sample.formatted(date: .omitted, time: .shortened)
    }

    private static let collecting = String(localized: "Collecting…",
                                           comment: "Studio wave and feed placeholder until enough sweeps have run to draw anything.")

    @ViewBuilder private var wave: some View {
        let segments = log.segments()
        if segments.contains(where: { $0.count > 1 }) {
            let start = now.addingTimeInterval(-StudioActivityLog.window)
            let peak = max(log.samples.map(\.tokensPerMinute).max() ?? 1, 1)
            ZStack {
                WaveShape(segments: segments, start: start, end: now, peak: peak, filled: true)
                    .fill(LinearGradient(colors: [StudioChrome.violet.opacity(0.45), StudioChrome.violet.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                WaveShape(segments: segments, start: start, end: now, peak: peak, filled: false)
                    .stroke(StudioChrome.waveLine, style: StrokeStyle(lineWidth: 2, lineJoin: .round))
                    .shadow(color: StudioChrome.violet, radius: 4)
            }
        } else {
            placeholder
        }
    }

    @ViewBuilder private var feed: some View {
        if log.entries.isEmpty {
            placeholder
        } else {
            VStack(alignment: .leading, spacing: 5) {
                // By offset: an entry has no id of its own.
                ForEach(Array(log.entries.prefix(Self.feedRows).enumerated()), id: \.offset) { _, entry in
                    let tint = entry.change == .startedWaiting
                        ? StudioChrome.amber : SessionPalette.forSession(entry.sessionID).color
                    HStack(spacing: 8) {
                        // As wide as the locale's widest time, measured by laying
                        // a sample out under it, so "11:46 AM" neither wraps nor
                        // shifts the column from row to row.
                        ZStack(alignment: .leading) {
                            Text(Self.widestTime).hidden()
                            Text(entry.at.formatted(date: .omitted, time: .shortened))
                        }
                        .foregroundStyle(StudioChrome.dim)
                        .lineLimit(1)
                        .fixedSize()
                        RoundedRectangle(cornerRadius: 2)
                            .fill(tint)
                            .frame(width: 8, height: 8)
                            .shadow(color: tint, radius: 3)
                        (Text(entry.title).bold().foregroundColor(tint)
                         + Text("  " + StudioDashboardModel.changeText(entry.change))
                            .foregroundColor(entry.change == .startedWaiting ? StudioChrome.amber : StudioChrome.text))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.system(size: 11, design: .monospaced))
                }
            }
        }
    }

    private var placeholder: some View {
        Text(Self.collecting)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(StudioChrome.dim)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Each segment its own sub-path, so a gap in the samples is a gap in the line.
private struct WaveShape: Shape {
    let segments: [[StudioActivityLog.Sample]]
    let start: Date
    let end: Date
    let peak: Double
    let filled: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let span = max(end.timeIntervalSince(start), 1)
        func point(_ sample: StudioActivityLog.Sample) -> CGPoint {
            let x = rect.minX + rect.width * min(max(sample.at.timeIntervalSince(start) / span, 0), 1)
            let y = rect.maxY - rect.height * 0.92 * min(sample.tokensPerMinute / peak, 1)
            return CGPoint(x: x, y: y)
        }
        for segment in segments where segment.count > 1 {
            let points = segment.map(point)
            if filled {
                path.move(to: CGPoint(x: points[0].x, y: rect.maxY))
                points.forEach { path.addLine(to: $0) }
                path.addLine(to: CGPoint(x: points[points.count - 1].x, y: rect.maxY))
                path.closeSubpath()
            } else {
                path.move(to: points[0])
                points.dropFirst().forEach { path.addLine(to: $0) }
            }
        }
        return path
    }
}
