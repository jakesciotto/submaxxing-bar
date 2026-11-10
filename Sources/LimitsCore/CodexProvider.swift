import Foundation

public struct CodexProvider: UsageProvider {
    public let id = ProviderID.codex
    public init() {}

    public func fetch() async throws -> FetchResult {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
        guard let raw = try? Data(contentsOf: home.appending(path: "auth.json")) else {
            throw FetchError.notConfigured
        }
        let auth = try JSONValue.object(raw)
        guard let tokens = auth["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty
        else {
            throw FetchError.needsSignIn("No sign-in. Sign in to Codex in ChatGPT.")
        }
        if let expiry = JWT.expiry(access), expiry < Date() {
            throw FetchError.needsSignIn("Sign-in expired. Open Codex in ChatGPT.")
        }
        var headers = ["Authorization": "Bearer \(access)"]
        if let account = tokens["account_id"] as? String { headers["ChatGPT-Account-Id"] = account }
        let data = try await HTTP.get(
            URL(string: "https://chatgpt.com/backend-api/wham/usage")!,
            headers: headers,
            rejected: { .needsSignIn("Sign-in rejected (\($0)). Open Codex in ChatGPT.") }
        )
        let idClaims = JWT.claims(tokens["id_token"] as? String ?? "")
        let planFallback = (idClaims["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_plan_type"] as? String
        return try FetchResult.parse(data) { try CodexParser.parse($0, planFallback: planFallback, now: Date()) }
    }
}

public enum CodexParser {
    public static func parse(_ data: Data, planFallback: String?, now: Date) throws -> UsageSnapshot {
        let root = try JSONValue.object(data)
        let limits = root["rate_limit"] as? [String: Any] ?? [:]
        var meters: [Meter] = []
        for key in ["primary_window", "secondary_window"] {
            guard let window = limits[key] as? [String: Any], let used = JSONValue.number(window["used_percent"]) else {
                continue
            }
            var reset = JSONValue.date(window["reset_at"])
            if reset == nil, let after = JSONValue.number(window["reset_after_seconds"]) {
                reset = now.addingTimeInterval(after)
            }
            meters.append(Meter(label: label(seconds: JSONValue.number(window["limit_window_seconds"])), usedPercent: used, resetsAt: reset))
        }
        if let credits = workspaceCredits(root["spend_control"]) { meters.append(credits) }
        let plan = JSONValue.capitalized(root["plan_type"] as? String ?? planFallback)
        return UsageSnapshot(provider: .codex, plan: plan, meters: meters, fetchedAt: now)
    }

    static func workspaceCredits(_ value: Any?) -> Meter? {
        guard let control = value as? [String: Any],
              let individual = control["individual_limit"] as? [String: Any],
              let used = JSONValue.number(individual["used"]),
              let limit = JSONValue.number(individual["limit"]), limit > 0
        else { return nil }
        return Meter(
            label: "Credits",
            usedPercent: used / limit * 100,
            resetsAt: JSONValue.date(individual["reset_at"]),
            detail: "\(JSONValue.count(used)) / \(JSONValue.count(limit))",
            kind: .spend
        )
    }

    static func label(seconds: Double?) -> String {
        guard let seconds, seconds > 0 else { return "Window" }
        switch Int(seconds) {
        case 18_000: return "Session"
        case 604_800: return "Weekly"
        case 2_592_000: return "Monthly"
        default:
            let hours = Int(seconds / 3600)
            return hours < 48 ? "\(hours)h" : "\(hours / 24)d"
        }
    }
}
