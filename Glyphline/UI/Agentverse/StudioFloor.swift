import SwiftUI

/// The studio view's floor: one desk per on-track session and the break room the
/// waiting ones stand in.
///
/// Like the office and the datastream it is a pure function of its inputs. The
/// frame drives the decoration; `now` only feeds the "N min" bubbles.
struct StudioFloor: View {
    let sessions: [AgentSession]
    let hovered: String?
    let frame: Int
    let now: Date

    /// One desk per session, in the order the coordinator keeps them. State is
    /// read from `activity` alone; the action only feeds the bubble.
    static func desks(from sessions: [AgentSession]) -> [StudioDesk] {
        sessions.map { session in
            let waiting = session.activity == .waitingForYou
            return StudioDesk(id: session.id,
                              name: session.displayTitle,
                              waiting: waiting,
                              action: session.action,
                              waitingSince: waiting ? session.lastActivityAt : nil,
                              figure: StudioFigure.forSession(session.id))
        }
    }

    var body: some View {
        let desks = Self.desks(from: sessions)
        let renderer = StudioRenderer(hovered: hovered, frame: frame, now: now)
        Canvas(rendersAsynchronously: false) { context, size in
            renderer.draw(in: context, size: size, desks: desks)
        }
    }
}
