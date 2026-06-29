import Foundation
import Combine

/// Holds the registered providers and the latest snapshot for each. This is the single source of truth
/// the SwiftUI panel observes. Adding a new provider is a one-line change in `makeDefault()`.
@MainActor
final class ProviderRegistry: ObservableObject {
    @Published private(set) var snapshots: [ProviderSnapshot]
    @Published private(set) var isRefreshing = false
    let settings: ProviderSettingsStore

    private let providers: [any UsageProvider]
    private let providerByID: [String: any UsageProvider]
    private let providerInfoByID: [String: ProviderInfo]
    private var snapshotByID: [String: ProviderSnapshot]
    private var settingsCancellable: AnyCancellable?
    /// When the last refresh *completed* (success or failure). nil until the first one finishes.
    private(set) var lastRefreshAt: Date?
    /// Minimum spacing between *automatic* refreshes. Forced refreshes (launch, manual button) bypass it.
    private let minAutoInterval: TimeInterval = 25

    init(providers: [any UsageProvider]) {
        self.providers = providers
        self.providerByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.info.id, $0) })
        self.providerInfoByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.info.id, $0.info) })
        self.snapshotByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.info.id, ProviderSnapshot.loading($0.info)) })
        self.settings = ProviderSettingsStore(providerIDs: providers.map { $0.info.id })
        self.snapshots = []
        self.snapshots = visibleSnapshots()
        self.settingsCancellable = settings.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.snapshots = self?.visibleSnapshots() ?? []
                self?.objectWillChange.send()
            }
        }
    }

    var orderedProviderInfos: [ProviderInfo] {
        settings.providerPreferences.compactMap { providerInfoByID[$0.id] }
    }

    /// True when no refresh has completed yet, or the last one is older than the auto interval — used to
    /// decide whether opening the popover should trigger a fetch.
    func isStale() -> Bool {
        guard let last = lastRefreshAt else { return true }
        return Date().timeIntervalSince(last) >= minAutoInterval
    }

    /// Refresh every enabled provider concurrently and publish results in the configured order. Automatic callers
    /// (timer, popover-open) are throttled to `minAutoInterval`; pass `force: true` for user-initiated
    /// refreshes that must always fetch. Note this is distinct from each provider's own rate-limit
    /// cooldown — a forced refresh still won't hit a provider that knows it's being rate-limited.
    func refreshAll(force: Bool = false) async {
        if !force, let last = lastRefreshAt, Date().timeIntervalSince(last) < minAutoInterval {
            return
        }
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let enabledIDs = settings.enabledProviderIDs
        let results = await withTaskGroup(of: (String, ProviderSnapshot).self) { group in
            for id in enabledIDs {
                guard let provider = providerByID[id] else { continue }
                group.addTask { (id, await provider.refresh()) }
            }
            var collected: [(String, ProviderSnapshot)] = []
            for await result in group { collected.append(result) }
            return collected
        }

        for (id, snapshot) in results {
            snapshotByID[id] = snapshot
        }
        snapshots = visibleSnapshots()
        lastRefreshAt = Date()
    }

    private func visibleSnapshots() -> [ProviderSnapshot] {
        settings.enabledProviderIDs.compactMap { id in
            snapshotByID[id] ?? providerInfoByID[id].map(ProviderSnapshot.loading)
        }
    }

    /// The default set of providers shipped with the app. Start with Claude; append more here.
    static func makeDefault() -> ProviderRegistry {
        ProviderRegistry(providers: [
            ClaudeProvider(),
            CodexProvider(),
            CursorProvider(),
            ZAIProvider(),
            OpenRouterProvider(),
            GrokProvider(),
            DevinProvider(),
            CopilotProvider(),
            AntigravityProvider(),
        ])
    }
}
