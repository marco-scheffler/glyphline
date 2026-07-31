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
    let lapText: String
    let state: State

    var stateText: String { state.text }
    var isWaiting: Bool { state == .waiting }

    init(session: AgentSession, workTokens: Int64) {
        self.init(cwd: session.cwd, branch: session.gitBranch,
                  subagentCount: session.subagentCount, workTokens: workTokens,
                  state: session.activity == .waitingForYou ? .waiting : .working)
    }

    /// A session in the pit lane. It reads the same as one on track apart from
    /// its state — it is the same session, standing still.
    init(parked: ParkedAgentSession, workTokens: Int64) {
        self.init(cwd: parked.cwd, branch: parked.gitBranch,
                  subagentCount: parked.subagentCount, workTokens: workTokens,
                  state: .parked)
    }

    private init(cwd: String, branch: String?, subagentCount: Int, workTokens: Int64,
                 state: State) {
        // The last component only: the column is 264 px wide, and the leading
        // part of the path is the same on every row.
        title = URL(fileURLWithPath: cwd).lastPathComponent
        var parts: [String] = []
        if let branch, !branch.isEmpty { parts.append(branch) }
        if subagentCount > 0 { parts.append("+\(subagentCount)") }
        subtitle = parts.joined(separator: " · ")
        lapText = "L\(CarPosition.lapCount(workTokens: workTokens))"
        self.state = state
    }
}

struct AgentRow: View {
    let model: AgentRowModel
    let livery: CarLivery

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 2)
                .fill(livery.body)
                .overlay(RoundedRectangle(cornerRadius: 2).stroke(livery.accent, lineWidth: 2))
                .frame(width: 20, height: 11)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title).font(.callout)
                if !model.subtitle.isEmpty {
                    Text(model.subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Text(model.lapText).font(.caption.monospacedDigit())
            Text(model.stateText)
                .font(.caption2)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(model.state.tint, in: RoundedRectangle(cornerRadius: 4))
        }
    }
}
