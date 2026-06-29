import Foundation

/// Display formatting shared by the usage rows.
enum UsageFormat {
    /// "Resets in 2d 11h" / "Resets at 13:42" / hidden, based on user settings.
    static func resets(
        at date: Date?,
        format: ResetTimeFormat,
        timeDisplayFormat: TimeDisplayFormat = .system,
        now: Date = Date()
    ) -> String? {
        guard let date else { return nil }
        guard format != .hidden else { return nil }
        if format == .time {
            return "Resets at " + timeFormatter(for: timeDisplayFormat).string(from: date)
        }
        if format == .dateTime {
            return "Resets " + dateTimeFormatter(for: timeDisplayFormat).string(from: date)
        }

        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "Resetting" }

        let totalMinutes = Int(seconds / 60)
        let days = totalMinutes / (60 * 24)
        let hours = (totalMinutes % (60 * 24)) / 60
        let minutes = totalMinutes % 60

        let parts: [String]
        if days > 0 {
            parts = ["\(days)d", "\(hours)h"]
        } else if hours > 0 {
            parts = ["\(hours)h", "\(minutes)m"]
        } else {
            parts = ["\(max(minutes, 1))m"]
        }
        return "Resets in " + parts.joined(separator: " ")
    }

    /// The left-hand status, e.g. "35% left" or "$5.00 left".
    static func value(_ metric: UsageMetric, format: UsageValueFormat) -> String {
        switch metric.kind {
        case .percent:
            switch format {
            case .remaining:
                return "\(metric.percentLeft)% left"
            case .used:
                return "\(Int(metric.fraction * 100 + 0.5))% used"
            case .usedAndLimit:
                return "\(Int(metric.fraction * 100 + 0.5))% / 100%"
            }
        case .dollars:
            switch format {
            case .remaining:
                let remaining = max(metric.limit - metric.used, 0)
                return "\(dollars(remaining)) left"
            case .used:
                return "\(dollars(metric.used)) used"
            case .usedAndLimit:
                return "\(dollars(metric.used)) / \(dollars(metric.limit))"
            }
        case .credits:
            let available = Int(metric.used.rounded(.down))
            switch format {
            case .remaining, .used:
                return "\(available) credits available"
            case .usedAndLimit:
                return "\(available) credits"
            }
        case .count(let suffix):
            let used = Int(metric.used.rounded(.down))
            let limit = Int(metric.limit.rounded(.down))
            let remaining = max(limit - used, 0)
            switch format {
            case .remaining:
                return "\(remaining) \(suffix) left"
            case .used:
                return "\(used) \(suffix) used"
            case .usedAndLimit:
                return "\(used) / \(limit) \(suffix)"
            }
        }
    }

    static func dollars(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    private static func timeFormatter(for timeDisplayFormat: TimeDisplayFormat) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        apply(timeDisplayFormat, to: formatter, includesDate: false)
        return formatter
    }

    private static func dateTimeFormatter(for timeDisplayFormat: TimeDisplayFormat) -> DateFormatter
    {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        apply(timeDisplayFormat, to: formatter, includesDate: true)
        return formatter
    }

    private static func apply(
        _ timeDisplayFormat: TimeDisplayFormat, to formatter: DateFormatter, includesDate: Bool
    ) {
        switch timeDisplayFormat {
        case .system:
            return
        case .twelveHour:
            formatter.setLocalizedDateFormatFromTemplate(includesDate ? "yMd hmma" : "hmma")
        case .twentyFourHour:
            formatter.setLocalizedDateFormatFromTemplate(includesDate ? "yMd HHmm" : "HHmm")
        }
    }
}
