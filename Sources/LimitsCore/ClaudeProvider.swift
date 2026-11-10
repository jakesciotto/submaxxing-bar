import Foundation

public struct ClaudeProvider: UsageProvider {
    public let id = ProviderID.claude
    public init() {}

    struct Credentials {
        let accessToken: String
        let expiresAt: Date?
        let plan: String?
        let planSource: [String: String]
    }

    public func fetch() async throws -> FetchResult {
        let credentials = try await loadCredentials()
        if let expiry = credentials.expiresAt, expiry < Date() {
            throw FetchError.needsSignIn("Sign-in expired. Run claude.")
        }
        let data = try await HTTP.get(
            URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            headers: [
                "Authorization": "Bearer \(credentials.accessToken)",
                "anthropic-beta": "oauth-2025-04-20",
            ],
            rejected: { .needsSignIn("Sign-in rejected (\($0)). Run claude.") }
        )
        return try FetchResult.parse(data, context: credentials.planSource) {
            try ClaudeParser.parse($0, plan: credentials.plan, now: Date())
        }
    }

    func loadCredentials() async throws -> Credentials {
        var data: Data?
        let keychain = try await Shell.run(
            "/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        )
        if keychain.status == 0 {
            let text = String(decoding: keychain.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            data = Data(text.utf8)
        } else {
            let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/.credentials.json")
            data = try? Data(contentsOf: file)
        }
        guard let data else { throw FetchError.notConfigured }
        let root = try JSONValue.object(data)
        guard let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else {
            throw FetchError.needsSignIn("No sign-in. Run claude and log in.")
        }
        let type = oauth["subscriptionType"] as? String
        let tier = oauth["rateLimitTier"] as? String
        return Credentials(
            accessToken: token,
            expiresAt: JSONValue.date(oauth["expiresAt"]),
            plan: ClaudeParser.planLabel(type: type, tier: tier),
            planSource: ["subscriptionType": type ?? "null", "rateLimitTier": tier ?? "null"]
        )
    }
}

public enum ClaudeParser {
    static let windows: [(key: String, label: String)] = [
        ("five_hour", "Session"),
        ("seven_day", "Weekly"),
        ("seven_day_opus", "Opus weekly"),
        ("seven_day_sonnet", "Sonnet weekly"),
    ]

    public static func parse(_ data: Data, plan: String?, now: Date) throws -> UsageSnapshot {
        let root = try JSONValue.object(data)
        var meters: [Meter] = []
        for (key, label) in windows {
            if let meter = window(root[key], label: label) { meters.append(meter) }
        }
        if root["seven_day"] == nil || root["seven_day"] is NSNull,
           let apps = window(root["seven_day_oauth_apps"], label: "Weekly") {
            meters.append(apps)
        }
        meters.append(contentsOf: scopedWeekly(root["limits"], excluding: Set(meters.map(\.label))))
        if let extra = extraUsage(root["extra_usage"]) { meters.append(extra) }
        return UsageSnapshot(provider: .claude, plan: plan, meters: meters, fetchedAt: now)
    }

    static func scopedWeekly(_ value: Any?, excluding existing: Set<String>) -> [Meter] {
        (value as? [[String: Any]] ?? []).compactMap { limit in
            guard limit["kind"] as? String == "weekly_scoped",
                  let percent = JSONValue.number(limit["percent"]),
                  let scope = limit["scope"] as? [String: Any],
                  let name = (scope["model"] as? [String: Any])?["display_name"] as? String
            else { return nil }
            let label = "\(name) weekly"
            guard !existing.contains(label) else { return nil }
            return Meter(label: label, usedPercent: percent, resetsAt: JSONValue.date(limit["resets_at"]))
        }
    }

    static func extraUsage(_ value: Any?) -> Meter? {
        guard let extra = value as? [String: Any], extra["is_enabled"] as? Bool == true,
              let percent = JSONValue.number(extra["utilization"])
        else { return nil }
        var detail: String?
        if let used = JSONValue.number(extra["used_credits"]), let limit = JSONValue.number(extra["monthly_limit"]) {
            let scale = pow(10, JSONValue.number(extra["decimal_places"]) ?? 2)
            let currency = extra["currency"] as? String ?? "USD"
            detail = "\(JSONValue.money(used / scale, currency: currency)) / \(JSONValue.money(limit / scale, currency: currency))"
        }
        return Meter(label: "Extra usage", usedPercent: percent, detail: detail, kind: .spend)
    }

    static func window(_ value: Any?, label: String) -> Meter? {
        guard let window = value as? [String: Any], let used = JSONValue.number(window["utilization"]) else {
            return nil
        }
        return Meter(label: label, usedPercent: used, resetsAt: JSONValue.date(window["resets_at"]))
    }

    public static func planLabel(type: String?, tier: String?) -> String? {
        let type = (type ?? "").lowercased()
        let tier = (tier ?? "").lowercased()
        guard type.isEmpty || type == "max" else { return JSONValue.capitalized(type) }
        if tier.contains("20x") { return "Max 20x" }
        if tier.contains("5x") { return "Max 5x" }
        return type.isEmpty ? nil : "Max"
    }
}
