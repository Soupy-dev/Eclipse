//
//  JSLoader-Streams.swift
//  Sora
//
//  Created by Francesco on 07/08/25.
//

import JavaScriptCore

final class ServiceStreamHeaderSanitizerLedger: @unchecked Sendable {
    static let shared = ServiceStreamHeaderSanitizerLedger()

    private let lock = NSLock()
    private var entries: [String: [String]] = [:]
    private var order: [String] = []
    private let maximumEntries = 4_096

    static func isMeasurable(_ streamURL: String) -> Bool {
        !streamURL.isEmpty && streamURL.utf8.count <= 2_048
    }

    func record(droppedKeys: [String], for streamURL: String) {
        guard Self.isMeasurable(streamURL) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !droppedKeys.isEmpty else {
            if entries.removeValue(forKey: streamURL) != nil {
                order.removeAll { $0 == streamURL }
            }
            return
        }
        if entries[streamURL] == nil {
            order.append(streamURL)
            while order.count > maximumEntries, let oldest = order.first {
                order.removeFirst()
                entries.removeValue(forKey: oldest)
            }
        }
        entries[streamURL] = droppedKeys
    }

    func droppedKeys(for streamURL: String) -> [String]? {
        guard Self.isMeasurable(streamURL) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return entries[streamURL] ?? []
    }
}

enum ServiceStreamResultBoundaryError: Error {
    case invalidPayload
}

typealias ServiceStreamExtractionResult = (
    streams: [String]?,
    subtitles: [String]?,
    sources: [[String: Any]]?
)

extension JSController {
    private static let streamExtractionTimeoutNanoseconds: UInt64 = 20_000_000_000
    private static let maximumStreamResultBytes = 4 * 1_024 * 1_024
    private static let maximumStreamEntries = 1_200
    private static let maximumSubtitleEntries = 256

    static func boundedStreamExtractionResult(from data: Data) throws -> ServiceStreamExtractionResult {
        guard !data.isEmpty else {
            throw ServiceStreamResultBoundaryError.invalidPayload
        }
        guard data.count <= maximumStreamResultBytes else {
            Logger.shared.log(
                "Service stream result refused by Eclipse bytes=\(data.count) cap=maximumStreamResultBytes=\(maximumStreamResultBytes); the whole stream list is discarded, so an empty result here is an Eclipse limit, not a dead source",
                type: "Plugin"
            )
            throw ServiceStreamResultBoundaryError.invalidPayload
        }
        do {
            try SkyStreamJSONEnvelopeValidator.validate(
                data,
                limits: .init(
                    maximumDepth: 12,
                    maximumTokens: 400_000,
                    maximumValuesPerContainer: 20_000,
                    maximumStringBytes: 1_024 * 1_024,
                    maximumScalarTokenBytes: 128
                )
            )
        } catch {
            Logger.shared.log(
                "Service stream envelope refused by Eclipse bytes=\(data.count) caps=depth12/tokens400000/values20000/string1MiB; the whole stream list is discarded, so an empty result here is an Eclipse limit, not a dead source",
                type: "Plugin"
            )
            throw error
        }
        let value = try JSONSerialization.jsonObject(with: data)
        if let object = value as? [String: Any] {
            let envelope = boundedServiceHeaders(object["headers"])
            let envelopeHeaders = envelope.headers
            let envelopeSubtitleHeaders = boundedServiceHeaders(object["subtitleHeaders"]).headers
            let carriesEnvelopeHeaders = envelopeHeaders != nil || envelopeSubtitleHeaders != nil
            let sources: [[String: Any]]? = {
                if let values = object["streams"] as? [[String: Any]] {
                    let bounded = boundedServiceObjects(
                        values,
                        limit: maximumStreamEntries,
                        label: "stream",
                        transform: boundedStreamSource
                    )
                    return bounded.isEmpty ? nil : bounded
                }
                if let value = object["stream"] as? [String: Any],
                   let bounded = boundedStreamSource(value) {
                    return [bounded]
                }
                guard carriesEnvelopeHeaders else { return nil }
                if let values = object["streams"] as? [String] {
                    let bounded = pairedStreamSources(
                        boundedServiceStrings(values, limit: maximumStreamEntries, maximumBytes: 64 * 1_024, label: "stream")
                    )
                    return bounded.isEmpty ? nil : bounded
                }
                if let value = object["stream"] as? String,
                   let bounded = boundedServiceString(value, maximumBytes: 64 * 1_024, field: "stream") {
                    return [["streamUrl": bounded]]
                }
                return nil
            }()
            let offsetsLackingOwnHeaders = Set(
                (sources ?? []).enumerated().compactMap { $0.element["headers"] == nil ? $0.offset : nil }
            )
            var decoratedSources: [[String: Any]]? = sources
            if carriesEnvelopeHeaders, let values = sources {
                decoratedSources = values.map { source -> [String: Any] in
                    var decorated = source
                    if decorated["headers"] == nil, let envelopeHeaders {
                        decorated["headers"] = envelopeHeaders
                    }
                    if decorated["subtitleHeaders"] == nil, let envelopeSubtitleHeaders {
                        decorated["subtitleHeaders"] = envelopeSubtitleHeaders
                    }
                    return decorated
                }
            }
            let streams: [String]? = {
                if sources != nil { return nil }
                if let values = object["streams"] as? [String] {
                    let bounded = boundedServiceStrings(values, limit: maximumStreamEntries, maximumBytes: 64 * 1_024, label: "stream")
                    return bounded.isEmpty ? nil : bounded
                }
                if let value = object["stream"] as? String,
                   let bounded = boundedServiceString(value, maximumBytes: 64 * 1_024, field: "stream") {
                    return [bounded]
                }
                return nil
            }()
            if !envelope.droppedKeys.isEmpty {
                let envelopeURLKeys = ["streamUrl", "url", "file", "src", "link", "stream"]
                var envelopeTargets: [String] = []
                for (offset, source) in (decoratedSources ?? []).enumerated() {
                    guard offsetsLackingOwnHeaders.contains(offset) else { continue }
                    for key in envelopeURLKeys {
                        if let text = source[key] as? String {
                            envelopeTargets.append(text)
                            break
                        }
                    }
                }
                envelopeTargets.append(contentsOf: streams ?? [])
                for target in envelopeTargets {
                    let merged = Set(
                        ServiceStreamHeaderSanitizerLedger.shared.droppedKeys(for: target) ?? []
                    ).union(envelope.droppedKeys)
                    ServiceStreamHeaderSanitizerLedger.shared.record(
                        droppedKeys: merged.sorted(),
                        for: target
                    )
                }
            }
            let subtitles: [String]? = {
                if let values = object["subtitles"] as? [String] {
                    let bounded = boundedServiceStrings(values, limit: maximumSubtitleEntries, maximumBytes: 64 * 1_024, label: "subtitle")
                    return bounded.isEmpty ? nil : bounded
                }
                if let value = object["subtitles"] as? String,
                   let bounded = boundedServiceString(value, maximumBytes: 64 * 1_024, field: "subtitles") {
                    return [bounded]
                }
                if let values = object["subtitles"] as? [[String: Any]] {
                    let bounded = boundedSubtitleSources(values).compactMap { source in
                        ["url", "file", "src"].compactMap { source[$0] as? String }.first
                    }
                    return bounded.isEmpty ? nil : bounded
                }
                return nil
            }()
            return (streams, subtitles, decoratedSources)
        }
        if let values = value as? [String] {
            let bounded = boundedServiceStrings(values, limit: maximumStreamEntries, maximumBytes: 64 * 1_024, label: "stream")
            guard !bounded.isEmpty else { throw ServiceStreamResultBoundaryError.invalidPayload }
            return (bounded, nil, nil)
        }
        throw ServiceStreamResultBoundaryError.invalidPayload
    }

    private static func boundedStreamSource(_ source: [String: Any]) -> [String: Any]? {
        let urlKeys = ["streamUrl", "url", "file", "src", "link", "stream", "subtitle"]
        let metadataKeys = [
            "title", "name", "label", "quality", "provider", "type", "filename", "streamName", "server",
            "source", "codec", "video", "audio", "audioTrack", "lang", "language", "languageCode", "langCode",
            "locale", "audioLang", "audioLanguage", "dub", "dubLang", "dubLanguage"
        ]
        let metadataArrayKeys = [
            "languages", "languageCodes", "langCodes", "locales", "audioLangs", "audioLanguages", "audioTracks",
            "dubLanguages"
        ]
        var bounded: [String: Any] = [:]
        for key in urlKeys {
            if let value = source[key] as? String,
               let value = boundedServiceString(value, maximumBytes: 64 * 1_024, field: key) {
                bounded[key] = value
            }
        }
        for key in metadataKeys {
            if let value = source[key] as? String,
               let value = boundedServiceString(value, maximumBytes: 2 * 1_024, field: key) {
                bounded[key] = value
            } else if let value = source[key] as? NSNumber {
                bounded[key] = String(value.stringValue.prefix(128))
            }
        }
        for key in metadataArrayKeys {
            if let values = source[key] as? [String] {
                bounded[key] = boundedServiceStrings(values, limit: 32, maximumBytes: 2 * 1_024, label: "language")
            }
        }
        let sanitizedHeaders = boundedServiceHeaders(source["headers"])
        if let headers = sanitizedHeaders.headers {
            bounded["headers"] = headers
        }
        let sanitizedSubtitleHeaders = boundedServiceHeaders(source["subtitleHeaders"])
        if let headers = sanitizedSubtitleHeaders.headers {
            bounded["subtitleHeaders"] = headers
        }
        let sanitizerDrops = Array(Set(sanitizedHeaders.droppedKeys)).sorted()
        if let values = source["subtitles"] as? [String] {
            bounded["subtitles"] = boundedServiceStrings(
                values,
                limit: maximumSubtitleEntries,
                maximumBytes: 64 * 1_024,
                label: "subtitle"
            )
        } else if let values = source["subtitles"] as? [[String: Any]] {
            bounded["subtitles"] = boundedSubtitleSources(values)
        } else if let value = source["subtitles"] as? String,
                  !value.isEmpty,
                  value.utf8.count <= 16 * 1_024 {
            bounded["subtitles"] = value
        }
        for key in ["allSubtitles", "subtitleTracks"] {
            if let values = source[key] as? [[String: Any]] {
                bounded[key] = boundedSubtitleSources(values)
            }
        }
        let hasStreamURL = urlKeys.dropLast().contains { bounded[$0] is String }
        if hasStreamURL {
            for key in urlKeys.dropLast() {
                if let streamURL = bounded[key] as? String {
                    ServiceStreamHeaderSanitizerLedger.shared.record(
                        droppedKeys: sanitizerDrops,
                        for: streamURL
                    )
                    break
                }
            }
        }
        return hasStreamURL ? bounded : nil
    }

    private static func pairedStreamSources(_ values: [String]) -> [[String: Any]] {
        func isHTTPStream(_ value: String) -> Bool {
            let lowercased = value.lowercased()
            return lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://")
        }

        var sources: [[String: Any]] = []
        var index = 0
        while index < values.count, sources.count < maximumStreamEntries {
            let entry = values[index]
            if isHTTPStream(entry) {
                sources.append(["streamUrl": entry])
                index += 1
            } else if index + 1 < values.count, isHTTPStream(values[index + 1]) {
                var source: [String: Any] = ["streamUrl": values[index + 1]]
                if let title = boundedServiceString(entry, maximumBytes: 2 * 1_024, field: "title") {
                    source["title"] = title
                }
                sources.append(source)
                index += 2
            } else {
                index += 1
            }
        }
        return sources
    }

    private static func boundedSubtitleSources(
        _ sources: [[String: Any]]
    ) -> [[String: Any]] {
        var bounded: [[String: Any]] = []
        bounded.reserveCapacity(min(sources.count, maximumSubtitleEntries))
        for source in sources {
            guard let subtitle = boundedSubtitleSource(source) else { continue }
            bounded.append(subtitle)
            if bounded.count == maximumSubtitleEntries { break }
        }
        return bounded
    }

    private static func boundedSubtitleSource(_ source: [String: Any]) -> [String: Any]? {
        var bounded: [String: Any] = [:]
        for key in ["url", "file", "src"] {
            if let value = source[key] as? String,
               let value = boundedServiceString(value, maximumBytes: 64 * 1_024, field: key) {
                bounded[key] = value
            }
        }
        for key in ["title", "name", "label", "lang", "language"] {
            if let value = source[key] as? String,
               let value = boundedServiceString(value, maximumBytes: 2 * 1_024, field: key) {
                bounded[key] = value
            }
        }
        if let headers = boundedServiceHeaders(source["headers"]).headers {
            bounded["headers"] = headers
        }
        return ["url", "file", "src"].contains { bounded[$0] is String } ? bounded : nil
    }

    private static func boundedServiceHeaders(
        _ value: Any?
    ) -> (headers: [String: String]?, droppedKeys: [String]) {
        let raw: [String: String]
        var droppedKeys: [String] = []
        if let value = value as? [String: String] {
            raw = value
        } else if let value = value as? [String: Any] {
            raw = value.reduce(into: [:]) { result, pair in
                if let string = pair.value as? String { result[pair.key] = string }
                else if let number = pair.value as? NSNumber { result[pair.key] = number.stringValue }
            }
        } else {
            return (nil, [])
        }
        var bounded: [String: String] = [:]
        var totalBytes = 0
        for (name, value) in raw.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            guard bounded.count < 64,
                  !name.isEmpty,
                  name.utf8.count <= 128,
                  value.utf8.count <= 8 * 1_024,
                  !name.contains(":"),
                  !name.contains("\r"),
                  !name.contains("\n"),
                  !value.contains("\r"),
                  !value.contains("\n") else {
                let isEclipseCap = !name.isEmpty
                    && !name.contains(":")
                    && !name.contains("\r")
                    && !name.contains("\n")
                    && !value.contains("\r")
                    && !value.contains("\n")
                if isEclipseCap { droppedKeys.append(name) }
                continue
            }
            let entryBytes = name.utf8.count + value.utf8.count + 4
            guard entryBytes <= 32 * 1_024 - totalBytes else {
                droppedKeys.append(name)
                continue
            }
            bounded[name] = value
            totalBytes += entryBytes
        }
        if !droppedKeys.isEmpty {
            Logger.shared.log(
                "Service stream headers dropped by Eclipse droppedKeys=[\(droppedKeys.sorted().joined(separator: ","))] kept=\(bounded.count) caps=64/128B/8KiB/32KiB; a 401 or 403 on playback after this is Eclipse's header set, not the source's",
                type: "Plugin"
            )
        }
        return (bounded.isEmpty ? nil : bounded, droppedKeys.sorted())
    }

    private static func boundedServiceStrings(
        _ values: [String],
        limit: Int,
        maximumBytes: Int,
        label: String
    ) -> [String] {
        var bounded: [String] = []
        var rejected = 0
        var refusedByValueCap = 0
        bounded.reserveCapacity(min(values.count, limit))
        for value in values {
            guard bounded.count < limit else { break }
            if let value = boundedServiceString(value, maximumBytes: maximumBytes, field: label) {
                bounded.append(value)
            } else if value.utf8.count > maximumBytes {
                refusedByValueCap += 1
            } else {
                rejected += 1
            }
        }
        logRowReduction(
            label: label,
            raw: values.count,
            kept: bounded.count,
            rejected: rejected,
            refusedByValueCap: refusedByValueCap,
            limit: limit
        )
        return bounded
    }

    private static func boundedServiceObjects<T, U>(
        _ values: [T],
        limit: Int,
        label: String,
        transform: (T) -> U?
    ) -> [U] {
        var bounded: [U] = []
        var rejected = 0
        bounded.reserveCapacity(min(values.count, limit))
        for value in values {
            guard bounded.count < limit else { break }
            if let value = transform(value) {
                bounded.append(value)
            } else {
                rejected += 1
            }
        }
        logRowReduction(
            label: label,
            raw: values.count,
            kept: bounded.count,
            rejected: rejected,
            refusedByValueCap: 0,
            limit: limit
        )
        return bounded
    }

    private static func logRowReduction(
        label: String,
        raw: Int,
        kept: Int,
        rejected: Int,
        refusedByValueCap: Int,
        limit: Int
    ) {
        let untried = raw - kept - rejected
        if untried > 0 {
            Logger.shared.log(
                "Service \(label) rows cut by Eclipse raw=\(raw) kept=\(kept) untried=\(untried) cap=\(limit); Eclipse stopped at its own cap and never examined those rows",
                type: "Plugin"
            )
        }
        if refusedByValueCap > 0 {
            Logger.shared.log(
                "Service \(label) rows refused by Eclipse's value cap raw=\(raw) kept=\(kept) refused=\(refusedByValueCap); those values were past Eclipse's per-value byte cap, not unusable source data",
                type: "Plugin"
            )
        }
        if rejected > 0 {
            Logger.shared.log(
                "Service \(label) rows unusable raw=\(raw) kept=\(kept) rejected=\(rejected); Eclipse could not read a usable value out of those rows",
                type: "Plugin"
            )
        }
    }

    private static func boundedServiceString(
        _ value: String,
        maximumBytes: Int,
        field: String = "value"
    ) -> String? {
        guard !value.isEmpty else { return nil }
        guard value.utf8.count <= maximumBytes else {
            EclipseLedgerOnce.emit(
                scope: "service-stream-value-cap",
                signature: "\(field)|\(maximumBytes)"
            ) {
                Logger.shared.log(
                    "Service stream value dropped by Eclipse field=\(field) cap=\(maximumBytes); the field is absent from the stream Eclipse built, not from the source's result",
                    type: "Plugin"
                )
            }
            return nil
        }
        guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        return value
    }

    @discardableResult
    func fetchStreamUrlJS(
        episodeUrl: String,
        softsub: Bool = false,
        module: Service,
        timeoutNanoseconds: UInt64 = JSController.streamExtractionTimeoutNanoseconds,
        completion: @escaping (ServiceStreamExtractionResult) -> Void
    ) -> JSCallbackDeadline<ServiceStreamExtractionResult> {
        let emptyResult: ServiceStreamExtractionResult = (nil, nil, nil)
        let request = JSCallbackDeadline<ServiceStreamExtractionResult> { result in
            DispatchQueue.main.async {
                completion(result)
            }
        }
        let operation = beginStreamExtractionOperation(service: module, primaryURL: episodeUrl)
        let boundary = makeBoundary()
        request.setCancellationHandler { [weak self] in
            self?.cancelPendingServiceOperation(operation, reason: "stream-extraction-cancelled")
        }
        let finish: (ServiceStreamExtractionResult, String) -> Void = { [weak self, request] result, reason in
            _ = request.finish(with: result) {
                self?.endServiceOperation(operation, reason: reason)
            }
        }

        request.armTimeout(
            nanoseconds: timeoutNanoseconds,
            value: emptyResult
        ) { [weak self] in
            Logger.shared.log(
                "Service stream extraction timed out service=\(module.metadata.sourceName)",
                type: "Stream"
            )
            self?.handleOperationTimeout(
                operation,
                boundary: boundary,
                reason: "stream-extraction-timeout"
            )
        }

        enqueueJavaScriptOperation(
            operation,
            service: module,
            boundary: boundary,
            shouldStart: { request.isPending },
            unavailable: { finish(emptyResult, "runtime-unavailable") }
        ) { [weak self] context in
            guard let self else {
                finish(emptyResult, "controller-released")
                return
            }
            guard context.exception == nil,
                  let extractStreamUrlFunction = context.objectForKeyedSubscript("extractStreamUrl"),
                  !extractStreamUrlFunction.isUndefined,
                  !extractStreamUrlFunction.isNull else {
                Logger.shared.log("No usable JavaScript function extractStreamUrl found service=\(module.metadata.sourceName)", type: "Error")
                finish(emptyResult, "missing-function-or-exception")
                return
            }
            let promiseValue = extractStreamUrlFunction.call(withArguments: [episodeUrl])
            guard request.isPending else { return }
            guard let promise = promiseValue else {
                finish(emptyResult, "invalid-promise")
                return
            }

            let deliverResult: (JSValue) -> Void = { [weak self] result in
                guard request.isPending, let self else { return }
                if result.isNull || result.isUndefined {
                    finish(emptyResult, "empty-result")
                    return
                }
                if let resultString = result.toString(), resultString == "[object Promise]" {
                    finish(emptyResult, "promise-object")
                    return
                }
                guard let data = Self.boundedUTF8Data(
                    from: result,
                    maximumBytes: Self.maximumStreamResultBytes
                ) else {
                    Logger.shared.log(
                        "Service stream payload refused by Eclipse before parsing cap=maximumStreamResultBytes=\(Self.maximumStreamResultBytes); the result was oversized or not a string, so an empty stream list here is not a dead source",
                        type: "Plugin"
                    )
                    finish(emptyResult, "invalid-data")
                    return
                }
                do {
                    let bounded = try Self.boundedStreamExtractionResult(from: data)
                    self.logStreamSourceDiagnostics(bounded.sources ?? [], serviceName: module.metadata.sourceName)
                    self.logPlainStreamDiagnostics(bounded.streams ?? [], serviceName: module.metadata.sourceName)
                    Logger.shared.log("Service stream extraction completed service=\(module.metadata.sourceName) plainStreams=\(bounded.streams?.count ?? 0) structuredSources=\(bounded.sources?.count ?? 0) subtitles=\(bounded.subtitles?.count ?? 0)", type: "Plugin")
                    finish(bounded, "resolved")
                    return
                } catch {
                    if let raw = String(data: data, encoding: .utf8),
                       let bounded = Self.boundedServiceString(raw, maximumBytes: 64 * 1_024, field: "raw-body"),
                       let url = URL(string: bounded),
                       let scheme = url.scheme?.lowercased(),
                       scheme == "http" || scheme == "https" {
                        finish(([bounded], nil, nil), "resolved-raw-url")
                        return
                    }
                }
                finish(emptyResult, "parse-error")
            }

            guard Self.isThenable(promise) else {
                deliverResult(promise)
                return
            }

            let thenBlock: @convention(block) (JSValue) -> Void = { result in
                deliverResult(result)
            }
            let catchBlock: @convention(block) (JSValue) -> Void = { _ in
                guard request.isPending else { return }
                Logger.shared.log("Service stream promise rejected; untrusted body suppressed", type: "Error")
                finish(emptyResult, "rejected")
            }
            guard let thenFunction = JSValue(object: thenBlock, in: context),
                  let catchFunction = JSValue(object: catchBlock, in: context) else {
                finish(emptyResult, "handler-create-failed")
                return
            }
            promise.invokeMethod("then", withArguments: [thenFunction])
            guard request.isPending else { return }
            promise.invokeMethod("catch", withArguments: [catchFunction])
        }
        return request
    }

    private func logStreamSourceDiagnostics(_ sources: [[String: Any]], serviceName: String) {
        let summaries = sources.enumerated().prefix(8).map { index, source in
            streamSourceDiagnosticSummary(source, index: index)
        }.joined(separator: " || ")
        Logger.shared.log("Service stream diagnostics service=\(serviceName) sourceCount=\(sources.count) \(summaries)", type: "StreamDiagnostics")
    }

    private func logPlainStreamDiagnostics(_ urls: [String], serviceName: String) {
        let summaries = urls.enumerated().prefix(8).map { index, urlString in
            plainStreamDiagnosticSummary(urlString, index: index)
        }.joined(separator: " || ")
        Logger.shared.log("Service stream diagnostics service=\(serviceName) sourceCount=\(urls.count) \(summaries)", type: "StreamDiagnostics")
    }

    private func streamSourceDiagnosticSummary(_ source: [String: Any], index: Int) -> String {
        let urlString = firstStringValue(in: source, keys: ["url", "file", "src", "link", "stream"])
        let name = firstStringValue(in: source, keys: ["name", "title", "label", "quality"]) ?? "nil"
        let headerKeys = ((source["headers"] as? [String: Any]) ?? (source["headers"] as? [String: String])?.mapValues { $0 as Any } ?? [:])
            .keys
            .sorted()
            .joined(separator: ",")
        let summary = urlString.map { plainStreamDiagnosticSummary($0, index: index) } ?? "#\(index) url=nil"
        return "\(summary) name=\(name) headerKeys=[\(headerKeys)]"
    }

    private func plainStreamDiagnosticSummary(_ urlString: String, index: Int) -> String {
        guard let url = URL(string: urlString) else {
            return "#\(index) url=invalid"
        }
        let ext = url.pathExtension.isEmpty ? "none" : url.pathExtension
        return "#\(index) host=\(url.host ?? "nil") ext=\(ext)"
    }

    private func firstStringValue(in source: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = source[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
