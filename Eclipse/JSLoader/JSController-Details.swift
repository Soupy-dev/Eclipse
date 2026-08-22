//
//  JSControllerDetails.swift
//  Sora
//
//  Created by Francesco on 07/08/25.
//

import Foundation
import JavaScriptCore

enum ServiceDetailResultBoundaryError: Error {
    case invalidPayload
}

struct MediaItem: Identifiable {
    let id = UUID()
    let description: String
    let aliases: String
    let airdate: String
}

struct EpisodeLink: Identifiable {
    let id = UUID()
    let number: Int
    let title: String
    let href: String
    let duration: Int?
}

private final class ServiceDetailsAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var detailsFinished = false
    private var episodesFinished = false
    private var details: [MediaItem] = []
    private var episodes: [EpisodeLink] = []

    func finishDetails(_ value: [MediaItem]) -> ([MediaItem], [EpisodeLink])? {
        lock.lock()
        guard !detailsFinished else {
            lock.unlock()
            return nil
        }
        detailsFinished = true
        details = value
        let result = episodesFinished ? (details, episodes) : nil
        lock.unlock()
        return result
    }

    func finishEpisodes(_ value: [EpisodeLink]) -> ([MediaItem], [EpisodeLink])? {
        lock.lock()
        guard !episodesFinished else {
            lock.unlock()
            return nil
        }
        episodesFinished = true
        episodes = value
        let result = detailsFinished ? (details, episodes) : nil
        lock.unlock()
        return result
    }
}

extension JSController {
    private static let maximumDetailResultBytes = 4 * 1_024 * 1_024
    private static let maximumDetailItems = 16
    private static let maximumEpisodeLinks = 4_096

    static func boundedMediaItems(
        from data: Data
    ) throws -> (items: [MediaItem], rawCount: Int) {
        let array = try boundedServiceArray(from: data)
        let items = array.prefix(maximumDetailItems).map { item in
            MediaItem(
                description: boundedServiceText(item["description"] as? String, maximumBytes: 64 * 1_024),
                aliases: boundedServiceText(item["aliases"] as? String, maximumBytes: 8 * 1_024),
                airdate: boundedServiceText(item["airdate"] as? String, maximumBytes: 256)
            )
        }
        return (items, array.count)
    }

    static func boundedEpisodeLinks(
        from data: Data
    ) throws -> (
        episodes: [EpisodeLink],
        rawCount: Int,
        eclipseRejectedRowCount: Int,
        unreadableRowCount: Int
    ) {
        let array = try boundedServiceArray(from: data)
        var episodes: [EpisodeLink] = []
        var eclipseRejectedRowCount = 0
        var unreadableRowCount = 0
        episodes.reserveCapacity(min(array.count, maximumEpisodeLinks))
        for (index, item) in array.enumerated() {
            guard episodes.count < maximumEpisodeLinks else { break }
            // A recap or special numbered 13.5, or a non-numeric label, must still yield a row.
            // The href is what makes the episode playable; dropping the row loses it entirely
            // from the list, from Continue Watching and from the download refresh path.
            guard let href = item["href"] as? String,
                  !href.isEmpty,
                  !href.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                unreadableRowCount += 1
                continue
            }
            guard href.utf8.count <= maximumEpisodeHrefBytes else {
                eclipseRejectedRowCount += 1
                continue
            }
            guard let number = coercedEpisodeNumber(item["number"], fallback: index + 1) else {
                eclipseRejectedRowCount += 1
                continue
            }
            episodes.append(EpisodeLink(number: number, title: "", href: href, duration: nil))
        }
        return (episodes, array.count, eclipseRejectedRowCount, unreadableRowCount)
    }


    static func payloadDiscardAttribution(_ error: Error) -> String {
        if let envelope = error as? SkyStreamJSONEnvelopeError {
            switch envelope {
            case .excessiveDepth, .excessiveTokens, .excessiveContainerValues, .excessiveTokenBytes:
                return "the payload failed Eclipse's own bounds, so this empty result is Eclipse's doing"
            case .empty, .malformedStructure:
                return "the source returned an empty or malformed payload, so this is the source's data, not an Eclipse cap"
            }
        }
        return "the source's payload could not be read as a list of objects, so this is the source's data, not an Eclipse cap"
    }

    static func logEpisodeRowReduction(
        _ bounded: (
            episodes: [EpisodeLink],
            rawCount: Int,
            eclipseRejectedRowCount: Int,
            unreadableRowCount: Int
        )
    ) {
        let untried = bounded.rawCount
            - bounded.eclipseRejectedRowCount
            - bounded.unreadableRowCount
            - bounded.episodes.count
        if untried + bounded.eclipseRejectedRowCount > 0 {
            Logger.shared.log(
                "Service episode rows cut by Eclipse raw=\(bounded.rawCount) kept=\(bounded.episodes.count) untried=\(untried) rejected=\(bounded.eclipseRejectedRowCount) caps=maximumEpisodeLinks=\(maximumEpisodeLinks)/href=\(maximumEpisodeHrefBytes)B/episodeNumber=\(maximumEpisodeNumberMagnitude); those rows were lost to Eclipse's own bounds, not withheld by the source",
                type: "Plugin"
            )
        }
        if bounded.unreadableRowCount > 0 {
            Logger.shared.log(
                "Service episode rows unreadable raw=\(bounded.rawCount) kept=\(bounded.episodes.count) unreadable=\(bounded.unreadableRowCount); those rows carried no usable href, so this is the source's data, not an Eclipse cap",
                type: "Plugin"
            )
        }
    }

    private static func boundedServiceArray(from data: Data) throws -> [[String: Any]] {
        guard !data.isEmpty else {
            throw ServiceDetailResultBoundaryError.invalidPayload
        }
        guard data.count <= maximumDetailResultBytes else {
            Logger.shared.log(
                "Service detail result refused by Eclipse bytes=\(data.count) cap=maximumDetailResultBytes=\(maximumDetailResultBytes); the whole detail payload is discarded, so an empty episode list here is an Eclipse limit, not a dead source",
                type: "Plugin"
            )
            throw ServiceDetailResultBoundaryError.invalidPayload
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
                "Service detail envelope refused by Eclipse bytes=\(data.count) caps=depth12/tokens400000/values20000/string1MiB; the whole detail payload is discarded, so an empty episode list here is an Eclipse limit, not a dead source",
                type: "Plugin"
            )
            throw error
        }
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ServiceDetailResultBoundaryError.invalidPayload
        }
        return array
    }

    private static func boundedServiceText(_ value: String?, maximumBytes: Int) -> String {
        guard let value, maximumBytes > 0 else { return "" }
        let bytes = value.utf8
        guard bytes.count > maximumBytes else { return value }

        // Do not let String(decoding:) insert a replacement scalar when the
        // byte limit cuts through a multi-byte character; that could make the
        // returned UTF-8 representation larger than the advertised bound.
        var prefix = Data(bytes.prefix(maximumBytes))
        while !prefix.isEmpty {
            if let truncated = String(data: prefix, encoding: .utf8) {
                return truncated
            }
            prefix.removeLast()
        }
        return ""
    }

    static let maximumEpisodeHrefBytes = 16 * 1_024
    static let maximumEpisodeNumberMagnitude = 100_000

    private static func coercedEpisodeNumber(_ value: Any?, fallback: Int) -> Int? {
        if let bounded = boundedEpisodeNumber(value) { return bounded }
        if let number = value as? NSNumber {
            let rounded = number.doubleValue.rounded()
            guard rounded.isFinite,
                  rounded >= Double(-maximumEpisodeNumberMagnitude),
                  rounded <= Double(maximumEpisodeNumberMagnitude) else { return nil }
            return Int(rounded)
        }
        if let text = value as? String,
           let parsed = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            let rounded = parsed.rounded()
            guard rounded.isFinite,
                  rounded >= Double(-maximumEpisodeNumberMagnitude),
                  rounded <= Double(maximumEpisodeNumberMagnitude) else { return nil }
            return Int(rounded)
        }
        return fallback
    }

    private static func boundedEpisodeNumber(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber {
            let double = value.doubleValue
            guard double.isFinite, double == double.rounded() else { return nil }
            return Int(exactly: double)
        }
        if let value = value as? String, value.utf8.count <= 16 {
            return Int(value)
        }
        return nil
    }

    func fetchDetailsJS(
        url: String,
        module: Service? = nil,
        timeoutNanoseconds: UInt64 = 20_000_000_000,
        completion: @escaping ([MediaItem], [EpisodeLink]) -> Void
    ) {
        guard let url = ServiceModuleURLParser.url(url) else {
            Logger.shared.log("Service detail rejected an invalid URL; value suppressed", type: "Error")
            completion([], [])
            return
        }

        let operation: ServiceSandboxOperation
        if let module {
            operation = beginServiceOperation(
                service: module,
                operation: "extractDetails",
                primaryURL: url.absoluteString
            )
        } else {
            operation = ServiceSandboxOperation(
                id: UUID(),
                serviceID: nil,
                scriptFingerprint: nil,
                serviceName: "unknown",
                operation: "extractDetails",
                primaryURL: url.absoluteString
            )
        }
        let boundary = makeBoundary()
        let accumulator = ServiceDetailsAccumulator()
        let request = JSCallbackDeadline<([MediaItem], [EpisodeLink])> { result in
            DispatchQueue.main.async { completion(result.0, result.1) }
        }
        let finish: (([MediaItem], [EpisodeLink]), String) -> Void = { [weak self, request] result, reason in
            _ = request.finish(with: result) {
                self?.endServiceOperation(operation, reason: reason)
            }
        }
        request.armTimeout(nanoseconds: timeoutNanoseconds, value: ([], [])) { [weak self] in
            Logger.shared.log("Timeout for service details service=\(module?.metadata.sourceName ?? "unknown")", type: "Warning")
            self?.handleOperationTimeout(operation, boundary: boundary, reason: "details-timeout")
        }

        enqueueJavaScriptOperation(
            operation,
            service: module,
            boundary: boundary,
            shouldStart: { request.isPending },
            unavailable: { finish(([], []), "runtime-unavailable") }
        ) { context in
            if context.exception != nil {
                finish(([], []), "exception")
                return
            }
            guard let extractDetails = context.objectForKeyedSubscript("extractDetails"),
                  !extractDetails.isUndefined,
                  !extractDetails.isNull,
                  let extractEpisodes = context.objectForKeyedSubscript("extractEpisodes"),
                  !extractEpisodes.isUndefined,
                  !extractEpisodes.isNull else {
                finish(([], []), "missing-function")
                return
            }

            func deliverIfComplete(
                _ result: ([MediaItem], [EpisodeLink])?,
                reason: String
            ) {
                if let result {
                    Logger.shared.log("Service details completed service=\(module?.metadata.sourceName ?? "unknown") details=\(result.0.count) episodes=\(result.1.count)", type: "Service")
                    finish(result, reason)
                }
            }

            func deliverDetails(_ result: JSValue) {
                guard request.isPending else { return }
                var items: [MediaItem] = []
                if let data = Self.boundedUTF8Data(from: result, maximumBytes: Self.maximumDetailResultBytes) {
                    do {
                        let bounded = try Self.boundedMediaItems(from: data)
                        items = bounded.items
                        if bounded.rawCount > bounded.items.count {
                            Logger.shared.log(
                                "Service detail items reduced by Eclipse raw=\(bounded.rawCount) kept=\(bounded.items.count); the missing rows were dropped by Eclipse, not withheld by the source",
                                type: "Plugin"
                            )
                        }
                    } catch {
                        items = []
                        Logger.shared.log(
                            "Service detail items discarded; \(Self.payloadDiscardAttribution(error))",
                            type: "Plugin"
                        )
                    }
                } else {
                    Logger.shared.log(
                        "Service detail payload refused by Eclipse before parsing cap=maximumDetailResultBytes=\(Self.maximumDetailResultBytes); the result was oversized or not a string, so an empty detail here is not a dead source",
                        type: "Plugin"
                    )
                }
                deliverIfComplete(accumulator.finishDetails(items), reason: "resolved")
            }

            func deliverEpisodes(_ result: JSValue) {
                guard request.isPending else { return }
                var episodes: [EpisodeLink] = []
                if let data = Self.boundedUTF8Data(from: result, maximumBytes: Self.maximumDetailResultBytes) {
                    do {
                        let bounded = try Self.boundedEpisodeLinks(from: data)
                        episodes = bounded.episodes
                        Self.logEpisodeRowReduction(bounded)
                    } catch {
                        episodes = []
                        Logger.shared.log(
                            "Service episode rows discarded; \(Self.payloadDiscardAttribution(error))",
                            type: "Plugin"
                        )
                    }
                } else {
                    Logger.shared.log(
                        "Service episode payload refused by Eclipse before parsing cap=maximumDetailResultBytes=\(Self.maximumDetailResultBytes); the result was oversized or not a string, so an empty episode list here is not a dead source",
                        type: "Plugin"
                    )
                }
                deliverIfComplete(accumulator.finishEpisodes(episodes), reason: "resolved")
            }

            let detailsThen: @convention(block) (JSValue) -> Void = { result in
                deliverDetails(result)
            }
            let detailsCatch: @convention(block) (JSValue) -> Void = { _ in
                guard request.isPending else { return }
                Logger.shared.log("Service detail promise rejected; untrusted body suppressed", type: "Error")
                deliverIfComplete(accumulator.finishDetails([]), reason: "resolved-with-detail-rejection")
            }
            let episodesThen: @convention(block) (JSValue) -> Void = { result in
                deliverEpisodes(result)
            }
            let episodesCatch: @convention(block) (JSValue) -> Void = { _ in
                guard request.isPending else { return }
                Logger.shared.log("Service episodes promise rejected; untrusted body suppressed", type: "Error")
                deliverIfComplete(accumulator.finishEpisodes([]), reason: "resolved-with-episode-rejection")
            }

            guard let detailsThenValue = JSValue(object: detailsThen, in: context),
                  let detailsCatchValue = JSValue(object: detailsCatch, in: context),
                  let episodesThenValue = JSValue(object: episodesThen, in: context),
                  let episodesCatchValue = JSValue(object: episodesCatch, in: context) else {
                finish(([], []), "handler-create-failed")
                return
            }

            guard let detailsPromise = extractDetails.call(withArguments: [url.absoluteString]),
                  request.isPending else { return }
            if Self.isThenable(detailsPromise) {
                detailsPromise.invokeMethod("then", withArguments: [detailsThenValue])
                guard request.isPending else { return }
                detailsPromise.invokeMethod("catch", withArguments: [detailsCatchValue])
            } else {
                deliverDetails(detailsPromise)
            }
            guard request.isPending,
                  let episodesPromise = extractEpisodes.call(withArguments: [url.absoluteString]),
                  request.isPending else { return }
            if Self.isThenable(episodesPromise) {
                episodesPromise.invokeMethod("then", withArguments: [episodesThenValue])
                guard request.isPending else { return }
                episodesPromise.invokeMethod("catch", withArguments: [episodesCatchValue])
            } else {
                deliverEpisodes(episodesPromise)
            }
        }
    }

    func fetchEpisodesJS(
        url: String,
        module: Service,
        timeoutNanoseconds: UInt64 = 20_000_000_000,
        completion: @escaping ([EpisodeLink]) -> Void
    ) {
        guard let url = ServiceModuleURLParser.url(url) else {
            Logger.shared.log("Service episodes rejected an invalid URL; value suppressed", type: "Error")
            completion([])
            return
        }

        let operation = beginServiceOperation(service: module, operation: "extractEpisodes", primaryURL: url.absoluteString)
        let boundary = makeBoundary()
        let request = JSCallbackDeadline<[EpisodeLink]> { result in
            DispatchQueue.main.async { completion(result) }
        }
        let finish: ([EpisodeLink], String) -> Void = { [weak self, request] result, reason in
            _ = request.finish(with: result) {
                self?.endServiceOperation(operation, reason: reason)
            }
        }
        request.armTimeout(nanoseconds: timeoutNanoseconds, value: []) { [weak self] in
            Logger.shared.log("Timeout for extractEpisodes service=\(module.metadata.sourceName)", type: "Warning")
            self?.handleOperationTimeout(operation, boundary: boundary, reason: "episodes-timeout")
        }

        enqueueJavaScriptOperation(
            operation,
            service: module,
            boundary: boundary,
            shouldStart: { request.isPending },
            unavailable: { finish([], "runtime-unavailable") }
        ) { context in
            guard context.exception == nil,
                  let function = context.objectForKeyedSubscript("extractEpisodes"),
                  !function.isUndefined,
                  !function.isNull else {
                finish([], "missing-function-or-exception")
                return
            }
            guard let promise = function.call(withArguments: [url.absoluteString]),
                  request.isPending else { return }

            func deliverEpisodes(_ result: JSValue) {
                guard request.isPending else { return }
                let episodes: [EpisodeLink]
                if let data = Self.boundedUTF8Data(from: result, maximumBytes: Self.maximumDetailResultBytes) {
                    do {
                        let bounded = try Self.boundedEpisodeLinks(from: data)
                        episodes = bounded.episodes
                        Self.logEpisodeRowReduction(bounded)
                    } catch {
                        episodes = []
                        Logger.shared.log(
                            "Service episode rows discarded; \(Self.payloadDiscardAttribution(error))",
                            type: "Plugin"
                        )
                    }
                } else {
                    episodes = []
                    Logger.shared.log(
                        "Service episode payload refused by Eclipse before parsing cap=maximumDetailResultBytes=\(Self.maximumDetailResultBytes); the result was oversized or not a string, so an empty episode list here is not a dead source",
                        type: "Plugin"
                    )
                }
                Logger.shared.log("Service episodes completed service=\(module.metadata.sourceName) episodeCount=\(episodes.count) target=\(ServiceSandboxState.redactedURL(url.absoluteString))", type: "Service")
                finish(episodes, "resolved")
            }

            let thenBlock: @convention(block) (JSValue) -> Void = { result in
                deliverEpisodes(result)
            }
            let catchBlock: @convention(block) (JSValue) -> Void = { _ in
                guard request.isPending else { return }
                Logger.shared.log("Service episodes promise rejected; untrusted body suppressed", type: "Error")
                finish([], "rejected")
            }
            guard let thenValue = JSValue(object: thenBlock, in: context),
                  let catchValue = JSValue(object: catchBlock, in: context) else {
                finish([], "handler-create-failed")
                return
            }
            guard Self.isThenable(promise) else {
                deliverEpisodes(promise)
                return
            }
            promise.invokeMethod("then", withArguments: [thenValue])
            guard request.isPending else { return }
            promise.invokeMethod("catch", withArguments: [catchValue])
        }
    }
}
