import CommonCrypto
import Foundation
import SQLite3

public struct CursorProvider: UsageProvider {
    public let id = ProviderID.cursor
    public init() {}

    static let tokenKey = "cursorAuth/accessToken"
    static let membershipKey = "cursorAuth/stripeMembershipType"

    public func resetDeniedAccess() async {
        await CursorKeychain.shared.resetDenial()
    }

    public func fetch() async throws -> FetchResult {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
        guard FileManager.default.fileExists(atPath: path) else { throw FetchError.notConfigured }
        let values = try CursorStateDB.read(path: path, keys: [Self.tokenKey, Self.membershipKey])
        guard let stored = values[Self.tokenKey], !stored.isEmpty else {
            throw FetchError.needsSignIn("Signed out. Open Cursor.")
        }
        let token = try await Self.plaintext(stored)
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

    static func plaintext(_ stored: String) async throws -> String {
        guard CursorSafeStorage.isEncrypted(stored) else { return stored }
        let key = try await CursorKeychain.shared.key()
        do {
            return try CursorSafeStorage.decrypt(stored, key: key)
        } catch {
            await CursorKeychain.shared.forgetKey()
            throw error
        }
    }
}

enum CursorSafeStorage {
    static let prefix = "cursor-safe-storage:v1:"
    static let version = Data("v10".utf8)
    static let salt = Data("saltysalt".utf8)
    static let iterations: UInt32 = 1003
    static let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)

    static func isEncrypted(_ value: String) -> Bool {
        value.hasPrefix(prefix)
    }

    static func deriveKey(password: Data) -> Data {
        var key = Data(count: kCCKeySizeAES128)
        let status = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), iterations,
                        keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), kCCKeySizeAES128
                    )
                }
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed: \(status)")
        return key
    }

    static func decrypt(_ value: String, key: Data) throws -> String {
        let failure = FetchError.badResponse("Cannot decrypt Cursor token.")
        guard let blob = Data(base64Encoded: String(value.dropFirst(prefix.count))),
              blob.starts(with: version)
        else { throw failure }
        let ciphertext = blob.dropFirst(version.count)
        var plaintext = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var written = 0
        let status = plaintext.withUnsafeMutableBytes { output in
            ciphertext.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                            input.baseAddress, ciphertext.count,
                            output.baseAddress, output.count, &written
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess, let text = String(data: plaintext.prefix(written), encoding: .utf8) else {
            throw failure
        }
        return text
    }
}

actor CursorKeychain {
    static let shared = CursorKeychain()
    static let service = "Cursor Safe Storage"
    static let account = "Cursor Key"
    static let denied = FetchError.needsSignIn("Keychain access denied. Click refresh to retry.")

    private var cached: Data?
    private var isDenied = false
    private var pending: Task<Data, Error>?

    func key() async throws -> Data {
        if let cached { return cached }
        if isDenied { throw Self.denied }
        if let pending { return try await pending.value }
        let task = Task { try await Self.read() }
        pending = task
        defer { pending = nil }
        do {
            let key = try await task.value
            cached = key
            return key
        } catch let error as FetchError where error == Self.denied {
            isDenied = true
            throw error
        }
    }

    func resetDenial() {
        isDenied = false
    }

    func forgetKey() {
        cached = nil
    }

    private static func read() async throws -> Data {
        let result = try await Shell.run(
            "/usr/bin/security", ["find-generic-password", "-s", service, "-a", account, "-w"], timeout: 120
        )
        switch result.status {
        case 0:
            var password = result.output
            if password.last == UInt8(ascii: "\n") { password.removeLast() }
            guard !password.isEmpty else { throw denied }
            return CursorSafeStorage.deriveKey(password: password)
        case 44:
            throw FetchError.needsSignIn("Cursor key not in Keychain. Open Cursor.")
        default:
            throw denied
        }
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
