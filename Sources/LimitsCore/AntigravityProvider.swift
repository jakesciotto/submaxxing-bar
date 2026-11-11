import Foundation

public struct AntigravityProvider: UsageProvider {
    public let id = ProviderID.antigravity
    public var minimumInterval: TimeInterval { 15 * 60 }
    public init() {}

    static let quotaPath = "exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    static let startTimeout: TimeInterval = 15

    public func fetch() async throws -> FetchResult {
        guard let agy = Self.locate() else { throw FetchError.notConfigured }
        let work = try Self.workDirectory()
        let log = work.appending(path: "agy.log")
        try? FileManager.default.removeItem(at: log)
        let token = UUID().uuidString

        let process = Process()
        process.executableURL = agy
        process.arguments = ["--log-file", log.path, "acp"]
        process.currentDirectoryURL = work
        process.environment = ProcessInfo.processInfo.environment.merging(["ANTIGRAVITY_CSRF_TOKEN": token]) { $1 }
        let input = Pipe()
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw FetchError.badResponse("Cannot start agy.")
        }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }

        try? input.fileHandleForWriting.write(contentsOf: Self.openSession(cwd: work.path))
        let port = try await Self.waitForPort(log: log, process: process)
        do {
            let data = try await HTTP.post(
                URL(string: "http://127.0.0.1:\(port)/\(Self.quotaPath)")!,
                body: Data("{}".utf8),
                headers: [
                    "Content-Type": "application/json",
                    "Connect-Protocol-Version": "1",
                    "x-codeium-csrf-token": token,
                ],
                rejected: { .badResponse("agy refused the request (\($0)).") }
            )
            return try FetchResult.parse(data) { try AntigravityParser.parse($0, now: Date()) }
        } catch {
            if !Self.signedIn(log: Self.read(log)) { throw FetchError.needsSignIn("Signed out. Run agy.") }
            throw error
        }
    }

    static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin/agy", "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func workDirectory() throws -> URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/SubmaxxingBar/antigravity")
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw FetchError.badResponse("Cannot create \(url.path).")
        }
        return url
    }

    static func openSession(cwd: String) -> Data {
        let messages: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize",
             "params": ["protocolVersion": 1, "clientCapabilities": [String: Any]()]],
            ["jsonrpc": "2.0", "id": 2, "method": "session/new",
             "params": ["cwd": cwd, "mcpServers": [Any]()]],
        ]
        return messages.reduce(into: Data()) { data, message in
            data += (try? JSONSerialization.data(withJSONObject: message)) ?? Data()
            data += Data("\n".utf8)
        }
    }

    static func waitForPort(log: URL, process: Process) async throws -> Int {
        let deadline = Date().addingTimeInterval(startTimeout)
        while true {
            try await Task.sleep(for: .milliseconds(150))
            let text = read(log)
            if let port = port(inLog: text) { return port }
            if !process.isRunning || Date() > deadline {
                if !signedIn(log: text) { throw FetchError.needsSignIn("Signed out. Run agy.") }
                throw FetchError.badResponse(process.isRunning ? "agy did not start in time." : "agy exited early.")
            }
        }
    }

    static func port(inLog text: String) -> Int? {
        text.firstMatch(of: /listening on random port at (\d+) for HTTP$/.anchorsMatchLineEndings()).flatMap { Int($0.1) }
    }

    static func signedIn(log text: String) -> Bool {
        text.contains("authenticated successfully")
    }

    static func read(_ url: URL) -> String {
        (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

public enum AntigravityParser {
    static let windowOrder = ["5h": 0, "daily": 1, "weekly": 2]

    public static func parse(_ data: Data, now: Date) throws -> UsageSnapshot {
        let root = try JSONValue.object(data)
        let summary = root["response"] as? [String: Any] ?? root
        var meters: [Meter] = []
        for group in summary["groups"] as? [[String: Any]] ?? [] {
            let name = groupLabel(group["displayName"] as? String)
            let buckets = (group["buckets"] as? [[String: Any]] ?? []).sorted {
                windowOrder[$0["window"] as? String ?? "", default: 3] < windowOrder[$1["window"] as? String ?? "", default: 3]
            }
            for bucket in buckets {
                let window = bucket["window"] as? String ?? bucket["bucketId"] as? String ?? "limit"
                let remaining = JSONValue.number(bucket["remainingFraction"]) ?? 0
                meters.append(Meter(
                    label: "\(name) \(window)",
                    usedPercent: min(100, max(0, (1 - remaining) * 100)),
                    resetsAt: JSONValue.date(bucket["resetTime"])
                ))
            }
        }
        guard !meters.isEmpty else {
            throw FetchError.badResponse("Unknown format. Copy diagnostics.")
        }
        return UsageSnapshot(provider: .antigravity, plan: nil, meters: meters, fetchedAt: now)
    }

    static func groupLabel(_ name: String?) -> String {
        guard var name, !name.isEmpty else { return "Models" }
        if name.lowercased().hasSuffix(" models") { name.removeLast(" models".count) }
        return name.replacingOccurrences(of: " and ", with: "/")
    }
}
