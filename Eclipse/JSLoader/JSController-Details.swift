import JavaScriptCore

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

extension JSController {
    func fetchDetailsJS(url: String, module: Service? = nil, completion: @escaping ([MediaItem], [EpisodeLink]) -> Void) {
        guard let url = URL(string: url) else {
            Logger.shared.log("Service detail rejected an invalid URL; value suppressed", type: "Error")
            completion([], [])
            return
        }

        let operation = module.map {
            beginServiceOperation(service: $0, operation: "extractDetails", primaryURL: url.absoluteString)
        }

        func endOperation(reason: String) {
            if let operation {
                self.endServiceOperation(operation, reason: reason)
            }
        }
        
        if context.exception != nil {
            Logger.shared.log("Service detail JavaScript exception; untrusted body suppressed", type: "Error")
            endOperation(reason: "exception")
            completion([], [])
            return
        }
        
        guard let extractDetailsFunction = context.objectForKeyedSubscript("extractDetails") else {
            Logger.shared.log("No JavaScript function extractDetails found service=\(module?.metadata.sourceName ?? "unknown")", type: "Error")
            endOperation(reason: "missing-details-function")
            completion([], [])
            return
        }
        
        guard let extractEpisodesFunction = context.objectForKeyedSubscript("extractEpisodes") else {
            Logger.shared.log("No JavaScript function extractEpisodes found service=\(module?.metadata.sourceName ?? "unknown")", type: "Error")
            endOperation(reason: "missing-episodes-function")
            completion([], [])
            return
        }
        
        var resultItems: [MediaItem] = []
        var episodeLinks: [EpisodeLink] = []
        
        let dispatchGroup = DispatchGroup()
        
        dispatchGroup.enter()
        var hasLeftDetailsGroup = false
        let detailsGroupQueue = DispatchQueue(label: "details.group")
        
        let promiseValueDetails = extractDetailsFunction.call(withArguments: [url.absoluteString])
        guard let promiseDetails = promiseValueDetails else {
            Logger.shared.log("extractDetails did not return a Promise service=\(module?.metadata.sourceName ?? "unknown")", type: "Error")
            detailsGroupQueue.sync {
                guard !hasLeftDetailsGroup else { return }
                hasLeftDetailsGroup = true
                dispatchGroup.leave()
            }
            endOperation(reason: "invalid-details-promise")
            completion([], [])
            return
        }
        
        let thenBlockDetails: @convention(block) (JSValue) -> Void = { result in
            detailsGroupQueue.sync {
                guard !hasLeftDetailsGroup else {
                    Logger.shared.log("extractDetails: thenBlock called but group already left", type: "Debug")
                    return
                }
                hasLeftDetailsGroup = true
                
                if let jsonOfDetails = result.toString(),
                   let dataDetails = jsonOfDetails.data(using: .utf8) {
                    do {
                        if let array = try JSONSerialization.jsonObject(with: dataDetails, options: []) as? [[String: Any]] {
                            resultItems = array.map { item -> MediaItem in
                                MediaItem(
                                    description: item["description"] as? String ?? "",
                                    aliases: item["aliases"] as? String ?? "",
                                    airdate: item["airdate"] as? String ?? ""
                                )
                            }
                        } else {
                            Logger.shared.log("Failed to parse JSON of extractDetails service=\(module?.metadata.sourceName ?? "unknown")", type: "Error")
                        }
                    } catch {
                        Logger.shared.log("JSON parsing error of extractDetails service=\(module?.metadata.sourceName ?? "unknown"): \(error)", type: "Error")
                    }
                } else {
                    Logger.shared.log("Result is not a string of extractDetails service=\(module?.metadata.sourceName ?? "unknown")", type: "Error")
                }
                dispatchGroup.leave()
            }
        }
        
        let catchBlockDetails: @convention(block) (JSValue) -> Void = { _ in
            detailsGroupQueue.sync {
                guard !hasLeftDetailsGroup else {
                    Logger.shared.log("extractDetails: catchBlock called but group already left", type: "Debug")
                    return
                }
                hasLeftDetailsGroup = true
                
                Logger.shared.log("Service detail promise rejected; untrusted body suppressed", type: "Error")
                dispatchGroup.leave()
            }
        }
        
        let thenFunctionDetails = JSValue(object: thenBlockDetails, in: context)
        let catchFunctionDetails = JSValue(object: catchBlockDetails, in: context)
        
        promiseDetails.invokeMethod("then", withArguments: [thenFunctionDetails as Any])
        promiseDetails.invokeMethod("catch", withArguments: [catchFunctionDetails as Any])
        
        dispatchGroup.enter()
        let promiseValueEpisodes = extractEpisodesFunction.call(withArguments: [url.absoluteString])
        
        var hasLeftEpisodesGroup = false
        let episodesGroupQueue = DispatchQueue(label: "episodes.group")
        
        let timeoutWorkItem = DispatchWorkItem {
            Logger.shared.log("Timeout for extractEpisodes service=\(module?.metadata.sourceName ?? "unknown")", type: "Warning")
            episodesGroupQueue.sync {
                guard !hasLeftEpisodesGroup else {
                    Logger.shared.log("extractEpisodes: timeout called but group already left", type: "Debug")
                    return
                }
                hasLeftEpisodesGroup = true
                dispatchGroup.leave()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: timeoutWorkItem)
        
        guard let promiseEpisodes = promiseValueEpisodes else {
            Logger.shared.log("extractEpisodes did not return a Promise service=\(module?.metadata.sourceName ?? "unknown")", type: "Error")
            timeoutWorkItem.cancel()
            episodesGroupQueue.sync {
                guard !hasLeftEpisodesGroup else { return }
                hasLeftEpisodesGroup = true
                dispatchGroup.leave()
            }
            endOperation(reason: "invalid-episodes-promise")
            completion([], [])
            return
        }
        
        let thenBlockEpisodes: @convention(block) (JSValue) -> Void = { result in
            timeoutWorkItem.cancel()
            episodesGroupQueue.sync {
                guard !hasLeftEpisodesGroup else {
                    Logger.shared.log("extractEpisodes: thenBlock called but group already left", type: "Debug")
                    return
                }
                hasLeftEpisodesGroup = true
                
                if let jsonOfEpisodes = result.toString(),
                   let dataEpisodes = jsonOfEpisodes.data(using: .utf8) {
                    do {
                        if let array = try JSONSerialization.jsonObject(with: dataEpisodes, options: []) as? [[String: Any]] {
                            episodeLinks = array.map { item -> EpisodeLink in
                                EpisodeLink(
                                    number: item["number"] as? Int ?? 0,
                                    title: "",
                                    href: item["href"] as? String ?? "",
                                    duration: nil
                                )
                            }
                        } else {
                            Logger.shared.log("Failed to parse JSON of extractEpisodes service=\(module?.metadata.sourceName ?? "unknown")", type: "Error")
                        }
                    } catch {
                        Logger.shared.log("JSON parsing error of extractEpisodes service=\(module?.metadata.sourceName ?? "unknown"): \(error)", type: "Error")
                    }
                } else {
                    Logger.shared.log("Result is not a string of extractEpisodes service=\(module?.metadata.sourceName ?? "unknown")", type: "Error")
                }
                dispatchGroup.leave()
            }
        }
        
        let catchBlockEpisodes: @convention(block) (JSValue) -> Void = { _ in
            timeoutWorkItem.cancel()
            episodesGroupQueue.sync {
                guard !hasLeftEpisodesGroup else {
                    Logger.shared.log("extractEpisodes: catchBlock called but group already left", type: "Debug")
                    return
                }
                hasLeftEpisodesGroup = true
                
                Logger.shared.log("Service episodes promise rejected; untrusted body suppressed", type: "Error")
                dispatchGroup.leave()
            }
        }
        
        let thenFunctionEpisodes = JSValue(object: thenBlockEpisodes, in: context)
        let catchFunctionEpisodes = JSValue(object: catchBlockEpisodes, in: context)
        
        promiseEpisodes.invokeMethod("then", withArguments: [thenFunctionEpisodes as Any])
        promiseEpisodes.invokeMethod("catch", withArguments: [catchFunctionEpisodes as Any])
        
        dispatchGroup.notify(queue: .main) {
            Logger.shared.log("Service details completed service=\(module?.metadata.sourceName ?? "unknown") details=\(resultItems.count) episodes=\(episodeLinks.count)", type: "Service")
            endOperation(reason: "resolved")
            completion(resultItems, episodeLinks)
        }
    }
    
    func fetchEpisodesJS(url: String, module: Service, completion: @escaping ([EpisodeLink]) -> Void) {
        guard let url = URL(string: url) else {
            Logger.shared.log("Service episodes rejected an invalid URL; value suppressed", type: "Error")
            completion([])
            return
        }

        let operation = beginServiceOperation(service: module, operation: "extractEpisodes", primaryURL: url.absoluteString)
        
        if context.exception != nil {
            Logger.shared.log("Service episodes JavaScript exception; untrusted body suppressed", type: "Error")
            endServiceOperation(operation, reason: "exception")
            completion([])
            return
        }
        
        guard let extractEpisodesFunction = context.objectForKeyedSubscript("extractEpisodes") else {
            Logger.shared.log("No JavaScript function extractEpisodes found service=\(module.metadata.sourceName)", type: "Error")
            endServiceOperation(operation, reason: "missing-function")
            completion([])
            return
        }
        
        var episodeLinks: [EpisodeLink] = []
        
        let promiseValueEpisodes = extractEpisodesFunction.call(withArguments: [url.absoluteString])
        
        var hasCompleted = false
        let completionQueue = DispatchQueue(label: "episodes.completion")
        
        let timeoutWorkItem = DispatchWorkItem {
            Logger.shared.log("Timeout for extractEpisodes service=\(module.metadata.sourceName)", type: "Warning")
            completionQueue.sync {
                guard !hasCompleted else {
                    Logger.shared.log("extractEpisodes: timeout called but already completed", type: "Debug")
                    return
                }
                hasCompleted = true
                self.endServiceOperation(operation, reason: "timeout")
                DispatchQueue.main.async {
                    completion([])
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: timeoutWorkItem)
        
        guard let promiseEpisodes = promiseValueEpisodes else {
            Logger.shared.log("extractEpisodes did not return a Promise service=\(module.metadata.sourceName)", type: "Error")
            timeoutWorkItem.cancel()
            endServiceOperation(operation, reason: "invalid-promise")
            completion([])
            return
        }
        
        let thenBlockEpisodes: @convention(block) (JSValue) -> Void = { result in
            timeoutWorkItem.cancel()
            completionQueue.sync {
                guard !hasCompleted else {
                    Logger.shared.log("extractEpisodes: thenBlock called but already completed", type: "Debug")
                    return
                }
                hasCompleted = true
                
                if let jsonOfEpisodes = result.toString(),
                   let dataEpisodes = jsonOfEpisodes.data(using: .utf8) {
                    do {
                        if let array = try JSONSerialization.jsonObject(with: dataEpisodes, options: []) as? [[String: Any]] {
                            episodeLinks = array.map { item -> EpisodeLink in
                                EpisodeLink(
                                    number: item["number"] as? Int ?? 0,
                                    title: "",
                                    href: item["href"] as? String ?? "",
                                    duration: nil
                                )
                            }
                        } else {
                            Logger.shared.log("Failed to parse JSON of extractEpisodes service=\(module.metadata.sourceName)", type: "Error")
                        }
                    } catch {
                        Logger.shared.log("JSON parsing error of extractEpisodes service=\(module.metadata.sourceName): \(error)", type: "Error")
                    }
                } else {
                    Logger.shared.log("Result is not a string of extractEpisodes service=\(module.metadata.sourceName)", type: "Error")
                }

                Logger.shared.log("Service episodes completed service=\(module.metadata.sourceName) episodeCount=\(episodeLinks.count) target=\(ServiceSandboxState.redactedURL(url.absoluteString))", type: "Service")
                self.endServiceOperation(operation, reason: "resolved")

                let resolvedEpisodeLinks = episodeLinks
                DispatchQueue.main.async {
                    completion(resolvedEpisodeLinks)
                }
            }
        }
        
        let catchBlockEpisodes: @convention(block) (JSValue) -> Void = { _ in
            timeoutWorkItem.cancel()
            completionQueue.sync {
                guard !hasCompleted else {
                    Logger.shared.log("extractEpisodes: catchBlock called but already completed", type: "Debug")
                    return
                }
                hasCompleted = true
                
                Logger.shared.log("Service episodes promise rejected; untrusted body suppressed", type: "Error")
                self.endServiceOperation(operation, reason: "rejected")
                DispatchQueue.main.async {
                    completion([])
                }
            }
        }
        
        let thenFunctionEpisodes = JSValue(object: thenBlockEpisodes, in: context)
        let catchFunctionEpisodes = JSValue(object: catchBlockEpisodes, in: context)
        
        promiseEpisodes.invokeMethod("then", withArguments: [thenFunctionEpisodes as Any])
        promiseEpisodes.invokeMethod("catch", withArguments: [catchFunctionEpisodes as Any])
    }
}
