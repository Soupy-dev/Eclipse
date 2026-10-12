import CryptoKit
import Foundation
import Security

enum SimklAPIError: Error, LocalizedError, Equatable {
    case invalidRequest
    case missingConfiguration
    case invalidResponse
    case invalidCallback
    case authorizationDenied
    case permissionMissing
    case unmatchedMedia
    case randomGenerationFailed
    case rateLimited(until: Date)
    case http(status: Int, error: String?)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "SIMKL sign-in is unavailable in this build."
        case .invalidRequest:
            return "The SIMKL request could not be prepared."
        case .invalidResponse:
            return "SIMKL returned an invalid response."
        case .invalidCallback:
            return "The SIMKL sign-in response could not be verified. Try signing in again."
        case .authorizationDenied:
            return "SIMKL sign-in was cancelled."
        case .permissionMissing:
            return "Reconnect SIMKL and allow Eclipse to read and update your media library."
        case .unmatchedMedia:
            return "SIMKL could not identify this title or episode."
        case .randomGenerationFailed:
            return "SIMKL sign-in could not be started. Try again."
        case .rateLimited(let until):
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return "SIMKL's request limit has been reached. Try again \(formatter.localizedString(for: until, relativeTo: Date()))."
        case .http(let status, let error):
            if error == "invalid_grant" {
                return "Your SIMKL session has expired. Sign in again."
            }
            if status == 401 { return "SIMKL authentication failed. Try signing in again." }
            if status == 403 { return "SIMKL did not allow this request. Check your account permissions." }
            return "SIMKL could not complete the request (\(status))."
        }
    }
}

enum SimklAPI {
    static var clientID: String {
        (try? validatedClientID(Bundle.main.object(forInfoDictionaryKey: "SimklClientID") as? String)) ?? ""
    }

    static func validatedClientID(_ raw: String?) throws -> String {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty, value.utf8.count <= 4_096, !value.contains("$("),
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else {
            throw SimklAPIError.missingConfiguration
        }
        return value
    }
    static let redirectURI = "luna://simkl-callback"
    static let issuer = "https://simkl.com"
    static let maximumResponseBytes = 32 * 1_024 * 1_024
    static let maximumMutationResponseBytes = 2 * 1_024 * 1_024

    static var appVersion: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return value.flatMap { $0.isEmpty ? nil : String($0.prefix(64)) } ?? "1.0"
    }

    static func request(path: String, method: String = "GET", body: [String: Any]? = nil,
                        queryItems: [URLQueryItem] = [], clientID: String = SimklAPI.clientID) throws -> URLRequest {
        let clientID = try validatedClientID(clientID)
        guard path.hasPrefix("/"), !path.hasPrefix("//"), path.utf8.count <= 1_024,
              !path.contains("?"), !path.contains("#"), !path.contains("\\"),
              !path.contains(".."), let pathComponents = URLComponents(string: path),
              pathComponents.scheme == nil, pathComponents.host == nil,
              pathComponents.query == nil, pathComponents.fragment == nil,
              !pathComponents.path.contains(".."), !pathComponents.path.contains("\\"),
              ["GET", "POST", "DELETE"].contains(method), queryItems.count <= 32,
              queryItems.allSatisfy({ item in
                  !["client_id", "app-name", "app-version"].contains(item.name)
                      && !item.name.isEmpty && item.name.utf8.count <= 128
                      && (item.value?.utf8.count ?? 0) <= 4_096
              }), var components = URLComponents(string: "https://api.simkl.com") else {
            throw SimklAPIError.invalidRequest
        }
        components.percentEncodedPath = pathComponents.percentEncodedPath
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "app-name", value: "eclipse"),
            URLQueryItem(name: "app-version", value: appVersion)
        ] + queryItems
        guard let url = components.url else { throw SimklAPIError.invalidRequest }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Eclipse/\(appVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            guard method != "GET", JSONSerialization.isValidJSONObject(body) else {
                throw SimklAPIError.invalidRequest
            }
            let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            guard data.count <= maximumMutationResponseBytes else { throw SimklAPIError.invalidRequest }
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    static func formBody(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let pairs = fields.keys.sorted().map { key in
            let name = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            let value = (fields[key] ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(name)=\(value)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    static func formRequest(path: String, fields: [String: String], clientID: String = SimklAPI.clientID) throws -> URLRequest {
        let clientID = try validatedClientID(clientID)
        guard ["/oauth2/token", "/oauth2/device", "/oauth2/revoke"].contains(path),
              fields.count <= 16, fields.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 128 && $0.value.utf8.count <= 4_096 }) else {
            throw SimklAPIError.invalidRequest
        }
        var request = try request(path: path, method: "POST", clientID: clientID)
        var parameters = fields
        parameters["client_id"] = clientID
        request.httpBody = formBody(parameters)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return request
    }

    static func generateCodeVerifier() throws -> String {
        try randomToken(byteCount: 32)
    }

    static func generateState() throws -> String {
        try randomToken(byteCount: 32)
    }

    static func codeChallenge(verifier: String) throws -> String {
        guard validVerifier(verifier) else { throw SimklAPIError.invalidRequest }
        return base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func authorizationURL(verifier: String, state: String, clientID: String = SimklAPI.clientID) throws -> URL {
        let clientID = try validatedClientID(clientID)
        guard !state.isEmpty, state.utf8.count <= 512,
              var components = URLComponents(string: "https://simkl.com/oauth2/authorize") else {
            throw SimklAPIError.invalidRequest
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "media:read media:write"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: try codeChallenge(verifier: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        guard let url = components.url else { throw SimklAPIError.invalidRequest }
        return url
    }

    static func authorizationCode(callback: URL, state: String) throws -> String {
        guard !state.isEmpty, state.utf8.count <= 512, callback.absoluteString.utf8.count <= 16_384,
              var components = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              components.fragment == nil, components.user == nil, components.password == nil,
              components.port == nil else { throw SimklAPIError.invalidCallback }
        let items = components.queryItems ?? []
        components.query = nil
        guard components.string == redirectURI, items.count <= 16,
              Set(items.map(\.name)).count == items.count else { throw SimklAPIError.invalidCallback }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard values["state"] == state, values["iss"] == issuer else { throw SimklAPIError.invalidCallback }
        if values["error"] != nil { throw SimklAPIError.authorizationDenied }
        guard let code = values["code"], !code.isEmpty, code.utf8.count <= 4_096 else {
            throw SimklAPIError.invalidCallback
        }
        return code
    }

    static func jsonObject(_ data: Data, maximumBytes: Int = maximumResponseBytes) throws -> [String: Any] {
        guard !data.isEmpty, data.count <= maximumBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SimklAPIError.invalidResponse
        }
        var stack: [(Any, Int)] = [(object, 0)]
        var count = 0
        while let (value, depth) = stack.popLast() {
            count += 1
            guard depth <= 64, count <= 500_000 else { throw SimklAPIError.invalidResponse }
            if let dictionary = value as? [String: Any] {
                stack.append(contentsOf: dictionary.values.map { ($0, depth + 1) })
            } else if let array = value as? [Any] {
                stack.append(contentsOf: array.map { ($0, depth + 1) })
            }
        }
        return object
    }

    static func validateMutationResponse(_ data: Data) throws {
        let object = try jsonObject(data, maximumBytes: maximumMutationResponseBytes)
        guard object["error"] == nil else { throw SimklAPIError.invalidResponse }
        if let value = object["not_found"] {
            guard let missing = value as? [String: Any] else { throw SimklAPIError.invalidResponse }
            for value in missing.values {
                guard let items = value as? [Any] else { throw SimklAPIError.invalidResponse }
                guard items.isEmpty else { throw SimklAPIError.unmatchedMedia }
            }
        }
        let action = object["action"] as? String
        guard object["added"] is [String: Any] || object["deleted"] is [String: Any]
                || ["start", "pause", "scrobble", "checkin"].contains(action ?? "") else {
            throw SimklAPIError.invalidResponse
        }
    }

    static func errorCode(_ data: Data) -> String? {
        guard data.count <= maximumMutationResponseBytes,
              let object = try? jsonObject(data, maximumBytes: maximumMutationResponseBytes),
              let code = object["error"] as? String, !code.isEmpty, code.utf8.count <= 128 else { return nil }
        return code
    }

    private static func validVerifier(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return (43...128).contains(value.utf8.count) && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func randomToken(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw SimklAPIError.randomGenerationFailed
        }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

struct SimklAuthResponse: Codable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
    let refreshToken: String
    let scope: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }

    init(data: Data) throws {
        guard !data.isEmpty, data.count <= 65_536 else { throw SimklAPIError.invalidResponse }
        self = try JSONDecoder().decode(Self.self, from: data)
        try validate()
    }

    func validate() throws {
        guard !accessToken.isEmpty, accessToken.utf8.count <= 4_096,
              !refreshToken.isEmpty, refreshToken.utf8.count <= 4_096,
              tokenType.lowercased() == "bearer", expiresIn > 0, expiresIn <= 31_536_000,
              scope.utf8.count <= 256 else { throw SimklAPIError.invalidResponse }
        let scopes = Set(scope.split(separator: " ").map(String.init))
        guard scopes.contains("media:read"), scopes.contains("media:write") else {
            throw SimklAPIError.permissionMissing
        }
    }
}

struct SimklDeviceAuthorizationResponse: Codable {
    let deviceCode: String
    let userCode: String
    let verificationURI: URL
    let verificationURIComplete: URL
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case verificationURIComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }

    init(data: Data) throws {
        guard !data.isEmpty, data.count <= 65_536 else { throw SimklAPIError.invalidResponse }
        self = try JSONDecoder().decode(Self.self, from: data)
        try validate()
    }

    func validate() throws {
        guard !deviceCode.isEmpty, deviceCode.utf8.count <= 4_096,
              userCode.utf8.count <= 32, !userCode.isEmpty,
              expiresIn > 0, expiresIn <= 900, interval >= 1, interval <= 60,
              Self.validVerificationURL(verificationURI), Self.validVerificationURL(verificationURIComplete),
              let base = URLComponents(url: verificationURI, resolvingAgainstBaseURL: false), base.query == nil,
              let complete = URLComponents(url: verificationURIComplete, resolvingAgainstBaseURL: false),
              complete.queryItems == [URLQueryItem(name: "user_code", value: userCode)] else {
            throw SimklAPIError.invalidResponse
        }
    }

    private static func validVerificationURL(_ url: URL) -> Bool {
        guard url.absoluteString.utf8.count <= 1_024,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme == "https" && components.host == "simkl.com"
            && components.path == "/pin" && components.port == nil && components.user == nil
            && components.password == nil && components.fragment == nil
    }
}

actor SimklRequestLimiter {
    static let shared = SimklRequestLimiter()

    private struct UserState {
        let readGate: TrackerRequestGate
        let writeGate: TrackerRequestGate
        var resetAt: Date
        var remaining: Int?
        var blockedUntil: Date?
        var lastUsed: Date
    }

    private var users: [String: UserState] = [:]
    private let readInterval: TimeInterval
    private let writeInterval: TimeInterval

    init(readInterval: TimeInterval = 0.15, writeInterval: TimeInterval = 1.05) {
        self.readInterval = readInterval
        self.writeInterval = writeInterval
    }

    func requireReady(userID: String) throws {
        guard !userID.isEmpty, userID.utf8.count <= 256 else { throw SimklAPIError.invalidRequest }
        let now = Date()
        try checkAvailability(state(userID: userID, now: now), now: now)
    }

    func wait(userID: String, method: String) async throws {
        guard !userID.isEmpty, userID.utf8.count <= 256 else { throw SimklAPIError.invalidRequest }
        let now = Date()
        let user = state(userID: userID, now: now)
        try checkAvailability(user, now: now)
        let gate = method == "GET" ? user.readGate : user.writeGate
        try await gate.waitForSlot(priority: TrackerRequestContext.priority)
        try Task.checkCancellation()
        if let current = users[userID] { try checkAvailability(current, now: Date()) }
    }

    func record(response: HTTPURLResponse, data: Data, userID: String, method: String,
                now: Date = Date()) async -> TimeInterval? {
        var user = state(userID: userID, now: now)
        if let text = response.value(forHTTPHeaderField: "X-RateLimit-Remaining"),
           let remaining = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), remaining >= 0 {
            user.remaining = min(user.remaining ?? remaining, remaining)
            if user.remaining == 0 { user.blockedUntil = max(user.blockedUntil ?? now, user.resetAt) }
        }
        let error = SimklAPI.errorCode(data)
        let delay: TimeInterval?
        if response.statusCode == 429 && ["user_limit_exceeded", "app_limit_exceeded"].contains(error ?? "") {
            let reset = Self.retryDate(response: response, now: now) ?? user.resetAt
            user.remaining = 0
            user.blockedUntil = max(user.blockedUntil ?? now, reset)
            delay = nil
        } else if response.statusCode == 429 || (response.statusCode == 400 && error == "RATE_LIMIT") {
            let retryDate = error == "rate_limit" || error == "RATE_LIMIT"
                ? now.addingTimeInterval(1.1)
                : Self.retryDate(response: response, now: now) ?? now.addingTimeInterval(1.1)
            let interval = max(0, retryDate.timeIntervalSince(now))
            if interval > 60 {
                user.blockedUntil = max(user.blockedUntil ?? now, retryDate)
                delay = nil
            } else {
                delay = interval
            }
        } else {
            delay = nil
        }
        users[userID] = user
        if let delay {
            let until = now.addingTimeInterval(delay)
            await user.readGate.record(pauseUntil: until)
            await user.writeGate.record(pauseUntil: until)
        }
        return delay
    }

    static func nextReset(after now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        if let timezone = TimeZone(identifier: "America/New_York") { calendar.timeZone = timezone }
        let start = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: start) ?? now.addingTimeInterval(86_400)
    }

    static func retryDate(response: HTTPURLResponse, now: Date) -> Date? {
        guard let text = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              seconds.isFinite, seconds >= 0, seconds <= 604_800 else { return nil }
        return now.addingTimeInterval(max(1, seconds))
    }

    private func state(userID: String, now: Date) -> UserState {
        if var existing = users[userID] {
            if now >= existing.resetAt {
                existing.resetAt = Self.nextReset(after: now)
                existing.remaining = nil
            }
            if let until = existing.blockedUntil, until <= now { existing.blockedUntil = nil }
            existing.lastUsed = now
            users[userID] = existing
            return existing
        }
        if users.count >= 128,
           let oldest = users.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            users.removeValue(forKey: oldest)
        }
        let new = UserState(readGate: TrackerRequestGate(minInterval: readInterval),
                            writeGate: TrackerRequestGate(minInterval: writeInterval),
                            resetAt: Self.nextReset(after: now), remaining: nil,
                            blockedUntil: nil, lastUsed: now)
        users[userID] = new
        return new
    }

    private func checkAvailability(_ user: UserState, now: Date) throws {
        if let until = user.blockedUntil, until > now { throw SimklAPIError.rateLimited(until: until) }
        if user.remaining == 0, user.resetAt > now { throw SimklAPIError.rateLimited(until: user.resetAt) }
    }
}
