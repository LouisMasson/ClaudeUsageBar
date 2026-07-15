import SwiftUI

struct DashboardView: View {
    @ObservedObject var usageState: UsageState
    let onRefresh: () -> Void

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
                vpsSection
            }
            .padding(28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
