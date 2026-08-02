import SwiftUI

/// A model's colour, beside its name. The same colour the chart draws it in —
/// that is the whole point of the swatch: it is what lets a reader carry a hue
/// from a bar down to the row that names it.
struct ModelSwatch: View {
    let identifier: String?

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            // A nil identifier is the same unknown the label calls "Unknown
            // model", and gets the same grey.
            .fill(DashboardPresentation.modelColor(identifier ?? ""))
            .frame(width: 8, height: 8)
    }
}

// MARK: - Small parts

struct AgentCountBox: View {
    let count: Int
    let label: String
    let isHot: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(count)")
                .font(.system(size: 23, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(isHot ? Color.orange : Color.primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
        .padding(.horizontal, 11)
        .background(
            isHot
                ? AnyShapeStyle(Color.orange.opacity(0.16))
                : AnyShapeStyle(.quaternary.opacity(0.4)),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
    }
}

struct SectionTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .kerning(0.8)
            .foregroundStyle(.secondary)
    }
}

struct CardTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .kerning(0.7)
            .foregroundStyle(.secondary)
    }
}

struct ScanningRow: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Scanning local transcripts…")
                .foregroundStyle(.secondary)
        }
    }
}

/// An empty state that reads as a sentence rather than as an empty box. Every one
/// of them says what is missing, because a blank panel only ever says "broken".
struct EmptyStateBox: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(16)
            .glassCard()
    }
}

extension View {
    /// Liquid Glass itself, not an approximation of it. A material plus a
    /// drawn separator stroke is flat: it blurs but does not refract, it does
    /// not react to the window moving, and its edge is a line we chose rather
    /// than the one the system lights. `glassEffect` brings all three, and it
    /// draws its own border — hence no `strokeBorder` here any more.
    ///
    /// This is why the deployment target is macOS 26: the effect has no
    /// back-deployment and the layered-gradient stand-in it replaces looked
    /// wrong next to the system chrome that now uses the real thing.
    /// The tint is what keeps the cards dark.
    ///
    /// Untinted `.regular` glass lightens whatever it samples by a fixed
    /// amount, so on a near-black background the cards came out milky and
    /// floated well above the surface — the reference has them barely
    /// separated from it, which is what lets the chart's colours carry the
    /// screen. Tinting with the background's own colour puts that lightening
    /// back down without replacing the effect: the refraction, the edge
    /// lighting and the reaction to the window moving all survive.
    func glassCard(cornerRadius: CGFloat = 15) -> some View {
        glassEffect(
            .regular.tint(DashboardBackground.cardTint),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }
}
