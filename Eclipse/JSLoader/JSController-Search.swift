import JavaScriptCore

struct SearchItem: Identifiable {
    let id = UUID()
    let title: String
    let imageUrl: String
    let href: String
}

extension JSController {
    func fetchJsSearchResults(keyword: String, module: Service, maxResults: Int? = nil, completion: @escaping ([SearchItem]) -> Void) {
        let operation = beginServiceOperation(service: module, operation: "searchResults", primaryURL: keyword)

        if context.exception != nil {
            Logger.shared.log("Service search JavaScript exception; untrusted body suppressed", type: "Error")
            endServiceOperation(operation, reason: "exception")
            completion([])
            return
        }
        
        guard let searchResultsFunction = context.objectForKeyedSubscript("searchResults") else {
            Logger.shared.log("Search function not found in service \(module.metadata.sourceName)", type: "Error")
            endServiceOperation(operation, reason: "missing-function")
            completion([])
            return
        }
        
        let promiseValue = searchResultsFunction.call(withArguments: [keyword])
        guard let promise = promiseValue else {
            Logger.shared.log("Search function returned invalid response service=\(module.metadata.sourceName)", type: "Error")
            endServiceOperation(operation, reason: "invalid-promise")
            completion([])
            return
        }
        
        let thenBlock: @convention(block) (JSValue) -> Void = { result in
            if let jsonString = result.toString(),
               let data = jsonString.data(using: .utf8) {
                do {
                    if let array = try JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]] {
                        let resultItems = array.prefix(maxResults ?? array.count).compactMap { item -> SearchItem? in
                            guard let title = item["title"] as? String,
                                  let imageUrl = item["image"] as? String,
                                  let href = item["href"] as? String else {
                                Logger.shared.log("Invalid search result data format service=\(module.metadata.sourceName)", type: "Error")
                                return nil
                            }
                            return SearchItem(title: title, imageUrl: imageUrl, href: href)
                        }

                        Logger.shared.log("Service search completed service=\(module.metadata.sourceName) query='\(keyword)' rawResults=\(array.count) returnedResults=\(resultItems.count)", type: "Service")
                        self.endServiceOperation(operation, reason: "resolved")
                        
                        DispatchQueue.main.async {
                            completion(resultItems)
                        }
                        
                    } else {
                        Logger.shared.log("Could not parse search JSON response service=\(module.metadata.sourceName)", type: "Error")
                        self.endServiceOperation(operation, reason: "parse-failed")
                        DispatchQueue.main.async {
                            completion([])
                        }
                    }
                } catch {
                    Logger.shared.log("Search JSON parsing error service=\(module.metadata.sourceName): \(error)", type: "Error")
                    self.endServiceOperation(operation, reason: "parse-error")
                    DispatchQueue.main.async {
                        completion([])
                    }
                }
            } else {
                Logger.shared.log("Invalid search result format service=\(module.metadata.sourceName)", type: "Error")
                self.endServiceOperation(operation, reason: "invalid-result")
                DispatchQueue.main.async {
                    completion([])
                }
            }
        }
        
        let catchBlock: @convention(block) (JSValue) -> Void = { _ in
            Logger.shared.log("Service search promise rejected; untrusted body suppressed", type: "Error")
            self.endServiceOperation(operation, reason: "rejected")
            DispatchQueue.main.async {
                completion([])
            }
        }
        
        let thenFunction = JSValue(object: thenBlock, in: context)
        let catchFunction = JSValue(object: catchBlock, in: context)
        
        promise.invokeMethod("then", withArguments: [thenFunction as Any])
        promise.invokeMethod("catch", withArguments: [catchFunction as Any])
    }
}
