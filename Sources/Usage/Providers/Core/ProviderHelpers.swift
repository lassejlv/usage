import Foundation

enum ProviderHelpers {
    static func expandedPath(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    static func readText(_ path: String) -> String? {
        try? String(contentsOfFile: expandedPath(path), encoding: .utf8)
    }

    static func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: expandedPath(path))
    }

    static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return jsonObject(data)
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let double as Double: double
        case let int as Int: Double(int)
        case let number as NSNumber: number.doubleValue
        case let string as String: Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default: nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        }
        return nil
    }

    static func apiKey(configPaths: [String], environmentNames: [String]) -> String? {
        for path in configPaths {
            guard let text = readText(path), let key = keyFromConfigText(text) else { continue }
            return key
        }
        for name in environmentNames {
            guard let value = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty
            else {
                continue
            }
            return value
        }
        return nil
    }

    static func keyFromConfigText(_ text: String) -> String? {
        if let object = jsonObject(text) {
            for field in ["apiKey", "api_key", "key"] {
                if let value = (object[field] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !value.isEmpty {
                    return value
                }
            }
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.contains("{") ? nil : trimmed
    }

    static func tomlString(_ text: String, key: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == key
            else {
                continue
            }
            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            if let quote = value.first, quote == "\"" || quote == "'" {
                var output = ""
                var previous: Character?
                for character in value.dropFirst() {
                    if character == quote, previous != "\\" {
                        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? nil : trimmed
                    }
                    output.append(character)
                    previous = character
                }
                return nil
            }
            if let comment = value.firstIndex(of: "#") {
                value = value[..<comment].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return value.isEmpty ? nil : String(value)
        }
        return nil
    }

    static func sqliteValue(path: String, sql: String) -> String? {
        let expandedPath = expandedPath(path)
        guard FileManager.default.fileExists(atPath: expandedPath) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sqlite3", expandedPath, sql]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    static func jwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return jsonObject(data)
    }

    static func isoDate(_ value: Any?) -> Date? {
        if let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) { return date }
            let internet = ISO8601DateFormatter()
            internet.formatOptions = [.withInternetDateTime]
            if let date = internet.date(from: string) { return date }
            let dayOnly = DateFormatter()
            dayOnly.calendar = Calendar(identifier: .gregorian)
            dayOnly.locale = Locale(identifier: "en_US_POSIX")
            dayOnly.timeZone = TimeZone(secondsFromGMT: 0)
            dayOnly.dateFormat = "yyyy-MM-dd"
            if let date = dayOnly.date(from: string) { return date }
        }
        guard let raw = number(value), raw.isFinite else { return nil }
        return Date(timeIntervalSince1970: raw < 1e11 ? raw : raw / 1000)
    }

    static func title(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
            .split { $0 == "_" || $0 == "-" || $0.isWhitespace }
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    static func clampPercent(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}
