import Foundation

/// Static description of a provider — identity and how to render it. Kept separate from live data
/// so the UI can show a provider's card (name, icon) before any usage has been fetched.
struct ProviderInfo: Identifiable, Hashable, Sendable {
    /// Stable machine id, also the icon asset name (e.g. "claude" -> claude.svg).
    let id: String
    let displayName: String
    /// SF Symbol used as a fallback when no bundled icon asset matches `id`.
    let fallbackSymbol: String

    init(id: String, displayName: String, fallbackSymbol: String = "circle.dashed") {
        self.id = id
        self.displayName = displayName
        self.fallbackSymbol = fallbackSymbol
    }

    var accentHex: String? {
        switch id {
        case "claude": "#C18064"
        case "codex": "#61A1AE"
        case "cursor": "#55BCA6"
        case "openrouter": "#6467F2"
        case "antigravity": "#60BA7E"
        case "copilot": "#A855F7"
        case "grok": "#FFFFFF"
        default: nil
        }
    }
}

/// A single usage row within a provider — e.g. "Session 35% left, resets in 2d 11h".
struct UsageMetric: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case percent
        case dollars
        case credits
        case count(String)
    }

    let id = UUID()
    let label: String
    let used: Double
    let limit: Double
    let kind: Kind
    let resetsAt: Date?
    /// Length of the reset window (e.g. 5h session, 7d weekly). With `resetsAt`, lets `Pace` project
    /// the burn rate to the end of the window for the "Know Before You Run Out" line. nil → no pace.
    let windowDuration: TimeInterval?

    init(
        label: String, used: Double, limit: Double, kind: Kind = .percent,
        resetsAt: Date? = nil, windowDuration: TimeInterval? = nil
    ) {
        self.label = label
        self.used = used
        self.limit = limit
        self.kind = kind
        self.resetsAt = resetsAt
        self.windowDuration = windowDuration
    }

    /// Fraction filled, clamped to 0...1, for the progress bar.
    var fraction: Double {
        guard limit > 0 else { return 0 }
        return min(max(used / limit, 0), 1)
    }

    /// Fraction *remaining*, clamped to 0...1 — what the progress bars (cards and tab mini-bars)
    /// actually fill to. For most kinds that's `1 - fraction`; credits already track remaining
    /// headroom directly, so their fraction is already "remaining".
    var remainingFraction: Double {
        switch kind {
        case .percent, .dollars, .count:
            return 1 - fraction
        case .credits:
            return fraction
        }
    }

    var percentLeft: Int {
        Int((1 - fraction) * 100 + 0.5)
    }
}

extension Notification.Name {
    /// Posted by a provider when its background spend fetch yields a new value. The userInfo carries
    /// the provider id and the `SpendSummary`, so the registry can patch that snapshot in place
    /// (surfacing the Cost block promptly) without re-fetching every provider.
    static let providerSpendDidUpdate = Notification.Name("providerSpendDidUpdate")
}

enum SpendUpdate {
    static let idKey = "providerID"
    static let spendKey = "spend"
}

/// Token + dollar usage over a period, sourced from local CLI logs via `ccusage`. Rendered as the
/// "Cost" block on a provider card — not a progress bar, since there's no fixed limit to fill.
struct SpendSummary: Sendable, Hashable {
    struct Period: Sendable, Hashable {
        /// Estimated dollars for the period; nil when the source priced no day (tokens-only).
        var costUSD: Double?
        var tokens: Int
    }

    /// Today's usage, or nil when the source has nothing for today.
    var today: Period?
    /// Sum across the trailing 30 days, or nil when the whole window is idle.
    var last30Days: Period?
    /// True when dollars are a local estimate at API rates (the ccusage path), driving an "est." hint.
    var estimated: Bool
}

/// The result of refreshing one provider: either live metrics or an error, plus metadata.
struct ProviderSnapshot: Identifiable, Sendable {
    enum State: Sendable {
        case loading
        case ok
        case error(String)
    }

    let provider: ProviderInfo
    var plan: String?
    var metrics: [UsageMetric]
    var refreshedAt: Date?
    var state: State
    /// A soft, secondary message shown alongside content — never an error.
    /// e.g. "Live usage rate limited - retry in ~5m". nil when nothing to note.
    var note: String? = nil
    /// True when `metrics` are last-good values that may be out of date (e.g. a
    /// rate-limited refresh). The UI tints the note to signal "data may be old".
    var stale: Bool = false
    /// Token + dollar spend (today / last 30 days) for providers that expose it; nil otherwise.
    var spend: SpendSummary? = nil

    var id: String { provider.id }

    /// Returns a copy carrying `spend`. Spend comes from local logs / the usage export — independent of
    /// the live-quota API — so it's kept even when the live snapshot errored (a transient API blip
    /// shouldn't hide real cost). Skipped only while `.loading`, when there's nothing else to show yet.
    func attaching(spend: SpendSummary?) -> ProviderSnapshot {
        guard let spend else { return self }
        if case .loading = state { return self }
        var copy = self
        copy.spend = spend
        return copy
    }

    static func loading(_ provider: ProviderInfo) -> ProviderSnapshot {
        ProviderSnapshot(provider: provider, plan: nil, metrics: [], refreshedAt: nil, state: .loading)
    }

    static func ok(
        _ provider: ProviderInfo,
        plan: String?,
        metrics: [UsageMetric],
        at date: Date,
        note: String? = nil,
        stale: Bool = false
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider, plan: plan, metrics: metrics, refreshedAt: date,
            state: .ok, note: note, stale: stale
        )
    }

    static func error(_ provider: ProviderInfo, _ message: String) -> ProviderSnapshot {
        ProviderSnapshot(provider: provider, plan: nil, metrics: [], refreshedAt: nil, state: .error(message))
    }

    /// Refresh was rate-limited and there is no prior data to show. Renders as a calm
    /// status badge (state stays `.ok` so it avoids the scary error path), not an error.
    static func rateLimited(_ provider: ProviderInfo, plan: String?, note: String, at date: Date) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider, plan: plan, metrics: [], refreshedAt: date,
            state: .ok, note: note, stale: true
        )
    }
}
