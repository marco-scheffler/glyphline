import SwiftUI

struct DataQualityBadge: View {
    let quality: DataQuality

    var body: some View {
        Text(quality.displayName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(quality.foregroundStyle)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minWidth: 84)
            .background(quality.backgroundStyle, in: Capsule())
    }
}

private extension DataQuality {
    var displayName: String {
        switch self {
        case .exact:
            "Exact"
        case .estimated:
            "Estimated"
        case .partial:
            "Partial"
        case .unavailable:
            "Unavailable"
        }
    }

    var foregroundStyle: Color {
        switch self {
        case .exact:
            .green
        case .estimated:
            .blue
        case .partial:
            .orange
        case .unavailable:
            .secondary
        }
    }

    var backgroundStyle: Color {
        switch self {
        case .exact:
            Color.green.opacity(0.16)
        case .estimated:
            Color.blue.opacity(0.16)
        case .partial:
            Color.orange.opacity(0.16)
        case .unavailable:
            Color.secondary.opacity(0.14)
        }
    }
}
