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
            case .working: "working"
            case .waiting: "waiting"
            case .parked: "parked"
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

    var stateText: String { state.text }

    init(session: AgentSession, workTokens: Int64) {
        self.init(sessionID: session.id, cwd: session.cwd, branch: session.gitBranch,
                  subagentCount: session.subagentCount, workTokens: workTokens,
                  state: session.activity == .waitingForYou ? .waiting : .working)
    }

    /// A session in the pit lane. It reads the same as one on track apart from
    /// its state — it is the same session, standing still.
    init(parked: ParkedAgentSession, workTokens: Int64) {
        self.init(sessionID: parked.sessionID, cwd: parked.cwd, branch: parked.gitBranch,
                  subagentCount: parked.subagentCount, workTokens: workTokens,
                  state: .parked)
    }

    private init(sessionID: String, cwd: String, branch: String?, subagentCount: Int,
                 workTokens: Int64, state: State) {
        // The last component only: the column is 264 px wide, and the leading
        // part of the path is the same on every row.
        title = URL(fileURLWithPath: cwd).lastPathComponent
        var parts: [String] = []
        if let branch, !branch.isEmpty { parts.append(branch) }
        if subagentCount > 0 { parts.append("+\(subagentCount)") }
        subtitle = parts.joined(separator: " · ")
        tokenText = AgentRowModel.millions(workTokens)
        self.state = state
        swatch = SessionPalette.forSession(sessionID).color
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
