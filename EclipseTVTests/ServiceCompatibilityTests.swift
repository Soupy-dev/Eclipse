import Foundation
import JavaScriptCore
import XCTest
@testable import Eclipse

private final class BoundedResponseURLProtocol: URLProtocol {
    private let stateLock = NSLock()
    private var stopped = false
    private var delayedWorkItem: DispatchWorkItem?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "bounded-response.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else { return }

        let response: URLResponse
        if url.path == "/declared-oversize" {
            response = URLResponse(
                url: url,
                mimeType: "application/octet-stream",
                expectedContentLength: 4,
                textEncodingName: nil
            )
        } else {
            response = HTTPURLResponse(
                url: url,
                statusCode: url.path == "/status" ? 503 : 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "3"]
            )!
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        switch url.path {
        case "/declared-oversize":
            return
        case "/streamed-oversize":
            client?.urlProtocol(self, didLoad: Data([1, 2]))
            client?.urlProtocol(self, didLoad: Data([3, 4]))
            client?.urlProtocolDidFinishLoading(self)
        case "/slow":
            client?.urlProtocol(self, didLoad: Data([1]))
            let workItem = DispatchWorkItem { [weak self] in
                guard let self, !self.isStopped else { return }
                self.client?.urlProtocol(self, didLoad: Data([2]))
                self.client?.urlProtocolDidFinishLoading(self)
            }
            delayedWorkItem = workItem
            DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: workItem)
        default:
            client?.urlProtocol(self, didLoad: Data([1]))
            client?.urlProtocol(self, didLoad: Data([2, 3]))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stateLock.lock()
        stopped = true
        let workItem = delayedWorkItem
        delayedWorkItem = nil
        stateLock.unlock()
        workItem?.cancel()
    }

    private var isStopped: Bool {
        stateLock.lock()
        let value = stopped
        stateLock.unlock()
        return value
    }
}

private final class CallbackRecorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Value] {
        lock.lock()
        let snapshot = storage
        lock.unlock()
        return snapshot
    }
}

private func makeStreamCancellationTestService() -> Service {
    let script = """
    function extractStreamUrl(url) {
        if (url === "hang") {
            return new Promise(function() {});
        }
        return Promise.resolve(JSON.stringify({
            stream: "https://media.example/retry.m3u8"
        }));
    }
    """
    return Service(
        id: UUID(),
        metadata: ServiceMetadata(
            sourceName: "Cancellation Retry Test",
            author: ServiceMetadata.Author(name: "Tests", icon: ""),
            iconUrl: "",
            version: "1",
            language: "en",
            baseUrl: "https://media.example",
            streamType: "hls",
            quality: "1080p",
            searchBaseUrl: "https://media.example",
            scriptUrl: "https://media.example/service.js",
            softsub: false,
            multiStream: false,
            multiSubs: false,
            type: nil,
            novel: false,
            settings: false
        ),
        jsScript: script,
        url: "https://media.example/service.json",
        isActive: true,
        sortIndex: 0
    )
}

private func makeJavaScriptIsolationTestService(
    id: UUID = UUID(),
    name: String,
    script: String
) -> Service {
    Service(
        id: id,
        metadata: ServiceMetadata(
            sourceName: name,
            author: ServiceMetadata.Author(name: "Tests", icon: ""),
            iconUrl: "",
            version: "1",
            language: "en",
            baseUrl: "https://media.example",
            streamType: "hls",
            quality: "1080p",
            searchBaseUrl: "https://media.example",
            scriptUrl: "https://media.example/service.js",
            softsub: false,
            multiStream: false,
            multiSubs: false,
            type: nil,
            novel: false,
            settings: false
        ),
        jsScript: script,
        url: "https://media.example/service.json",
        isActive: true,
        sortIndex: 0
    )
}

private func fetchIsolationSearch(
    controller: JSController,
    service: Service,
    timeoutNanoseconds: UInt64
) async -> [SearchItem] {
    await withCheckedContinuation { continuation in
        controller.fetchJsSearchResults(
            keyword: "query",
            module: service,
            timeoutNanoseconds: timeoutNanoseconds
        ) { result in
            continuation.resume(returning: result)
        }
    }
}

private actor RateLimiterProbe {
    private var starts: [UInt64] = []
    private var inFlight = 0
    private var peakInFlight = 0

    func begin(at timestamp: UInt64) {
        starts.append(timestamp)
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
    }

    func end() {
        inFlight -= 1
    }

    func snapshot() -> (starts: [UInt64], peakInFlight: Int) {
        (starts, peakInFlight)
    }
}

private actor BlockingRateLimiterOperation {
    private var didStart = false
    private var isReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func signalStarted() {
        didStart = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilStarted() async {
        guard !didStart else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            startWaiters.append(continuation)
        }
    }

    func waitForRelease() async {
        guard !isReleased else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            releaseWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private actor RateLimiterEventRecorder {
    private var events: [Int] = []

    func record(_ event: Int) {
        events.append(event)
    }

    func snapshot() -> [Int] {
        events
    }
}

private actor AnimeIdentityBatchRecorder {
    private var batches: [[Int]] = []

    func fetch(
        keys: [AnimeSeasonIdentityRequestKey]
    ) -> [AnimeSeasonIdentityRequestKey: AniListSeasonIdentity] {
        batches.append(keys.map(\.anilistId).sorted())
        return keys.reduce(into: [:]) { result, key in
            result[key] = AniListSeasonIdentity(
                anilistId: key.anilistId,
                malId: nil,
                kitsuId: nil,
                title: "Anime \(key.anilistId)",
                englishTitle: nil,
                romajiTitle: nil,
                nativeTitle: nil,
                episodeCount: 12,
                posterURL: nil
            )
        }
    }

    func snapshot() -> [[Int]] {
        batches
    }
}

final class ServiceCompatibilityTests: XCTestCase {
    func testAutoModeSourceSelectionUsesSavedOrderAndFiltersUnavailableSources() throws {
        let suiteName = "AutoModeSourceSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["service:a", "stremio:b", "service:c"], forKey: "servicesAutoModeSourceIds")
        defaults.set(["stremio:b", "missing", "service:a", "stremio:b"], forKey: "servicesAutoModeSourceOrderIds")

        XCTAssertEqual(
            AutoModeSourceSelection.orderedSelectedSourceIds(
                availableSourceIds: ["service:c", "service:a", "stremio:b", "service:unselected"],
                defaults: defaults
            ),
            ["stremio:b", "service:a", "service:c"]
        )
    }

    func testAutoModeSourceSelectionKeepsStableFallbackOrder() throws {
        let suiteName = "AutoModeSourceSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["service:a", "service:c"], forKey: "servicesAutoModeSourceIds")

        XCTAssertEqual(
            AutoModeSourceSelection.orderedSelectedSourceIds(
                availableSourceIds: ["service:c", "service:b", "service:a"],
                defaults: defaults
            ),
            ["service:c", "service:a"]
        )
    }

    func testPlainHTTPProviderIsCompatible() {
        let capabilities = ServiceProviderCapabilities.analyze(
            javaScript: "fetch('https://example.com/streams')"
        )

        XCTAssertEqual(capabilities, .httpOnly)
        XCTAssertTrue(capabilities.isSupportedOnCurrentPlatform)
        XCTAssertNil(capabilities.compatibilityError)
    }

    func testServiceSandboxAcceptsOnlyAbsoluteHTTPAndHTTPSURLs() {
        XCTAssertNotNil(ServiceSandboxState.validatedHTTPURL("https://example.com/provider.json"))
        XCTAssertNotNil(ServiceSandboxState.validatedHTTPURL("http://localhost:8080/streams"))

        XCTAssertNil(ServiceSandboxState.validatedHTTPURL("file:///private/secret"))
        XCTAssertNil(ServiceSandboxState.validatedHTTPURL("ftp://example.com/provider.json"))
        XCTAssertNil(ServiceSandboxState.validatedHTTPURL("javascript:alert(1)"))
        XCTAssertNil(ServiceSandboxState.validatedHTTPURL("data:text/plain,secret"))
        XCTAssertNil(ServiceSandboxState.validatedHTTPURL("/relative/provider.json"))
        XCTAssertNil(ServiceSandboxState.validatedHTTPURL("https:///missing-host"))

        XCTAssertTrue(FetchDelegate.isAllowedRedirectURL(URL(string: "https://cdn.example/script.js")))
        XCTAssertFalse(FetchDelegate.isAllowedRedirectURL(URL(string: "ftp://cdn.example/script.js")))
        XCTAssertFalse(FetchDelegate.isAllowedRedirectURL(URL(fileURLWithPath: "/private/secret")))
    }

    func testServiceSandboxAllowsBoundedNetworkRequestsDuringScriptLoad() {
        let sandbox = ServiceSandboxState()
        let identity = ServiceJavaScriptIdentity(
            serviceID: UUID(),
            scriptFingerprint: "top-level-fetch",
            serviceName: "Top Level Fetch Test"
        )

        sandbox.beginLoading(identity: identity)
        let operation = sandbox.allowServiceNetworkRequest(
            api: "fetch",
            urlString: "http://localhost:8080/bootstrap"
        )
        sandbox.endLoading()

        XCTAssertEqual(operation?.serviceID, identity.serviceID)
        XCTAssertEqual(operation?.operation, "loadScript")
        XCTAssertNil(sandbox.allowServiceNetworkRequest(
            api: "fetch",
            urlString: "http://localhost:8080/after-load"
        ))
    }

    func testSensitiveProviderSettingsAreClassifiedWithoutInspectingTheirSecrets() {
        XCTAssertTrue(ServiceSettingSecurity.isSensitive(key: "apiToken", comment: nil, value: "value"))
        XCTAssertTrue(ServiceSettingSecurity.isSensitive(key: "endpoint", comment: "API key for provider", value: "value"))
        XCTAssertTrue(
            ServiceSettingSecurity.isSensitive(
                key: "endpoint",
                comment: nil,
                value: "https://provider.example/configure?access_token=value"
            )
        )
        XCTAssertTrue(
            ServiceSettingSecurity.isSensitive(
                key: "endpoint",
                comment: nil,
                value: ServiceSettingSecurity.keychainPlaceholder
            )
        )
        XCTAssertFalse(ServiceSettingSecurity.isSensitive(key: "preferredLanguage", comment: nil, value: "en"))
        XCTAssertFalse(ServiceSettingSecurity.isSensitive(key: "quality", comment: "Playback quality", value: "1080p"))

        let freeFormString = ServiceSetting(
            key: "providerValue",
            value: "opaque-value",
            type: .string,
            comment: nil,
            options: nil
        )
        XCTAssertTrue(freeFormString.isSensitive)
    }

    func testServiceStringSettingUsesAValidEscapedJavaScriptLiteral() throws {
        let value = "quote=\" backslash=\\ newline=\n interpolation=${secret}"
        let literal = ServiceSettingSecurity.javascriptStringLiteral(value)
        let decoded = try JSONDecoder().decode(
            String.self,
            from: try XCTUnwrap(literal.data(using: .utf8))
        )

        XCTAssertEqual(decoded, value)
        XCTAssertFalse(literal.contains("\n"))
    }

    func testSensitiveProviderSettingVaultHydratesOnlyEphemeralScript() throws {
        let serviceID = UUID()
        let key = "apiToken"
        let secret = "unit-secret-value"
        defer { TVServiceSettingVault.remove(serviceID: serviceID, key: key) }

        XCTAssertTrue(TVServiceSettingVault.protect(secret, serviceID: serviceID, key: key))
        let persistedScript = """
        // Settings start
        const apiToken = "\(ServiceSettingSecurity.keychainPlaceholder)";
        // Settings end
        """
        let runtimeScript = TVServiceSettingVault.hydrating(persistedScript, serviceID: serviceID)

        XCTAssertFalse(persistedScript.contains(secret))
        XCTAssertTrue(runtimeScript.contains(secret))
        XCTAssertFalse(runtimeScript.contains(ServiceSettingSecurity.keychainPlaceholder))
    }

    func testDOMProviderGetsTypedBrowserAutomationError() {
        let capabilities = ServiceProviderCapabilities.analyze(
            javaScript: "document.querySelector('.play').click()"
        )

        XCTAssertFalse(capabilities.isSupportedOnCurrentPlatform)
        XCTAssertEqual(capabilities.compatibilityError, .browserAutomationRequired)
    }

    func testChallengeProviderStaysEnableableAndOnlyWarns() {
        let capabilities = ServiceProviderCapabilities.analyze(
            javaScript: "const cookie = 'cf_clearance'; fetch(url)"
        )

        XCTAssertTrue(capabilities.requirements.contains(.interactiveChallenge))
        XCTAssertTrue(capabilities.isSupportedOnCurrentPlatform)
        XCTAssertNil(capabilities.compatibilityError)
        XCTAssertEqual(capabilities.compatibilityAdvisory, .interactiveChallengeRequired)
    }

    func testBrowserAutomationStillDisqualifiesAlongsideAChallengeMarker() {
        let capabilities = ServiceProviderCapabilities.analyze(
            javaScript: "const cookie = 'cf_clearance'; document.querySelector('.play').click()"
        )

        XCTAssertFalse(capabilities.isSupportedOnCurrentPlatform)
        XCTAssertEqual(capabilities.compatibilityError, .browserAutomationRequired)
    }

    func testTorrentOnlyProviderGetsTypedTransportError() {
        let capabilities = ServiceProviderCapabilities.analyze(
            javaScript: "return [{ url: `magnet:?xt=urn:btih:${result.infoHash}` }]"
        )

        XCTAssertFalse(capabilities.isSupportedOnCurrentPlatform)
        XCTAssertTrue(capabilities.requirements.contains(.torrentOnly))
        XCTAssertEqual(capabilities.compatibilityError, .torrentTransportRequired)
    }

    func testMixedDirectAndTorrentProviderRemainsEligible() {
        let capabilities = ServiceProviderCapabilities.analyze(
            javaScript: "return [{ url: 'magnet:?xt=urn:btih:abc' }, { url: 'https://cdn.example/video.m3u8' }]"
        )

        XCTAssertFalse(capabilities.requirements.contains(.torrentOnly))
        XCTAssertNil(capabilities.compatibilityError)
    }

    func testBrowserRequirementTakesPrecedenceWhenProviderNeedsBoth() {
        let capabilities = ServiceProviderCapabilities.analyze(
            javaScript: "document.querySelector('#challenge'); const cookie = 'cf_clearance'"
        )

        XCTAssertEqual(
            capabilities.requirements,
            [.browserAutomation, .interactiveChallenge]
        )
        XCTAssertEqual(capabilities.compatibilityError, .browserAutomationRequired)
    }

    func testTokenBearingStremioEndpointIsReducedToOrigin() {
        let redacted = StremioClient.redactedEndpointDescription(
            from: "https://secret-token@addons.example.com:8443/super-secret/manifest.json?token=abc#private"
        )

        XCTAssertEqual(redacted, "https://addons.example.com:8443")
        XCTAssertFalse(redacted.contains("secret"))
        XCTAssertFalse(redacted.contains("token"))
        XCTAssertFalse(redacted.contains("manifest"))
    }

    @MainActor
    func testKitsuPreflightTreatsMissingPrefixesAsWildcardAndHonorsExplicitRestrictions() {
        XCTAssertTrue(StremioAddonManager.explicitlySupportsKitsuContentIds(nil))
        XCTAssertTrue(StremioAddonManager.explicitlySupportsKitsuContentIds([]))
        XCTAssertFalse(StremioAddonManager.explicitlySupportsKitsuContentIds(["tt", "tmdb:"]))
        XCTAssertTrue(StremioAddonManager.explicitlySupportsKitsuContentIds([" KITSU: "]))
    }

    func testKitsuQueryCacheRetainsMissesAndStaysBounded() {
        var cache = KitsuLookupQueryCache(capacity: 2)
        cache.store(.noMatch, for: "first")
        cache.store(.match(42), for: "second")

        XCTAssertEqual(cache.entry(for: "first"), .noMatch)
        XCTAssertEqual(cache.entry(for: "second"), .match(42))

        cache.store(.noMatch, for: "third")
        XCTAssertNil(cache.entry(for: "first"))
        XCTAssertEqual(cache.entry(for: "second"), .match(42))
        XCTAssertEqual(cache.entry(for: "third"), .noMatch)
    }

    func testStreamLanguageFilterHasNoConfigurationWorkWhenRulesAreDisabled() throws {
        let suiteName = "StreamLanguageFilterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertNil(
            StreamLanguageFilter.configuration(
                sourceId: "stremio:test",
                defaults: defaults
            )
        )
        XCTAssertFalse(
            StreamLanguageFilter.shouldHide(
                languageHints: [],
                metadata: ["large metadata payload without a quality label"],
                sourceId: "stremio:test",
                defaults: defaults
            )
        )
    }

    func testStreamLanguageFilterPreservesUnknownLanguageAndSourceRules() throws {
        let suiteName = "StreamLanguageFilterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        StreamLanguageFilter.setHidesStreamsWithoutLanguageData(true, defaults: defaults)
        StreamLanguageFilter.setExtraRulesSourceIds(["stremio:selected"], defaults: defaults)

        XCTAssertNotNil(
            StreamLanguageFilter.configuration(
                sourceId: "stremio:selected",
                defaults: defaults
            )
        )
        XCTAssertNil(
            StreamLanguageFilter.configuration(
                sourceId: "stremio:excluded",
                defaults: defaults
            )
        )
        XCTAssertTrue(
            StreamLanguageFilter.shouldHide(
                languageHints: ["und"],
                metadata: ["1080p WEB-DL"],
                sourceId: "stremio:selected",
                defaults: defaults
            )
        )
        XCTAssertFalse(
            StreamLanguageFilter.shouldHide(
                languageHints: ["English"],
                metadata: ["1080p WEB-DL"],
                sourceId: "stremio:selected",
                defaults: defaults
            )
        )
    }

    func testServiceTimeoutReturnsBeforeAnUncooperativeContinuation() async {
        let start = ContinuousClock.now
        let result: Int? = await ServiceManager.shared.withTimeout(nanoseconds: 20_000_000) {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                    continuation.resume(returning: 7)
                }
            }
        }
        let elapsed = start.duration(to: .now)

        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, .milliseconds(150))

        // Let the intentionally uncooperative test operation finish so it does
        // not retain a limiter reservation past this test.
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    func testServiceTimeoutPropagatesFastResultWithoutWaitingForDeadline() async {
        let start = ContinuousClock.now
        let result: Int? = await ServiceManager.shared.withTimeout(nanoseconds: 1_000_000_000) {
            42
        }
        let elapsed = start.duration(to: .now)

        XCTAssertEqual(result, 42)
        XCTAssertLessThan(elapsed, .milliseconds(150))
    }

    func testJSCallbackDeadlineDeliversSuccessfulResultExactlyOnce() async {
        let recorder = CallbackRecorder<Int>()
        let deadline = JSCallbackDeadline<Int> { recorder.append($0) }
        deadline.armTimeout(
            nanoseconds: 30_000_000,
            value: 99,
            beforeDelivery: {}
        )

        XCTAssertTrue(deadline.finish(with: 42))
        XCTAssertFalse(deadline.finish(with: 7))
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(recorder.values, [42])
        XCTAssertFalse(deadline.isPending)
    }

    func testJSCallbackDeadlineTimeoutAndCancellationAreMutuallyExclusive() async {
        let delivered = CallbackRecorder<Int>()
        let cancelled = CallbackRecorder<Bool>()
        let deadline = JSCallbackDeadline<Int> { delivered.append($0) }
        deadline.setCancellationHandler { cancelled.append(true) }
        deadline.armTimeout(
            nanoseconds: 30_000_000,
            value: 99,
            beforeDelivery: {}
        )

        XCTAssertTrue(deadline.cancel())
        XCTAssertFalse(deadline.cancel())
        try? await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertTrue(delivered.values.isEmpty)
        XCTAssertEqual(cancelled.values, [true])
        XCTAssertFalse(deadline.isPending)
    }

    func testJSCallbackDeadlineDeliversTimeoutFallbackOnce() async {
        let delivered = CallbackRecorder<Int>()
        let cleanup = CallbackRecorder<Bool>()
        let deadline = JSCallbackDeadline<Int> { delivered.append($0) }
        deadline.armTimeout(
            nanoseconds: 10_000_000,
            value: 99,
            beforeDelivery: { cleanup.append(true) }
        )

        try? await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertEqual(delivered.values, [99])
        XCTAssertEqual(cleanup.values, [true])
        XCTAssertFalse(deadline.finish(with: 42))
        XCTAssertFalse(deadline.isPending)
    }

    func testServiceJavaScriptQuarantineRequiresRepeatedFingerprintIncidents() throws {
        let suiteName = "ServiceJavaScriptQuarantineTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let serviceID = UUID()
        let original = ServiceJavaScriptIdentity(
            serviceID: serviceID,
            scriptFingerprint: "first-script",
            serviceName: "Hostile Test"
        )
        let automaticallyUpdated = ServiceJavaScriptIdentity(
            serviceID: serviceID,
            scriptFingerprint: "rotated-script",
            serviceName: "Hostile Test"
        )

        let firstLaunch = ServiceJavaScriptQuarantineStore(defaults: defaults)
        XCTAssertFalse(
            firstLaunch.recordNonYieldingBoundary(
                identity: original,
                operation: "searchResults"
            )
        )
        XCTAssertFalse(firstLaunch.isQuarantined(original))
        XCTAssertFalse(firstLaunch.isQuarantined(automaticallyUpdated))

        let secondLaunch = ServiceJavaScriptQuarantineStore(defaults: defaults)
        XCTAssertFalse(secondLaunch.isQuarantined(original))
        XCTAssertFalse(secondLaunch.recordNonYieldingBoundary(
            identity: original,
            operation: "searchResults"
        ))
        XCTAssertFalse(secondLaunch.isQuarantined(original))

        let thirdLaunch = ServiceJavaScriptQuarantineStore(defaults: defaults)
        XCTAssertTrue(thirdLaunch.recordNonYieldingBoundary(
            identity: original,
            operation: "searchResults"
        ))
        XCTAssertTrue(thirdLaunch.isQuarantined(original))
        XCTAssertFalse(thirdLaunch.isQuarantined(automaticallyUpdated))

        thirdLaunch.clear(serviceID: serviceID)
        XCTAssertFalse(thirdLaunch.isQuarantined(original))
    }

    func testServiceJavaScriptQuarantineCapacityFailsOpenForUnknownServices() throws {
        let suiteName = "ServiceJavaScriptQuarantineCapacityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let serviceID = UUID()
        let original = ServiceJavaScriptIdentity(
            serviceID: serviceID,
            scriptFingerprint: "first-script",
            serviceName: "First Hostile Service"
        )
        let store = ServiceJavaScriptQuarantineStore(defaults: defaults, strikeLimit: 1)
        XCTAssertTrue(
            store.recordNonYieldingBoundary(identity: original, operation: "searchResults")
        )

        for index in 0..<256 {
            _ = store.recordNonYieldingBoundary(
                identity: ServiceJavaScriptIdentity(
                    serviceID: UUID(),
                    scriptFingerprint: "later-script-\(index)",
                    serviceName: "Later Hostile Service \(index)"
                ),
                operation: "searchResults"
            )
        }

        let reloadedStore = ServiceJavaScriptQuarantineStore(defaults: defaults, strikeLimit: 1)
        let automaticallyUpdated = ServiceJavaScriptIdentity(
            serviceID: serviceID,
            scriptFingerprint: "rotated-script",
            serviceName: "First Hostile Service"
        )
        XCTAssertTrue(reloadedStore.isQuarantined(original))
        XCTAssertFalse(reloadedStore.isQuarantined(automaticallyUpdated))

        let unknownService = ServiceJavaScriptIdentity(
            serviceID: UUID(),
            scriptFingerprint: "unknown-script",
            serviceName: "Unknown Service"
        )
        XCTAssertFalse(reloadedStore.isQuarantined(unknownService))

        reloadedStore.clear(serviceID: serviceID)
        XCTAssertFalse(reloadedStore.isQuarantined(automaticallyUpdated))
        XCTAssertFalse(reloadedStore.isQuarantined(unknownService))
        XCTAssertFalse(reloadedStore.isQuarantined(ServiceJavaScriptIdentity(
            serviceID: UUID(),
            scriptFingerprint: "another-unknown-script",
            serviceName: "Another Unknown Service"
        )))
    }

    func testServiceTimerRegistryClampsNonFiniteDelaysAndBoundsFloods() {
        XCTAssertEqual(
            ServiceJavaScriptTimerRegistry.boundedDelay(milliseconds: .nan),
            0
        )
        XCTAssertEqual(
            ServiceJavaScriptTimerRegistry.boundedDelay(milliseconds: -.infinity),
            0
        )
        XCTAssertEqual(
            ServiceJavaScriptTimerRegistry.boundedDelay(milliseconds: .infinity),
            60
        )
        XCTAssertEqual(
            ServiceJavaScriptTimerRegistry.boundedDelay(milliseconds: Double.greatestFiniteMagnitude),
            60
        )
        XCTAssertEqual(
            ServiceJavaScriptTimerRegistry.boundedDelay(
                milliseconds: .nan,
                minimumMilliseconds: 16
            ),
            0.016
        )

        let registry = ServiceJavaScriptTimerRegistry()
        let ids = (0..<ServiceJavaScriptTimerRegistry.maximumLiveTimers).compactMap { _ in
            registry.reserveID()
        }
        XCTAssertEqual(ids.count, ServiceJavaScriptTimerRegistry.maximumLiveTimers)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertNil(registry.reserveID())
        registry.invalidate()
        XCTAssertEqual(registry.liveCount, 0)
    }

    func testServiceSandboxBoundsAndCancelsNativeOperationsOnInvalidation() {
        let sandbox = ServiceSandboxState()
        let cancellations = CallbackRecorder<UUID>()
        let leases = (0..<ServiceSandboxState.maximumConcurrentNativeOperations).compactMap { _ in
            sandbox.reserveNativeOperation()
        }
        XCTAssertEqual(leases.count, ServiceSandboxState.maximumConcurrentNativeOperations)
        XCTAssertEqual(
            sandbox.liveNativeOperationCount,
            ServiceSandboxState.maximumConcurrentNativeOperations
        )
        XCTAssertNil(sandbox.reserveNativeOperation())

        for lease in leases {
            let id = lease.id
            lease.installCancellationHandler {
                cancellations.append(id)
            }
        }
        sandbox.invalidate()

        XCTAssertEqual(Set(cancellations.values), Set(leases.map(\.id)))
        XCTAssertEqual(sandbox.liveNativeOperationCount, 0)
        XCTAssertTrue(leases.allSatisfy { !$0.isActive })
        XCTAssertNil(sandbox.reserveNativeOperation())
    }

    func testServiceSandboxDeinitCancelsRegisteredNativeOperation() throws {
        let cancellations = CallbackRecorder<Bool>()
        var sandbox: ServiceSandboxState? = ServiceSandboxState()
        weak var weakSandbox = sandbox
        let lease = try XCTUnwrap(sandbox?.reserveNativeOperation())
        lease.installCancellationHandler {
            cancellations.append(true)
        }

        sandbox = nil

        XCTAssertNil(weakSandbox)
        XCTAssertEqual(cancellations.values, [true])
        XCTAssertFalse(lease.isActive)
    }

    func testServiceNetworkInputBoundaryDropsExcessHeadersAndRejectsBodies() throws {
        let context = try XCTUnwrap(JSContext())
        let reader = try XCTUnwrap(ServiceJavaScriptValueReader(context: context))
        let oversizedHeaders = try XCTUnwrap(context.evaluateScript(
            """
            (function () {
                const headers = {};
                for (let index = 0; index < 65; index++) {
                    headers["X-Test-" + index] = "value";
                }
                return headers;
            })()
            """
        ))
        let boundedHeaders = try ServiceJavaScriptNetworkInputBoundary.headers(
            from: oversizedHeaders,
            reader: reader
        )
        XCTAssertEqual(boundedHeaders.count, 64)

        let oversizedArrayBody = try XCTUnwrap(context.evaluateScript(
            "new Array(4097).fill(0)"
        ))
        XCTAssertThrowsError(
            try ServiceJavaScriptNetworkInputBoundary.fetchV2Body(
                from: oversizedArrayBody,
                reader: reader
            )
        )

        let oversizedStringBody = try XCTUnwrap(context.evaluateScript(
            "'x'.repeat(2 * 1024 * 1024 + 1)"
        ))
        XCTAssertThrowsError(
            try ServiceJavaScriptNetworkInputBoundary.fetchV2Body(
                from: oversizedStringBody,
                reader: reader
            )
        )

        let validBody = try XCTUnwrap(context.evaluateScript(
            "({name: 'bounded', values: [1, true, null]})"
        ))
        XCTAssertEqual(
            try ServiceJavaScriptNetworkInputBoundary.fetchV2Body(
                from: validBody,
                reader: reader
            ),
            #"{"name":"bounded","values":[1,true,null]}"#
        )

        XCTAssertEqual(
            try ServiceJavaScriptNetworkInputBoundary.httpMethod(
                from: context.evaluateScript("'customVerb'")
            ),
            "customVerb"
        )
        XCTAssertEqual(
            try ServiceJavaScriptNetworkInputBoundary.httpMethod(
                from: context.evaluateScript("'PROPFIND'")
            ),
            "PROPFIND"
        )
        XCTAssertThrowsError(
            try ServiceJavaScriptNetworkInputBoundary.httpMethod(
                from: context.evaluateScript("'GET POST'")
            )
        )
    }

    func testNativeNetworkEntrypointsRejectOversizedURLMethodAndEncodingBeforeLeasing() throws {
        let context = try XCTUnwrap(JSContext())
        let sandbox = ServiceSandboxState()
        sandbox.installJavaScriptScheduler { callback in callback() }
        sandbox.beginOperation(ServiceSandboxOperation(
            id: UUID(),
            serviceID: UUID(),
            scriptFingerprint: "hostile-scalar-inputs",
            serviceName: "Hostile Scalar Inputs Test",
            operation: "searchResults",
            primaryURL: "https://media.example"
        ))
        let session = URLSession.fetchData(allowRedirects: true)
        context.setupNativeFetch(sandbox: sandbox, serviceSession: session)
        context.setupFetchV2(sandbox: sandbox, serviceSession: session)
        context.setupNetworkFetch(sandbox: sandbox)
        context.setupNetworkFetchSimple(sandbox: sandbox)

        let result = try XCTUnwrap(context.evaluateScript(
            """
            (function () {
                const oversizedURL = 'x'.repeat(16 * 1024 + 1);
                let rejected = 0;
                fetchNative(oversizedURL, {}, function () {}, function () { rejected += 1; });
                networkFetchNative(oversizedURL, {}, function () {}, function () { rejected += 1; });
                networkFetchSimpleNative(oversizedURL, {}, function () {}, function () { rejected += 1; });
                function capture(response) {
                    if (response && response.error) rejected += 1;
                }
                fetchV2Native(oversizedURL, {}, 'GET', null, true, 'utf-8', capture, function () {});
                fetchV2Native('https://media.example/page', {}, 'M'.repeat(65), null, true, 'utf-8', capture, function () {});
                fetchV2Native('https://media.example/page', {}, 'GET', null, true, 'e'.repeat(65), capture, function () {});
                return rejected;
            })()
            """
        ))

        XCTAssertEqual(result.toInt32(), 6)
        XCTAssertEqual(sandbox.liveNativeOperationCount, 0)
    }

    func testServiceBrowserOutputsAreBoundedWithExplicitTruncation() {
        var requests: [String] = []
        var totalBytes = 0
        for index in 0..<ServiceBrowserOutputBoundary.maximumRequestCount {
            XCTAssertEqual(
                ServiceBrowserOutputBoundary.appendRequest(
                    "https://media.example/\(index)",
                    to: &requests,
                    totalBytes: &totalBytes
                ),
                .appended
            )
        }
        XCTAssertEqual(requests.count, ServiceBrowserOutputBoundary.maximumRequestCount)
        XCTAssertEqual(
            ServiceBrowserOutputBoundary.appendRequest(
                "https://media.example/overflow",
                to: &requests,
                totalBytes: &totalBytes
            ),
            .truncated
        )

        var totalLimitedRequests: [String] = []
        var limitedBytes = 0
        var sawTotalTruncation = false
        for index in 0..<ServiceBrowserOutputBoundary.maximumRequestCount {
            let value = "https://media.example/\(index)/"
                + String(repeating: "x", count: 16_000)
            if ServiceBrowserOutputBoundary.appendRequest(
                value,
                to: &totalLimitedRequests,
                totalBytes: &limitedBytes
            ) == .truncated {
                sawTotalTruncation = true
                break
            }
        }
        XCTAssertTrue(sawTotalTruncation)
        XCTAssertLessThanOrEqual(
            limitedBytes,
            ServiceBrowserOutputBoundary.maximumRequestTotalBytes
        )
        XCTAssertEqual(
            ServiceBrowserOutputBoundary.appendRequest(
                String(repeating: "u", count: ServiceBrowserOutputBoundary.maximumRequestURLBytes + 1),
                to: &totalLimitedRequests,
                totalBytes: &limitedBytes
            ),
            .truncated
        )

        let oversizedHTML = String(
            repeating: "é",
            count: ServiceBrowserOutputBoundary.maximumHTMLBytes / 2 + 1
        )
        let boundedHTML = ServiceBrowserOutputBoundary.boundedHTMLPrefix(oversizedHTML)
        XCTAssertTrue(boundedHTML.truncated)
        XCTAssertLessThanOrEqual(
            boundedHTML.html.utf8.count,
            ServiceBrowserOutputBoundary.maximumHTMLBytes
        )
        XCTAssertTrue(boundedHTML.html.hasSuffix("é"))
    }

    func testNetworkFetchOptionsIgnoreExtensionsAndBoundHeadersPerField() throws {
        let context = try XCTUnwrap(JSContext())
        let reader = try XCTUnwrap(ServiceJavaScriptValueReader(context: context))
        let value = try XCTUnwrap(context.evaluateScript(
            """
            (function () {
                const headers = {};
                for (let index = 0; index < 65; index++) {
                    headers["X-Test-" + index] = "value";
                }
                return {
                    timeoutSeconds: 5,
                    headers: headers,
                    htmlContent: null,
                    compatibilityExtension: "ignored"
                };
            })()
            """
        ))
        let full = try ServiceNetworkFetchInputBoundary.networkFetchOptions(
            from: value,
            reader: reader
        )
        let simple = try ServiceNetworkFetchInputBoundary.simpleOptions(
            from: value,
            reader: reader
        )

        XCTAssertEqual(full.timeoutSeconds, 5)
        XCTAssertEqual(full.headers.count, 64)
        XCTAssertEqual(simple.timeoutSeconds, 5)
        XCTAssertEqual(simple.headers.count, 64)
    }

    func testFetchV2GETBodyRejectionDoesNotConsumeNativeOperationBudget() throws {
        let context = try XCTUnwrap(JSContext())
        let sandbox = ServiceSandboxState()
        sandbox.installJavaScriptScheduler { callback in callback() }
        sandbox.beginOperation(ServiceSandboxOperation(
            id: UUID(),
            serviceID: UUID(),
            scriptFingerprint: "get-body",
            serviceName: "GET Body Test",
            operation: "searchResults",
            primaryURL: "https://media.example"
        ))
        context.setupFetchV2(
            sandbox: sandbox,
            serviceSession: URLSession.fetchData(allowRedirects: true)
        )

        let result = try XCTUnwrap(context.evaluateScript(
            """
            (function () {
                let rejected = 0;
                for (let index = 0; index < 32; index++) {
                    fetchV2Native(
                        "https://media.example/page",
                        {},
                        "GET",
                        "payload",
                        true,
                        "utf-8",
                        function (response) {
                            if (response && response.error) rejected += 1;
                        },
                        function () {}
                    );
                }
                return rejected;
            })()
            """
        ))

        XCTAssertEqual(result.toInt32(), 32)
        XCTAssertEqual(sandbox.liveNativeOperationCount, 0)
    }

    @MainActor
    func testServiceTimerBridgeSurvivesNonFiniteHugeAndFloodedDelays() async throws {
        let suiteName = "ServiceJavaScriptTimerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ServiceJavaScriptQuarantineStore(defaults: defaults, strikeLimit: 1)
        let pool = ServiceJavaScriptWorkerPool(maximumConcurrentWorkers: 1)
        let lane = try XCTUnwrap(pool.leaseLane())
        let controller = JSController(worker: lane, quarantineStore: store)
        let service = makeJavaScriptIsolationTestService(
            name: "Timer Flood Test",
            script: """
            function searchResults(query) {
                const ids = [
                    setTimeout(function() {}, NaN),
                    setTimeout(function() {}, Infinity),
                    setTimeout(function() {}, -Infinity),
                    setTimeout(function() {}, Number.MAX_VALUE),
                    setInterval(function() {}, NaN)
                ];
                for (let index = 0; index < 1000; index++) {
                    ids.push(setTimeout(function() {}, index));
                }
                const accepted = ids.filter(function(id) { return id > 0; });
                accepted.forEach(clearTimeout);
                return Promise.resolve(JSON.stringify([{
                    title: String(accepted.length),
                    image: "https://media.example/poster.jpg",
                    href: "https://media.example/timers"
                }]));
            }
            """
        )
        controller.loadScript(service.jsScript, service: service)

        let result = await fetchIsolationSearch(
            controller: controller,
            service: service,
            timeoutNanoseconds: 1_000_000_000
        )

        XCTAssertEqual(result.map(\.title), ["64"])
        XCTAssertFalse(store.isQuarantined(service))
        XCTAssertTrue(lane.isAvailable)
    }

    @MainActor
    func testRapidSupersedingLoadsDoNotQuarantineAQueuedScript() async throws {
        let suiteName = "ServiceJavaScriptSupersededLoadTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ServiceJavaScriptQuarantineStore(defaults: defaults, strikeLimit: 1)
        let pool = ServiceJavaScriptWorkerPool(maximumConcurrentWorkers: 1)
        let lane = try XCTUnwrap(pool.leaseLane())
        let controller = JSController(worker: lane, quarantineStore: store)
        let first = makeJavaScriptIsolationTestService(
            name: "Superseded Script",
            script: "function searchResults(query) { return Promise.resolve(JSON.stringify([])); }"
        )
        let second = makeJavaScriptIsolationTestService(
            name: "Current Script",
            script: """
            function searchResults(query) {
                return Promise.resolve(JSON.stringify([{
                    title: "Current",
                    image: "https://media.example/poster.jpg",
                    href: "https://media.example/current"
                }]));
            }
            """
        )

        lane.async { Thread.sleep(forTimeInterval: 0.08) }
        controller.loadScript(
            first.jsScript,
            service: first,
            timeoutNanoseconds: 20_000_000
        )
        controller.loadScript(
            second.jsScript,
            service: second,
            timeoutNanoseconds: 1_000_000_000
        )
        let result = await fetchIsolationSearch(
            controller: controller,
            service: second,
            timeoutNanoseconds: 1_000_000_000
        )

        XCTAssertEqual(result.map(\.title), ["Current"])
        XCTAssertFalse(store.isQuarantined(first))
        XCTAssertFalse(store.isQuarantined(second))
        XCTAssertTrue(lane.isAvailable)
    }

    @MainActor
    func testSynchronousServiceLoopTimesOutOffMainAndQuarantinesFirstStrike() async throws {
        let suiteName = "ServiceJavaScriptLoopTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ServiceJavaScriptQuarantineStore(defaults: defaults, strikeLimit: 1)
        let pool = ServiceJavaScriptWorkerPool(maximumConcurrentWorkers: 1)
        let lane = try XCTUnwrap(pool.leaseLane())
        let controller = JSController(worker: lane, quarantineStore: store)
        let service = makeJavaScriptIsolationTestService(
            name: "Busy Loop Test",
            script: """
            function searchResults(query) {
                const until = Date.now() + 300;
                while (Date.now() < until) {}
                return Promise.resolve(JSON.stringify([]));
            }
            """
        )
        controller.loadScript(service.jsScript, service: service)

        let start = ContinuousClock.now
        let result = await fetchIsolationSearch(
            controller: controller,
            service: service,
            timeoutNanoseconds: 30_000_000
        )
        let elapsed = start.duration(to: .now)

        XCTAssertTrue(result.isEmpty)
        XCTAssertLessThan(elapsed, .milliseconds(200))
        XCTAssertTrue(store.isQuarantined(service))
        XCTAssertFalse(lane.isAvailable)
    }

    @MainActor
    func testStuckWorkerRehomesUnrelatedQueuedControllerToSurvivingLane() async throws {
        let suiteName = "ServiceJavaScriptLaneRehomeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ServiceJavaScriptQuarantineStore(defaults: defaults, strikeLimit: 1)
        let pool = ServiceJavaScriptWorkerPool(maximumConcurrentWorkers: 2)
        let hostileLane = try XCTUnwrap(pool.leaseLane())
        let survivingLane = try XCTUnwrap(pool.leaseLane())
        let healthyControllerLane = try XCTUnwrap(pool.leaseLane())
        XCTAssertTrue(hostileLane === healthyControllerLane)

        let hostileController = JSController(worker: hostileLane, quarantineStore: store)
        let healthyController = JSController(worker: healthyControllerLane, quarantineStore: store)
        let hostileService = makeJavaScriptIsolationTestService(
            name: "Lane Hostile Service",
            script: """
            function searchResults(query) {
                const until = Date.now() + 500;
                while (Date.now() < until) {}
                return Promise.resolve(JSON.stringify([]));
            }
            """
        )
        let healthyService = makeJavaScriptIsolationTestService(
            name: "Lane Healthy Service",
            script: """
            function searchResults(query) {
                return Promise.resolve(JSON.stringify([{
                    title: "Rehomed",
                    image: "https://media.example/poster.jpg",
                    href: "https://media.example/rehomed"
                }]));
            }
            """
        )
        hostileController.loadScript(hostileService.jsScript, service: hostileService)
        let hostileFunctionLoaded = await hostileController.hasJavaScriptFunction(
            named: "searchResults"
        )
        XCTAssertTrue(hostileFunctionLoaded)

        async let hostileResult = fetchIsolationSearch(
            controller: hostileController,
            service: hostileService,
            timeoutNanoseconds: 30_000_000
        )
        try? await Task.sleep(nanoseconds: 10_000_000)
        healthyController.loadScript(
            healthyService.jsScript,
            service: healthyService,
            timeoutNanoseconds: 1_000_000_000
        )
        let healthyResult = await fetchIsolationSearch(
            controller: healthyController,
            service: healthyService,
            timeoutNanoseconds: 1_000_000_000
        )
        let completedHostileResult = await hostileResult

        XCTAssertTrue(completedHostileResult.isEmpty)
        XCTAssertEqual(healthyResult.map(\.title), ["Rehomed"])
        XCTAssertTrue(store.isQuarantined(hostileService))
        XCTAssertFalse(store.isQuarantined(healthyService))
        XCTAssertFalse(hostileLane.isAvailable)
        XCTAssertTrue(survivingLane.isAvailable)
    }

    @MainActor
    func testRehomedControllerHangRetiresReplacementLaneAndExhaustsExactPool() async throws {
        let suiteName = "ServiceJavaScriptReplacementLaneTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ServiceJavaScriptQuarantineStore(defaults: defaults, strikeLimit: 1)
        let pool = ServiceJavaScriptWorkerPool(maximumConcurrentWorkers: 2)
        let firstLane = try XCTUnwrap(pool.leaseLane())
        let secondLane = try XCTUnwrap(pool.leaseLane())
        let rehomedControllerLane = try XCTUnwrap(pool.leaseLane())
        XCTAssertTrue(firstLane === rehomedControllerLane)

        let firstController = JSController(worker: firstLane, quarantineStore: store)
        let rehomedController = JSController(
            worker: rehomedControllerLane,
            quarantineStore: store
        )
        let firstHostile = makeJavaScriptIsolationTestService(
            name: "First Physical Lane Hostile",
            script: """
            function searchResults(query) {
                const until = Date.now() + 500;
                while (Date.now() < until) {}
                return Promise.resolve(JSON.stringify([]));
            }
            """
        )
        let rehomedServiceID = UUID()
        let initiallyHealthy = makeJavaScriptIsolationTestService(
            id: rehomedServiceID,
            name: "Replacement Lane Service",
            script: """
            function searchResults(query) {
                return Promise.resolve(JSON.stringify([{
                    title: "Survived First Lane",
                    image: "https://media.example/poster.jpg",
                    href: "https://media.example/healthy"
                }]));
            }
            """
        )
        firstController.loadScript(firstHostile.jsScript, service: firstHostile)
        let firstLoaded = await firstController.hasJavaScriptFunction(named: "searchResults")
        XCTAssertTrue(firstLoaded)

        async let firstResult = fetchIsolationSearch(
            controller: firstController,
            service: firstHostile,
            timeoutNanoseconds: 30_000_000
        )
        try? await Task.sleep(nanoseconds: 10_000_000)
        rehomedController.loadScript(
            initiallyHealthy.jsScript,
            service: initiallyHealthy,
            timeoutNanoseconds: 1_000_000_000
        )
        let healthyResult = await fetchIsolationSearch(
            controller: rehomedController,
            service: initiallyHealthy,
            timeoutNanoseconds: 1_000_000_000
        )
        let completedFirstResult = await firstResult
        XCTAssertTrue(completedFirstResult.isEmpty)
        XCTAssertEqual(healthyResult.map(\.title), ["Survived First Lane"])
        XCTAssertFalse(firstLane.isAvailable)
        XCTAssertTrue(secondLane.isAvailable)

        let replacementHostile = makeJavaScriptIsolationTestService(
            id: rehomedServiceID,
            name: "Replacement Lane Service",
            script: """
            function searchResults(query) {
                const until = Date.now() + 500;
                while (Date.now() < until) {}
                return Promise.resolve(JSON.stringify([]));
            }
            """
        )
        rehomedController.loadScript(
            replacementHostile.jsScript,
            service: replacementHostile,
            timeoutNanoseconds: 1_000_000_000
        )
        let replacementResult = await fetchIsolationSearch(
            controller: rehomedController,
            service: replacementHostile,
            timeoutNanoseconds: 30_000_000
        )

        XCTAssertTrue(replacementResult.isEmpty)
        XCTAssertTrue(store.isQuarantined(replacementHostile))
        XCTAssertFalse(secondLane.isAvailable)
        let firstReplacement = try XCTUnwrap(
            pool.leaseLane(),
            "a wedged lane is replaced within a bounded budget rather than shrinking the pool until relaunch"
        )
        firstReplacement.markPermanentlyUnavailable()
        let secondReplacement = try XCTUnwrap(pool.leaseLane())
        secondReplacement.markPermanentlyUnavailable()
        XCTAssertNil(pool.leaseLane(), "the replacement budget is finite")

        let exhaustedController = JSController(
            worker: pool.leaseLane(),
            quarantineStore: store
        )
        let hasFunction = await exhaustedController.hasJavaScriptFunction(named: "searchResults")
        XCTAssertFalse(hasFunction)
    }

    @MainActor
    func testUnavailableServiceLaneMakesFunctionProbeReturnFalsePromptly() async throws {
        let suiteName = "ServiceJavaScriptUnavailableProbeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ServiceJavaScriptQuarantineStore(defaults: defaults)
        let pool = ServiceJavaScriptWorkerPool(maximumConcurrentWorkers: 1)
        let lane = try XCTUnwrap(pool.leaseLane())
        let controller = JSController(worker: lane, quarantineStore: store)

        lane.markPermanentlyUnavailable()

        let start = ContinuousClock.now
        let hasFunction = await controller.hasJavaScriptFunction(named: "searchResults")
        let elapsed = start.duration(to: .now)

        XCTAssertFalse(hasFunction)
        XCTAssertLessThan(elapsed, .milliseconds(200))
    }

    @MainActor
    func testExhaustedServiceWorkerPoolFailsNewControllerClosedWithoutHanging() async throws {
        let suiteName = "ServiceJavaScriptExhaustedPoolTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ServiceJavaScriptQuarantineStore(defaults: defaults)
        let pool = ServiceJavaScriptWorkerPool(maximumConcurrentWorkers: 2)
        let firstLane = try XCTUnwrap(pool.leaseLane())
        let secondLane = try XCTUnwrap(pool.leaseLane())
        firstLane.markPermanentlyUnavailable()
        secondLane.markPermanentlyUnavailable()

        let firstReplacement = try XCTUnwrap(
            pool.leaseLane(),
            "a wedged pool grants a bounded replacement rather than dying until relaunch"
        )
        firstReplacement.markPermanentlyUnavailable()
        let secondReplacement = try XCTUnwrap(pool.leaseLane())
        secondReplacement.markPermanentlyUnavailable()
        XCTAssertNil(pool.leaseLane(), "the replacement budget is finite")

        let controller = JSController(worker: pool.leaseLane(), quarantineStore: store)
        let service = makeJavaScriptIsolationTestService(
            name: "Exhausted Pool Test",
            script: "function searchResults(query) { return Promise.resolve(JSON.stringify([])); }"
        )
        controller.loadScript(service.jsScript, service: service)

        let start = ContinuousClock.now
        async let functionProbe = controller.hasJavaScriptFunction(named: "searchResults")
        async let searchResult = fetchIsolationSearch(
            controller: controller,
            service: service,
            timeoutNanoseconds: 1_000_000_000
        )
        let (hasFunction, result) = await (functionProbe, searchResult)
        let elapsed = start.duration(to: .now)

        XCTAssertFalse(hasFunction)
        XCTAssertTrue(result.isEmpty)
        XCTAssertLessThan(elapsed, .milliseconds(200))
        XCTAssertFalse(store.isQuarantined(service))
    }

    @MainActor
    func testUnresolvedPromiseTimesOutWithoutQuarantineAndFreshRuntimeRecovers() async throws {
        let suiteName = "ServiceJavaScriptPromiseTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ServiceJavaScriptQuarantineStore(defaults: defaults)
        let pool = ServiceJavaScriptWorkerPool(maximumConcurrentWorkers: 1)
        let lane = try XCTUnwrap(pool.leaseLane())
        let controller = JSController(worker: lane, quarantineStore: store)
        let serviceID = UUID()
        let unresolved = makeJavaScriptIsolationTestService(
            id: serviceID,
            name: "Unresolved Promise Test",
            script: "function searchResults(query) { return new Promise(function() {}); }"
        )
        controller.loadScript(unresolved.jsScript, service: unresolved)

        let first = await fetchIsolationSearch(
            controller: controller,
            service: unresolved,
            timeoutNanoseconds: 30_000_000
        )

        XCTAssertTrue(first.isEmpty)
        XCTAssertFalse(store.isQuarantined(unresolved))
        XCTAssertTrue(lane.isAvailable)

        let healthy = makeJavaScriptIsolationTestService(
            id: serviceID,
            name: "Unresolved Promise Test",
            script: """
            function searchResults(query) {
                return Promise.resolve(JSON.stringify([{
                    title: "Recovered",
                    image: "https://media.example/poster.jpg",
                    href: "https://media.example/title"
                }]));
            }
            """
        )
        controller.loadScript(healthy.jsScript, service: healthy)
        let recovered = await fetchIsolationSearch(
            controller: controller,
            service: healthy,
            timeoutNanoseconds: 1_000_000_000
        )

        XCTAssertEqual(recovered.map(\.title), ["Recovered"])
        XCTAssertFalse(store.isQuarantined(healthy))
        XCTAssertTrue(lane.isAvailable)
    }

    @MainActor
    func testServiceStreamCancellationReloadsSameControllerBeforeImmediateRetry() async {
        let service = makeStreamCancellationTestService()
        let controller = JSController()
        controller.loadScript(service.jsScript, service: service)
        let abandonedCallbacks = CallbackRecorder<Bool>()

        let abandoned = controller.fetchStreamUrlJS(
            episodeUrl: "hang",
            module: service,
            timeoutNanoseconds: 1_000_000_000
        ) { _ in
            abandonedCallbacks.append(true)
        }
        XCTAssertTrue(abandoned.cancel())

        let result = await withCheckedContinuation { continuation in
            controller.fetchStreamUrlJS(
                episodeUrl: "retry",
                module: service,
                timeoutNanoseconds: 1_000_000_000
            ) { result in
                continuation.resume(returning: result)
            }
        }

        XCTAssertEqual(result.streams, ["https://media.example/retry.m3u8"])
        XCTAssertNil(result.subtitles)
        XCTAssertNil(result.sources)
        XCTAssertTrue(abandonedCallbacks.values.isEmpty)
    }

    @MainActor
    func testStaleStreamCancellationDoesNotDetachNewerOperationContext() async {
        let service = makeStreamCancellationTestService()
        let controller = JSController()
        controller.loadScript(service.jsScript, service: service)
        let oldOperation = controller.beginServiceOperation(
            service: service,
            operation: "extractStreamUrl",
            primaryURL: "old"
        )
        let newerOperation = controller.beginServiceOperation(
            service: service,
            operation: "extractStreamUrl",
            primaryURL: "new"
        )

        controller.cancelPendingServiceOperation(oldOperation, reason: "stale-timeout")

        let hasFunction = await controller.hasJavaScriptFunction(named: "extractStreamUrl")
        XCTAssertTrue(hasFunction)
        controller.endServiceOperation(newerOperation, reason: "test-complete")
    }

    func testBoundedResponseBufferRejectsBeforeAcceptingBytePastLimit() throws {
        var buffer = try BoundedResponseBuffer(maximumBytes: 3)
        try buffer.append(1)
        try buffer.append(2)
        try buffer.append(3)

        XCTAssertEqual(buffer.data, Data([1, 2, 3]))
        XCTAssertThrowsError(try buffer.append(4)) { error in
            XCTAssertEqual(
                error as? BoundedURLSessionError,
                .responseTooLarge(maximumBytes: 3)
            )
        }
        XCTAssertEqual(buffer.data, Data([1, 2, 3]))
    }

    func testBoundedResponseBufferRejectsOversizedContentLengthImmediately() {
        XCTAssertThrowsError(
            try BoundedResponseBuffer(maximumBytes: 4, expectedContentLength: 5)
        ) { error in
            XCTAssertEqual(
                error as? BoundedURLSessionError,
                .responseTooLarge(maximumBytes: 4)
            )
        }
    }

    func testBoundedResponseBufferAppendsChunksWithoutAcceptingPartialOverflow() throws {
        var buffer = try BoundedResponseBuffer(maximumBytes: 3)
        try buffer.append(Data([1, 2]))

        XCTAssertThrowsError(try buffer.append(Data([3, 4]))) { error in
            XCTAssertEqual(
                error as? BoundedURLSessionError,
                .responseTooLarge(maximumBytes: 3)
            )
        }
        XCTAssertEqual(buffer.data, Data([1, 2]))
    }

    func testBoundedDataDelegateAcceptsChunkedResponseAtExactLimit() async throws {
        let session = makeBoundedResponseSession()
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.boundedData(
            from: URL(string: "https://bounded-response.test/exact")!,
            maximumResponseBytes: 3
        )

        XCTAssertEqual(data, Data([1, 2, 3]))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    func testBoundedDataDelegatePreservesHTTPErrorResponse() async throws {
        let session = makeBoundedResponseSession()
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.boundedData(
            from: URL(string: "https://bounded-response.test/status")!,
            maximumResponseBytes: 3
        )

        XCTAssertEqual(data, Data([1, 2, 3]))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
    }

    func testBoundedDataDelegateRejectsDeclaredOversizeBeforeBody() async {
        let session = makeBoundedResponseSession()
        defer { session.invalidateAndCancel() }

        do {
            _ = try await session.boundedData(
                from: URL(string: "https://bounded-response.test/declared-oversize")!,
                maximumResponseBytes: 3
            )
            XCTFail("Expected an oversized response error")
        } catch {
            XCTAssertEqual(
                error as? BoundedURLSessionError,
                .responseTooLarge(maximumBytes: 3)
            )
        }
    }

    func testBoundedDataDelegateRejectsStreamedOverflow() async {
        let session = makeBoundedResponseSession()
        defer { session.invalidateAndCancel() }

        do {
            _ = try await session.boundedData(
                from: URL(string: "https://bounded-response.test/streamed-oversize")!,
                maximumResponseBytes: 3
            )
            XCTFail("Expected an oversized response error")
        } catch {
            XCTAssertEqual(
                error as? BoundedURLSessionError,
                .responseTooLarge(maximumBytes: 3)
            )
        }
    }

    func testBoundedDataDelegateCancellationResumesPromptly() async {
        let session = makeBoundedResponseSession()
        defer { session.invalidateAndCancel() }

        let requestTask = Task {
            try await session.boundedData(
                from: URL(string: "https://bounded-response.test/slow")!,
                maximumResponseBytes: 3
            )
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        requestTask.cancel()

        do {
            _ = try await requestTask.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    private func makeBoundedResponseSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedResponseURLProtocol.self]
        return URLSession(
            configuration: configuration,
            delegate: FetchDelegate(allowRedirects: true),
            delegateQueue: nil
        )
    }

    func testLoggerRedactsUntrustedURLsHeadersCookiesAndTokens() {
        let message = """
        provider=https://user:password@addons.example.com/private-token/manifest.json?access_token=query-secret#fragment
        Authorization: Bearer header-secret
        Cookie: session=cookie-secret; secondary=still-secret
        refresh_token=loose-secret
        """

        let redacted = Logger.redactedSensitiveMessage(message)

        XCTAssertTrue(redacted.contains("https://addons.example.com"))
        XCTAssertTrue(redacted.contains("Authorization=<redacted>"))
        XCTAssertTrue(redacted.contains("Cookie=<redacted>"))
        XCTAssertFalse(redacted.contains("private-token"))
        XCTAssertFalse(redacted.contains("query-secret"))
        XCTAssertFalse(redacted.contains("header-secret"))
        XCTAssertFalse(redacted.contains("cookie-secret"))
        XCTAssertFalse(redacted.contains("still-secret"))
        XCTAssertFalse(redacted.contains("loose-secret"))
        XCTAssertFalse(redacted.contains("user:password"))
    }

    func testLoggerRedactionFastPathPreservesOrdinaryDiagnostics() {
        let message = "MPV frame ready generation=42 bufferedSeconds=8.5"
        XCTAssertEqual(Logger.redactedSensitiveMessage(message), message)
    }

    func testLoggerRedactionFastPathStillAppliesMaximumLength() {
        XCTAssertEqual(
            Logger.redactedSensitiveMessage("ordinary diagnostic", maximumLength: 8),
            "ordinary...<truncated>"
        )
    }

    func testMediaStateRecordNameSanitizesCloudKitSeparators() {
        XCTAssertEqual(
            MediaStateRecordName.make(kind: .rating, identifier: "tv/42#user"),
            "rating|tv_42_user"
        )
    }

    func testPlaybackRequestDropsHeaderInjectionAndEmptyValues() throws {
        let request = PlaybackRequest(
            url: try XCTUnwrap(URL(string: "https://media.example/video.m3u8")),
            headers: [
                "Authorization": "  Bearer secret  ",
                "X-Injected\r\nHeader": "blocked",
                "X-Value": "unsafe\nvalue",
                "Empty": "   "
            ]
        )

        XCTAssertEqual(request.headers, ["Authorization": "Bearer secret"])
    }

    func testTMDBRateLimiterEnforcesGlobalStartSpacingAndConcurrencyLimit() async throws {
        let limiter = TMDBRateLimiter(maxConcurrent: 2, minInterval: 0.025)
        let probe = RateLimiterProbe()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try await limiter.execute {
                        await probe.begin(at: DispatchTime.now().uptimeNanoseconds)
                        do {
                            try await Task.sleep(nanoseconds: 60_000_000)
                            await probe.end()
                        } catch {
                            await probe.end()
                            throw error
                        }
                    }
                }
            }
            try await group.waitForAll()
        }

        let snapshot = await probe.snapshot()
        XCTAssertLessThanOrEqual(snapshot.peakInFlight, 2)
        XCTAssertEqual(snapshot.starts.count, 6)

        let orderedStarts = snapshot.starts.sorted()
        for (earlier, later) in zip(orderedStarts, orderedStarts.dropFirst()) {
            XCTAssertGreaterThanOrEqual(
                later - earlier,
                20_000_000,
                "Request starts should remain globally spaced instead of waking as a burst"
            )
        }
    }

    func testTMDBRateLimiterRemovesCanceledWaiterWithoutBlockingNextRequest() async throws {
        let limiter = TMDBRateLimiter(maxConcurrent: 1, minInterval: 0)
        let blocker = BlockingRateLimiterOperation()
        let recorder = RateLimiterEventRecorder()

        let first = Task {
            try await limiter.execute {
                await blocker.signalStarted()
                await blocker.waitForRelease()
            }
        }
        await blocker.waitUntilStarted()

        let canceled = Task {
            try await limiter.execute {
                await recorder.record(2)
            }
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        canceled.cancel()

        let next = Task {
            try await limiter.execute {
                await recorder.record(3)
            }
        }

        await blocker.release()
        try await first.value
        do {
            try await canceled.value
            XCTFail("Expected the queued limiter request to be canceled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        try await next.value

        let recordedEvents = await recorder.snapshot()
        XCTAssertEqual(recordedEvents, [3])
    }

    func testAniListCatalogPageRequestUsesDirectBoundedPagination() {
        let thirdPage = AniListCatalogPageRequest(page: 3, requestedPageSize: 20)
        XCTAssertEqual(thirdPage.page, 3)
        XCTAssertEqual(thirdPage.perPage, 20)
        XCTAssertEqual(
            thirdPage.graphQLArguments,
            "page: 3, perPage: 20"
        )
        XCTAssertEqual(
            AniListCatalogPageRequest(page: 0, requestedPageSize: 500).graphQLArguments,
            "page: 1, perPage: 50"
        )
    }

    func testAniListCatalogQueryPlanRequestsOnlyEnabledKindsInStableOrder() {
        let plan = AniListService.CatalogQueryPlan(
            kinds: [.upcoming, .trending],
            requestedLimit: 500
        )

        XCTAssertEqual(plan.orderedKinds, [.trending, .upcoming])
        XCTAssertEqual(plan.limit, 50)
        XCTAssertEqual(plan.query.components(separatedBy: "Page(perPage:").count - 1, 2)
        XCTAssertTrue(plan.query.contains("trending: Page(perPage: 50)"))
        XCTAssertTrue(plan.query.contains("sort: [TRENDING_DESC]"))
        XCTAssertTrue(plan.query.contains("upcoming: Page(perPage: 50)"))
        XCTAssertTrue(plan.query.contains("status: NOT_YET_RELEASED"))
        XCTAssertFalse(plan.query.contains("popular: Page"))
        XCTAssertFalse(plan.query.contains("topRated: Page"))
        XCTAssertFalse(plan.query.contains("airing: Page"))
    }

    func testAniListRateLimiterExtendsAnAlreadyReservedWaiterForServerPause() async throws {
        // burstCapacity 1 pins the strict-spacing configuration: the invariant
        // under test (a sleeping waiter requeues behind a later 429 pause)
        // requires the second waiter to actually sleep out its reservation.
        let limiter = AniListRateLimiter(minInterval: 0.12, burstCapacity: 1)
        try await limiter.waitForSlot()

        let clock = ContinuousClock()
        let startedAt = clock.now
        let waiter = Task {
            try await limiter.waitForSlot()
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        await limiter.pause(for: 0.22)
        try await waiter.value

        let elapsed = startedAt.duration(to: clock.now)
        XCTAssertGreaterThanOrEqual(
            elapsed,
            .milliseconds(190),
            "A waiter with a stale reservation must requeue behind a later 429 pause"
        )
    }

    func testAniListRateLimiterAdmitsBurstThenEnforcesSpacing() async throws {
        // The limiter is single-lane: burst credit belongs to every caller. An
        // earlier draft of these tests asked for a `lane:` argument, which was
        // never implemented — and could not be usefully added, because
        // `waitForSlot` has exactly one call site (the anime-detail structure
        // fetch) and that is the very path the burst exists to speed up.
        let limiter = AniListRateLimiter(minInterval: 0.15, burstCapacity: 3)
        let clock = ContinuousClock()

        let startedAt = clock.now
        for _ in 0..<3 {
            try await limiter.waitForSlot()
        }
        let burstElapsed = startedAt.duration(to: clock.now)
        XCTAssertLessThan(
            burstElapsed,
            .milliseconds(100),
            "An idle limiter must admit up to burstCapacity requests without spacing delays"
        )

        try await limiter.waitForSlot()
        let fourthElapsed = startedAt.duration(to: clock.now)
        XCTAssertGreaterThanOrEqual(
            fourthElapsed,
            .milliseconds(120),
            "Requests beyond the burst allowance must wait out the configured spacing"
        )
    }

    func testAniListRateLimiterBurstDoesNotCompoundOverSustainedTraffic() async throws {
        // The load-bearing half of the burst design: the virtual schedule may
        // lag `now` by at most the burst allowance, never further. Without that
        // ceiling an idle period would bank unlimited credit and a later flurry
        // would fire every request at once — which is what gets an API key
        // throttled. Six requests at burstCapacity 3 must therefore pay spacing
        // for the last three.
        let limiter = AniListRateLimiter(minInterval: 0.15, burstCapacity: 3)
        let clock = ContinuousClock()

        let startedAt = clock.now
        for _ in 0..<6 {
            try await limiter.waitForSlot()
        }
        let elapsed = startedAt.duration(to: clock.now)
        XCTAssertGreaterThanOrEqual(
            elapsed,
            .milliseconds(400),
            "Sustained traffic must average minInterval once the burst allowance is spent"
        )
    }

    func testAniListRateLimiterBurstAdmissionStillRespectsExpiredDeadline() async throws {
        let limiter = AniListRateLimiter(minInterval: 0.1, burstCapacity: 4)
        do {
            try await limiter.waitForSlot(deadline: Date().addingTimeInterval(-0.5))
            XCTFail("An already-expired deadline must fail even when burst credit is available")
        } catch {
            // Deliberately NOT `URLError(.timedOut)`. Nothing has been sent to
            // AniList when this throws, so grading it as a transport timeout
            // let `classifyAniListFailure` escalate our own queue depth into a
            // 180-second "AniList unavailable" state plus a user-facing
            // MyAnimeList-fallback notice, while AniList was answering every
            // request normally. The distinct type is what makes that
            // misclassification impossible.
            guard case AniListRateLimiterError.localBackPressure = error else {
                XCTFail("Expected localBackPressure, got \(error)")
                return
            }
        }
    }

    func testAniListRateLimiterBoundsHostileServerDelaysWithoutIntegerTraps() {
        XCTAssertEqual(AniListRateLimiter.boundedRetryAfter("nan"), 5)
        XCTAssertEqual(AniListRateLimiter.boundedRetryAfter("inf"), 5)
        XCTAssertEqual(AniListRateLimiter.boundedRetryAfter("-1"), 5)
        XCTAssertEqual(AniListRateLimiter.boundedRetryAfter("1e300"), 120)
        XCTAssertEqual(AniListRateLimiter.boundedRetryAfter("3"), 3)

        XCTAssertNil(AniListRateLimiter.boundedRateLimitInterval("nan"))
        XCTAssertEqual(AniListRateLimiter.boundedRateLimitInterval("1e-300"), 60)
        XCTAssertNil(AniListRateLimiter.boundedRateLimitInterval("1e-320"))
        XCTAssertEqual(AniListRateLimiter.boundedRateLimitInterval("0.1"), 60)
        XCTAssertEqual(AniListRateLimiter.boundedRateLimitInterval("90"), 0.8)

        XCTAssertNil(AniListRateLimiter.boundedResetDelay("nan"))
        XCTAssertEqual(
            AniListRateLimiter.boundedResetDelay(
                "1e300",
                now: Date(timeIntervalSince1970: 1_000)
            ),
            120
        )
        XCTAssertEqual(AniListRateLimiter.nanoseconds(for: .nan), 0)
        XCTAssertEqual(AniListRateLimiter.nanoseconds(for: 1e300), UInt64.max)
    }

    func testAniMapResponseBoundaryRejectsCompactHostileContainersAndStrings() throws {
        let validLookup = Data(#"[{"tmdb_show_id":1,"anilist_id":2}]"#.utf8)
        XCTAssertNoThrow(try AniMapResponseBoundary.validate(validLookup, scope: .lookup))

        let excessLookupRows = Data(
            ("[" + String(repeating: "{},", count: AniMapResponseBoundary.maximumLookupRows) + "{}]").utf8
        )
        XCTAssertThrowsError(
            try AniMapResponseBoundary.validate(excessLookupRows, scope: .lookup)
        )

        let oversizedField = Data(
            ("[{\"imdb_id\":\"" + String(repeating: "a", count: 4 * 1_024 + 1) + "\"}]").utf8
        )
        XCTAssertThrowsError(
            try AniMapResponseBoundary.validate(oversizedField, scope: .globalIndex)
        )

        let excessiveDepth = Data("[[[[[[[[[0]]]]]]]]]".utf8)
        XCTAssertThrowsError(
            try AniMapResponseBoundary.validate(excessiveDepth, scope: .lookup)
        )
    }

    func testAnimeEpisodeContextIndexPrecomputesStableAbsoluteNumbersAndSeasonCounts() {
        let episodes = [
            testAnimeEpisode(season: 2, number: 2, tmdbSeason: 4, tmdbEpisode: 9),
            testAnimeEpisode(season: 1, number: 2, tmdbSeason: 1, tmdbEpisode: 2),
            testAnimeEpisode(season: 1, number: 1, tmdbSeason: 1, tmdbEpisode: 1)
        ]
        let index = AnimeEpisodeContextIndex(episodes: episodes)

        XCTAssertEqual(index.absoluteNumber(seasonNumber: 1, episodeNumber: 1), 1)
        XCTAssertEqual(index.absoluteNumber(seasonNumber: 1, episodeNumber: 2), 2)
        XCTAssertEqual(index.absoluteNumber(seasonNumber: 2, episodeNumber: 2), 3)
        XCTAssertEqual(index.episodeCount(seasonNumber: 1), 2)
        XCTAssertEqual(index.episodeCount(seasonNumber: 2), 1)
        XCTAssertNil(index.episodeCount(seasonNumber: 3))
        XCTAssertEqual(
            index.episode(seasonNumber: 2, episodeNumber: 2)?.tmdbEpisodeNumber,
            9
        )
    }

    func testAnimeSeasonIdentityCoordinatorBatchesConcurrentDistinctIDs() async {
        let coordinator = AnimeSeasonIdentityRequestCoordinator()
        let recorder = AnimeIdentityBatchRecorder()
        let firstKey = AnimeSeasonIdentityRequestKey(anilistId: 101, languageCode: "en")
        let secondKey = AnimeSeasonIdentityRequestKey(anilistId: 202, languageCode: "en")

        async let first = coordinator.value(for: firstKey) { keys in
            await recorder.fetch(keys: keys)
        }
        async let second = coordinator.value(for: secondKey) { keys in
            await recorder.fetch(keys: keys)
        }

        let values = await (first, second)
        XCTAssertEqual(values.0?.anilistId, 101)
        XCTAssertEqual(values.1?.anilistId, 202)
        let batches = await recorder.snapshot()
        XCTAssertEqual(batches, [[101, 202]])
    }

    private func testAnimeEpisode(
        season: Int,
        number: Int,
        tmdbSeason: Int,
        tmdbEpisode: Int
    ) -> AniListEpisode {
        AniListEpisode(
            number: number,
            title: "Episode \(number)",
            description: nil,
            seasonNumber: season,
            stillPath: nil,
            airDate: nil,
            runtime: nil,
            tmdbSeasonNumber: tmdbSeason,
            tmdbEpisodeNumber: tmdbEpisode
        )
    }
}
