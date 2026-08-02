import SwiftUI

/// The office seen from above: floor, walls, desks and the break room.
///
/// A port of the approved reference sketch, but no longer lit by the sketch's
/// fixed lamp: the key light's angle and colour, the sky in the windows and the
/// pools on the floor all come from `OfficeLighting` — the real sun over the
/// user's own place, under the real weather there.
///
/// The people are here too: whoever is working sits at a desk with a green
/// crystal over its head, whoever is waiting on you has got up and gone to the
/// break room under an amber one, and whoever is off the clock is on the sofa
/// strip along the bottom under a grey one.
struct OfficeScene: View {
    let sessions: [AgentSession]
    let parked: [ParkedAgentSession]
    /// Tokens worked per session id, keyed the same way the sidebar keys it.
    let workTokens: [String: Int64]
    let hovered: String?
    let frame: Int
    /// The sun and the sky, resolved by the window and passed in like the frame
    /// number, so the scene stays a pure function of its inputs.
    let lighting: OfficeLighting

    var body: some View {
        // Pulled out of the closure: `Canvas`'s renderer is `@Sendable`, so it
        // may only capture values, never the view.
        // The full title, not a character-clipped one: the renderer cuts it to
        // the measured width of the column it will actually be drawn in, and a
        // count clipped here would only ever be right at one window size.
        let desks = sessions.map { session in
            OfficeDesk(id: session.id,
                       name: session.displayTitle,
                       repository: session.repositoryName,
                       waiting: session.activity == .waitingForYou,
                       subagentCount: session.subagentCount,
                       workTokens: workTokens[session.id] ?? 0)
        }
        let offClock = parked.map { session in
            OfficeDesk(id: session.sessionID,
                       name: session.displayTitle,
                       repository: session.repositoryName,
                       waiting: false,
                       subagentCount: session.subagentCount,
                       workTokens: workTokens[session.sessionID] ?? 0)
        }
        let hovered = hovered
        let frame = frame
        let lighting = lighting

        Canvas(opaque: true) { context, size in
            OfficeRenderer(layout: IsoLayout.fit(sessionCount: desks.count, canvas: size),
                           frame: frame,
                           hovered: hovered,
                           lighting: lighting)
                .draw(in: context, size: size, desks: desks, offClock: offClock)
        }
    }
}

/// What the room needs to know about one session to give it a desk.
struct OfficeDesk: Equatable, Sendable {
    let id: String
    /// What the plate leads with: what this session is doing, in full. The
    /// renderer cuts it to the measured width of its label column.
    let name: String
    /// The second line's first field. Every desk in one checkout repeats it,
    /// which is exactly why it is no longer the name.
    let repository: String
    let waiting: Bool
    let subagentCount: Int
    let workTokens: Int64

    /// The shirt this session wears. Derived from the id and from nothing else,
    /// so it survives a restart and matches the sidebar's swatch.
    var shirt: SceneRGB { SessionPalette.forSession(id).shirt }

    /// A per-session offset into every wobble the figure has, so a room full of
    /// people does not breathe in unison.
    var seed: Double {
        Double(SessionPalette.fnv1a(id) % 6_283) / 1_000
    }

    /// "glyphline · 36.1M · +54" — the reference's numbers, with the repository
    /// in front of them now that the plate's first line is the title.
    var caption: String {
        var parts: [String] = []
        if !repository.isEmpty, repository != name { parts.append(repository) }
        parts.append(AgentRowModel.millions(workTokens))
        if subagentCount > 0 { parts.append("+\(subagentCount)") }
        return parts.joined(separator: " · ")
    }
}
