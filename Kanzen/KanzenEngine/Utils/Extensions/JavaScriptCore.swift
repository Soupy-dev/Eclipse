//
//  JavaScriptCore.swift
//  Kanzen
//
//  Created by Dawud Osman on 13/05/2025.
//

import JavaScriptCore
import Foundation

private enum LegacyKanzenNetworkError: Error {
    case invalidURL
    case invalidMethod
    case invalidHeaders
    case requestBodyTooLarge
    case responseTooLarge
}

enum LegacyKanzenNetworkPolicy {
    static let maximumRequestBodyBytes = 2 * 1_024 * 1_024
    static let maximumResponseBytes = 8 * 1_024 * 1_024
    static let maximumRedirects = 10
    static let maximumTimerDelayMilliseconds: Double = 3_600_000
    private static let allowedMethods: Set<String> = [
        "GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"
    ]

    static func boundedTimerDelayMilliseconds(_ rawValue: Double) -> Double? {
        guard rawValue.isFinite else { return nil }
        return min(max(rawValue, 0), maximumTimerDelayMilliseconds)
    }

    static func validatedHTTPURL(_ rawValue: String) throws -> URL {
        guard rawValue.utf8.count <= 16 * 1_024,
              let url = URL(string: rawValue),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil,
              url.user == nil,
              url.password == nil else {
            throw LegacyKanzenNetworkError.invalidURL
        }
        return url
    }

    static func normalizedMethod(_ rawValue: String?) throws -> String {
        let method = (rawValue ?? "GET")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard allowedMethods.contains(method) else {
            throw LegacyKanzenNetworkError.invalidMethod
        }
        return method
    }

    static func requestBody(_ rawValue: String?, method: String) throws -> Data? {
        let isEmpty = rawValue == nil
            || rawValue?.isEmpty == true
            || rawValue == "null"
            || rawValue == "undefined"
        guard !isEmpty else { return nil }
        guard method != "GET", method != "HEAD",
              let data = rawValue?.data(using: .utf8),
              data.count <= maximumRequestBodyBytes else {
            throw LegacyKanzenNetworkError.requestBodyTooLarge
        }
        return data
    }

    static func stringHeaders(from rawValue: Any?) throws -> [String: String] {
        guard let rawValue, !(rawValue is NSNull) else { return [:] }
        let pairs: [(String, Any)]
        if let dictionary = rawValue as? [String: Any] {
            guard dictionary.count <= 64 else { throw LegacyKanzenNetworkError.invalidHeaders }
            pairs = dictionary.map { ($0.key, $0.value) }
        } else if let dictionary = rawValue as? [AnyHashable: Any] {
            guard dictionary.count <= 64 else { throw LegacyKanzenNetworkError.invalidHeaders }
            pairs = dictionary.map { (String(describing: $0.key), $0.value) }
        } else if let dictionary = rawValue as? [String: String] {
            guard dictionary.count <= 64 else { throw LegacyKanzenNetworkError.invalidHeaders }
            pairs = dictionary.map { ($0.key, $0.value) }
        } else {
            throw LegacyKanzenNetworkError.invalidHeaders
        }

        var result: [String: String] = [:]
        result.reserveCapacity(pairs.count)
        for (key, value) in pairs {
            let stringValue: String
            if let value = value as? String {
                stringValue = value
            } else if let value = value as? NSNumber {
                stringValue = value.stringValue
            } else if value is NSNull {
                continue
            } else {
                throw LegacyKanzenNetworkError.invalidHeaders
            }
            guard key.utf8.count <= 128, stringValue.utf8.count <= 8 * 1_024 else {
                throw LegacyKanzenNetworkError.invalidHeaders
            }
            result[key] = stringValue
        }
        return result
    }

    static func responseHeaders(_ response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        var totalBytes = 0
        let fields = response.allHeaderFields.compactMap { key, value -> (String, String)? in
            guard let name = key as? String else { return nil }
            return (name, value as? String ?? String(describing: value))
        }.sorted { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }

        for (name, value) in fields {
            let lowered = name.lowercased()
            guard result.count < 64,
                  lowered != "set-cookie",
                  lowered != "set-cookie2",
                  name.utf8.count <= 128,
                  value.utf8.count <= 8 * 1_024,
                  !name.contains("\r"), !name.contains("\n"),
                  !value.contains("\r"), !value.contains("\n") else { continue }
            let nextTotal = totalBytes + name.utf8.count + value.utf8.count + 4
            guard nextTotal <= 32 * 1_024 else { break }
            result[name] = value
            totalBytes = nextTotal
        }
        return result
    }

    static func textEncoding(_ rawValue: String?) -> String.Encoding {
        switch rawValue?.lowercased() {
        case "windows-1251", "cp1251": return .windowsCP1251
        case "windows-1252", "cp1252": return .windowsCP1252
        case "iso-8859-1", "latin1": return .isoLatin1
        case "ascii": return .ascii
        case "utf-16", "utf16": return .utf16
        default: return .utf8
        }
    }

    static func perform(
        client: SkyStreamPinnedHTTPClient,
        rawURL: String,
        rawMethod: String?,
        rawHeaders: [String: String],
        rawBody: String?,
        followsRedirects: Bool
    ) async throws -> SkyStreamPinnedHTTPClient.Response {
        let url = try validatedHTTPURL(rawURL)
        let method = try normalizedMethod(rawMethod)
        let body = try requestBody(rawBody, method: method)
        let preparedHeaders: ServicePinnedRequestHeaders
        do {
            preparedHeaders = try ServicePinnedRequestHeaders(rawHeaders, method: method)
        } catch {
            throw LegacyKanzenNetworkError.invalidHeaders
        }
        do {
            return try await client.fetch(
                url.absoluteString,
                purpose: .pluginRequest,
                method: method,
                headers: preparedHeaders.headers,
                body: body,
                byteRange: preparedHeaders.byteRange,
                allowsCookies: true,
                followsRedirects: followsRedirects,
                maximumRedirects: maximumRedirects,
                maximumResponseBytes: maximumResponseBytes,
                maximumRequestBodyBytes: maximumRequestBodyBytes,
                timeout: 30
            )
        } catch SkyStreamSecurityError.responseTooLarge {
            throw LegacyKanzenNetworkError.responseTooLarge
        }
    }

    static func userFacingError(_ error: Error) -> String {
        switch error {
        case LegacyKanzenNetworkError.invalidURL:
            return "Invalid or blocked URL"
        case LegacyKanzenNetworkError.invalidMethod:
            return "Unsupported HTTP method"
        case LegacyKanzenNetworkError.invalidHeaders:
            return "Unsafe request headers"
        case LegacyKanzenNetworkError.requestBodyTooLarge:
            return "Request body is invalid or too large"
        case LegacyKanzenNetworkError.responseTooLarge:
            return "Network response exceeded the size limit"
        case is CancellationError:
            return "Network request cancelled"
        default:
            return "Network request failed"
        }
    }
}

extension JSContext
{
    func setupTimeOut(runtimeState: KanzenLegacyJavaScriptRuntimeState)
    {

        let setTimeout: @convention(block) (JSValue, Double) -> Void = { callback, delay in
            guard !callback.isUndefined, !callback.isNull,
                  let boundedDelay = LegacyKanzenNetworkPolicy.boundedTimerDelayMilliseconds(delay) else {
                return
            }
            runtimeState.scheduleTimer(delayMilliseconds: boundedDelay) {
                callback.call(withArguments: [])
            }
        }

        self.setObject(setTimeout, forKeyedSubscript: "setTimeout" as (NSCopying & NSObjectProtocol))
    }

    func setupBundle()
    {
        guard let jsPath = Bundle.main.path(forResource: "bundle", ofType: "js")
        else{
            ReaderLogger.shared.log("bundle not found",type: "Error")
            return
        }
        do {
            let jsCode = try String(contentsOfFile: jsPath, encoding: .utf8)
            self.evaluateScript(jsCode)
            ReaderLogger.shared.log("bundle loaded successfully")
        } catch {
            ReaderLogger.shared.log("Error loading bundled legacy JavaScript support", type: "Error")
        }

    }

    func setUpConsole()
    {
        let consoleObject = JSValue(newObjectIn: self)
        let consoleLogFunction: @convention(block) (String) -> Void = {
            message in
            ReaderLogger.shared.log("Legacy JavaScript console message omitted length=\(message.utf8.count)", type: "AidokuRuntime")
        }
        let consolePrintFunction: @convention(block) (JSValue) -> Void = {
            message in
            let length = message.toString()?.utf8.count ?? 0
            ReaderLogger.shared.log("Legacy JavaScript console print omitted length=\(length)", type: "AidokuRuntime")
        }

        consoleObject?.setObject(consoleLogFunction, forKeyedSubscript: "log" as NSString)
        consoleObject?.setObject(consolePrintFunction, forKeyedSubscript: "print" as NSString)
        self.setObject(consoleObject, forKeyedSubscript: "console" as NSString)
    }

    func setUpFetch(
        pinnedHTTPClient: SkyStreamPinnedHTTPClient,
        runtimeState: KanzenLegacyJavaScriptRuntimeState
    )
    {
        let fetch: @convention(block) (JSValue,JSValue) -> JSValue = {
            [weak context = self] jsUrl, jsOptions in
            guard let context else {
                return JSValue(undefinedIn: nil)
            }
            guard let urlStr = jsUrl.toString(),
                  (try? LegacyKanzenNetworkPolicy.validatedHTTPURL(urlStr)) != nil else
            {
                return JSValue(newErrorFromMessage: "Invalid URL", in: context)
            }

            guard let promiseConstructor = context.objectForKeyedSubscript("Promise"),
                  !promiseConstructor.isUndefined,
                  !promiseConstructor.isNull else {
                ReaderLogger.shared.log("Promise constructor not found in JSContext", type: "Error")
                return JSValue(newErrorFromMessage: "Promise is not supported", in: context)
            }

            let executor: @convention(block) (@escaping (JSValue) -> Void, @escaping (JSValue) -> Void) -> Void = { [weak context] resolve, reject in
                guard let context else { return }
                var method: String? = "GET"
                var headers: [String: String] = [:]
                var body: String?
                if let options = jsOptions.toDictionary() as? [String: Any]
                {
                    if let value = options["method"] as? String
                    {
                        method = value
                    }
                    if let values = options["headers"] as? [String: String]
                    {
                        headers = values
                    }
                    if let value = options["body"] as? String
                    {
                        body = value
                    }
                }

                guard let nativeLease = runtimeState.reserveNativeOperation() else {
                    reject(JSValue(newErrorFromMessage: "Too many active network requests", in: context))
                    return
                }
                let task = Task { [weak context] in
                    defer { nativeLease.finish() }
                    do {
                        let output = try await LegacyKanzenNetworkPolicy.perform(
                            client: pinnedHTTPClient,
                            rawURL: urlStr,
                            rawMethod: method,
                            rawHeaders: headers,
                            rawBody: body,
                            followsRedirects: true
                        )
                        try Task.checkCancellation()
                        runtimeState.scheduleJavaScript { [weak context] in
                            guard let context else { return }
                            let data = output.data
                            let textFunc: @convention(block) () -> String = {
                                String(data: data, encoding: .utf8) ?? ""
                            }
                            let jsonFunc: @convention(block) () -> JSValue = { [weak context] in
                            guard let context else { return JSValue(undefinedIn: nil) }
                            do{
                                let json = try JSONSerialization.jsonObject(with: data, options: [])
                                return JSValue(object: json, in: context)
                            }
                            catch
                            {
                                ReaderLogger.shared.log("JSON serialization failed",type:"Error")
                            }
                                return JSValue(newErrorFromMessage: "No Data", in: context)
                            }

                            guard let textJs = JSValue(object: textFunc, in: context),
                                  let jsonJs = JSValue(object: jsonFunc, in: context)
                            else {
                                reject(JSValue(newErrorFromMessage: "Failed to create JSValue", in: context))
                                return
                            }
                            let responseObject: [String: Any] = [
                                "status": output.response.statusCode,
                                "headers": LegacyKanzenNetworkPolicy.responseHeaders(output.response),
                                "text": textJs,
                                "json": jsonJs,
                                "data": data.base64EncodedString()
                            ]

                            resolve(JSValue(object: responseObject, in: context))
                        }
                    } catch {
                        let token = servicePinnedNetworkErrorToken(error)
                        ReaderLogger.shared.log(
                            "Legacy JavaScript fetch failed token=\(token)",
                            type: "AidokuNetwork"
                        )
                        let message = LegacyKanzenNetworkPolicy.userFacingError(error)
                        runtimeState.scheduleJavaScript { [weak context] in
                            guard let context else { return }
                            reject(JSValue(newErrorFromMessage: message, in: context))
                        }
                    }
                }
                _ = nativeLease.install(task)

            }

            let promise = JSValue(newPromiseIn: context, fromExecutor: { resolve, reject in
                executor(
                    { value in resolve?.call(withArguments: [value]) },
                    { error in reject?.call(withArguments: [error]) }
                )
            })

            return promise ?? JSValue(newErrorFromMessage: "Promise not supported", in: context)

        }

        self.setObject(fetch, forKeyedSubscript: "fetch" as NSString)
    }

    func setUpJSEnvirontment(runtimeState: KanzenLegacyJavaScriptRuntimeState)
    {
        let pinnedHTTPClient = SkyStreamPinnedHTTPClient()
        setUpFetch(pinnedHTTPClient: pinnedHTTPClient, runtimeState: runtimeState)
        setUpConsole()
        setupBundle()
        setupTimeOut(runtimeState: runtimeState)
    }

    func setUpNovelConsole()
    {
        let consoleObject = JSValue(newObjectIn: self)

        let consoleLogFunction: @convention(block) (String) -> Void = { message in
            ReaderLogger.shared.log("Legacy novel JavaScript console message omitted length=\(message.utf8.count)", type: "AidokuRuntime")
        }
        consoleObject?.setObject(consoleLogFunction, forKeyedSubscript: "log" as NSString)

        let consoleErrorFunction: @convention(block) (String) -> Void = { message in
            ReaderLogger.shared.log("Legacy novel JavaScript console error omitted length=\(message.utf8.count)", type: "Error")
        }
        consoleObject?.setObject(consoleErrorFunction, forKeyedSubscript: "error" as NSString)

        self.setObject(consoleObject, forKeyedSubscript: "console" as NSString)

        let logFunction: @convention(block) (String) -> Void = { message in
            ReaderLogger.shared.log("Legacy JavaScript log omitted length=\(message.utf8.count)", type: "AidokuRuntime")
        }
        self.setObject(logFunction, forKeyedSubscript: "log" as NSString)
    }

    func setUpNovelFetch(
        pinnedHTTPClient: SkyStreamPinnedHTTPClient,
        runtimeState: KanzenLegacyJavaScriptRuntimeState
    )
    {
        let fetchNativeFunction: @convention(block) (String, [String: String]?, JSValue, JSValue) -> Void = { urlString, headers, resolve, reject in
            guard (try? LegacyKanzenNetworkPolicy.validatedHTTPURL(urlString)) != nil else {
                ReaderLogger.shared.log("Legacy JavaScript fetch rejected an invalid URL; value omitted", type: "Error")
                reject.call(withArguments: ["Invalid URL"])
                return
            }
            let callResolve: (String) -> Void = { value in
                runtimeState.scheduleJavaScript {
                    if !resolve.isUndefined {
                        resolve.call(withArguments: [value])
                    }
                }
            }
            let callReject: (String) -> Void = { value in
                runtimeState.scheduleJavaScript {
                    if !reject.isUndefined {
                        reject.call(withArguments: [value])
                    }
                }
            }
            guard let nativeLease = runtimeState.reserveNativeOperation() else {
                callReject("Too many active network requests")
                return
            }
            let task = Task {
                defer { nativeLease.finish() }
                do {
                    let output = try await LegacyKanzenNetworkPolicy.perform(
                        client: pinnedHTTPClient,
                        rawURL: urlString,
                        rawMethod: "GET",
                        rawHeaders: headers ?? [:],
                        rawBody: nil,
                        followsRedirects: true
                    )
                    try Task.checkCancellation()
                    guard let text = String(data: output.data, encoding: .utf8) else {
                        ReaderLogger.shared.log("Unable to decode legacy fetch data to text", type: "Error")
                        callReject("Unable to decode data")
                        return
                    }
                    callResolve(text)
                } catch {
                    ReaderLogger.shared.log(
                        "Legacy JavaScript fetchNative failed token=\(servicePinnedNetworkErrorToken(error))",
                        type: "AidokuNetwork"
                    )
                    callReject(LegacyKanzenNetworkPolicy.userFacingError(error))
                }
            }
            _ = nativeLease.install(task)
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

    func setUpNovelFetchV2(
        pinnedHTTPClient: SkyStreamPinnedHTTPClient,
        runtimeState: KanzenLegacyJavaScriptRuntimeState
    )
    {
        let fetchV2NativeFunction: @convention(block) (String, Any?, String?, String?, ObjCBool, String?, JSValue, JSValue) -> Void = { urlString, headersAny, method, body, redirect, encoding, resolve, reject in
            let callResolve: ([String: Any]) -> Void = { dict in
                runtimeState.scheduleJavaScript {
                    if !resolve.isUndefined {
                        resolve.call(withArguments: [dict])
                    }
                }
            }

            guard (try? LegacyKanzenNetworkPolicy.validatedHTTPURL(urlString)) != nil else {
                ReaderLogger.shared.log("Legacy JavaScript fetchv2 rejected an invalid URL; value omitted", type: "Error")
                callResolve([
                    "status": 0,
                    "headers": [:],
                    "body": "",
                    "error": "Invalid or blocked URL"
                ])
                return
            }

            let headers: [String: String]
            let httpMethod: String
            do {
                headers = try LegacyKanzenNetworkPolicy.stringHeaders(from: headersAny)
                httpMethod = try LegacyKanzenNetworkPolicy.normalizedMethod(method)
                _ = try LegacyKanzenNetworkPolicy.requestBody(body, method: httpMethod)
            } catch {
                callResolve([
                    "status": 0,
                    "headers": [:],
                    "body": "",
                    "error": LegacyKanzenNetworkPolicy.userFacingError(error)
                ])
                return
            }

            let textEncoding = LegacyKanzenNetworkPolicy.textEncoding(encoding)
            guard let nativeLease = runtimeState.reserveNativeOperation() else {
                callResolve([
                    "status": 0,
                    "headers": [:],
                    "body": "",
                    "error": "Too many active network requests"
                ])
                return
            }
            let task = Task {
                defer { nativeLease.finish() }
                do {
                    let output = try await LegacyKanzenNetworkPolicy.perform(
                        client: pinnedHTTPClient,
                        rawURL: urlString,
                        rawMethod: httpMethod,
                        rawHeaders: headers,
                        rawBody: body,
                        followsRedirects: redirect.boolValue
                    )
                    try Task.checkCancellation()
                    var responseDict: [String: Any] = [
                        "status": output.response.statusCode,
                        "headers": LegacyKanzenNetworkPolicy.responseHeaders(output.response),
                        "body": ""
                    ]
                    if let text = String(data: output.data, encoding: textEncoding)
                        ?? String(data: output.data, encoding: .utf8) {
                        responseDict["body"] = text
                    }
                    callResolve(responseDict)
                } catch {
                    ReaderLogger.shared.log(
                        "Legacy JavaScript fetchv2 failed token=\(servicePinnedNetworkErrorToken(error))",
                        type: "AidokuNetwork"
                    )
                    callResolve([
                        "status": 0,
                        "headers": [:],
                        "body": "",
                        "error": LegacyKanzenNetworkPolicy.userFacingError(error)
                    ])
                }
            }
            _ = nativeLease.install(task)
        }

        self.setObject(fetchV2NativeFunction, forKeyedSubscript: "fetchV2Native" as NSString)

        let fetchv2Definition = """
            function fetchv2(url, headers, method, body, redirect, encoding) {
                if (headers === undefined || headers === null) headers = {};
                if (method === undefined || method === null) method = "GET";
                if (body === undefined) body = null;
                if (redirect === undefined || redirect === null) redirect = true;

                var processedBody = null;
                if (method != "GET") {
                    processedBody = (body && (typeof body === 'object')) ? JSON.stringify(body) : (body || null);
                }

                var finalEncoding = encoding || "utf-8";

                var processedHeaders = {};
                if (headers && typeof headers === 'object' && !Array.isArray(headers)) {
                    processedHeaders = headers;
                }

                return new Promise(function(resolve, reject) {
                    fetchV2Native(url, processedHeaders, method, processedBody, redirect, finalEncoding, function(rawText) {
                        var responseObj = {
                            headers: rawText.headers,
                            status: rawText.status,
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

    func setupNovelBase64Functions()
    {
        let btoaFunction: @convention(block) (String) -> String? = { data in
            guard let data = data.data(using: .utf8) else { return nil }
            return data.base64EncodedString()
        }
        let atobFunction: @convention(block) (String) -> String? = { base64String in
            guard let data = Data(base64Encoded: base64String) else { return nil }
            return String(data: data, encoding: .utf8)
        }
        self.setObject(btoaFunction, forKeyedSubscript: "btoa" as NSString)
        self.setObject(atobFunction, forKeyedSubscript: "atob" as NSString)
    }

    func setupNovelScrapingUtilities()
    {
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

    func setUpNovelJSEnvironment(runtimeState: KanzenLegacyJavaScriptRuntimeState)
    {
        let pinnedHTTPClient = SkyStreamPinnedHTTPClient()
        setUpNovelConsole()
        setUpNovelFetch(pinnedHTTPClient: pinnedHTTPClient, runtimeState: runtimeState)
        setUpNovelFetchV2(pinnedHTTPClient: pinnedHTTPClient, runtimeState: runtimeState)
        setupNovelBase64Functions()
        setupNovelScrapingUtilities()
        setupBundle()
        setupTimeOut(runtimeState: runtimeState)
    }
}
