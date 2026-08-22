import CommonCrypto
import CryptoKit
import Foundation
import JavaScriptCore
import SwiftSoup

enum NuvioPluginRuntime {

    private static let queueRegistryLock = NSLock()
    private static var providerQueues: [String: DispatchQueue] = [:]

    fileprivate static func providerQueue(for scraperID: String) -> DispatchQueue {
        queueRegistryLock.lock()
        defer { queueRegistryLock.unlock() }
        if let existing = providerQueues[scraperID] { return existing }
        let sanitized = scraperID.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "-",
            options: .regularExpression
        )
        let queue = DispatchQueue(
            label: "app.eclipse.soupy.nuvio-plugin-runtime.\(sanitized)",
            qos: .userInitiated
        )
        providerQueues[scraperID] = queue
        return queue
    }

    private static let timeoutQueue = DispatchQueue(label: "app.eclipse.soupy.nuvio-plugin-timeout", qos: .utility)

    private static let permits = NuvioExecutionPermits(capacity: maximumConcurrentExecutions)

    private static let maximumConcurrentExecutions = 4

    private static let queueDrainGracePeriod: TimeInterval = 5

    private static let maximumResultJSONBytes = 4 * 1024 * 1024

    private static let maximumResultRows = 500
    private static let maximumScannedResultRows = 4_000
    private static let maximumSettingsOptions = 200

    private static func reclaimOrBurnPermit(queue: DispatchQueue, scraper: NuvioPluginScraper) {
        let probe = NuvioQueueDrainProbe()
        queue.async {
            if probe.markDrained() {

                permits.restoreBurnedPermit()
                Logger.shared.log(
                    "Nuvio runtime for provider=\(scraper.name) recovered; its permit was returned",
                    type: "Plugin"
                )
            } else {
                permits.release()
            }
        }
        timeoutQueue.asyncAfter(deadline: .now() + queueDrainGracePeriod) {
            guard probe.markExpired() else { return }
            let remaining = permits.burn()
            Logger.shared.log(
                "Nuvio runtime permit burned by provider=\(scraper.name): its queue did not accept work "
                    + "\(Int(queueDrainGracePeriod))s after the run timed out, so its JavaScript is still executing. "
                    + "\(remaining) of \(maximumConcurrentExecutions) permits remain.",
                type: "Error"
            )
        }
    }
    private static let timeoutSeconds: TimeInterval = 60

    private static let maxFetchBodyDecodeBytes = 12 * 1024 * 1024

    private static let maxFetchBodyChars = maxFetchBodyDecodeBytes

    private static let maxFetchResponseBytes = 12 * 1024 * 1024
    private static let maxHeaderValueCharacters = 8 * 1024
    private static let maxRequestHeaderCount = 64
    private static let maxRequestHeaderTotalBytes = 32 * 1024

    private static let forbiddenRequestHeaderNames: Set<String> = [
        "proxy-authorization", "set-cookie"
    ]

    private static let withheldResponseHeaderNames: Set<String> = [
        "proxy-authenticate", "www-authenticate"
    ]

    private static let maxConcurrentFetchesPerRun = 8
    private static let maxFetchesPerRun = 150

    private static let maxRandomValueBytes = 65_536

    private static let maxDerivedKeyBytes = 1024
    private static let maxDerivationIterations = 1_000_000

    private static let maxHexEncodableInputBytes = maxFetchResponseBytes

    private static let defaultDesktopUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36"

    static func execute(
        code: String,
        tmdbId: String,
        mediaType: String,
        season: Int?,
        episode: Int?,
        scraper: NuvioPluginScraper,
        repository: NuvioPluginRepository,
        scraperSettings: [String: Any],
        servicesProfileID: UUID,
        sharesServices: Bool
    ) async throws -> NuvioStreamBatch {
        let tally = NuvioFetchTally()
        let batch = try await run(
            code: code,
            scraper: scraper,
            scraperSettings: scraperSettings,
            servicesProfileID: servicesProfileID,
            sharesServices: sharesServices,
            invocation: invocationCode(
                tmdbId: tmdbId,
                mediaType: mediaType,
                season: season,
                episode: episode
            ),
            tally: tally,
            decode: { rawJSON in
                try parseStreams(rawJSON: rawJSON, scraper: scraper, repository: repository)
            }
        )
        let counts = tally.snapshot
        return NuvioStreamBatch(
            streams: batch.streams,
            unplayableCount: batch.unplayableCount,
            torrentCount: batch.torrentCount,
            unreadableURLCount: batch.unreadableURLCount,
            discardedRowCount: batch.discardedRowCount,
            requestCount: counts.requests,
            ownSourceRequestCount: counts.ownSourceRequests,
            ownSourceFailureCount: counts.ownSourceFailures,
            malformedURLCount: batch.malformedURLCount,
            ledgerDescription: tally.ledgerDescription,
            interference: tally.interference
        )
    }

    static func executeSettings(
        code: String,
        scraper: NuvioPluginScraper,
        scraperSettings: [String: Any],
        servicesProfileID: UUID,
        sharesServices: Bool
    ) async throws -> [NuvioSettingsField] {
        try await run(
            code: code,
            scraper: scraper,
            scraperSettings: scraperSettings,
            servicesProfileID: servicesProfileID,
            sharesServices: sharesServices,
            invocation: settingsInvocationCode(),
            decode: { rawJSON in
                try parseSettingsFields(rawJSON: rawJSON)
            }
        )
    }

    private static func run<Value>(
        code: String,
        scraper: NuvioPluginScraper,
        scraperSettings: [String: Any],
        servicesProfileID: UUID,
        sharesServices: Bool,
        invocation: String,
        tally: NuvioFetchTally? = nil,
        decode: @escaping (String) throws -> Value
    ) async throws -> Value {
        let queue = providerQueue(for: scraper.id)

        guard await permits.acquire() else {

            if Task.isCancelled { throw CancellationError() }
            Logger.shared.log(
                "Nuvio runtime refused provider=\(scraper.name): every execution permit has been burned by "
                    + "plugins whose JavaScript never returned. Eclipse returns one permit "
                    + "\(Int(NuvioExecutionPermits.burnRecoveryInterval))s after the last burn, "
                    + "so this recovers without a relaunch.",
                type: "Error"
            )
            throw NuvioPluginError.runtimeUnavailable
        }
        let settingsJSON = jsonLiteral(scraperSettings) ?? "{}"
        let configurationMaterial = [
            scraper.repositoryId,
            scraper.version,
            code,
            settingsJSON
        ].joined(separator: "\u{0}")
        let configurationFingerprint = Data(
            SHA256.hash(data: Data(configurationMaterial.utf8))
        ).base64EncodedString()
        let sessions = NuvioProviderFetchSessionRegistry.shared.session(
            profileID: servicesProfileID,
            sharesServices: sharesServices,
            scraperID: scraper.id,
            configurationFingerprint: configurationFingerprint
        )
        return try await withCheckedThrowingContinuation { continuation in

            let box = NuvioPluginRuntimeCompletion(continuation: continuation, queue: queue)
            let requests = NuvioNativeRequestLimiter(
                maximumConcurrent: maxConcurrentFetchesPerRun,
                maximumPerRun: maxFetchesPerRun
            )
            box.onSettled = { settledNormally in

                requests.tearDown()
                if settledNormally {
                    permits.release()
                } else {

                    reclaimOrBurnPermit(queue: queue, scraper: scraper)
                }
            }
            box.timeout = DispatchWorkItem {
                box.failExpired()
            }
            if let timeout = box.timeout {
                timeoutQueue.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
            }

            queue.async {

                guard !box.isFinished else { return }

                box.markExecutionBegan()

                let context = JSContext()
                box.context = context
                let cheerio = NuvioCheerioBridge(tally: tally)

                let redactor = NuvioSecretRedactor(settings: scraperSettings)
                let trap = NuvioRuntimeExceptionTrap()
                context?.exceptionHandler = { _, exception in
                    guard let exception else { return }
                    let message = redactor.redact(exception.toString() ?? "Unknown JavaScript error")
                    trap.record(message)
                    let location = [
                        exception.objectForKeyedSubscript("line")?.toString(),
                        exception.objectForKeyedSubscript("column")?.toString()
                    ]
                    .compactMap { $0 }
                    .filter { $0 != "undefined" }
                    .joined(separator: ":")
                    let stack = exception.objectForKeyedSubscript("stack")?.toString()
                        .map { $0.replacingOccurrences(of: "\n", with: " <- ") }
                        .map { redactor.redact($0) }
                        .map { String($0.prefix(400)) }
                    Logger.shared.log(
                        "Nuvio plugin JS exception provider=\(scraper.name): \(message)"
                            + (location.isEmpty ? "" : " at \(location)")
                            + (stack.map { " stack=\($0)" } ?? ""),
                        type: "Plugin"
                    )
                }

                configure(
                    context,
                    box: box,
                    cheerio: cheerio,
                    scraper: scraper,
                    tally: tally,
                    requests: requests,
                    sessions: sessions,
                    decode: decode,
                    redactor: redactor
                )

                trap.beginCapture()
                context?.evaluateScript(polyfillCode(scraperId: scraper.id, settingsJSON: settingsJSON))
                if let failure = trap.endCapture() {
                    box.fail(NuvioPluginError.runtimeBootstrapFailed(failure))
                    return
                }

                trap.beginCapture()
                context?.evaluateScript(moduleWrapped(code))
                if let failure = trap.endCapture() {
                    box.fail(NuvioPluginError.runtimeFailed("Plugin failed to load: \(failure)"))
                    return
                }

                trap.beginCapture()
                context?.evaluateScript(invocation)
                if let failure = trap.endCapture() {
                    box.recordDeferredFailure(failure)
                }
            }
        }
    }

    private static func configure<Value>(
        _ context: JSContext?,
        box: NuvioPluginRuntimeCompletion<Value>,
        cheerio: NuvioCheerioBridge,
        scraper: NuvioPluginScraper,
        tally: NuvioFetchTally?,
        requests: NuvioNativeRequestLimiter,
        sessions: NuvioProviderFetchSession,
        decode: @escaping (String) throws -> Value,
        redactor: NuvioSecretRedactor
    ) {
        guard let context else { return }

        let captureResult: @convention(block) (String) -> Void = { rawJSON in

            guard rawJSON.utf8.count <= maximumResultJSONBytes else {
                Logger.shared.log(
                    "Nuvio provider result refused by Eclipse provider=\(scraper.name) bytes=\(rawJSON.utf8.count) cap=maximumResultJSONBytes=\(maximumResultJSONBytes); the whole result set is discarded, so an empty result here is an Eclipse limit, not a dead provider",
                    type: "Error"
                )
                box.fail(NuvioPluginError.runtimeLimitExceeded(
                    "Eclipse refused this provider's result set because it was larger than Eclipse's own \(maximumResultJSONBytes)-byte limit."
                ))
                return
            }
            do {
                box.succeed(try decode(rawJSON))
            } catch {
                box.fail(error)
            }
        }
        context.setObject(captureResult, forKeyedSubscript: "__capture_result" as NSString)

        let captureError: @convention(block) (String) -> Void = { message in
            box.fail(NuvioPluginError.runtimeFailed(message))
        }
        context.setObject(captureError, forKeyedSubscript: "__capture_error" as NSString)

        let console = JSValue(newObjectIn: context)
        let log: @convention(block) (String) -> Void = { message in
            Logger.shared.log(
                "Nuvio plugin console provider=\(scraper.name): \(redactor.redact(message))",
                type: "Plugin"
            )
        }
        console?.setObject(log, forKeyedSubscript: "log" as NSString)
        console?.setObject(log, forKeyedSubscript: "info" as NSString)
        console?.setObject(log, forKeyedSubscript: "debug" as NSString)
        console?.setObject(log, forKeyedSubscript: "warn" as NSString)
        console?.setObject(log, forKeyedSubscript: "error" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)

        let nativeFetch: @convention(block) (String, String, JSValue?, String?, ObjCBool, Double, JSValue, JSValue) -> Void = { urlString, method, headersValue, body, followRedirects, timeoutMilliseconds, resolve, reject in

            let requestHeaders = headers(from: headersValue)
            let shouldFollowRedirects = followRedirects.boolValue

            let admission = requests.admit()
            guard case .admitted(let requestID) = admission else {
                if case .refused(let reason) = admission {
                    tally?.recordEclipseRefusal(.concurrencyCap)
                    Logger.shared.log(
                        "Nuvio plugin fetch refused provider=\(scraper.name): \(reason)",
                        type: "Plugin"
                    )

                    box.queue.async {
                        guard !box.isFinished else { return }
                        reject.call(withArguments: [reason])
                    }
                }
                return
            }
            let task = Task {
                let holdsSlot = await requests.acquireSlot(id: requestID)
                defer { requests.release(id: requestID, heldSlot: holdsSlot) }

                guard holdsSlot, !Task.isCancelled else { return }
                do {
                    let response = try await fetch(
                        urlString: urlString,
                        method: method,
                        headers: requestHeaders,
                        body: body,
                        followRedirects: shouldFollowRedirects,
                        timeoutMilliseconds: timeoutMilliseconds,
                        scraperName: scraper.name,
                        tally: tally,
                        sessions: sessions
                    )

                    let status = response["status"] as? Int ?? 0
                    tally?.recordStatus(status)
                    tally?.record(host: URL(string: urlString)?.host, failed: status == 0 || status >= 500)
                    box.queue.async {
                        guard !box.isFinished else { return }
                        resolve.call(withArguments: [response])
                    }
                } catch {
                    if !(error is NuvioEclipseRefusalRejection) {
                        tally?.recordTransportFailure()
                    }
                    tally?.record(host: URL(string: urlString)?.host, failed: true)
                    box.queue.async {
                        guard !box.isFinished else { return }
                        reject.call(withArguments: [error.localizedDescription])
                    }
                }
            }
            requests.register(requestID, task: task)
        }
        context.setObject(nativeFetch, forKeyedSubscript: "__native_fetch" as NSString)

        let scheduleTimeout: @convention(block) (JSValue?, Double) -> Void = { callback, milliseconds in
            guard let callback, !callback.isUndefined, !callback.isNull else { return }
            let clamped = min(max(0, milliseconds), timeoutSeconds * 1000)
            box.queue.asyncAfter(deadline: .now() + clamped / 1000.0) {
                guard !box.isFinished else { return }
                callback.call(withArguments: [])
            }
        }
        context.setObject(scheduleTimeout, forKeyedSubscript: "__schedule_timeout" as NSString)

        let hash: @convention(block) (String, String) -> String = { algorithm, value in
            bridgeValue(orJSError: "") { try digestHex(algorithm: algorithm, value: value) }
        }
        context.setObject(hash, forKeyedSubscript: "__crypto_hash" as NSString)

        let hmac: @convention(block) (String, String, String) -> String = { algorithm, value, key in
            hmacHex(algorithm: algorithm, value: value, key: key)
        }
        context.setObject(hmac, forKeyedSubscript: "__crypto_hmac" as NSString)

        let base64Encode: @convention(block) (String) -> String = { value in
            Data(value.utf8).base64EncodedString()
        }
        context.setObject(base64Encode, forKeyedSubscript: "__base64_encode" as NSString)

        let base64Decode: @convention(block) (String) -> String = { value in
            guard let data = Data(base64Encoded: value) else { return "" }
            return String(data: data, encoding: .utf8) ?? ""
        }
        context.setObject(base64Decode, forKeyedSubscript: "__base64_decode" as NSString)

        let utf8ToHex: @convention(block) (String) -> String = { value in
            bridgeValue(orJSError: "") { try boundedHexFromData(Data(value.utf8)) }
        }
        context.setObject(utf8ToHex, forKeyedSubscript: "__utf8_to_hex" as NSString)

        let hexToUTF8: @convention(block) (String) -> String = { value in
            let normalized = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: " ", with: "")
                .lowercased()
            let evenHex = normalized.count.isMultiple(of: 2) ? normalized : "0\(normalized)"
            var bytes: [UInt8] = []
            var index = evenHex.startIndex
            while index < evenHex.endIndex {
                let next = evenHex.index(index, offsetBy: 2)
                if let byte = UInt8(evenHex[index..<next], radix: 16) {
                    bytes.append(byte)
                }
                index = next
            }
            return String(data: Data(bytes), encoding: .utf8) ?? ""
        }
        context.setObject(hexToUTF8, forKeyedSubscript: "__hex_to_utf8" as NSString)

        let utf8ToHexCrypto: @convention(block) (String) -> String = { value in
            bridgeValue(orJSError: "") { try boundedHexFromData(Data(value.utf8)) }
        }
        context.setObject(utf8ToHexCrypto, forKeyedSubscript: "__crypto_utf8_to_hex" as NSString)

        let hexToUTF8Crypto: @convention(block) (String) -> String = { value in

            String(decoding: dataFromHex(value), as: UTF8.self)
        }
        context.setObject(hexToUTF8Crypto, forKeyedSubscript: "__crypto_hex_to_utf8" as NSString)

        let digestRaw: @convention(block) (String, String) -> String = { name, dataHex in
            digestHexRaw(hashName: name, dataHex: dataHex)
        }
        context.setObject(digestRaw, forKeyedSubscript: "__crypto_digest_hex_raw" as NSString)

        let hmacRaw: @convention(block) (String, String, String) -> String = { name, keyHex, dataHex in
            hmacHexRaw(hashName: name, keyHex: keyHex, dataHex: dataHex)
        }
        context.setObject(hmacRaw, forKeyedSubscript: "__crypto_hmac_hex_raw" as NSString)

        let pbkdf2: @convention(block) (String, String, Int32, Int32, String) -> String = { passHex, saltHex, iterations, keyBits, name in
            bridgeValue(orJSError: "") {
                try pbkdf2Hex(
                    passHex: passHex,
                    saltHex: saltHex,
                    iterations: Int(iterations),
                    keyBits: Int(keyBits),
                    hashName: name
                )
            }
        }
        context.setObject(pbkdf2, forKeyedSubscript: "__crypto_pbkdf2_hex" as NSString)

        let aesEncrypt: @convention(block) (String, String, String, String) -> String = { mode, keyHex, ivHex, dataHex in
            bridgeValue(orJSError: "") {
                try cipherHex(encrypt: true, algorithmMode: mode, keyHex: keyHex, ivHex: ivHex, dataHex: dataHex)
            }
        }
        context.setObject(aesEncrypt, forKeyedSubscript: "__crypto_aes_encrypt_hex" as NSString)

        let aesDecrypt: @convention(block) (String, String, String, String) -> String = { mode, keyHex, ivHex, dataHex in
            bridgeValue(orJSError: "") {
                try cipherHex(encrypt: false, algorithmMode: mode, keyHex: keyHex, ivHex: ivHex, dataHex: dataHex)
            }
        }
        context.setObject(aesDecrypt, forKeyedSubscript: "__crypto_aes_decrypt_hex" as NSString)

        let des3Encrypt: @convention(block) (String, String, String, String) -> String = { mode, keyHex, ivHex, dataHex in
            bridgeValue(orJSError: "") {
                try cipherHex(encrypt: true, algorithmMode: mode, keyHex: keyHex, ivHex: ivHex, dataHex: dataHex)
            }
        }
        context.setObject(des3Encrypt, forKeyedSubscript: "__crypto_des3_encrypt_hex" as NSString)

        let des3Decrypt: @convention(block) (String, String, String, String) -> String = { mode, keyHex, ivHex, dataHex in
            bridgeValue(orJSError: "") {
                try cipherHex(encrypt: false, algorithmMode: mode, keyHex: keyHex, ivHex: ivHex, dataHex: dataHex)
            }
        }
        context.setObject(des3Decrypt, forKeyedSubscript: "__crypto_des3_decrypt_hex" as NSString)

        let randomValues: @convention(block) (Int32) -> String = { byteLength in
            randomHex(byteLength: Int(byteLength))
        }
        context.setObject(randomValues, forKeyedSubscript: "__crypto_get_random_values_hex" as NSString)

        let parseURL: @convention(block) (String, String?) -> [String: Any] = { value, base in
            Self.parseURL(value, base: base)
        }
        context.setObject(parseURL, forKeyedSubscript: "__parse_url" as NSString)

        let cheerioLoad: @convention(block) (String) -> Int32 = { html in
            bridgeValue(orJSError: Int32(0)) { Int32(try cheerio.load(html)) }
        }
        context.setObject(cheerioLoad, forKeyedSubscript: "__cheerio_load" as NSString)

        let cheerioSelect: @convention(block) (Int32, String) -> [Int32] = { handle, selector in
            bridgeValue(orJSError: [Int32]()) {
                try cheerio.select(handle: Int(handle), selector: selector).map(Int32.init)
            }
        }
        context.setObject(cheerioSelect, forKeyedSubscript: "__cheerio_select" as NSString)

        let cheerioText: @convention(block) (Int32) -> String = { handle in
            bridgeValue(orJSError: "") { try cheerio.text(handle: Int(handle)) }
        }
        context.setObject(cheerioText, forKeyedSubscript: "__cheerio_text" as NSString)

        let cheerioHTML: @convention(block) (Int32) -> String = { handle in
            bridgeValue(orJSError: "") { try cheerio.html(handle: Int(handle)) }
        }
        context.setObject(cheerioHTML, forKeyedSubscript: "__cheerio_html" as NSString)

        let cheerioInnerHTML: @convention(block) (Int32) -> String = { handle in
            bridgeValue(orJSError: "") { try cheerio.innerHTML(handle: Int(handle)) }
        }
        context.setObject(cheerioInnerHTML, forKeyedSubscript: "__cheerio_inner_html" as NSString)

        let cheerioAttr: @convention(block) (Int32, String) -> String? = { handle, name in
            bridgeValue(orJSError: String?.none) { try cheerio.attr(handle: Int(handle), name: name) }
        }
        context.setObject(cheerioAttr, forKeyedSubscript: "__cheerio_attr" as NSString)

        let cheerioNext: @convention(block) (Int32) -> Int32 = { handle in
            bridgeValue(orJSError: Int32(0)) { Int32(try cheerio.next(handle: Int(handle)) ?? 0) }
        }
        context.setObject(cheerioNext, forKeyedSubscript: "__cheerio_next" as NSString)

        let cheerioPrevious: @convention(block) (Int32) -> Int32 = { handle in
            bridgeValue(orJSError: Int32(0)) { Int32(try cheerio.previous(handle: Int(handle)) ?? 0) }
        }
        context.setObject(cheerioPrevious, forKeyedSubscript: "__cheerio_prev" as NSString)

        let cheerioChildren: @convention(block) (Int32) -> [Int32] = { handle in
            bridgeValue(orJSError: [Int32]()) {
                try cheerio.children(handle: Int(handle)).map(Int32.init)
            }
        }
        context.setObject(cheerioChildren, forKeyedSubscript: "__cheerio_children" as NSString)

        let cheerioParent: @convention(block) (Int32) -> Int32 = { handle in
            bridgeValue(orJSError: Int32(0)) { Int32(try cheerio.parent(handle: Int(handle)) ?? 0) }
        }
        context.setObject(cheerioParent, forKeyedSubscript: "__cheerio_parent" as NSString)

        let cheerioMatches: @convention(block) (Int32, String) -> Bool = { handle, selector in
            bridgeValue(orJSError: false) { try cheerio.matches(handle: Int(handle), selector: selector) }
        }
        context.setObject(cheerioMatches, forKeyedSubscript: "__cheerio_matches" as NSString)
    }

    private static func bridgeValue<Value>(orJSError fallback: Value, _ work: () throws -> Value) -> Value {
        do {
            return try work()
        } catch {
            if let context = JSContext.current() {
                context.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: context)
            }
            return fallback
        }
    }

    private static func fetch(
        urlString: String,
        method: String,
        headers: [String: String],
        body: String?,
        followRedirects: Bool,
        timeoutMilliseconds: Double,
        scraperName: String,
        tally: NuvioFetchTally?,
        sessions: NuvioProviderFetchSession
    ) async throws -> [String: Any] {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            tally?.recordEclipseRefusal(.invalidRequestURL)
            throw NuvioPluginError.runtimeFailed("Invalid fetch URL.")
        }
        guard !ServiceSandboxState.isBlockedTrackingURL(url.absoluteString) else {
            tally?.recordEclipseRefusal(.trackingSandbox)
            Logger.shared.log(
                "Nuvio plugin blocked tracking fetch provider=\(scraperName)"
                    + " target=\(ServiceSandboxState.redactedURL(url.absoluteString))",
                type: "ServiceSandbox"
            )
            throw NuvioPluginError.runtimeFailed("Plugin network request blocked by sandbox.")
        }

        let validated: SkyStreamValidatedRemoteURL
        do {
            validated = try await SkyStreamRemoteURLPolicy.shared.validateForNetworkDispatch(
                urlString,
                purpose: .nuvioRequest
            )
        } catch {
            if NuvioPluginSupport.isUnreachableHostError(error) {
                Logger.shared.log(
                    "Nuvio plugin host did not resolve provider=\(scraperName)"
                        + " target=\(SkyStreamRemoteURLPolicy.redactedDescription(of: url))"
                        + " reason=\(error.localizedDescription);"
                        + " the provider's own host is unreachable, this is not an Eclipse block",
                    type: "Plugin"
                )
            } else {
                tally?.recordEclipseRefusal(.addressPolicy)
                Logger.shared.log(
                    "Nuvio plugin blocked unsafe fetch provider=\(scraperName)"
                        + " target=\(SkyStreamRemoteURLPolicy.redactedDescription(of: url))"
                        + " reason=\(error.localizedDescription)",
                    type: "ServiceSandbox"
                )
            }
            throw NuvioPluginError.runtimeFailed("Plugin network request blocked by sandbox.")
        }

        var sanitizedHeaders = sanitizedRequestHeaders(headers, scraperName: scraperName, tally: tally)
        if sanitizedHeaders["user-agent"] == nil {
            sanitizedHeaders["user-agent"] = defaultDesktopUserAgent
        }

        let requestMethod = method.isEmpty ? "GET" : method.uppercased()
        guard ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"].contains(requestMethod) else {
            throw NuvioPluginError.runtimeFailed("Invalid fetch method.")
        }
        let requestBody: Data?
        if let body, !body.isEmpty, requestMethod != "GET" {
            let data = Data(body.utf8)
            guard data.count <= 2 * 1024 * 1024 else {
                throw NuvioPluginError.runtimeFailed("Plugin request body is too large.")
            }
            requestBody = data
        } else {
            requestBody = nil
        }

        let responseData: Data
        let httpResponse: HTTPURLResponse
        do {
            Logger.shared.log("Nuvio plugin fetch provider=\(scraperName) target=\(ServiceSandboxState.redactedURL(url.absoluteString))", type: "Plugin")
            let timeoutInterval = min(max(timeoutMilliseconds / 1_000, 0.25), 30)
            var request = URLRequest(url: validated.url, timeoutInterval: timeoutInterval)
            request.httpMethod = requestMethod
            request.httpBody = requestBody
            for (name, value) in sanitizedHeaders {
                request.setValue(value, forHTTPHeaderField: name)
            }
            let result = try await sessions.withSession { session in
                try await session.boundedData(
                    for: request,
                    maximumResponseBytes: maxFetchResponseBytes,
                    allowRedirects: followRedirects
                )
            }
            guard let response = result.1 as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            responseData = result.0
            httpResponse = response
        } catch is CancellationError {
            throw CancellationError()
        } catch is BoundedURLSessionError {
            tally?.recordEclipseRefusal(.responseTooLarge)
            throw NuvioPluginError.runtimeFailed(
                BoundedURLSessionError.responseTooLarge(
                    maximumBytes: maxFetchResponseBytes
                ).localizedDescription
            )
        } catch let error as URLError where error.code == .timedOut {
            tally?.recordTransportFailureCode(error.code.rawValue)
            throw NuvioPluginError.runtimeFailed("TimeoutError")
        } catch let error as URLError {
            tally?.recordTransportFailureCode(error.code.rawValue)
            throw NuvioPluginError.runtimeFailed(
                "Plugin network request failed. (URLError \(error.code.rawValue))"
            )
        } catch {
            throw NuvioPluginError.runtimeFailed("Plugin network request failed.")
        }
        let (text, wasTruncated) = decodeResponseBody(responseData)
        let leadingBytes = Array(responseData.prefix(2))
        if leadingBytes.count == 2, leadingBytes[0] == 0x1f, leadingBytes[1] == 0x8b {
            Logger.shared.log(
                "Nuvio plugin response arrived still gzip-compressed provider=\(scraperName)"
                    + " target=\(ServiceSandboxState.redactedURL(url.absoluteString))"
                    + " bytes=\(responseData.count); Eclipse decoded it as UTF-8, so the plugin is"
                    + " parsing replacement characters and will find nothing",
                type: "Plugin"
            )
        }
        if wasTruncated {
            tally?.recordTruncatedBody()
            Logger.shared.log(
                "Nuvio plugin response truncated by Eclipse provider=\(scraperName)"
                    + " target=\(ServiceSandboxState.redactedURL(url.absoluteString))"
                    + " bytes=\(responseData.count) charCap=\(maxFetchBodyChars);"
                    + " a provider that finds nothing after this was cut off by Eclipse, not by its source",
                type: "Plugin"
            )
        }
        var responseHeaders: [String: String] = [:]
        httpResponse.allHeaderFields.forEach { key, value in
            let headerName = String(describing: key)
            guard !withheldResponseHeaderNames.contains(headerName.lowercased()) else { return }
            let headerValue = String(describing: value)
            responseHeaders[headerName] = String(headerValue.prefix(maxHeaderValueCharacters))
        }

        return [
            "ok": (200...299).contains(httpResponse.statusCode),
            "status": httpResponse.statusCode,
            "statusText": HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
            "url": httpResponse.url?.absoluteString ?? url.absoluteString,
            "headers": responseHeaders,
            "body": text
        ]
    }

    private static func sanitizedRequestHeaders(
        _ headers: [String: String],
        scraperName: String,
        tally: NuvioFetchTally? = nil
    ) -> [String: String] {
        var dropped = 0
        var candidates: [String: String] = [:]
        for (rawName, rawValue) in headers {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else { continue }
            guard !forbiddenRequestHeaderNames.contains(name) else {
                dropped += 1
                Logger.shared.log(
                    "Nuvio plugin dropped credential request header provider=\(scraperName) name=\(name)",
                    type: "Plugin"
                )
                continue
            }
            if value.count > maxHeaderValueCharacters {
                Logger.shared.log(
                    "Nuvio plugin truncated a request header provider=\(scraperName) name=\(name) chars=\(value.count) charCap=\(maxHeaderValueCharacters); the value is sent altered, so a 401 or 403 after this is Eclipse's header, not the source's",
                    type: "Plugin"
                )
            }
            candidates[name] = String(value.prefix(maxHeaderValueCharacters))
        }

        var accepted: [String: String] = [:]
        var totalBytes = 0
        let managedNames: Set<String> = [
            "accept-encoding", "connection", "content-length", "host", "keep-alive",
            "proxy-authenticate", "proxy-authorization", "proxy-connection", "te", "trailer",
            "transfer-encoding", "upgrade"
        ]
        let validNameCharacters = CharacterSet(
            charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        )

        let ordered = candidates.sorted(by: { $0.key < $1.key })
        let nameIsWellFormed: (String) -> Bool = { name in
            name.utf8.count <= 128 && name.unicodeScalars.allSatisfy {
                $0.value < 128 && validNameCharacters.contains($0)
            }
        }
        let valueIsWellFormed: (String) -> Bool = { value in
            value.unicodeScalars.allSatisfy { $0.value == 9 || $0.value >= 32 && $0.value != 127 }
        }
        let sacrificeableKeys: (Int) -> [String] = { offset in
            ordered[offset...]
                .filter { nameIsWellFormed($0.key) && valueIsWellFormed($0.value) && !managedNames.contains($0.key) }
                .map { $0.key }
        }

        var hostManagedNames: [String] = []
        for (offset, entry) in ordered.enumerated() {
            let name = entry.key
            let value = entry.value
            guard accepted.count < maxRequestHeaderCount else {
                let sacrificed = sacrificeableKeys(offset)
                dropped += sacrificed.count
                Logger.shared.log(
                    "Nuvio plugin dropped request headers over the count cap provider=\(scraperName) droppedKeys=[\(sacrificed.joined(separator: ","))] cap=maxRequestHeaderCount=\(maxRequestHeaderCount); a 401 or 403 after this is Eclipse's header set, not the source's",
                    type: "Plugin"
                )
                break
            }
            let nameIsValid = name.unicodeScalars.allSatisfy {
                $0.value < 128 && validNameCharacters.contains($0)
            }
            let valueIsValid = valueIsWellFormed(value)
            guard name.utf8.count <= 128 else {
                dropped += 1
                Logger.shared.log(
                    "Nuvio plugin dropped an over-long request header name provider=\(scraperName) bytes=\(name.utf8.count) cap=128; this is an Eclipse cap",
                    type: "Plugin"
                )
                continue
            }
            guard nameIsValid, valueIsValid else {
                Logger.shared.log(
                    "Nuvio plugin dropped unsafe request header provider=\(scraperName) name=\(name); the header is malformed, so this is the provider's data, not an Eclipse cap",
                    type: "Plugin"
                )
                continue
            }
            guard !managedNames.contains(name) else {
                hostManagedNames.append(name)
                continue
            }
            let size = name.utf8.count + value.utf8.count + 4
            guard totalBytes + size <= maxRequestHeaderTotalBytes else {
                let sacrificed = sacrificeableKeys(offset)
                dropped += sacrificed.count
                Logger.shared.log(
                    "Nuvio plugin dropped request headers over the byte cap provider=\(scraperName) droppedKeys=[\(sacrificed.joined(separator: ","))] usedBytes=\(totalBytes) cap=maxRequestHeaderTotalBytes=\(maxRequestHeaderTotalBytes); a 401 or 403 after this is Eclipse's header set, not the source's",
                    type: "Plugin"
                )
                break
            }
            totalBytes += size
            accepted[name] = value
        }
        if !hostManagedNames.isEmpty {
            EclipseLedgerOnce.emit(
                scope: "nuvio-host-managed",
                signature: "\(scraperName)|\(hostManagedNames.joined(separator: ","))"
            ) {
                Logger.shared.log(
                    "Nuvio plugin removed host-managed request headers provider=\(scraperName) names=[\(hostManagedNames.joined(separator: ","))]; these are set by the transport and are not counted as an Eclipse refusal",
                    type: "Plugin"
                )
            }
        }
        tally?.recordDroppedRequestHeaders(dropped)
        return accepted
    }

    private static func decodeResponseBody(_ data: Data) -> (text: String, truncated: Bool) {
        guard !data.isEmpty else { return ("", false) }
        let exceededByteCap = data.count > maxFetchBodyDecodeBytes
        let limited = exceededByteCap ? Data(data.prefix(maxFetchBodyDecodeBytes)) : data
        var text = String(decoding: limited, as: UTF8.self)
        var exceededCharCap = false
        if text.count > maxFetchBodyChars {
            exceededCharCap = true
            text = String(text.prefix(maxFetchBodyChars)) + "\n...[truncated]"
        }
        return (text, exceededByteCap || exceededCharCap)
    }

    private static func parseStreams(
        rawJSON: String,
        scraper: NuvioPluginScraper,
        repository: NuvioPluginRepository
    ) throws -> NuvioStreamBatch {
        guard let data = rawJSON.data(using: .utf8) else {
            throw NuvioPluginError.invalidResponse
        }
        let decoded = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])

        let array: [[String: Any]]
        if let direct = decoded as? [Any] {
            array = direct.compactMap { $0 as? [String: Any] }
        } else if let object = decoded as? [String: Any],
                  let streams = object["streams"] as? [Any] {
            array = streams.compactMap { $0 as? [String: Any] }
        } else {
            throw NuvioPluginError.invalidResponse
        }

        var torrentCount = 0
        var unreadableURLCount = 0
        var discardedRowCount = 0
        var malformedURLCount = 0

        var streams: [NuvioPluginStream] = []
        streams.reserveCapacity(min(array.count, maximumResultRows))
        let scannedRows = array.prefix(maximumScannedResultRows)
        let unscannedRowCount = array.count - scannedRows.count
        if unscannedRowCount > 0 {
            Logger.shared.log(
                "Nuvio provider=\(scraper.name) returned \(array.count) result rows;"
                    + " Eclipse scanned the first \(maximumScannedResultRows) and skipped"
                    + " \(unscannedRowCount) without reading them",
                type: "Plugin"
            )
        }
        for (index, item) in scannedRows.enumerated() {
            let deliveredURL = streamURL(from: item["url"])
            guard let deliveredURL,
                  !deliveredURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                discardedRowCount += 1
                continue
            }
            guard !deliveredURL.lowercased().hasPrefix("magnet:") else {
                torrentCount += 1
                continue
            }
            let urlString = NuvioPluginSupport.repairedDeliveryURL(deliveredURL) ?? deliveredURL
            guard NuvioPluginSupport.isDirectHTTPURL(urlString) else {
                unreadableURLCount += 1
                continue
            }
            if urlString != deliveredURL {
                Logger.shared.log(
                    "Nuvio provider=\(scraper.name) delivered a stream URL with unencoded spaces"
                        + " row=\(index); Eclipse percent-encoded them so the row stays playable,"
                        + " and a later failure on this row is still the provider's data",
                    type: "Plugin"
                )
            }
            if let defect = NuvioPluginSupport.urlDeliveryDefect(urlString) {
                malformedURLCount += 1
                Logger.shared.log(
                    "Nuvio provider=\(scraper.name) delivered a stream URL that is not a legal URI"
                        + " defect=\(defect) row=\(index)"
                        + " evidence=\(NuvioPluginSupport.urlDefectEvidence(urlString));"
                        + " Eclipse passes it through unchanged, so a later playback failure on this row"
                        + " is the provider's data, not Eclipse's URL handling",
                    type: "Plugin"
                )
            }

            let title = cleanString(item["title"]) ?? cleanString(item["name"]) ?? "Stream"
            let headers = cleanHeaders(item["headers"])
            let subtitles = parseSubtitles(from: item)
            streams.append(NuvioPluginStream(
                id: NuvioPluginSupport.streamID(scraperId: scraper.id, sourceId: repository.id, url: urlString, title: title, index: index),
                scraperId: scraper.id,
                scraperName: scraper.name,
                sourceId: repository.id,
                sourceName: repository.displayName,
                title: title,
                name: cleanString(item["name"]),
                url: urlString,
                quality: cleanString(item["quality"]),
                size: cleanString(item["size"]),
                language: cleanString(item["language"]),
                provider: cleanString(item["provider"]),
                type: cleanString(item["type"]),
                headers: headers,
                subtitles: subtitles
            ))
            if streams.count == maximumResultRows {
                let untried = scannedRows.count - index - 1
                if untried > 0 {
                    Logger.shared.log(
                        "Nuvio provider=\(scraper.name) result rows stopped at \(maximumResultRows) cap=maximumResultRows untried=\(untried); Eclipse never examined those rows, so it cannot say whether they were playable",
                        type: "Plugin"
                    )
                }
                break
            }
        }
        return NuvioStreamBatch(
            streams: streams,
            unplayableCount: torrentCount + unreadableURLCount,
            torrentCount: torrentCount,
            unreadableURLCount: unreadableURLCount,
            discardedRowCount: discardedRowCount,
            malformedURLCount: malformedURLCount
        )
    }

    private static func streamURL(from value: Any?) -> String? {
        if let value = value as? String { return cleanString(value) }
        if let value = value as? [String: Any] { return cleanString(value["url"]) }
        return nil
    }

    private static func parseSettingsFields(rawJSON: String) throws -> [NuvioSettingsField] {
        guard let data = rawJSON.data(using: .utf8) else {
            throw NuvioPluginError.invalidResponse
        }
        let decoded = try JSONSerialization.jsonObject(with: data)

        let array: [[String: Any]]
        if let direct = decoded as? [[String: Any]] {
            array = direct
        } else if let object = decoded as? [String: Any],
                  let fields = object["settings"] as? [[String: Any]] {
            array = fields
        } else {
            return []
        }

        return array.prefix(maximumResultRows).compactMap { item in
            guard let rawKind = cleanString(item["type"]),
                  let kind = NuvioSettingsFieldKind(rawValue: rawKind.lowercased()) else {
                return nil
            }
            let key = cleanString(item["key"]) ?? ""
            guard kind == .header || !key.isEmpty else { return nil }

            let options = (item["options"] as? [Any] ?? []).prefix(maximumSettingsOptions).compactMap { option -> NuvioSettingsOption? in
                if let text = cleanString(option) {
                    return NuvioSettingsOption(label: text, value: text)
                }
                guard let object = option as? [String: Any],
                      let value = cleanString(object["value"]) else {
                    return nil
                }
                return NuvioSettingsOption(label: cleanString(object["label"]) ?? value, value: value)
            }

            return NuvioSettingsField(
                kind: kind,
                key: key,
                label: cleanString(item["label"]) ?? cleanString(item["title"]) ?? key,
                description: cleanString(item["description"]),
                options: options,
                defaultValue: settingsValue(from: item["defaultValue"] ?? item["default"])
            )
        }
    }

    private static func settingsValue(from value: Any?) -> NuvioSettingsValue? {

        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let value = number.doubleValue
            return value.isFinite ? .number(value) : nil
        }
        if let text = value as? String {
            return .string(text)
        }
        return nil
    }

    private static func parseSubtitles(from item: [String: Any]) -> [NuvioPluginSubtitle]? {
        let topLevelHeaders = cleanHeaders(item["subtitleHeaders"])
            ?? cleanHeaders(item["subtitlesHeaders"])
            ?? cleanHeaders(item["subtitle_headers"])
        var subtitles = NuvioSubtitleTrackAccumulator()

        if let subtitle = cleanString(item["subtitle"] ?? item["subtitleURL"] ?? item["subtitleUrl"]),
           NuvioPluginSupport.isDirectHTTPURL(subtitle) {
            subtitles.append(NuvioPluginSubtitle(
                url: subtitle,
                language: cleanString(item["subtitleLanguage"] ?? item["subtitleLang"] ?? item["lang"]) ?? "Unknown",
                name: cleanString(item["subtitleName"] ?? item["subtitleTitle"]),
                headers: topLevelHeaders
            ))
        }

        for key in ["subtitles", "subtitleTracks", "allSubtitles"] {
            guard let value = item[key] else { continue }
            guard !subtitles.isFull else {
                subtitles.noteRefusedURLs(refusedSubtitleURLs(value))
                continue
            }
            appendSubtitleValue(
                value,
                inheritedHeaders: topLevelHeaders,
                to: &subtitles
            )
        }
        if subtitles.refusedWhenFull > 0 {
            Logger.shared.log(
                "Nuvio subtitle tracks dropped by Eclipse at cap=maximumTracksPerStream=\(NuvioSubtitleBoundary.maximumTracksPerStream) kept=\(subtitles.tracks.count) refused=\(subtitles.refusedWhenFull); a stream offering more tracks than this loses the remainder to Eclipse, not to the provider",
                type: "Plugin"
            )
        }
        return subtitles.tracks.isEmpty ? nil : subtitles.tracks
    }

    private static func refusedSubtitleURLs(_ value: Any) -> [String] {
        func url(_ dictionary: [String: Any]) -> String? {
            guard let subtitle = parseSubtitleObject(dictionary, inheritedHeaders: nil) else {
                return nil
            }
            let normalized = subtitle.url.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }
        if let dictionary = value as? [String: Any] { return [url(dictionary)].compactMap { $0 } }
        if let dictionaries = value as? [[String: Any]] { return dictionaries.compactMap(url) }
        if let mixed = value as? [Any], !(mixed is [String]) {
            return mixed.flatMap { refusedSubtitleURLs($0) }
        }
        if let strings = value as? [String] {
            return strings.compactMap {
                guard let cleaned = cleanString($0),
                      NuvioPluginSupport.isDirectHTTPURL(cleaned) else { return nil }
                return cleaned
            }
        }
        if let text = value as? String,
           let cleaned = cleanString(text),
           NuvioPluginSupport.isDirectHTTPURL(cleaned) {
            return [cleaned]
        }
        return []
    }

    private static func appendSubtitleValue(
        _ value: Any,
        inheritedHeaders: [String: String]?,
        to subtitles: inout NuvioSubtitleTrackAccumulator
    ) {
        guard !subtitles.isFull else {
            subtitles.noteRefusedURLs(refusedSubtitleURLs(value))
            return
        }
        if let dictionary = value as? [String: Any],
           let subtitle = parseSubtitleObject(dictionary, inheritedHeaders: inheritedHeaders) {
            subtitles.append(subtitle)
            return
        }

        if let dictionaries = value as? [[String: Any]] {
            for dictionary in dictionaries {
                guard !subtitles.isFull else {
                    subtitles.noteRefusedURLs(refusedSubtitleURLs(dictionary))
                    continue
                }
                if let subtitle = parseSubtitleObject(
                    dictionary,
                    inheritedHeaders: inheritedHeaders
                ) {
                    subtitles.append(subtitle)
                }
            }
            return
        }

        if let strings = value as? [String] {
            appendSubtitleStrings(
                strings,
                inheritedHeaders: inheritedHeaders,
                to: &subtitles
            )
            return
        }

        if let mixed = value as? [Any] {
            for element in mixed {
                guard !subtitles.isFull else {
                    subtitles.noteRefusedURLs(refusedSubtitleURLs(element))
                    continue
                }
                appendSubtitleValue(element, inheritedHeaders: inheritedHeaders, to: &subtitles)
            }
            return
        }

        if let urlString = cleanString(value),
           NuvioPluginSupport.isDirectHTTPURL(urlString) {
            subtitles.append(
                NuvioPluginSubtitle(
                    url: urlString,
                    language: "Unknown",
                    name: nil,
                    headers: inheritedHeaders
                )
            )
        }
    }

    private static func parseSubtitleObject(_ object: [String: Any], inheritedHeaders: [String: String]?) -> NuvioPluginSubtitle? {
        guard let url = cleanString(object["url"] ?? object["href"] ?? object["link"] ?? object["file"] ?? object["src"]),
              NuvioPluginSupport.isDirectHTTPURL(url) else {
            return nil
        }

        let language = cleanString(object["language"] ?? object["lang"] ?? object["locale"]) ?? "Unknown"
        let name = cleanString(object["name"] ?? object["title"] ?? object["label"])
        let headers = cleanHeaders(object["headers"] ?? object["requestHeaders"] ?? object["subtitleHeaders"]) ?? inheritedHeaders

        return NuvioPluginSubtitle(url: url, language: language, name: name, headers: headers)
    }

    private static func appendSubtitleStrings(
        _ values: [String],
        inheritedHeaders: [String: String]?,
        to subtitles: inout NuvioSubtitleTrackAccumulator
    ) {
        var pendingLabel: String?

        for rawValue in values {
            guard !subtitles.isFull else {
                if let value = cleanString(rawValue),
                   NuvioPluginSupport.isDirectHTTPURL(value) {
                    subtitles.noteRefusedURLs([value])
                }
                continue
            }
            guard let value = cleanString(rawValue) else { continue }
            if NuvioPluginSupport.isDirectHTTPURL(value) {
                subtitles.append(NuvioPluginSubtitle(
                    url: value,
                    language: pendingLabel ?? "Unknown",
                    name: pendingLabel,
                    headers: inheritedHeaders
                ))
                pendingLabel = nil
            } else {
                pendingLabel = value
            }
        }
    }

    private static func cleanHeaders(_ value: Any?) -> [String: String]? {
        guard let dictionary = value as? [String: Any] else { return nil }
        let pairs = dictionary.compactMap { key, value -> (String, String)? in
            let headerName = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !headerName.isEmpty,
                  !headerName.caseInsensitiveCompare("Range").isSame,
                  let headerValue = cleanString(value),
                  !headerValue.isEmpty else {
                return nil
            }
            return (headerName, String(headerValue.prefix(maxHeaderValueCharacters)))
        }

        return pairs.isEmpty ? nil : Dictionary(pairs, uniquingKeysWith: { existing, _ in existing })
    }

    private static func cleanString(_ value: Any?) -> String? {
        let raw: String?
        if let value = value as? String {
            raw = value
        } else if let value = value as? NSNumber {
            raw = value.stringValue
        } else {
            raw = nil
        }
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed != "[object Object]" else {
            return nil
        }
        return trimmed
    }

    private static func headers(from value: JSValue?) -> [String: String] {
        guard let raw = value,
              !raw.isNull,
              !raw.isUndefined else {
            return [:]
        }

        if let dictionary = raw.toDictionary() {
            let direct = cleanHeaderDictionary(dictionary)
            if !direct.isEmpty { return direct }

            if let nested = dictionary["_headers"] as? [AnyHashable: Any] {
                let nestedHeaders = cleanHeaderDictionary(nested)
                if !nestedHeaders.isEmpty { return nestedHeaders }
            } else if let nested = dictionary["_headers"] as? [String: Any] {
                let nestedHeaders = cleanHeaderDictionary(Dictionary(uniqueKeysWithValues: nested.map { (AnyHashable($0.key), $0.value) }))
                if !nestedHeaders.isEmpty { return nestedHeaders }
            }
        }

        let nested = raw.forProperty("_headers")
        if let nested,
           !nested.isNull,
           !nested.isUndefined,
           let dictionary = nested.toDictionary() {
            let nestedHeaders = cleanHeaderDictionary(dictionary)
            if !nestedHeaders.isEmpty { return nestedHeaders }
        }

        if let entries = raw.invokeMethod("entries", withArguments: [])?.toArray() {
            let entryHeaders = cleanHeaderEntries(entries)
            if !entryHeaders.isEmpty { return entryHeaders }
        }

        return [:]
    }

    private static func cleanHeaderDictionary(_ dictionary: [AnyHashable: Any]) -> [String: String] {
        let pairs = dictionary.compactMap { key, value -> (String, String)? in
            let headerName = String(describing: key).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !headerName.isEmpty,
                  !headerName.caseInsensitiveCompare("Range").isSame,
                  let headerValue = cleanString(value),
                  !headerValue.isEmpty else {
                return nil
            }
            return (headerName, String(headerValue.prefix(maxHeaderValueCharacters)))
        }
        var headers: [String: String] = [:]
        for (key, value) in pairs {
            headers[key] = value
        }
        return headers
    }

    private static func cleanHeaderEntries(_ entries: [Any]) -> [String: String] {
        let pairs = entries.compactMap { entry -> (String, String)? in
            guard let pair = entry as? [Any],
                  pair.count >= 2,
                  let key = cleanString(pair[0]),
                  let value = cleanString(pair[1]) else {
                return nil
            }
            let headerName = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let headerValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !headerName.isEmpty,
                  !headerName.caseInsensitiveCompare("Range").isSame,
                  !headerValue.isEmpty else {
                return nil
            }
            return (headerName, String(headerValue.prefix(maxHeaderValueCharacters)))
        }
        var headers: [String: String] = [:]
        for (key, value) in pairs {
            headers[key] = value
        }
        return headers
    }

    private static func moduleWrapped(_ code: String) -> String {
        """
        (function() {
            var module = { exports: {} };
            var exports = module.exports;
            globalThis.module = module;
            globalThis.exports = exports;
            \(code)
            globalThis.__nuvio_module = module;
        })();
        """
    }

    private static func invocationCode(tmdbId: String, mediaType: String, season: Int?, episode: Int?) -> String {
        let tmdbLiteral = jsonLiteral(tmdbId) ?? "\"\(tmdbId)\""
        let mediaTypeLiteral = jsonLiteral(mediaType) ?? "\"\(mediaType)\""

        let seasonLiteral = season.map(String.init) ?? "undefined"
        let episodeLiteral = episode.map(String.init) ?? "undefined"
        return """
        (function() {
            var getStreams = (globalThis.__nuvio_module && globalThis.__nuvio_module.exports && globalThis.__nuvio_module.exports.getStreams) || globalThis.getStreams;
            if (typeof getStreams !== "function") {
                __capture_error("getStreams not found");
                return;
            }
            Promise.resolve(getStreams(\(tmdbLiteral), \(mediaTypeLiteral), \(seasonLiteral), \(episodeLiteral)))
                .then(function(result) {
                    __capture_result(JSON.stringify(result || []));
                })
                .catch(function(error) {
                    __capture_error(String((error && (error.stack || error.message)) || error || "Plugin failed"));
                });
        })();
        """
    }

    private static func settingsInvocationCode() -> String {
        """
        (function() {
            var onSettings = (globalThis.__nuvio_module && globalThis.__nuvio_module.exports && globalThis.__nuvio_module.exports.onSettings) || globalThis.onSettings;
            if (typeof onSettings !== "function") {
                __capture_result("[]");
                return;
            }
            Promise.resolve(onSettings())
                .then(function(result) {
                    __capture_result(JSON.stringify(result || []));
                })
                .catch(function(error) {
                    __capture_error(String((error && (error.stack || error.message)) || error || "Plugin settings failed"));
                });
        })();
        """
    }

    private static func polyfillCode(scraperId: String, settingsJSON: String) -> String {
        let scraperLiteral = jsonLiteral(scraperId) ?? "\"\(scraperId)\""
        return """
        globalThis.global = globalThis;
        globalThis.window = globalThis;
        globalThis.self = globalThis;
        globalThis.SCRAPER_ID = \(scraperLiteral);
        globalThis.SCRAPER_SETTINGS = \(settingsJSON);

        // atob/btoa must operate on binary ("Latin1") strings - one character per byte (0-255) -
        // NOT UTF-8. Decoding the base64 bytes as UTF-8 (the previous behaviour) returned "" for any
        // payload that wasn't valid UTF-8, breaking every scraper that base64-decodes ciphertext,
        // obfuscated config, or otherwise feeds the result through `charCodeAt`. Pure-JS,
        // binary-correct implementations matching the reference runtime and browsers:
        globalThis.atob = function(value) {
            var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=";
            var str = String(value).replace(/=+$/, "");
            if (str.length % 4 === 1) throw new Error("InvalidCharacterError");
            var output = "";
            var bc = 0, bs, buffer, idx = 0;
            while ((buffer = str.charAt(idx++))) {
                buffer = chars.indexOf(buffer);
                if (buffer === -1) continue;
                bs = bc % 4 ? bs * 64 + buffer : buffer;
                if (bc++ % 4) output += String.fromCharCode(255 & (bs >> ((-2 * bc) & 6)));
            }
            return output;
        };
        globalThis.btoa = function(value) {
            var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=";
            var str = String(value);
            var output = "";
            for (var block, charCode, idx = 0, map = chars;
                 str.charAt(idx | 0) || (map = "=", idx % 1);
                 output += map.charAt(63 & (block >> (8 - (idx % 1) * 8)))) {
                charCode = str.charCodeAt(idx += 3 / 4);
                if (charCode > 0xFF) throw new Error("InvalidCharacterError");
                block = (block << 8) | charCode;
            }
            return output;
        };

        if (!Array.prototype.flat) {
            Array.prototype.flat = function(depth) {
                depth = depth === undefined ? 1 : Math.floor(depth);
                if (depth < 1) return Array.prototype.slice.call(this);
                function flatten(items, level) {
                    return items.reduce(function(output, item) {
                        return output.concat(Array.isArray(item) && level > 0 ? flatten(item, level - 1) : item);
                    }, []);
                }
                return flatten(this, depth);
            };
        }
        if (!Array.prototype.flatMap) {
            Array.prototype.flatMap = function(fn, thisArg) { return this.map(fn, thisArg).flat(1); };
        }
        if (!Object.entries) {
            Object.entries = function(obj) { var out = []; for (var k in obj) if (Object.prototype.hasOwnProperty.call(obj, k)) out.push([k, obj[k]]); return out; };
        }
        if (!Object.fromEntries) {
            Object.fromEntries = function(entries) { var out = {}; entries.forEach(function(pair) { out[pair[0]] = pair[1]; }); return out; };
        }
        if (!String.prototype.replaceAll) {
            String.prototype.replaceAll = function(search, replacement) { return this.split(search).join(replacement); };
        }

        function HeadersShim(headers) {
            this._headers = {};
            var self = this;
            function add(name, value) {
                if (name == null || value == null) return;
                self._headers[String(name)] = String(value);
            }
            if (headers instanceof HeadersShim) {
                headers.forEach(function(value, name) { add(name, value); });
            } else if (Array.isArray(headers)) {
                headers.forEach(function(pair) {
                    if (pair && pair.length >= 2) add(pair[0], pair[1]);
                });
            } else if (headers && typeof headers.entries === "function" && !headers._pairs) {
                var entries = headers.entries();
                if (Array.isArray(entries)) {
                    entries.forEach(function(pair) {
                        if (pair && pair.length >= 2) add(pair[0], pair[1]);
                    });
                }
            } else if (headers && typeof headers === "object") {
                Object.keys(headers).forEach(function(name) { add(name, headers[name]); });
            }
        }
        HeadersShim.prototype.get = function(name) {
            var needle = String(name).toLowerCase();
            for (var key in this._headers) {
                if (String(key).toLowerCase() === needle) return this._headers[key];
            }
            return null;
        };
        HeadersShim.prototype.set = function(name, value) { this._headers[String(name)] = String(value); };
        HeadersShim.prototype.append = function(name, value) { this.set(name, value); };
        HeadersShim.prototype.has = function(name) { return this.get(name) !== null; };
        HeadersShim.prototype.delete = function(name) {
            var needle = String(name).toLowerCase();
            for (var key in this._headers) {
                if (String(key).toLowerCase() === needle) delete this._headers[key];
            }
        };
        HeadersShim.prototype.entries = function() {
            var self = this;
            return Object.keys(this._headers).map(function(key) { return [key, self._headers[key]]; });
        };
        HeadersShim.prototype.keys = function() { return Object.keys(this._headers); };
        HeadersShim.prototype.values = function() {
            var self = this;
            return Object.keys(this._headers).map(function(key) { return self._headers[key]; });
        };
        HeadersShim.prototype.forEach = function(callback) {
            var self = this;
            Object.keys(this._headers).forEach(function(key) { callback(self._headers[key], key, self); });
        };
        if (typeof Symbol !== "undefined" && Symbol.iterator) {
            HeadersShim.prototype[Symbol.iterator] = function() { return this.entries()[Symbol.iterator](); };
        }
        globalThis.Headers = HeadersShim;

        function headersToObject(headers) {
            var out = {};
            var shim = new HeadersShim(headers || {});
            shim.forEach(function(value, name) { out[name] = value; });
            return out;
        }

        function hasHeader(headers, name) {
            var needle = String(name).toLowerCase();
            for (var key in headers) {
                if (String(key).toLowerCase() === needle) return true;
            }
            return false;
        }

        // Serialize the structured body types before handing a plain string to the native
        // bridge, and only set a Content-Type the caller didn't already choose.
        function encodeRequestBody(body, headers) {
            if (body == null) return null;
            if (typeof globalThis.FormData === "function" && body instanceof globalThis.FormData) {
                var boundary = body.__multipartBoundary();
                if (!hasHeader(headers, "Content-Type")) {
                    headers["Content-Type"] = "multipart/form-data; boundary=" + boundary;
                }
                return body.__multipartBody(boundary);
            }
            if (typeof globalThis.URLSearchParams === "function" && body instanceof globalThis.URLSearchParams) {
                if (!hasHeader(headers, "Content-Type")) {
                    headers["Content-Type"] = "application/x-www-form-urlencoded;charset=UTF-8";
                }
                return body.toString();
            }
            if (typeof globalThis.Buffer === "function" && globalThis.Buffer.isBuffer && globalThis.Buffer.isBuffer(body)) {
                return body.toString("utf8");
            }
            return String(body);
        }

        globalThis.fetch = function(url, options) {
            options = options || {};
            var method = options.method || "GET";
            var headers = headersToObject(options.headers || {});
            var body = encodeRequestBody(options.body, headers);
            var redirect = options.redirect === "manual" ? false : true;
            var signal = options.signal;
            if (signal && signal.aborted) {
                return Promise.reject(signal.reason || new Error("AbortError"));
            }
            var timeoutMilliseconds = 30000;
            if (signal && Number.isFinite(Number(signal._eclipseTimeoutMilliseconds))) {
                timeoutMilliseconds = Math.min(Math.max(Number(signal._eclipseTimeoutMilliseconds), 250), 30000);
            }
            return new Promise(function(resolve, reject) {
                __native_fetch(String(url), String(method), headers, body, redirect, timeoutMilliseconds, function(raw) {
                    var response = {
                        ok: !!raw.ok,
                        status: raw.status || 0,
                        statusText: raw.statusText || "",
                        url: raw.url || String(url),
                        headers: new HeadersShim(raw.headers || {}),
                        text: function() { return Promise.resolve(raw.body || ""); },
                        json: function() {
                            try { return Promise.resolve(JSON.parse(raw.body || "null")); }
                            catch (error) { return Promise.reject(error); }
                        }
                    };
                    resolve(response);
                }, reject);
            });
        };

        globalThis.AbortSignal = function() {
            this.aborted = false;
            this.reason = undefined;
            this._listeners = [];
        };
        globalThis.AbortSignal.prototype.addEventListener = function(type, listener) {
            if (type === "abort" && typeof listener === "function") this._listeners.push(listener);
        };
        globalThis.AbortSignal.prototype.removeEventListener = function(type, listener) {
            if (type !== "abort") return;
            this._listeners = this._listeners.filter(function(value) { return value !== listener; });
        };
        globalThis.AbortSignal.prototype.dispatchEvent = function(event) {
            if (!event || event.type !== "abort") return true;
            this._listeners.forEach(function(listener) {
                try { listener.call(this, event); } catch (_) {}
            }, this);
            return true;
        };
        globalThis.AbortController = function() { this.signal = new globalThis.AbortSignal(); };
        globalThis.AbortController.prototype.abort = function(reason) {
            if (this.signal.aborted) return;
            this.signal.aborted = true;
            this.signal.reason = reason;
            this.signal.dispatchEvent({ type: "abort" });
        };

        (function() {
            var __nuvioTimers = {};
            var __nuvioTimerSeq = 1;
            globalThis.setTimeout = function(handler, timeout) {
                if (typeof handler !== "function") return 0;
                var id = __nuvioTimerSeq++;
                __nuvioTimers[id] = true;
                var extraArgs = Array.prototype.slice.call(arguments, 2);
                __schedule_timeout(function() {
                    if (!__nuvioTimers[id]) return;
                    delete __nuvioTimers[id];
                    try { handler.apply(undefined, extraArgs); }
                    catch (e) { if (typeof console !== "undefined" && console.error) console.error("setTimeout callback error:", e); }
                }, Number(timeout) || 0);
                return id;
            };
            globalThis.clearTimeout = function(id) { if (id != null) delete __nuvioTimers[id]; };
            // No real interval timer (avoids runaway loops keeping the JS context alive);
            // scrapers only rely on setTimeout for fetch timeouts in practice.
            globalThis.setInterval = function() { return 0; };
            globalThis.clearInterval = function(id) { if (id != null) delete __nuvioTimers[id]; };
            globalThis.setImmediate = function(handler) {
                return globalThis.setTimeout.apply(null, [handler, 0].concat(Array.prototype.slice.call(arguments, 1)));
            };
            globalThis.clearImmediate = function(id) { globalThis.clearTimeout(id); };
            if (typeof globalThis.queueMicrotask !== "function") {
                globalThis.queueMicrotask = function(cb) { if (typeof cb === "function") Promise.resolve().then(cb); };
            }
        })();

        globalThis.URL = function(value, base) {
            var parsed = __parse_url(String(value), base == null ? null : String(base));
            this.href = parsed.href || String(value);
            this.protocol = parsed.protocol || "";
            this.host = parsed.host || "";
            this.hostname = parsed.hostname || "";
            this.port = parsed.port || "";
            this.pathname = parsed.pathname || "";
            this.search = parsed.search || "";
            this.hash = parsed.hash || "";
            this.origin = parsed.origin || "";
            this.searchParams = new globalThis.URLSearchParams(this.search || "");
            Object.defineProperty(this.searchParams, "_url", { value: this, enumerable: false, writable: true, configurable: true });
        };
        globalThis.URL.prototype.__applySearchParams = function(serialized) {
            var query = serialized.length > 0 ? "?" + serialized : "";
            var base = this.href;
            var hashIndex = base.indexOf("#");
            var hash = hashIndex >= 0 ? base.slice(hashIndex) : "";
            if (hashIndex >= 0) base = base.slice(0, hashIndex);
            var queryIndex = base.indexOf("?");
            if (queryIndex >= 0) base = base.slice(0, queryIndex);
            this.search = query;
            this.href = base + query + hash;
        };
        globalThis.URL.prototype.toString = function() { return this.href; };

        globalThis.URLSearchParams = function(value) {
            this._pairs = [];
            if (value && value._pairs && Array.isArray(value._pairs)) {
                this._pairs = value._pairs.map(function(pair) { return [String(pair[0]), String(pair[1])]; });
                return;
            }
            if (Array.isArray(value)) {
                for (var pairIndex = 0; pairIndex < value.length; pairIndex++) {
                    var item = value[pairIndex];
                    if (item && item.length >= 2) this._pairs.push([String(item[0]), String(item[1])]);
                }
                return;
            }
            if (value && typeof value === "object") {
                var self = this;
                Object.keys(value).forEach(function(key) { self._pairs.push([String(key), String(value[key])]); });
                return;
            }
            var text = value == null ? "" : String(value);
            if (text.charAt(0) === "?") text = text.slice(1);
            if (text.length > 0) {
                var parts = text.split("&");
                for (var i = 0; i < parts.length; i++) {
                    var pair = parts[i].split("=");
                    this._pairs.push([decodeURIComponent(pair[0] || ""), decodeURIComponent(pair.slice(1).join("=") || "")]);
                }
            }
        };
        globalThis.URLSearchParams.prototype.get = function(name) {
            for (var i = 0; i < this._pairs.length; i++) if (this._pairs[i][0] === name) return this._pairs[i][1];
            return null;
        };
        globalThis.URLSearchParams.prototype.__syncURL = function() {
            if (this._url) this._url.__applySearchParams(this.toString());
        };
        globalThis.URLSearchParams.prototype.set = function(name, value) {
            var replaced = false;
            for (var i = 0; i < this._pairs.length; i++) {
                if (this._pairs[i][0] === name) {
                    this._pairs[i][1] = String(value);
                    replaced = true;
                    break;
                }
            }
            if (!replaced) this._pairs.push([String(name), String(value)]);
            this.__syncURL();
        };
        globalThis.URLSearchParams.prototype.append = function(name, value) {
            this._pairs.push([String(name), String(value)]);
            this.__syncURL();
        };
        globalThis.URLSearchParams.prototype.has = function(name) {
            for (var i = 0; i < this._pairs.length; i++) if (this._pairs[i][0] === name) return true;
            return false;
        };
        globalThis.URLSearchParams.prototype.delete = function(name) {
            this._pairs = this._pairs.filter(function(pair) { return pair[0] !== name; });
            this.__syncURL();
        };
        globalThis.URLSearchParams.prototype.getAll = function(name) {
            return this._pairs.filter(function(pair) { return pair[0] === name; }).map(function(pair) { return pair[1]; });
        };
        globalThis.URLSearchParams.prototype.entries = function() { return this._pairs.slice(); };
        globalThis.URLSearchParams.prototype.keys = function() { return this._pairs.map(function(pair) { return pair[0]; }); };
        globalThis.URLSearchParams.prototype.values = function() { return this._pairs.map(function(pair) { return pair[1]; }); };
        globalThis.URLSearchParams.prototype.forEach = function(callback) {
            for (var i = 0; i < this._pairs.length; i++) callback(this._pairs[i][1], this._pairs[i][0], this);
        };
        globalThis.URLSearchParams.prototype.sort = function() {
            this._pairs.sort(function(lhs, rhs) { return lhs[0] < rhs[0] ? -1 : (lhs[0] > rhs[0] ? 1 : 0); });
            this.__syncURL();
        };
        globalThis.URLSearchParams.prototype.toString = function() {
            return this._pairs.map(function(pair) { return encodeURIComponent(pair[0]) + "=" + encodeURIComponent(pair[1]); }).join("&");
        };
        if (typeof Symbol !== "undefined" && Symbol.iterator) {
            globalThis.URLSearchParams.prototype[Symbol.iterator] = function() { return this.entries()[Symbol.iterator](); };
        }

        // ===== TextEncoder / TextDecoder =====
        if (typeof TextEncoder === "undefined") {
            globalThis.TextEncoder = function() {};
            TextEncoder.prototype.encode = function(str) {
                var hex = __crypto_utf8_to_hex(String(str == null ? "" : str));
                var bytes = new Uint8Array(hex.length / 2);
                for (var i = 0; i < hex.length; i += 2) bytes[i / 2] = parseInt(hex.substring(i, i + 2), 16);
                return bytes;
            };
        }
        if (typeof TextDecoder === "undefined") {
            globalThis.TextDecoder = function() {};
            TextDecoder.prototype.decode = function(data) {
                var bytes = data;
                if (data instanceof ArrayBuffer) bytes = new Uint8Array(data);
                else if (data && data.buffer instanceof ArrayBuffer && !(data instanceof Uint8Array)) bytes = new Uint8Array(data.buffer, data.byteOffset || 0, data.byteLength);
                var hex = "";
                for (var i = 0; i < bytes.length; i++) hex += bytes[i].toString(16).padStart(2, "0");
                return __crypto_hex_to_utf8(hex);
            };
        }

        // A few scrapers reach for `Buffer.from(value, "base64")` as a decoder. Back it with
        // the same binary-safe primitives as atob/btoa rather than pulling in a Node shim.
        (function() {
            function bytesToLatin1(bytes) {
                var out = "";
                for (var i = 0; i < bytes.length; i++) out += String.fromCharCode(bytes[i] & 0xff);
                return out;
            }
            function hexToBytes(hex) {
                var bytes = new Uint8Array(hex.length / 2);
                for (var i = 0; i < hex.length; i += 2) bytes[i / 2] = parseInt(hex.substring(i, i + 2), 16);
                return bytes;
            }
            function bytesToHex(bytes) {
                var hex = "";
                for (var i = 0; i < bytes.length; i++) hex += bytes[i].toString(16).padStart(2, "0");
                return hex;
            }
            function latin1ToBytes(value) {
                var bytes = new Uint8Array(value.length);
                for (var i = 0; i < value.length; i++) bytes[i] = value.charCodeAt(i) & 0xff;
                return bytes;
            }
            function makeBuffer(bytes) {
                var buffer = Object.create(BufferShim.prototype);
                buffer._bytes = bytes;
                buffer.length = bytes.length;
                return buffer;
            }
            function BufferShim() {}
            BufferShim.prototype.toString = function(encoding) {
                var enc = String(encoding || "utf8").toLowerCase();
                if (enc === "hex") return bytesToHex(this._bytes);
                if (enc === "base64") return globalThis.btoa(bytesToLatin1(this._bytes));
                if (enc === "latin1" || enc === "binary" || enc === "ascii") return bytesToLatin1(this._bytes);
                return __crypto_hex_to_utf8(bytesToHex(this._bytes));
            };
            BufferShim.from = function(value, encoding) {
                if (value == null) return makeBuffer(new Uint8Array(0));
                if (value instanceof Uint8Array) return makeBuffer(value);
                if (value instanceof ArrayBuffer) return makeBuffer(new Uint8Array(value));
                if (Array.isArray(value)) return makeBuffer(new Uint8Array(value));
                var enc = String(encoding || "utf8").toLowerCase();
                var text = String(value);
                if (enc === "base64") return makeBuffer(latin1ToBytes(globalThis.atob(text)));
                if (enc === "hex") return makeBuffer(hexToBytes(text.length % 2 ? "0" + text : text));
                if (enc === "latin1" || enc === "binary" || enc === "ascii") return makeBuffer(latin1ToBytes(text));
                return makeBuffer(hexToBytes(__crypto_utf8_to_hex(text)));
            };
            BufferShim.byteLength = function(value, encoding) { return BufferShim.from(value, encoding).length; };
            BufferShim.isBuffer = function(value) { return value instanceof BufferShim; };
            BufferShim.concat = function(list) {
                var total = 0, i;
                for (i = 0; i < list.length; i++) total += list[i]._bytes.length;
                var merged = new Uint8Array(total), offset = 0;
                for (i = 0; i < list.length; i++) { merged.set(list[i]._bytes, offset); offset += list[i]._bytes.length; }
                return makeBuffer(merged);
            };
            if (typeof globalThis.Buffer === "undefined") globalThis.Buffer = BufferShim;
        })();

        // `AbortSignal.timeout(ms)` is used as a request deadline. The native fetch already
        // carries its own timeout, so the signal is inert here - it just must exist and abort
        // on schedule so `signal.aborted` checks behave.
        if (typeof globalThis.AbortSignal === "function" && typeof globalThis.AbortSignal.timeout !== "function") {
            globalThis.AbortSignal.timeout = function(milliseconds) {
                var controller = new globalThis.AbortController();
                var timeoutMilliseconds = Math.min(Math.max(Number(milliseconds) || 0, 0), 30000);
                controller.signal._eclipseTimeoutMilliseconds = timeoutMilliseconds;
                globalThis.setTimeout(function() { controller.abort("TimeoutError"); }, timeoutMilliseconds);
                return controller.signal;
            };
        }
        if (typeof globalThis.AbortSignal === "function" && typeof globalThis.AbortSignal.abort !== "function") {
            globalThis.AbortSignal.abort = function(reason) {
                var controller = new globalThis.AbortController();
                controller.abort(reason);
                return controller.signal;
            };
        }

        if (typeof globalThis.FormData === "undefined") {
            globalThis.FormData = function() { this._entries = []; };
            globalThis.FormData.prototype.append = function(name, value) {
                this._entries.push([String(name), value == null ? "" : String(value)]);
            };
            globalThis.FormData.prototype.set = function(name, value) {
                this.delete(name);
                this.append(name, value);
            };
            globalThis.FormData.prototype.get = function(name) {
                var needle = String(name);
                for (var i = 0; i < this._entries.length; i++) {
                    if (this._entries[i][0] === needle) return this._entries[i][1];
                }
                return null;
            };
            globalThis.FormData.prototype.getAll = function(name) {
                var needle = String(name);
                return this._entries.filter(function(pair) { return pair[0] === needle; })
                    .map(function(pair) { return pair[1]; });
            };
            globalThis.FormData.prototype.has = function(name) { return this.get(name) !== null; };
            globalThis.FormData.prototype.delete = function(name) {
                var needle = String(name);
                this._entries = this._entries.filter(function(pair) { return pair[0] !== needle; });
            };
            globalThis.FormData.prototype.entries = function() { return this._entries.slice(); };
            globalThis.FormData.prototype.forEach = function(callback) {
                var self = this;
                this._entries.forEach(function(pair) { callback(pair[1], pair[0], self); });
            };
            globalThis.FormData.prototype.__multipartBoundary = function() {
                return "----EclipseNuvioFormBoundary" + String(this._entries.length) + "x7MA4YWxkTrZu0gW";
            };
            globalThis.FormData.prototype.__multipartBody = function(boundary) {
                var body = "";
                this._entries.forEach(function(pair) {
                    body += "--" + boundary + "\\r\\n";
                    body += 'Content-Disposition: form-data; name="' + pair[0] + '"\\r\\n\\r\\n';
                    body += pair[1] + "\\r\\n";
                });
                return body + "--" + boundary + "--\\r\\n";
            };
        }

        // ===== CryptoJS (byte-accurate, native-backed) + TripleDES =====
        var WordArray = {
            init: function(words, sigBytes) {
                this.words = words || [];
                this.sigBytes = sigBytes != undefined ? sigBytes : this.words.length * 4;
            },
            toString: function(encoder) { return (encoder || CryptoJS.enc.Hex).stringify(this); },
            concat: function(wordArray) {
                var thisWords = this.words, thatWords = wordArray.words;
                var thisSigBytes = this.sigBytes, thatSigBytes = wordArray.sigBytes;
                this.clamp();
                for (var i = 0; i < thatSigBytes; i++) {
                    var thatByte = (thatWords[i >>> 2] >>> (24 - (i % 4) * 8)) & 0xff;
                    thisWords[(thisSigBytes + i) >>> 2] |= thatByte << (24 - ((thisSigBytes + i) % 4) * 8);
                }
                this.sigBytes += thatSigBytes;
                return this;
            },
            clamp: function() {
                var words = this.words, sigBytes = this.sigBytes;
                if (sigBytes % 4) words[sigBytes >>> 2] &= 0xffffffff << (32 - (sigBytes % 4) * 8);
                words.length = Math.ceil(sigBytes / 4);
                return this;
            },
            clone: function() { return __wordArrayCreate(this.words.slice(0), this.sigBytes); }
        };
        function __wordArrayCreate(words, sigBytes) { var wa = Object.create(WordArray); wa.init(words, sigBytes); return wa; }
        function __isWordArray(value) { return value && typeof value === "object" && Array.isArray(value.words) && typeof value.sigBytes === "number"; }
        function __copyUint8Array(bytes) { bytes = __toUint8Array(bytes); var copy = new Uint8Array(bytes.length); copy.set(bytes); return copy; }
        function __toUint8Array(data) {
            if (!data) return new Uint8Array(0);
            if (data instanceof Uint8Array) return data;
            if (data instanceof ArrayBuffer) return new Uint8Array(data);
            if (typeof ArrayBuffer !== "undefined" && ArrayBuffer.isView && ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset || 0, data.byteLength);
            if (Array.isArray(data)) return new Uint8Array(data);
            if (typeof data.length === "number") return new Uint8Array(Array.prototype.slice.call(data));
            return new Uint8Array(0);
        }
        function __bytesToArrayBuffer(bytes) { return __copyUint8Array(bytes).buffer; }
        function __wordArrayToBytes(wordArray) {
            if (!__isWordArray(wordArray)) return typeof wordArray === "string" ? new TextEncoder().encode(wordArray) : __toUint8Array(wordArray);
            var bytes = new Uint8Array(wordArray.sigBytes);
            for (var i = 0; i < wordArray.sigBytes; i++) bytes[i] = (wordArray.words[i >>> 2] >>> (24 - (i % 4) * 8)) & 0xff;
            return bytes;
        }
        function __bytesToWordArray(bytes) {
            bytes = __toUint8Array(bytes);
            var words = [];
            for (var i = 0; i < bytes.length; i++) words[i >>> 2] |= (bytes[i] & 0xff) << (24 - (i % 4) * 8);
            return __wordArrayCreate(words, bytes.length);
        }
        function __normalizeWordArrayInput(value) {
            if (__isWordArray(value)) return __wordArrayToBytes(value);
            if (typeof value === "string") return new TextEncoder().encode(value);
            return __toUint8Array(value);
        }
        function __bytesToHex(bytes) { bytes = __toUint8Array(bytes); var out = []; for (var i = 0; i < bytes.length; i++) { var hex = bytes[i].toString(16); out.push(hex.length < 2 ? "0" + hex : hex); } return out.join(""); }
        function __hexToBytes(hex) {
            hex = String(hex || "").replace(/[^0-9a-fA-F]/g, "");
            if (hex.length % 2) hex = "0" + hex;
            var bytes = new Uint8Array(hex.length / 2);
            for (var i = 0; i < hex.length; i += 2) bytes[i / 2] = parseInt(hex.substr(i, 2), 16) & 0xff;
            return bytes;
        }
        function __concatBytes() {
            var total = 0, parts = [];
            for (var i = 0; i < arguments.length; i++) { var part = __toUint8Array(arguments[i]); parts.push(part); total += part.length; }
            var out = new Uint8Array(total), offset = 0;
            for (var j = 0; j < parts.length; j++) { out.set(parts[j], offset); offset += parts[j].length; }
            return out;
        }
        function __normalizeHashName(hash) {
            var name = hash && hash.name ? hash.name : hash;
            name = String(name || "SHA-256").toUpperCase().replace(/[^A-Z0-9]/g, "");
            if (name === "SHA1" || name === "SHA256" || name === "SHA384" || name === "SHA512" || name === "MD5") return name;
            throw new Error("Unsupported hash algorithm: " + name);
        }
        function __normalizeAlgorithmName(algo) {
            var name = algo && algo.name ? algo.name : algo;
            name = String(name || "").toUpperCase();
            if (name.indexOf("AES-GCM") >= 0) return "AES-GCM";
            if (name.indexOf("AES-CBC") >= 0) return "AES-CBC";
            if (name.indexOf("AES-ECB") >= 0 || name === "ECB") return "AES-ECB";
            if (name.indexOf("PBKDF2") >= 0) return "PBKDF2";
            if (name.indexOf("HMAC") >= 0) return "HMAC";
            return name;
        }
        function __aesModeName(mode, padding) {
            var normalized = __normalizeAlgorithmName(mode || "AES-CBC");
            if (normalized === "CBC") normalized = "AES-CBC";
            if (normalized === "GCM") normalized = "AES-GCM";
            if (normalized !== "AES-CBC" && normalized !== "AES-GCM" && normalized !== "AES-ECB") throw new Error("Unsupported AES cipher mode: " + normalized);
            if (padding === CryptoJS.pad.NoPadding || padding === "NoPadding") normalized += "-NoPadding";
            return normalized;
        }
        function __des3ModeName(mode, padding) {
            var m = String((mode && mode.name) || mode || "CBC").toUpperCase();
            if (m.indexOf("CBC") < 0 && m.indexOf("ECB") < 0) throw new Error("Unsupported TripleDES cipher mode: " + m);
            var normalized = m.indexOf("ECB") >= 0 ? "DES3-ECB" : "DES3-CBC";
            if (padding === CryptoJS.pad.NoPadding || padding === "NoPadding") normalized += "-NoPadding";
            return normalized;
        }
        function __nativeDigestBytes(hash, dataBytes) {
            if (typeof __crypto_digest_hex_raw === "undefined") throw new Error("Native digest bridge is unavailable");
            return __hexToBytes(__crypto_digest_hex_raw(__normalizeHashName(hash), __bytesToHex(dataBytes)));
        }
        function __nativeHmacBytes(hash, keyBytes, dataBytes) {
            if (typeof __crypto_hmac_hex_raw === "undefined") throw new Error("Native HMAC bridge is unavailable");
            return __hexToBytes(__crypto_hmac_hex_raw(__normalizeHashName(hash), __bytesToHex(keyBytes), __bytesToHex(dataBytes)));
        }
        function __nativePbkdf2Bytes(passwordBytes, saltBytes, iterations, keySizeBits, hash) {
            if (typeof __crypto_pbkdf2_hex === "undefined") throw new Error("Native PBKDF2 bridge is unavailable");
            return __hexToBytes(__crypto_pbkdf2_hex(__bytesToHex(passwordBytes), __bytesToHex(saltBytes), iterations, keySizeBits, __normalizeHashName(hash)));
        }
        function __nativeAesBytes(encrypt, mode, keyBytes, ivBytes, dataBytes) {
            var fn = encrypt ? __crypto_aes_encrypt_hex : __crypto_aes_decrypt_hex;
            if (typeof fn === "undefined") throw new Error("Native AES bridge is unavailable");
            return __hexToBytes(fn(mode, __bytesToHex(keyBytes), __bytesToHex(ivBytes), __bytesToHex(dataBytes)));
        }
        function __nativeDes3Bytes(encrypt, mode, keyBytes, ivBytes, dataBytes) {
            var fn = encrypt ? __crypto_des3_encrypt_hex : __crypto_des3_decrypt_hex;
            if (typeof fn === "undefined") throw new Error("Native TripleDES bridge is unavailable");
            return __hexToBytes(fn(mode, __bytesToHex(keyBytes), __bytesToHex(ivBytes), __bytesToHex(dataBytes)));
        }
        function __evpKdf(passwordBytes, saltBytes, keySizeBytes, ivSizeBytes) {
            var targetSize = keySizeBytes + ivSizeBytes;
            var derived = new Uint8Array(targetSize);
            var block = new Uint8Array(0), offset = 0;
            while (offset < targetSize) {
                block = __nativeDigestBytes("MD5", __concatBytes(block, passwordBytes, saltBytes || new Uint8Array(0)));
                var take = Math.min(block.length, targetSize - offset);
                derived.set(block.subarray(0, take), offset);
                offset += take;
            }
            return { key: derived.subarray(0, keySizeBytes), iv: derived.subarray(keySizeBytes, keySizeBytes + ivSizeBytes) };
        }
        function __opensslSaltHeader() { return new Uint8Array([83, 97, 108, 116, 101, 100, 95, 95]); }
        function __hasOpenSslSaltHeader(bytes) {
            var header = __opensslSaltHeader();
            if (!bytes || bytes.length < 16) return false;
            for (var i = 0; i < header.length; i++) if (bytes[i] !== header[i]) return false;
            return true;
        }
        function __makeCipherParams(ciphertext, key, iv, salt, mode) {
            return {
                ciphertext: __bytesToWordArray(ciphertext),
                key: key ? __bytesToWordArray(key) : undefined,
                iv: iv ? __bytesToWordArray(iv) : undefined,
                salt: salt ? __bytesToWordArray(salt) : undefined,
                mode: mode,
                toString: function(formatter) { return (formatter || CryptoJS.format.OpenSSL).stringify(this); }
            };
        }
        function __makeCipherApi(nativeFn, modeNameFn, keySizeBytes, ivSizeBytes) {
            return {
                encrypt: function(message, key, options) {
                    options = options || {};
                    var data = __normalizeWordArrayInput(message);
                    var kBytes, ivBytes, saltBytes;
                    if (typeof key === "string") {
                        saltBytes = options.salt ? __wordArrayToBytes(options.salt) : __wordArrayToBytes(CryptoJS.lib.WordArray.random(8));
                        var derived = __evpKdf(new TextEncoder().encode(key), saltBytes, keySizeBytes, ivSizeBytes);
                        kBytes = derived.key;
                        ivBytes = options.iv ? __wordArrayToBytes(options.iv) : derived.iv;
                    } else {
                        kBytes = __wordArrayToBytes(key);
                        ivBytes = options.iv ? __wordArrayToBytes(options.iv) : new Uint8Array(0);
                    }
                    var mode = modeNameFn(options.mode, options.padding);
                    var resBytes = nativeFn(true, mode, kBytes, ivBytes, data);
                    return __makeCipherParams(resBytes, kBytes, ivBytes, saltBytes, mode);
                },
                decrypt: function(cipher, key, options) {
                    options = options || {};
                    var cipherParams = typeof cipher === "string" ? CryptoJS.format.OpenSSL.parse(cipher) : cipher;
                    var data = cipherParams.ciphertext ? __wordArrayToBytes(cipherParams.ciphertext) : __toUint8Array(cipherParams);
                    var kBytes, ivBytes;
                    if (typeof key === "string") {
                        var saltBytes = options.salt ? __wordArrayToBytes(options.salt) : (cipherParams.salt ? __wordArrayToBytes(cipherParams.salt) : new Uint8Array(0));
                        var derived = __evpKdf(new TextEncoder().encode(key), saltBytes, keySizeBytes, ivSizeBytes);
                        kBytes = derived.key;
                        ivBytes = options.iv ? __wordArrayToBytes(options.iv) : derived.iv;
                    } else {
                        kBytes = __wordArrayToBytes(key);
                        ivBytes = options.iv ? __wordArrayToBytes(options.iv) : new Uint8Array(0);
                    }
                    var mode = modeNameFn(options.mode, options.padding);
                    return __bytesToWordArray(nativeFn(false, mode, kBytes, ivBytes, data));
                }
            };
        }
        var CryptoJS = {
            enc: {
                Hex: {
                    stringify: function(wordArray) { return __bytesToHex(__wordArrayToBytes(wordArray)); },
                    parse: function(hexStr) { return __bytesToWordArray(__hexToBytes(hexStr)); }
                },
                Utf8: {
                    stringify: function(wordArray) { return new TextDecoder("utf-8").decode(__wordArrayToBytes(wordArray)); },
                    parse: function(utf8Str) { return __bytesToWordArray(new TextEncoder().encode(String(utf8Str))); }
                },
                Latin1: {
                    stringify: function(wordArray) { var bytes = __wordArrayToBytes(wordArray); var out = ""; for (var i = 0; i < bytes.length; i++) out += String.fromCharCode(bytes[i]); return out; },
                    parse: function(str) { str = String(str || ""); var bytes = new Uint8Array(str.length); for (var i = 0; i < str.length; i++) bytes[i] = str.charCodeAt(i) & 0xff; return __bytesToWordArray(bytes); }
                },
                Base64: {
                    stringify: function(wordArray) { var bytes = __wordArrayToBytes(wordArray); var binaryStr = ""; for (var j = 0; j < bytes.length; j++) binaryStr += String.fromCharCode(bytes[j]); return btoa(binaryStr); },
                    parse: function(base64Str) { var binaryStr = atob(String(base64Str || "")); var bytes = new Uint8Array(binaryStr.length); for (var i = 0; i < binaryStr.length; i++) bytes[i] = binaryStr.charCodeAt(i) & 0xff; return __bytesToWordArray(bytes); }
                }
            },
            lib: {
                WordArray: {
                    create: function(words, sigBytes) {
                        if (words == null) return __wordArrayCreate([], sigBytes || 0);
                        if (__isWordArray(words)) return words.clone();
                        if (typeof words === "string") return CryptoJS.enc.Utf8.parse(words);
                        if (words instanceof ArrayBuffer || (typeof ArrayBuffer !== "undefined" && ArrayBuffer.isView && ArrayBuffer.isView(words))) {
                            var bytes = __toUint8Array(words);
                            return __bytesToWordArray(sigBytes != undefined ? bytes.subarray(0, sigBytes) : bytes);
                        }
                        return __wordArrayCreate(words, sigBytes);
                    },
                    random: function(nBytes) {
                        var bytes = new Uint8Array(nBytes || 0);
                        globalThis.crypto.getRandomValues(bytes);
                        return __bytesToWordArray(bytes);
                    }
                },
                CipherParams: {
                    create: function(params) {
                        params = params || {};
                        params.toString = params.toString || function(formatter) { return (formatter || CryptoJS.format.OpenSSL).stringify(this); };
                        return params;
                    }
                }
            },
            format: {
                OpenSSL: {
                    stringify: function(cipherParams) {
                        var cipherBytes = __wordArrayToBytes(cipherParams.ciphertext);
                        var out = cipherParams.salt ? __concatBytes(__opensslSaltHeader(), __wordArrayToBytes(cipherParams.salt), cipherBytes) : cipherBytes;
                        return CryptoJS.enc.Base64.stringify(__bytesToWordArray(out));
                    },
                    parse: function(str) {
                        var bytes = __wordArrayToBytes(CryptoJS.enc.Base64.parse(str));
                        if (__hasOpenSslSaltHeader(bytes)) return CryptoJS.lib.CipherParams.create({ salt: __bytesToWordArray(bytes.subarray(8, 16)), ciphertext: __bytesToWordArray(bytes.subarray(16)) });
                        return CryptoJS.lib.CipherParams.create({ ciphertext: __bytesToWordArray(bytes) });
                    }
                }
            },
            mode: { CBC: "AES-CBC", GCM: "AES-GCM", ECB: "AES-ECB", CTR: "AES-CTR", CFB: "AES-CFB", OFB: "AES-OFB" },
            pad: { Pkcs7: "Pkcs7", NoPadding: "NoPadding" },
            algo: { MD5: "MD5", SHA1: "SHA1", SHA256: "SHA256", SHA384: "SHA384", SHA512: "SHA512", AES: "AES" },
            MD5: function(m) { return __bytesToWordArray(__nativeDigestBytes("MD5", __normalizeWordArrayInput(m))); },
            SHA1: function(m) { return __bytesToWordArray(__nativeDigestBytes("SHA1", __normalizeWordArrayInput(m))); },
            SHA256: function(m) { return __bytesToWordArray(__nativeDigestBytes("SHA256", __normalizeWordArrayInput(m))); },
            SHA384: function(m) { return __bytesToWordArray(__nativeDigestBytes("SHA384", __normalizeWordArrayInput(m))); },
            SHA512: function(m) { return __bytesToWordArray(__nativeDigestBytes("SHA512", __normalizeWordArrayInput(m))); },
            HmacMD5: function(m, k) { return __bytesToWordArray(__nativeHmacBytes("MD5", __normalizeWordArrayInput(k), __normalizeWordArrayInput(m))); },
            HmacSHA1: function(m, k) { return __bytesToWordArray(__nativeHmacBytes("SHA1", __normalizeWordArrayInput(k), __normalizeWordArrayInput(m))); },
            HmacSHA256: function(m, k) { return __bytesToWordArray(__nativeHmacBytes("SHA256", __normalizeWordArrayInput(k), __normalizeWordArrayInput(m))); },
            HmacSHA384: function(m, k) { return __bytesToWordArray(__nativeHmacBytes("SHA384", __normalizeWordArrayInput(k), __normalizeWordArrayInput(m))); },
            HmacSHA512: function(m, k) { return __bytesToWordArray(__nativeHmacBytes("SHA512", __normalizeWordArrayInput(k), __normalizeWordArrayInput(m))); },
            PBKDF2: function(pass, salt, options) {
                options = options || {};
                var pBytes = __normalizeWordArrayInput(pass);
                var sBytes = __normalizeWordArrayInput(salt);
                var iter = options.iterations || 1000;
                var kSize = options.keySize || 8;
                var algo = options.hasher || "SHA1";
                return __bytesToWordArray(__nativePbkdf2Bytes(pBytes, sBytes, iter, kSize * 32, algo));
            }
        };
        CryptoJS.AES = __makeCipherApi(__nativeAesBytes, __aesModeName, 32, 16);
        CryptoJS.TripleDES = __makeCipherApi(__nativeDes3Bytes, __des3ModeName, 24, 8);
        CryptoJS.DES3 = CryptoJS.TripleDES;
        globalThis.CryptoJS = CryptoJS;

        // ===== Web Crypto (subtle digest/hmac/aes + getRandomValues) =====
        function __makeCryptoKey(type, algorithm, extractable, usages, rawBytes) {
            return { type: type, extractable: !!extractable, algorithm: algorithm, usages: usages || [], _raw: __copyUint8Array(rawBytes) };
        }
        function __webCryptoAlgorithm(algo) {
            var name = __normalizeAlgorithmName(algo);
            var out = { name: name };
            if (algo && typeof algo === "object" && algo.length) out.length = algo.length;
            if (algo && typeof algo === "object" && algo.hash) out.hash = { name: __normalizeHashName(algo.hash) };
            return out;
        }
        globalThis.crypto = {
            subtle: {
                digest: async function(algo, data) { return __bytesToArrayBuffer(__nativeDigestBytes(algo, __toUint8Array(data))); },
                importKey: async function(fmt, data, algo, extractable, usages) {
                    fmt = String(fmt || "raw").toLowerCase();
                    if (fmt !== "raw") throw new Error("Unsupported key format: " + fmt);
                    return __makeCryptoKey("secret", __webCryptoAlgorithm(algo || {}), extractable, usages || [], __toUint8Array(data));
                },
                exportKey: async function(fmt, key) { return __bytesToArrayBuffer(key._raw); },
                deriveBits: async function(params, key, len) {
                    if (__normalizeAlgorithmName(params) !== "PBKDF2") throw new Error("Only PBKDF2 deriveBits is supported");
                    return __bytesToArrayBuffer(__nativePbkdf2Bytes(__toUint8Array(key._raw), __toUint8Array(params.salt), params.iterations || 1000, len, params.hash || "SHA-256"));
                },
                encrypt: async function(params, key, data) {
                    var mode = __normalizeAlgorithmName(params);
                    if (mode !== "AES-CBC" && mode !== "AES-GCM") throw new Error("Unsupported encrypt algorithm: " + mode);
                    return __bytesToArrayBuffer(__nativeAesBytes(true, mode, __toUint8Array(key._raw), __toUint8Array(params.iv || new Uint8Array(0)), __toUint8Array(data)));
                },
                decrypt: async function(params, key, data) {
                    var mode = __normalizeAlgorithmName(params);
                    if (mode !== "AES-CBC" && mode !== "AES-GCM") throw new Error("Unsupported decrypt algorithm: " + mode);
                    return __bytesToArrayBuffer(__nativeAesBytes(false, mode, __toUint8Array(key._raw), __toUint8Array(params.iv || new Uint8Array(0)), __toUint8Array(data)));
                },
                sign: async function(algo, key, data) {
                    if (__normalizeAlgorithmName(algo || key.algorithm) === "HMAC" || (key.algorithm && key.algorithm.name === "HMAC")) {
                        var hash = (algo && algo.hash) || (key.algorithm && key.algorithm.hash) || "SHA-256";
                        return __bytesToArrayBuffer(__nativeHmacBytes(hash, __toUint8Array(key._raw), __toUint8Array(data)));
                    }
                    throw new Error("Unsupported sign algorithm");
                },
                verify: async function(algo, key, sig, data) {
                    if (__normalizeAlgorithmName(algo || key.algorithm) === "HMAC" || (key.algorithm && key.algorithm.name === "HMAC")) {
                        var expected = __nativeHmacBytes((algo && algo.hash) || (key.algorithm && key.algorithm.hash) || "SHA-256", __toUint8Array(key._raw), __toUint8Array(data));
                        var actual = __toUint8Array(sig);
                        if (expected.length !== actual.length) return false;
                        var diff = 0;
                        for (var i = 0; i < expected.length; i++) diff |= expected[i] ^ actual[i];
                        return diff === 0;
                    }
                    throw new Error("Unsupported verify algorithm");
                }
            },
            getRandomValues: function(arr) {
                if (!arr) return arr;
                var byteLength = arr.byteLength != undefined ? arr.byteLength : arr.length;
                if (!byteLength) return arr;
                if (typeof __crypto_get_random_values_hex === "undefined") throw new Error("Native random bridge is unavailable");
                if (byteLength > 65536) throw new Error("QuotaExceededError: getRandomValues supports at most 65536 bytes");
                var random = __hexToBytes(__crypto_get_random_values_hex(byteLength));
                // A short answer would leave the tail of the array zero-filled, which reads as a
                // successful call and silently produces a predictable key or IV.
                if (random.length < byteLength) throw new Error("Native random bridge returned insufficient entropy");
                if (arr.buffer && arr.byteLength != undefined) new Uint8Array(arr.buffer, arr.byteOffset || 0, arr.byteLength).set(random);
                else for (var i = 0; i < arr.length; i++) arr[i] = random[i] || 0;
                return arr;
            },
            randomUUID: function() {
                var b = new Uint8Array(16);
                globalThis.crypto.getRandomValues(b);
                b[6] = (b[6] & 0x0f) | 0x40;
                b[8] = (b[8] & 0x3f) | 0x80;
                var h = __bytesToHex(b);
                return h.substr(0, 8) + "-" + h.substr(8, 4) + "-" + h.substr(12, 4) + "-" + h.substr(16, 4) + "-" + h.substr(20);
            }
        };

        globalThis.WebAssembly = globalThis.WebAssembly || {
            instantiate: async function() { return { instance: { exports: {} }, module: {} }; }
        };

        function __cheerioFiltered(list, selector) {
            if (selector === undefined || selector === null) return createCheerioCollection(list);
            var needle = String(selector);
            if (needle === "*") return createCheerioCollection(list);
            return createCheerioCollection(list.filter(function(id) {
                return __cheerio_matches(id, needle);
            }));
        }
        function createCheerioCollection(ids) {
            ids = ids || [];
            function api(selector) { return api.find(selector); }
            api.length = ids.length;
            api.get = function(index) {
                if (index === undefined) return ids.map(function(id) { return createCheerioCollection([id]); });
                return ids[index] == null ? undefined : createCheerioCollection([ids[index]]);
            };
            api.eq = function(index) { return ids[index] == null ? createCheerioCollection([]) : createCheerioCollection([ids[index]]); };
            api.first = function() { return api.eq(0); };
            api.last = function() { return api.eq(ids.length - 1); };
            api.text = function() { return ids.map(function(id) { return __cheerio_text(id); }).join(""); };
            api.html = function() { return ids.length ? __cheerio_inner_html(ids[0]) : null; };
            api.outerHtml = function() { return ids.length ? __cheerio_html(ids[0]) : null; };
            api.attr = function(name) {
                if (!ids.length) return undefined;
                var value = __cheerio_attr(ids[0], String(name));
                return value == null ? undefined : value;
            };
            api.find = function(selector) {
                var out = [];
                ids.forEach(function(id) { out = out.concat(__cheerio_select(id, String(selector))); });
                return createCheerioCollection(out);
            };
            api.next = function() {
                var out = [];
                ids.forEach(function(id) {
                    var next = __cheerio_next(id);
                    if (next) out.push(next);
                });
                return createCheerioCollection(out);
            };
            api.prev = function() {
                var out = [];
                ids.forEach(function(id) {
                    var previous = __cheerio_prev(id);
                    if (previous) out.push(previous);
                });
                return createCheerioCollection(out);
            };
            api.each = function(fn) {
                ids.forEach(function(id, index) { fn.call(createCheerioCollection([id]), index, createCheerioCollection([id])); });
                return api;
            };
            api.map = function(fn) {
                var out = [];
                ids.forEach(function(id, index) {
                    var value = fn.call(createCheerioCollection([id]), index, createCheerioCollection([id]));
                    if (value !== undefined && value !== null) out.push(value);
                });
                return {
                    length: out.length,
                    get: function(index) { return typeof index === "number" ? out[index] : out; },
                    toArray: function() { return out; }
                };
            };
            api.filter = function(selectorOrCallback) {
                if (typeof selectorOrCallback === "function") {
                    var filtered = [];
                    ids.forEach(function(id, index) {
                        var item = createCheerioCollection([id]);
                        if (selectorOrCallback.call(item, index, item)) filtered.push(id);
                    });
                    return createCheerioCollection(filtered);
                }
                var selector = String(selectorOrCallback);
                return createCheerioCollection(ids.filter(function(id) {
                    return __cheerio_matches(id, selector);
                }));
            };
            api.is = function(selector) {
                if (selector == null) return false;
                var needle = String(selector);
                return ids.some(function(id) { return __cheerio_matches(id, needle); });
            };
            api.not = function(selector) {
                var needle = String(selector);
                return createCheerioCollection(ids.filter(function(id) {
                    return !__cheerio_matches(id, needle);
                }));
            };
            api.slice = function(start, end) {
                return createCheerioCollection(ids.slice(start, end === undefined ? ids.length : end));
            };
            api.children = function(selector) {
                var out = [];
                ids.forEach(function(id) { out = out.concat(__cheerio_children(id)); });
                return __cheerioFiltered(out, selector);
            };
            api.hasClass = function(name) {
                if (name === undefined || name === null) return false;
                var needle = String(name);
                if (!needle.length) return false;
                return ids.some(function(id) {
                    var raw = __cheerio_attr(id, "class");
                    if (typeof raw !== "string" || !raw.length) return false;
                    var token = "";
                    for (var i = 0; i <= raw.length; i++) {
                        var code = i < raw.length ? raw.charCodeAt(i) : 32;
                        if (code === 32 || code === 9 || code === 10 || code === 13 || code === 12) {
                            if (token === needle) return true;
                            token = "";
                        } else {
                            token += raw.charAt(i);
                        }
                    }
                    return false;
                });
            };
            api.nextAll = function(selector) {
                var out = [];
                ids.forEach(function(id) {
                    var cursor = __cheerio_next(id);
                    while (cursor) { out.push(cursor); cursor = __cheerio_next(cursor); }
                });
                return __cheerioFiltered(out, selector);
            };
            api.prevAll = function(selector) {
                var out = [];
                ids.forEach(function(id) {
                    var cursor = __cheerio_prev(id);
                    while (cursor) { out.push(cursor); cursor = __cheerio_prev(cursor); }
                });
                return __cheerioFiltered(out, selector);
            };
            api.siblings = function(selector) {
                var out = [];
                ids.forEach(function(id) {
                    var backwards = [];
                    var cursor = __cheerio_prev(id);
                    while (cursor) { backwards.push(cursor); cursor = __cheerio_prev(cursor); }
                    backwards.reverse();
                    out = out.concat(backwards);
                    cursor = __cheerio_next(id);
                    while (cursor) { out.push(cursor); cursor = __cheerio_next(cursor); }
                });
                return __cheerioFiltered(out, selector);
            };
            api.parents = function(selector) {
                var out = [];
                ids.forEach(function(id) {
                    var cursor = __cheerio_parent(id);
                    while (cursor) { out.push(cursor); cursor = __cheerio_parent(cursor); }
                });
                return __cheerioFiltered(out, selector);
            };
            api.closest = function(selector) {
                if (selector === undefined || selector === null) return createCheerioCollection([]);
                var needle = String(selector);
                var out = [];
                ids.forEach(function(id) {
                    var cursor = id;
                    while (cursor) {
                        if (__cheerio_matches(cursor, needle)) { out.push(cursor); return; }
                        cursor = __cheerio_parent(cursor);
                    }
                });
                return createCheerioCollection(out);
            };
            api.parent = function() {
                var out = [];
                ids.forEach(function(id) {
                    var parent = __cheerio_parent(id);
                    if (parent) out.push(parent);
                });
                return createCheerioCollection(out);
            };
            api.toArray = function() { return ids.map(function(id) { return createCheerioCollection([id]); }); };
            return api;
        }
        function cheerioLoad(html) {
            var root = __cheerio_load(String(html || ""));
            function cheerioFn(selector, context) {
                if (selector == null) return createCheerioCollection([root]);
                // `$(existingNode)` / `$(existingCollection)` - return it untouched, matching cheerio.
                // Collections are FUNCTIONS (so they can be invoked as `$(...)`), so `typeof` is
                // "function", not "object". Accept both, otherwise the extremely common
                // `.map((i, el) => $(el)...)` / `.each((i, el) => $(el)...)` idiom falls through to
                // `String(selector)` (the function's source code) and produces a garbage selector.
                if (selector && (typeof selector === "object" || typeof selector === "function") && typeof selector.toArray === "function") {
                    return selector;
                }
                // `$(selector, context)` - scope the search to the context collection (also a function).
                if (context && (typeof context === "object" || typeof context === "function") && typeof context.find === "function") {
                    return context.find(String(selector));
                }
                return createCheerioCollection(__cheerio_select(root, String(selector)));
            }
            // Static `$.html()` - serialize the whole document; `$.html(el)` serializes the
            // outer HTML of a node/collection. Common scraper idiom; matches the reference runtime.
            cheerioFn.html = function(node) {
                if (node && typeof node === "object" && typeof node.outerHtml === "function") {
                    return node.outerHtml();
                }
                return __cheerio_html(root);
            };
            return cheerioFn;
        }
        var cheerioModule = { load: cheerioLoad };

        globalThis.require = function(name) {
            if (name === "cheerio" || name === "cheerio-without-node-native" || name === "react-native-cheerio") return cheerioModule;
            if (name === "crypto-js") return globalThis.CryptoJS;
            throw new Error("Module not available: " + name);
        };
        """
    }

    private static func jsonLiteral(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            if let string = value as? String,
               let data = try? JSONSerialization.data(withJSONObject: [string]),
               let text = String(data: data, encoding: .utf8) {
                return String(text.dropFirst().dropLast())
            }
            return nil
        }
        return text
    }

    private static func parseURL(_ value: String, base: String?) -> [String: Any] {
        let url: URL?
        if let base, let baseURL = URL(string: base) {
            url = URL(string: value, relativeTo: baseURL)?.absoluteURL
        } else {
            url = URL(string: value)
        }
        guard let url else { return ["href": value] }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let hostname = url.host ?? ""
        let port = url.port.map(String.init) ?? ""
        let host = port.isEmpty ? hostname : "\(hostname):\(port)"
        let pathname = url.path.isEmpty ? "/" : url.path
        return [
            "href": url.absoluteString,
            "protocol": (url.scheme ?? "").isEmpty ? "" : "\(url.scheme ?? ""):",
            "host": host,
            "hostname": hostname,
            "port": port,
            "pathname": pathname,
            "search": components?.percentEncodedQuery.map { "?\($0)" } ?? "",
            "hash": components?.percentEncodedFragment.map { "#\($0)" } ?? "",
            "origin": "\(url.scheme ?? "")://\(host)"
        ]
    }

    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)

    private static func hexFromData(_ data: Data) -> String {
        var characters = [UInt8]()
        characters.reserveCapacity(data.count * 2)
        for byte in data {
            characters.append(hexDigits[Int(byte >> 4)])
            characters.append(hexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: characters, as: UTF8.self)
    }

    private static func boundedHexFromData(_ data: Data) throws -> String {
        guard data.count <= maxHexEncodableInputBytes else {
            throw NuvioPluginError.runtimeFailed(
                "Refusing to hex-encode \(data.count) bytes: the limit is \(maxHexEncodableInputBytes) bytes."
            )
        }
        return hexFromData(data)
    }

    private static func dataFromHex(_ hex: String) -> Data {
        let filtered = hex.lowercased().filter { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
        let normalized = filtered.count.isMultiple(of: 2) ? filtered : "0" + filtered
        var data = Data(capacity: normalized.count / 2)
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: 2)
            if let byte = UInt8(normalized[index..<next], radix: 16) {
                data.append(byte)
            }
            index = next
        }
        return data
    }

    private static func digestHexRaw(hashName: String, dataHex: String) -> String {
        let data = dataFromHex(dataHex)
        switch hashName.uppercased() {
        case "MD5": return hexFromData(Data(Insecure.MD5.hash(data: data)))
        case "SHA1": return hexFromData(Data(Insecure.SHA1.hash(data: data)))
        case "SHA384": return hexFromData(Data(SHA384.hash(data: data)))
        case "SHA512": return hexFromData(Data(SHA512.hash(data: data)))
        default: return hexFromData(Data(SHA256.hash(data: data)))
        }
    }

    private static func hmacHexRaw(hashName: String, keyHex: String, dataHex: String) -> String {
        let key = SymmetricKey(data: dataFromHex(keyHex))
        let data = dataFromHex(dataHex)
        switch hashName.uppercased() {
        case "MD5": return hexFromData(Data(HMAC<Insecure.MD5>.authenticationCode(for: data, using: key)))
        case "SHA1": return hexFromData(Data(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: key)))
        case "SHA384": return hexFromData(Data(HMAC<SHA384>.authenticationCode(for: data, using: key)))
        case "SHA512": return hexFromData(Data(HMAC<SHA512>.authenticationCode(for: data, using: key)))
        default: return hexFromData(Data(HMAC<SHA256>.authenticationCode(for: data, using: key)))
        }
    }

    private static func pbkdf2Hex(passHex: String, saltHex: String, iterations: Int, keyBits: Int, hashName: String) throws -> String {
        let password = dataFromHex(passHex)
        let salt = dataFromHex(saltHex)
        let keyLength = max(1, keyBits / 8)
        guard keyLength <= maxDerivedKeyBytes else {
            throw NuvioPluginError.runtimeFailed(
                "PBKDF2 derives at most \(maxDerivedKeyBytes) bytes; \(keyLength) were requested."
            )
        }
        guard iterations <= maxDerivationIterations else {
            throw NuvioPluginError.runtimeFailed(
                "PBKDF2 runs at most \(maxDerivationIterations) iterations; \(iterations) were requested."
            )
        }
        let prf: CCPseudoRandomAlgorithm
        switch hashName.uppercased() {
        case "SHA1": prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
        case "SHA384": prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA384)
        case "SHA512": prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512)
        case "MD5": prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
        default: prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
        }
        var derived = [UInt8](repeating: 0, count: keyLength)
        let status = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.bindMemory(to: Int8.self).baseAddress, password.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    prf, UInt32(max(1, iterations)),
                    &derived, keyLength
                )
            }
        }
        guard Int(status) == kCCSuccess else {
            throw NuvioPluginError.runtimeFailed("PBKDF2 failed with status \(status).")
        }
        return hexFromData(Data(derived))
    }

    private static func randomHex(byteLength: Int) -> String {

        let count = max(0, min(byteLength, maxRandomValueBytes))
        guard count > 0 else { return "" }
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
        return hexFromData(Data(bytes))
    }

    private static func cipherHex(encrypt: Bool, algorithmMode: String, keyHex: String, ivHex: String, dataHex: String) throws -> String {
        let noPadding = algorithmMode.hasSuffix("-NoPadding")
        let base = noPadding ? String(algorithmMode.dropLast("-NoPadding".count)) : algorithmMode
        let parts = base.uppercased().split(separator: "-").map(String.init)
        let algo = parts.first ?? "AES"
        let mode = parts.count > 1 ? parts[parts.count - 1] : "CBC"

        let key = dataFromHex(keyHex)
        let iv = dataFromHex(ivHex)
        let input = dataFromHex(dataHex)

        if algo == "AES" && mode == "GCM" {
            return try aesGCMHex(encrypt: encrypt, key: key, iv: iv, input: input)
        }

        let algorithm = CCAlgorithm(algo == "DES3" || algo == "3DES" ? kCCAlgorithm3DES : kCCAlgorithmAES)
        let blockSize = (algo == "DES3" || algo == "3DES") ? kCCBlockSize3DES : kCCBlockSizeAES128
        var options: CCOptions = 0
        if !noPadding { options |= CCOptions(kCCOptionPKCS7Padding) }
        if mode == "ECB" { options |= CCOptions(kCCOptionECBMode) }

        guard let output = ccCrypt(
            operation: CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
            algorithm: algorithm,
            options: options,
            key: key,
            iv: mode == "ECB" ? Data() : iv,
            input: input,
            blockSize: blockSize
        ) else {
            throw NuvioPluginError.runtimeFailed(
                "\(algo)-\(mode) \(encrypt ? "encryption" : "decryption") failed. "
                    + "Check the key length (\(key.count) bytes) and IV length (\(iv.count) bytes)."
            )
        }
        return hexFromData(output)
    }

    private static func ccCrypt(operation: CCOperation, algorithm: CCAlgorithm, options: CCOptions, key: Data, iv: Data, input: Data, blockSize: Int) -> Data? {

        let keyCount = key.count
        let inputCount = input.count
        let ivIsEmpty = iv.isEmpty
        let outputCapacity = inputCount + blockSize
        var outMoved = 0
        var output = Data(count: outputCapacity)
        let status = output.withUnsafeMutableBytes { outBytes -> CCCryptorStatus in
            input.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            operation, algorithm, options,
                            keyBytes.baseAddress, keyCount,
                            ivIsEmpty ? nil : ivBytes.baseAddress,
                            inBytes.baseAddress, inputCount,
                            outBytes.baseAddress, outputCapacity,
                            &outMoved
                        )
                    }
                }
            }
        }
        guard status == CCCryptorStatus(kCCSuccess) else { return nil }
        return output.prefix(outMoved)
    }

    private static func aesGCMHex(encrypt: Bool, key: Data, iv: Data, input: Data) throws -> String {
        do {
            let symmetricKey = SymmetricKey(data: key)
            let nonce = try AES.GCM.Nonce(data: iv)
            if encrypt {
                let sealed = try AES.GCM.seal(input, using: symmetricKey, nonce: nonce)
                return hexFromData(sealed.ciphertext + sealed.tag)
            }
            guard input.count >= 16 else {
                throw NuvioPluginError.runtimeFailed(
                    "AES-GCM decryption needs the 16-byte authentication tag appended to the ciphertext."
                )
            }
            let tag = input.suffix(16)
            let ciphertext = input.prefix(input.count - 16)
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
            return hexFromData(try AES.GCM.open(box, using: symmetricKey))
        } catch let error as NuvioPluginError {
            throw error
        } catch {
            throw NuvioPluginError.runtimeFailed(
                "AES-GCM \(encrypt ? "encryption" : "decryption") failed: \(error.localizedDescription)"
            )
        }
    }

    private static func digestHex(algorithm: String, value: String) throws -> String {
        let data = Data(value.utf8)
        switch algorithm.uppercased() {
        case "MD5":
            return md5Hex(data)
        case "SHA1":
            return sha1Hex(data)
        case "SHA512":
            return hexFromData(Data(SHA512.hash(data: data)))
        case "HEX":

            return try boundedHexFromData(data)
        default:
            return hexFromData(Data(SHA256.hash(data: data)))
        }
    }

    private static func md5Hex(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_MD5(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return hexFromData(Data(hash))
    }

    private static func sha1Hex(_ data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA1(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return hexFromData(Data(hash))
    }

    private static func hmacHex(algorithm: String, value: String, key: String) -> String {
        let data = Data(value.utf8)
        let keyData = Data(key.utf8)
        let algorithmValue: CCHmacAlgorithm
        let length: Int
        switch algorithm.uppercased() {
        case "MD5":
            algorithmValue = CCHmacAlgorithm(kCCHmacAlgMD5)
            length = Int(CC_MD5_DIGEST_LENGTH)
        case "SHA1":
            algorithmValue = CCHmacAlgorithm(kCCHmacAlgSHA1)
            length = Int(CC_SHA1_DIGEST_LENGTH)
        case "SHA512":
            algorithmValue = CCHmacAlgorithm(kCCHmacAlgSHA512)
            length = Int(CC_SHA512_DIGEST_LENGTH)
        default:
            algorithmValue = CCHmacAlgorithm(kCCHmacAlgSHA256)
            length = Int(CC_SHA256_DIGEST_LENGTH)
        }

        var mac = [UInt8](repeating: 0, count: length)
        keyData.withUnsafeBytes { keyBytes in
            data.withUnsafeBytes { dataBytes in
                CCHmac(algorithmValue, keyBytes.baseAddress, keyData.count, dataBytes.baseAddress, data.count, &mac)
            }
        }
        return hexFromData(Data(mac))
    }
}

final class NuvioFetchTally: @unchecked Sendable {

    private static let sharedInfrastructureHosts: Set<String> = [
        "api.themoviedb.org",
        "image.tmdb.org",
        "graphql.anilist.co",
        "api.jikan.moe",
        "api.myanimelist.net",
        "kitsu.io",
        "raw.githubusercontent.com",
        "api.github.com"
    ]

    private let lock = NSLock()
    private var requests = 0
    private var ownSourceRequests = 0
    private var ownSourceFailures = 0
    private var statusCounts: [Int: Int] = [:]
    private var transportFailures = 0
    private var transportFailureCodes: [Int: Int] = [:]
    private var eclipseRefusalCounts: [String: Int] = [:]
    private var truncatedBodies = 0
    private var droppedRequestHeaders = 0

    func record(host: String?, failed: Bool) {
        let isShared = host.map { Self.sharedInfrastructureHosts.contains($0.lowercased()) } ?? false
        lock.lock()
        requests += 1
        if !isShared {
            ownSourceRequests += 1
            if failed { ownSourceFailures += 1 }
        }
        lock.unlock()
    }

    func recordStatus(_ status: Int) {
        lock.lock()
        statusCounts[status, default: 0] += 1
        lock.unlock()
    }

    func recordTransportFailure() {
        lock.lock()
        transportFailures += 1
        lock.unlock()
    }

    func recordTransportFailureCode(_ code: Int) {
        lock.lock()
        transportFailureCodes[code, default: 0] += 1
        lock.unlock()
    }

    func recordEclipseRefusal(_ reason: NuvioEclipseRefusal) {
        lock.lock()
        eclipseRefusalCounts[reason.token, default: 0] += 1
        lock.unlock()
    }

    func recordTruncatedBody() {
        lock.lock()
        truncatedBodies += 1
        lock.unlock()
    }

    func recordDroppedRequestHeaders(_ count: Int) {
        guard count > 0 else { return }
        lock.lock()
        droppedRequestHeaders += count
        lock.unlock()
    }

    var snapshot: (requests: Int, ownSourceRequests: Int, ownSourceFailures: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (requests, ownSourceRequests, ownSourceFailures)
    }

    var interference: NuvioEclipseInterference {
        lock.lock()
        defer { lock.unlock() }
        return NuvioEclipseInterference(
            refusalsByReason: eclipseRefusalCounts,
            truncatedBodies: truncatedBodies,
            droppedRequestHeaders: droppedRequestHeaders
        )
    }

    var ledgerDescription: String {
        lock.lock()
        let statuses = statusCounts
        let transport = transportFailures
        let transportCodes = transportFailureCodes
        let refusals = eclipseRefusalCounts
        let truncated = truncatedBodies
        let dropped = droppedRequestHeaders
        let total = requests
        let own = ownSourceRequests
        lock.unlock()

        let statusText = statuses.isEmpty
            ? "none"
            : statuses.sorted { $0.key < $1.key }.map { "\($0.key)x\($0.value)" }.joined(separator: ",")
        let refusalText = refusals.isEmpty
            ? "none"
            : refusals.sorted { $0.key < $1.key }.map { "\($0.key)x\($0.value)" }.joined(separator: ",")
        let transportText = transportCodes.isEmpty
            ? "none"
            : transportCodes.sorted { $0.key < $1.key }.map { "\($0.key)x\($0.value)" }.joined(separator: ",")
        return "fetches=\(total) ownSource=\(own) status=[\(statusText)] transportFailures=\(transport) "
            + "transportErrors=[\(transportText)] "
            + "eclipseRefused=[\(refusalText)] truncatedBodies=\(truncated) droppedHeaders=\(dropped)"
    }
}

enum NuvioEclipseRefusal {
    case invalidRequestURL
    case concurrencyCap
    case responseTooLarge
    case nodeBudget
    case addressPolicy
    case trackingSandbox

    var token: String {
        switch self {
        case .invalidRequestURL: return "invalid-url"
        case .concurrencyCap: return "request-cap"
        case .responseTooLarge: return "response-too-large"
        case .nodeBudget: return "node-budget"
        case .addressPolicy: return "address-policy"
        case .trackingSandbox: return "tracking-sandbox"
        }
    }

    static let scrapingBlockingTokens: Set<String> = [
        concurrencyCap.token,
        responseTooLarge.token,
        nodeBudget.token,
        addressPolicy.token,
        trackingSandbox.token
    ]
}

private struct NuvioEclipseRefusalRejection: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct NuvioEclipseInterference {
    static let none = NuvioEclipseInterference(
        refusalsByReason: [:],
        truncatedBodies: 0,
        droppedRequestHeaders: 0
    )

    let refusalsByReason: [String: Int]
    let truncatedBodies: Int
    let droppedRequestHeaders: Int

    var refusalCount: Int { refusalsByReason.values.reduce(0, +) }

    var isEmpty: Bool {
        refusalCount == 0 && truncatedBodies == 0 && droppedRequestHeaders == 0
    }

    private var blockingRefusals: [String: Int] {
        refusalsByReason.filter { NuvioEclipseRefusal.scrapingBlockingTokens.contains($0.key) }
    }

    var blocksScraping: Bool {
        !blockingRefusals.isEmpty || truncatedBodies > 0 || droppedRequestHeaders > 0
    }

    var blockingSummary: String {
        Self.describe(
            refusals: blockingRefusals,
            truncatedBodies: truncatedBodies,
            droppedRequestHeaders: droppedRequestHeaders
        )
    }

    var summary: String {
        Self.describe(
            refusals: refusalsByReason,
            truncatedBodies: truncatedBodies,
            droppedRequestHeaders: droppedRequestHeaders
        )
    }

    private static func describe(
        refusals: [String: Int],
        truncatedBodies: Int,
        droppedRequestHeaders: Int
    ) -> String {
        var parts: [String] = []
        if !refusals.isEmpty {
            let detail = refusals
                .sorted { $0.key < $1.key }
                .map { "\($0.key)x\($0.value)" }
                .joined(separator: ",")
            parts.append("refused=[\(detail)]")
        }
        if truncatedBodies > 0 { parts.append("truncatedBodies=\(truncatedBodies)") }
        if droppedRequestHeaders > 0 { parts.append("droppedHeaders=\(droppedRequestHeaders)") }
        return parts.joined(separator: " ")
    }
}

private struct NuvioProviderFetchSessionKey: Hashable {
    let scopeToken: String
    let scraperID: String
    let configurationFingerprint: String
}

private final class NuvioProviderFetchSessionRegistry: @unchecked Sendable {
    static let shared = NuvioProviderFetchSessionRegistry()

    private struct Entry {
        let session: NuvioProviderFetchSession
        var accessOrder: UInt64
    }

    private let lock = NSLock()
    private let maximumSessions = 128
    private var entries: [NuvioProviderFetchSessionKey: Entry] = [:]
    private var nextAccessOrder: UInt64 = 0
    private var scopeObserver: NSObjectProtocol?

    private init() {
        scopeObserver = NotificationCenter.default.addObserver(
            forName: ServiceStoreScope.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.clearAll()
        }
    }

    deinit {
        if let scopeObserver {
            NotificationCenter.default.removeObserver(scopeObserver)
        }
    }

    func session(
        profileID: UUID,
        sharesServices: Bool,
        scraperID: String,
        configurationFingerprint: String
    ) -> NuvioProviderFetchSession {
        let scopeToken = sharesServices
            ? "shared"
            : ProfileScopedStorage.token(for: profileID)
        let key = NuvioProviderFetchSessionKey(
            scopeToken: scopeToken,
            scraperID: scraperID,
            configurationFingerprint: configurationFingerprint
        )
        var retired: [NuvioProviderFetchSession] = []

        lock.lock()
        nextAccessOrder &+= 1
        if var existing = entries[key] {
            existing.accessOrder = nextAccessOrder
            entries[key] = existing
            lock.unlock()
            return existing.session
        }

        let obsoleteKeys = entries.keys.filter {
            $0.scopeToken == scopeToken
                && $0.scraperID == scraperID
                && $0 != key
        }
        for candidate in obsoleteKeys {
            if let removed = entries.removeValue(forKey: candidate) {
                retired.append(removed.session)
            }
        }

        let created = NuvioProviderFetchSession()
        entries[key] = Entry(session: created, accessOrder: nextAccessOrder)
        while entries.count > maximumSessions,
              let oldest = entries.min(by: {
                  $0.value.accessOrder < $1.value.accessOrder
              })?.key,
              let removed = entries.removeValue(forKey: oldest) {
            retired.append(removed.session)
        }
        lock.unlock()

        retired.forEach { $0.retire() }
        return created
    }

    private func clearAll() {
        lock.lock()
        let retired = entries.values.map(\.session)
        entries.removeAll(keepingCapacity: true)
        lock.unlock()
        retired.forEach { $0.retire() }
    }
}

private final class NuvioProviderFetchSession: @unchecked Sendable {
    private static let authorizeRedirect: FetchDelegate.RedirectAuthorization = { source, destination in
        _ = try await SkyStreamRemoteURLPolicy.shared.validateRedirectForNetworkDispatch(
            from: source,
            to: destination,
            purpose: .nuvioRequest
        )
    }

    private let lock = NSLock()
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        return URLSession(
            configuration: configuration,
            delegate: FetchDelegate(
                allowRedirects: true,
                redirectAuthorization: NuvioProviderFetchSession.authorizeRedirect
            ),
            delegateQueue: nil
        )
    }()
    private var isRetired = false
    private var borrowCount = 0

    func withSession<Value>(
        _ body: (URLSession) async throws -> Value
    ) async throws -> Value {
        guard borrow() else {
            throw NuvioPluginError.runtimeFailed("Plugin network request issued after the run ended.")
        }
        defer { giveBack() }
        return try await body(session)
    }

    func retire() {
        lock.lock()
        guard !isRetired else {
            lock.unlock()
            return
        }
        isRetired = true
        let shouldClear = retireIfIdleLocked()
        lock.unlock()
        if shouldClear { session.finishTasksAndInvalidate() }
    }

    private func borrow() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isRetired else { return false }
        borrowCount += 1
        return true
    }

    private func giveBack() {
        lock.lock()
        borrowCount -= 1
        let shouldClear = retireIfIdleLocked()
        lock.unlock()
        if shouldClear { session.finishTasksAndInvalidate() }
    }

    private func retireIfIdleLocked() -> Bool {
        isRetired && borrowCount == 0
    }
}

private final class NuvioNativeRequestLimiter: @unchecked Sendable {
    enum Admission {
        case admitted(UInt64)
        case refused(String)
    }

    private let maximumConcurrent: Int
    private let maximumPerRun: Int

    private let lock = NSLock()
    private var nextID: UInt64 = 0
    private var admittedCount = 0
    private var activeCount = 0
    private var tasks: [UInt64: Task<Void, Never>] = [:]
    private var waiters: [(id: UInt64, continuation: CheckedContinuation<Bool, Never>)] = []
    private var isTornDown = false

    init(maximumConcurrent: Int, maximumPerRun: Int) {
        self.maximumConcurrent = max(1, maximumConcurrent)
        self.maximumPerRun = max(1, maximumPerRun)
    }

    func admit() -> Admission {
        lock.lock()
        defer { lock.unlock() }
        guard !isTornDown else {
            return .refused("The plugin run has already finished.")
        }
        guard admittedCount < maximumPerRun else {
            return .refused("This plugin used its budget of \(maximumPerRun) network requests for one lookup.")
        }
        admittedCount += 1
        let id = nextID
        nextID &+= 1
        return .admitted(id)
    }

    func register(_ id: UInt64, task: Task<Void, Never>) {
        lock.lock()
        guard !isTornDown else {
            lock.unlock()
            task.cancel()
            return
        }
        tasks[id] = task
        lock.unlock()
    }

    func acquireSlot(id: UInt64) async -> Bool {
        lock.lock()
        if isTornDown {
            lock.unlock()
            return false
        }
        if activeCount < maximumConcurrent {
            activeCount += 1
            lock.unlock()
            return true
        }
        lock.unlock()

        return await withCheckedContinuation { continuation in
            lock.lock()
            if isTornDown {
                lock.unlock()
                continuation.resume(returning: false)
            } else if activeCount < maximumConcurrent {
                activeCount += 1
                lock.unlock()
                continuation.resume(returning: true)
            } else {
                waiters.append((id: id, continuation: continuation))
                lock.unlock()
            }
        }
    }

    func release(id: UInt64, heldSlot: Bool) {
        lock.lock()
        tasks.removeValue(forKey: id)
        guard heldSlot else {
            lock.unlock()
            return
        }
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            lock.unlock()

            waiter.continuation.resume(returning: true)
            return
        }
        activeCount -= 1
        lock.unlock()
    }

    func tearDown() {
        lock.lock()
        guard !isTornDown else {
            lock.unlock()
            return
        }
        isTornDown = true
        let outstanding = Array(tasks.values)
        let stranded = waiters
        tasks.removeAll()
        waiters.removeAll()
        lock.unlock()

        for waiter in stranded { waiter.continuation.resume(returning: false) }
        for task in outstanding { task.cancel() }
    }
}

private final class NuvioRuntimeExceptionTrap {
    private var isCapturing = false
    private var captured: String?

    func beginCapture() {
        isCapturing = true
        captured = nil
    }

    func endCapture() -> String? {
        isCapturing = false
        let message = captured
        captured = nil
        return message
    }

    func record(_ message: String) {
        guard isCapturing, captured == nil else { return }
        captured = message
    }
}

private final class NuvioPluginRuntimeCompletion<Value>: @unchecked Sendable {
    var context: JSContext?
    var timeout: DispatchWorkItem?

    let queue: DispatchQueue
    private let continuation: CheckedContinuation<Value, Error>
    private let lock = NSLock()
    private var completed = false
    private var deferredFailureMessage: String?
    private var expiredByWatchdog = false

    private var didBeginExecution = false

    var onSettled: ((_ settledNormally: Bool) -> Void)?

    func markExecutionBegan() {
        lock.lock()
        didBeginExecution = true
        lock.unlock()
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    init(continuation: CheckedContinuation<Value, Error>, queue: DispatchQueue) {
        self.continuation = continuation
        self.queue = queue
    }

    func succeed(_ value: Value) {
        finish {
            continuation.resume(returning: value)
        }
    }

    func fail(_ error: Error) {
        finish {
            continuation.resume(throwing: error)
        }
    }

    func recordDeferredFailure(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        guard deferredFailureMessage == nil else { return }
        deferredFailureMessage = message
    }

    func failExpired() {
        lock.lock()
        let message = deferredFailureMessage
        expiredByWatchdog = true
        lock.unlock()
        if let message {
            fail(NuvioPluginError.runtimeFailed(message))
        } else {
            fail(NuvioPluginError.runtimeTimeout)
        }
    }

    private func finish(_ resume: () -> Void) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        let timeout = timeout
        self.timeout = nil
        let releasedContext = context
        context = nil

        let settledNormally = !expiredByWatchdog || !didBeginExecution
        let settleHandler = onSettled
        onSettled = nil
        lock.unlock()
        timeout?.cancel()
        settleHandler?(settledNormally)

        if let releasedContext {
            queue.async {

                releasedContext.exceptionHandler = nil
                releasedContext.exception = nil
                withExtendedLifetime(releasedContext) {}
            }
        }
        resume()
    }
}

private final class NuvioExecutionPermits: @unchecked Sendable {

    fileprivate static let burnRecoveryInterval: TimeInterval = 180

    private let lock = NSLock()
    private let capacity: Int
    private var available: Int
    private var burned = 0
    private var lastBurnAt = Date.distantPast
    private var recoveriesGranted = 0

    private struct Waiter {
        let id: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var waiters: [Waiter] = []
    private var nextWaiterID: UInt64 = 0

    init(capacity: Int) {
        self.capacity = capacity
        self.available = capacity
    }

    func acquire() async -> Bool {
        if recoverOneBurnedPermitIfStalled() {
            Logger.shared.log(
                "Nuvio runtime returned one burned execution permit after "
                    + "\(Int(NuvioExecutionPermits.burnRecoveryInterval))s, so plugins can run again "
                    + "without a relaunch. Providers whose JavaScript never returned are still parked.",
                type: "Plugin"
            )
        }
        lock.lock()
        if burned >= capacity {
            lock.unlock()
            return false
        }
        if available > 0 {
            available -= 1
            lock.unlock()
            return true
        }
        let id = nextWaiterID
        nextWaiterID += 1
        lock.unlock()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if burned >= capacity {
                    lock.unlock()
                    continuation.resume(returning: false)
                } else if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(returning: false)
                } else if available > 0 {
                    available -= 1
                    lock.unlock()
                    continuation.resume(returning: true)
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            guard let index = waiters.firstIndex(where: { $0.id == id }) else {
                lock.unlock()
                return
            }
            let withdrawn = waiters.remove(at: index)
            lock.unlock()

            withdrawn.continuation.resume(returning: false)
        }
    }

    func release() {
        lock.lock()
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            lock.unlock()

            waiter.continuation.resume(returning: true)
            return
        }
        available = min(available + 1, capacity - burned)
        lock.unlock()
    }

    func burn() -> Int {
        lock.lock()
        burned = min(burned + 1, capacity)
        available = min(available, capacity - burned)
        lastBurnAt = Date()
        let remaining = capacity - burned

        let stranded = burned >= capacity ? waiters : []
        if burned >= capacity { waiters.removeAll() }
        lock.unlock()
        for waiter in stranded { waiter.continuation.resume(returning: false) }
        return remaining
    }

    func restoreBurnedPermit() {
        lock.lock()
        burned = max(burned - 1, 0)
        lock.unlock()
        release()
    }

    private func recoverOneBurnedPermitIfStalled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard burned >= capacity,
              recoveriesGranted < capacity,
              Date().timeIntervalSince(lastBurnAt) >= NuvioExecutionPermits.burnRecoveryInterval else {
            return false
        }
        recoveriesGranted += 1
        burned -= 1
        available = min(available + 1, capacity - burned)
        return true
    }
}

private final class NuvioQueueDrainProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    private var drained = false

    func markDrained() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        drained = true
        return expired
    }

    func markExpired() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !drained else { return false }
        expired = true
        return true
    }
}

private final class NuvioCheerioBridge {

    private static let maximumLiveDocuments = 32

    private static let maximumDocumentSourceBytes = 6 * 1024 * 1024

    private static let parsedDocumentSizeMultiplier = 8
    private static let maximumLiveDocumentBytes = 48 * 1024 * 1024
    private static let maximumLiveElements = 100_000

    private let tally: NuvioFetchTally?

    init(tally: NuvioFetchTally? = nil) {
        self.tally = tally
    }

    private var nextHandle = 1
    private var documents: [Int: Document] = [:]
    private var documentOrder: [Int] = []
    private var documentBytes: [Int: Int] = [:]
    private var liveDocumentBytes = 0
    private var elements: [Int: Element] = [:]
    private var elementOwners: [Int: Int] = [:]

    private var oldestElementHandle = 1

    func load(_ html: String) throws -> Int {
        let sourceBytes = html.utf8.count
        guard sourceBytes <= NuvioCheerioBridge.maximumDocumentSourceBytes else {
            tally?.recordEclipseRefusal(.nodeBudget)
            throw NuvioPluginError.runtimeLimitExceeded(
                "cheerio.load was given \(sourceBytes) bytes of HTML; Eclipse parses at most "
                    + "\(NuvioCheerioBridge.maximumDocumentSourceBytes) bytes in one document."
            )
        }

        let document = (try? SwiftSoup.parse(html)) ?? Document("")
        let handle = allocate()
        let estimatedBytes = sourceBytes * NuvioCheerioBridge.parsedDocumentSizeMultiplier
        documents[handle] = document
        documentOrder.append(handle)
        documentBytes[handle] = estimatedBytes
        liveDocumentBytes += estimatedBytes
        evictDocumentsBeyondCap()
        return handle
    }

    func select(handle: Int, selector: String) throws -> [Int] {
        let normalized = NuvioCheerioBridge.normalizeSelector(selector)
        do {
            if let document = documents[handle] {
                return try document.select(normalized).array().map { register($0, ownedBy: handle) }
            }
            if let element = elements[handle] {
                let documentHandle = owner(of: handle)
                return try element.select(normalized).array().map { register($0, ownedBy: documentHandle) }
            }
        } catch {
            Logger.shared.log("Nuvio cheerio selector failed selector=\(selector) error=\(error.localizedDescription)", type: "Plugin")
            return []
        }
        try requireLiveHandle(handle)
        return []
    }

    private static let containsRegex = try? NSRegularExpression(pattern: ":contains\\((\"|')(.*?)\\1\\)")

    private static func normalizeSelector(_ selector: String) -> String {
        guard let regex = containsRegex, selector.contains(":contains(") else { return selector }
        let range = NSRange(selector.startIndex..., in: selector)
        return regex.stringByReplacingMatches(in: selector, options: [], range: range, withTemplate: ":contains($2)")
    }

    func text(handle: Int) throws -> String {
        if let document = documents[handle] { return (try? document.text()) ?? "" }
        if let element = elements[handle] { return (try? element.text()) ?? "" }
        try requireLiveHandle(handle)
        return ""
    }

    func html(handle: Int) throws -> String {
        if let document = documents[handle] { return (try? document.outerHtml()) ?? "" }
        if let element = elements[handle] { return (try? element.outerHtml()) ?? "" }
        try requireLiveHandle(handle)
        return ""
    }

    func innerHTML(handle: Int) throws -> String {
        if let document = documents[handle] { return (try? document.html()) ?? "" }
        if let element = elements[handle] { return (try? element.html()) ?? "" }
        try requireLiveHandle(handle)
        return ""
    }

    func attr(handle: Int, name: String) throws -> String? {
        guard let element = elements[handle] else {
            try requireLiveHandle(handle)
            return nil
        }
        return try? element.attr(name)
    }

    func next(handle: Int) throws -> Int? {
        guard let element = elements[handle] else {
            try requireLiveHandle(handle)
            return nil
        }
        guard let sibling = try? element.nextElementSibling() else { return nil }
        return register(sibling, ownedBy: owner(of: handle))
    }

    func previous(handle: Int) throws -> Int? {
        guard let element = elements[handle] else {
            try requireLiveHandle(handle)
            return nil
        }
        guard let sibling = try? element.previousElementSibling() else { return nil }
        return register(sibling, ownedBy: owner(of: handle))
    }

    func children(handle: Int) throws -> [Int] {
        if let document = documents[handle] {
            return document.children().array().map { register($0, ownedBy: handle) }
        }
        if let element = elements[handle] {
            let documentHandle = owner(of: handle)
            return element.children().array().map { register($0, ownedBy: documentHandle) }
        }
        try requireLiveHandle(handle)
        return []
    }

    func parent(handle: Int) throws -> Int? {
        guard let element = elements[handle] else {
            try requireLiveHandle(handle)
            return nil
        }
        guard let parent = element.parent() else { return nil }
        return register(parent, ownedBy: owner(of: handle))
    }

    func matches(handle: Int, selector: String) throws -> Bool {
        let normalized = NuvioCheerioBridge.normalizeSelector(selector)
        guard let element = elements[handle] else {
            try requireLiveHandle(handle)
            return false
        }
        return (try? element.iS(normalized)) ?? false
    }

    private func requireLiveHandle(_ handle: Int) throws {
        guard handle > 0, handle < nextHandle,
              documents[handle] == nil, elements[handle] == nil else {
            return
        }
        tally?.recordEclipseRefusal(.nodeBudget)
        throw NuvioPluginError.runtimeLimitExceeded(
            "This cheerio node is no longer available: Eclipse keeps at most "
                + "\(NuvioCheerioBridge.maximumLiveDocuments) loaded documents and "
                + "\(NuvioCheerioBridge.maximumLiveElements) selected nodes per run."
        )
    }

    private func owner(of handle: Int) -> Int {
        elementOwners[handle] ?? handle
    }

    private func register(_ element: Element, ownedBy documentHandle: Int) -> Int {
        let handle = allocate()
        elements[handle] = element
        elementOwners[handle] = documentHandle
        evictElementsBeyondCap()
        return handle
    }

    private func evictElementsBeyondCap() {
        while elements.count > NuvioCheerioBridge.maximumLiveElements {
            guard evictOldestElement() else { return }
        }
    }

    private func evictOldestElement() -> Bool {
        while oldestElementHandle < nextHandle {
            let handle = oldestElementHandle
            oldestElementHandle += 1
            guard elements.removeValue(forKey: handle) != nil else { continue }
            elementOwners.removeValue(forKey: handle)
            return true
        }
        return false
    }

    private func evictDocumentsBeyondCap() {
        while documentOrder.count > 1,
              documentOrder.count > NuvioCheerioBridge.maximumLiveDocuments
                  || liveDocumentBytes > NuvioCheerioBridge.maximumLiveDocumentBytes {
            evictOldestDocument()
        }
    }

    private func evictOldestDocument() {
        guard !documentOrder.isEmpty else { return }
        let handle = documentOrder.removeFirst()
        documents.removeValue(forKey: handle)
        liveDocumentBytes -= documentBytes.removeValue(forKey: handle) ?? 0
        for elementHandle in elementOwners.filter({ $0.value == handle }).keys {
            elements.removeValue(forKey: elementHandle)
            elementOwners.removeValue(forKey: elementHandle)
        }
    }

    private func allocate() -> Int {
        defer { nextHandle += 1 }
        return nextHandle
    }
}

private extension ComparisonResult {
    var isSame: Bool { self == .orderedSame }
}
