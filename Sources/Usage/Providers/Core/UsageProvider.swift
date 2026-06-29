import Foundation

/// The runtime contract every provider implements. Conformers are reference types (actors/classes) so
/// they can carry their own auth + caching state across refreshes; `info` is read without isolation so
/// the registry and UI can show the card before the first fetch completes.
protocol UsageProvider: Sendable {
    nonisolated var info: ProviderInfo { get }

    /// Fetch the latest usage. Never throws — failures come back as `ProviderSnapshot.error` so one
    /// broken provider can't take down the whole refresh.
    func refresh() async -> ProviderSnapshot
}
