import Foundation
import XCTest
#if os(macOS)
@testable import EclipseMac
#else
@testable import Eclipse
#endif

final class SimklAPITests: XCTestCase {
    private let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    private let state = "fixture-sign-in-state"
    private let fixtureClientID = "fixture-simkl-client-id"

    func testClientConfigurationRejectsMissingUnexpandedAndMalformedValues() throws {
        XCTAssertEqual(try SimklAPI.validatedClientID("  \(fixtureClientID)\n"), fixtureClientID)
        for value in [nil, "", " \n", "$(SIMKL_CLIENT_ID)", "client\nid", String(repeating: "x", count: 4_097)] as [String?] {
            XCTAssertThrowsError(try SimklAPI.validatedClientID(value)) {
                XCTAssertEqual($0 as? SimklAPIError, .missingConfiguration)
            }
        }
        for value in ["", "$(SIMKL_CLIENT_ID)"] {
            XCTAssertThrowsError(try SimklAPI.request(path: "/sync/activities", clientID: value)) {
                XCTAssertEqual($0 as? SimklAPIError, .missingConfiguration)
            }
            XCTAssertThrowsError(try SimklAPI.authorizationURL(verifier: verifier, state: state, clientID: value)) {
                XCTAssertEqual($0 as? SimklAPIError, .missingConfiguration)
            }
            XCTAssertThrowsError(try SimklAPI.formRequest(path: "/oauth2/device", fields: [:], clientID: value)) {
                XCTAssertEqual($0 as? SimklAPIError, .missingConfiguration)
            }
        }
    }

    func testDefaultRequestsUseBundleConfigurationWithoutAnEmbeddedFallback() throws {
        let configured = try? SimklAPI.validatedClientID(Bundle.main.object(forInfoDictionaryKey: "SimklClientID") as? String)
        guard let configured else {
            XCTAssertTrue(SimklAPI.clientID.isEmpty)
            XCTAssertThrowsError(try SimklAPI.request(path: "/sync/activities")) {
                XCTAssertEqual($0 as? SimklAPIError, .missingConfiguration)
            }
            return
        }
        let request = try SimklAPI.request(path: "/sync/activities")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertTrue(components.queryItems?.first { $0.name == "client_id" }?.value == configured)
    }

    func testPKCEUsesTheS256RFCVectorAndSecureRandomValues() throws {
        XCTAssertEqual(try SimklAPI.codeChallenge(verifier: verifier),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertThrowsError(try SimklAPI.codeChallenge(verifier: "short"))
        XCTAssertThrowsError(try SimklAPI.codeChallenge(verifier: String(repeating: "a", count: 129)))
        XCTAssertThrowsError(try SimklAPI.codeChallenge(verifier: String(repeating: "é", count: 43)))
        let first = try SimklAPI.generateCodeVerifier()
        let second = try SimklAPI.generateCodeVerifier()
        XCTAssertEqual(first.count, 43)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try SimklAPI.codeChallenge(verifier: first).count, 43)
        XCTAssertEqual(try SimklAPI.generateState().count, 43)
    }

    func testAuthorizationUsesTheBrowserHostExactRedirectAndBothScopes() throws {
        let url = try SimklAPI.authorizationURL(verifier: verifier, state: state, clientID: fixtureClientID)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "simkl.com")
        XCTAssertEqual(components.path, "/oauth2/authorize")
        XCTAssertEqual(query["client_id"], fixtureClientID)
        XCTAssertEqual(query["redirect_uri"], "luna://simkl-callback")
        XCTAssertEqual(query["scope"], "media:read media:write")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["state"], state)
        XCTAssertFalse(query.keys.contains("code_verifier"))
    }

    func testCallbackRejectsWrongStateIssuerRouteAndDuplicateParameters() throws {
        let valid = try callback()
        XCTAssertEqual(try SimklAPI.authorizationCode(callback: valid, state: state), "fixture-code")
        for url in [
            try callback(state: "other-state"),
            try callback(issuer: "https://simkl.com.attacker.example"),
            try callback(issuer: "https://trakt.tv"),
            try callback(base: "luna://trakt-callback"),
            try callback(base: "luna://simkl-callback/"),
            try callback(base: "luna://user@simkl-callback"),
            try callback(base: "luna://simkl-callback:443"),
            try callback(extra: [URLQueryItem(name: "state", value: state)]),
            try callback(extra: [URLQueryItem(name: "code", value: "replacement")]),
            try callback(fragment: "unexpected")
        ] {
            XCTAssertThrowsError(try SimklAPI.authorizationCode(callback: url, state: state)) {
                XCTAssertEqual($0 as? SimklAPIError, .invalidCallback)
            }
        }
    }

    func testAuthorizationDenialStillRequiresValidStateAndIssuer() throws {
        let denied = try callback(extra: [URLQueryItem(name: "error", value: "access_denied")])
        XCTAssertThrowsError(try SimklAPI.authorizationCode(callback: denied, state: state)) {
            XCTAssertEqual($0 as? SimklAPIError, .authorizationDenied)
        }
        let untrusted = try callback(issuer: "https://other.example", extra: [URLQueryItem(name: "error", value: "access_denied")])
        XCTAssertThrowsError(try SimklAPI.authorizationCode(callback: untrusted, state: state)) {
            XCTAssertEqual($0 as? SimklAPIError, .invalidCallback)
        }
    }

    func testAPIRequestsKeepAttributionAndNeverAllowTheAPIHostToChange() throws {
        let request = try SimklAPI.request(path: "/sync/all-items/anime", queryItems: [URLQueryItem(name: "date_from", value: "2026-10-04T12:00:00Z")], clientID: fixtureClientID)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        XCTAssertEqual(components.host, "api.simkl.com")
        XCTAssertEqual(values["client_id"], fixtureClientID)
        XCTAssertEqual(values["app-name"], "eclipse")
        XCTAssertEqual(values["app-version"], SimklAPI.appVersion)
        XCTAssertEqual(values["date_from"], "2026-10-04T12:00:00Z")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Eclipse/\(SimklAPI.appVersion)")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        for path in ["https://attacker.example/sync/history", "//attacker.example/sync/history", "/sync/history?client_id=other", "/sync/../oauth2/token"] {
            XCTAssertThrowsError(try SimklAPI.request(path: path, clientID: fixtureClientID))
        }
        XCTAssertThrowsError(try SimklAPI.request(path: "/sync/history", queryItems: [URLQueryItem(name: "client_id", value: "other")], clientID: fixtureClientID))
        XCTAssertThrowsError(try SimklAPI.request(path: "/sync/history", method: "GET", body: ["movies": []], clientID: fixtureClientID))
    }

    func testFormEncodingPreservesSpecialCharactersAndPublicClientAuthentication() throws {
        XCTAssertEqual(String(data: SimklAPI.formBody(["value": "a+b&c=d e/é"]), encoding: .utf8),
                       "value=a%2Bb%26c%3Dd%20e%2F%C3%A9")
        let request = try SimklAPI.formRequest(path: "/oauth2/token", fields: [
            "grant_type": "authorization_code", "code": "fixture-code",
            "redirect_uri": SimklAPI.redirectURI, "code_verifier": verifier
        ], clientID: fixtureClientID)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let body = try XCTUnwrap(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8))
        XCTAssertTrue(body.contains("client_id=\(fixtureClientID)"))
        XCTAssertTrue(body.contains("redirect_uri=luna%3A%2F%2Fsimkl-callback"))
        XCTAssertFalse(body.contains("client_secret"))
        XCTAssertThrowsError(try SimklAPI.formRequest(path: "/sync/history", fields: [:], clientID: fixtureClientID))
    }

    func testTokenResponsesRequireRefreshAndActuallyGrantedWriteScope() throws {
        let token = try SimklAuthResponse(data: try json([
            "access_token": "simkl_at_fixture", "refresh_token": "simkl_rt_fixture",
            "token_type": "Bearer", "expires_in": 604_800, "scope": "media:read media:write"
        ]))
        XCTAssertEqual(token.expiresIn, 604_800)
        XCTAssertEqual(token.refreshToken, "simkl_rt_fixture")
        XCTAssertThrowsError(try SimklAuthResponse(data: try json([
            "access_token": "simkl_at_fixture", "refresh_token": "simkl_rt_fixture",
            "token_type": "Bearer", "expires_in": 604_800, "scope": "media:read"
        ]))) {
            XCTAssertEqual($0 as? SimklAPIError, .permissionMissing)
        }
        XCTAssertThrowsError(try SimklAuthResponse(data: try json([
            "access_token": "simkl_at_fixture", "refresh_token": "",
            "token_type": "Bearer", "expires_in": 604_800, "scope": "media:read media:write"
        ])))
    }

    func testDisconnectRevocationUsesThePublicClientFormEndpoint() throws {
        let request = try SimklAPI.formRequest(path: "/oauth2/revoke", fields: [
            "token": "fixture-refresh-token", "token_type_hint": "refresh_token", "client_id": "untrusted-client-id"
        ], clientID: fixtureClientID)
        XCTAssertEqual(request.url?.host, "api.simkl.com")
        XCTAssertEqual(request.url?.path, "/oauth2/revoke")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8))
        XCTAssertTrue(body.contains("client_id=\(fixtureClientID)"))
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "client_id" }?.value, fixtureClientID)
        XCTAssertFalse(body.contains("untrusted-client-id"))
        XCTAssertTrue(body.contains("token=fixture-refresh-token"))
        XCTAssertTrue(body.contains("token_type_hint=refresh_token"))
        XCTAssertFalse(body.contains("client_secret"))
    }

    func testDeviceSignInOnlyDisplaysSIMKLVerificationURLsAndBoundsPolling() throws {
        let value: [String: Any] = [
            "device_code": "private-device-code", "user_code": "BDWP-HQPK",
            "verification_uri": "https://simkl.com/pin",
            "verification_uri_complete": "https://simkl.com/pin?user_code=BDWP-HQPK",
            "expires_in": 900, "interval": 5
        ]
        let response = try SimklDeviceAuthorizationResponse(data: try json(value))
        XCTAssertEqual(response.userCode, "BDWP-HQPK")
        XCTAssertEqual(response.interval, 5)
        for (key, replacement) in [
            ("verification_uri", "https://attacker.example/pin"),
            ("verification_uri_complete", "https://simkl.com/pin?user_code=OTHER-CODE"),
            ("verification_uri_complete", "https://simkl.com/pin?user_code=BDWP-HQPK&next=https://attacker.example")
        ] {
            var invalid = value
            invalid[key] = replacement
            XCTAssertThrowsError(try SimklDeviceAuthorizationResponse(data: try json(invalid)))
        }
        var noDeadline = value
        noDeadline["expires_in"] = 0
        XCTAssertThrowsError(try SimklDeviceAuthorizationResponse(data: try json(noDeadline)))
    }

    func testMutationResponsesDetectPartialFailuresAndInvalidSuccessBodies() throws {
        try SimklAPI.validateMutationResponse(json(["added": ["movies": 0, "shows": 0], "not_found": ["movies": [], "shows": []]]))
        try SimklAPI.validateMutationResponse(json(["action": "scrobble", "progress": 100]))
        XCTAssertThrowsError(try SimklAPI.validateMutationResponse(json([
            "added": ["movies": 1], "not_found": ["movies": [["ids": ["tmdb": 42]]], "shows": []]
        ]))) {
            XCTAssertEqual($0 as? SimklAPIError, .unmatchedMedia)
        }
        for value: [String: Any] in [[:], ["not_found": []], ["added": [:], "not_found": ["movies": "bad"]], ["error": "id_err", "added": [:]]] {
            XCTAssertThrowsError(try SimklAPI.validateMutationResponse(json(value)))
        }
        XCTAssertThrowsError(try SimklAPI.validateMutationResponse(Data(repeating: 32, count: SimklAPI.maximumMutationResponseBytes + 1)))
    }

    func testQuotaExhaustionFailsImmediatelyAndDoesNotBlockOtherUsers() async throws {
        let limiter = SimklRequestLimiter(readInterval: 0, writeInterval: 0)
        let now = Date()
        let response = try httpResponse(status: 429, headers: ["Retry-After": "3600", "X-RateLimit-Remaining": "0"])
        let delay = await limiter.record(response: response, data: try json(["error": "user_limit_exceeded"]), userID: "first", method: "GET", now: now)
        XCTAssertNil(delay)
        do {
            try await limiter.wait(userID: "first", method: "POST")
            XCTFail("An exhausted account should fail without sleeping until reset")
        } catch SimklAPIError.rateLimited(let until) {
            XCTAssertGreaterThan(until.timeIntervalSince(now), 3_599)
        }
        try await limiter.wait(userID: "second", method: "POST")
    }

    func testLastAllowedSuccessRecordsExhaustionAndMissingHeadersAreNotZero() async throws {
        let limiter = SimklRequestLimiter(readInterval: 0, writeInterval: 0)
        let missing = try httpResponse(status: 200)
        let firstDelay = await limiter.record(response: missing, data: try json([:]), userID: "first", method: "GET")
        XCTAssertNil(firstDelay)
        try await limiter.wait(userID: "first", method: "GET")
        let last = try httpResponse(status: 200, headers: ["X-RateLimit-Remaining": "0"])
        _ = await limiter.record(response: last, data: try json([:]), userID: "first", method: "GET")
        do {
            try await limiter.wait(userID: "first", method: "GET")
            XCTFail("Remaining zero on a successful response should prevent the next request")
        } catch {
            guard let refusal = error as? SimklAPIError, case .rateLimited = refusal else { return XCTFail("Unexpected refusal: \(error)") }
        }
    }

    func testBurstRefusalsIgnoreTheDailyRetryAfterAndKeepWriteLockRetriesShort() async throws {
        let limiter = SimklRequestLimiter(readInterval: 0, writeInterval: 0)
        let burst = try httpResponse(status: 429, headers: ["Retry-After": "45000"])
        let burstDelay = await limiter.record(response: burst, data: try json(["error": "rate_limit"]), userID: "first", method: "POST")
        XCTAssertEqual(burstDelay ?? 0, 1.1, accuracy: 0.0001)
        let locked = try httpResponse(status: 400)
        let lockDelay = await limiter.record(response: locked, data: try json(["error": "RATE_LIMIT"]), userID: "second", method: "POST")
        XCTAssertEqual(lockDelay ?? 0, 1.1, accuracy: 0.0001)
    }

    func testDailyResetUsesNewYorkMidnightAcrossDaylightSavingTime() throws {
        let formatter = ISO8601DateFormatter()
        let cases = [
            ("2026-01-15T12:00:00Z", "2026-01-16T05:00:00Z"),
            ("2026-07-15T12:00:00Z", "2026-07-16T04:00:00Z"),
            ("2026-03-08T05:01:00Z", "2026-03-09T04:00:00Z"),
            ("2026-11-01T04:01:00Z", "2026-11-02T05:00:00Z")
        ]
        for (now, expected) in cases {
            XCTAssertEqual(SimklRequestLimiter.nextReset(after: try XCTUnwrap(formatter.date(from: now))),
                           try XCTUnwrap(formatter.date(from: expected)))
        }
    }

    private func callback(base: String = SimklAPI.redirectURI, state: String? = nil,
                          issuer: String = SimklAPI.issuer, extra: [URLQueryItem] = [],
                          fragment: String? = nil) throws -> URL {
        var components = try XCTUnwrap(URLComponents(string: base))
        components.queryItems = [URLQueryItem(name: "code", value: "fixture-code"),
                                 URLQueryItem(name: "state", value: state ?? self.state),
                                 URLQueryItem(name: "iss", value: issuer)] + extra
        components.fragment = fragment
        return try XCTUnwrap(components.url)
    }

    private func json(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func httpResponse(status: Int, headers: [String: String] = [:]) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(URL(string: "https://api.simkl.com/sync/activities")),
                                     statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers))
    }
}
