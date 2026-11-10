import Foundation

public struct ModelShare: Sendable, Equatable, Identifiable {
    public var id: String { model }
    public let model: String
    public let session: Double
    public let weekly: Double

    public init(model: String, session: Double, weekly: Double) {
        self.model = model
        self.session = session
        self.weekly = weekly
    }
}

public struct Breakdown: Sendable, Equatable {
    public let rows: [ModelShare]
    public let computedAt: Date

    public init(rows: [ModelShare], computedAt: Date) {
        self.rows = rows
        self.computedAt = computedAt
    }
}

public enum ModelBreakdown {
    public static let sessionWindow: TimeInterval = 5 * 3600
    public static let weeklyWindow: TimeInterval = 7 * 86_400

    struct Record: Sendable {
        let time: Date
        let model: String
        let weight: Double
        let key: String?
    }

    static func parseClaude(_ data: Data) -> [Record] {
        lines(data, containingAll: ["\"usage\"", "\"assistant\""]).compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  object["type"] as? String == "assistant",
                  let message = object["message"] as? [String: Any],
                  let model = message["model"] as? String, !model.hasPrefix("<"),
                  let usage = message["usage"] as? [String: Any],
                  let time = (object["timestamp"] as? String).flatMap(JSONValue.iso8601)
            else { return nil }
            let weight = ["input_tokens", "cache_creation_input_tokens", "output_tokens"]
                .reduce(0) { $0 + (JSONValue.number(usage[$1]) ?? 0) }
            guard weight > 0 else { return nil }
            let key = "\(message["id"] as? String ?? "")|\(object["requestId"] as? String ?? "")"
            return Record(time: time, model: model, weight: weight, key: key)
        }
    }

    static func parseCodex(_ data: Data) -> [Record] {
        var model: String?
        var records: [Record] = []
        for line in lines(data, containingAny: ["\"turn_context\"", "\"token_count\""]) {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = object["payload"] as? [String: Any]
            else { continue }
            if object["type"] as? String == "turn_context" {
                model = payload["model"] as? String
                continue
            }
            guard payload["type"] as? String == "token_count",
                  let model,
                  let last = (payload["info"] as? [String: Any])?["last_token_usage"] as? [String: Any],
                  let time = (object["timestamp"] as? String).flatMap(JSONValue.iso8601)
            else { continue }
            let input = JSONValue.number(last["input_tokens"]) ?? 0
            let cached = JSONValue.number(last["cached_input_tokens"]) ?? 0
            let weight = max(0, input - cached) + (JSONValue.number(last["output_tokens"]) ?? 0)
            if weight > 0 { records.append(Record(time: time, model: model, weight: weight, key: nil)) }
        }
        return records
    }

    static func aggregate(_ records: [Record], now: Date) -> [ModelShare] {
        var seen = Set<String>()
        var session: [String: Double] = [:]
        var weekly: [String: Double] = [:]
        for record in records {
            if let key = record.key, !seen.insert(key).inserted { continue }
            let age = now.timeIntervalSince(record.time)
            guard age >= 0, age <= weeklyWindow else { continue }
            let name = displayName(record.model)
            weekly[name, default: 0] += record.weight
            if age <= sessionWindow { session[name, default: 0] += record.weight }
        }
        let sessionTotal = session.values.reduce(0, +)
        let weeklyTotal = weekly.values.reduce(0, +)
        guard weeklyTotal > 0 else { return [] }
        return weekly
            .map { name, weight in
                ModelShare(
                    model: name,
                    session: sessionTotal > 0 ? (session[name] ?? 0) / sessionTotal : 0,
                    weekly: weight / weeklyTotal
                )
            }
            .filter { $0.weekly >= 0.005 || $0.session >= 0.005 }
            .sorted { ($0.weekly, $0.model) > ($1.weekly, $1.model) }
    }

    public static func displayName(_ model: String) -> String {
        var name = model.replacingOccurrences(of: #"\[.*\]$"#, with: "", options: .regularExpression)
        guard name.hasPrefix("claude-") else { return name }
        name = String(name.dropFirst(7)).replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
        let parts = name.split(separator: "-").map(String.init)
        guard let family = parts.first?.capitalized else { return name }
        let version = parts.dropFirst().filter { Int($0) != nil }
        return version.isEmpty ? family : "\(family) \(version.joined(separator: "."))"
    }

    private static func lines(_ data: Data, containingAll needles: [String]) -> [Data] {
        let patterns = needles.map { Data($0.utf8) }
        return data.split(separator: UInt8(ascii: "\n")).filter { line in
            patterns.allSatisfy { line.range(of: $0) != nil }
        }
    }

    private static func lines(_ data: Data, containingAny needles: [String]) -> [Data] {
        let patterns = needles.map { Data($0.utf8) }
        return data.split(separator: UInt8(ascii: "\n")).filter { line in
            patterns.contains { line.range(of: $0) != nil }
        }
    }
}

public actor BreakdownIndex {
    private struct Entry {
        let modified: Date
        let size: Int
        let records: [ModelBreakdown.Record]
    }

    private let provider: ProviderID
    private var cache: [String: Entry] = [:]

    public init(provider: ProviderID) {
        self.provider = provider
    }

    public func compute(now: Date = Date()) -> Breakdown {
        let cutoff = now.addingTimeInterval(-ModelBreakdown.weeklyWindow)
        var records: [ModelBreakdown.Record] = []
        var live = Set<String>()
        for (url, modified, size) in recentFiles(since: cutoff) {
            live.insert(url.path)
            if let entry = cache[url.path], entry.modified == modified, entry.size == size {
                records += entry.records
                continue
            }
            guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { continue }
            let parsed = provider == .claude ? ModelBreakdown.parseClaude(data) : ModelBreakdown.parseCodex(data)
            cache[url.path] = Entry(modified: modified, size: size, records: parsed)
            records += parsed
        }
        cache = cache.filter { live.contains($0.key) }
        return Breakdown(rows: ModelBreakdown.aggregate(records, now: now), computedAt: now)
    }

    private func recentFiles(since cutoff: Date) -> [(URL, Date, Int)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root: URL = switch provider {
        case .claude: home.appending(path: ".claude/projects")
        case .codex: ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }?.appending(path: "sessions")
            ?? home.appending(path: ".codex/sessions")
        case .cursor: home
        }
        guard provider != .cursor else { return [] }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var files: [(URL, Date, Int)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified >= cutoff
            else { continue }
            files.append((url, modified, values.fileSize ?? 0))
        }
        return files
    }
}
