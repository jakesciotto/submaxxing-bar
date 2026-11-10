import Foundation

enum JSONValue {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.badResponse("Unexpected response.")
        }
        return object
    }

    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.doubleValue
        }
        if let text = value as? String { return Double(text) }
        return nil
    }

    static func date(_ value: Any?) -> Date? {
        if let seconds = number(value) {
            return Date(timeIntervalSince1970: seconds > 1e12 ? seconds / 1000 : seconds)
        }
        guard let text = value as? String else { return nil }
        return iso8601(text)
    }

    static func iso8601(_ text: String) -> Date? {
        var normalized = text
        if let range = normalized.range(of: #"\.\d+"#, options: .regularExpression) {
            let digits = normalized[range].dropFirst()
            normalized.replaceSubrange(range, with: "." + String((digits + "000").prefix(3)))
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: normalized) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: normalized)
    }

    static func money(_ amount: Double, currency: String = "USD") -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US")
        formatter.currencyCode = currency
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f %@", amount, currency)
    }

    static func count(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(Int(value))
    }

    static func capitalized(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

enum JWT {
    static func claims(_ token: String) -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return [:] }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    static func expiry(_ token: String) -> Date? {
        JSONValue.number(claims(token)["exp"]).map { Date(timeIntervalSince1970: $0) }
    }
}

enum HTTP {
    struct StatusError: Error { let code: Int }

    static let session = URLSession(configuration: .ephemeral)

    static func get(_ url: URL, headers: [String: String]) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("SubmaxxingBar/0.1", forHTTPHeaderField: "User-Agent")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw StatusError(code: code) }
        return data
    }

    static func get(_ url: URL, headers: [String: String], rejected: (Int) -> FetchError) async throws -> Data {
        do {
            return try await get(url, headers: headers)
        } catch let error as StatusError {
            throw error.code == 401 || error.code == 403 ? rejected(error.code) : FetchError.http(error.code)
        }
    }
}

enum Shell {
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 30) async throws -> (status: Int32, output: Data) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning { process.terminate() }
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: (process.terminationStatus, data))
            }
        }
    }
}
