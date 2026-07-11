import SoraCore
import JavaScriptCore

private let serviceFetchMaximumResponseBytes = 10_000_000

private func serviceFetchErrorDescription(_ error: Error) -> String {
    if error is BoundedURLSessionError {
        return ServiceCompatibilityError.responseTooLarge.localizedDescription
    }
    if error is CancellationError {
        return "Network request cancelled."
    }
    if let urlError = error as? URLError {
        return "Network request failed (\(urlError.code.rawValue))."
    }
    return "Network request failed."
}

extension JSContext {
    func setupConsoleLogging(sandbox: ServiceSandboxState) {
        let consoleObject = JSValue(newObjectIn: self)
        
        let consoleLogFunction: @convention(block) (String) -> Void = { _ in }
        consoleObject?.setObject(consoleLogFunction, forKeyedSubscript: "log" as NSString)
        
        let consoleErrorFunction: @convention(block) (String) -> Void = { _ in
            Logger.shared.log("Service console.error reported; untrusted body suppressed", type: "Error")
        }
        consoleObject?.setObject(consoleErrorFunction, forKeyedSubscript: "error" as NSString)
        
        self.setObject(consoleObject, forKeyedSubscript: "console" as NSString)
        
        let logFunction: @convention(block) (String) -> Void = { _ in }
        self.setObject(logFunction, forKeyedSubscript: "log" as NSString)
    }
    
    func setupNativeFetch(sandbox: ServiceSandboxState) {
        let fetchNativeFunction: @convention(block) (String, [String: String]?, JSValue, JSValue) -> Void = { urlString, headers, resolve, reject in
            guard let url = ServiceSandboxState.validatedHTTPURL(urlString) else {
                Logger.shared.log(
                    "Service fetch rejected non-HTTP target \(sandbox.contextLabel()) target=unsupported-url",
                    type: "Error"
                )
                reject.call(withArguments: [ServiceCompatibilityError.unsupportedTransport.localizedDescription])
                return
            }

            guard let operation = sandbox.allowServiceNetworkRequest(api: "fetch", urlString: urlString) else {
                reject.call(withArguments: ["Service network request blocked by sandbox"])
                return
            }
            var request = URLRequest(url: url)
            if let headers = headers {
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
            CloudflareBypassManager.shared.applyCachedBypass(to: &request, for: url)
            let callResolve: (String) -> Void = { value in
                DispatchQueue.main.async {
                    if !resolve.isUndefined {
                        resolve.call(withArguments: [value])
                    }
                }
            }
            let callReject: (String) -> Void = { message in
                DispatchQueue.main.async {
                    if !reject.isUndefined {
                        reject.call(withArguments: [message])
                    }
                }
            }

            Task {
                do {
                    let (data, response) = try await URLSession.custom.boundedData(
                        for: request,
                        maximumResponseBytes: serviceFetchMaximumResponseBytes
                    )
                    if let text = String(data: data, encoding: .utf8) {
                        if let httpResponse = response as? HTTPURLResponse,
                           CloudflareBypassManager.isChallengeResponse(
                            status: httpResponse.statusCode,
                            body: text,
                            headers: CloudflareBypassManager.headersDictionary(from: httpResponse)
                           ) {
                            Logger.shared.log(
                                "Service fetch hit Cloudflare challenge service=\(operation.serviceName) operation=\(operation.operation) target=\(ServiceSandboxState.redactedURL(httpResponse.url?.absoluteString ?? urlString)) requested=\(ServiceSandboxState.redactedURL(urlString)) \(CloudflareBypassManager.challengeDebugSummary(status: httpResponse.statusCode, body: text, headers: CloudflareBypassManager.headersDictionary(from: httpResponse)))",
                                type: "Service"
                            )
                            if let recovered = await CloudflareBypassManager.shared.recoverChallengedRequest(
                                for: url,
                                method: request.httpMethod ?? "GET",
                                body: request.httpBody,
                                extraHeaders: request.allHTTPHeaderFields ?? [:],
                                allowRedirects: true
                            ), let recoveredText = String(data: recovered.data, encoding: .utf8) {
                                Logger.shared.log(
                                    "Service fetch recovered after Cloudflare verification service=\(operation.serviceName) operation=\(operation.operation) target=\(ServiceSandboxState.redactedURL(urlString)) status=\(recovered.response.statusCode) bytes=\(recovered.data.count)",
                                    type: "Service"
                                )
                                callResolve(recoveredText)
                            } else {
                                callReject(ServiceCompatibilityError.interactiveChallengeRequired.localizedDescription)
                            }
                            return
                        }
                        Logger.shared.log("Service fetch completed service=\(operation.serviceName) operation=\(operation.operation) target=\(ServiceSandboxState.redactedURL(urlString)) status=\((response as? HTTPURLResponse)?.statusCode ?? 0) bytes=\(data.count)", type: "Service")
                        callResolve(text)
                    } else {
                        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
                        Logger.shared.log("Service fetch decode failed service=\(operation.serviceName) operation=\(operation.operation) target=\(ServiceSandboxState.redactedURL(urlString)) status=\((response as? HTTPURLResponse)?.statusCode ?? 0) bytes=\(data.count) contentType=\(contentType)", type: "Error")
                        callReject("Unable to decode data")
                    }
                } catch {
                    let safeError = serviceFetchErrorDescription(error)
                    Logger.shared.log(
                        "Service fetch failed service=\(operation.serviceName) operation=\(operation.operation) target=\(ServiceSandboxState.redactedURL(urlString)) error=\(safeError)",
                        type: "Error"
                    )
                    callReject(safeError)
                }
            }
        }
        self.setObject(fetchNativeFunction, forKeyedSubscript: "fetchNative" as NSString)
        
        let fetchDefinition = """
                        function fetch(url, headers) {
                            return new Promise(function(resolve, reject) {
                                fetchNative(url, headers, resolve, reject);
                            });
                        }
                        """
        self.evaluateScript(fetchDefinition)
    }
    
    func setupFetchV2(sandbox: ServiceSandboxState) {
        let fetchV2NativeFunction: @convention(block) (String, Any?, String?, String?, ObjCBool, String?, JSValue, JSValue) -> Void = { urlString, headersAny, method, body, redirect, encoding, resolve, reject in
            let callResolveEarly: ([String: Any]) -> Void = { dict in
                DispatchQueue.main.async {
                    if !resolve.isUndefined {
                        resolve.call(withArguments: [dict])
                    }
                }
            }

            guard let url = ServiceSandboxState.validatedHTTPURL(urlString) else {
                Logger.shared.log(
                    "Service fetchv2 rejected non-HTTP target \(sandbox.contextLabel()) target=unsupported-url",
                    type: "Error"
                )
                callResolveEarly([
                    "status": 0,
                    "headers": [:],
                    "body": "",
                    "error": ServiceCompatibilityError.unsupportedTransport.localizedDescription
                ])
                return
            }

            guard let operation = sandbox.allowServiceNetworkRequest(api: "fetchv2", urlString: urlString) else {
                callResolveEarly([
                    "status": 0,
                    "headers": [:],
                    "body": "",
                    "error": "Service network request blocked by sandbox"
                ])
                return
            }
            
            var headers: [String: String]? = nil
            
            if let headersAny = headersAny {
                if headersAny is NSNull {
                    headers = nil
                } else if let headersDict = headersAny as? [String: Any] {
                    var safeHeaders: [String: String] = [:]
                    for (key, value) in headersDict {
                        let stringValue: String
                        if let str = value as? String {
                            stringValue = str
                        } else if let num = value as? NSNumber {
                            stringValue = num.stringValue
                        } else if value is NSNull {
                            continue
                        } else {
                            stringValue = String(describing: value)
                        }
                        safeHeaders[key] = stringValue
                    }
                    headers = safeHeaders.isEmpty ? nil : safeHeaders
                } else if let headersDict = headersAny as? [AnyHashable: Any] {
                    var safeHeaders: [String: String] = [:]
                    for (key, value) in headersDict {
                        let stringKey = String(describing: key)
                        
                        let stringValue: String
                        if let str = value as? String {
                            stringValue = str
                        } else if let num = value as? NSNumber {
                            stringValue = num.stringValue
                        } else if value is NSNull {
                            continue
                        } else {
                            stringValue = String(describing: value)
                        }
                        safeHeaders[stringKey] = stringValue
                    }
                    headers = safeHeaders.isEmpty ? nil : safeHeaders
                } else {
                    Logger.shared.log("Headers argument is not a dictionary, type: \(type(of: headersAny))", type: "Warning")
                    headers = nil
                }
            }
            
            let httpMethod = method ?? "GET"
            var request = URLRequest(url: url)
            request.httpMethod = httpMethod
            
            func getEncoding(from encodingString: String?) -> String.Encoding {
                guard let encodingString = encodingString?.lowercased() else {
                    return .utf8
                }
                
                switch encodingString {
                case "utf-8", "utf8":
                    return .utf8
                case "windows-1251", "cp1251":
                    return .windowsCP1251
                case "windows-1252", "cp1252":
                    return .windowsCP1252
                case "iso-8859-1", "latin1":
                    return .isoLatin1
                case "ascii":
                    return .ascii
                case "utf-16", "utf16":
                    return .utf16
                default:
                    Logger.shared.log("Unknown encoding '\(encodingString)', defaulting to UTF-8", type: "Warning")
                    return .utf8
                }
            }
            
            let textEncoding = getEncoding(from: encoding)
            
            let bodyIsEmpty = body == nil || (body)?.isEmpty == true || body == "null" || body == "undefined"
            
            if httpMethod == "GET" && !bodyIsEmpty {
                Logger.shared.log("Service fetchv2 rejected GET body service=\(operation.serviceName) operation=\(operation.operation) target=\(ServiceSandboxState.redactedURL(urlString))", type: "Error")
                callResolveEarly(["error": "GET request must not have a body"])
                return
            }
            
            if httpMethod != "GET" && !bodyIsEmpty {
                if let bodyString = body {
                    request.httpBody = bodyString.data(using: .utf8)
                }
            }
            
            if let headers = headers {
                for (key, value) in headers {
                    request.setValue(value, forHTTPHeaderField: key)
                }
            }
            CloudflareBypassManager.shared.applyCachedBypass(to: &request, for: url)
            
            let session = URLSession.fetchData(allowRedirects: redirect.boolValue)
            let callResolve: ([String: Any]) -> Void = { dict in
                DispatchQueue.main.async {
                    if !resolve.isUndefined {
                        resolve.call(withArguments: [dict])
                    } else {
                        Logger.shared.log("Resolve callback is undefined", type: "Error")
                    }
                }
            }

            Task {
                defer { session.finishTasksAndInvalidate() }

                do {
                    let (data, response) = try await session.boundedData(
                        for: request,
                        maximumResponseBytes: serviceFetchMaximumResponseBytes
                    )

                    func resolveResponse(data: Data, httpResponse: HTTPURLResponse?) {
                        let status = httpResponse?.statusCode ?? 0
                        var responseDict: [String: Any] = [
                            "status": status,
                            "ok": status >= 200 && status < 300,
                            "url": httpResponse?.url?.absoluteString ?? urlString,
                            "headers": CloudflareBypassManager.headersDictionary(from: httpResponse),
                            "body": ""
                        ]

                        if let text = String(data: data, encoding: textEncoding) {
                            responseDict["body"] = text
                            Logger.shared.log("Service fetchv2 completed service=\(operation.serviceName) operation=\(operation.operation) target=\(ServiceSandboxState.redactedURL(urlString)) status=\(status) bytes=\(data.count)", type: "Service")
                            callResolve(responseDict)
                        } else {
                            Logger.shared.log("Service fetchv2 decode warning service=\(operation.serviceName) operation=\(operation.operation) target=\(ServiceSandboxState.redactedURL(urlString)) encoding=\(encoding ?? "utf-8") status=\(status) bytes=\(data.count); trying UTF-8 fallback", type: "Warning")
                            if let fallbackText = String(data: data, encoding: .utf8) {
                                responseDict["body"] = fallbackText
                                Logger.shared.log("Service fetchv2 completed after UTF-8 fallback service=\(operation.serviceName) operation=\(operation.operation) target=\(ServiceSandboxState.redactedURL(urlString)) status=\(status) bytes=\(data.count)", type: "Service")
                                callResolve(responseDict)
                            } else {
                                let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
                                Logger.shared.log("Service fetchv2 decode failed service=\(operation.serviceName) operation=\(operation.operation) target=\(ServiceSandboxState.redactedURL(urlString)) status=\(status) bytes=\(data.count) contentType=\(contentType)", type: "Error")
                                callResolve(responseDict)
                            }
                        }
                    }

                    let httpResponse = response as? HTTPURLResponse
                    let responseText = String(data: data, encoding: textEncoding) ?? String(data: data, encoding: .utf8) ?? ""
                    if let httpResponse {
                        let responseHeaders = CloudflareBypassManager.headersDictionary(from: httpResponse)
                        if CloudflareBypassManager.isChallengeResponse(
                            status: httpResponse.statusCode,
                            body: responseText,
                            headers: responseHeaders
                        ) {
                            // The response URL may be Cloudflare's challenge/landing redirect,
                            // not the content URL the service asked for. Recover and retry the
                            // original request identity so a provider landing page cannot be
                            // parsed as the selected episode.
                            let challengeResponseURL = httpResponse.url ?? url
                            Logger.shared.log(
                                "Service fetchv2 hit Cloudflare challenge service=\(operation.serviceName) operation=\(operation.operation) target=\(ServiceSandboxState.redactedURL(challengeResponseURL.absoluteString)) requested=\(ServiceSandboxState.redactedURL(url.absoluteString)) \(CloudflareBypassManager.challengeDebugSummary(status: httpResponse.statusCode, body: responseText, headers: responseHeaders))",
                                type: "Service"
                            )
                            Task {
                                if let recovered = await CloudflareBypassManager.shared.recoverChallengedRequest(
                                    for: url,
                                    method: request.httpMethod ?? httpMethod,
                                    body: request.httpBody,
                                    extraHeaders: request.allHTTPHeaderFields ?? [:],
                                    allowRedirects: redirect.boolValue
                                ) {
                                    resolveResponse(data: recovered.data, httpResponse: recovered.response)
                                } else {
                                    callResolve([
                                        "status": httpResponse.statusCode,
                                        "ok": false,
                                        "url": url.absoluteString,
                                        "headers": [:],
                                        "body": "",
                                        "error": ServiceCompatibilityError.interactiveChallengeRequired.localizedDescription
                                    ])
                                }
                            }
                            return
                        }
                    }

                    resolveResponse(data: data, httpResponse: httpResponse)
                    
                } catch {
                    let safeError = serviceFetchErrorDescription(error)
                    Logger.shared.log(
                        "Service fetchv2 failed service=\(operation.serviceName) operation=\(operation.operation) target=\(ServiceSandboxState.redactedURL(urlString)) error=\(safeError)",
                        type: "Error"
                    )
                    callResolve(["error": safeError])
                }
            }
        }
        
        self.setObject(fetchV2NativeFunction, forKeyedSubscript: "fetchV2Native" as NSString)
        
        let fetchv2Definition = """
            function fetchv2(url, headers = {}, method = "GET", body = null, redirect = true, encoding) {
                
                var processedBody = null;
                if(method != "GET") {
                    processedBody = (body && (typeof body === 'object')) ? JSON.stringify(body) : (body || null)
                }
                
                var finalEncoding = encoding || "utf-8";
                
                // Ensure headers is an object and not null/undefined
                var processedHeaders = {};
                if (headers && typeof headers === 'object' && !Array.isArray(headers)) {
                    processedHeaders = headers;
                }
            
                return new Promise(function(resolve, reject) {
                    fetchV2Native(url, processedHeaders, method, processedBody, redirect, finalEncoding, function(rawText) {
                        const responseObj = {
                            headers: rawText.headers,
                            status: rawText.status,
                            ok: rawText.ok || (rawText.status >= 200 && rawText.status < 300),
                            url: rawText.url || url,
                            error: rawText.error || null,
                            _data: rawText.body,
                            text: function() {
                                return Promise.resolve(this._data);
                            },
                            json: function() {
                                try {
                                    return Promise.resolve(JSON.parse(this._data));
                                } catch (e) {
                                    return Promise.reject("JSON parse error: " + e.message);
                                }
                            }
                        };
                        resolve(responseObj);
                    }, reject);
                });
            }
            """
        self.evaluateScript(fetchv2Definition)
    }

    func setupFetchAliases() {
        let fetchAliasDefinition = """
            function soraFetch(url, options) {
                var headers = {};
                var method = "GET";
                var body = null;
                var redirect = true;
                var encoding = undefined;

                if (options) {
                    if (
                        options.headers !== undefined ||
                        options.method !== undefined ||
                        options.body !== undefined ||
                        options.redirect !== undefined ||
                        options.encoding !== undefined
                    ) {
                        headers = options.headers || {};
                        method = options.method || "GET";
                        body = options.body || null;
                        redirect = options.redirect !== undefined ? options.redirect : true;
                        encoding = options.encoding;
                    } else if (typeof options === "object" && !Array.isArray(options)) {
                        headers = options;
                    }
                }

                return fetchv2(url, headers, method, body, redirect, encoding);
            }

            function fetch(url, options) {
                return soraFetch(url, options);
            }
            """
        self.evaluateScript(fetchAliasDefinition)
    }

    func setupSoraCompatibility() {
        let validationToken = "eclipse-cranci-1"
        let tokenFunction: @convention(block) () -> String = { validationToken }
        self.setObject(tokenFunction, forKeyedSubscript: "_0xB4F2" as NSString)

        let compatibilityDefinition = """
            if (typeof sendLog === "undefined") {
                function sendLog(message) {
                    if (typeof console !== "undefined" && console.log) {
                        console.log("[Module] " + message);
                    }
                }
            }
            """
        self.evaluateScript(compatibilityDefinition)
    }

    func setupTimerFunctions() {
        var timers: [Int: DispatchWorkItem] = [:]
        var nextTimerId = 1

        let setTimeoutFunction: @convention(block) (JSValue?, Double) -> Int = { callback, delay in
            let id = nextTimerId
            nextTimerId += 1
            guard let callback, !callback.isUndefined, !callback.isNull else {
                return id
            }

            let item = DispatchWorkItem {
                timers.removeValue(forKey: id)
                callback.call(withArguments: [])
            }
            timers[id] = item
            DispatchQueue.main.asyncAfter(deadline: .now() + max(delay, 0) / 1000.0, execute: item)
            return id
        }

        let clearTimerFunction: @convention(block) (Int) -> Void = { id in
            timers[id]?.cancel()
            timers.removeValue(forKey: id)
        }

        let setIntervalFunction: @convention(block) (JSValue?, Double) -> Int = { callback, delay in
            let id = nextTimerId
            nextTimerId += 1
            guard let callback, !callback.isUndefined, !callback.isNull else {
                return id
            }

            let interval = max(delay, 16) / 1000.0
            func schedule() {
                guard timers[id] != nil else { return }
                let item = DispatchWorkItem {
                    guard timers[id] != nil else { return }
                    callback.call(withArguments: [])
                    schedule()
                }
                timers[id] = item
                DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: item)
            }

            timers[id] = DispatchWorkItem {}
            schedule()
            return id
        }

        self.setObject(setTimeoutFunction, forKeyedSubscript: "setTimeout" as NSString)
        self.setObject(clearTimerFunction, forKeyedSubscript: "clearTimeout" as NSString)
        self.setObject(setIntervalFunction, forKeyedSubscript: "setInterval" as NSString)
        self.setObject(clearTimerFunction, forKeyedSubscript: "clearInterval" as NSString)
    }
    
    func setupBase64Functions() {
        let btoaFunction: @convention(block) (String) -> String? = { data in
            guard let data = data.data(using: .utf8) else {
                Logger.shared.log("btoa: Failed to encode input as UTF-8", type: "Error")
                return nil
            }
            return data.base64EncodedString()
        }
        
        let atobFunction: @convention(block) (String) -> String? = { base64String in
            guard let data = Data(base64Encoded: base64String) else {
                Logger.shared.log("atob: Invalid base64 input", type: "Error")
                return nil
            }
            
            return String(data: data, encoding: .utf8)
        }
        
        self.setObject(btoaFunction, forKeyedSubscript: "btoa" as NSString)
        self.setObject(atobFunction, forKeyedSubscript: "atob" as NSString)
    }
    
    func setupScrapingUtilities() {
        let scrapingUtils = """
        function getElementsByTag(html, tag) {
            const regex = new RegExp(`<${tag}[^>]*>([\\s\\S]*?)<\\/${tag}>`, 'gi');
            let result = [];
            let match;
            while ((match = regex.exec(html)) !== null) {
                result.push(match[1]);
            }
            return result;
        }
        function getAttribute(html, tag, attr) {
            const regex = new RegExp(`<${tag}[^>]*${attr}=[\"']?([^\"' >]+)[\"']?[^>]*>`, 'i');
            const match = regex.exec(html);
            return match ? match[1] : null;
        }
        function getInnerText(html) {
            return html.replace(/<[^>]+>/g, '').replace(/\\s+/g, ' ').trim();
        }
        function extractBetween(str, start, end) {
            const s = str.indexOf(start);
            if (s === -1) return '';
            const e = str.indexOf(end, s + start.length);
            if (e === -1) return '';
            return str.substring(s + start.length, e);
        }
        function stripHtml(html) {
            return html.replace(/<[^>]+>/g, '');
        }
        function normalizeWhitespace(str) {
            return str.replace(/\\s+/g, ' ').trim();
        }
        function urlEncode(str) {
            return encodeURIComponent(str);
        }
        function urlDecode(str) {
            try { return decodeURIComponent(str); } catch (e) { return str; }
        }
        function htmlEntityDecode(str) {
            return str.replace(/&([a-zA-Z]+);/g, function(_, entity) {
                const entities = { quot: '"', apos: "'", amp: '&', lt: '<', gt: '>' };
                return entities[entity] || _;
            });
        }
        function transformResponse(response, fn) {
            try { return fn(response); } catch (e) { return response; }
        }
        """
        self.evaluateScript(scrapingUtils)
    }

    func setupJavaScriptEnvironment(sandbox: ServiceSandboxState) {
        setupWeirdCode()
        setupConsoleLogging(sandbox: sandbox)
        setupNativeFetch(sandbox: sandbox)
        setupNetworkFetch(sandbox: sandbox)
        setupNetworkFetchSimple(sandbox: sandbox)
        setupFetchV2(sandbox: sandbox)
        setupFetchAliases()
        setupSoraCompatibility()
        setupTimerFunctions()
        setupBase64Functions()
        setupScrapingUtilities()
    }
}
