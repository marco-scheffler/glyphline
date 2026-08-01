import SwiftUI

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
    /// The sun and the sky, resolved by the window on its own slow clock. Like
    /// `frame`, it enters here rather than being read inside the drawing.
    let lighting: OfficeLighting

    var body: some View {
        OfficeScene(sessions: sessions,
                    parked: parked,
                    workTokens: workTokens,
                    hovered: hovered,
                    frame: frame,
                    lighting: lighting)
    }
}
