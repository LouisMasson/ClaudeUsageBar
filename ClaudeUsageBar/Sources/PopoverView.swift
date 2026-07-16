import SwiftUI

struct PopoverView: View {
    @ObservedObject var usageState: UsageState
    let onRefresh: () -> Void
    let onSettings: () -> Void
    let onDashboard: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: "gauge")
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("AI Usage Monitor")
                        .font(.headline)
                    Text("IA, crédits et infrastructure")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if usageState.isOffline {
                    // Discrete offline badge — keeps the cached data visible rather
                    // than replacing everything with an error banner.
                    Text("Hors ligne")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                } else if usageState.isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if usageState.usage != nil
                        || usageState.codexUsage != nil
                        || usageState.clineUsage != nil
                        || usageState.openRouterCredits != nil
                        || usageState.cookieExpired
                        || usageState.codexError != nil
                        || usageState.error != nil {
                        UsageDetailsView(usageState: usageState, onSettings: onSettings)
                    } else {
                        Text("Chargement…")
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding()
                    }

                    if usageState.vpsStatus != nil || usageState.vpsError != nil {
                        Divider()
                        VPSCompactCard(usageState: usageState)
                    }
                }
            }
            .frame(maxHeight: 485)

            Divider()

            Button(action: onDashboard) {
                Label("Ouvrir le dashboard", systemImage: "arrow.up.right.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

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
        .frame(width: 380)
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

struct VPSCompactCard: View {
    @ObservedObject var usageState: UsageState

    var body: some View {
        if let status = usageState.vpsStatus {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    Circle()
                        .fill(status.isHealthy ? UsagePalette.green : UsagePalette.orange)
                        .frame(width: 9, height: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("VPS Contabo")
                            .font(.body.bold())
                        Text("CPU \(percent(status.vps.cpuPercent))   RAM \(percent(status.vps.ramPercent))   SSD \(percent(status.vps.diskPercent))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                        Text("\(status.sites.healthy)/\(status.sites.total) sites · \(status.services.healthy)/\(status.services.total) services")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        if let analytics = status.sites.items.first(where: { $0.name == "louismasson.me" })?.analytics {
                            Text("louismasson.me · \(analytics.thirtyDays.visitors) visiteurs / 30 j")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    MiniSparkline(samples: usageState.vpsHistory.suffix(24).map(\.cpu))
                        .frame(width: 84, height: 34)
                }
            }
        } else if let error = usageState.vpsError {
            Label(error, systemImage: "server.rack")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }
}

struct MiniSparkline: View {
    let samples: [Double]

    var body: some View {
        GeometryReader { geometry in
            Path { path in
                guard samples.count > 1 else { return }
                for (index, value) in samples.enumerated() {
                    let x = geometry.size.width * CGFloat(index) / CGFloat(samples.count - 1)
                    let y = geometry.size.height * (1 - CGFloat(min(max(value, 0), 100)) / 100)
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(UsagePalette.green, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}

struct UsageDetailsView: View {
    @ObservedObject var usageState: UsageState
    var onSettings: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let codex = usageState.codexUsage {
                ProviderHeader(title: "Codex", symbol: "terminal", detail: codex.rateLimits.planType?.capitalized)
                ForEach(codex.windows) { window in
                    UsageRow(
                        title: window.label,
                        utilization: window.usedPercent,
                        resetTime: window.resetLabel,
                        isPrimary: codex.windows.first?.id == window.id
                    )
                }
                HStack {
                    Text("Tokens cumulés")
                    Spacer()
                    Text(compact(codex.tokenUsage.summary.lifetimeTokens ?? 0))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            } else if let error = usageState.codexError {
                ProviderHeader(title: "Codex", symbol: "terminal")
                Text(error).font(.caption2).foregroundColor(.secondary)
            }

            if usageState.usage != nil || usageState.cookieExpired || usageState.error != nil {
                Divider()
                ProviderHeader(title: "Claude", symbol: "sparkles")
                if usageState.usage != nil || usageState.cookieExpired {
                    UsageRow(
                        title: "Session 5h",
                        utilization: usageState.sessionUtilization,
                        resetTime: usageState.sessionResetTime,
                        isPrimary: true,
                        projectedAtReset: usageState.sessionProjectedUtilization,
                        isNA: usageState.cookieExpired
                    )

                    UsageRow(
                        title: "Hebdomadaire",
                        utilization: usageState.weeklyUtilization,
                        resetTime: usageState.weeklyResetTime,
                        projectedAtReset: usageState.weeklyProjectedUtilization,
                        isNA: usageState.cookieExpired
                    )
                } else if let error = usageState.error {
                    Text(error).font(.caption2).foregroundColor(.secondary)
                }

                if usageState.cookieExpired {
                    Button(action: onSettings) {
                        HStack(spacing: 4) {
                            Image(systemName: "lock.rotation")
                                .font(.caption2)
                            Text("Session Claude expirée — mettre à jour")
                                .font(.caption2)
                        }
                        .foregroundColor(UsagePalette.orange)
                    }
                    .buttonStyle(.borderless)
                }
            }

            // OpenRouter — only rendered when a key is configured and at least
            // one fetch has completed (success or failure).
            if usageState.openRouterCredits != nil || usageState.openRouterError != nil {
                Divider()
                ProviderHeader(title: "OpenRouter", symbol: "network")

                if usageState.openRouterCredits != nil {
                    CreditsRow(
                        title: "Crédits",
                        remainingLabel: usageState.openRouterRemainingLabel
                    )
                } else if let error = usageState.openRouterError {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                }

                Link(destination: URL(string: "https://openrouter.ai/settings/credits")!) {
                    Label("Recharger des crédits", systemImage: "plus.circle")
                        .font(.caption)
                }
            }

            // Cline Pass — only rendered when a cookie is configured and at least
            // one fetch has completed (success or failure).
            if usageState.clineUsage != nil || usageState.clineError != nil {
                Divider()
                ProviderHeader(title: "Cline Pass", symbol: "chevron.left.forwardslash.chevron.right")

                if usageState.clineUsage != nil {
                    UsageRow(
                        title: "Session (5h)",
                        utilization: usageState.clineFiveHourUtilization,
                        resetTime: usageState.clineFiveHourResetTime,
                        projectedAtReset: usageState.clineFiveHourProjectedUtilization
                    )

                    UsageRow(
                        title: "Hebdomadaire",
                        utilization: usageState.clineWeeklyUtilization,
                        resetTime: usageState.clineWeeklyResetTime,
                        projectedAtReset: usageState.clineWeeklyProjectedUtilization
                    )

                } else if let error = usageState.clineError {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                }
            }
        }
    }

    private func compact(_ value: Int) -> String {
        switch value {
        case 1_000_000_000...: return String(format: "%.1fB", Double(value) / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...: return String(format: "%.1fK", Double(value) / 1_000)
        default: return "\(value)"
        }
    }
}

struct ProviderHeader: View {
    let title: String
    let symbol: String
    var detail: String? = nil

    var body: some View {
        HStack {
            Label(title, systemImage: symbol).font(.body.bold())
            Spacer()
            if let detail {
                Text(detail).font(.caption).foregroundColor(.secondary)
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
    /// When true (e.g. Claude cookie expired), the row shows "N/A" in muted gray
    /// and an empty bar instead of a value. The row stays visible so the layout
    /// doesn't jump and the user sees which buckets are affected.
    var isNA: Bool = false

    /// Color driven by projection when present (forward-looking), else current utilization.
    var barColor: Color {
        UsagePalette.color(for: projectedAtReset ?? utilization)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(isPrimary ? .body.bold() : .body)
                Spacer()
                if isNA {
                    Text("N/A")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                } else {
                    Text("\(utilization)%")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(barColor)
                }
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 6)

                    if !isNA {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(barColor)
                            .frame(width: geometry.size.width * CGFloat(utilization) / 100, height: 6)
                    }
                }
            }
            .frame(height: 6)

            HStack(spacing: 8) {
                Text("Reset: \(isNA ? "N/A" : resetTime)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if !isNA, let projected = projectedAtReset {
                    Spacer()
                    Text("→ \(projected)% au reset")
                        .font(.caption)
                        .foregroundColor(barColor)
                }
            }
        }
    }
}

/// Compact row for displaying a credit balance (remaining only) instead of a
/// percentage. Used by the OpenRouter section so it shows the actual dollar
/// amount left rather than a utilization bar.
struct CreditsRow: View {
    let title: String
    let remainingLabel: String

    // Muted green — `.green` is too bright against the popover background, so we
    // use the shared palette shade that reads as "positive balance" without
    // flashing.
    private let creditColor = UsagePalette.green

    var body: some View {
        HStack {
            Text(title)
                .font(.body)
            Spacer()
            Text(remainingLabel)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(creditColor)
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

/// Shown when the Claude session cookie has expired (401/403). Offers a direct
/// shortcut to Settings so the user can paste a fresh cookie without hunting for
/// the gear icon.
struct CookieExpiredView: View {
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.rotation")
                .foregroundColor(UsagePalette.orange)
                .font(.title2)

            Text("Session expirée")
                .font(.body.bold())

            Text("Votre cookie de session n'est plus valide. Ouvrez les réglages pour le mettre à jour.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Ouvrir les réglages", action: onSettings)
                .buttonStyle(.borderedProminent)
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
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            Text("Configuration")
                .font(.headline)

            Divider()

            Toggle(isOn: $settingsState.claudeOAuthEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Utiliser la connexion Claude Code")
                    Text("Une autorisation Keychain unique peut être demandée à la sauvegarde.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)

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
                Text("VPS Contabo")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("https://status.patronusguardian.org", text: $settingsState.vpsBaseURL)
                    .textFieldStyle(.roundedBorder)
                SecureField("Token API lecture seule", text: $settingsState.vpsAPIToken)
                    .textFieldStyle(.roundedBorder)
                Text("Le token reste dans le Keychain de l’app.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("OpenRouter API Key (optionnel)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("sk-or-v1-...", text: $settingsState.openRouterKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                SecureField("Clé de gestion (activité)", text: $settingsState.openRouterManagementKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                Text("La clé standard affiche les crédits. La clé de gestion, distincte et en lecture seule ici, charge l’activité.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Cline Pass (optionnel)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("cline_session_id=...", text: $settingsState.clineSessionCookie)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                Text("Collez le cookie `cline_session_id=...` depuis app.cline.bot. Laissez vide pour désactiver.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Icône de la barre des menus")
                    .font(.caption)
                    .foregroundColor(.secondary)
                MenuBarIconPicker(selection: $settingsState.menuBarIcon)
                Text("L’icône sera appliquée après la sauvegarde.")
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

            Toggle(isOn: $settingsState.alertsEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Alertes de seuil")
                    Text("macOS demandera l’autorisation uniquement lors de l’activation.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)

            Toggle(isOn: $settingsState.launchAtLoginEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ouvrir à la connexion")
                    Text("Utilise le service de connexion natif de macOS.")
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
        }
        .frame(width: 360, height: 600)
    }
}

private struct MenuBarIconPicker: View {
    @Binding var selection: MenuBarIcon

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 6)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(MenuBarIcon.allCases) { icon in
                Button {
                    selection = icon
                } label: {
                    Group {
                        if let symbolName = icon.systemSymbolName {
                            Image(systemName: symbolName)
                        } else {
                            Text("◐")
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .foregroundColor(selection == icon ? .accentColor : .primary)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selection == icon ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(selection == icon ? Color.accentColor : Color.clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .help(icon.label)
                .accessibilityLabel(icon.label)
                .accessibilityAddTraits(selection == icon ? .isSelected : [])
            }
        }
    }
}
