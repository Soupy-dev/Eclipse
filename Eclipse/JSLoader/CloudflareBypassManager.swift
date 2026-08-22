import Combine
import Foundation

#if os(tvOS)
enum CloudflareBypassError: LocalizedError {
    case unavailableOnTV

    var errorDescription: String? {
        "Interactive browser verification is not available on Apple TV."
    }
}

extension Notification.Name {
    static let cloudflareBypassSolved = Notification.Name("CloudflareBypassSolved")
}

/// tvOS deliberately has no browser-backed Cloudflare bypass. Keeping the public HTTP
/// surface here lets JavaScriptCore services use URLSession while challenge pages fail
/// immediately and Auto Mode can continue to the next source.
final class CloudflareBypassManager: ObservableObject {
    static let shared = CloudflareBypassManager()

    @Published private(set) var pendingVerificationURL: URL?

    private init() {}

    func applyCachedBypass(to request: inout URLRequest, for url: URL) {}

    func headersByApplyingCachedBypass(_ headers: [String: String], for url: URL) -> [String: String] {
        headers
    }

    func fullCookieHeader(for host: String) -> String? { nil }
    func bypassUserAgent(for host: String) -> String? { nil }

    @MainActor
    func flagPendingVerification(for url: URL) {
        var redacted = URLComponents()
        redacted.scheme = url.scheme
        redacted.host = url.host
        redacted.port = url.port
        redacted.path = "/"
        pendingVerificationURL = redacted.url
        Logger.shared.log(
            "CloudflareBypass: interactive challenge unavailable on tvOS host=\(url.host?.lowercased() ?? "unknown-host")",
            type: "Service"
        )
    }

    @MainActor
    @discardableResult
    func refreshSessionAfterChallenge(
        for url: URL,
        rejectedCookieHeader: String? = nil
    ) async -> Bool {
        flagPendingVerification(for: url)
        return false
    }

    func recoverChallengedRequest(
        for url: URL,
        method: String,
        body: Data?,
        extraHeaders: [String: String],
        allowRedirects: Bool
    ) async -> (data: Data, response: HTTPURLResponse)? {
        await flagPendingVerification(for: url)
        return nil
    }

    static func isChallengeResponse(status: Int, body: String, headers: [String: String] = [:]) -> Bool {
        let lowerBody = body.lowercased()
        let isBlockedStatus = [403, 429, 503].contains(status)
        let lowerHeaders = headers.reduce(into: [String: String]()) { result, pair in
            result[pair.key.lowercased()] = pair.value.lowercased()
        }

        // Cloudflare explicitly labels challenge responses with this header. Unlike `Server:
        // cloudflare` and `CF-Ray`, it is not also present on ordinary rate-limit, access-denied,
        // or origin-error pages that no amount of human verification can solve.
        if lowerHeaders["cf-mitigated"]?.contains("challenge") == true {
            return true
        }

        // Tokens that appear only on the actual interstitial/challenge document, never on an
        // already-cleared page — reliable on any status.
        let bodyIsDocument = lowerBody.contains("<html") || lowerBody.contains("<!doctype")

        if lowerBody.contains("__cf_chl_")
            || lowerBody.contains("cf_chl_opt")
            || lowerBody.contains("enable javascript and cookies")
            || (bodyIsDocument && lowerBody.contains("check.ddos-guard.net"))
            || (bodyIsDocument && lowerBody.contains("/.well-known/ddos-guard/"))
            || (lowerBody.contains("just a moment") && lowerBody.contains("cloudflare")) {
            return true
        }

        // Cloudflare injects its challenge-platform / Turnstile scripts (and a "cloudflare"
        // footer) into normal, already-solved responses too, and provider pages routinely mention
        // "ddos-guard" — so these markers only signal a wall when the response is itself a block.
        // Gating on status is what stops a solved 200 content page (which still carries
        // challenge-platform) from being misread as still-challenged: the re-solve loop that then
        // tripped Cloudflare's 429 rate limit.
        if isBlockedStatus {
            let hasProviderMarker = lowerBody.contains("challenges.cloudflare.com")
                || lowerBody.contains("cf-turnstile")
                || lowerBody.contains("challenge-platform")
                || lowerBody.contains("cf-spinner")
                || lowerBody.contains("jschl")
                || (lowerBody.contains("ddos-guard")
                    && (lowerBody.contains("checking your browser")
                        || lowerBody.contains("please wait")))
            if hasProviderMarker {
                return true
            }
        }

        // A generic HTML 403/429/503 served by Cloudflare is commonly a rate limit (Error 1015),
        // access denial (1020), or origin failure. Those pages carry Server/CF-Ray headers and a
        // Cloudflare footer but do not contain a challenge a user can complete.
        return false
    }

    static func headersDictionary(from response: HTTPURLResponse?) -> [String: String] {
        guard let response else { return [:] }
        return response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            result[String(describing: pair.key)] = String(describing: pair.value)
        }
    }
}
#else
import WebKit

import SwiftUI
import UIKit

enum CloudflareBypassError: Error {
    case timeout
}

extension Notification.Name {
    static let cloudflareBypassSolved = Notification.Name("CloudflareBypassSolved")
}

final class CloudflareBypassManager: ObservableObject {
    static let shared = CloudflareBypassManager()

    @Published private(set) var activeBypassWebView: WKWebView?
    @Published private(set) var pendingVerificationURL: URL?

    private struct CachedBypass: Codable {
        let cookieHeader: String
        let userAgent: String
        let expires: Date
    }

    private enum Keys {
        static let persistedCache = "serviceCloudflareBypassCache"
        static let interactiveHosts = "serviceCloudflareInteractiveHosts"
    }

    private let lock = NSLock()
    private var cache: [String: CachedBypass] = [:]
    private var inProgressHosts: Set<String> = []
    private var bypassWebViews: [String: WKWebView] = [:]

    /// Hosts observed to require an interactive tap — the silent phase failed and we had to
    /// show the box. Persisted so that once cf_clearance expires, the next challenge on that
    /// host shows the box immediately instead of hanging through the whole silent budget first.
    private var interactiveHosts: Set<String> = []

    /// The single host currently allowed to own the silent host window / visible sheet
    /// singletons in `triggerBypass`. `inProgressHosts` only dedupes the SAME host; this
    /// additionally serializes DIFFERENT hosts so two concurrent challenges (e.g. from Auto
    /// Mode's concurrent per-source search) can't tear down or strand each other's flow.
    private var activeFlowHost: String?

    /// Cloudflare's non-interactive JS challenge ("Just a moment...") and low-risk managed
    /// challenges resolve on their own within a few seconds of real JS execution — no tap
    /// required. Only an explicit Turnstile widget needs a human. Budgets below make the
    /// common case silent and fast, and only escalate to visible UI for the genuine minority.
    private static let silentSolveBudgetSeconds: TimeInterval = 5
    private static let totalSolveBudgetSeconds: TimeInterval = 45
    private static let maximumSharedCookieCount = 64
    private static let maximumSharedCookieNameBytes = 64
    private static let maximumSharedCookieValueBytes = 4 * 1_024
    private static let maximumSharedCookieHeaderBytes = 32 * 1_024

    private init() {
        loadPersistedCache()
        loadInteractiveHosts()
    }

    private func isKnownInteractiveHost(_ host: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return interactiveHosts.contains(host)
    }

    private func markHostInteractive(_ host: String) {
        lock.lock()
        let inserted = interactiveHosts.insert(host).inserted
        let snapshot = Array(interactiveHosts)
        lock.unlock()
        guard inserted else { return }
        UserDefaults.standard.set(snapshot, forKey: Keys.interactiveHosts)
        Logger.shared.log("CloudflareBypass: host marked interactive host=\(host)", type: "Service")
    }

    private func loadInteractiveHosts() {
        let stored = UserDefaults.standard.stringArray(forKey: Keys.interactiveHosts) ?? []
        lock.lock()
        interactiveHosts = Set(stored)
        lock.unlock()
    }

    func applyCachedBypass(to request: inout URLRequest, for url: URL) {
        guard let host = normalizedHost(from: url),
              let entry = cachedEntry(for: host),
              let vettedCookieHeader = Self.vettedSharedCookieHeader(from: entry.cookieHeader) else {
            return
        }

        let existingCookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
        let mergedCookie = mergeCookieHeaders(existingCookie, vettedCookieHeader)
        request.setValue(mergedCookie, forHTTPHeaderField: "Cookie")

        if !entry.userAgent.isEmpty {
            request.setValue(entry.userAgent, forHTTPHeaderField: "User-Agent")
        }

        EclipseLedgerOnce.emit(
            scope: "cloudflare-applied-session",
            signature: "\(host)|\(cookieNameSummary(vettedCookieHeader))|\(!existingCookie.isEmpty)|\(userAgentProfile(entry.userAgent))"
        ) {
            Logger.shared.log(
                "CloudflareBypass: applied cached session host=\(host) cachedCookies=\(cookiePairCount(in: vettedCookieHeader)) cookieNames=\(cookieNameSummary(vettedCookieHeader)) mergedWithExisting=\(!existingCookie.isEmpty) userAgent=\(!entry.userAgent.isEmpty) uaProfile=\(userAgentProfile(entry.userAgent))",
                type: "Service"
            )
        }
    }

    func headersByApplyingCachedBypass(_ headers: [String: String], for url: URL) -> [String: String] {
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        applyCachedBypass(to: &request, for: url)
        return request.allHTTPHeaderFields ?? headers
    }

    func fullCookieHeader(for host: String) -> String? {
        cachedEntry(for: normalizedHost(host))?.cookieHeader
    }

    func bypassUserAgent(for host: String) -> String? {
        let userAgent = cachedEntry(for: normalizedHost(host))?.userAgent ?? ""
        return userAgent.isEmpty ? nil : userAgent
    }

    func store(cookieHeader: String, userAgent: String, for host: String) {
        let normalizedHost = normalizedHost(host)
        guard let cookieHeader = Self.vettedSharedCookieHeader(from: cookieHeader) else {
            return
        }

        lock.lock()
        cache[normalizedHost] = CachedBypass(
            cookieHeader: cookieHeader,
            userAgent: userAgent,
            // Retain a browser clearance until the provider actually rejects it. The old
            // one-hour client timeout discarded valid iPad sessions and prompted again.
            expires: Date().addingTimeInterval(24 * 60 * 60)
        )
        lock.unlock()

        persistCache()
        Logger.shared.log(
            "CloudflareBypass: stored solved session host=\(normalizedHost) cookies=\(cookiePairCount(in: cookieHeader)) cookieNames=\(cookieNameSummary(cookieHeader)) userAgent=\(!userAgent.isEmpty) uaProfile=\(userAgentProfile(userAgent)) ttlSeconds=86400",
            type: "Service"
        )
        NotificationCenter.default.post(name: .cloudflareBypassSolved, object: normalizedHost)
    }

    @MainActor
    func flagPendingVerification(for url: URL) {
        guard let host = normalizedHost(from: url) else { return }
        pendingVerificationURL = url
        Logger.shared.log(
            "CloudflareBypass: pending manual verification host=\(host)",
            type: "Service"
        )
    }

    /// Starts a new browser-backed solve after a request proves that its reused clearance is no
    /// longer accepted by the server. Callers may pass the Cookie header used by that rejected
    /// request so a late response cannot discard a newer session established in the meantime.
    /// This deliberately performs no media fetch; download/player transports retry themselves
    /// after the replacement session is ready.
    @MainActor
    @discardableResult
    func refreshSessionAfterChallenge(
        for url: URL,
        rejectedCookieHeader: String? = nil
    ) async -> Bool {
        guard let host = normalizedHost(from: url) else { return false }

        if retainedSessionIsNewer(than: rejectedCookieHeader, for: host) {
            Logger.shared.log(
                "CloudflareBypass: ignored rejection from older session host=\(host); newer session retained",
                type: "Service"
            )
            return true
        }

        if inProgressHosts.contains(host) {
            Logger.shared.log(
                "CloudflareBypass: confirmed challenge joining active replacement flow host=\(host)",
                type: "Service"
            )
        } else {
            invalidateRejectedSession(
                for: url,
                rejectedCookieHeader: rejectedCookieHeader,
                reason: "confirmed-challenge"
            )
        }

        let presentation: BypassPresentation = isKnownInteractiveHost(host) ? .visible : .silentThenEscalate
        return (try? await runBypassFlow(for: url, presentation: presentation)) ?? false
    }

    func recoverChallengedRequest(
        for url: URL,
        method: String,
        body: Data?,
        extraHeaders: [String: String],
        allowRedirects: Bool
    ) async -> (data: Data, response: HTTPURLResponse)? {
        let recoveryStartedAt = Date()
        Logger.shared.log(
            "CloudflareBypass: recovery requested host=\(redactedHost(url)) method=\(method) bodyBytes=\(body?.count ?? 0) extraHeaders=\(extraHeaders.count) redirects=\(allowRedirects)",
            type: "Service"
        )

        if let recovered = await retryWithSolvedSession(
            for: url,
            method: method,
            body: body,
            extraHeaders: extraHeaders,
            allowRedirects: allowRedirects
        ) {
            Logger.shared.log(
                "CloudflareBypass: recovered with existing solved session host=\(redactedHost(url)) status=\(recovered.response.statusCode) bytes=\(recovered.data.count) elapsedMs=\(elapsedMilliseconds(since: recoveryStartedAt))",
                type: "Service"
            )
            return recovered
        }

        Logger.shared.log(
            "CloudflareBypass: attempting automatic verification host=\(redactedHost(url))",
            type: "Service"
        )
        // Most Cloudflare/DDoS-Guard challenges resolve on their own with no UI. When one
        // doesn't (typically an interactive Turnstile checkbox), attemptAutomaticBypass shows
        // the verification box ITSELF (via a top-level window) and waits for the user to solve
        // it — this recovery path fires deep in the fetch layer, during search as well as stream
        // extraction, where no button UI is reachable, so it can't rely on the caller to surface
        // it. It returns false only if the user cancels or the whole budget elapses unsolved.
        guard await attemptAutomaticBypass(for: url) else {
            await flagPendingVerification(for: url)
            Logger.shared.log(
                "CloudflareBypass: automatic verification unavailable host=\(redactedHost(url)) elapsedMs=\(elapsedMilliseconds(since: recoveryStartedAt))",
                type: "Service"
            )
            return nil
        }

        let recovered = await retryWithSolvedSession(
            for: url,
            method: method,
            body: body,
            extraHeaders: extraHeaders,
            allowRedirects: allowRedirects
        )

        if recovered == nil {
            await flagPendingVerification(for: url)
            Logger.shared.log(
                "CloudflareBypass: recovery unavailable after silent verification host=\(redactedHost(url)) elapsedMs=\(elapsedMilliseconds(since: recoveryStartedAt))",
                type: "Service"
            )
        } else if let recovered {
            Logger.shared.log(
                "CloudflareBypass: recovered after silent verification host=\(redactedHost(url)) status=\(recovered.response.statusCode) bytes=\(recovered.data.count) elapsedMs=\(elapsedMilliseconds(since: recoveryStartedAt))",
                type: "Service"
            )
        }
        return recovered
    }

    func retryWithSolvedSession(
        for url: URL,
        method: String,
        body: Data?,
        extraHeaders: [String: String],
        allowRedirects: Bool
    ) async -> (data: Data, response: HTTPURLResponse)? {
        let retryStartedAt = Date()
        guard let host = normalizedHost(from: url) else {
            Logger.shared.log("CloudflareBypass: retry skipped because URL has no host", type: "Service")
            return nil
        }

        let sessionInfo: (cookieHeader: String, userAgent: String, source: String)?
        if let liveInfo = await liveBypassSessionInfo(for: host) {
            sessionInfo = (liveInfo.cookieHeader, liveInfo.userAgent, "liveWebView")
        } else if let entry = cachedEntry(for: host) {
            sessionInfo = (entry.cookieHeader, entry.userAgent, "cache")
        } else {
            sessionInfo = nil
        }

        guard let sessionInfo else {
            Logger.shared.log("CloudflareBypass: no solved session available host=\(host)", type: "Service")
            return nil
        }

        Logger.shared.log(
            "CloudflareBypass: retrying challenged request host=\(host) source=\(sessionInfo.source) method=\(method) bodyBytes=\(body?.count ?? 0) cookies=\(cookiePairCount(in: sessionInfo.cookieHeader)) cookieNames=\(cookieNameSummary(sessionInfo.cookieHeader)) uaProfile=\(userAgentProfile(sessionInfo.userAgent)) redirects=\(allowRedirects)",
            type: "Service"
        )

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (key, value) in extraHeaders where !["cookie", "user-agent"].contains(key.lowercased()) {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if !sessionInfo.cookieHeader.isEmpty {
            request.setValue(sessionInfo.cookieHeader, forHTTPHeaderField: "Cookie")
        }
        if !sessionInfo.userAgent.isEmpty {
            request.setValue(sessionInfo.userAgent, forHTTPHeaderField: "User-Agent")
        }

        let session = URLSession.fetchData(allowRedirects: allowRedirects)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.boundedData(
                for: request,
                maximumResponseBytes: 10_000_000
            )
            guard let httpResponse = response as? HTTPURLResponse else { return nil }
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            if Self.isChallengeResponse(
                status: httpResponse.statusCode,
                body: bodyText,
                headers: Self.headersDictionary(from: httpResponse)
            ) {
                if sessionInfo.source == "liveWebView",
                   let recovered = await browserRecoveredResponse(
                    for: url,
                    host: host,
                    reloadAfterRejectedReuse: true
                   ) {
                    Logger.shared.log(
                        "CloudflareBypass: recovered challenged request from live browser document host=\(host) status=\(recovered.response.statusCode) bytes=\(recovered.data.count) elapsedMs=\(elapsedMilliseconds(since: retryStartedAt))",
                        type: "Service"
                    )
                    return recovered
                }
                await invalidateRejectedSession(
                    for: url,
                    rejectedCookieHeader: sessionInfo.cookieHeader,
                    reason: "session-retry-challenged"
                )
                Logger.shared.log(
                    "CloudflareBypass: solved session still challenged host=\(host) elapsedMs=\(elapsedMilliseconds(since: retryStartedAt)) \(Self.challengeDebugSummary(status: httpResponse.statusCode, body: bodyText, headers: Self.headersDictionary(from: httpResponse))) rejectedSessionCleared=true",
                    type: "Service"
                )
                return nil
            }
            Logger.shared.log(
                "CloudflareBypass: session retry succeeded host=\(redactedHost(url)) source=\(sessionInfo.source) status=\(httpResponse.statusCode) bytes=\(data.count) elapsedMs=\(elapsedMilliseconds(since: retryStartedAt))",
                type: "Service"
            )
            return (data, httpResponse)
        } catch {
            Logger.shared.log(
                "CloudflareBypass: session retry failed host=\(redactedHost(url)) elapsedMs=\(elapsedMilliseconds(since: retryStartedAt)) reason=\(servicePinnedNetworkErrorToken(error))",
                type: "Error"
            )
            return nil
        }
    }

    private enum BypassPresentation: Equatable {
        /// Automatic recovery path: try invisibly first, and if the silent budget elapses
        /// unsolved, move the challenge into a visible sheet so the user can complete it. This
        /// is what actually resolves interactive Turnstile challenges without any UI wiring at
        /// the call site.
        case silentThenEscalate
        /// Show the sheet immediately: used by the manual "Verify Cloudflare" action and for
        /// hosts already known to require an interactive tap (skips the wasted silent phase).
        case visible
    }

    /// Automatic recovery path used by `recoverChallengedRequest`. Tries to solve invisibly
    /// within the silent budget; if that isn't enough (typically a genuine interactive
    /// Turnstile checkbox), it escalates to a visible sheet and waits for the user to solve it.
    /// Returns true once solved, false if the user cancels or the whole budget elapses.
    @MainActor
    @discardableResult
    func attemptAutomaticBypass(for url: URL) async -> Bool {
        guard let host = normalizedHost(from: url) else { return false }
        // A host we've already learned needs a human tap skips straight to the box instead of
        // burning the silent budget it can never satisfy; everything else tries silently first.
        let presentation: BypassPresentation = isKnownInteractiveHost(host) ? .visible : .silentThenEscalate
        return (try? await runBypassFlow(for: url, presentation: presentation)) ?? false
    }

    /// User-initiated verification: shows the bypass sheet immediately and waits for the user
    /// to complete it. Intended to be called from a "Verify Cloudflare" affordance driven by
    /// `pendingVerificationURL`.
    @MainActor
    func triggerBypass(for url: URL) async throws {
        // Cancellation (or any other non-solved exit) makes runBypassFlow return false rather
        // than throw, since it's a normal, expected outcome for the automatic path — but
        // callers of this .visible entry point need throws to mean "not solved" so they don't
        // mistake a cancelled/unsolved sheet for success and retry with no usable session.
        // This entry point is only surfaced after a request was challenged. A cached entry here
        // is therefore evidence of rejected reuse, not proof that verification is still valid.
        // Clear both the persisted header and its retained browser before runBypassFlow performs
        // its normal cache fast-path.
        let host = normalizedHost(from: url)
        if let host, inProgressHosts.contains(host) {
            Logger.shared.log(
                "CloudflareBypass: manual verification joining active replacement flow host=\(host)",
                type: "Service"
            )
        } else {
            invalidateRejectedSession(
                for: url,
                rejectedCookieHeader: nil,
                reason: "manual-verification"
            )
        }
        guard try await runBypassFlow(for: url, presentation: .visible) else {
            throw CloudflareBypassError.timeout
        }
    }

    @MainActor
    private func runBypassFlow(for url: URL, presentation: BypassPresentation) async throws -> Bool {
        let requestedAt = Date()
        guard let host = normalizedHost(from: url) else { return false }
        if cachedEntry(for: host) != nil {
            Logger.shared.log("CloudflareBypass: verification skipped because cache exists host=\(host)", type: "Service")
            return true
        }
        if inProgressHosts.contains(host) {
            Logger.shared.log("CloudflareBypass: verification already in progress; waiting host=\(host)", type: "Service")
            var existingFlowFinished = false
            for _ in 0..<120 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if !inProgressHosts.contains(host) {
                    existingFlowFinished = true
                    break
                }
            }
            if let cached = cachedEntry(for: host), !cached.cookieHeader.isEmpty {
                Logger.shared.log("CloudflareBypass: shared verification produced solved session host=\(host) elapsedMs=\(elapsedMilliseconds(since: requestedAt)) cookieNames=\(cookieNameSummary(cached.cookieHeader)) uaProfile=\(userAgentProfile(cached.userAgent))", type: "Service")
                return true
            }
            if !existingFlowFinished {
                Logger.shared.log("CloudflareBypass: verification wait timed out host=\(host) elapsedMs=\(elapsedMilliseconds(since: requestedAt))", type: "Service")
                throw CloudflareBypassError.timeout
            }
            // The other flow finished without a usable session. Do not silently return and strand
            // every waiter; let this request open a fresh verification flow.
            Logger.shared.log("CloudflareBypass: shared verification ended unsolved; retrying host=\(host) elapsedMs=\(elapsedMilliseconds(since: requestedAt))", type: "Service")
        }

        inProgressHosts.insert(host)
        defer { inProgressHosts.remove(host) }

        // The silent host and the visible sheet are both single-slot: only one host's flow may
        // own them at a time. inProgressHosts above only dedupes the SAME host; two DIFFERENT
        // challenged hosts can otherwise reach here concurrently (e.g. Auto Mode's concurrent
        // per-source search) and stomp each other's window. Queue behind whichever flow is
        // currently running rather than silently losing the race.
        if activeFlowHost != nil {
            Logger.shared.log("CloudflareBypass: waiting for another host's verification slot host=\(host) blockedBy=\(activeFlowHost ?? "unknown")", type: "Service")
            var acquiredSlot = false
            for _ in 0..<Int(Self.totalSolveBudgetSeconds * 4) {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if activeFlowHost == nil {
                    acquiredSlot = true
                    break
                }
            }
            if !acquiredSlot {
                Logger.shared.log("CloudflareBypass: gave up waiting for verification slot host=\(host)", type: "Service")
                throw CloudflareBypassError.timeout
            }
        }
        activeFlowHost = host
        defer { activeFlowHost = nil }

        // Only this call may touch activeBypassWebView / the silent host / the visible window
        // for the rest of this function, so the budgets below measure this flow's own runtime,
        // not time spent waiting behind another host or another same-host caller.
        let verificationStartedAt = Date()

        guard await ServiceBrowserAutomationPolicy.permitsNavigation(
            to: url,
            allowsLocalDocument: false
        ) else {
            Logger.shared.log(
                "CloudflareBypass: verification target rejected host=\(host) reason=browser-policy",
                type: "Service"
            )
            flagPendingVerification(for: url)
            return false
        }

        let webView = makeBypassWebView()
        // Load the exact URL that got challenged, not the bare host. cf_clearance is domain-wide,
        // but many providers (e.g. AnimePahe) only present the interactive Turnstile widget — the
        // "blue box" the user actually taps — on the specific deep/API path that was walled; the
        // landing page often isn't challenged at all, so loading it would show no widget to solve.
        // Autoplay video escaping into the system AVPlayer is prevented separately, by
        // makeBypassWebView's `mediaTypesRequiringUserActionForPlayback = .all`, so loading a
        // content/player URL here is safe.
        let verificationURL = url
        Logger.shared.log("CloudflareBypass: verification web view opened host=\(host) presentation=\(presentation)", type: "Service")

        activeBypassWebView = webView
        var isVisible = presentation == .visible
        switch presentation {
        case .visible:
            CloudflareBypassWindowController.shared.show()
        case .silentThenEscalate:
            // Attach to a real, live, correctly-sized window but keep it invisible: most
            // Cloudflare/DDoS-Guard JS challenges resolve on their own in a few seconds and
            // never need to interrupt the user.
            CloudflareBypassSilentHost.shared.attach(webView)
        }
        defer {
            activeBypassWebView = nil
            CloudflareBypassSilentHost.shared.detach(webView)
            CloudflareBypassWindowController.shared.hide()
        }

        webView.load(URLRequest(url: verificationURL))
        Logger.shared.log("CloudflareBypass: verification web view loading host=\(host) target=\(Self.redactedURL(verificationURL.absoluteString))", type: "Service")

        var attempt = 0
        var lastLoggedAt = verificationStartedAt
        while Date().timeIntervalSince(verificationStartedAt) < Self.totalSolveBudgetSeconds {
            attempt += 1
            let elapsed = Date().timeIntervalSince(verificationStartedAt)
            try await Task.sleep(nanoseconds: Self.pollingIntervalNanoseconds(elapsed: elapsed))
            guard activeBypassWebView != nil else {
                Logger.shared.log("CloudflareBypass: verification cancelled host=\(host)", type: "Service")
                flagPendingVerification(for: url)
                return false
            }
            if let solved = await captureSolvedSessionIfPresent(
                originalHost: host,
                in: webView,
                retainsWebView: true
            ) {
                Logger.shared.log(
                    "CloudflareBypass: verification solved host=\(host) resolvedHost=\(solved.resolvedHost ?? "nil") cachedHosts=\(solved.cachedHosts.joined(separator: ",")) cookieNames=\(cookieNameSummary(solved.cookieHeader)) uaProfile=\(userAgentProfile(solved.userAgent)) elapsedMs=\(elapsedMilliseconds(since: verificationStartedAt)) shownInteractiveUI=\(isVisible)",
                    type: "Service"
                )
                return true
            }

            if presentation == .silentThenEscalate, !isVisible, elapsed >= Self.silentSolveBudgetSeconds {
                // The silent attempt didn't resolve on its own, so this challenge needs a human
                // (typically an interactive Turnstile checkbox). Surface the SAME flow in a
                // visible sheet and reload the page so the widget renders and is tappable in the
                // now-interactive window, and remember this host so its next challenge skips the
                // wasted silent phase entirely.
                Logger.shared.log("CloudflareBypass: escalating to visible verification host=\(host) elapsedMs=\(elapsedMilliseconds(since: verificationStartedAt))", type: "Service")
                markHostInteractive(host)
                CloudflareBypassSilentHost.shared.detach(webView)
                CloudflareBypassWindowController.shared.show()
                webView.load(URLRequest(url: verificationURL))
                isVisible = true
            }

            if Date().timeIntervalSince(lastLoggedAt) >= 5 {
                lastLoggedAt = Date()
                let cookieHeader = await allCookiesHeader(for: host, in: webView) ?? ""
                let html = await documentHTML(for: webView)
                Logger.shared.log(
                    "CloudflareBypass: verification waiting host=\(host) attempt=\(attempt) elapsedMs=\(elapsedMilliseconds(since: verificationStartedAt)) solvedCookie=\(Self.isSolvedCookieHeader(cookieHeader)) cookieNames=\(cookieNameSummary(cookieHeader)) challengeDocument=\(Self.isChallengeResponse(status: 200, body: html)) htmlBytes=\(html.utf8.count) markers=\(Self.challengeMarkerSummary(from: html)) visible=\(isVisible)",
                    type: "Service"
                )
            }
        }

        Logger.shared.log("CloudflareBypass: verification timed out host=\(host) elapsedMs=\(elapsedMilliseconds(since: verificationStartedAt)) presentation=\(presentation)", type: "Service")
        flagPendingVerification(for: url)
        if presentation == .visible {
            throw CloudflareBypassError.timeout
        }
        return false
    }

    /// Front-loads polling so a fast, silent solve (the common case) is detected within a
    /// couple hundred milliseconds instead of up to 500ms late, while keeping the same
    /// eventual cadence for slow challenges so we don't spin needlessly.
    private static func pollingIntervalNanoseconds(elapsed: TimeInterval) -> UInt64 {
        let seconds: TimeInterval
        if elapsed < 5 {
            seconds = 0.2
        } else if elapsed < 20 {
            seconds = 0.4
        } else {
            seconds = 0.75
        }
        return UInt64(seconds * 1_000_000_000)
    }

    @MainActor
    func cancelActiveBypass() {
        if let host = activeBypassWebView?.url?.host?.lowercased() ?? pendingVerificationURL?.host?.lowercased() {
            Logger.shared.log("CloudflareBypass: user cancelled verification host=\(host)", type: "Service")
        } else {
            Logger.shared.log("CloudflareBypass: user cancelled verification", type: "Service")
        }
        activeBypassWebView = nil
    }

    static func isChallengeResponse(status: Int, body: String, headers: [String: String] = [:]) -> Bool {
        let lowerBody = body.lowercased()
        let isBlockedStatus = [403, 429, 503].contains(status)
        let lowerHeaders = headers.reduce(into: [String: String]()) { result, pair in
            result[pair.key.lowercased()] = pair.value.lowercased()
        }

        // Cloudflare explicitly labels challenge responses with this header. Unlike `Server:
        // cloudflare` and `CF-Ray`, it is not also present on ordinary rate-limit, access-denied,
        // or origin-error pages that no amount of human verification can solve.
        if lowerHeaders["cf-mitigated"]?.contains("challenge") == true {
            return true
        }

        // Tokens that appear only on the actual interstitial/challenge document, never on an
        // already-cleared page — reliable on any status.
        let bodyIsDocument = lowerBody.contains("<html") || lowerBody.contains("<!doctype")

        if lowerBody.contains("__cf_chl_")
            || lowerBody.contains("cf_chl_opt")
            || lowerBody.contains("enable javascript and cookies")
            || (bodyIsDocument && lowerBody.contains("check.ddos-guard.net"))
            || (bodyIsDocument && lowerBody.contains("/.well-known/ddos-guard/"))
            || (lowerBody.contains("just a moment") && lowerBody.contains("cloudflare")) {
            return true
        }

        // Cloudflare injects its challenge-platform / Turnstile scripts (and a "cloudflare"
        // footer) into normal, already-solved responses too, and provider pages routinely mention
        // "ddos-guard" — so these markers only signal a wall when the response is itself a block.
        // Gating on status is what stops a solved 200 content page (which still carries
        // challenge-platform) from being misread as still-challenged: the re-solve loop that then
        // tripped Cloudflare's 429 rate limit.
        if isBlockedStatus {
            let hasProviderMarker = lowerBody.contains("challenges.cloudflare.com")
                || lowerBody.contains("cf-turnstile")
                || lowerBody.contains("challenge-platform")
                || lowerBody.contains("cf-spinner")
                || lowerBody.contains("jschl")
                || (lowerBody.contains("ddos-guard")
                    && (lowerBody.contains("checking your browser")
                        || lowerBody.contains("please wait")))
            if hasProviderMarker {
                return true
            }
        }

        // A generic HTML 403/429/503 served by Cloudflare is commonly a rate limit (Error 1015),
        // access denial (1020), or origin failure. Those pages carry Server/CF-Ray headers and a
        // Cloudflare footer but do not contain a challenge a user can complete.
        return false
    }

    static func headersDictionary(from response: HTTPURLResponse?) -> [String: String] {
        guard let response else { return [:] }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            headers[String(describing: key)] = String(describing: value)
        }
        return headers
    }

    @MainActor
    func captureSolvedCookies(from webView: WKWebView, for url: URL?) {
        guard let url, let host = normalizedHost(from: url) else { return }
        Task { @MainActor in
            if let solved = await captureSolvedSessionIfPresent(
                originalHost: host,
                in: webView,
                retainsWebView: false
            ) {
                Logger.shared.log(
                    "CloudflareBypass: captured solved cookies from web view host=\(host) resolvedHost=\(solved.resolvedHost ?? "nil") cachedHosts=\(solved.cachedHosts.joined(separator: ",")) cookieNames=\(cookieNameSummary(solved.cookieHeader)) uaProfile=\(userAgentProfile(solved.userAgent))",
                    type: "Service"
                )
            }
        }
    }

    private func cachedEntry(for host: String) -> CachedBypass? {
        lock.lock()
        let entry = cache[host]
        if let entry, entry.expires <= Date() {
            cache.removeValue(forKey: host)
            lock.unlock()
            persistCache()
            Logger.shared.log("CloudflareBypass: cached session expired host=\(host)", type: "Service")
            return nil
        }
        lock.unlock()
        return entry
    }

    private func removeCachedEntry(for host: String) {
        lock.lock()
        let removed = cache.removeValue(forKey: host) != nil
        lock.unlock()
        if removed {
            persistCache()
            Logger.shared.log("CloudflareBypass: removed cached session host=\(host)", type: "Service")
        }
    }

    /// Returns true when a challenge response belongs to an older request and the cache now
    /// contains a different clearance. Cookie values are compared only in memory and never
    /// emitted to logs.
    private func retainedSessionIsNewer(than rejectedCookieHeader: String?, for host: String) -> Bool {
        guard let rejectedCookieHeader,
              !rejectedCookieHeader.isEmpty,
              let current = cachedEntry(for: host) else {
            return false
        }

        let rejectedClearance = clearanceCookieFingerprint(in: rejectedCookieHeader)
        let currentClearance = clearanceCookieFingerprint(in: current.cookieHeader)
        guard !rejectedClearance.isEmpty, !currentClearance.isEmpty else { return false }
        return rejectedClearance != currentClearance
    }

    /// Drops every retained alias of a browser session that the server just rejected. This is
    /// intentionally MainActor-isolated because bypassWebViews contains UIKit/WebKit objects.
    /// If the caller supplies the rejected Cookie header, shared-jar cleanup only deletes those
    /// exact clearance tokens, protecting a newer solve from a late response.
    @MainActor
    private func invalidateRejectedSession(
        for url: URL,
        rejectedCookieHeader: String?,
        reason: String
    ) {
        guard let host = normalizedHost(from: url) else { return }

        if retainedSessionIsNewer(than: rejectedCookieHeader, for: host) {
            Logger.shared.log(
                "CloudflareBypass: skipped rejected-session cleanup because a newer session exists host=\(host) reason=\(reason)",
                type: "Service"
            )
            return
        }

        let staleWebView = bypassWebViews[host]
        var invalidatedHosts = Set([host])
        if let staleWebView {
            for (candidateHost, candidateWebView) in bypassWebViews where candidateWebView === staleWebView {
                invalidatedHosts.insert(candidateHost)
            }
        }

        for candidateHost in invalidatedHosts {
            bypassWebViews.removeValue(forKey: candidateHost)
            removeCachedEntry(for: candidateHost)
        }
        staleWebView?.stopLoading()

        let rejectedClearance: [String: String]
        if let rejectedCookieHeader {
            rejectedClearance = clearanceCookieFingerprint(in: rejectedCookieHeader)
        } else {
            rejectedClearance = [:]
        }
        let sharedCookieStorage = HTTPCookieStorage.shared
        var removedSharedClearanceCount = 0
        for cookie in sharedCookieStorage.cookies ?? [] where Self.isClearanceCookieName(cookie.name) {
            let domain = cookie.domain
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            let domainMatches = invalidatedHosts.contains { candidateHost in
                candidateHost == domain
                    || candidateHost.hasSuffix("." + domain)
                    || domain.hasSuffix("." + candidateHost)
            }
            guard domainMatches else { continue }

            if !rejectedClearance.isEmpty,
               rejectedClearance[cookie.name.lowercased()] != cookie.value {
                continue
            }
            sharedCookieStorage.deleteCookie(cookie)
            removedSharedClearanceCount += 1
        }

        Logger.shared.log(
            "CloudflareBypass: invalidated rejected session host=\(host) aliases=\(invalidatedHosts.count) retainedBrowser=\(staleWebView != nil) sharedClearanceCookiesRemoved=\(removedSharedClearanceCount) reason=\(reason)",
            type: "Service"
        )
    }

    private func persistCache() {
        lock.lock()
        let live = cache.filter { $0.value.expires > Date() }
        cache = live
        let data = try? JSONEncoder().encode(live)
        lock.unlock()

        if let data {
            UserDefaults.standard.set(data, forKey: Keys.persistedCache)
        }
    }

    private func loadPersistedCache() {
        guard let data = UserDefaults.standard.data(forKey: Keys.persistedCache),
              let decoded = try? JSONDecoder().decode([String: CachedBypass].self, from: data) else { return }
        cache = decoded.reduce(into: [String: CachedBypass]()) { result, pair in
            guard pair.value.expires > Date(),
                  let vettedHeader = Self.vettedSharedCookieHeader(
                    from: pair.value.cookieHeader
                  ) else {
                return
            }
            result[pair.key] = CachedBypass(
                cookieHeader: vettedHeader,
                userAgent: pair.value.userAgent,
                expires: pair.value.expires
            )
        }
        #if os(iOS)
        // A short-lived build used an iPhone UA for iPad verification. Those cookies are tied to
        // that profile and can make AnimePahe return its landing page instead of the requested
        // episode. Start a native iPad verification rather than replaying that incompatible cache.
        if UIDevice.current.userInterfaceIdiom == .pad {
            let before = cache.count
            cache = cache.filter { !$0.value.userAgent.contains("(iPhone;") }
            if cache.count != before {
                persistCache()
                Logger.shared.log("CloudflareBypass: discarded incompatible iPhone-profile cache on iPad", type: "Service")
            }
        }
        #endif
        persistCache()
        Logger.shared.log("CloudflareBypass: loaded persisted sessions count=\(cache.count)", type: "Service")
    }

    @MainActor
    private func liveBypassSessionInfo(for host: String) async -> (cookieHeader: String, userAgent: String)? {
        guard let webView = bypassWebViews[host],
              let cookieHeader = await allCookiesHeader(for: host, in: webView),
              !cookieHeader.isEmpty else { return nil }
        return (cookieHeader, await userAgent(for: webView))
    }

    @MainActor
    private func browserRecoveredResponse(
        for url: URL,
        host: String,
        reloadAfterRejectedReuse: Bool
    ) async -> (data: Data, response: HTTPURLResponse)? {
        let browserRecoveryStartedAt = Date()
        guard let webView = bypassWebViews[host],
              await ServiceBrowserAutomationPolicy.permitsNavigation(
                to: url,
                allowsLocalDocument: false
              ) else {
            Logger.shared.log(
                "CloudflareBypass: browser recovery rejected host=\(host) reason=browser-policy",
                type: "Service"
            )
            return nil
        }

        var previousDocumentMarker: String?
        if reloadAfterRejectedReuse {
            // URLSession just proved that this browser session's reused clearance was rejected.
            // Mark the currently retained DOM, then navigate even when its URL already matches.
            // Without this freshness check an old, previously solved /play/ document can be
            // accepted immediately and the app never opens a new human verification flow.
            previousDocumentMarker = UUID().uuidString
            if let previousDocumentMarker {
                await setBrowserRecoveryMarker(previousDocumentMarker, in: webView)
            }
            Logger.shared.log(
                "CloudflareBypass: browser recovery reloading rejected session host=\(host) target=\(Self.redactedURL(url.absoluteString))",
                type: "Service"
            )
            webView.load(URLRequest(url: url))
        } else if !browserURL(webView.url, matchesRequestedURL: url, host: host) {
            Logger.shared.log(
                "CloudflareBypass: browser recovery navigating host=\(host) from=\(Self.redactedURL(webView.url?.absoluteString ?? "nil")) to=\(Self.redactedURL(url.absoluteString))",
                type: "Service"
            )
            webView.load(URLRequest(url: url))
        }

        // iPad WebKit often reaches the solved cookie several seconds before the provider's
        // JavaScript finishes inserting the playable iframe. Give the completed document time to
        // stabilize instead of accepting an incomplete /play/ page or immediately failing it.
        for attempt in 1...40 {
            // Read the freshness sentinel first. If this still comes from the retained document,
            // nothing else sampled in this iteration is eligible for recovery. Once navigation
            // replaces that JavaScript world, subsequent document reads belong to the new page.
            let currentDocumentMarker = await browserRecoveryMarker(in: webView)
            let isFreshDocument = previousDocumentMarker == nil || currentDocumentMarker != previousDocumentMarker
            let currentURL = webView.url
            let html = await documentHTML(for: webView)
            let readyState = await documentReadyState(for: webView)
            let bodyBytes = html.data(using: .utf8)?.count ?? 0
            let urlMatches = browserURL(currentURL, matchesRequestedURL: url, host: host)
            let isChallenge = Self.isChallengeResponse(status: 200, body: html)
            let isUsefulDocument = browserDocumentLooksUseful(html, for: url)
            let hasPlayableEmbed = browserDocumentHasPlayableEmbed(html, for: url)
            let isPlaybackDocument = url.path.lowercased().contains("/play/")
            let isDocumentComplete = readyState.caseInsensitiveCompare("complete") == .orderedSame
            let hasCompletedNavigation = !webView.isLoading
            let hasRequiredContent = isPlaybackDocument ? hasPlayableEmbed : isUsefulDocument

            if isFreshDocument,
               urlMatches,
               hasCompletedNavigation,
               isDocumentComplete,
               bodyBytes > 0,
               !isChallenge,
               hasRequiredContent,
               let data = html.data(using: .utf8),
               let response = HTTPURLResponse(
                url: currentURL ?? url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html; charset=utf-8"]
               ) {
                Logger.shared.log(
                    "CloudflareBypass: browser document accepted host=\(host) elapsedMs=\(elapsedMilliseconds(since: browserRecoveryStartedAt)) readyState=\(readyState) url=\(Self.redactedURL(currentURL?.absoluteString ?? "nil")) bytes=\(bodyBytes) challenge=\(isChallenge) playable=\(hasPlayableEmbed) markers=\(browserDocumentMarkerSummary(html))",
                    type: "Service"
                )
                return (data, response)
            }

            // Once the forced navigation has completed on another challenge page, the retained
            // browser session is definitively stale. Fail fast so retryWithSolvedSession can
            // discard it and run a fresh silent-then-visible verification instead of polling the
            // interstitial for the entire browser-recovery budget.
            if isFreshDocument,
               urlMatches,
               hasCompletedNavigation,
               isDocumentComplete,
               isChallenge {
                Logger.shared.log(
                    "CloudflareBypass: reloaded browser session still challenged host=\(host) elapsedMs=\(elapsedMilliseconds(since: browserRecoveryStartedAt)) markers=\(browserDocumentMarkerSummary(html))",
                    type: "Service"
                )
                return nil
            }

            if attempt == 1 || attempt == 20 || attempt == 40 {
                Logger.shared.log(
                    "CloudflareBypass: browser document not ready host=\(host) attempt=\(attempt) elapsedMs=\(elapsedMilliseconds(since: browserRecoveryStartedAt)) readyState=\(readyState) navigationComplete=\(hasCompletedNavigation) url=\(Self.redactedURL(currentURL?.absoluteString ?? "nil")) fresh=\(isFreshDocument) matchesRequest=\(urlMatches) bytes=\(bodyBytes) challenge=\(isChallenge) useful=\(isUsefulDocument) playable=\(hasPlayableEmbed) markers=\(browserDocumentMarkerSummary(html))",
                    type: "Service"
                )
            }

            // Front-load polling: the completed document is usually ready within a second or
            // two, so checking every 200ms early on shaves real latency off the common case.
            try? await Task.sleep(nanoseconds: attempt <= 10 ? 200_000_000 : 500_000_000)
        }

        Logger.shared.log(
            "CloudflareBypass: browser document recovery gave up host=\(host) elapsedMs=\(elapsedMilliseconds(since: browserRecoveryStartedAt))",
            type: "Service"
        )
        return nil
    }

    @MainActor
    private func setBrowserRecoveryMarker(_ marker: String, in webView: WKWebView) async {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("window.__eclipseCloudflareRecoveryMarker = '\(marker)'") { _, _ in
                continuation.resume()
            }
        }
    }

    @MainActor
    private func browserRecoveryMarker(in webView: WKWebView) async -> String? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("window.__eclipseCloudflareRecoveryMarker || null") { result, _ in
                continuation.resume(returning: result as? String)
            }
        }
    }

    private func browserDocumentLooksUseful(_ html: String, for url: URL) -> Bool {
        let path = url.path.lowercased()
        guard path.contains("/play/") else { return true }

        let lowerHTML = html.lowercased()
        return lowerHTML.contains("kwik")
            || lowerHTML.contains(".m3u8")
            || lowerHTML.contains("<video")
            || lowerHTML.contains("<source")
            || lowerHTML.contains("<iframe")
            || lowerHTML.contains("data-src")
    }

    private func browserDocumentHasPlayableEmbed(_ html: String, for url: URL) -> Bool {
        let path = url.path.lowercased()
        guard path.contains("/play/") else { return false }

        let lowerHTML = html.lowercased()
        return lowerHTML.contains(".m3u8")
            || lowerHTML.contains("<video")
            || lowerHTML.contains("<source")
            || (lowerHTML.contains("kwik") && (lowerHTML.contains("<iframe") || lowerHTML.contains("data-src")))
    }

    private func browserDocumentMarkerSummary(_ html: String) -> String {
        let lowerHTML = html.lowercased()
        var markers: [String] = []
        if lowerHTML.contains("ddos-guard") { markers.append("ddos") }
        if lowerHTML.contains("cloudflare") { markers.append("cloudflare") }
        if lowerHTML.contains("kwik") { markers.append("kwik") }
        if lowerHTML.contains(".m3u8") { markers.append("m3u8") }
        if lowerHTML.contains("<video") { markers.append("video") }
        if lowerHTML.contains("<source") { markers.append("source") }
        if lowerHTML.contains("<iframe") { markers.append("iframe") }
        if lowerHTML.contains("data-src") { markers.append("data-src") }
        if lowerHTML.contains("stream") { markers.append("stream") }
        return markers.isEmpty ? "none" : markers.joined(separator: ",")
    }

    private func browserURL(_ currentURL: URL?, matchesRequestedURL requestedURL: URL, host: String) -> Bool {
        guard let currentURL else { return false }
        let currentHost = currentURL.host?.lowercased()
        let requestedHost = requestedURL.host?.lowercased()
        guard currentHost == requestedHost || currentHost == host else { return false }

        let currentPath = currentURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let requestedPath = requestedURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard currentPath == requestedPath else { return false }

        // Some providers identify the selected episode entirely in query parameters.
        // Comparing only the path lets a live verification web view reuse the previous
        // episode's completed document for a new request with the same path, handing a stale
        // (and apparently random) stream back to the service parser.
        return normalizedQueryIdentity(for: currentURL) == normalizedQueryIdentity(for: requestedURL)
    }

    private func normalizedQueryIdentity(for url: URL) -> [String] {
        guard let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            return []
        }
        return items.map { item in
            "\(item.name)=\(item.value ?? "")"
        }.sorted()
    }

    @MainActor
    private func makeBypassWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        #if os(iOS)
        // iPad defaults to a desktop browsing profile. Keep the verification web view in
        // mobile content mode, matching the normal iPhone/iPad browser configuration.
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        config.allowsInlineMediaPlayback = true
        #endif
        // This web view exists only to establish the anti-bot session. Allowing provider
        // pages to autoplay media here can make an advertisement or featured video escape
        // the hidden verification window into WebKit's system AVPlayer. Requiring an explicit
        // media gesture does not interfere with Cloudflare/Turnstile JavaScript.
        config.mediaTypesRequiringUserActionForPlayback = .all
        #if os(iOS)
        let bounds = UIScreen.main.bounds
        #else
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        #endif
        // A zero-size frame is a well-known headless/automation tell (bot checks read
        // window.innerWidth/getBoundingClientRect). Give the view a real, device-sized frame
        // from the start even while it is only attached to the invisible silent host.
        return WKWebView(frame: bounds, configuration: config)
    }

    @MainActor
    private func allCookiesHeader(for host: String, in webView: WKWebView) async -> String? {
        #if os(tvOS)
        return nil
        #else
        return await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: Self.vettedSharedCookieHeader(
                    from: cookies,
                    for: host
                ))
            }
        }
        #endif
    }

    private struct SolvedSession {
        let cookieHeader: String
        let userAgent: String
        let resolvedHost: String?
        let cachedHosts: [String]
    }

    /// Detects whether the challenge has produced a clearance cookie and, if so, captures the
    /// session. cf_clearance / __ddg is issued for whichever host actually served the challenge
    /// — which, after a redirect (e.g. animepahe.com → animepahe.pw), is NOT the host the module
    /// asked for. So this looks for the clearance across ALL of the web view's cookies rather
    /// than pre-filtering by the original host (the old bug that made an interactive solve poll
    /// forever), mirrors every cookie into `HTTPCookieStorage.shared` so plain URLSession fetches
    /// carry them across that same cross-domain redirect, and caches the session under both the
    /// originally-requested host and the resolved challenge host.
    @MainActor
    private func captureSolvedSessionIfPresent(
        originalHost: String,
        in webView: WKWebView,
        retainsWebView: Bool
    ) async -> SolvedSession? {
        let cookies = await allCookies(in: webView)
        guard cookies.contains(where: { Self.isClearanceCookieName($0.name) }) else {
            return nil
        }

        // A provider can reject a clearance before its client-side expiry. The stale cookie is
        // still present in WebKit while the interstitial is displayed, so cookie presence alone
        // must never turn that rejected reuse back into a fresh 24-hour cache entry.
        let html = await documentHTML(for: webView)
        guard !Self.isChallengeResponse(status: 200, body: html) else { return nil }

        let userAgent = await userAgent(for: webView)
        let resolvedHost = webView.url?.host?.lowercased()

        // Put every cookie in the shared jar honoring its own domain, so a later URLSession
        // request to the original host is served the clearance after it redirects to the host
        // that actually issued it.
        let sharedCookieStorage = HTTPCookieStorage.shared
        for cookie in cookies {
            sharedCookieStorage.setCookie(cookie)
        }

        var cachedHosts: [String] = []
        var candidateHosts: [String] = []
        var solvedHeaders: [String: String] = [:]
        for candidate in [originalHost, resolvedHost].compactMap({ $0 }) where !candidateHosts.contains(candidate) {
            candidateHosts.append(candidate)
            if retainsWebView {
                bypassWebViews[candidate] = webView
            }
            guard let hostHeader = Self.vettedSharedCookieHeader(
                from: cookies,
                for: candidate
            ), Self.isSolvedCookieHeader(hostHeader) else {
                continue
            }
            store(cookieHeader: hostHeader, userAgent: userAgent, for: candidate)
            solvedHeaders[candidate] = hostHeader
            cachedHosts.append(candidate)
        }
        if let pendingHost = pendingVerificationURL?.host?.lowercased(), candidateHosts.contains(pendingHost) {
            pendingVerificationURL = nil
        }

        // cf_clearance is issued by whichever host served the challenge, which after a redirect
        // (animepahe.com -> animepahe.pw) is not the host the module asked for. Without carrying
        // it back to the requested host, retryWithSolvedSession finds no cached entry and the
        // caller re-solves the same challenge forever.
        if let resolvedHost,
           let resolvedHeader = solvedHeaders[resolvedHost],
           !cachedHosts.contains(originalHost) {
            store(cookieHeader: resolvedHeader, userAgent: userAgent, for: originalHost)
            solvedHeaders[originalHost] = resolvedHeader
            cachedHosts.append(originalHost)
            Logger.shared.log(
                "CloudflareBypass: carried the solved session to the requested host"
                    + " requested=\(originalHost) solvedBy=\(resolvedHost)",
                type: "Service"
            )
        }

        let solvedHeader = resolvedHost.flatMap({ solvedHeaders[$0] })
            ?? cachedHosts.compactMap({ solvedHeaders[$0] }).first
            ?? ""

        return SolvedSession(
            cookieHeader: solvedHeader,
            userAgent: userAgent,
            resolvedHost: resolvedHost,
            cachedHosts: cachedHosts
        )
    }

    @MainActor
    private func allCookies(in webView: WKWebView) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private static func isClearanceCookieName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "cf_clearance" || lower.hasPrefix("__ddg")
    }

    private static let sharedCookieLedgerLock = NSLock()
    private static var reportedSharedCookieLedger = Set<String>()
    private static var reportedSharedCookieLedgerFullAnnounced = false

    private static func reportSharedCookieLedgerOnce(_ signature: String, _ emit: () -> Void) {
        sharedCookieLedgerLock.lock()
        let alreadyFull = reportedSharedCookieLedger.count >= 512
        let isNew = !alreadyFull && reportedSharedCookieLedger.insert(signature).inserted
        let shouldAnnounceFull = alreadyFull && !reportedSharedCookieLedgerFullAnnounced
        if shouldAnnounceFull { reportedSharedCookieLedgerFullAnnounced = true }
        sharedCookieLedgerLock.unlock()
        if shouldAnnounceFull {
            Logger.shared.log(
                "Cloudflare clearance ledger reached its 512-signature bound; further cookie"
                    + " vetting verdicts are not reported for this session, so a silent"
                    + " re-challenge after this point has no ledger line",
                type: "Plugin"
            )
        }
        guard isNew else { return }
        emit()
    }

    static func vettedSharedCookieHeader(from rawHeader: String) -> String? {
        guard !rawHeader.isEmpty else { return nil }
        guard rawHeader.utf8.count <= maximumSharedCookieHeaderBytes else {
            reportSharedCookieLedgerOnce("header-bytes") {
            Logger.shared.log(
                "Cloudflare clearance header refused by Eclipse bytes=\(rawHeader.utf8.count) cap=maximumSharedCookieHeaderBytes=\(maximumSharedCookieHeaderBytes); the whole solved session is discarded, so a re-challenge after this is Eclipse's cap, not the site's",
                type: "Plugin"
            )
            }
            return nil
        }
        var seenNames: Set<String> = []
        var vetted: [String] = []
        var dropped: [String] = []
        var malformed: [String] = []
        for part in rawHeader.split(separator: ";", omittingEmptySubsequences: true) {
            let pieces = part.split(separator: "=", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard pieces.count == 2 else { continue }
            let name = pieces[0]
            let value = pieces[1]
            let normalizedName = name.lowercased()
            guard !name.isEmpty,
                  !value.isEmpty,
                  !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                malformed.append(normalizedName)
                continue
            }
            guard name.utf8.count <= maximumSharedCookieNameBytes,
                  value.utf8.count <= maximumSharedCookieValueBytes else {
                dropped.append(normalizedName)
                continue
            }
            guard seenNames.insert(normalizedName).inserted else { continue }
            guard vetted.count < maximumSharedCookieCount else {
                dropped.append(normalizedName)
                continue
            }
            vetted.append("\(name)=\(value)")
        }
        if !dropped.isEmpty {
            reportSharedCookieLedgerOnce("dropped:\(dropped.sorted().joined(separator: ","))") {
            Logger.shared.log(
                "Cloudflare clearance cookies dropped by Eclipse droppedNames=[\(dropped.sorted().joined(separator: ","))] kept=\(vetted.count) caps=\(maximumSharedCookieCount)/\(maximumSharedCookieNameBytes)B/\(maximumSharedCookieValueBytes)B; a re-challenge after this is Eclipse's cap, not the site's",
                type: "Plugin"
            )
            }
        }
        if !malformed.isEmpty {
            reportSharedCookieLedgerOnce("unusable:\(malformed.sorted().joined(separator: ","))") {
            Logger.shared.log(
                "Cloudflare clearance cookies skipped as unusable names=[\(malformed.sorted().joined(separator: ","))] kept=\(vetted.count); they were empty or carried control characters, so this is the site's header, not an Eclipse cap",
                type: "Plugin"
            )
            }
        }
        guard !vetted.isEmpty else {
            reportSharedCookieLedgerOnce("no-usable-cookies") {
            Logger.shared.log(
                "Cloudflare clearance header produced no usable cookies after Eclipse vetting; the solved session is discarded",
                type: "Plugin"
            )
            }
            return nil
        }
        return vetted.joined(separator: "; ")
    }

    private static func vettedSharedCookieHeader(
        from cookies: [HTTPCookie],
        now: Date = Date()
    ) -> String? {
        let prioritized = cookies.sorted { left, right in
            let leftClearance = isClearanceCookieName(left.name)
            let rightClearance = isClearanceCookieName(right.name)
            if leftClearance != rightClearance { return leftClearance }
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
        var seenNames: Set<String> = []
        var accepted: [String] = []
        var droppedCookies: [String] = []
        var unusableCookies: [String] = []
        var expiredCookies: [String] = []
        var totalBytes = 0
        for cookie in prioritized {
            let name = cookie.name
            let value = cookie.value
            let normalizedName = name.lowercased()
            let entryBytes = name.utf8.count + value.utf8.count + 2
            guard cookie.expiresDate.map({ $0 > now }) != false else {
                expiredCookies.append(normalizedName)
                continue
            }
            guard !name.isEmpty,
                  !value.isEmpty,
                  !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                unusableCookies.append(normalizedName)
                continue
            }
            guard name.utf8.count <= maximumSharedCookieNameBytes,
                  value.utf8.count <= maximumSharedCookieValueBytes else {
                droppedCookies.append(normalizedName)
                continue
            }
            guard seenNames.insert(normalizedName).inserted else { continue }
            guard accepted.count < maximumSharedCookieCount,
                  entryBytes <= maximumSharedCookieHeaderBytes - totalBytes else {
                droppedCookies.append(normalizedName)
                continue
            }
            accepted.append("\(name)=\(value)")
            totalBytes += entryBytes
        }
        if !droppedCookies.isEmpty {
            Logger.shared.log(
                "Cloudflare solved-session cookies dropped by Eclipse droppedNames=[\(droppedCookies.sorted().joined(separator: ","))] kept=\(accepted.count) caps=\(maximumSharedCookieCount)/\(maximumSharedCookieNameBytes)B/\(maximumSharedCookieValueBytes)B/\(maximumSharedCookieHeaderBytes)B; a re-challenge after this is Eclipse's cap, not the site's",
                type: "Plugin"
            )
        }
        if !unusableCookies.isEmpty {
            Logger.shared.log(
                "Cloudflare solved-session cookies skipped as unusable names=[\(unusableCookies.sorted().joined(separator: ","))] kept=\(accepted.count); they were empty or carried control characters, so this is the site's cookie jar, not an Eclipse cap",
                type: "Plugin"
            )
        }
        if !expiredCookies.isEmpty {
            Logger.shared.log(
                "Cloudflare solved-session cookies skipped as expired names=[\(expiredCookies.sorted().joined(separator: ","))] kept=\(accepted.count); the site set them to expire, so this is not an Eclipse cap",
                type: "Plugin"
            )
        }
        return accepted.isEmpty ? nil : accepted.joined(separator: "; ")
    }

    static func vettedSharedCookieHeader(
        from cookies: [HTTPCookie],
        for host: String,
        now: Date = Date()
    ) -> String? {
        let normalizedHost = host.lowercased()
        let applicable = cookies.filter { cookie in
            let domain = cookie.domain
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
                .lowercased()
            return cookie.expiresDate.map({ $0 > now }) != false
                && (cookie.path.isEmpty || cookie.path == "/")
                && (normalizedHost == domain || normalizedHost.hasSuffix(".\(domain)"))
        }
        guard applicable.contains(where: { isClearanceCookieName($0.name) }) else {
            return nil
        }
        let excluded = cookies.count - applicable.count
        if excluded > 0 {
reportSharedCookieLedgerOnce("not-applicable:\(normalizedHost):\(excluded)") {
                Logger.shared.log(
                    "Cloudflare solved-session cookies excluded before vetting count=\(excluded);"
                        + " they were expired or scoped to a different host or path, so this is the"
                        + " site's cookie jar, not an Eclipse cap",
                    type: "Plugin"
                )
            }
        }
        return vettedSharedCookieHeader(from: applicable, now: now)
    }

    @MainActor
    private func userAgent(for webView: WKWebView) async -> String {
        if let customUserAgent = webView.customUserAgent, !customUserAgent.isEmpty {
            return customUserAgent
        }
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("navigator.userAgent") { result, _ in
                continuation.resume(returning: (result as? String) ?? "")
            }
        }
    }

    @MainActor
    private func documentHTML(for webView: WKWebView) async -> String {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(
                ServiceBrowserOutputBoundary.boundedHTMLCaptureScript
            ) { result, _ in
                let payload = result as? [String: Any]
                continuation.resume(returning: (payload?["html"] as? String) ?? "")
            }
        }
    }

    @MainActor
    private func documentReadyState(for webView: WKWebView) async -> String {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("document.readyState || ''") { result, _ in
                continuation.resume(returning: (result as? String) ?? "")
            }
        }
    }

    private func normalizedHost(from url: URL) -> String? {
        url.host?.lowercased()
    }

    private func normalizedHost(_ host: String) -> String {
        host.lowercased()
    }

    private static func redactedURL(_ urlString: String) -> String {
        ServiceSandboxState.redactedURL(urlString)
    }

    private func mergeCookieHeaders(_ existing: String, _ bypass: String) -> String {
        if existing.isEmpty { return bypass }
        if bypass.isEmpty { return existing }

        var merged = cookiePairs(from: existing)
        for bypassPair in cookiePairs(from: bypass) {
            if let index = merged.firstIndex(where: { $0.name == bypassPair.name }) {
                merged[index] = bypassPair
            } else {
                merged.append(bypassPair)
            }
        }
        return merged.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private func cookiePairs(from header: String) -> [(name: String, value: String)] {
        header.split(separator: ";").compactMap { part in
            let pieces = part.split(separator: "=", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard pieces.count == 2, !pieces[0].isEmpty else { return nil }
            return (name: pieces[0], value: pieces[1])
        }
    }

    private func clearanceCookieFingerprint(in header: String) -> [String: String] {
        cookiePairs(from: header).reduce(into: [String: String]()) { result, pair in
            guard Self.isClearanceCookieName(pair.name) else { return }
            result[pair.name.lowercased()] = pair.value
        }
    }

    private func cookiePairCount(in header: String) -> Int {
        cookiePairs(from: header).count
    }

    private func cookieNameSummary(_ header: String, limit: Int = 6) -> String {
        let names = cookiePairs(from: header).map(\.name)
        guard !names.isEmpty else { return "none" }
        let prefix = names.prefix(limit)
        let suffix = names.count > limit ? ",..." : ""
        return prefix.joined(separator: ",") + suffix
    }

    private func userAgentProfile(_ userAgent: String) -> String {
        let lowerUserAgent = userAgent.lowercased()
        guard !lowerUserAgent.isEmpty else { return "unknown" }
        if lowerUserAgent.contains("ipad;") { return "ipad" }
        if lowerUserAgent.contains("iphone;") { return "iphone" }
        if lowerUserAgent.contains("android") && lowerUserAgent.contains("mobile") { return "android-mobile" }
        if lowerUserAgent.contains("android") { return "android-tablet" }
        if lowerUserAgent.contains("mobile") { return "mobile-other" }
        if lowerUserAgent.contains("macintosh") { return "mac-desktop" }
        if lowerUserAgent.contains("windows") { return "windows-desktop" }
        if lowerUserAgent.contains("linux") { return "linux-desktop" }
        return "other"
    }

    private func elapsedMilliseconds(since startDate: Date) -> Int {
        Int(Date().timeIntervalSince(startDate) * 1000)
    }

    private static func isSolvedCookieHeader(_ header: String) -> Bool {
        let lowerHeader = header.lowercased()
        if lowerHeader.contains("cf_clearance=") {
            return true
        }
        return header.split(separator: ";").contains { part in
            let name = part.split(separator: "=", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            return name.hasPrefix("__ddg")
        }
    }

    private func redactedHost(_ url: URL) -> String {
        normalizedHost(from: url) ?? "unknown-host"
    }

}

#if os(iOS)
@MainActor
private func cloudflarePresentationScene() -> UIWindowScene? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    return scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.windowScene
        ?? scenes.first(where: { $0.activationState == .foregroundActive })
        ?? scenes.first
}

private struct CloudflareBypassSheetView: View {
    @ObservedObject private var manager = CloudflareBypassManager.shared

    var body: some View {
        NavigationView {
            Group {
                if let webView = manager.activeBypassWebView {
                    CloudflareBypassWebView(webView: webView)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    EclipseLoadingIndicator()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Security Check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        Task { @MainActor in
                            CloudflareBypassManager.shared.cancelActiveBypass()
                        }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .background(Color(UIColor.systemBackground))
    }
}

private struct CloudflareBypassWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor
private final class CloudflareBypassWindowController {
    static let shared = CloudflareBypassWindowController()
    private var window: UIWindow?

    private init() {}

    func show() {
        guard window == nil else { return }
        guard let scene = cloudflarePresentationScene() else { return }

        let host = UIHostingController(rootView: CloudflareBypassSheetView().profileScopedAppStorage())
        host.view.backgroundColor = UIColor.systemBackground

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = host
        window.makeKeyAndVisible()
        self.window = window
    }

    func hide() {
        window?.isHidden = true
        window = nil
    }
}

/// Hosts a bypass web view inside a real, live window (so it lays out and runs JS timers
/// exactly like a visible page) while staying imperceptible and non-interactive. This lets
/// the common, non-interactive Cloudflare/DDoS-Guard challenge resolve without ever showing
/// UI to the user; `triggerBypass` only escalates to `CloudflareBypassWindowController` when
/// a challenge turns out to need a real tap.
@MainActor
private final class CloudflareBypassSilentHost {
    static let shared = CloudflareBypassSilentHost()
    private var window: UIWindow?
    private weak var hostedWebView: WKWebView?

    private init() {}

    func attach(_ webView: WKWebView) {
        guard window == nil else { return }
        guard let scene = cloudflarePresentationScene() else { return }

        let hostViewController = UIViewController()
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hostViewController.view.addSubview(webView)

        let window = UIWindow(windowScene: scene)
        window.windowLevel = .normal - 1
        window.isUserInteractionEnabled = false
        // Not fully 0: a zero-alpha layer can be treated as non-rendering by the compositor
        // on some OS versions, which would reintroduce the throttling we're trying to avoid.
        window.alpha = 0.01
        window.rootViewController = hostViewController
        window.isHidden = false

        self.window = window
        hostedWebView = webView
    }

    func detach(_ webView: WKWebView) {
        guard hostedWebView === webView else { return }
        webView.removeFromSuperview()
        window?.isHidden = true
        window = nil
        hostedWebView = nil
    }
}
#endif
#endif

/// Challenge diagnostics are platform-neutral even though interactive browser
/// recovery is unavailable on tvOS. Shared JavaScript fetch logging uses this
/// surface on every platform.
extension CloudflareBypassManager {
    static func challengeDebugSummary(status: Int, body: String, headers: [String: String] = [:]) -> String {
        let lowerHeaders = headers.reduce(into: [String: String]()) { result, pair in
            result[pair.key.lowercased()] = pair.value
        }
        let server = lowerHeaders["server"]?.lowercased() ?? "none"
        let contentType = lowerHeaders["content-type"]?.split(separator: ";", maxSplits: 1).first.map(String.init) ?? "unknown"
        let locationHost: String
        if let locationValue = lowerHeaders["location"],
           let locationURL = URL(string: locationValue),
           let host = locationURL.host?.lowercased() {
            locationHost = host
        } else {
            locationHost = "none"
        }
        let hasCFRay = lowerHeaders["cf-ray"] != nil
        let hasSetCookie = lowerHeaders["set-cookie"] != nil
        let hasDDoSGuardHeader = server.contains("ddos-guard")
        return "status=\(status) server=\(server) cfRay=\(hasCFRay) ddgHeader=\(hasDDoSGuardHeader) contentType=\(contentType) locationHost=\(locationHost) setCookie=\(hasSetCookie) bodyBytes=\(body.utf8.count) markers=\(challengeMarkerSummary(from: body))"
    }

    private static func challengeMarkerSummary(from body: String) -> String {
        let lowerBody = body.lowercased()
        var markers: [String] = []
        if lowerBody.contains("ddos-guard") { markers.append("ddos") }
        if lowerBody.contains("cloudflare") { markers.append("cloudflare") }
        if lowerBody.contains("__cf_chl_") { markers.append("cf-chl") }
        if lowerBody.contains("cf-turnstile") { markers.append("turnstile") }
        if lowerBody.contains("challenge-platform") { markers.append("platform") }
        if lowerBody.contains("just a moment") { markers.append("just-a-moment") }
        if lowerBody.contains(".m3u8") { markers.append("m3u8") }
        if lowerBody.contains("<video") { markers.append("video") }
        if lowerBody.contains("<source") { markers.append("source") }
        if lowerBody.contains("<iframe") { markers.append("iframe") }
        if lowerBody.contains("kwik") { markers.append("kwik") }
        return markers.isEmpty ? "none" : markers.joined(separator: ",")
    }
}
