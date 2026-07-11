import JavaScriptCore

typealias ServiceStreamExtractionResult = (
    streams: [String]?,
    subtitles: [String]?,
    sources: [[String: Any]]?
)

extension JSController {
    private static let streamExtractionTimeoutNanoseconds: UInt64 = 20_000_000_000

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
        request.setCancellationHandler { [weak self] in
            self?.cancelPendingServiceOperation(operation, reason: "stream-extraction-cancelled")
        }
        let finish: (ServiceStreamExtractionResult, String) -> Void = { [weak self, request] result, reason in
            _ = request.finish(with: result) {
                self?.endServiceOperation(operation, reason: reason)
            }
        }

        if context.exception != nil {
            Logger.shared.log("Service stream JavaScript exception; untrusted body suppressed", type: "Error")
            finish(emptyResult, "exception")
            return request
        }
        
        guard let extractStreamUrlFunction = context.objectForKeyedSubscript("extractStreamUrl") else {
            Logger.shared.log("No JavaScript function extractStreamUrl found service=\(module.metadata.sourceName)", type: "Error")
            finish(emptyResult, "missing-function")
            return request
        }
        
        let promiseValue = extractStreamUrlFunction.call(withArguments: [episodeUrl])
        guard let promise = promiseValue else {
            Logger.shared.log("extractStreamUrl did not return a Promise service=\(module.metadata.sourceName)", type: "Error")
            finish(emptyResult, "invalid-promise")
            return request
        }

        request.armTimeout(
            nanoseconds: timeoutNanoseconds,
            value: emptyResult
        ) { [weak self] in
            Logger.shared.log(
                "Service stream extraction timed out service=\(module.metadata.sourceName)",
                type: "Stream"
            )
            self?.cancelPendingServiceOperation(operation, reason: "stream-extraction-timeout")
        }
        
        let thenBlock: @convention(block) (JSValue) -> Void = { [weak self] result in
            guard let self else {
                finish(emptyResult, "controller-released")
                return
            }
            
            if result.isNull || result.isUndefined {
                Logger.shared.log("Received null or undefined stream result service=\(module.metadata.sourceName)", type: "Error")
                finish(emptyResult, "empty-result")
                return
            }
            
            if let resultString = result.toString(), resultString == "[object Promise]" {
                Logger.shared.log("Received Promise object instead of resolved stream value service=\(module.metadata.sourceName)", type: "Error")
                finish(emptyResult, "promise-object")
                return
            }
            
            guard let jsonString = result.toString() else {
                Logger.shared.log("Failed to convert stream JSValue to string service=\(module.metadata.sourceName)", type: "Error")
                finish(emptyResult, "invalid-result")
                return
            }
            
            guard let data = jsonString.data(using: .utf8) else {
                Logger.shared.log("Failed to convert stream string to data service=\(module.metadata.sourceName)", type: "Error")
                finish(emptyResult, "invalid-data")
                return
            }
            
            do {
                if let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                    var streamUrls: [String]? = nil
                    var subtitleUrls: [String]? = nil
                    var streamUrlsAndHeaders : [[String:Any]]? = nil
                    
                    if let streamSources = json["streams"] as? [[String:Any]] {
                        streamUrlsAndHeaders = streamSources
                        Logger.shared.log("Found \(streamSources.count) streams and headers service=\(module.metadata.sourceName)", type: "Stream")
                        self.logStreamSourceDiagnostics(streamSources, serviceName: module.metadata.sourceName)
                    } else if let streamSource = json["stream"] as? [String:Any] {
                        streamUrlsAndHeaders = [streamSource]
                        Logger.shared.log("Found single stream with headers service=\(module.metadata.sourceName)", type: "Stream")
                        self.logStreamSourceDiagnostics([streamSource], serviceName: module.metadata.sourceName)
                    } else if let streamsArray = json["streams"] as? [String] {
                        streamUrls = streamsArray
                        Logger.shared.log("Found \(streamsArray.count) streams service=\(module.metadata.sourceName)", type: "Stream")
                        self.logPlainStreamDiagnostics(streamsArray, serviceName: module.metadata.sourceName)
                    } else if let streamUrl = json["stream"] as? String {
                        streamUrls = [streamUrl]
                        Logger.shared.log("Found single stream service=\(module.metadata.sourceName)", type: "Stream")
                        self.logPlainStreamDiagnostics([streamUrl], serviceName: module.metadata.sourceName)
                    }
                    
                    if let subsArray = json["subtitles"] as? [String] {
                        subtitleUrls = subsArray
                        Logger.shared.log("Found \(subsArray.count) subtitle tracks service=\(module.metadata.sourceName)", type: "Stream")
                    } else if let subtitleUrl = json["subtitles"] as? String {
                        subtitleUrls = [subtitleUrl]
                        Logger.shared.log("Found single subtitle track service=\(module.metadata.sourceName)", type: "Stream")
                    }
                    
                    Logger.shared.log("Service stream extraction completed service=\(module.metadata.sourceName) plainStreams=\(streamUrls?.count ?? 0) structuredSources=\(streamUrlsAndHeaders?.count ?? 0) subtitles=\(subtitleUrls?.count ?? 0)", type: "Stream")
                    finish((streamUrls, subtitleUrls, streamUrlsAndHeaders), "resolved")
                    return
                }
                
                if let streamsArray = try JSONSerialization.jsonObject(with: data, options: []) as? [String] {
                    Logger.shared.log("Starting multi-stream with \(streamsArray.count) sources service=\(module.metadata.sourceName)", type: "Stream")
                    finish((streamsArray, nil, nil), "resolved-array")
                    return
                }
            } catch {
                Logger.shared.log("Stream JSON parsing error service=\(module.metadata.sourceName): \(error.localizedDescription)", type: "Error")
            }
            
            Logger.shared.log("Starting stream from raw string service=\(module.metadata.sourceName) target=\(ServiceSandboxState.redactedURL(jsonString))", type: "Stream")
            finish(([jsonString], nil, nil), "raw-string")
        }
        
        let catchBlock: @convention(block) (JSValue) -> Void = { _ in
            Logger.shared.log("Service stream promise rejected; untrusted body suppressed", type: "Error")
            finish(emptyResult, "rejected")
        }
        
        let thenFunction = JSValue(object: thenBlock, in: context)
        let catchFunction = JSValue(object: catchBlock, in: context)
        
        guard let thenFunction = thenFunction, let catchFunction = catchFunction else {
            Logger.shared.log("Failed to create JSValue objects for stream Promise handling service=\(module.metadata.sourceName)", type: "Error")
            finish(emptyResult, "handler-create-failed")
            return request
        }
        
        promise.invokeMethod("then", withArguments: [thenFunction])
        promise.invokeMethod("catch", withArguments: [catchFunction])
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
        let tail = url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent
        return "#\(index) host=\(url.host ?? "nil") ext=\(ext) tail=\(tail)"
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
