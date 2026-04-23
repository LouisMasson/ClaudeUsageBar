import SwiftUI

struct PopoverView: View {
    @ObservedObject var usageState: UsageState
    let onRefresh: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "sparkles")
                    .foregroundColor(.purple)
                Text("Claude Usage")
                    .font(.headline)
                Spacer()
                if usageState.isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }

            Divider()

            if let error = usageState.error {
                ErrorView(message: error, onRetry: onRefresh)
            } else if usageState.usage != nil {
                UsageDetailsView(usageState: usageState)
            } else {
                Text("Chargement...")
                    .foregroundColor(.secondary)
            }

            Divider()

            // Footer
            HStack {
                if let lastUpdated = usageState.lastUpdated {
                    Text("MAJ: \(timeAgo(lastUpdated))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(usageState.isLoading)

                Button(action: onSettings) {
                    Image(systemName: "gear")
                }
                .buttonStyle(.borderless)

                Button(action: onQuit) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding()
        .frame(width: 280)
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 {
            return "a l'instant"
        } else if interval < 3600 {
            return "il y a \(Int(interval / 60)) min"
        } else {
            return "il y a \(Int(interval / 3600))h"
        }
    }
}

struct UsageDetailsView: View {
    @ObservedObject var usageState: UsageState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Session actuelle (5h)
            UsageRow(
                title: "Session (5h)",
                utilization: usageState.sessionUtilization,
                resetTime: usageState.sessionResetTime,
                isPrimary: true,
                projectedAtReset: usageState.sessionProjectedUtilization
            )

            // Limites hebdomadaires
            Text("HEBDOMADAIRE")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 4)

            UsageRow(
                title: "Tous modeles",
                utilization: usageState.weeklyUtilization,
                resetTime: usageState.weeklyResetTime
            )

            UsageRow(
                title: "Sonnet",
                utilization: usageState.sonnetUtilization,
                resetTime: usageState.usage?.sevenDaySonnet?.timeUntilReset ?? "N/A"
            )

            UsageRow(
                title: "Claude Design",
                utilization: usageState.designUtilization,
                resetTime: usageState.usage?.sevenDayOmelette?.timeUntilReset ?? "N/A"
            )

            // OpenRouter — only rendered when a key is configured and at least
            // one fetch has completed (success or failure).
            if usageState.openRouterCredits != nil || usageState.openRouterError != nil {
                Text("OPENROUTER")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)

                if let credits = usageState.openRouterCredits {
                    UsageRow(
                        title: "Crédits",
                        utilization: credits.utilization,
                        resetTime: usageState.openRouterRemainingLabel
                    )
                } else if let error = usageState.openRouterError {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                }
            }
        }
    }
}

struct UsageRow: View {
    let title: String
    let utilization: Int
    let resetTime: String
    var isPrimary: Bool = false
    /// Projected utilization (%) at reset time. Only the session row uses this;
    /// weekly buckets move too slowly for a useful short-term forecast.
    var projectedAtReset: Int? = nil

    /// Color driven by projection when present (forward-looking), else current utilization.
    var barColor: Color {
        let reference = projectedAtReset ?? utilization
        switch reference {
        case ..<60:  return .green
        case ..<85:  return .orange
        default:     return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(isPrimary ? .body.bold() : .body)
                Spacer()
                Text("\(utilization)%")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(barColor)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 6)

                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor)
                        .frame(width: geometry.size.width * CGFloat(utilization) / 100, height: 6)
                }
            }
            .frame(height: 6)

            HStack(spacing: 8) {
                Text("Reset: \(resetTime)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let projected = projectedAtReset {
                    Spacer()
                    Text("→ \(projected)% au reset")
                        .font(.caption)
                        .foregroundColor(barColor)
                }
            }
        }
    }
}

struct ErrorView: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.orange)
                .font(.title2)

            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Reessayer", action: onRetry)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

struct SettingsViewWrapper: View {
    @ObservedObject var settingsState: SettingsState
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configuration")
                .font(.headline)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Organization ID")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("8b711afd-6fda-...", text: $settingsState.orgId)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Session Cookie")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("sessionKey=sk-ant-...", text: $settingsState.cookie)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
            }

            Text("Copiez: sessionKey=sk-ant-sid01-...")
                .font(.caption2)
                .foregroundColor(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("OpenRouter API Key (optionnel)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("sk-or-v1-...", text: $settingsState.openRouterKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                Text("Laissez vide pour désactiver l'affichage OpenRouter.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Divider()

            Toggle(isOn: $settingsState.notchOverlayEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Overlay sous l'encoche")
                        .font(.body)
                    Text("Affiche l'usage au survol du haut de l'écran (Mac notch).")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)

            HStack {
                Spacer()
                Button("Annuler", action: onCancel)
                    .buttonStyle(.bordered)
                Button("Sauvegarder", action: onSave)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 320)
    }
}
