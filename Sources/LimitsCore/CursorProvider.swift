import Foundation
import SQLite3

public struct CursorProvider: UsageProvider {
    public let id = ProviderID.cursor
    public init() {}

    static let tokenKey = "cursorAuth/accessToken"
    static let membershipKey = "cursorAuth/stripeMembershipType"

    public func fetch() async throws -> FetchResult {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
        guard FileManager.default.fileExists(atPath: path) else { throw FetchError.notConfigured }
        let values = try CursorStateDB.read(path: path, keys: [Self.tokenKey, Self.membershipKey])
        guard let token = values[Self.tokenKey], !token.isEmpty else {
            throw FetchError.needsSignIn("Signed out. Open Cursor.")
        }
        if token.hasPrefix("cursor-safe-storage:") {
            throw FetchError.unsupported("Encrypted token. Not supported yet.")
        }
        let claims = JWT.claims(token)
        if let expiry = JWT.expiry(token), expiry < Date() {
            throw FetchError.needsSignIn("Sign-in expired. Open Cursor.")
        }
        guard let subject = claims["sub"] as? String, let userID = subject.split(separator: "|").last else {
            throw FetchError.badResponse("Token has no user ID.")
        }
        let data = try await HTTP.get(
            URL(string: "https://cursor.com/api/usage-summary")!,
            headers: ["Cookie": "WorkosCursorSessionToken=\(userID)%3A%3A\(token)"],
            rejected: { .needsSignIn("Sign-in rejected (\($0)). Open Cursor.") }
        )
        let membership = values[Self.membershipKey]
        return try FetchResult.parse(data) { try CursorParser.parse($0, membership: membership, now: Date()) }
    }
}

public enum CursorParser {
    public static func parse(_ data: Data, membership: String?, now: Date) throws -> UsageSnapshot {
        let root = try JSONValue.object(data)
        let reset = JSONValue.date(root["billingCycleEnd"])
        let individual = root["individualUsage"] as? [String: Any] ?? [:]
        var meters: [Meter] = []
        if let plan = individual["plan"] as? [String: Any], plan["enabled"] as? Bool != false {
            let used = JSONValue.number(plan["used"])
            let limit = JSONValue.number(plan["limit"])
            if let used, let limit, limit > 0 {
                meters.append(Meter(label: "Included", usedPercent: used / limit * 100, resetsAt: reset, detail: dollars(used, of: limit)))
            } else if let percent = JSONValue.number(plan["totalPercentUsed"]) {
                meters.append(Meter(label: "Included", usedPercent: percent, resetsAt: reset))
            }
        }
        if let onDemand = individual["onDemand"] as? [String: Any], onDemand["enabled"] as? Bool == true,
           let used = JSONValue.number(onDemand["used"]), let limit = JSONValue.number(onDemand["limit"]), limit > 0 {
            meters.append(Meter(label: "On-demand", usedPercent: used / limit * 100, resetsAt: reset, detail: dollars(used, of: limit), kind: .spend))
        }
        guard !meters.isEmpty else {
            throw FetchError.badResponse("Unknown format. Copy diagnostics.")
        }
        let plan = JSONValue.capitalized(root["membershipType"] as? String ?? membership)
        return UsageSnapshot(provider: .cursor, plan: plan, meters: meters, fetchedAt: now)
    }

    static func dollars(_ usedCents: Double, of limitCents: Double) -> String {
        "\(JSONValue.money(usedCents / 100)) / \(JSONValue.money(limitCents / 100))"
    }
}

enum CursorStateDB {
    static func read(path: String, keys: [String]) throws -> [String: String] {
        let base = URL(fileURLWithPath: path).absoluteString
        for mode in ["mode=ro", "immutable=1"] {
            if let values = try? query(uri: "\(base)?\(mode)", keys: keys) { return values }
        }
        throw FetchError.badResponse("Cannot read Cursor data.")
    }

    private static func query(uri: String, keys: [String]) throws -> [String: String] {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            throw FetchError.badResponse("open failed")
        }
        sqlite3_busy_timeout(db, 2000)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
        guard sqlite3_prepare_v2(db, "SELECT key, value FROM ItemTable WHERE key IN (\(placeholders))", -1, &statement, nil) == SQLITE_OK else {
            throw FetchError.badResponse("prepare failed")
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, key) in keys.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), key, -1, transient)
        }
        var values: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let keyText = sqlite3_column_text(statement, 0) else { continue }
            values[String(cString: keyText)] = decode(statement)
        }
        return values
    }

    private static func decode(_ statement: OpaquePointer?) -> String? {
        let count = Int(sqlite3_column_bytes(statement, 1))
        let pointer: UnsafeRawPointer? = sqlite3_column_type(statement, 1) == SQLITE_BLOB
            ? sqlite3_column_blob(statement, 1)
            : sqlite3_column_text(statement, 1).map { UnsafeRawPointer($0) }
        guard let pointer, count > 0 else { return nil }
        let bytes = Data(bytes: pointer, count: count)
        let looksUTF16 = count % 2 == 0 && bytes.count > 1 && bytes[bytes.startIndex + 1] == 0
        let text = looksUTF16
            ? String(data: bytes, encoding: .utf16LittleEndian)
            : String(data: bytes, encoding: .utf8)
        return text?.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
    }
}
