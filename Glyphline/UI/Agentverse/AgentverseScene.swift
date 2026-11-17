import SwiftUI

/// Which of the two pictures the Agentverse shows.
///
/// Unlike the circuit choice this one is kept across launches: it is which of
/// two tools the user prefers, not which of five equivalent tracks they feel
/// like today, and asking again every launch would nag.
enum AgentverseView: String, CaseIterable, Identifiable {
    case office
    case datastream
    case studio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .office: "Office"
        case .datastream: "Datastream"
        case .studio: "Studio"
        }
    }
}

/// The drawing, separated from where its inputs come from.
///
/// The circuit it used to draw has been removed; what it draws now is the
/// isometric office. This type survives as the contract the window depends on,
/// so which view is on screen stays a change to one file.
///
/// `frame` replaces the clock: the window passes the running frame number, a
/// test passes a fixed one. Without that the picture would depend on when it was
/// taken and no two renders could be compared. The inputs are kept even though
/// nothing reads them yet, so that filling this in later is a change to one
/// file rather than to the window as well.
struct AgentverseScene: View {
    let sessions: [AgentSession]
    let parked: [ParkedAgentSession]
    /// Tokens worked per session id, keyed the same way the sidebar keys it.
    let workTokens: [String: Int64]
    let hovered: String?
    let frame: Int
    /// The wall clock at this frame, for the studio's "N min" bubbles. Enters
    /// as a value like `frame`; the office and the datastream ignore it.
    let now: Date
    /// The sun and the sky, resolved by the window on its own slow clock. Like
    /// `frame`, it enters here rather than being read inside the drawing.
    let lighting: OfficeLighting
    /// Which picture to draw. Enters as a value for the same reason the frame
    /// does: the scene stays a pure function of its inputs.
    let view: AgentverseView

    var body: some View {
        switch view {
        case .office:
            OfficeScene(sessions: sessions,
                        parked: parked,
                        workTokens: workTokens,
                        hovered: hovered,
                        frame: frame,
                        lighting: lighting)
        case .datastream:
            DatastreamScene(sessions: sessions,
                            parked: parked,
                            workTokens: workTokens,
                            hovered: hovered,
                            frame: frame)
        case .studio:
            // Parked sessions are not on the floor.
            StudioFloor(sessions: sessions,
                        hovered: hovered,
                        frame: frame,
                        now: now)
        }
    }
}
