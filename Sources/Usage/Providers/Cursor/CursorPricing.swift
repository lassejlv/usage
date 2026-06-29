import Foundation

/// Token counts for a single Cursor usage event (one CSV row).
struct CursorTokenUsage: Sendable, Equatable {
    let inputCacheWrite: Int
    let inputNoCacheWrite: Int
    let cacheRead: Int
    let output: Int

    /// All buckets summed — the measured token total shown alongside the cost.
    var total: Int { inputCacheWrite + inputNoCacheWrite + cacheRead + output }
}

/// One parsed, priced row from Cursor's CSV usage export.
struct CursorUsageRow: Sendable {
    var date: Date
    var model: String
    var tokens: CursorTokenUsage
    /// Locally imputed dollars (CSV tokens × bundled model pricing); 0 for unknown models.
    var costDollars: Double
}

// MARK: - Manifest decoding

/// Bundled model-pricing manifest (`model_manifest.json`) used to impute Cursor spend from the usage
/// CSV, since the export carries token counts but no cost. Only the fields the imputation uses are
/// decoded; the rest of the manifest is ignored.
struct CursorModelManifest: Decodable, Sendable {
    let pricing: [String: PricingEntry]
    let aliasRules: [AliasRule]

    enum CodingKeys: String, CodingKey {
        case pricing
        case aliasRules = "alias_rules"
    }

    struct PricingEntry: Decodable, Sendable {
        let inputPerMillion: Double
        let cacheWritePerMillion: Double
        let cacheReadPerMillion: Double
        let outputPerMillion: Double

        enum CodingKeys: String, CodingKey {
            case inputPerMillion = "input_per_million"
            case cacheWritePerMillion = "cache_write_per_million"
            case cacheReadPerMillion = "cache_read_per_million"
            case outputPerMillion = "output_per_million"
        }
    }

    struct AliasRule: Decodable, Sendable {
        let pattern: String
        let canonical: String
    }

    static let empty = CursorModelManifest(pricing: [:], aliasRules: [])
}

// MARK: - Pricing

enum CursorPricing {
    private static let manifest: CursorModelManifest = {
        guard let url = Bundle.module.url(forResource: "model_manifest", withExtension: "json")
            ?? Bundle.module.url(forResource: "model_manifest", withExtension: "json", subdirectory: "Resources"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(CursorModelManifest.self, from: data)
        else {
            return .empty
        }
        return manifest
    }()

    /// Regex → canonical model name. First match wins; compiled once.
    private struct CompiledAlias: @unchecked Sendable {
        let regex: NSRegularExpression
        let canonical: String
    }

    private static let aliasRules: [CompiledAlias] = manifest.aliasRules.compactMap { rule in
        (try? NSRegularExpression(pattern: rule.pattern)).map { CompiledAlias(regex: $0, canonical: rule.canonical) }
    }

    private static func pricingEntry(for model: String) -> CursorModelManifest.PricingEntry? {
        let range = NSRange(model.startIndex..<model.endIndex, in: model)
        guard let canonical = aliasRules.first(where: { $0.regex.firstMatch(in: model, range: range) != nil })?.canonical
        else {
            return nil
        }
        return manifest.pricing[canonical]
    }

    /// Estimate the USD cost for one CSV row at the base model API rate. Cursor's CSV rows are
    /// aggregates, so long-context thresholds and Max Mode uplift can't be applied reliably — we bill
    /// at base rates. Returns 0 for unknown/unpriced models.
    static func estimatedCostDollars(model: String, tokens: CursorTokenUsage) -> Double {
        guard let entry = pricingEntry(for: model) else { return 0 }
        return Double(tokens.inputCacheWrite) / 1_000_000 * entry.cacheWritePerMillion
            + Double(tokens.inputNoCacheWrite) / 1_000_000 * entry.inputPerMillion
            + Double(tokens.cacheRead) / 1_000_000 * entry.cacheReadPerMillion
            + Double(tokens.output) / 1_000_000 * entry.outputPerMillion
    }
}

// MARK: - CSV → rows

enum CursorUsageCSV {
    private nonisolated(unsafe) static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private nonisolated(unsafe) static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let plainDateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Maps Cursor's exported CSV text into priced rows. Rows with an unparseable date are skipped.
    static func parse(csv: String) -> [CursorUsageRow] {
        var rows: [CursorUsageRow] = []
        CursorCSVParser.forEachRecord(in: csv) { r in
            guard let dateStr = r["Date"]?.trimmingCharacters(in: .whitespaces), !dateStr.isEmpty,
                  let date = parseDate(dateStr)
            else {
                return
            }
            let model = (r["Model"] ?? "").trimmingCharacters(in: .whitespaces)
            let tokens = CursorTokenUsage(
                inputCacheWrite: parseInt(r["Input (w/ Cache Write)"]),
                inputNoCacheWrite: parseInt(r["Input (w/o Cache Write)"]),
                cacheRead: parseInt(r["Cache Read"]),
                output: parseInt(r["Output Tokens"])
            )
            rows.append(CursorUsageRow(
                date: date,
                model: model,
                tokens: tokens,
                costDollars: CursorPricing.estimatedCostDollars(model: model, tokens: tokens)
            ))
        }
        return rows
    }

    private static func parseDate(_ raw: String) -> Date? {
        isoFractional.date(from: raw) ?? iso.date(from: raw) ?? plainDateTime.date(from: raw)
    }

    private static func parseInt(_ raw: String?) -> Int {
        let normalized = (raw ?? "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        return normalized.isEmpty ? 0 : (Int(normalized) ?? 0)
    }
}
