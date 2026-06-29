import AppKit
import Charts
import SwiftUI

/// Hosts the full analytics window — a standalone, resizable window with a sidebar, distinct from the
/// menu-bar popover. The AppDelegate flips the app to `.regular` while it's open (so it gets a Dock
/// icon and proper focus) and back to `.accessory` on close via `onClose`.
@MainActor
final class AnalyticsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    init(registry: ProviderRegistry) {
        let hosting = NSHostingController(rootView: AnalyticsView(registry: registry))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Usage Analytics"
        window.setContentSize(NSSize(width: 880, height: 580))
        window.setFrameAutosaveName("UsageAnalyticsWindow")
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

private enum AnalyticsSection: Hashable {
    case overview
    case provider(String)
}

struct AnalyticsView: View {
    @ObservedObject var registry: ProviderRegistry
    @State private var selection: AnalyticsSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Overview", systemImage: "chart.bar.xaxis")
                    .tag(AnalyticsSection.overview)

                Section("Providers") {
                    ForEach(registry.snapshots) { snapshot in
                        Label {
                            Text(snapshot.provider.displayName)
                        } icon: {
                            ProviderIcon(info: snapshot.provider, size: 16)
                        }
                        .tag(AnalyticsSection.provider(snapshot.provider.id))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 212, max: 280)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 500)
        .preferredColorScheme(registry.settings.theme.colorScheme)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .overview {
        case .overview:
            OverviewPane(registry: registry)
        case .provider(let id):
            if let snapshot = registry.snapshots.first(where: { $0.provider.id == id }) {
                ProviderDetailPane(snapshot: snapshot)
                    .id(id)
            } else {
                placeholder("Select a provider")
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Overview

private struct OverviewPane: View {
    @ObservedObject var registry: ProviderRegistry

    private var snapshots: [ProviderSnapshot] { registry.snapshots }

    private var totalCost: Double? {
        let samples = snapshots.compactMap { $0.spend?.last30Days?.costUSD }
        return samples.isEmpty ? nil : samples.reduce(0, +)
    }

    private var totalTokens: Int {
        snapshots.compactMap { $0.spend?.last30Days?.tokens }.reduce(0, +)
    }

    private var tokenBars: [ProviderBar] {
        snapshots.compactMap { snapshot in
            guard let tokens = snapshot.spend?.last30Days?.tokens, tokens > 0 else { return nil }
            return ProviderBar(name: snapshot.provider.displayName, tokens: tokens,
                               color: providerAccent(snapshot.provider))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Overview").font(.system(size: 26, weight: .bold))

                HStack(spacing: 12) {
                    StatTile(title: "30-day cost",
                             value: totalCost.map { UsageFormat.cost($0) } ?? "—",
                             systemImage: "dollarsign.circle.fill")
                    StatTile(title: "30-day tokens",
                             value: totalTokens > 0 ? UsageFormat.tokens(totalTokens) : "—",
                             systemImage: "number.circle.fill")
                    StatTile(title: "Providers",
                             value: "\(snapshots.count)",
                             systemImage: "square.grid.2x2.fill")
                }

                if !tokenBars.isEmpty {
                    AnalyticsCard("Tokens · last 30 days") {
                        Chart(tokenBars) { bar in
                            BarMark(
                                x: .value("Tokens", bar.tokens),
                                y: .value("Provider", bar.name)
                            )
                            .foregroundStyle(bar.color)
                            .annotation(position: .trailing, alignment: .leading) {
                                Text(UsageFormat.tokens(bar.tokens))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .chartXAxis {
                            AxisMarks { value in
                                AxisGridLine()
                                AxisValueLabel {
                                    if let tokens = value.as(Double.self) {
                                        Text(UsageFormat.tokens(Int(tokens)))
                                    }
                                }
                            }
                        }
                        .frame(height: CGFloat(tokenBars.count) * 40 + 24)
                    }
                }

                AnalyticsCard("Providers") {
                    VStack(spacing: 0) {
                        ForEach(Array(snapshots.enumerated()), id: \.element.id) { index, snapshot in
                            ProviderSummaryRow(snapshot: snapshot)
                            if index < snapshots.count - 1 {
                                Divider().opacity(0.4)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

private struct ProviderBar: Identifiable {
    let name: String
    let tokens: Int
    let color: Color
    var id: String { name }
}

private struct ProviderSummaryRow: View {
    let snapshot: ProviderSnapshot

    var body: some View {
        HStack(spacing: 10) {
            ProviderIcon(info: snapshot.provider, size: 18)
            Text(snapshot.provider.displayName)
                .font(.system(size: 14, weight: .medium))
            if let plan = snapshot.plan {
                Text(plan).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if let last30 = snapshot.spend?.last30Days {
                Text(UsageFormat.spend(last30))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else if let headline = headlineMetric {
                Text("\(headline.percentLeft)% left")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
    }

    private var headlineMetric: UsageMetric? {
        let labels = ["Weekly", "Session"]
        return labels.compactMap { label in
            snapshot.metrics.first { $0.label.localizedCaseInsensitiveContains(label) }
        }.first ?? snapshot.metrics.first
    }
}

// MARK: - Provider detail

private struct ProviderDetailPane: View {
    let snapshot: ProviderSnapshot

    private var accent: Color { providerAccent(snapshot.provider) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 12) {
                    ProviderIcon(info: snapshot.provider, size: 28)
                    Text(snapshot.provider.displayName).font(.system(size: 26, weight: .bold))
                    if let plan = snapshot.plan {
                        Text(plan).font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if !snapshot.metrics.isEmpty {
                    AnalyticsCard("Usage") {
                        VStack(spacing: 16) {
                            ForEach(snapshot.metrics) { metric in
                                AnalyticsMeterRow(metric: metric, accent: accent)
                            }
                        }
                    }
                } else if case .error(let message) = snapshot.state {
                    AnalyticsCard("Usage") {
                        Text(message).font(.system(size: 13)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let spend = snapshot.spend {
                    AnalyticsCard("Spend") {
                        VStack(alignment: .leading, spacing: 8) {
                            if let today = spend.today { spendRow("Today", today) }
                            if let last30 = spend.last30Days { spendRow("Last 30 days", last30) }
                            if spend.estimated {
                                Text("Estimated cost")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }

                    if !spend.daily.isEmpty {
                        AnalyticsCard("Tokens per day") {
                            Chart(spend.daily) { day in
                                BarMark(
                                    x: .value("Day", day.date, unit: .day),
                                    y: .value("Tokens", day.tokens)
                                )
                                .foregroundStyle(accent)
                            }
                            .chartYAxis {
                                AxisMarks { value in
                                    AxisGridLine()
                                    AxisValueLabel {
                                        if let tokens = value.as(Double.self) {
                                            Text(UsageFormat.tokens(Int(tokens)))
                                        }
                                    }
                                }
                            }
                            .frame(height: 180)
                        }

                        let costDays = spend.daily.filter { ($0.costUSD ?? 0) > 0 }
                        if !costDays.isEmpty {
                            AnalyticsCard("Cost per day") {
                                Chart(costDays) { day in
                                    BarMark(
                                        x: .value("Day", day.date, unit: .day),
                                        y: .value("Cost", day.costUSD ?? 0)
                                    )
                                    .foregroundStyle(accent.opacity(0.7))
                                }
                                .chartYAxis {
                                    AxisMarks { value in
                                        AxisGridLine()
                                        AxisValueLabel {
                                            if let cost = value.as(Double.self) {
                                                Text(UsageFormat.cost(cost))
                                            }
                                        }
                                    }
                                }
                                .frame(height: 180)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private func spendRow(_ label: String, _ period: SpendSummary.Period) -> some View {
        HStack(spacing: 6) {
            Text("\(label):").foregroundStyle(.secondary)
            Text(UsageFormat.spend(period))
            Spacer()
        }
        .font(.system(size: 14))
    }
}

private struct AnalyticsMeterRow: View {
    let metric: UsageMetric
    let accent: Color

    private var remaining: Double { metric.remainingFraction }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(metric.label).font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(UsageFormat.value(metric, format: .remaining))
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(barColor)
                        .frame(width: max(geo.size.width * remaining, remaining > 0 ? 4 : 0))
                }
            }
            .frame(height: 8)
            if let resets = UsageFormat.resets(at: metric.resetsAt, format: .relative) {
                Text(resets).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var barColor: Color {
        if remaining <= 0.1 { return .red }
        if remaining <= 0.25 { return .yellow }
        return accent
    }
}

// MARK: - Shared components

private struct StatTile: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .bold)).lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct AnalyticsCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }
}

private func providerAccent(_ info: ProviderInfo) -> Color {
    info.accentHex.flatMap(Color.init(analyticsHex:)) ?? .accentColor
}

extension Color {
    fileprivate init?(analyticsHex hex: String) {
        var raw = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("#") { raw.removeFirst() }
        guard raw.count == 6, let value = Int(raw, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}
