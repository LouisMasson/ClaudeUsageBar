import SwiftUI

struct DashboardView: View {
    @ObservedObject var usageState: UsageState
    let onRefresh: () -> Void
    @State private var openRouterDays = 7

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Vue d’ensemble")
                            .font(.largeTitle.bold())
                        Text("Consommation IA et santé de l’infrastructure")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(action: onRefresh) {
                        Label("Actualiser", systemImage: "arrow.clockwise")
                    }
                    .disabled(usageState.isLoading)
                }

                aiSection
                openRouterActivitySection
                vpsSection
            }
            .padding(28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var openRouterActivitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Activité OpenRouter", systemImage: "waveform.path.ecg")
                    .font(.title2.bold())
                Spacer()
                Picker("Période", selection: $openRouterDays) {
                    Text("7 jours").tag(7)
                    Text("30 jours").tag(30)
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                Link(destination: URL(string: "https://openrouter.ai/activity")!) {
                    Label("Voir sur OpenRouter", systemImage: "arrow.up.right.square")
                }
            }

            if let snapshot = usageState.openRouterActivity {
                let summary = snapshot.summary(days: openRouterDays)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    OpenRouterMetricCard(
                        title: "Dépenses",
                        value: currency(summary.spend),
                        change: summary.spendChange,
                        symbol: "dollarsign.circle"
                    )
                    OpenRouterMetricCard(
                        title: "Requêtes",
                        value: compact(summary.requests),
                        change: summary.requestsChange,
                        symbol: "arrow.left.arrow.right"
                    )
                    OpenRouterMetricCard(
                        title: "Volume de tokens",
                        value: compact(summary.tokens),
                        change: summary.tokensChange,
                        symbol: "text.word.spacing"
                    )
                    OpenRouterMetricCard(
                        title: "Coût / 1M tokens",
                        value: currency(summary.blendedCostPerMillion),
                        change: nil,
                        symbol: "chart.line.uptrend.xyaxis"
                    )
                    OpenRouterMetricCard(
                        title: "Taux de cache",
                        value: summary.cacheHitRate.map { String(format: "%.1f%%", $0 * 100) } ?? "—",
                        change: nil,
                        symbol: "bolt.horizontal.circle"
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Dépenses quotidiennes").font(.headline)
                        Spacer()
                        Text("\(openRouterDays) derniers jours terminés (UTC)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    MiniSparkline(samples: summary.daily.map(\.spend))
                        .frame(height: 105)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                    OpenRouterRankingCard(title: "Modèles principaux", rows: Array(summary.topModels.prefix(5)))
                    OpenRouterRankingCard(title: "Apps principales", rows: Array(summary.topApps.prefix(5)))
                    if !summary.topKeys.isEmpty {
                        OpenRouterRankingCard(title: "Clés API principales", rows: Array(summary.topKeys.prefix(5)))
                    }
                }

                HStack(spacing: 16) {
                    Label("Raisonnement : \(compact(summary.reasoningTokens)) tokens", systemImage: "brain")
                    if summary.byokInference > 0 {
                        Label("BYOK : \(currency(summary.byokInference))", systemImage: "key")
                    }
                    Spacer()
                    Text("Actualisé \(snapshot.fetchedAt.formatted(date: .omitted, time: .shortened))")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            } else if usageState.isLoadingOpenRouterActivity {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Chargement de l’activité OpenRouter…")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(28)
            } else if let error = usageState.openRouterActivityError {
                VStack(spacing: 8) {
                    Image(systemName: "key.fill")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("Activité indisponible").font(.headline)
                    Text(error).font(.caption).foregroundColor(.secondary)
                    Link("Créer une clé de gestion OpenRouter", destination: URL(string: "https://openrouter.ai/settings/management-keys")!)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.04)))
            } else {
                Text("Ajoutez une clé OpenRouter dans les réglages pour charger l’activité.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            }
        }
    }

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Consommation IA", systemImage: "sparkles")
                .font(.title2.bold())
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                DashboardMetricCard(
                    title: "Claude · Session 5h",
                    value: "\(usageState.sessionUtilization)%",
                    detail: "Reset \(usageState.sessionResetTime)",
                    progress: Double(usageState.sessionUtilization)
                )
                DashboardMetricCard(
                    title: "Claude · Semaine",
                    value: "\(usageState.weeklyUtilization)%",
                    detail: "Reset \(usageState.weeklyResetTime)",
                    progress: Double(usageState.weeklyUtilization)
                )
                if usageState.usage?.sevenDaySonnet != nil {
                    DashboardMetricCard(
                        title: "Claude · Sonnet",
                        value: "\(usageState.sonnetUtilization)%",
                        detail: "Reset \(usageState.usage?.sevenDaySonnet?.timeUntilReset ?? "N/A")",
                        progress: Double(usageState.sonnetUtilization)
                    )
                }
                if usageState.usage?.sevenDayOmelette != nil {
                    DashboardMetricCard(
                        title: "Claude · Design",
                        value: "\(usageState.designUtilization)%",
                        detail: "Reset \(usageState.usage?.sevenDayOmelette?.timeUntilReset ?? "N/A")",
                        progress: Double(usageState.designUtilization)
                    )
                }
                if usageState.openRouterCredits != nil {
                    DashboardMetricCard(
                        title: "OpenRouter",
                        value: usageState.openRouterRemainingLabel,
                        detail: usageState.openRouterTotalLabel,
                        progress: Double(usageState.openRouterUtilization)
                    )
                }
                if usageState.clineUsage != nil {
                    DashboardMetricCard(
                        title: "Cline · Session 5h",
                        value: "\(usageState.clineFiveHourUtilization)%",
                        detail: "Reset \(usageState.clineFiveHourResetTime)",
                        progress: Double(usageState.clineFiveHourUtilization)
                    )
                    DashboardMetricCard(
                        title: "Cline · Semaine",
                        value: "\(usageState.clineWeeklyUtilization)%",
                        detail: "Reset \(usageState.clineWeeklyResetTime)",
                        progress: Double(usageState.clineWeeklyUtilization)
                    )
                    DashboardMetricCard(
                        title: "Cline · Mensuel",
                        value: "\(usageState.clineMonthlyUtilization)%",
                        detail: "Reset \(usageState.clineMonthlyResetTime)",
                        progress: Double(usageState.clineMonthlyUtilization)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var vpsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("VPS Contabo", systemImage: "server.rack")
                .font(.title2.bold())
            if let status = usageState.vpsStatus {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                    DashboardMetricCard(title: "CPU", value: percent(status.vps.cpuPercent), detail: status.vps.uptime, progress: status.vps.cpuPercent)
                    DashboardMetricCard(title: "RAM", value: percent(status.vps.ramPercent), detail: "Mémoire utilisée", progress: status.vps.ramPercent)
                    DashboardMetricCard(title: "SSD", value: percent(status.vps.diskPercent), detail: "Espace utilisé", progress: status.vps.diskPercent)
                    DashboardMetricCard(title: "Disponibilité", value: "\(status.sites.healthy)/\(status.sites.total)", detail: "Sites · \(status.services.healthy)/\(status.services.total) services", progress: status.sites.total == 0 ? 0 : Double(status.sites.healthy) / Double(status.sites.total) * 100)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("CPU — historique 7 jours")
                        .font(.headline)
                    MiniSparkline(samples: usageState.vpsHistory.map(\.cpu))
                        .frame(height: 110)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
                }

                HStack(alignment: .top, spacing: 16) {
                    AvailabilityList(title: "Sites", items: status.sites.items)
                    AvailabilityList(title: "Services", items: status.services.items)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("VPS non configuré").font(.headline)
                    Text(usageState.vpsError ?? "Ajoutez le token API dans les réglages.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(30)
            }
        }
    }

    private func percent(_ value: Double) -> String { "\(Int(value.rounded()))%" }

    private func currency(_ value: Double) -> String { String(format: "$%.2f", value) }

    private func compact(_ value: Int) -> String {
        switch value {
        case 1_000_000_000...: return String(format: "%.1fB", Double(value) / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...: return String(format: "%.1fK", Double(value) / 1_000)
        default: return "\(value)"
        }
    }
}

struct OpenRouterMetricCard: View {
    let title: String
    let value: String
    let change: Double?
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundColor(.secondary)
            Text(value).font(.system(size: 27, weight: .bold, design: .rounded))
            if let change {
                Label(
                    String(format: "%@%.1f%% vs période précédente", change >= 0 ? "+" : "", change),
                    systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right"
                )
                .font(.caption)
                .foregroundColor(change >= 0 ? UsagePalette.green : UsagePalette.red)
            } else {
                Text("Période sélectionnée").font(.caption).foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)))
    }
}

struct OpenRouterRankingCard: View {
    let title: String
    let rows: [OpenRouterActivityRank]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if rows.isEmpty {
                Text("Aucune activité sur cette période")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 9) {
                        Text("\(index + 1)")
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.secondary)
                            .frame(width: 14)
                        Text(row.name).lineLimit(1)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(String(format: "$%.2f", row.spend)).font(.callout.monospacedDigit())
                            Text("\(compact(row.tokens)) tok · \(row.requests) req.")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)))
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

struct DashboardMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.headline)
            Text(value).font(.system(size: 26, weight: .bold, design: .rounded))
            ProgressView(value: min(max(progress, 0), 100), total: 100)
                .tint(UsagePalette.color(for: Int(progress)))
            Text(detail).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)))
    }
}

struct AvailabilityList: View {
    let title: String
    let items: [VPSAvailabilityItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(items) { item in
                HStack {
                    Circle()
                        .fill(item.isHealthy ? UsagePalette.green : UsagePalette.red)
                        .frame(width: 7, height: 7)
                    Text(item.name).lineLimit(1)
                    Spacer()
                    Text(item.detail ?? item.status)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)))
    }
}
