import Foundation

enum UsageValueFormat: String, CaseIterable, Identifiable, Codable {
    case remaining
    case used
    case usedAndLimit

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .remaining: "Remaining"
        case .used: "Used"
        case .usedAndLimit: "Used / Limit"
        }
    }
}

enum ResetTimeFormat: String, CaseIterable, Identifiable, Codable {
    case relative
    case time
    case dateTime
    case hidden

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .relative: "Relative"
        case .time: "Time"
        case .dateTime: "Date & Time"
        case .hidden: "Hidden"
        }
    }
}

enum RefreshIntervalPreset: String, CaseIterable, Identifiable, Codable {
    case twoMinutes
    case fiveMinutes
    case fifteenMinutes
    case thirtyMinutes
    case custom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .twoMinutes: "2 min"
        case .fiveMinutes: "5 min"
        case .fifteenMinutes: "15 min"
        case .thirtyMinutes: "30 min"
        case .custom: "Custom"
        }
    }

    var minutes: Int? {
        switch self {
        case .twoMinutes: 2
        case .fiveMinutes: 5
        case .fifteenMinutes: 15
        case .thirtyMinutes: 30
        case .custom: nil
        }
    }
}

enum AppIconStyle: String, CaseIterable, Identifiable, Codable {
    case bars
    case gauge
    case percent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bars: "Bars"
        case .gauge: "Gauge"
        case .percent: "Percent"
        }
    }

    var systemImageName: String {
        switch self {
        case .bars: "chart.bar.fill"
        case .gauge: "gauge.with.dots.needle.67percent"
        case .percent: "percent"
        }
    }
}

enum AppTheme: String, CaseIterable, Identifiable, Codable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

enum AppDensity: String, CaseIterable, Identifiable, Codable {
    case compact
    case `default`
    case spacious

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .compact: "Compact"
        case .default: "Default"
        case .spacious: "Spacious"
        }
    }
}

enum TimeDisplayFormat: String, CaseIterable, Identifiable, Codable {
    case system
    case twelveHour
    case twentyFourHour

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System"
        case .twelveHour: "12-hour"
        case .twentyFourHour: "24-hour"
        }
    }
}

struct ProviderPreference: Identifiable, Codable, Hashable {
    let id: String
    var isEnabled: Bool
}

@MainActor
final class ProviderSettingsStore: ObservableObject {
    @Published var providerPreferences: [ProviderPreference] {
        didSet { saveProviderPreferences() }
    }
    @Published var valueFormat: UsageValueFormat {
        didSet { saveValueFormat() }
    }
    @Published var resetTimeFormat: ResetTimeFormat {
        didSet { saveResetTimeFormat() }
    }
    @Published var refreshIntervalPreset: RefreshIntervalPreset {
        didSet { saveRefreshIntervalPreset() }
    }
    @Published var customRefreshMinutes: Int {
        didSet {
            customRefreshMinutes = Self.clampedRefreshMinutes(customRefreshMinutes)
            saveCustomRefreshMinutes()
        }
    }
    @Published var launchAtLogin: Bool {
        didSet { saveLaunchAtLogin() }
    }
    @Published var iconStyle: AppIconStyle {
        didSet { saveIconStyle() }
    }
    @Published var theme: AppTheme {
        didSet { saveTheme() }
    }
    @Published var density: AppDensity {
        didSet { saveDensity() }
    }
    @Published var timeDisplayFormat: TimeDisplayFormat {
        didSet { saveTimeDisplayFormat() }
    }
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: notificationsEnabledKey) }
    }
    @Published var notifyAlmostOut: Bool {
        didSet { defaults.set(notifyAlmostOut, forKey: notifyAlmostOutKey) }
    }
    @Published var notifyCuttingClose: Bool {
        didSet { defaults.set(notifyCuttingClose, forKey: notifyCuttingCloseKey) }
    }
    @Published var notifyWillRunOut: Bool {
        didSet { defaults.set(notifyWillRunOut, forKey: notifyWillRunOutKey) }
    }

    private let defaults: UserDefaults
    private let providerPreferenceKey = "providerPreferences.v2"
    private let valueFormatKey = "usageValueFormat.v1"
    private let resetTimeFormatKey = "resetTimeFormat.v1"
    private let refreshIntervalPresetKey = "refreshIntervalPreset.v1"
    private let customRefreshMinutesKey = "customRefreshMinutes.v1"
    private let launchAtLoginKey = "launchAtLogin.v1"
    private let iconStyleKey = "iconStyle.v1"
    private let themeKey = "theme.v1"
    private let densityKey = "density.v1"
    private let timeDisplayFormatKey = "timeDisplayFormat.v1"
    private let notificationsEnabledKey = "notificationsEnabled.v1"
    private let notifyAlmostOutKey = "notifyAlmostOut.v1"
    private let notifyCuttingCloseKey = "notifyCuttingClose.v1"
    private let notifyWillRunOutKey = "notifyWillRunOut.v1"

    init(providerIDs: [String], defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let stored =
            defaults.data(forKey: providerPreferenceKey)
            .flatMap { try? JSONDecoder().decode([ProviderPreference].self, from: $0) } ?? []
        var storedByID = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
        let storedIDs = stored.map(\.id).filter { providerIDs.contains($0) }
        let newIDs = providerIDs.filter { !storedIDs.contains($0) }
        self.providerPreferences = (storedIDs + newIDs).map { id in
            storedByID.removeValue(forKey: id) ?? ProviderPreference(id: id, isEnabled: false)
        }

        if let raw = defaults.string(forKey: valueFormatKey),
            let format = UsageValueFormat(rawValue: raw)
        {
            self.valueFormat = format
        } else {
            self.valueFormat = .remaining
        }

        if let raw = defaults.string(forKey: resetTimeFormatKey),
            let format = ResetTimeFormat(rawValue: raw)
        {
            self.resetTimeFormat = format
        } else {
            self.resetTimeFormat = .relative
        }

        if let raw = defaults.string(forKey: refreshIntervalPresetKey),
            let preset = RefreshIntervalPreset(rawValue: raw)
        {
            self.refreshIntervalPreset = preset
        } else {
            self.refreshIntervalPreset = .fiveMinutes
        }
        let customMinutes = defaults.integer(forKey: customRefreshMinutesKey)
        self.customRefreshMinutes = Self.clampedRefreshMinutes(
            customMinutes == 0 ? 10 : customMinutes)
        self.launchAtLogin = defaults.bool(forKey: launchAtLoginKey)

        if let raw = defaults.string(forKey: iconStyleKey),
            let iconStyle = AppIconStyle(rawValue: raw)
        {
            self.iconStyle = iconStyle
        } else {
            self.iconStyle = .bars
        }

        if let raw = defaults.string(forKey: themeKey),
            let theme = AppTheme(rawValue: raw)
        {
            self.theme = theme
        } else {
            self.theme = .system
        }

        if let raw = defaults.string(forKey: densityKey),
            let density = AppDensity(rawValue: raw)
        {
            self.density = density
        } else {
            self.density = .default
        }

        if let raw = defaults.string(forKey: timeDisplayFormatKey),
            let timeDisplayFormat = TimeDisplayFormat(rawValue: raw)
        {
            self.timeDisplayFormat = timeDisplayFormat
        } else {
            self.timeDisplayFormat = .twentyFourHour
        }

        // Notifications: master is opt-in (off by default); the per-milestone toggles default on so
        // enabling the master immediately alerts on all three milestones.
        self.notificationsEnabled = defaults.bool(forKey: notificationsEnabledKey)
        self.notifyAlmostOut = defaults.object(forKey: notifyAlmostOutKey) as? Bool ?? true
        self.notifyCuttingClose = defaults.object(forKey: notifyCuttingCloseKey) as? Bool ?? true
        self.notifyWillRunOut = defaults.object(forKey: notifyWillRunOutKey) as? Bool ?? true
    }

    func isEnabled(_ id: String) -> Bool {
        providerPreferences.first { $0.id == id }?.isEnabled ?? false
    }

    func setEnabled(_ id: String, _ isEnabled: Bool) {
        guard let index = providerPreferences.firstIndex(where: { $0.id == id }) else { return }
        providerPreferences[index].isEnabled = isEnabled
    }

    func moveProvider(_ id: String, by offset: Int) {
        guard let from = providerPreferences.firstIndex(where: { $0.id == id }) else { return }
        let to = max(0, min(providerPreferences.count - 1, from + offset))
        guard from != to else { return }
        let item = providerPreferences.remove(at: from)
        providerPreferences.insert(item, at: to)
    }

    var enabledProviderIDs: [String] {
        providerPreferences.filter(\.isEnabled).map(\.id)
    }

    var refreshIntervalSeconds: TimeInterval {
        TimeInterval((refreshIntervalPreset.minutes ?? customRefreshMinutes) * 60)
    }

    private func saveProviderPreferences() {
        guard let data = try? JSONEncoder().encode(providerPreferences) else { return }
        defaults.set(data, forKey: providerPreferenceKey)
    }

    private func saveValueFormat() {
        defaults.set(valueFormat.rawValue, forKey: valueFormatKey)
    }

    private func saveResetTimeFormat() {
        defaults.set(resetTimeFormat.rawValue, forKey: resetTimeFormatKey)
    }

    private func saveRefreshIntervalPreset() {
        defaults.set(refreshIntervalPreset.rawValue, forKey: refreshIntervalPresetKey)
    }

    private func saveCustomRefreshMinutes() {
        defaults.set(customRefreshMinutes, forKey: customRefreshMinutesKey)
    }

    private func saveLaunchAtLogin() {
        defaults.set(launchAtLogin, forKey: launchAtLoginKey)
    }

    private func saveIconStyle() {
        defaults.set(iconStyle.rawValue, forKey: iconStyleKey)
    }

    private func saveTheme() {
        defaults.set(theme.rawValue, forKey: themeKey)
    }

    private func saveDensity() {
        defaults.set(density.rawValue, forKey: densityKey)
    }

    private func saveTimeDisplayFormat() {
        defaults.set(timeDisplayFormat.rawValue, forKey: timeDisplayFormatKey)
    }

    private static func clampedRefreshMinutes(_ value: Int) -> Int {
        min(max(value, 1), 24 * 60)
    }
}
