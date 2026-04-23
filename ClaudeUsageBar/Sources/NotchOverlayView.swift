import SwiftUI

/// Compact pill-shaped SwiftUI view rendered in the notch overlay panel.
struct NotchOverlayView: View {
    @ObservedObject var usageState: UsageState

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.circle.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(tintColor)

            VStack(alignment: .leading, spacing: 4) {
                Text("Claude Usage")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    HStack(spacing: 2) {
                        Text("\(usageState.sessionUtilization)%")
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundColor(.primary)
                        if let projected = usageState.sessionProjectedUtilization {
                            Text("→\(projected)%")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(tintColor)
                        }
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.12))
                            Capsule()
                                .fill(tintColor)
                                .frame(width: geo.size.width * CGFloat(min(max(usageState.sessionUtilization, 0), 100)) / 100)
                        }
                    }
                    .frame(height: 5)

                    Text(usageState.sessionResetTime)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 240, height: 58)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    /// Color driven by projection when available (forward-looking), otherwise by
    /// current utilization. Mirrors the menu bar and popover palette.
    private var tintColor: Color {
        let reference = usageState.sessionProjectedUtilization ?? usageState.sessionUtilization
        switch reference {
        case ..<60:  return .green
        case ..<85:  return .orange
        default:     return .red
        }
    }
}
