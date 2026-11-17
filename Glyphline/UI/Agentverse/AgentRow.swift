import SwiftUI

/// One line of the list, as text rather than as a view, so what it says can be
/// asserted without rendering anything.
struct AgentRowModel: Equatable {
    /// Three states, one value: a row cannot be waiting *and* parked, and a
    /// pair of booleans would let it claim to be.
    enum State: Equatable {
        case working, waiting, parked

        var text: String {
            switch self {
            case .working:
                String(localized: "working", comment: "Agent state: this coding agent is busy running. Shown both as a small pill beside a row and as the caption under a count. Lower case, one short word — the space is narrow in both places.")
            case .waiting:
                String(localized: "waiting", comment: "Agent list badge: this coding agent has stopped and is waiting for the user to answer it. Lower case, one or two words — it is a small pill beside the row.")
            case .parked:
                String(localized: "parked", comment: "Agent list badge: this coding agent's session is idle — still open, but nothing is running and nothing is being asked of the user. Lower case, one or two words — it is a small pill beside the row.")
            }
        }

        var tint: Color {
            switch self {
            case .working: Color.green.opacity(0.18)
            case .waiting: Color.orange.opacity(0.22)
            case .parked: Color.white.opacity(0.10)
            }
        }
    }

    let title: String
    let subtitle: String
    /// The work done, in millions of tokens: "36.1M". Its own column rather than
    /// part of the subtitle, so the numbers line up down the list the way the
    /// reference sketch has them.
    let tokenText: String
    let state: State
    /// The colour this session wears in the scene. The row carries it so that
    /// picking a figure out of the room and finding it in the list is one look
    /// rather than two.
    let swatch: Color
    /// The session the row stands for, so a card can draw its figure.
    let sessionID: String
    /// What the session is doing, in words: its last action, how long it has
    /// waited, or that it is parked.
    let actionText: String
    let subagentCount: Int
    /// Repository · branch, without the subagent count.
    let placeText: String
    /// This session's work tokens against the busiest one listed, 0…1.
    let tokenFraction: Double

    var stateText: String { state.text }

    init(session: AgentSession, workTokens: Int64, now: Date = Date(), tokenFraction: Double = 0) {
        let waiting = session.activity == .waitingForYou
        self.init(sessionID: session.id, label: session.displayTitle,
                  repository: session.repositoryName, branch: session.gitBranch,
                  subagentCount: session.subagentCount, workTokens: workTokens,
                  state: waiting ? .waiting : .working,
                  actionText: waiting
                      ? StudioBubble.waitingText(since: session.lastActivityAt, now: now)
                      : session.action.text,
                  tokenFraction: tokenFraction)
    }

    /// A session in the pit lane. It reads the same as one on track apart from
    /// its state — it is the same session, standing still.
    init(parked: ParkedAgentSession, workTokens: Int64, tokenFraction: Double = 0) {
        self.init(sessionID: parked.sessionID, label: parked.displayTitle,
                  repository: parked.repositoryName, branch: parked.gitBranch,
                  subagentCount: parked.subagentCount, workTokens: workTokens,
                  state: .parked, actionText: State.parked.text,
                  tokenFraction: tokenFraction)
    }

    private init(sessionID: String, label: String, repository: String, branch: String?,
                 subagentCount: Int, workTokens: Int64, state: State,
                 actionText: String, tokenFraction: Double) {
        title = SessionLabel.truncated(label, to: SessionLabel.sidebarLimit)
        // The repository leads the second line now that the first one names the
        // work: it is what every session in a checkout shares, so it is context
        // rather than identity. Suppressed when it is already the title, which is
        // what a session with neither a title nor a slug falls back to.
        var parts: [String] = []
        if !repository.isEmpty, repository != label { parts.append(repository) }
        if let branch, !branch.isEmpty { parts.append(branch) }
        // The card carries "+N" as its own badge, so its line stops here.
        placeText = parts.joined(separator: " · ")
        if subagentCount > 0 { parts.append("+\(subagentCount)") }
        subtitle = parts.joined(separator: " · ")
        tokenText = AgentRowModel.millions(workTokens)
        self.state = state
        swatch = SessionPalette.forSession(sessionID).color
        self.sessionID = sessionID
        self.actionText = actionText
        self.subagentCount = subagentCount
        self.tokenFraction = min(1, max(0, tokenFraction))
    }

    /// One session's work against the busiest one listed; 0 when nobody has
    /// done any, so an idle list draws empty bars rather than dividing by zero.
    static func tokenFraction(_ tokens: Int64, largest: Int64) -> Double {
        guard largest > 0 else { return 0 }
        return min(1, max(0, Double(tokens) / Double(largest)))
    }

    /// Not localised on purpose: this sits in a monospaced column beside other
    /// numbers, and a decimal comma in one place and a point in another is the
    /// kind of thing that only shows up on someone else's machine.
    static func millions(_ tokens: Int64) -> String {
        String(format: "%.1fM", max(0, Double(tokens)) / 1_000_000)
    }
}

struct AgentRow: View {
    let model: AgentRowModel

    var body: some View {
        HStack(spacing: 9) {
            // A diamond, as in the reference: a square rotated 45°, small
            // enough to be a mark rather than a block of colour.
            RoundedRectangle(cornerRadius: 2)
                .fill(model.swatch)
                .frame(width: 8, height: 8)
                .rotationEffect(.degrees(45))
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title).font(.callout)
                if !model.subtitle.isEmpty {
                    Text(model.subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Text(model.tokenText)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text(model.stateText)
                .font(.caption2)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(model.state.tint, in: RoundedRectangle(cornerRadius: 4))
        }
    }
}

/// The studio's version of a row: a neon card with the session's figure, its
/// action in the session colour, a work-token bar and a state dot.
struct StudioAgentCard: View {
    let model: AgentRowModel

    private static let amber = Color(red: 1, green: 176 / 255, blue: 32 / 255)
    private static let green = Color(red: 77 / 255, green: 1, blue: 154 / 255)
    private static let off = Color(red: 85 / 255, green: 80 / 255, blue: 122 / 255)
    private static let base = Color(red: 12 / 255, green: 10 / 255, blue: 26 / 255)
    private static let tokenInk = Color(red: 207 / 255, green: 200 / 255, blue: 1)

    private var parked: Bool { model.state == .parked }
    private var tint: Color { parked ? Self.off : model.swatch }
    private var actionTint: Color { model.state == .waiting ? Self.amber : tint }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 0) {
                Text(model.title)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1).truncationMode(.tail)
                if !model.placeText.isEmpty {
                    Text(model.placeText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                        .padding(.top, 1)
                }
                actionLine
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(actionTint)
                    .padding(.top, 4)
                bar.padding(.top, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 6) {
                StudioStateDot(state: model.state, colour: dotColour)
                Text(model.tokenText)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Self.tokenInk)
                if model.subagentCount > 0 {
                    Text(verbatim: "+\(model.subagentCount)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(tint)
                        .padding(.horizontal, 4)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(tint, lineWidth: 1))
                }
            }
        }
        .padding(.vertical, 9).padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(Self.base)
                .overlay(RoundedRectangle(cornerRadius: 11).fill(tint.opacity(0.09)))
        )
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(tint, lineWidth: 1.5))
        .shadow(color: parked ? .clear : tint.opacity(0.22), radius: 7)
        .opacity(parked ? 0.6 : 1)
        // The card is the Studio's night palette on a near-black fill; in a
        // light system appearance the default label colours would vanish on it.
        .environment(\.colorScheme, .dark)
    }

    /// While waiting, the minutes are the news: the sentence is split at its
    /// last "·" and only the lead gives way, so "· 123 min" survives a 240 pt
    /// sidebar. The wording stays `StudioBubble.waitingText`'s own.
    @ViewBuilder
    private var actionLine: some View {
        let text = model.actionText
        if model.state == .waiting, let split = text.range(of: "·", options: .backwards) {
            HStack(spacing: 0) {
                Text(verbatim: String(text[..<split.lowerBound]))
                    .lineLimit(1).truncationMode(.tail)
                Text(verbatim: String(text[split.lowerBound...]))
                    .lineLimit(1).fixedSize().layoutPriority(1)
            }
            // One sentence for VoiceOver, not a lead and a tail.
            .accessibilityElement(children: .combine)
        } else {
            Text(verbatim: text).lineLimit(1).truncationMode(.tail)
        }
    }

    private var dotColour: Color {
        switch model.state {
        case .working: Self.green
        case .waiting: Self.amber
        case .parked: Self.off
        }
    }

    /// The figure's head, drawn by the floor's own renderer so the card and
    /// the desk show the same person.
    private var avatar: some View {
        let figure = StudioFigure.forSession(model.sessionID)
        let parked = parked
        return Canvas { context, size in
            let scale = size.width / 60
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.scaleBy(x: scale, y: scale)
            if parked {
                context.fill(Path(ellipseIn: CGRect(x: -14, y: -14, width: 28, height: 28)),
                             with: .color(Self.off))
            } else {
                StudioRenderer(hovered: nil, frame: 0, now: .distantPast)
                    .drawFigure(context, figure: figure, cup: false)
            }
        }
        .frame(width: 38, height: 38)
        .background(Self.base.overlay(tint.opacity(0.30)))
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private var bar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule().fill(tint)
                    .frame(width: proxy.size.width * model.tokenFraction)
                    .shadow(color: tint, radius: 4)
            }
        }
        .frame(height: 3)
    }
}

/// Green while working, amber and pulsing while waiting, grey when parked.
private struct StudioStateDot: View {
    let state: AgentRowModel.State
    let colour: Color
    @State private var dimmed = false

    var body: some View {
        Circle()
            .fill(colour)
            .frame(width: 9, height: 9)
            .shadow(color: state == .parked ? .clear : colour, radius: 4.5)
            .opacity(dimmed ? 0.35 : 1)
            .scaleEffect(dimmed ? 0.8 : 1)
            .onAppear { pulse() }
            .onChange(of: state) { _, _ in pulse() }
    }

    private func pulse() {
        if state == .waiting {
            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { dimmed = true }
        } else {
            withAnimation(.default) { dimmed = false }
        }
    }
}
