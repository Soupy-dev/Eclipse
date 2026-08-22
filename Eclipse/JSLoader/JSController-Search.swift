//
//  JSController-Search.swift
//  Sora
//
//  Created by Francesco on 07/08/25.
//

import Foundation
import JavaScriptCore

struct SearchItem: Identifiable {
    let id = UUID()
    let title: String
    let imageUrl: String
    let href: String
}

enum ServiceSearchResultBoundaryError: Error {
    case invalidPayload
}

extension JSController {
    private static let maximumSearchResultBytes = 4 * 1_024 * 1_024
    private static let maximumSearchResults = 1_200
    private static let searchResultTimeoutNanoseconds: UInt64 = 20_000_000_000

    static func boundedSearchItems(
        from data: Data,
        maxResults: Int? = nil
    ) throws -> (items: [SearchItem], rawCount: Int) {
        guard !data.isEmpty else {
            throw ServiceSearchResultBoundaryError.invalidPayload
        }
        guard data.count <= maximumSearchResultBytes else {
            Logger.shared.log(
                "Service search result refused by Eclipse bytes=\(data.count) cap=maximumSearchResultBytes=\(maximumSearchResultBytes); the whole result set is discarded, so an empty search here is an Eclipse limit, not a dead source",
                type: "Plugin"
            )
            throw ServiceSearchResultBoundaryError.invalidPayload
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
                "Service search envelope refused by Eclipse bytes=\(data.count) caps=depth12/tokens400000/values20000/string1MiB; the whole result set is discarded, so an empty search here is an Eclipse limit, not a dead source",
                type: "Plugin"
            )
            throw error
        }
        guard let array = try JSONSerialization.jsonObject(
            with: data,
            options: []
        ) as? [[String: Any]] else {
            throw ServiceSearchResultBoundaryError.invalidPayload
        }
        let resultLimit = min(
            max(maxResults ?? maximumSearchResults, 0),
            maximumSearchResults
        )
        var items: [SearchItem] = []
        items.reserveCapacity(min(resultLimit, array.count))
        for item in array {
            guard items.count < resultLimit else { break }
            guard let rawTitle = item["title"] as? String,
                  let imageUrl = item["image"] as? String,
                  let href = item["href"] as? String,
                  rawTitle.utf8.count <= 512,
                  imageUrl.utf8.count <= 16 * 1_024,
                  href.utf8.count <= 16 * 1_024,
                  !imageUrl.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !href.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                continue
            }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            items.append(SearchItem(title: title, imageUrl: imageUrl, href: href))
        }
        return (items, array.count)
    }

    func fetchJsSearchResults(
        keyword: String,
        module: Service,
        maxResults: Int? = nil,
        timeoutNanoseconds: UInt64 = JSController.searchResultTimeoutNanoseconds,
        completion: @escaping ([SearchItem]) -> Void
    ) {
        var keywordPrefix = Data(keyword.utf8.prefix(1_024))
        while !keywordPrefix.isEmpty, String(data: keywordPrefix, encoding: .utf8) == nil {
            keywordPrefix.removeLast()
        }
        let boundedKeyword = (String(data: keywordPrefix, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if keyword.utf8.count > 1_024 {
            Logger.shared.log(
                "Service search keyword truncated by Eclipse bytes=\(keyword.utf8.count) cap=1024; the source is searching for less than the user typed",
                type: "Plugin"
            )
        }
        guard !boundedKeyword.isEmpty else {
            completion([])
            return
        }
        let operation = beginServiceOperation(service: module, operation: "searchResults")
        let boundary = makeBoundary()
        let request = JSCallbackDeadline<[SearchItem]> { items in
            DispatchQueue.main.async { completion(items) }
        }
        let finish: ([SearchItem], String) -> Void = { [weak self, request] items, reason in
            _ = request.finish(with: items) {
                self?.endServiceOperation(operation, reason: reason)
            }
        }
        request.armTimeout(
            nanoseconds: timeoutNanoseconds,
            value: []
        ) { [weak self] in
            Logger.shared.log("Timeout for service search service=\(module.metadata.sourceName) queryBytes=\(boundedKeyword.utf8.count)", type: "Warning")
            self?.handleOperationTimeout(
                operation,
                boundary: boundary,
                reason: "search-timeout"
            )
        }

        enqueueJavaScriptOperation(
            operation,
            service: module,
            boundary: boundary,
            shouldStart: { request.isPending },
            unavailable: { finish([], "runtime-unavailable") }
        ) { context in
            if context.exception != nil {
                Logger.shared.log("Service search JavaScript exception; untrusted body suppressed", type: "Error")
                finish([], "exception")
                return
            }

            guard let searchResultsFunction = context.objectForKeyedSubscript("searchResults"),
                  !searchResultsFunction.isUndefined,
                  !searchResultsFunction.isNull else {
                Logger.shared.log("Search function not found in service \(module.metadata.sourceName)", type: "Error")
                finish([], "missing-function")
                return
            }

            let promiseValue = searchResultsFunction.call(withArguments: [boundedKeyword])
            guard request.isPending, let promise = promiseValue else {
                if request.isPending {
                    Logger.shared.log("Search function returned invalid response service=\(module.metadata.sourceName)", type: "Error")
                    finish([], "invalid-promise")
                }
                return
            }

            let deliverResult: (JSValue) -> Void = { result in
                guard request.isPending else { return }
                if let data = Self.boundedUTF8Data(
                    from: result,
                    maximumBytes: Self.maximumSearchResultBytes
                ) {
                    do {
                        let parsed = try Self.boundedSearchItems(
                            from: data,
                            maxResults: maxResults
                        )
                        Logger.shared.log("Service search completed service=\(module.metadata.sourceName) queryBytes=\(boundedKeyword.utf8.count) rawResults=\(parsed.rawCount) returnedResults=\(parsed.items.count)", type: "Service")
                        finish(parsed.items, "resolved")
                    } catch {
                        Logger.shared.log("Service search result failed bounded parsing service=\(module.metadata.sourceName)", type: "Error")
                        finish([], "parse-error")
                    }
                } else {
                    Logger.shared.log("Service search result exceeded its bounded string contract service=\(module.metadata.sourceName)", type: "Error")
                    finish([], "invalid-result")
                }
            }

            guard Self.isThenable(promise) else {
                if promise.isNull || promise.isUndefined {
                    Logger.shared.log("Service search returned no value service=\(module.metadata.sourceName)", type: "Error")
                    finish([], "sync-empty")
                } else {
                    deliverResult(promise)
                }
                return
            }

            let thenBlock: @convention(block) (JSValue) -> Void = { result in
                deliverResult(result)
            }

            let catchBlock: @convention(block) (JSValue) -> Void = { _ in
                guard request.isPending else { return }
                Logger.shared.log("Service search promise rejected; untrusted body suppressed", type: "Error")
                finish([], "rejected")
            }

            let thenFunction = JSValue(object: thenBlock, in: context)
            let catchFunction = JSValue(object: catchBlock, in: context)
            guard request.isPending,
                  let thenFunction,
                  let catchFunction else {
                if request.isPending {
                    finish([], "handler-create-failed")
                }
                return
            }

            promise.invokeMethod("then", withArguments: [thenFunction])
            guard request.isPending else { return }
            promise.invokeMethod("catch", withArguments: [catchFunction])
        }
    }
}
