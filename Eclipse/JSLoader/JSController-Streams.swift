//
//  JSLoader-Streams.swift
//  Sora
//
//  Created by Francesco on 07/08/25.
//

import JavaScriptCore

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
        guard !data.isEmpty, data.count <= maximumStreamResultBytes else {
            throw ServiceStreamResultBoundaryError.invalidPayload
        }
        try SkyStreamJSONEnvelopeValidator.validate(
            data,
            limits: .init(
                maximumDepth: 12,
                maximumTokens: 100_000,
                maximumValuesPerContainer: 4_096,
                maximumStringBytes: 64 * 1_024,
                maximumScalarTokenBytes: 128
            )
        )
        let value = try JSONSerialization.jsonObject(with: data)
        if let object = value as? [String: Any] {
            let envelopeHeaders = boundedServiceHeaders(object["headers"])
            let envelopeSubtitleHeaders = boundedServiceHeaders(object["subtitleHeaders"])
            let carriesEnvelopeHeaders = envelopeHeaders != nil || envelopeSubtitleHeaders != nil
            let sources: [[String: Any]]? = {
                if let values = object["streams"] as? [[String: Any]] {
                    let bounded = boundedServiceObjects(
                        values,
                        limit: maximumStreamEntries,
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
                        boundedServiceStrings(values, limit: maximumStreamEntries, maximumBytes: 16 * 1_024)
                    )
                    return bounded.isEmpty ? nil : bounded
                }
                if let value = object["stream"] as? String,
                   let bounded = boundedServiceString(value, maximumBytes: 16 * 1_024) {
                    return [["streamUrl": bounded]]
                }
                return nil
            }()
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
                    let bounded = boundedServiceStrings(values, limit: maximumStreamEntries, maximumBytes: 16 * 1_024)
                    return bounded.isEmpty ? nil : bounded
                }
                if let value = object["stream"] as? String,
                   let bounded = boundedServiceString(value, maximumBytes: 16 * 1_024) {
                    return [bounded]
                }
                return nil
            }()
            let subtitles: [String]? = {
                if let values = object["subtitles"] as? [String] {
                    let bounded = boundedServiceStrings(values, limit: maximumSubtitleEntries, maximumBytes: 16 * 1_024)
                    return bounded.isEmpty ? nil : bounded
                }
                if let value = object["subtitles"] as? String,
                   let bounded = boundedServiceString(value, maximumBytes: 16 * 1_024) {
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
            let bounded = boundedServiceStrings(values, limit: maximumStreamEntries, maximumBytes: 16 * 1_024)
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
               let value = boundedServiceString(value, maximumBytes: 16 * 1_024) {
                bounded[key] = value
            }
        }
        for key in metadataKeys {
            if let value = source[key] as? String,
               let value = boundedServiceString(value, maximumBytes: 2 * 1_024) {
                bounded[key] = value
            } else if let value = source[key] as? NSNumber {
                bounded[key] = String(value.stringValue.prefix(128))
            }
        }
        for key in metadataArrayKeys {
            if let values = source[key] as? [String] {
                bounded[key] = boundedServiceStrings(values, limit: 32, maximumBytes: 2 * 1_024)
            }
        }
        if let headers = boundedServiceHeaders(source["headers"]) {
            bounded["headers"] = headers
        }
        if let headers = boundedServiceHeaders(source["subtitleHeaders"]) {
            bounded["subtitleHeaders"] = headers
        }
        if let values = source["subtitles"] as? [String] {
            bounded["subtitles"] = boundedServiceStrings(
                values,
                limit: maximumSubtitleEntries,
                maximumBytes: 16 * 1_024
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
                if let title = boundedServiceString(entry, maximumBytes: 2 * 1_024) {
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
               let value = boundedServiceString(value, maximumBytes: 16 * 1_024) {
                bounded[key] = value
            }
        }
        for key in ["title", "name", "label", "lang", "language"] {
            if let value = source[key] as? String,
               let value = boundedServiceString(value, maximumBytes: 2 * 1_024) {
                bounded[key] = value
            }
        }
        if let headers = boundedServiceHeaders(source["headers"]) {
            bounded["headers"] = headers
        }
        return ["url", "file", "src"].contains { bounded[$0] is String } ? bounded : nil
    }

    private static func boundedServiceHeaders(_ value: Any?) -> [String: String]? {
        let raw: [String: String]
        if let value = value as? [String: String] {
            raw = value
        } else if let value = value as? [String: Any] {
            raw = value.reduce(into: [:]) { result, pair in
                if let string = pair.value as? String { result[pair.key] = string }
                else if let number = pair.value as? NSNumber { result[pair.key] = number.stringValue }
            }
        } else {
            return nil
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
                continue
            }
            let entryBytes = name.utf8.count + value.utf8.count + 4
            guard entryBytes <= 32 * 1_024 - totalBytes else { continue }
            bounded[name] = value
            totalBytes += entryBytes
        }
        return bounded.isEmpty ? nil : bounded
    }

    private static func boundedServiceStrings(
        _ values: [String],
        limit: Int,
        maximumBytes: Int
    ) -> [String] {
        var bounded: [String] = []
        bounded.reserveCapacity(min(values.count, limit))
        for value in values {
            guard bounded.count < limit else { break }
            if let value = boundedServiceString(value, maximumBytes: maximumBytes) {
                bounded.append(value)
            }
        }
        return bounded
    }

    private static func boundedServiceObjects<T, U>(
        _ values: [T],
        limit: Int,
        transform: (T) -> U?
    ) -> [U] {
        var bounded: [U] = []
        bounded.reserveCapacity(min(values.count, limit))
        for value in values {
            guard bounded.count < limit else { break }
            if let value = transform(value) {
                bounded.append(value)
            }
        }
        return bounded
    }

    private static func boundedServiceString(_ value: String, maximumBytes: Int) -> String? {
        guard !value.isEmpty,
              value.utf8.count <= maximumBytes,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
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
                    finish(emptyResult, "invalid-data")
                    return
                }
                do {
                    let bounded = try Self.boundedStreamExtractionResult(from: data)
                    self.logStreamSourceDiagnostics(bounded.sources ?? [], serviceName: module.metadata.sourceName)
                    self.logPlainStreamDiagnostics(bounded.streams ?? [], serviceName: module.metadata.sourceName)
                    Logger.shared.log("Service stream extraction completed service=\(module.metadata.sourceName) plainStreams=\(bounded.streams?.count ?? 0) structuredSources=\(bounded.sources?.count ?? 0) subtitles=\(bounded.subtitles?.count ?? 0)", type: "Stream")
                    finish(bounded, "resolved")
                    return
                } catch {
                    if let raw = String(data: data, encoding: .utf8),
                       let bounded = Self.boundedServiceString(raw, maximumBytes: 16 * 1_024),
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
