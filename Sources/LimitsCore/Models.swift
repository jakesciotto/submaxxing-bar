import Foundation

public enum ProviderID: String, CaseIterable, Sendable, Codable, Identifiable {
    case claude, codex, cursor

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .cursor: "Cursor"
        }
    }
}

public struct Meter: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable {
        case quota, spend
    }

    public var id: String { label }
    public let label: String
    public let usedPercent: Double
    public let resetsAt: Date?
    public let detail: String?
    public let kind: Kind

    public init(label: String, usedPercent: Double, resetsAt: Date? = nil, detail: String? = nil, kind: Kind = .quota) {
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.detail = detail
        self.kind = kind
    }
}

public struct UsageSnapshot: Sendable, Equatable, Codable {
    public let provider: ProviderID
    public let plan: String?
    public let meters: [Meter]
    public let fetchedAt: Date

    public init(provider: ProviderID, plan: String?, meters: [Meter], fetchedAt: Date) {
        self.provider = provider
        self.plan = plan
        self.meters = meters
        self.fetchedAt = fetchedAt
    }

    public var peakPercent: Double? { meters.filter { $0.kind == .quota }.map(\.usedPercent).max() }
}

public struct FetchResult: Sendable {
    public let raw: Data
    public let snapshot: UsageSnapshot
    public let context: [String: String]

    public init(raw: Data, snapshot: UsageSnapshot, context: [String: String] = [:]) {
        self.raw = raw
        self.snapshot = snapshot
        self.context = context
    }

    static func parse(_ data: Data, context: [String: String] = [:], _ parser: (Data) throws -> UsageSnapshot) throws -> FetchResult {
        do {
            return FetchResult(raw: data, snapshot: try parser(data), context: context)
        } catch {
            throw ParseFailure(error: FetchError.wrap(error), raw: data)
        }
    }
}

public struct ParseFailure: Error, Sendable {
    public let error: FetchError
    public let raw: Data
}

public enum FetchError: Error, Equatable, Sendable {
    case notConfigured
    case needsSignIn(String)
    case unsupported(String)
    case http(Int)
    case rateLimited(until: Date?)
    case badResponse(String)
    case network(String)

    public var message: String {
        switch self {
        case .notConfigured: "Not found"
        case .needsSignIn(let hint): hint
        case .unsupported(let text): text
        case .http(let code): "HTTP \(code)"
        case .rateLimited(let until):
            until.map { "Rate limited. Next try \($0.formatted(date: .omitted, time: .shortened))." } ?? "Rate limited."
        case .badResponse(let text): text
        case .network(let text): text
        }
    }

    public static func wrap(_ error: Error) -> FetchError {
        if let error = error as? FetchError { return error }
        if let failure = error as? ParseFailure { return failure.error }
        if let error = error as? URLError { return .network(error.localizedDescription) }
        return .badResponse(error.localizedDescription)
    }
}

public protocol UsageProvider: Sendable {
    var id: ProviderID { get }
    func fetch() async throws -> FetchResult
}

public enum Providers {
    public static let all: [any UsageProvider] = [ClaudeProvider(), CodexProvider(), CursorProvider()]
}
