//
//  NetworkFetch.swift
//  Sora
//
//  Created by paul on 17/08/2025.
//

import Combine
import Foundation
import JavaScriptCore

enum ServiceResponseTextDecoding {
    static func encoding(named rawName: String?) -> String.Encoding? {
        guard let rawName else { return nil }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return nil }
        switch name {
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
            break
        }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    static func text(
        from data: Data,
        declaredEncoding: String.Encoding,
        response: HTTPURLResponse?
    ) -> (text: String, charset: String)? {
        if let text = String(data: data, encoding: declaredEncoding) {
            return (text, charsetName(for: declaredEncoding))
        }
        if let responseCharset = response?.textEncodingName,
           let responseEncoding = encoding(named: responseCharset),
           responseEncoding != declaredEncoding,
           let text = String(data: data, encoding: responseEncoding) {
            return (text, responseCharset)
        }
        if declaredEncoding != .utf8, let text = String(data: data, encoding: .utf8) {
            return (text, "utf-8")
        }
        return nil
    }

    private static func charsetName(for encoding: String.Encoding) -> String {
        let cfEncoding = CFStringConvertNSStringEncodingToEncoding(encoding.rawValue)
        guard cfEncoding != kCFStringEncodingInvalidId,
              let name = CFStringConvertEncodingToIANACharSetName(cfEncoding) else {
            return "unknown"
        }
        return name as String
    }
}

enum ServiceBrowserOutputBoundary {
    enum RequestDisposition: Equatable {
        case appended
        case duplicate
        case truncated
    }

    static let maximumRequestCount = 1_024
    static let maximumRequestURLBytes = 16 * 1_024
    static let maximumRequestTotalBytes = 1_024 * 1_024
    static let maximumHTMLBytes = 12 * 1_024 * 1_024

    static func appendRequest(
        _ urlString: String,
        to requests: inout [String],
        totalBytes: inout Int
    ) -> RequestDisposition {
        if requests.contains(urlString) { return .duplicate }
        let byteCount = urlString.utf8.count
        guard !urlString.isEmpty,
              requests.count < maximumRequestCount,
              byteCount <= maximumRequestURLBytes,
              byteCount <= maximumRequestTotalBytes,
              totalBytes <= maximumRequestTotalBytes - byteCount else {
            return .truncated
        }
        requests.append(urlString)
        totalBytes += byteCount
        return .appended
    }

    static func boundedURLString(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= maximumRequestURLBytes else {
            return nil
        }
        return value
    }

    static func boundedHTMLPrefix(_ value: String) -> (html: String, truncated: Bool) {
        guard value.utf8.count > maximumHTMLBytes else { return (value, false) }
        var data = Data(value.utf8.prefix(maximumHTMLBytes))
        while !data.isEmpty {
            if let prefix = String(data: data, encoding: .utf8) {
                return (prefix, true)
            }
            data.removeLast()
        }
        return ("", true)
    }

    /// The scan happens inside WebKit so no more than maximumHTMLBytes is bridged
    /// back to the app process, even when a hostile document has an enormous DOM.
    static let boundedHTMLCaptureScript = """
    (function() {
        const source = document.documentElement ? document.documentElement.outerHTML : '';
        const maximumBytes = \(maximumHTMLBytes);
        let bytes = 0;
        let end = 0;
        for (let index = 0; index < source.length;) {
            const first = source.charCodeAt(index);
            let units = 1;
            let width;
            if (first <= 0x7f) {
                width = 1;
            } else if (first <= 0x7ff) {
                width = 2;
            } else if (first >= 0xd800 && first <= 0xdbff
                       && index + 1 < source.length) {
                const second = source.charCodeAt(index + 1);
                if (second >= 0xdc00 && second <= 0xdfff) {
                    units = 2;
                    width = 4;
                } else {
                    width = 3;
                }
            } else {
                width = 3;
            }
            if (bytes + width > maximumBytes) break;
            bytes += width;
            index += units;
            end = index;
        }
        return { html: source.slice(0, end), truncated: end < source.length };
    })()
    """
}

#if !os(tvOS)
import WebKit
#if os(iOS)
import UIKit
#endif

private func serviceWebViewViewportBounds(forUserAgent userAgent: String) -> CGRect {
    let lowerUA = userAgent.lowercased()
    let isMobile = lowerUA.contains("mobile") || lowerUA.contains("iphone") || lowerUA.contains("android")
    #if os(iOS)
    if isMobile {
        return UIScreen.main.bounds
    }
    #endif
    return isMobile
        ? CGRect(x: 0, y: 0, width: 414, height: 896)
        : CGRect(x: 0, y: 0, width: 1920, height: 1080)
}

@MainActor
private final class ServiceBrowserDataStoreRegistry {
    static let shared = ServiceBrowserDataStoreRegistry()
    private static let maximumStores = 256

    private var stores: [String: WKWebsiteDataStore] = [:]
    private var storeOrder: [String] = []
    private var registeredInvalidationScopes: Set<UUID> = []

    func dataStore(for sandbox: ServiceSandboxState) -> WKWebsiteDataStore {
        if let serviceKey = sandbox.browserIsolationKey() {
            if let existing = stores[serviceKey] {
                if let index = storeOrder.firstIndex(of: serviceKey) {
                    storeOrder.remove(at: index)
                    storeOrder.append(serviceKey)
                }
                return existing
            }
            if stores.count >= Self.maximumStores,
               let oldest = storeOrder.first {
                storeOrder.removeFirst()
                stores.removeValue(forKey: oldest)
            }
            let store = WKWebsiteDataStore.nonPersistent()
            stores[serviceKey] = store
            storeOrder.append(serviceKey)
            return store
        }
        let scopeID = sandbox.isolationScopeID
        let scopeKey = scopeID.uuidString
        if let existing = stores[scopeKey] {
            return existing
        }
        let store = WKWebsiteDataStore.nonPersistent()
        stores[scopeKey] = store
        storeOrder.append(scopeKey)
        if registeredInvalidationScopes.insert(scopeID).inserted {
            sandbox.registerInvalidationHandler { [scopeID] in
                Task { @MainActor in
                    ServiceBrowserDataStoreRegistry.shared.remove(scopeID)
                }
            }
        }
        return store
    }

    private func remove(_ scopeID: UUID) {
        let scopeKey = scopeID.uuidString
        stores.removeValue(forKey: scopeKey)
        storeOrder.removeAll { $0 == scopeKey }
        registeredInvalidationScopes.remove(scopeID)
    }
}

enum ServiceBrowserAutomationPolicy {
    enum StaticDecision: Equatable {
        case localDocument
        case web
        case reject
    }

    @MainActor
    static func isolatedConfiguration(
        for sandbox: ServiceSandboxState
    ) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = ServiceBrowserDataStoreRegistry.shared.dataStore(
            for: sandbox
        )
        return configuration
    }

    static func staticDecision(
        for url: URL,
        allowsLocalDocument: Bool
    ) -> StaticDecision {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased() else {
            return .reject
        }
        if allowsLocalDocument,
           components.user == nil,
           components.password == nil,
           (scheme == "about" || scheme == "data" || scheme == "blob") {
            return .localDocument
        }
        guard scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else {
            return .reject
        }
        return .web
    }

    static func permitsNavigation(
        to url: URL,
        allowsLocalDocument: Bool
    ) async -> Bool {
        switch staticDecision(for: url, allowsLocalDocument: allowsLocalDocument) {
        case .localDocument:
            return true
        case .reject:
            return false
        case .web:
            return true
        }
    }

    static func requiresOriginLock(for headers: [String: String]) -> Bool {
        false
    }

    static func boundedHeaders(_ headers: [String: String]) -> [String: String] {
        var accepted: [String: String] = [:]
        var totalBytes = 0
        for (name, value) in headers.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            guard accepted.count < 64,
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
            accepted[name] = value
            totalBytes += entryBytes
        }
        return accepted
    }

    static func secFetchSite(referer: String?, target: URL) -> String {
        guard let referer, !referer.isEmpty else { return "none" }
        guard let refererURL = ServiceModuleURLParser.url(referer) else { return "cross-site" }
        return isSameOrigin(refererURL, target) ? "same-origin" : "cross-site"
    }

    static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = normalizedOrigin(lhs), let right = normalizedOrigin(rhs) else {
            return false
        }
        return left == right
    }

    private static func normalizedOrigin(_ url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else { return nil }
        let port = components.port ?? (scheme == "https" ? 443 : (scheme == "http" ? 80 : -1))
        return "\(scheme)://\(host):\(port)"
    }

    @MainActor
    static func installHTTPSOnlyContentRule(
        in configuration: WKWebViewConfiguration
    ) async -> Bool {
        return true
    }
}

enum ServiceBrowserCookiePolicy {
    static let maximumReturnedCookies = 64
    static let maximumScannedCookies = 4_096

    static func returnedCookies(
        from cookies: [HTTPCookie],
        for url: URL,
        now: Date = Date()
    ) -> [String: String] {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return [:] }
        let requestPath = url.path.isEmpty ? "/" : url.path
        let isSecureRequest = url.scheme?.lowercased() == "https"
        var result: [String: String] = [:]

        for cookie in cookies.prefix(maximumScannedCookies) {
            guard result.count < maximumReturnedCookies,
                  cookie.name.utf8.count <= 256,
                  cookie.value.utf8.count <= 4 * 1_024,
                  cookie.expiresDate.map({ $0 > now }) != false,
                  !cookie.isSecure || isSecureRequest,
                  domain(cookie.domain, matches: host),
                  path(cookie.path, matches: requestPath) else {
                continue
            }
            result[cookie.name] = cookie.value
        }
        return result
    }

    static func returnedCookies(
        from cookies: [HTTPCookie],
        preferring urls: [URL],
        now: Date = Date()
    ) -> [String: String] {
        var result: [String: String] = [:]
        for url in urls {
            for (name, value) in returnedCookies(from: cookies, for: url, now: now) {
                if result[name] != nil || result.count < maximumReturnedCookies {
                    result[name] = value
                }
            }
        }
        for cookie in cookies.prefix(maximumScannedCookies) {
            guard result.count < maximumReturnedCookies,
                  result[cookie.name] == nil,
                  cookie.name.utf8.count <= 256,
                  cookie.value.utf8.count <= 4 * 1_024,
                  cookie.expiresDate.map({ $0 > now }) != false else {
                continue
            }
            result[cookie.name] = cookie.value
        }
        return result
    }

    private static func domain(_ rawDomain: String, matches host: String) -> Bool {
        let permitsSubdomains = rawDomain.hasPrefix(".")
        let domain = rawDomain
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !domain.isEmpty else { return false }
        return host == domain || (permitsSubdomains && host.hasSuffix(".\(domain)"))
    }

    private static func path(_ rawCookiePath: String, matches requestPath: String) -> Bool {
        let cookiePath = rawCookiePath.hasPrefix("/") ? rawCookiePath : "/"
        guard requestPath.hasPrefix(cookiePath) else { return false }
        if requestPath == cookiePath || cookiePath.hasSuffix("/") {
            return true
        }
        let boundaryIndex = requestPath.index(requestPath.startIndex, offsetBy: cookiePath.count)
        return boundaryIndex < requestPath.endIndex && requestPath[boundaryIndex] == "/"
    }
}

private enum ServiceWebViewCookieLoader {
    static func load(_ request: URLRequest, in webView: WKWebView, for url: URL) {
        if let host = url.host,
           let userAgent = CloudflareBypassManager.shared.bypassUserAgent(for: host) {

            webView.customUserAgent = userAgent
            webView.frame = serviceWebViewViewportBounds(forUserAgent: userAgent)
        }

        #if os(tvOS)
        webView.load(request)
        #else
        guard let cookieHeader = request.value(forHTTPHeaderField: "Cookie"),
              url.host != nil,
              !cookieHeader.isEmpty else {
            webView.load(request)
            return
        }

        // Explicit Cookie headers can be replayed by an opaque WebKit redirect.
        // Seed an exact-host cookie jar, then let WebKit apply normal domain and
        // secure-cookie rules to every hop instead of carrying the raw header.
        var cookieScopedRequest = request
        cookieScopedRequest.setValue(nil, forHTTPHeaderField: "Cookie")

        let cookies = cookies(from: cookieHeader, for: url)
        guard !cookies.isEmpty else {
            webView.load(cookieScopedRequest)
            return
        }

        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        Task { @MainActor in
            for cookie in cookies {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    cookieStore.setCookie(cookie) {
                        continuation.resume()
                    }
                }
            }
            webView.load(cookieScopedRequest)
        }
        #endif
    }

    #if !os(tvOS)
    private static func cookies(from header: String, for url: URL) -> [HTTPCookie] {
        guard let host = url.host else { return [] }
        let isSecure = url.scheme?.lowercased() == "https"
        return header.split(separator: ";").compactMap { part -> HTTPCookie? in
            let pieces = part.split(separator: "=", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard pieces.count == 2, !pieces[0].isEmpty else { return nil }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: pieces[0],
                .value: pieces[1],
                .domain: host,
                .path: "/"
            ]
            if isSecure {
                properties[.secure] = "TRUE"
            }
            return HTTPCookie(properties: properties)
        }
    }
    #endif
}
#endif

struct NetworkFetchOptions {
    let timeoutSeconds: Int
    let headers: [String: String]
    let cutoff: String?
    let returnHTML: Bool
    let returnCookies: Bool
    let clickSelectors: [String]
    let waitForSelectors: [String]
    let maxWaitTime: Int
    let htmlContent: String?

    init(
        timeoutSeconds: Int = 10,
        headers: [String: String] = [:],
        cutoff: String? = nil,
        returnHTML: Bool = false,
        returnCookies: Bool = true,
        clickSelectors: [String] = [],
        waitForSelectors: [String] = [],
        maxWaitTime: Int = 5,
        htmlContent: String? = nil
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.headers = headers
        self.cutoff = cutoff
        self.returnHTML = returnHTML
        self.returnCookies = returnCookies
        self.clickSelectors = clickSelectors
        self.waitForSelectors = waitForSelectors
        self.maxWaitTime = maxWaitTime
        self.htmlContent = htmlContent
    }
}

struct NetworkFetchSimpleOptions {
    let timeoutSeconds: Int
    let headers: [String: String]
    let htmlContent: String?
}

enum ServiceNetworkFetchInputBoundary {
    static let maximumSelectorCount = 64
    static let maximumSelectorBytes = 2 * 1_024
    static let maximumSelectorTotalBytes = 32 * 1_024
    static let maximumCutoffBytes = 4 * 1_024
    static let maximumHTMLBytes = 12 * 1_024 * 1_024
    static let maximumTimeoutSeconds = 60

    private static let networkFetchKeys: Set<String> = [
        "timeoutSeconds", "headers", "cutoff", "returnHTML", "returnCookies",
        "clickSelectors", "waitForSelectors", "maxWaitTime", "htmlContent"
    ]
    private static let simpleKeys: Set<String> = [
        "timeoutSeconds", "headers", "htmlContent"
    ]

    static func networkFetchOptions(
        from value: JSValue?,
        reader: ServiceJavaScriptValueReader
    ) throws -> NetworkFetchOptions {
        guard let value, !value.isUndefined, !value.isNull else {
            return NetworkFetchOptions()
        }
        let keys = try validatedKeys(
            of: value,
            allowed: networkFetchKeys,
            reader: reader
        )
        return NetworkFetchOptions(
            timeoutSeconds: try integer(
                "timeoutSeconds",
                in: value,
                keys: keys,
                defaultValue: 10,
                reader: reader
            ),
            headers: keys.contains("headers")
                ? try ServiceJavaScriptNetworkInputBoundary.headers(
                    from: reader.property("headers", of: value),
                    reader: reader
                )
                : [:],
            cutoff: try optionalString(
                "cutoff",
                in: value,
                keys: keys,
                maximumBytes: maximumCutoffBytes,
                reader: reader
            ),
            returnHTML: try boolean(
                "returnHTML",
                in: value,
                keys: keys,
                defaultValue: false,
                reader: reader
            ),
            returnCookies: try boolean(
                "returnCookies",
                in: value,
                keys: keys,
                defaultValue: true,
                reader: reader
            ),
            clickSelectors: try stringArray(
                "clickSelectors",
                in: value,
                keys: keys,
                reader: reader
            ),
            waitForSelectors: try stringArray(
                "waitForSelectors",
                in: value,
                keys: keys,
                reader: reader
            ),
            maxWaitTime: try integer(
                "maxWaitTime",
                in: value,
                keys: keys,
                defaultValue: 5,
                reader: reader
            ),
            htmlContent: try optionalString(
                "htmlContent",
                in: value,
                keys: keys,
                maximumBytes: maximumHTMLBytes,
                reader: reader
            )
        )
    }

    static func simpleOptions(
        from value: JSValue?,
        reader: ServiceJavaScriptValueReader
    ) throws -> NetworkFetchSimpleOptions {
        guard let value, !value.isUndefined, !value.isNull else {
            return NetworkFetchSimpleOptions(
                timeoutSeconds: 5,
                headers: [:],
                htmlContent: nil
            )
        }
        let keys = try validatedKeys(
            of: value,
            allowed: simpleKeys,
            reader: reader
        )
        return NetworkFetchSimpleOptions(
            timeoutSeconds: try integer(
                "timeoutSeconds",
                in: value,
                keys: keys,
                defaultValue: 5,
                reader: reader
            ),
            headers: keys.contains("headers")
                ? try ServiceJavaScriptNetworkInputBoundary.headers(
                    from: reader.property("headers", of: value),
                    reader: reader
                )
                : [:],
            htmlContent: try optionalString(
                "htmlContent",
                in: value,
                keys: keys,
                maximumBytes: maximumHTMLBytes,
                reader: reader
            )
        )
    }

    private static func validatedKeys(
        of value: JSValue,
        allowed: Set<String>,
        reader: ServiceJavaScriptValueReader
    ) throws -> Set<String> {
        let keys = try reader.ownEnumerableKeys(
            of: value,
            maximumCount: 64,
            maximumKeyBytes: 64,
            tolerant: true
        )
        return Set(keys).intersection(allowed)
    }

    private static func integer(
        _ key: String,
        in object: JSValue,
        keys: Set<String>,
        defaultValue: Int,
        reader: ServiceJavaScriptValueReader
    ) throws -> Int {
        guard keys.contains(key) else { return defaultValue }
        let value = try reader.property(key, of: object)
        if value.isUndefined || value.isNull { return defaultValue }
        guard value.isNumber else {
            throw ServiceJavaScriptValueBoundaryError.invalidValue
        }
        let number = value.toDouble()
        guard number.isFinite else {
            throw ServiceJavaScriptValueBoundaryError.invalidValue
        }
        let truncated = number.rounded(.towardZero)
        let clamped = min(max(truncated, 1), Double(maximumTimeoutSeconds))
        if clamped != number {
            Logger.shared.log(
                "Service networkFetch clamped option key=\(key) applied=\(Int(clamped))s",
                type: "Service"
            )
        }
        return Int(clamped)
    }

    private static func boolean(
        _ key: String,
        in object: JSValue,
        keys: Set<String>,
        defaultValue: Bool,
        reader: ServiceJavaScriptValueReader
    ) throws -> Bool {
        guard keys.contains(key) else { return defaultValue }
        let value = try reader.property(key, of: object)
        if value.isUndefined || value.isNull { return defaultValue }
        guard value.isBoolean else {
            throw ServiceJavaScriptValueBoundaryError.invalidValue
        }
        return value.toBool()
    }

    private static func optionalString(
        _ key: String,
        in object: JSValue,
        keys: Set<String>,
        maximumBytes: Int,
        reader: ServiceJavaScriptValueReader
    ) throws -> String? {
        guard keys.contains(key) else { return nil }
        let value = try reader.property(key, of: object)
        if value.isUndefined || value.isNull { return nil }
        guard let string = ServiceJavaScriptValueReader.boundedString(
            from: value,
            maximumBytes: maximumBytes
        ) else {
            throw ServiceJavaScriptValueBoundaryError.valueTooLarge
        }
        return string
    }

    private static func stringArray(
        _ key: String,
        in object: JSValue,
        keys: Set<String>,
        reader: ServiceJavaScriptValueReader
    ) throws -> [String] {
        guard keys.contains(key) else { return [] }
        let value = try reader.property(key, of: object)
        if value.isUndefined || value.isNull { return [] }
        let count = try reader.arrayLength(of: value, maximumCount: maximumSelectorCount)
        var strings: [String] = []
        strings.reserveCapacity(count)
        var totalBytes = 0
        for index in 0..<count {
            let item = try reader.property(index, of: value)
            guard let string = ServiceJavaScriptValueReader.boundedString(
                from: item,
                maximumBytes: maximumSelectorBytes
            ) else {
                throw ServiceJavaScriptValueBoundaryError.invalidValue
            }
            let byteCount = string.utf8.count
            guard totalBytes <= maximumSelectorTotalBytes - byteCount else {
                throw ServiceJavaScriptValueBoundaryError.valueTooLarge
            }
            totalBytes += byteCount
            strings.append(string)
        }
        return strings
    }
}

extension JSContext {
    func setupNetworkFetch(sandbox: ServiceSandboxState) {
        guard let valueReader = ServiceJavaScriptValueReader(context: self) else {
            Logger.shared.log("Service networkFetch input boundary could not be installed", type: "Error")
            return
        }
        let networkFetchNativeFunction: @convention(block) (JSValue, JSValue?, JSValue, JSValue) -> Void = { urlValue, optionsValue, resolve, reject in
            let urlString: String
            do {
                urlString = try ServiceJavaScriptNetworkInputBoundary.urlString(from: urlValue)
            } catch {
                reject.call(withArguments: ["Service networkFetch URL was rejected"])
                return
            }
            guard let operation = sandbox.allowServiceNetworkRequest(api: "networkFetch", urlString: urlString) else {
                reject.call(withArguments: ["Service network request blocked by sandbox"])
                return
            }
            let options: NetworkFetchOptions
            do {
                options = try ServiceNetworkFetchInputBoundary.networkFetchOptions(
                    from: optionsValue,
                    reader: valueReader
                )
            } catch {
                reject.call(withArguments: ["Service networkFetch options were rejected"])
                return
            }
            guard let nativeLease = sandbox.reserveNativeOperation() else {
                reject.call(withArguments: ["Service native operation budget exhausted"])
                return
            }

            let workItem = DispatchWorkItem {
                guard nativeLease.isActive else { return }
                NetworkFetchManager.shared.performNetworkFetch(
                    urlString: urlString,
                    options: options,
                    operation: operation,
                    sandbox: sandbox,
                    resolve: resolve,
                    reject: reject,
                    nativeLease: nativeLease
                )
            }
            nativeLease.installCancellationHandler {
                workItem.cancel()
            }
            DispatchQueue.main.async(execute: workItem)
        }

        self.setObject(networkFetchNativeFunction, forKeyedSubscript: "networkFetchNative" as NSString)

        let networkFetchDefinition = """
            function networkFetch(url, options = {}) {
                if (typeof options === 'number') {
                    const timeoutSeconds = options;
                    const headers = arguments[2] || {};
                    const cutoff = arguments[3] || null;
                    options = { timeoutSeconds, headers, cutoff };
                }

                const finalOptions = {
                    timeoutSeconds: options.timeoutSeconds || 10,
                    headers: options.headers || {},
                    cutoff: options.cutoff || null,
                    returnHTML: options.returnHTML || false,
                    returnCookies: options.returnCookies !== undefined ? options.returnCookies : true,
                    clickSelectors: options.clickSelectors || [],
                    waitForSelectors: options.waitForSelectors || [],
                    maxWaitTime: options.maxWaitTime || 5,
                    htmlContent: options.htmlContent || null
                };

                return new Promise(function(resolve, reject) {
                    networkFetchNative(url || '', finalOptions, function(result) {
                        const requests = result.requests || [];
                        resolve({
                            url: result.originalUrl,
                            requests: requests,
                            html: result.html || null,
                            cookies: result.cookies || null,
                            success: result.success,
                            error: result.error || null,
                            totalRequests: requests.length,
                            requestsTruncated: result.requestsTruncated || false,
                            cutoffTriggered: result.cutoffTriggered || false,
                            cutoffUrl: result.cutoffUrl || null,
                            htmlCaptured: result.htmlCaptured || false,
                            htmlTruncated: result.htmlTruncated || false,
                            cookiesCaptured: result.cookiesCaptured || false,
                            elementsClicked: result.elementsClicked || [],
                            waitResults: result.waitResults || {}
                        });
                    }, reject);
                });
            }

            function networkFetchWithHTML(url, timeoutSeconds = 10) {
                return networkFetch(url, {
                    timeoutSeconds: timeoutSeconds,
                    returnHTML: true,
                    returnCookies: true
                });
            }

            function networkFetchWithCutoff(url, cutoff, timeoutSeconds = 10) {
                return networkFetch(url, {
                    timeoutSeconds: timeoutSeconds,
                    cutoff: cutoff,
                    returnCookies: true
                });
            }

            function networkFetchWithClicks(url, clickSelectors, options = {}) {
                return networkFetch(url, {
                    timeoutSeconds: options.timeoutSeconds || 10,
                    headers: options.headers || {},
                    cutoff: options.cutoff || null,
                    returnHTML: options.returnHTML || false,
                    returnCookies: options.returnCookies !== undefined ? options.returnCookies : true,
                    clickSelectors: Array.isArray(clickSelectors) ? clickSelectors : [clickSelectors],
                    waitForSelectors: options.waitForSelectors || [],
                    maxWaitTime: options.maxWaitTime || 5
                });
            }

            function networkFetchWithWaitAndClick(url, waitForSelectors, clickSelectors, options = {}) {
                return networkFetch(url, {
                    timeoutSeconds: options.timeoutSeconds || 10,
                    headers: options.headers || {},
                    cutoff: options.cutoff || null,
                    returnHTML: options.returnHTML || false,
                    returnCookies: options.returnCookies !== undefined ? options.returnCookies : true,
                    clickSelectors: Array.isArray(clickSelectors) ? clickSelectors : [clickSelectors],
                    waitForSelectors: Array.isArray(waitForSelectors) ? waitForSelectors : [waitForSelectors],
                    maxWaitTime: options.maxWaitTime || 5
                });
            }

            function networkFetchFromHTML(htmlContent, options = {}) {
                return networkFetch('', {
                    timeoutSeconds: options.timeoutSeconds || 10,
                    headers: options.headers || {},
                    cutoff: options.cutoff || null,
                    returnHTML: options.returnHTML || false,
                    returnCookies: options.returnCookies !== undefined ? options.returnCookies : true,
                    clickSelectors: options.clickSelectors || [],
                    waitForSelectors: options.waitForSelectors || [],
                    maxWaitTime: options.maxWaitTime || 5,
                    htmlContent: htmlContent
                });
            }
            """

        self.evaluateScript(networkFetchDefinition)
    }

    func setupNetworkFetchSimple(sandbox: ServiceSandboxState) {
        guard let valueReader = ServiceJavaScriptValueReader(context: self) else {
            Logger.shared.log("Service networkFetchSimple input boundary could not be installed", type: "Error")
            return
        }
        let networkFetchSimpleNativeFunction: @convention(block) (JSValue, JSValue?, JSValue, JSValue) -> Void = { urlValue, optionsValue, resolve, reject in
            let urlString: String
            do {
                urlString = try ServiceJavaScriptNetworkInputBoundary.urlString(from: urlValue)
            } catch {
                reject.call(withArguments: ["Service networkFetchSimple URL was rejected"])
                return
            }
            guard let operation = sandbox.allowServiceNetworkRequest(api: "networkFetchSimple", urlString: urlString) else {
                reject.call(withArguments: ["Service network request blocked by sandbox"])
                return
            }
            let options: NetworkFetchSimpleOptions
            do {
                options = try ServiceNetworkFetchInputBoundary.simpleOptions(
                    from: optionsValue,
                    reader: valueReader
                )
            } catch {
                reject.call(withArguments: ["Service networkFetchSimple options were rejected"])
                return
            }
            guard let nativeLease = sandbox.reserveNativeOperation() else {
                reject.call(withArguments: ["Service native operation budget exhausted"])
                return
            }
            let workItem = DispatchWorkItem {
                guard nativeLease.isActive else { return }
                NetworkFetchSimpleManager.shared.performNetworkFetch(
                    urlString: urlString,
                    timeoutSeconds: options.timeoutSeconds,
                    htmlContent: options.htmlContent,
                    headers: options.headers,
                    operation: operation,
                    sandbox: sandbox,
                    resolve: resolve,
                    reject: reject,
                    nativeLease: nativeLease
                )
            }
            nativeLease.installCancellationHandler {
                workItem.cancel()
            }
            DispatchQueue.main.async(execute: workItem)
        }
        self.setObject(networkFetchSimpleNativeFunction, forKeyedSubscript: "networkFetchSimpleNative" as NSString)
        let networkFetchSimpleDefinition = """
            function networkFetchSimple(url, options = {}) {
                if (typeof options === 'number') {
                    const timeoutSeconds = options;
                    options = { timeoutSeconds };
                }
                const finalOptions = {
                    timeoutSeconds: options.timeoutSeconds || 5,
                    htmlContent: options.htmlContent || null,
                    headers: options.headers || {}
                };
                return new Promise(function(resolve, reject) {
                    networkFetchSimpleNative(url || '', finalOptions, function(result) {
                        const requests = result.requests || [];
                        resolve({
                            url: result.originalUrl,
                            requests: requests,
                            success: result.success,
                            error: result.error || null,
                            totalRequests: requests.length,
                            requestsTruncated: result.requestsTruncated || false
                        });
                    }, reject);
                });
            }

            function networkFetchSimpleFromHTML(htmlContent, options = {}) {
                return networkFetchSimple('', {
                    timeoutSeconds: options.timeoutSeconds || 5,
                    htmlContent: htmlContent,
                    headers: options.headers || {}
                });
            }
            """
        self.evaluateScript(networkFetchSimpleDefinition)
    }
}

#if !os(tvOS)
class NetworkFetchSimpleManager: NSObject, ObservableObject {
    static let shared = NetworkFetchSimpleManager()

    private var activeMonitors: [String: NetworkFetchSimpleMonitor] = [:]

    private override init() {
        super.init()
    }

    func performNetworkFetch(urlString: String, timeoutSeconds: Int, htmlContent: String? = nil, headers: [String: String] = [:], operation: ServiceSandboxOperation, sandbox: ServiceSandboxState, resolve: JSValue, reject: JSValue, nativeLease: ServiceSandboxNativeOperationLease) {
        guard nativeLease.isActive else { return }
        let monitorId = UUID().uuidString
        let monitor = NetworkFetchSimpleMonitor(sandbox: sandbox)
        activeMonitors[monitorId] = monitor
        nativeLease.installCancellationHandler { [weak self, weak monitor] in
            DispatchQueue.main.async {
                monitor?.cancel()
                self?.activeMonitors.removeValue(forKey: monitorId)
            }
        }
        monitor.startMonitoring(
            urlString: urlString,
            timeoutSeconds: timeoutSeconds,
            htmlContent: htmlContent,
            headers: headers,
            operation: operation
        ) { [weak self] result in
            self?.activeMonitors.removeValue(forKey: monitorId)
            nativeLease.finish()
            sandbox.performJavaScriptCallback {
                if !resolve.isUndefined {
                    resolve.call(withArguments: [result])
                }
            }
        }
    }
}

class NetworkFetchSimpleMonitor: NSObject, ObservableObject {
    private weak var sandbox: ServiceSandboxState?
    private var webView: WKWebView?
    private var completionHandler: (([String: Any]) -> Void)?
    private var timer: Timer?
    private var operation: ServiceSandboxOperation?
    private var allowsLocalDocument = false
    private var cancelled = false
    private var networkRequestBytes = 0
    private var requestsTruncated = false

    @Published private(set) var networkRequests: [String] = []

    private var originalUrlString: String = ""

    init(sandbox: ServiceSandboxState) {
        self.sandbox = sandbox
        super.init()
    }

    func cancel() {
        cancelled = true
        timer?.invalidate()
        timer = nil
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: "networkLogger"
        )
        webView = nil
        operation = nil
        completionHandler = nil
    }

    func startMonitoring(urlString: String, timeoutSeconds: Int, htmlContent: String? = nil, headers: [String: String] = [:], operation: ServiceSandboxOperation, completion: @escaping ([String: Any]) -> Void) {
        guard !cancelled else { return }
        originalUrlString = urlString
        self.operation = operation
        completionHandler = completion
        networkRequests.removeAll()
        networkRequestBytes = 0
        requestsTruncated = false
        allowsLocalDocument = htmlContent?.isEmpty == false

        Task { @MainActor [weak self] in
            guard let self, !cancelled else { return }
            let preparedHeaders = ServiceBrowserAutomationPolicy.boundedHeaders(headers)
            let navigationURL = ServiceModuleURLParser.url(urlString)

            if !allowsLocalDocument {
                guard let navigationURL,
                      await ServiceBrowserAutomationPolicy.permitsNavigation(
                        to: navigationURL,
                        allowsLocalDocument: false
                      ) else {
                    failMonitoring(error: "Browser automation requires an HTTP or HTTPS URL.")
                    return
                }
            }
            guard await setupWebView(), !cancelled else {
                if cancelled { return }
                failMonitoring(error: "Browser security policy could not be installed.")
                return
            }
            if let htmlContent, !htmlContent.isEmpty {
                loadHTMLContent(htmlContent)
            } else if let navigationURL {
                loadURL(url: navigationURL, headers: preparedHeaders)
            }
            timer = Timer.scheduledTimer(
                withTimeInterval: TimeInterval(min(max(timeoutSeconds, 1), 60)),
                repeats: false
            ) { [weak self] _ in
                self?.stopMonitoring()
            }
        }
    }

    private func loadHTMLContent(_ htmlContent: String) {
        guard let webView = webView else { return }

        addRequest("data:text/html;charset=utf-8,<html_content>")

        webView.loadHTMLString(htmlContent, baseURL: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.simulateUserInteraction()
        }
    }

    @MainActor
    private func setupWebView() async -> Bool {
        guard !cancelled, let sandbox else { return false }
        let config = ServiceBrowserAutomationPolicy.isolatedConfiguration(for: sandbox)
#if os(iOS)
        config.allowsInlineMediaPlayback = true
#endif
        config.mediaTypesRequiringUserActionForPlayback = []
        guard await ServiceBrowserAutomationPolicy.installHTTPSOnlyContentRule(
            in: config
        ), !cancelled else { return false }

        let jsCode = """
        """

        let userScript = WKUserScript(source: jsCode, injectionTime: WKUserScriptInjectionTime.atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(userScript)
        config.userContentController.add(self, name: "networkLogger")

        let userAgent = URLSession.randomDesktopUserAgent
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), configuration: config)
        webView?.navigationDelegate = self

        webView?.customUserAgent = userAgent
        return true
    }

    private func loadURL(url: URL, headers: [String: String] = [:]) {
        guard let webView = webView else { return }
        addRequest(url.absoluteString)
        var request = URLRequest(url: url)
        request.setValue(webView.customUserAgent ?? URLSession.randomUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.5", forHTTPHeaderField: "Accept-Language")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("upgrade-insecure-requests", forHTTPHeaderField: "Upgrade-Insecure-Requests")
        request.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        CloudflareBypassManager.shared.applyCachedBypass(to: &request, for: url)
        let referer = request.value(forHTTPHeaderField: "Referer")
        let secFetchSite = ServiceBrowserAutomationPolicy.secFetchSite(referer: referer, target: url)
        request.setValue(secFetchSite, forHTTPHeaderField: "Sec-Fetch-Site")
        if let operation {
            Logger.shared.log(
                "Service networkFetchSimple navigation service=\(operation.serviceName) operation=\(operation.operation) target=\(ServiceSandboxState.redactedURL(url.absoluteString)) referer=\(ServiceSandboxState.redactedURL(referer)) secFetchSite=\(secFetchSite)",
                type: "Service"
            )
        }
        ServiceWebViewCookieLoader.load(request, in: webView, for: url)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.simulateUserInteraction()
        }
    }

    private func simulateUserInteraction() {
        guard let webView = webView else { return }

        let jsInteraction = """
        """
        webView.evaluateJavaScript(jsInteraction, completionHandler: nil)
    }

    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil

        if let webView {
            Task { @MainActor in
                CloudflareBypassManager.shared.captureSolvedCookies(from: webView, for: webView.url)
            }
        }
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "networkLogger")

        let rawOriginalURL = networkRequests.first == "data:text/html;charset=utf-8,<html_content>" ?
            "data:text/html;charset=utf-8,<html_content>" :
            (webView?.url?.absoluteString ?? originalUrlString)
        let originalUrl = ServiceBrowserOutputBoundary.boundedURLString(rawOriginalURL)
            ?? ServiceSandboxState.redactedURL(rawOriginalURL)
        if originalUrl != rawOriginalURL { requestsTruncated = true }

        let result: [String: Any] = [
            "originalUrl": originalUrl,
            "requests": networkRequests,
            "requestsTruncated": requestsTruncated,
            "success": true
        ]

        if let operation {
            Logger.shared.log("Service networkFetchSimple completed service=\(operation.serviceName) operation=\(operation.operation) requestCount=\(networkRequests.count) original=\(ServiceSandboxState.redactedURL(originalUrl))", type: "Service")
        }

        webView = nil
        operation = nil

        completionHandler?(result)
        completionHandler = nil
    }

    private func failMonitoring(error: String) {
        timer?.invalidate()
        timer = nil
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: "networkLogger"
        )
        webView = nil
        operation = nil
        let completion = completionHandler
        completionHandler = nil
        completion?([
            "originalUrl": ServiceSandboxState.redactedURL(originalUrlString),
            "requests": [],
            "requestsTruncated": requestsTruncated,
            "success": false,
            "error": error
        ])
    }

    private func addRequest(_ urlString: String) {
        DispatchQueue.main.async {
            if ServiceBrowserOutputBoundary.appendRequest(
                urlString,
                to: &self.networkRequests,
                totalBytes: &self.networkRequestBytes
            ) == .truncated {
                self.requestsTruncated = true
            }
        }
    }
}

extension NetworkFetchSimpleMonitor: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation) {}

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation) {
        Task { @MainActor in
            CloudflareBypassManager.shared.captureSolvedCookies(from: webView, for: webView.url)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation, withError error: Error) {}

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        // A challenge page builds its widget in about:blank / blob: sub-frames. The top-level URL
        // was already validated before the load, so restricting the scheme to http(s) inside a
        // sub-frame only stops the page from rendering the thing this web view exists to solve.
        let isSubframeNavigation = navigationAction.targetFrame?.isMainFrame == false
        Task { @MainActor [weak self] in
            guard let self,
                  !ServiceSandboxState.isBlockedTrackingURL(url.absoluteString),
                  await ServiceBrowserAutomationPolicy.permitsNavigation(
                    to: url,
                    allowsLocalDocument: allowsLocalDocument || isSubframeNavigation
                  ) else {
                decisionHandler(.cancel)
                return
            }
            addRequest(url.absoluteString)
            decisionHandler(.allow)
        }
    }
}

extension NetworkFetchSimpleMonitor: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "networkLogger" {
            if let messageBody = message.body as? [String: Any],
               let url = messageBody["url"] as? String {
                addRequest(url)
            }
        }
    }
}

class NetworkFetchManager: NSObject, ObservableObject {
    static let shared = NetworkFetchManager()

    private var activeMonitors: [String: NetworkFetchMonitor] = [:]

    private override init() {
        super.init()
    }

    func performNetworkFetch(urlString: String, options: NetworkFetchOptions, operation: ServiceSandboxOperation, sandbox: ServiceSandboxState, resolve: JSValue, reject: JSValue, nativeLease: ServiceSandboxNativeOperationLease) {
        guard nativeLease.isActive else { return }
        let monitorId = UUID().uuidString
        let monitor = NetworkFetchMonitor(sandbox: sandbox)
        activeMonitors[monitorId] = monitor
        nativeLease.installCancellationHandler { [weak self, weak monitor] in
            DispatchQueue.main.async {
                monitor?.cancel()
                self?.activeMonitors.removeValue(forKey: monitorId)
            }
        }

        monitor.startMonitoring(
            urlString: urlString,
            options: options,
            operation: operation
        ) { [weak self] result in
            self?.activeMonitors.removeValue(forKey: monitorId)
            nativeLease.finish()

            sandbox.performJavaScriptCallback {
                if !resolve.isUndefined {
                    resolve.call(withArguments: [result])
                }
            }
        }
    }
}

class NetworkFetchMonitor: NSObject, ObservableObject {
    private weak var sandbox: ServiceSandboxState?
    private var webView: WKWebView?
    private var completionHandler: (([String: Any]) -> Void)?
    private var timer: Timer?
    private var options: NetworkFetchOptions?
    private var operation: ServiceSandboxOperation?
    private var elementsClicked: [String] = []
    private var waitResults: [String: Bool] = [:]
    private var cookies: [String: String] = [:]
    private var originalURLString = ""
    private var allowsLocalDocument = false
    private var cancelled = false
    private var networkRequestBytes = 0
    private var requestsTruncated = false
    private var htmlTruncated = false
    private let networkLoggerHandlerName = "eclipseNetworkLogger"
        + UUID().uuidString.replacingOccurrences(of: "-", with: "")

    @Published private(set) var networkRequests: [String] = []
    @Published private(set) var cutoffTriggered = false
    @Published private(set) var cutoffUrl: String? = nil
    @Published private(set) var htmlContent: String? = nil
    @Published private(set) var htmlCaptured = false
    @Published private(set) var cookiesCaptured = false

    init(sandbox: ServiceSandboxState) {
        self.sandbox = sandbox
        super.init()
    }

    func cancel() {
        cancelled = true
        timer?.invalidate()
        timer = nil
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: networkLoggerHandlerName
        )
        webView = nil
        options = nil
        operation = nil
        completionHandler = nil
    }

    func startMonitoring(urlString: String, options: NetworkFetchOptions, operation: ServiceSandboxOperation, completion: @escaping ([String: Any]) -> Void) {
        guard !cancelled else { return }
        originalURLString = urlString
        self.options = options
        self.operation = operation
        completionHandler = completion
        networkRequests.removeAll()
        networkRequestBytes = 0
        requestsTruncated = false
        cutoffTriggered = false
        cutoffUrl = nil
        htmlContent = nil
        htmlCaptured = false
        htmlTruncated = false
        cookiesCaptured = false
        elementsClicked.removeAll()
        waitResults.removeAll()
        cookies.removeAll()
        allowsLocalDocument = options.htmlContent?.isEmpty == false

        Task { @MainActor [weak self] in
            guard let self, !cancelled else { return }
            let preparedHeaders = ServiceBrowserAutomationPolicy.boundedHeaders(options.headers)
            let navigationURL = ServiceModuleURLParser.url(urlString)
            if !allowsLocalDocument {
                guard let navigationURL,
                      await ServiceBrowserAutomationPolicy.permitsNavigation(
                        to: navigationURL,
                        allowsLocalDocument: false
                      ) else {
                    failMonitoring(error: "Browser automation requires an HTTP or HTTPS URL.")
                    return
                }
            }
            guard await setupWebView(), !cancelled else {
                if cancelled { return }
                failMonitoring(error: "Browser security policy could not be installed.")
                return
            }
            if let htmlContent = options.htmlContent, !htmlContent.isEmpty {
                loadHTMLContent(htmlContent)
            } else if let navigationURL {
                loadURL(url: navigationURL, headers: preparedHeaders)
            }
            timer = Timer.scheduledTimer(
                withTimeInterval: TimeInterval(min(max(options.timeoutSeconds, 1), 60)),
                repeats: false
            ) { [weak self] _ in
                if options.returnHTML || options.returnCookies {
                    self?.captureDataThenComplete()
                } else {
                    self?.stopMonitoring(reason: "timeout")
                }
            }
        }
    }

    private func captureDataThenComplete() {
        guard let webView = webView, let options = options else {
            stopMonitoring(reason: "timeout")
            return
        }

        let shouldCaptureHTML = options.returnHTML
        let shouldCaptureCookies = options.returnCookies

        var completedTasks = 0
        let totalTasks = (shouldCaptureHTML ? 1 : 0) + (shouldCaptureCookies ? 1 : 0)

        if totalTasks == 0 {
            stopMonitoring(reason: "timeout")
            return
        }

        let checkCompletion = {
            completedTasks += 1
            if completedTasks >= totalTasks {
                self.stopMonitoring(reason: "timeout_with_data")
            }
        }

        if shouldCaptureHTML {
            webView.evaluateJavaScript(
                ServiceBrowserOutputBoundary.boundedHTMLCaptureScript
            ) { [weak self] result, error in
                DispatchQueue.main.async {
                    if let payload = result as? [String: Any],
                       let html = payload["html"] as? String,
                       html.utf8.count <= ServiceBrowserOutputBoundary.maximumHTMLBytes,
                       error == nil {
                        self?.htmlContent = html
                        self?.htmlCaptured = true
                        self?.htmlTruncated = payload["truncated"] as? Bool ?? false
                    } else if error == nil {
                        self?.htmlTruncated = true
                    }
                    checkCompletion()
                }
            }
        }

        if shouldCaptureCookies {
            captureCookies {
                DispatchQueue.main.async {
                    checkCompletion()
                }
            }
        }
    }

    private func captureCookies(completion: @escaping () -> Void) {
        guard let webView = webView else {
            completion()
            return
        }

        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        var preferredURLs: [URL] = []
        if let originalURL = ServiceModuleURLParser.url(originalURLString) {
            preferredURLs.append(originalURL)
        }
        if let finalURL = webView.url,
           !preferredURLs.contains(where: { $0.absoluteString == finalURL.absoluteString }) {
            preferredURLs.append(finalURL)
        }

        cookieStore.getAllCookies { [weak self] cookies in
            DispatchQueue.main.async {
                let cookieDict = ServiceBrowserCookiePolicy.returnedCookies(
                    from: cookies,
                    preferring: preferredURLs
                )

                self?.cookies = cookieDict
                self?.cookiesCaptured = !cookieDict.isEmpty
                if let operation = self?.operation {
                    Logger.shared.log(
                        "Service networkFetch cookies service=\(operation.serviceName) operation=\(operation.operation) cookiesScanned=\(cookies.count) cookiesReturned=\(cookieDict.count)",
                        type: "Service"
                    )
                }

                completion()
            }
        }
    }

    @MainActor
    private func setupWebView() async -> Bool {
        guard !cancelled, let sandbox else { return false }
        let config = ServiceBrowserAutomationPolicy.isolatedConfiguration(for: sandbox)
#if os(iOS)
        config.allowsInlineMediaPlayback = true
#endif
        config.mediaTypesRequiringUserActionForPlayback = []
        guard await ServiceBrowserAutomationPolicy.installHTTPSOnlyContentRule(
            in: config
        ), !cancelled else { return false }

        let jsCode = """
        (function() {
            const eclipseNativeLogger = window.webkit.messageHandlers['\(networkLoggerHandlerName)'];
            try {
                delete window.webkit.messageHandlers['\(networkLoggerHandlerName)'];
            } catch(e) {
            }
            let eclipseReportedRequestCount = 0;
            let eclipseReportedRequestBytes = 0;
            let eclipseReportedRequestsTruncated = false;
            const eclipseReportedRequestURLs = new Set();
            function eclipseMarkRequestsTruncated() {
                if (eclipseReportedRequestsTruncated) return;
                eclipseReportedRequestsTruncated = true;
                eclipseNativeLogger.postMessage({
                    type: 'requests-truncated'
                });
            }
            function eclipseBoundedUTF8(value, maximumBytes) {
                let source;
                try {
                    source = String(value == null ? '' : value);
                } catch(e) {
                    return ['', 0, false];
                }
                let bytes = 0;
                let end = 0;
                for (let index = 0; index < source.length;) {
                    const first = source.charCodeAt(index);
                    let units = 1;
                    let width;
                    if (first <= 0x7f) {
                        width = 1;
                    } else if (first <= 0x7ff) {
                        width = 2;
                    } else if (first >= 0xd800 && first <= 0xdbff
                               && index + 1 < source.length
                               && source.charCodeAt(index + 1) >= 0xdc00
                               && source.charCodeAt(index + 1) <= 0xdfff) {
                        units = 2;
                        width = 4;
                    } else {
                        width = 3;
                    }
                    if (bytes + width > maximumBytes) break;
                    bytes += width;
                    index += units;
                    end = index;
                }
                return [source.slice(0, end), bytes, end < source.length];
            }
            function eclipseReport(type, value) {
                const bounded = eclipseBoundedUTF8(value, 16384);
                if (!bounded[0]) return;
                if (eclipseReportedRequestURLs.has(bounded[0])) return;
                if (eclipseReportedRequestCount >= 1024) {
                    eclipseMarkRequestsTruncated();
                    return;
                }
                if (bounded[2]) eclipseMarkRequestsTruncated();
                if (eclipseReportedRequestBytes + bounded[1] > 1048576) {
                    eclipseMarkRequestsTruncated();
                    return;
                }
                eclipseReportedRequestURLs.add(bounded[0]);
                eclipseReportedRequestCount += 1;
                eclipseReportedRequestBytes += bounded[1];
                eclipseNativeLogger.postMessage({
                    type: type,
                    url: bounded[0]
                });
            }
            Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
            Object.defineProperty(navigator, 'plugins', { get: () => [1, 2, 3, 4, 5] });
            Object.defineProperty(navigator, 'languages', { get: () => ['en-US', 'en'] });
            delete window.navigator.__proto__.webdriver;

            window.chrome = { runtime: {} };
            Object.defineProperty(navigator, 'permissions', { get: () => undefined });

            const originalFetch = window.fetch;
            const originalXHROpen = XMLHttpRequest.prototype.open;
            const originalXHRSend = XMLHttpRequest.prototype.send;

            window.fetch = function() {
                const url = arguments[0];

                try {
                    const fullUrl = new URL(url, window.location.href).href;
                    eclipseReport('fetch', fullUrl);
                } catch(e) {
                    eclipseReport('fetch', url);
                }
                return originalFetch.apply(this, arguments);
            };

            XMLHttpRequest.prototype.open = function() {
                const method = arguments[0];
                const url = arguments[1];

                try {
                    this._url = new URL(url, window.location.href).href;
                } catch(e) {
                    this._url = url;
                }

                eclipseReport('xhr-open', this._url);

                const self = this;
                const originalOnReadyStateChange = this.onreadystatechange;

                this.onreadystatechange = function() {
                    if (this.readyState === 4) {
                        if (this.responseURL) {
                            eclipseReport('xhr-response', this.responseURL);
                        }

                        try {
                            const responseText = this.responseText;
                            if (responseText) {
                                const urlRegex = /(https?:\\/\\/[^\\s"'<>]+\\.(m3u8|ts|mp4|webm|mkv))/gi;
                                const matches = responseText.match(urlRegex);
                                if (matches) {
                                    matches.forEach(function(match) {
                                        eclipseReport('response-content', match);
                                    });
                                }
                            }
                        } catch(e) {
                        }
                    }

                    if (originalOnReadyStateChange) {
                        originalOnReadyStateChange.apply(this, arguments);
                    }
                };

                return originalXHROpen.apply(this, arguments);
            };

            XMLHttpRequest.prototype.send = function() {
                if (this._url) {
                    eclipseReport('xhr-send', this._url);
                }
                return originalXHRSend.apply(this, arguments);
            };

            const originalWebSocket = window.WebSocket;
            window.WebSocket = function(url, protocols) {
                eclipseReport('websocket', url);
                return new originalWebSocket(url, protocols);
            };

            const hookUrlProperties = function(obj, properties) {
                properties.forEach(function(prop) {
                    if (obj && obj.prototype) {
                        const descriptor = Object.getOwnPropertyDescriptor(obj.prototype, prop) || {};
                        const originalSetter = descriptor.set;

                        if (originalSetter) {
                            Object.defineProperty(obj.prototype, prop, {
                                set: function(value) {
                                    if (typeof value === 'string' && (value.includes('http') || value.includes('.m3u8') || value.includes('.ts'))) {
                                        eclipseReport('property-set', value);
                                    }
                                    return originalSetter.call(this, value);
                                },
                                get: descriptor.get,
                                configurable: true
                            });
                        }
                    }
                });
            };

            hookUrlProperties(HTMLVideoElement, ['src']);
            hookUrlProperties(HTMLSourceElement, ['src']);
            hookUrlProperties(HTMLScriptElement, ['src']);
            hookUrlProperties(HTMLImageElement, ['src']);

            let jwHookAttempts = 0;
            const aggressiveJWHook = function() {
                jwHookAttempts++;

                if (window.jwplayer) {
                    const originalJWPlayer = window.jwplayer;
                    window.jwplayer = function(id) {
                        const player = originalJWPlayer.apply(this, arguments);

                        if (player && player.setup) {
                            const originalSetup = player.setup;
                            player.setup = function(config) {
                                const extractUrls = function(obj, path = '') {
                                    if (!obj) return;

                                    if (typeof obj === 'string' && (obj.includes('http') || obj.includes('.m3u8') || obj.includes('.ts'))) {
                                        eclipseReport('jwplayer-config', obj);
                                    } else if (typeof obj === 'object' && obj !== null) {
                                        Object.keys(obj).forEach(function(key) {
                                            extractUrls(obj[key], path + '.' + key);
                                        });
                                    }
                                };

                                extractUrls(config);
                                return originalSetup.call(this, config);
                            };
                        }

                        return player;
                    };

                    Object.keys(originalJWPlayer).forEach(function(key) {
                        window.jwplayer[key] = originalJWPlayer[key];
                    });
                }

                if (jwHookAttempts < 20) {
                    setTimeout(aggressiveJWHook, 200);
                }
            };

            aggressiveJWHook();

            window.waitForElementAndClick = function(waitSelectors, clickSelectors, maxWaitTime) {
                return new Promise(function(resolve) {
                    const results = {
                        waitResults: {},
                        clickResults: []
                    };

                    waitSelectors.forEach(function(selector) {
                        results.waitResults[selector] = false;
                    });

                    const startTime = Date.now();
                    const checkInterval = 100;

                    const checkAndClick = function() {
                        const elapsed = (Date.now() - startTime) / 1000;

                        let allFound = waitSelectors.length === 0;

                        waitSelectors.forEach(function(selector) {
                            const element = document.querySelector(selector);
                            if (element && element.offsetParent !== null) {
                                results.waitResults[selector] = true;
                            }
                        });

                        allFound = waitSelectors.every(function(selector) {
                            return results.waitResults[selector];
                        });

                        if (allFound || elapsed >= maxWaitTime) {
                            clickSelectors.forEach(function(selector) {
                                try {
                                    const elements = document.querySelectorAll(selector);
                                    let clicked = false;

                                    elements.forEach(function(element) {
                                        if (element && element.offsetParent !== null) {
                                            try {
                                                element.click();
                                                clicked = true;
                                            } catch(e1) {
                                                try {
                                                    const event = new MouseEvent('click', {
                                                        view: window,
                                                        bubbles: true,
                                                        cancelable: true
                                                    });
                                                    element.dispatchEvent(event);
                                                    clicked = true;
                                                } catch(e2) {
                                                }
                                            }
                                        }
                                    });

                                    results.clickResults.push({
                                        selector: selector,
                                        success: clicked,
                                        elementsFound: elements.length
                                    });
                                } catch(e) {
                                    results.clickResults.push({
                                        selector: selector,
                                        success: false,
                                        error: e.message
                                    });
                                }
                            });

                            eclipseNativeLogger.postMessage({
                                type: 'click-results',
                                results: results
                            });

                            resolve(results);
                        } else if (elapsed < maxWaitTime) {
                            setTimeout(checkAndClick, checkInterval);
                        }
                    };

                    checkAndClick();
                });
            };

            const nuclearScan = function() {
                Object.keys(window).forEach(function(key) {
                    try {
                        const value = window[key];
                        if (typeof value === 'string' && (value.includes('.m3u8') || value.includes('.ts') || (value.includes('http') && value.includes('.')))) {
                            eclipseReport('global-variable', value);
                        }
                    } catch(e) {
                    }
                });

                document.querySelectorAll('script').forEach(function(script) {
                    if (script.textContent) {
                        const urlRegex = /(https?:\\/\\/[^\\s"'<>]+\\.(m3u8|ts|mp4))/gi;
                        const matches = script.textContent.match(urlRegex);
                        if (matches) {
                            matches.forEach(function(match) {
                                eclipseReport('script-content', match);
                            });
                        }
                    }
                });
            };

            setTimeout(nuclearScan, 500);
            setTimeout(nuclearScan, 1500);
            setTimeout(nuclearScan, 3000);

        })();
        """

        let userScript = WKUserScript(source: jsCode, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(userScript)
        config.userContentController.add(self, name: networkLoggerHandlerName)

        let userAgent = URLSession.randomDesktopUserAgent
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), configuration: config)
        webView?.navigationDelegate = self

        webView?.customUserAgent = userAgent
        return true
    }

    private func loadHTMLContent(_ htmlContent: String) {
        guard let webView = webView else { return }

        addRequest("data:text/html;charset=utf-8,<html_content>")

        webView.loadHTMLString(htmlContent, baseURL: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.performCustomInteractions()

            if self.options?.returnCookies == true {
                self.captureCookies {
                }
            }
        }
    }

    private func loadURL(url: URL, headers: [String: String]) {
        guard let webView = webView else { return }

        addRequest(url.absoluteString)

        var request = URLRequest(url: url)

        request.setValue(webView.customUserAgent ?? URLSession.randomUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.5", forHTTPHeaderField: "Accept-Language")
        request.setValue("gzip, deflate, br", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("upgrade-insecure-requests", forHTTPHeaderField: "Upgrade-Insecure-Requests")
        request.setValue("navigate", forHTTPHeaderField: "Sec-Fetch-Mode")

        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        CloudflareBypassManager.shared.applyCachedBypass(to: &request, for: url)

        let referer = request.value(forHTTPHeaderField: "Referer")
        let secFetchSite = ServiceBrowserAutomationPolicy.secFetchSite(referer: referer, target: url)
        request.setValue(secFetchSite, forHTTPHeaderField: "Sec-Fetch-Site")
        if let operation {
            Logger.shared.log(
                "Service networkFetch navigation service=\(operation.serviceName) operation=\(operation.operation) target=\(ServiceSandboxState.redactedURL(url.absoluteString)) referer=\(ServiceSandboxState.redactedURL(referer)) secFetchSite=\(secFetchSite)",
                type: "Service"
            )
        }

        ServiceWebViewCookieLoader.load(request, in: webView, for: url)

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.performCustomInteractions()

            if self.options?.returnCookies == true {
                self.captureCookies {
                }
            }
        }
    }

    private func performCustomInteractions() {
        guard let webView = webView, let options = options else { return }

        if !options.waitForSelectors.isEmpty || !options.clickSelectors.isEmpty {
            let waitSelectorsJS = (try? JSONEncoder().encode(options.waitForSelectors))
                .map { String(decoding: $0, as: UTF8.self) } ?? "[]"
            let clickSelectorsJS = (try? JSONEncoder().encode(options.clickSelectors))
                .map { String(decoding: $0, as: UTF8.self) } ?? "[]"

            let customInteractionJS = """
            window.waitForElementAndClick(
                \(waitSelectorsJS),
                \(clickSelectorsJS),
                \(options.maxWaitTime)
            );
            """
            webView.evaluateJavaScript(customInteractionJS, completionHandler: nil)
        } else {
            simulateUserInteraction()
        }
    }

    private func simulateUserInteraction() {
        guard let webView = webView else { return }

        let jsInteraction = """
        setTimeout(function() {
            const playButtons = document.querySelectorAll('button, div, span, a');
            const filteredButtons = Array.from(playButtons).filter(function(el) {
                const text = el.textContent || el.innerText || '';
                const classes = el.className || '';
                const id = el.id || '';
                return text.toLowerCase().includes('play') ||
                       classes.toLowerCase().includes('play') ||
                       id.toLowerCase().includes('play') ||
                       el.getAttribute('aria-label')?.toLowerCase().includes('play');
            });
            filteredButtons.forEach(function(btn, index) {
                setTimeout(function() {
                    try {
                        btn.click();
                    } catch(e) {}
                }, index * 200);
            });
            window.scrollTo(0, document.body.scrollHeight / 2);
            setTimeout(function() {
                window.scrollTo(0, 0);
            }, 500);
            document.querySelectorAll('video').forEach(function(video) {
                if (video.play && typeof video.play === 'function') {
                    video.play().catch(function(e) {
                    });
                }
            });
            if (window.jwplayer) {
                try {
                    const players = window.jwplayer().getInstances?.() || [];
                    players.forEach(function(player) {
                        if (player.play) {
                            player.play();
                        }
                    });
                } catch(e) {}
            }
            if (window.videojs) {
                try {
                    window.videojs.getAllPlayers?.().forEach(function(player) {
                        if (player.play) {
                            player.play();
                        }
                    });
                } catch(e) {}
            }
        }, 1000);
        """
        webView.evaluateJavaScript(jsInteraction, completionHandler: nil)
    }

    private func stopMonitoring(reason: String = "completed") {
        timer?.invalidate()
        timer = nil

        if let webView {
            Task { @MainActor in
                CloudflareBypassManager.shared.captureSolvedCookies(from: webView, for: webView.url)
            }
        }
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: networkLoggerHandlerName
        )

        let rawOriginalURL = options?.htmlContent != nil
            ? "data:text/html;charset=utf-8,<html_content>"
            : (webView?.url?.absoluteString ?? originalURLString)
        let originalUrl = ServiceBrowserOutputBoundary.boundedURLString(rawOriginalURL)
            ?? ServiceSandboxState.redactedURL(rawOriginalURL)
        if originalUrl != rawOriginalURL { requestsTruncated = true }

        let result: [String: Any] = [
            "originalUrl": originalUrl,
            "requests": networkRequests,
            "requestsTruncated": requestsTruncated,
            "html": htmlContent as Any,
            "cookies": cookies.isEmpty ? NSNull() : cookies,
            "success": true,
            "cutoffTriggered": cutoffTriggered,
            "cutoffUrl": cutoffUrl as Any,
            "htmlCaptured": htmlCaptured,
            "htmlTruncated": htmlTruncated,
            "cookiesCaptured": cookiesCaptured,
            "elementsClicked": elementsClicked,
            "waitResults": waitResults
        ]

        if let operation {
            Logger.shared.log("Service networkFetch completed service=\(operation.serviceName) operation=\(operation.operation) reason=\(reason) requestCount=\(networkRequests.count) original=\(ServiceSandboxState.redactedURL(originalUrl)) cutoff=\(cutoffTriggered)", type: "Service")
        }

        webView = nil
        operation = nil

        completionHandler?(result)
        completionHandler = nil
    }

    private func failMonitoring(error: String) {
        timer?.invalidate()
        timer = nil
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(
            forName: networkLoggerHandlerName
        )
        webView = nil
        operation = nil
        let completion = completionHandler
        completionHandler = nil
        completion?([
            "originalUrl": ServiceSandboxState.redactedURL(originalURLString),
            "requests": [],
            "requestsTruncated": requestsTruncated,
            "html": NSNull(),
            "cookies": NSNull(),
            "success": false,
            "error": error,
            "cutoffTriggered": false,
            "cutoffUrl": NSNull(),
            "htmlCaptured": false,
            "htmlTruncated": htmlTruncated,
            "cookiesCaptured": false,
            "elementsClicked": [],
            "waitResults": [:]
        ])
    }

    private func addRequest(_ urlString: String) {
        DispatchQueue.main.async {
            let disposition = ServiceBrowserOutputBoundary.appendRequest(
                urlString,
                to: &self.networkRequests,
                totalBytes: &self.networkRequestBytes
            )
            if disposition == .truncated {
                self.requestsTruncated = true
            }

            if disposition == .appended {
                if let cutoff = self.options?.cutoff, !cutoff.isEmpty {
                    if urlString.lowercased().contains(cutoff.lowercased()) {
                        self.cutoffTriggered = true
                        self.cutoffUrl = urlString
                        self.stopMonitoring(reason: "cutoff")
                        return
                    }
                }
            }
        }
    }
}

extension NetworkFetchMonitor: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation) {
        cookies.removeAll(keepingCapacity: false)
        cookiesCaptured = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation) {
        if options?.returnCookies == true {
            captureCookies {}
        }
        Task { @MainActor in
            CloudflareBypassManager.shared.captureSolvedCookies(from: webView, for: webView.url)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation, withError error: Error) {}

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }
        // A challenge page builds its widget in about:blank / blob: sub-frames. The top-level URL
        // was already validated before the load, so restricting the scheme to http(s) inside a
        // sub-frame only stops the page from rendering the thing this web view exists to solve.
        let isSubframeNavigation = navigationAction.targetFrame?.isMainFrame == false
        Task { @MainActor [weak self] in
            guard let self,
                  !ServiceSandboxState.isBlockedTrackingURL(url.absoluteString),
                  await ServiceBrowserAutomationPolicy.permitsNavigation(
                    to: url,
                    allowsLocalDocument: allowsLocalDocument || isSubframeNavigation
                  ) else {
                decisionHandler(.cancel)
                return
            }
            addRequest(url.absoluteString)
            decisionHandler(.allow)
        }
    }
}

extension NetworkFetchMonitor: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == networkLoggerHandlerName {
            if let messageBody = message.body as? [String: Any] {
                if let url = messageBody["url"] as? String {
                    addRequest(url)
                } else if let type = messageBody["type"] as? String {
                    if type == "requests-truncated" {
                        DispatchQueue.main.async {
                            self.requestsTruncated = true
                        }
                    } else if type == "click-results" {
                        if let results = messageBody["results"] as? [String: Any] {
                            if let clickResults = results["clickResults"] as? [[String: Any]] {
                                DispatchQueue.main.async {
                                    for clickResult in clickResults {
                                        if let selector = clickResult["selector"] as? String,
                                           let success = clickResult["success"] as? Bool, success {
                                            self.elementsClicked.append(selector)
                                        }
                                    }
                                }
                            }

                            if let waitResults = results["waitResults"] as? [String: Bool] {
                                DispatchQueue.main.async {
                                    self.waitResults = waitResults
                                }
                            }
                        }
                    } else if type == "cookies" {
                        // Do not trust subframe JavaScript to choose the cookie
                        // scope. `captureCookies` reads the isolated WebKit jar
                        // and applies host/path/secure rules for the effective
                        // main-frame URL instead.
                        return
                    }
                }
            }
        }
    }
}
#else
private enum TVNetworkFetchExecutor {
    private static let maximumResponseBytes = 10_000_000

    static func execute(
        urlString: String,
        options: NetworkFetchOptions,
        operation: ServiceSandboxOperation,
        session: URLSession?
    ) async -> [String: Any] {
        if options.htmlContent?.isEmpty == false
            || !options.clickSelectors.isEmpty
            || !options.waitForSelectors.isEmpty {
            return failure(
                originalURL: urlString,
                error: ServiceCompatibilityError.browserAutomationRequired.localizedDescription
            )
        }

        guard let url = ServiceModuleURLParser.url(urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            return failure(
                originalURL: urlString,
                error: ServiceCompatibilityError.unsupportedTransport.localizedDescription
            )
        }

        do {
            var rawHeaders = options.headers
            rawHeaders["User-Agent"] = rawHeaders["User-Agent"] ?? URLSession.randomUserAgent
            rawHeaders["Accept"] = rawHeaders["Accept"]
                ?? "text/html,application/xhtml+xml,application/json,text/plain;q=0.9,*/*;q=0.8"
            var request = URLRequest(
                url: url,
                timeoutInterval: TimeInterval(min(max(options.timeoutSeconds, 1), 60))
            )
            request.httpMethod = "GET"
            for (name, value) in boundedHeaders(rawHeaders) {
                request.setValue(value, forHTTPHeaderField: name)
            }
            let ownedSession: URLSession?
            let requestSession: URLSession
            if let session {
                ownedSession = nil
                requestSession = session
            } else {
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpShouldSetCookies = true
                configuration.httpCookieAcceptPolicy = .always
                let created = URLSession(
                    configuration: configuration,
                    delegate: FetchDelegate(allowRedirects: true),
                    delegateQueue: nil
                )
                ownedSession = created
                requestSession = created
            }
            defer { ownedSession?.finishTasksAndInvalidate() }
            let (data, response) = try await requestSession.boundedData(
                for: request,
                maximumResponseBytes: maximumResponseBytes,
                allowRedirects: true
            )

            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            let body = decodedText(from: data, response: httpResponse)
            let responseHeaders = CloudflareBypassManager.headersDictionary(from: httpResponse)
            if CloudflareBypassManager.isChallengeResponse(
                status: httpResponse.statusCode,
                body: body,
                headers: responseHeaders
            ) {
                Logger.shared.log(
                    "Service networkFetch hit Cloudflare challenge service=\(operation.serviceName) operation=\(operation.operation) target=\(ServiceSandboxState.redactedURL(url.absoluteString)) \(CloudflareBypassManager.challengeDebugSummary(status: httpResponse.statusCode, body: body, headers: responseHeaders))",
                    type: "Service"
                )
                await CloudflareBypassManager.shared.flagPendingVerification(for: url)
                return failure(
                    originalURL: url.absoluteString,
                    error: ServiceCompatibilityError.interactiveChallengeRequired.localizedDescription
                )
            }

            let finalURL = httpResponse.url?.absoluteString ?? url.absoluteString
            let outputURL = ServiceBrowserOutputBoundary.boundedURLString(finalURL)
                ?? ServiceSandboxState.redactedURL(finalURL)
            var outputRequests: [String] = []
            var outputRequestBytes = 0
            let requestDisposition = ServiceBrowserOutputBoundary.appendRequest(
                finalURL,
                to: &outputRequests,
                totalBytes: &outputRequestBytes
            )
            let cutoffMatched = options.cutoff.map {
                !$0.isEmpty && finalURL.localizedCaseInsensitiveContains($0)
            } ?? false
            let cookieValues = options.returnCookies
                ? responseCookies(from: httpResponse, for: httpResponse.url ?? url)
                : [:]
            let boundedHTML = ServiceBrowserOutputBoundary.boundedHTMLPrefix(body)
            let htmlValue: Any = options.returnHTML ? boundedHTML.html : NSNull()
            let cookieValue: Any = cookieValues.isEmpty ? NSNull() : cookieValues

            Logger.shared.log(
                "Service networkFetch completed service=\(operation.serviceName) operation=\(operation.operation) requestCount=1 original=\(ServiceSandboxState.redactedURL(finalURL)) cutoff=\(cutoffMatched)",
                type: "Service"
            )

            return [
                "originalUrl": outputURL,
                "requests": outputRequests,
                "requestsTruncated": requestDisposition == .truncated,
                "html": htmlValue,
                "cookies": cookieValue,
                "success": true,
                "cutoffTriggered": cutoffMatched,
                "cutoffUrl": cutoffMatched ? finalURL : NSNull(),
                "htmlCaptured": options.returnHTML,
                "htmlTruncated": options.returnHTML && boundedHTML.truncated,
                "cookiesCaptured": !cookieValues.isEmpty,
                "elementsClicked": [],
                "waitResults": [:]
            ]
        } catch BoundedURLSessionError.responseTooLarge {
            Logger.shared.log(
                "Service networkFetch rejected oversized response service=\(operation.serviceName) operation=\(operation.operation) target=\(ServiceSandboxState.redactedURL(urlString)) limitBytes=\(maximumResponseBytes)",
                type: "Error"
            )
            return failure(
                originalURL: urlString,
                error: ServiceCompatibilityError.responseTooLarge.localizedDescription
            )
        } catch {
            let safeError = "Network request failed (\(servicePinnedNetworkErrorToken(error)))."
            Logger.shared.log(
                "Service networkFetch failed service=\(operation.serviceName) operation=\(operation.operation) target=\(ServiceSandboxState.redactedURL(urlString))",
                type: "Error"
            )
            return failure(originalURL: urlString, error: safeError)
        }
    }

    private static func boundedHeaders(_ headers: [String: String]) -> [String: String] {
        let managedNames: Set<String> = [
            "connection", "content-length", "host", "keep-alive", "proxy-authenticate",
            "proxy-authorization", "proxy-connection", "te", "trailer", "transfer-encoding",
            "upgrade"
        ]
        let validNameCharacters = CharacterSet(
            charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        )
        var accepted: [String: String] = [:]
        var totalBytes = 0
        for (rawName, rawValue) in headers.sorted(by: { $0.key.lowercased() < $1.key.lowercased() }) {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let nameIsValid = !name.isEmpty && name.unicodeScalars.allSatisfy {
                $0.value < 128 && validNameCharacters.contains($0)
            }
            let valueIsValid = value.unicodeScalars.allSatisfy {
                $0.value == 9 || $0.value >= 32 && $0.value != 127
            }
            let entryBytes = name.utf8.count + value.utf8.count + 4
            guard accepted.count < 64,
                  name.utf8.count <= 128,
                  value.utf8.count <= 16 * 1_024,
                  entryBytes <= 64 * 1_024 - totalBytes,
                  nameIsValid,
                  valueIsValid,
                  !managedNames.contains(name.lowercased()) else {
                continue
            }
            accepted[name] = value
            totalBytes += entryBytes
        }
        return accepted
    }

    private static func failure(originalURL: String, error: String) -> [String: Any] {
        [
            "originalUrl": ServiceSandboxState.redactedURL(originalURL),
            "requests": [],
            "requestsTruncated": false,
            "html": NSNull(),
            "cookies": NSNull(),
            "success": false,
            "error": error,
            "cutoffTriggered": false,
            "cutoffUrl": NSNull(),
            "htmlCaptured": false,
            "htmlTruncated": false,
            "cookiesCaptured": false,
            "elementsClicked": [],
            "waitResults": [:]
        ]
    }

    private static func decodedText(from data: Data, response: HTTPURLResponse?) -> String {
        if let decoded = ServiceResponseTextDecoding.text(
            from: data,
            declaredEncoding: .utf8,
            response: response
        ) {
            return decoded.text
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func responseCookies(from response: HTTPURLResponse?, for url: URL) -> [String: String] {
        guard let response else { return [:] }
        let headerFields = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            result[String(describing: pair.key)] = String(describing: pair.value)
        }
        return HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
            .reduce(into: [String: String]()) { result, cookie in
                result[cookie.name] = cookie.value
            }
    }
}

final class NetworkFetchSimpleManager: NSObject, ObservableObject {
    static let shared = NetworkFetchSimpleManager()

    private override init() {
        super.init()
    }

    func performNetworkFetch(
        urlString: String,
        timeoutSeconds: Int,
        htmlContent: String? = nil,
        headers: [String: String] = [:],
        operation: ServiceSandboxOperation,
        sandbox: ServiceSandboxState,
        resolve: JSValue,
        reject: JSValue,
        nativeLease: ServiceSandboxNativeOperationLease
    ) {
        let options = NetworkFetchOptions(
            timeoutSeconds: timeoutSeconds,
            headers: headers,
            returnHTML: false,
            returnCookies: false,
            htmlContent: htmlContent
        )
        let task = Task { [nativeLease] in
            defer { nativeLease.finish() }
            guard nativeLease.isActive else { return }
            let result = await TVNetworkFetchExecutor.execute(
                urlString: urlString,
                options: options,
                operation: operation,
                session: sandbox.networkSession()
            )
            sandbox.performJavaScriptCallback {
                if !resolve.isUndefined {
                    resolve.call(withArguments: [[
                        "originalUrl": result["originalUrl"] ?? ServiceSandboxState.redactedURL(urlString),
                        "requests": result["requests"] ?? [],
                        "requestsTruncated": result["requestsTruncated"] ?? false,
                        "success": result["success"] ?? false,
                        "error": result["error"] ?? NSNull()
                    ]])
                }
            }
        }
        nativeLease.installCancellationHandler {
            task.cancel()
        }
    }
}

final class NetworkFetchManager: NSObject, ObservableObject {
    static let shared = NetworkFetchManager()

    private override init() {
        super.init()
    }

    func performNetworkFetch(
        urlString: String,
        options: NetworkFetchOptions,
        operation: ServiceSandboxOperation,
        sandbox: ServiceSandboxState,
        resolve: JSValue,
        reject: JSValue,
        nativeLease: ServiceSandboxNativeOperationLease
    ) {
        let task = Task { [nativeLease] in
            defer { nativeLease.finish() }
            guard nativeLease.isActive else { return }
            let result = await TVNetworkFetchExecutor.execute(
                urlString: urlString,
                options: options,
                operation: operation,
                session: sandbox.networkSession()
            )
            sandbox.performJavaScriptCallback {
                if !resolve.isUndefined {
                    resolve.call(withArguments: [result])
                }
            }
        }
        nativeLease.installCancellationHandler {
            task.cancel()
        }
    }
}
#endif
