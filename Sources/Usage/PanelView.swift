import SwiftUI

struct PanelView: View {
    @ObservedObject var registry: ProviderRegistry
    @ObservedObject var settings: ProviderSettingsStore
    @State private var layout: PanelLayout = .usage

    init(registry: ProviderRegistry) {
        self.registry = registry
        self.settings = registry.settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.4)

            Group {
                switch layout {
                case .usage:
                    usageView
                case .settings:
                    SettingsView(registry: registry)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().opacity(0.4)
            footer
        }
        .frame(width: 360, height: 460)
        .preferredColorScheme(settings.theme.colorScheme)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(layout == .usage ? "Usage" : "Settings")
                .font(.system(size: 15, weight: .bold))
            Spacer()
            if registry.isRefreshing {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .layoutPriority(1)
    }

    private var usageView: some View {
        Group {
            if registry.snapshots.isEmpty {
                EmptyProvidersView {
                    layout = .settings
                }
            } else {
                ScrollView {
                    VStack(spacing: settings.density.cardSpacing) {
                        ForEach(registry.snapshots) { snapshot in
                            ProviderCard(
                                snapshot: snapshot,
                                valueFormat: settings.valueFormat,
                                resetTimeFormat: settings.resetTimeFormat,
                                timeDisplayFormat: settings.timeDisplayFormat,
                                density: settings.density
                            )
                        }
                    }
                    .padding(settings.density.contentPadding)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Usage 0.1.0")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button {
                    Task { await registry.refreshAll(force: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                Divider()

                Button {
                    layout = layout == .usage ? .settings : .usage
                } label: {
                    Label(
                        layout == .usage ? "Settings" : "Usage",
                        systemImage: layout == .usage
                            ? "gearshape" : "gauge.with.dots.needle.67percent")
                }

                Divider()

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power")
                }
            } label: {
                Label(layout == .usage ? "Refresh" : "Settings", systemImage: "ellipsis.circle")
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .layoutPriority(1)
    }
}

private enum PanelLayout {
    case usage
    case settings
}

private struct EmptyProvidersView: View {
    let openSettings: () -> Void
    @State private var layoutIndex = 0
    private let timer = Timer.publish(every: 2.5, on: .main, in: .common).autoconnect()

    private let icons = [
        ProviderInfo(id: "claude", displayName: "Claude", fallbackSymbol: "sparkles"),
        ProviderInfo(id: "codex", displayName: "Codex", fallbackSymbol: "terminal"),
        ProviderInfo(id: "cursor", displayName: "Cursor", fallbackSymbol: "cursorarrow"),
        ProviderInfo(
            id: "copilot", displayName: "Copilot",
            fallbackSymbol: "chevron.left.forwardslash.chevron.right"),
        ProviderInfo(id: "grok", displayName: "Grok", fallbackSymbol: "xmark"),
        ProviderInfo(id: "antigravity", displayName: "Antigravity", fallbackSymbol: "atom"),
    ]

    private let layouts: [[CGPoint]] = [
        [
            CGPoint(x: -68, y: -48), CGPoint(x: 68, y: -46), CGPoint(x: -76, y: 28),
            CGPoint(x: 78, y: 34), CGPoint(x: -28, y: 78), CGPoint(x: 34, y: 78),
        ],
        [
            CGPoint(x: 66, y: -52), CGPoint(x: -74, y: 22), CGPoint(x: 34, y: 78),
            CGPoint(x: -30, y: -78), CGPoint(x: 82, y: 24), CGPoint(x: -40, y: 76),
        ],
        [
            CGPoint(x: -82, y: -10), CGPoint(x: -30, y: -78), CGPoint(x: 76, y: -34),
            CGPoint(x: -56, y: 62), CGPoint(x: 34, y: 78), CGPoint(x: 84, y: 26),
        ],
    ]

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.16))
                .frame(width: 220, height: 220)
                .blur(radius: 52)
                .offset(x: 70, y: -70)

            Circle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 160, height: 160)
                .blur(radius: 44)
                .offset(x: -90, y: 90)

            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: 104, height: 104)

                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white)

                    ForEach(Array(icons.enumerated()), id: \.element.id) { index, info in
                        let point = layouts[layoutIndex % layouts.count][index]
                        floatingIcon(info, x: point.x, y: point.y)
                    }
                }
                .frame(height: 190)

                VStack(spacing: 7) {
                    Text("Pick your meters")
                        .font(.system(size: 18, weight: .bold))
                        .lineLimit(1)
                    Text("Enable the providers you want to track.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button(action: openSettings) {
                    Label("Open Settings", systemImage: "gearshape")
                }
                .controlSize(.regular)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .onReceive(timer) { _ in
            withAnimation(.spring(response: 0.7, dampingFraction: 0.78)) {
                layoutIndex = (layoutIndex + 1) % layouts.count
            }
        }
    }

    private func floatingIcon(_ info: ProviderInfo, x: CGFloat, y: CGFloat) -> some View {
        ProviderIcon(info: info, size: 17)
            .frame(width: 32, height: 32)
            .background(Color.primary.opacity(0.08), in: Circle())
            .offset(x: x, y: y)
    }
}

private struct SettingsView: View {
    @ObservedObject var registry: ProviderRegistry
    @ObservedObject var settings: ProviderSettingsStore

    init(registry: ProviderRegistry) {
        self.registry = registry
        self.settings = registry.settings
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                appearanceSection
                formatSection
                refreshSection
                systemSection
                providerSection
            }
            .padding(16)
        }
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Appearance")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            Picker("Icon Style", selection: $settings.iconStyle) {
                ForEach(AppIconStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.menu)

            Picker("Theme", selection: $settings.theme) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.displayName).tag(theme)
                }
            }
            .pickerStyle(.menu)

            Picker("Density", selection: $settings.density) {
                ForEach(AppDensity.allCases) { density in
                    Text(density.displayName).tag(density)
                }
            }
            .pickerStyle(.menu)

            Picker("Time Format", selection: $settings.timeDisplayFormat) {
                ForEach(TimeDisplayFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.menu)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private var formatSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Format")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            Picker("Usage value", selection: $settings.valueFormat) {
                ForEach(UsageValueFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.menu)

            Picker("Reset time", selection: $settings.resetTimeFormat) {
                ForEach(ResetTimeFormat.allCases) { format in
                    Text(format.displayName).tag(format)
                }
            }
            .pickerStyle(.menu)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private var refreshSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Refresh")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            Picker("Interval", selection: $settings.refreshIntervalPreset) {
                ForEach(RefreshIntervalPreset.allCases) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .pickerStyle(.menu)

            if settings.refreshIntervalPreset == .custom {
                HStack {
                    Text("Minutes")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    TextField("Minutes", value: $settings.customRefreshMinutes, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("System")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            Toggle("Launch at login", isOn: $settings.launchAtLogin)
                .toggleStyle(.switch)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Providers")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(Array(registry.orderedProviderInfos.enumerated()), id: \.element.id) {
                    index, info in
                    ProviderSettingsRow(
                        info: info,
                        isEnabled: Binding(
                            get: { registry.settings.isEnabled(info.id) },
                            set: { settings.setEnabled(info.id, $0) }
                        ),
                        moveUp: { settings.moveProvider(info.id, by: -1) },
                        moveDown: { settings.moveProvider(info.id, by: 1) },
                        canMoveUp: index > 0,
                        canMoveDown: index < registry.orderedProviderInfos.count - 1
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ProviderSettingsRow: View {
    let info: ProviderInfo
    @Binding var isEnabled: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void
    let canMoveUp: Bool
    let canMoveDown: Bool

    var body: some View {
        HStack(spacing: 8) {
            ProviderIcon(info: info, size: 16)
            Text(info.displayName)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            Button(action: moveUp) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .disabled(!canMoveUp)
            Button(action: moveDown) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)
            .disabled(!canMoveDown)
            Toggle("", isOn: $isEnabled)
                .labelsHidden()
        }
        .frame(minHeight: 28)
    }
}

/// One provider's card: header (icon + name + plan), then its usage rows or a status line.
private struct ProviderCard: View {
    let snapshot: ProviderSnapshot
    let valueFormat: UsageValueFormat
    let resetTimeFormat: ResetTimeFormat
    let timeDisplayFormat: TimeDisplayFormat
    let density: AppDensity

    var body: some View {
        VStack(alignment: .leading, spacing: density.cardInnerSpacing) {
            HStack(spacing: 8) {
                ProviderIcon(info: snapshot.provider, size: 18)
                Text(snapshot.provider.displayName)
                    .font(.system(size: 15, weight: .bold))
                if let plan = snapshot.plan {
                    Text(plan)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            content

            // Staleness note below the metrics (only when there ARE metrics — the no-data case shows the
            // message as a badge inside `content`, so it isn't repeated here).
            if let note = snapshot.note, !snapshot.metrics.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 10))
                    Text(note).font(.system(size: 11))
                }
                .foregroundStyle(snapshot.stale ? Color.yellow.opacity(0.9) : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(density.cardPadding)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var content: some View {
        switch snapshot.state {
        case .loading:
            statusRow("Loading…")
        case .error(let message):
            statusRow(message)
        case .ok:
            if !snapshot.metrics.isEmpty {
                ForEach(snapshot.metrics) {
                    MetricRow(
                        metric: $0,
                        valueFormat: valueFormat,
                        resetTimeFormat: resetTimeFormat,
                        timeDisplayFormat: timeDisplayFormat,
                        density: density,
                        accentHex: snapshot.provider.accentHex
                    )
                }
            } else if let note = snapshot.note {
                // Rate-limited with no prior data: a calm badge, not a scary error.
                statusBadge(note, systemImage: "clock.badge.exclamationmark")
            } else {
                statusRow("No data")
            }
        }
    }

    private func statusRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusBadge(_ text: String, systemImage: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).font(.system(size: 11, weight: .semibold))
            Text(text).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A labeled progress bar with "X% left" and "Resets in …".
private struct MetricRow: View {
    let metric: UsageMetric
    let valueFormat: UsageValueFormat
    let resetTimeFormat: ResetTimeFormat
    let timeDisplayFormat: TimeDisplayFormat
    let density: AppDensity
    let accentHex: String?

    var body: some View {
        VStack(alignment: .leading, spacing: density.metricSpacing) {
            Text(metric.label)
                .font(.system(size: 14, weight: .semibold))

            ProgressBar(
                fraction: remainingFraction, color: barColor, height: density.progressBarHeight)

            HStack {
                Text(UsageFormat.value(metric, format: valueFormat))
                    .font(.system(size: 13))
                Spacer()
                if let resets = UsageFormat.resets(
                    at: metric.resetsAt,
                    format: resetTimeFormat,
                    timeDisplayFormat: timeDisplayFormat
                ) {
                    Text(resets)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Green/yellow/red by how much is left, mirroring the screenshot's color cues.
    private var barColor: Color {
        let left = remainingFraction
        if left <= 0.1 { return .red }
        if left <= 0.25 { return .yellow }
        return accentHex.flatMap(Color.init(hex:)) ?? .accentColor
    }

    private var remainingFraction: Double {
        switch metric.kind {
        case .percent, .dollars, .count:
            return 1 - metric.fraction
        case .credits:
            return metric.fraction
        }
    }
}

extension Color {
    fileprivate init?(hex: String) {
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

private struct ProgressBar: View {
    let fraction: Double
    let color: Color
    let height: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(color)
                    .frame(width: max(geo.size.width * fraction, fraction > 0 ? 4 : 0))
            }
        }
        .frame(height: height)
    }
}
