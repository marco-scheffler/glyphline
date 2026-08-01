import SwiftUI

/// The drawing, separated from where its inputs come from.
///
/// A placeholder for now: the circuit it used to draw has been removed, and the
/// two stylised views that replace it are not built yet. What survives is the
/// shape of the contract, because that is the part the window depends on.
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

    var body: some View {
        // A flat fill and nothing else. Deliberately not an empty view: the
        // window puts an overlay on top of this, and a zero-sized scene would
        // collapse the split view's right-hand pane.
        Color(white: 0.07)
    }
}
