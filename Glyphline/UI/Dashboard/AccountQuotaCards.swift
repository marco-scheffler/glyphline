import SwiftUI

// MARK: - The quota card

/// One account's quota: its name at the top, every window it reports stacked
/// beneath.
///
/// The name is a stored property with no default and no optional, so this card
/// cannot be built without it. That is what keeps an account unambiguous now
/// that the window rows no longer repeat it — the compiler, rather than a
/// convention each call site has to remember.
struct AccountQuotaCardModel: Identifiable, Equatable {
    var id: UUID
    var accountName: String
    var providerName: String
    var cards: [QuotaCardModel]
    /// Why there are no windows to draw, when there are none. Rendered inside
    /// the card rather than in place of it: an account that reports nothing is
    /// still an account, and dropping its card would make it look unconfigured.
    var message: String?
}

/// The account cards, filling the row and sharing its width evenly.
///
/// A `LazyVGrid` of adaptive columns stood here. It reflows, but its cells size
/// themselves, so three accounts with unequal amounts to say came out ragged —
/// and a spent weekly window renders a different number of lines from one at
/// 100 %, so ragged was the normal case rather than the unlucky one.
///
/// This is instead the same shape the summary tiles use: a row is an `HStack` of
/// cards that each claim `maxWidth: .infinity` (even widths) and
/// `maxHeight: .infinity` (the row's height, so the shortest card's glass still
/// reaches the bottom edge), fixed on the vertical axis because the enclosing
/// `ScrollView` proposes nil height and an unbounded `maxHeight` would otherwise
/// have nothing finite to fill.
///
/// `ViewThatFits` picks how many columns the pane can carry: each candidate row
/// is as many cards wide as it says, and a card will not go below
/// `minimumCardWidth`, so the widest candidate that still fits wins. That is
/// what makes the layout answer both questions at once — a narrower window and
/// a fourth account reflow by the same rule.
struct AccountQuotaGrid: View {
    let accounts: [AccountQuotaCardModel]

    /// Below this a card's headroom figure and its pace sentence stop fitting on
    /// their own lines. It is the same 300 the adaptive grid used.
    static let minimumCardWidth: CGFloat = 300
    static let spacing: CGFloat = 14

    var body: some View {
        ViewThatFits(in: .horizontal) {
            ForEach(Self.columnCandidates(accountCount: accounts.count), id: \.self) { columns in
                grid(columns: columns)
            }
        }
    }

    /// The column counts to try, widest first: never more columns than there are
    /// accounts, and never fewer than one — a single column always "fits",
    /// because `ViewThatFits` falls back to its last candidate regardless.
    static func columnCandidates(accountCount: Int) -> [Int] {
        guard accountCount > 1 else { return [1] }
        return Array((1...accountCount).reversed())
    }

    /// The accounts split into rows of at most `columns`.
    static func rows(of accounts: [AccountQuotaCardModel], columns: Int) -> [[AccountQuotaCardModel]] {
        let width = max(columns, 1)
        return stride(from: 0, to: accounts.count, by: width).map {
            Array(accounts[$0..<min($0 + width, accounts.count)])
        }
    }

    private func grid(columns: Int) -> some View {
        VStack(spacing: Self.spacing) {
            ForEach(Self.rows(of: accounts, columns: columns), id: \.first?.id) { row in
                HStack(alignment: .top, spacing: Self.spacing) {
                    ForEach(row) { account in
                        AccountQuotaCard(model: account)
                    }
                    // A short last row keeps the column widths of the rows above
                    // it instead of stretching two cards across three columns.
                    if row.count < columns {
                        ForEach(0..<(columns - row.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct AccountQuotaCard: View {
    let model: AccountQuotaCardModel

    private var accountName: String { model.accountName }
    private var providerName: String { model.providerName }
    private var cards: [QuotaCardModel] { model.cards }
    private var message: String? { model.message }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(accountName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(providerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(cards) { card in
                    QuotaWindowRow(card: card)
                }
            }

            // The slack from equalising a row's heights goes below the content,
            // as it does in the summary tiles: an account with one window keeps
            // its figures on the same lines as the account beside it with two.
            Spacer(minLength: 0)
        }
        .frame(
            minWidth: AccountQuotaGrid.minimumCardWidth,
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
        .padding(16)
        .glassCard()
    }
}

/// One window inside its account's card: headroom, bar with pace marker, pace
/// sentence.
private struct QuotaWindowRow: View {
    let card: QuotaCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle(DashboardPresentation.quotaWindowLabel(for: card.kind))
                .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(card.headroomPercent)")
                    .font(.system(size: 28, weight: .semibold))
                    .monospacedDigit()
                Text("% free")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Spacer()
                // Percentages and nothing else: `RateWindow` reports a consumed
                // fraction and carries no token cap, so the reference's
                // "12.4M / 19.8M" would be a figure this app invented.
                Text(card.usageText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.top, 8)

            QuotaBar(card: card)
                .padding(.vertical, 10)

            HStack(spacing: 7) {
                Circle()
                    .fill(card.state.tint)
                    .frame(width: 7, height: 7)
                Text(card.paceText ?? card.headroomText)
                    .font(.caption)
            }

            // Its own line, indented past the dot to sit under the status text
            // rather than under the dot — 7 points of circle plus 7 of spacing.
            //
            // Under the status line and quieter than it, because the two say
            // different kinds of thing: the status line is the urgent statement
            // and carries the tint, the reset is the background fact. Appending
            // it to the status line instead would put the card's longest text on
            // the line that has to survive three cards side by side.
            //
            // Monospaced digits so the three cards in a row keep their digits in
            // the same columns as each other, and so a card does not shift when
            // the text is recomputed with different digits. It does not tick:
            // the string is snapshotted in `QuotaCardModel.make` and only
            // rebuilt when `DashboardPresentation` does, on a coordinator
            // publish.
            if let resetText = card.resetText {
                Text(resetText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .padding(.leading, 14)
                    .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The bar and its pace marker. The marker is the point of the card: "37 % left"
/// says nothing on its own, "37 % left where an even burn would have left you
/// 60 %" says stop.
///
/// Visible to the test target rather than private: what it draws is a pair of
/// positions on a track, and the only way to hold that honestly is to render it
/// and read the pixels back.
struct QuotaBar: View {
    let card: QuotaCardModel

    /// The share of the track that carries paint, measured from the left.
    ///
    /// The bar drains. It fills up as a window is *spent* if this is the used
    /// fraction, which puts it in plain contradiction with the "% free" figure
    /// printed directly above it — the number counting down while the bar counts
    /// up, and a window with nothing left drawn as a full bar. A gauge, not an
    /// odometer, and the same way the menu bar panel's rows have always read.
    var fillFraction: Double { card.headroomFraction }

    /// Where the marker sits on that same track, or `nil` for a window with no
    /// pace to draw.
    ///
    /// Mirrored, because the bar is. `pacePosition` is the elapsed share of the
    /// window — where an even burn would have *spent* you to by now — so on a
    /// draining bar it marks what such a burn would have *left*: four fifths
    /// through the window, a fifth. The reading inverts with it. The fill short
    /// of the marker now means burning faster than the window allows, where a
    /// filling bar meant that by running past it.
    var markerPosition: Double? { card.pacePosition.map { 1 - $0 } }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(card.state.tint)
                    .frame(width: geometry.size.width * fillFraction)

                if let marker = markerPosition {
                    Capsule()
                        .fill(.primary.opacity(0.65))
                        .frame(width: 2, height: 15)
                        .offset(x: geometry.size.width * marker - 1, y: -3)
                }
            }
        }
        .frame(height: 9)
    }
}

private extension QuotaCardState {
    var tint: Color {
        switch self {
        case .ok: .green
        case .warn: .orange
        case .spent: .red
        }
    }
}
