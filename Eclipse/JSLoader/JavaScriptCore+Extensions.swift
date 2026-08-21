//
//  JSContext+Extensions.swift
//  Sora
//
//  Created by Francesco on 07/08/25.
//

import JavaScriptCore
import Network

private let serviceFetchMaximumResponseBytes = 10_000_000

final class ServiceJavaScriptSessionRegistry: @unchecked Sendable {
    static let shared = ServiceJavaScriptSessionRegistry()
    private static let maximumSessions = 256

    private let lock = NSLock()
    private var sessions: [String: URLSession] = [:]
    private var sessionOrder: [String] = []

    func session(profileID: UUID, serviceID: UUID?) -> URLSession {
        guard let serviceID else { return Self.makeSession() }
        let key = "\(profileID.uuidString.lowercased()):\(serviceID.uuidString.lowercased())"

        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[key] {
            if let index = sessionOrder.firstIndex(of: key) {
                sessionOrder.remove(at: index)
                sessionOrder.append(key)
            }
            return existing
        }
        if sessions.count >= Self.maximumSessions,
           let oldest = sessionOrder.first {
            sessionOrder.removeFirst()
            sessions.removeValue(forKey: oldest)
        }
        let session = Self.makeSession()
        sessions[key] = session
        sessionOrder.append(key)
        return session
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpAdditionalHeaders = ["User-Agent": URLSession.randomUserAgent]
        return URLSession(
            configuration: configuration,
            delegate: FetchDelegate(allowRedirects: true),
            delegateQueue: nil
        )
    }
}

final class ServiceJavaScriptTimerRegistry: @unchecked Sendable {
    static let maximumLiveTimers = 64
    static let maximumDelayMilliseconds = 60_000.0

    private let lock = NSLock()
    private var workItems: [Int: DispatchWorkItem] = [:]
    private var nextID = 1
    private var invalidated = false

    static func boundedDelay(
        milliseconds rawValue: Double,
        minimumMilliseconds: Double = 0
    ) -> TimeInterval {
        let lower = max(minimumMilliseconds, 0)
        let milliseconds: Double
        if rawValue.isNaN || rawValue == -.infinity {
            milliseconds = lower
        } else if rawValue == .infinity {
            milliseconds = maximumDelayMilliseconds
        } else {
            milliseconds = min(max(rawValue, lower), maximumDelayMilliseconds)
        }
        return milliseconds / 1_000
    }

    func reserveID() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !invalidated, workItems.count < Self.maximumLiveTimers else { return nil }

        for _ in 0...Self.maximumLiveTimers {
            let candidate = nextID
            nextID = candidate == Int.max ? 1 : candidate + 1
            if workItems[candidate] == nil {
                workItems[candidate] = DispatchWorkItem {}
                return candidate
            }
        }
        return nil
    }

    func install(_ workItem: DispatchWorkItem, for id: Int) -> Bool {
        lock.lock()
        guard !invalidated, workItems[id] != nil else {
            lock.unlock()
            workItem.cancel()
            return false
        }
        workItems[id] = workItem
        lock.unlock()
        return true
    }

    func consumeTimeout(_ id: Int) -> Bool {
        lock.lock()
        let active = !invalidated && workItems.removeValue(forKey: id) != nil
        lock.unlock()
        return active
    }

    func isActive(_ id: Int) -> Bool {
        lock.lock()
        let active = !invalidated && workItems[id] != nil
        lock.unlock()
        return active
    }

    func cancel(_ id: Int) {
        lock.lock()
        let workItem = workItems.removeValue(forKey: id)
        lock.unlock()
        workItem?.cancel()
    }

    func invalidate() {
        let items: [DispatchWorkItem]
        lock.lock()
        guard !invalidated else {
            lock.unlock()
            return
        }
        invalidated = true
        items = Array(workItems.values)
        workItems.removeAll(keepingCapacity: false)
        lock.unlock()
        items.forEach { $0.cancel() }
    }

    var liveCount: Int {
        lock.lock()
        let count = workItems.count
        lock.unlock()
        return count
    }
}

struct ServicePinnedRequestHeaders {
    let headers: SkyStreamSanitizedHeaders
    let byteRange: ClosedRange<Int64>?

    init(_ rawHeaders: [String: String], method: String) throws {
        var headersWithoutRange: [String: String] = [:]
        headersWithoutRange.reserveCapacity(rawHeaders.count)
        var rawRange: String?

        for (name, value) in rawHeaders {
            if name.caseInsensitiveCompare("Range") == .orderedSame {
                guard rawRange == nil else { throw SkyStreamSecurityError.duplicateHeader }
                rawRange = value
            } else {
                headersWithoutRange[name] = value
            }
        }

        headers = try SkyStreamHeaderSanitizer.sanitize(
            headersWithoutRange,
            purpose: .pluginRequest
        )
        byteRange = try rawRange.map { value in
            guard method.uppercased() == "GET" else {
                throw SkyStreamSecurityError.invalidByteRange
            }
            return try Self.parseByteRange(value)
        }
    }

    private static func parseByteRange(_ rawValue: String) throws -> ClosedRange<Int64> {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count > 6,
              String(value.prefix(6)).caseInsensitiveCompare("bytes=") == .orderedSame,
              !value.contains(",") else {
            throw SkyStreamSecurityError.invalidByteRange
        }
        let bounds = value.dropFirst(6).split(
            separator: "-",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard bounds.count == 2,
              let lower = Int64(bounds[0]),
              let upper = Int64(bounds[1]),
              lower >= 0,
              upper >= lower else {
            throw SkyStreamSecurityError.invalidByteRange
        }
        let (length, overflow) = upper.subtractingReportingOverflow(lower)
        guard !overflow, length < 1_000_000 else {
            throw SkyStreamSecurityError.invalidByteRange
        }
        return lower...upper
    }
}

func servicePinnedNetworkErrorToken(_ error: Error) -> String {
    if error is CancellationError { return "cancelled" }
    if error is SkyStreamSecurityError { return "security-policy" }
    if let urlError = error as? URLError { return "url-\(urlError.code.rawValue)" }
    if let networkError = error as? NWError {
        switch networkError {
        case .posix(let code): return "nw-posix-\(code.rawValue)"
        case .dns(let code): return "nw-dns-\(code)"
        case .tls(let code): return "nw-tls-\(code)"
        default: return "nw-unknown"
        }
    }
    let nsError = error as NSError
    let safeDomain = String(nsError.domain.unicodeScalars.filter {
        CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
            .contains($0)
    }.prefix(48))
    return "ns-\(safeDomain.isEmpty ? "unknown" : safeDomain)-\(nsError.code)"
}

private func serviceFetchErrorDescription(_ error: Error) -> String {
    if error is BoundedURLSessionError
        || (error as? SkyStreamSecurityError) == .responseTooLarge {
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

enum ServiceJavaScriptValueBoundaryError: Error, Equatable {
    case invalidShape
    case tooManyEntries
    case valueTooLarge
    case invalidValue
}

/// Reads untrusted JavaScript collections without first bridging the complete
/// value through `toDictionary()`/`toArray()`. The captured helpers return
/// either a bounded list of own keys or one property at a time, so Swift never
/// materializes an attacker-sized native collection before checking its size.
struct ServiceJavaScriptValueReader {
    private let ownKeysFunction: JSValue
    private let propertyFunction: JSValue
    private let typeFunction: JSValue

    init?(context: JSContext) {
        guard let helpers = context.evaluateScript(
            #"""
            (function () {
                "use strict";
                const hasOwn = Object.prototype.hasOwnProperty;
                const apply = Reflect.apply;
                const isArray = Array.isArray;
                return {
                    ownKeys: function (value, maximumCount, maximumKeyLength, tolerant) {
                        try {
                            if (value === null || typeof value !== "object" || isArray(value)) {
                                return null;
                            }
                            const keys = [];
                            let visited = 0;
                            for (const key in value) {
                                visited += 1;
                                if (visited > maximumCount) return tolerant ? keys : null;
                                if (apply(hasOwn, value, [key])) {
                                    if (key.length > maximumKeyLength) {
                                        if (tolerant) continue;
                                        return null;
                                    }
                                    keys.push(key);
                                }
                            }
                            return keys;
                        } catch (_) {
                            return null;
                        }
                    },
                    property: function (value, key) {
                        try {
                            return { ok: true, value: value[key] };
                        } catch (_) {
                            return { ok: false };
                        }
                    },
                    type: function (value) {
                        try {
                            return typeof value;
                        } catch (_) {
                            return "invalid";
                        }
                    }
                };
            })()
            """#
        ),
        let ownKeysFunction = helpers.forProperty("ownKeys"),
        let propertyFunction = helpers.forProperty("property"),
        let typeFunction = helpers.forProperty("type"),
        !ownKeysFunction.isUndefined,
        !propertyFunction.isUndefined,
        !typeFunction.isUndefined else {
            return nil
        }
        self.ownKeysFunction = ownKeysFunction
        self.propertyFunction = propertyFunction
        self.typeFunction = typeFunction
    }

    func ownEnumerableKeys(
        of value: JSValue,
        maximumCount: Int,
        maximumKeyBytes: Int,
        tolerant: Bool = false
    ) throws -> [String] {
        guard maximumCount >= 0,
              maximumKeyBytes > 0,
              value.isObject,
              !value.isArray,
              !value.isNull,
              let rawKeys = ownKeysFunction.call(
                withArguments: [value, maximumCount, maximumKeyBytes, tolerant]
              ),
              rawKeys.isArray,
              let rawLength = rawKeys.forProperty("length"),
              rawLength.isNumber else {
            throw ServiceJavaScriptValueBoundaryError.invalidShape
        }
        let length = rawLength.toDouble()
        guard length.isFinite,
              length >= 0,
              length.rounded(.towardZero) == length,
              length <= Double(maximumCount) else {
            throw ServiceJavaScriptValueBoundaryError.tooManyEntries
        }

        var result: [String] = []
        result.reserveCapacity(Int(length))
        for index in 0..<Int(length) {
            guard let keyValue = rawKeys.atIndex(index) else {
                if tolerant { continue }
                throw ServiceJavaScriptValueBoundaryError.valueTooLarge
            }
            guard let key = Self.boundedString(
                    from: keyValue,
                    maximumBytes: maximumKeyBytes
                  ) else {
                if tolerant { continue }
                throw ServiceJavaScriptValueBoundaryError.valueTooLarge
            }
            result.append(key)
        }
        return result
    }

    func property(_ key: Any, of value: JSValue) throws -> JSValue {
        guard let result = propertyFunction.call(withArguments: [value, key]),
              result.isObject,
              result.forProperty("ok")?.toBool() == true,
              let propertyValue = result.forProperty("value") else {
            throw ServiceJavaScriptValueBoundaryError.invalidValue
        }
        return propertyValue
    }

    func arrayLength(of value: JSValue, maximumCount: Int) throws -> Int {
        guard maximumCount >= 0, value.isArray else {
            throw ServiceJavaScriptValueBoundaryError.invalidShape
        }
        let lengthValue = try property("length", of: value)
        guard lengthValue.isNumber else {
            throw ServiceJavaScriptValueBoundaryError.invalidShape
        }
        let length = lengthValue.toDouble()
        guard length.isFinite,
              length >= 0,
              length.rounded(.towardZero) == length,
              length <= Double(maximumCount) else {
            throw ServiceJavaScriptValueBoundaryError.tooManyEntries
        }
        return Int(length)
    }

    func javaScriptType(of value: JSValue) -> String? {
        typeFunction.call(withArguments: [value])?.toString()
    }

    static func boundedString(from value: JSValue, maximumBytes: Int) -> String? {
        guard let data = JSController.boundedUTF8Data(
            from: value,
            maximumBytes: maximumBytes
        ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

enum ServiceJavaScriptNetworkInputBoundary {
    static let maximumURLBytes = 16 * 1_024
    static let maximumMethodBytes = 64
    static let maximumEncodingBytes = 64
    static let maximumHeaderCount = 64
    static let maximumHeaderScanCount = 256
    static let maximumHeaderNameBytes = 128
    static let maximumHeaderValueBytes = 8 * 1_024
    static let maximumHeaderBytes = 32 * 1_024
    static let maximumRequestBodyBytes = 2 * 1_024 * 1_024

    private static let maximumJSONNodes = 4_096
    private static let maximumJSONArrayEntries = 4_096
    private static let maximumJSONObjectEntries = 256
    private static let maximumJSONDepth = 16
    private static let maximumJSONKeyBytes = 1_024
    private indirect enum JSONNode {
        case null
        case boolean(Bool)
        case number(Double)
        case string(String)
        case array([JSONNode])
        case object([(String, JSONNode)])
    }

    private struct JSONBudget {
        var nodes = 0
        var textBytes = 0

        mutating func consumeNode() throws {
            nodes += 1
            guard nodes <= maximumJSONNodes else {
                throw ServiceJavaScriptValueBoundaryError.tooManyEntries
            }
        }

        mutating func consumeText(_ count: Int) throws {
            guard count >= 0,
                  textBytes <= maximumRequestBodyBytes - count else {
                throw ServiceJavaScriptValueBoundaryError.valueTooLarge
            }
            textBytes += count
        }

        var remainingTextBytes: Int {
            max(maximumRequestBodyBytes - textBytes, 0)
        }
    }

    static func urlString(from value: JSValue) throws -> String {
        guard value.isString,
              let string = ServiceJavaScriptValueReader.boundedString(
                from: value,
                maximumBytes: maximumURLBytes
              ) else {
            throw ServiceJavaScriptValueBoundaryError.valueTooLarge
        }
        return string
    }

    static func httpMethod(from value: JSValue?) throws -> String {
        guard let value, !value.isUndefined, !value.isNull else { return "GET" }
        guard value.isString,
              let method = ServiceJavaScriptValueReader.boundedString(
                from: value,
                maximumBytes: maximumMethodBytes
              ), !method.isEmpty,
              method.unicodeScalars.allSatisfy({ scalar in
                let value = scalar.value
                return (value >= 48 && value <= 57)
                    || (value >= 65 && value <= 90)
                    || (value >= 97 && value <= 122)
                    || "!#$%&'*+-.^_`|~".unicodeScalars.contains(scalar)
              }) else {
            throw ServiceJavaScriptValueBoundaryError.invalidValue
        }
        return method
    }

    static func encodingName(from value: JSValue?) throws -> String? {
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        guard value.isString,
              let encoding = ServiceJavaScriptValueReader.boundedString(
                from: value,
                maximumBytes: maximumEncodingBytes
              ) else {
            throw ServiceJavaScriptValueBoundaryError.valueTooLarge
        }
        return encoding
    }

    static func headers(
        from value: JSValue?,
        reader: ServiceJavaScriptValueReader
    ) throws -> [String: String] {
        guard let value, !value.isUndefined, !value.isNull else { return [:] }
        let keys = try reader.ownEnumerableKeys(
            of: value,
            maximumCount: maximumHeaderScanCount,
            maximumKeyBytes: maximumHeaderNameBytes,
            tolerant: true
        )
        var headers: [String: String] = [:]
        headers.reserveCapacity(keys.count)
        var totalBytes = 0

        for key in keys {
            guard headers.count < maximumHeaderCount else { break }
            guard let rawValue = try? reader.property(key, of: value) else { continue }
            if rawValue.isNull || rawValue.isUndefined { continue }

            let stringValue: String
            if rawValue.isString,
               let bounded = ServiceJavaScriptValueReader.boundedString(
                from: rawValue,
                maximumBytes: maximumHeaderValueBytes
               ) {
                stringValue = bounded
            } else if rawValue.isNumber {
                let number = rawValue.toDouble()
                guard number.isFinite,
                      let converted = rawValue.toNumber()?.stringValue,
                      converted.utf8.count <= maximumHeaderValueBytes else {
                    continue
                }
                stringValue = converted
            } else if rawValue.isBoolean {
                stringValue = rawValue.toBool() ? "true" : "false"
            } else {
                continue
            }

            let entryBytes = key.utf8.count + stringValue.utf8.count + 4
            guard entryBytes <= maximumHeaderBytes - totalBytes else { continue }
            totalBytes += entryBytes
            headers[key] = stringValue
        }
        return headers
    }

    static func fetchV2Body(
        from value: JSValue?,
        reader: ServiceJavaScriptValueReader
    ) throws -> String? {
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        if value.isString {
            guard let body = ServiceJavaScriptValueReader.boundedString(
                from: value,
                maximumBytes: maximumRequestBodyBytes
            ) else {
                throw ServiceJavaScriptValueBoundaryError.valueTooLarge
            }
            return body
        }

        var budget = JSONBudget()
        let node = try jsonNode(
            from: value,
            reader: reader,
            depth: 0,
            budget: &budget
        )
        var output = Data()
        output.reserveCapacity(min(budget.textBytes + budget.nodes * 4, maximumRequestBodyBytes))
        try append(node, to: &output)
        guard let body = String(data: output, encoding: .utf8) else {
            throw ServiceJavaScriptValueBoundaryError.invalidValue
        }
        return body
    }

    private static func jsonNode(
        from value: JSValue,
        reader: ServiceJavaScriptValueReader,
        depth: Int,
        budget: inout JSONBudget
    ) throws -> JSONNode {
        guard depth <= maximumJSONDepth else {
            throw ServiceJavaScriptValueBoundaryError.tooManyEntries
        }
        try budget.consumeNode()

        if value.isNull { return .null }
        if value.isBoolean { return .boolean(value.toBool()) }
        if value.isNumber {
            let number = value.toDouble()
            guard number.isFinite else {
                throw ServiceJavaScriptValueBoundaryError.invalidValue
            }
            return .number(number)
        }
        if value.isString {
            guard budget.remainingTextBytes > 0,
                  let string = ServiceJavaScriptValueReader.boundedString(
                    from: value,
                    maximumBytes: budget.remainingTextBytes
                  ) else {
                throw ServiceJavaScriptValueBoundaryError.valueTooLarge
            }
            try budget.consumeText(string.utf8.count)
            return .string(string)
        }
        if value.isArray {
            let count = try reader.arrayLength(
                of: value,
                maximumCount: maximumJSONArrayEntries
            )
            var children: [JSONNode] = []
            children.reserveCapacity(count)
            for index in 0..<count {
                let child = try reader.property(index, of: value)
                guard !child.isUndefined else {
                    throw ServiceJavaScriptValueBoundaryError.invalidValue
                }
                children.append(
                    try jsonNode(
                        from: child,
                        reader: reader,
                        depth: depth + 1,
                        budget: &budget
                    )
                )
            }
            return .array(children)
        }
        guard value.isObject,
              reader.javaScriptType(of: value) == "object" else {
            throw ServiceJavaScriptValueBoundaryError.invalidValue
        }

        let keys = try reader.ownEnumerableKeys(
            of: value,
            maximumCount: maximumJSONObjectEntries,
            maximumKeyBytes: maximumJSONKeyBytes
        )
        var properties: [(String, JSONNode)] = []
        properties.reserveCapacity(keys.count)
        for key in keys {
            try budget.consumeText(key.utf8.count)
            let child = try reader.property(key, of: value)
            guard !child.isUndefined else {
                throw ServiceJavaScriptValueBoundaryError.invalidValue
            }
            properties.append((
                key,
                try jsonNode(
                    from: child,
                    reader: reader,
                    depth: depth + 1,
                    budget: &budget
                )
            ))
        }
        return .object(properties)
    }

    private static func append(_ node: JSONNode, to output: inout Data) throws {
        switch node {
        case .null:
            try append(Data("null".utf8), to: &output)
        case .boolean(let value):
            try append(Data((value ? "true" : "false").utf8), to: &output)
        case .number(let value):
            let encoded = try JSONSerialization.data(
                withJSONObject: NSNumber(value: value),
                options: .fragmentsAllowed
            )
            try append(encoded, to: &output)
        case .string(let value):
            try append(try encodedJSONString(value), to: &output)
        case .array(let children):
            try append(Data("[".utf8), to: &output)
            for (index, child) in children.enumerated() {
                if index > 0 { try append(Data(",".utf8), to: &output) }
                try append(child, to: &output)
            }
            try append(Data("]".utf8), to: &output)
        case .object(let properties):
            try append(Data("{".utf8), to: &output)
            for (index, property) in properties.enumerated() {
                if index > 0 { try append(Data(",".utf8), to: &output) }
                try append(try encodedJSONString(property.0), to: &output)
                try append(Data(":".utf8), to: &output)
                try append(property.1, to: &output)
            }
            try append(Data("}".utf8), to: &output)
        }
    }

    private static func encodedJSONString(_ value: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
    }

    private static func append(_ data: Data, to output: inout Data) throws {
        guard output.count <= maximumRequestBodyBytes - data.count else {
            throw ServiceJavaScriptValueBoundaryError.valueTooLarge
        }
        output.append(data)
    }
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

    func setupNativeFetch(
        sandbox: ServiceSandboxState,
        serviceSession: URLSession
    ) {
        guard let valueReader = ServiceJavaScriptValueReader(context: self) else {
            Logger.shared.log("Service fetch input boundary could not be installed", type: "Error")
            return
        }
        let fetchNativeFunction: @convention(block) (JSValue, JSValue?, JSValue, JSValue) -> Void = { urlValue, headersValue, resolve, reject in
            let urlString: String
            do {
                urlString = try ServiceJavaScriptNetworkInputBoundary.urlString(from: urlValue)
            } catch {
                reject.call(withArguments: ["Service request URL was rejected"])
                return
            }
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
            let headers: [String: String]
            do {
                headers = try ServiceJavaScriptNetworkInputBoundary.headers(
                    from: headersValue,
                    reader: valueReader
                )
            } catch {
                reject.call(withArguments: ["Service request headers were rejected"])
                return
            }
            guard let nativeLease = sandbox.reserveNativeOperation() else {
                reject.call(withArguments: ["Service native operation budget exhausted"])
                return
            }
            var request = URLRequest(url: url)
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            CloudflareBypassManager.shared.applyCachedBypass(to: &request, for: url)
            let callResolve: (String) -> Void = { value in
                sandbox.performJavaScriptCallback {
                    if !resolve.isUndefined {
                        resolve.call(withArguments: [value])
                    }
                }
            }
            let callReject: (String) -> Void = { message in
                sandbox.performJavaScriptCallback {
                    if !reject.isUndefined {
                        reject.call(withArguments: [message])
                    }
                }
            }

            let task = Task { [nativeLease] in
                defer { nativeLease.finish() }
                guard nativeLease.isActive else { return }
                do {
                    let (data, urlResponse) = try await serviceSession.boundedData(
                        for: request,
                        maximumResponseBytes: serviceFetchMaximumResponseBytes
                    )
                    let response = urlResponse as? HTTPURLResponse
                    if let text = ServiceResponseTextDecoding.text(
                        from: data,
                        declaredEncoding: .utf8,
                        response: response
                    )?.text {
                        if let response,
                           CloudflareBypassManager.isChallengeResponse(
                            status: response.statusCode,
                            body: text,
                            headers: CloudflareBypassManager.headersDictionary(from: response)
                           ) {
                            Logger.shared.log(
                                "Service fetch hit Cloudflare challenge service=\(operation.serviceName) operation=\(operation.operation) target=\(ServiceSandboxState.redactedURL(response.url?.absoluteString ?? urlString)) requested=\(ServiceSandboxState.redactedURL(urlString)) \(CloudflareBypassManager.challengeDebugSummary(status: response.statusCode, body: text, headers: CloudflareBypassManager.headersDictionary(from: response)))",
                                type: "Service"
                            )
                            if let recovered = await CloudflareBypassManager.shared.recoverChallengedRequest(
                                for: url,
                                method: request.httpMethod ?? "GET",
                                body: request.httpBody,
                                extraHeaders: request.allHTTPHeaderFields ?? [:],
                                allowRedirects: true
                            ), let recoveredText = ServiceResponseTextDecoding.text(
                                from: recovered.data,
                                declaredEncoding: .utf8,
                                response: recovered.response
                            )?.text {
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
                        Logger.shared.log("Service fetch completed service=\(operation.serviceName) operation=\(operation.operation) target=\(ServiceSandboxState.redactedURL(urlString)) status=\(response?.statusCode ?? 0) bytes=\(data.count)", type: "Service")
                        callResolve(text)
                    } else {
                        let contentType = response?.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
                        Logger.shared.log("Service fetch decode failed service=\(operation.serviceName) operation=\(operation.operation) target=\(ServiceSandboxState.redactedURL(urlString)) status=\(response?.statusCode ?? 0) bytes=\(data.count) contentType=\(contentType)", type: "Error")
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
            nativeLease.installCancellationHandler {
                task.cancel()
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

    func setupFetchV2(
        sandbox: ServiceSandboxState,
        serviceSession: URLSession
    ) {
        guard let valueReader = ServiceJavaScriptValueReader(context: self) else {
            Logger.shared.log("Service fetchv2 input boundary could not be installed", type: "Error")
            return
        }
        let fetchV2NativeFunction: @convention(block) (JSValue, JSValue?, JSValue?, JSValue?, ObjCBool, JSValue?, JSValue, JSValue) -> Void = { urlValue, headersValue, methodValue, bodyValue, redirect, encodingValue, resolve, reject in
            let callResolveEarly: ([String: Any]) -> Void = { dict in
                sandbox.performJavaScriptCallback {
                    if !resolve.isUndefined {
                        resolve.call(withArguments: [dict])
                    }
                }
            }

            let urlString: String
            let httpMethod: String
            let encoding: String?
            do {
                urlString = try ServiceJavaScriptNetworkInputBoundary.urlString(from: urlValue)
                httpMethod = try ServiceJavaScriptNetworkInputBoundary.httpMethod(from: methodValue)
                encoding = try ServiceJavaScriptNetworkInputBoundary.encodingName(from: encodingValue)
            } catch {
                callResolveEarly([
                    "status": 0,
                    "headers": [:],
                    "body": "",
                    "error": "Service request URL, method, or encoding was rejected"
                ])
                return
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

            let headers: [String: String]
            let body: String?
            do {
                headers = try ServiceJavaScriptNetworkInputBoundary.headers(
                    from: headersValue,
                    reader: valueReader
                )
                body = try ServiceJavaScriptNetworkInputBoundary.fetchV2Body(
                    from: bodyValue,
                    reader: valueReader
                )
            } catch {
                callResolveEarly([
                    "status": 0,
                    "headers": [:],
                    "body": "",
                    "error": "Service request input was rejected"
                ])
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = httpMethod

            func getEncoding(from encodingString: String?) -> String.Encoding {
                guard let encodingString = encodingString?.lowercased() else {
                    return .utf8
                }
                guard let resolved = ServiceResponseTextDecoding.encoding(named: encodingString) else {
                    Logger.shared.log("Unknown encoding '\(encodingString)', defaulting to UTF-8", type: "Warning")
                    return .utf8
                }
                return resolved
            }

            let textEncoding = getEncoding(from: encoding)

            func decodedResponseBody(
                from data: Data,
                httpResponse: HTTPURLResponse?
            ) -> (text: String, charset: String)? {
                ServiceResponseTextDecoding.text(
                    from: data,
                    declaredEncoding: textEncoding,
                    response: httpResponse
                )
            }

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

            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
            CloudflareBypassManager.shared.applyCachedBypass(to: &request, for: url)

            let callResolve: ([String: Any]) -> Void = { dict in
                sandbox.performJavaScriptCallback {
                    if !resolve.isUndefined {
                        resolve.call(withArguments: [dict])
                    } else {
                        Logger.shared.log("Resolve callback is undefined", type: "Error")
                    }
                }
            }

            guard let nativeLease = sandbox.reserveNativeOperation() else {
                callResolveEarly([
                    "status": 0,
                    "headers": [:],
                    "body": "",
                    "error": "Service native operation budget exhausted"
                ])
                return
            }

            let task = Task { [nativeLease] in
                defer { nativeLease.finish() }
                guard nativeLease.isActive else { return }
                do {
                    let (data, urlResponse) = try await serviceSession.boundedData(
                        for: request,
                        maximumResponseBytes: serviceFetchMaximumResponseBytes,
                        allowRedirects: redirect.boolValue
                    )
                    let response = urlResponse as? HTTPURLResponse

                    func resolveResponse(data: Data, httpResponse: HTTPURLResponse?) {
                        let status = httpResponse?.statusCode ?? 0
                        var responseDict: [String: Any] = [
                            "status": status,
                            "ok": status >= 200 && status < 300,
                            "url": httpResponse?.url?.absoluteString ?? urlString,
                            "headers": CloudflareBypassManager.headersDictionary(from: httpResponse),
                            "body": ""
                        ]

                        if let decoded = decodedResponseBody(from: data, httpResponse: httpResponse) {
                            responseDict["body"] = decoded.text
                            if decoded.charset.lowercased() != (encoding ?? "utf-8").lowercased() {
                                Logger.shared.log("Service fetchv2 decode warning service=\(operation.serviceName) operation=\(operation.operation) target=\(ServiceSandboxState.redactedURL(urlString)) encoding=\(encoding ?? "utf-8") status=\(status) bytes=\(data.count); decoded as \(decoded.charset)", type: "Warning")
                            }
                            Logger.shared.log("Service fetchv2 completed service=\(operation.serviceName) operation=\(operation.operation) target=\(ServiceSandboxState.redactedURL(urlString)) status=\(status) bytes=\(data.count) charset=\(decoded.charset)", type: "Service")
                            callResolve(responseDict)
                        } else {
                            let contentType = httpResponse?.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
                            Logger.shared.log("Service fetchv2 decode failed service=\(operation.serviceName) operation=\(operation.operation) target=\(ServiceSandboxState.redactedURL(urlString)) status=\(status) bytes=\(data.count) contentType=\(contentType)", type: "Error")
                            callResolve(responseDict)
                        }
                    }

                    let httpResponse = response
                    let responseText = decodedResponseBody(from: data, httpResponse: response)?.text ?? ""
                    if let httpResponse {
                        let responseHeaders = CloudflareBypassManager.headersDictionary(from: httpResponse)
                        if CloudflareBypassManager.isChallengeResponse(
                            status: httpResponse.statusCode,
                            body: responseText,
                            headers: responseHeaders
                        ) {

                            let challengeResponseURL = httpResponse.url ?? url
                            Logger.shared.log(
                                "Service fetchv2 hit Cloudflare challenge service=\(operation.serviceName) operation=\(operation.operation) target=\(ServiceSandboxState.redactedURL(challengeResponseURL.absoluteString)) requested=\(ServiceSandboxState.redactedURL(url.absoluteString)) \(CloudflareBypassManager.challengeDebugSummary(status: httpResponse.statusCode, body: responseText, headers: responseHeaders))",
                                type: "Service"
                            )
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
            nativeLease.installCancellationHandler {
                task.cancel()
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

    func setupTimerFunctions(sandbox: ServiceSandboxState) {
        let timers = ServiceJavaScriptTimerRegistry()
        sandbox.registerInvalidationHandler {
            timers.invalidate()
        }

        let setTimeoutFunction: @convention(block) (JSValue?, Double) -> Int = { callback, delay in
            guard let id = timers.reserveID() else { return 0 }
            guard let callback, !callback.isUndefined, !callback.isNull else {
                timers.cancel(id)
                return 0
            }

            let item = DispatchWorkItem {
                guard timers.isActive(id) else { return }
                sandbox.performJavaScriptCallback {
                    guard timers.consumeTimeout(id) else { return }
                    callback.call(withArguments: [])
                }
            }
            guard timers.install(item, for: id) else { return 0 }
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + ServiceJavaScriptTimerRegistry.boundedDelay(milliseconds: delay),
                execute: item
            )
            return id
        }

        let clearTimerFunction: @convention(block) (Int) -> Void = { id in
            timers.cancel(id)
        }

        let setIntervalFunction: @convention(block) (JSValue?, Double) -> Int = { callback, delay in
            guard let id = timers.reserveID() else { return 0 }
            guard let callback, !callback.isUndefined, !callback.isNull else {
                timers.cancel(id)
                return 0
            }

            let interval = ServiceJavaScriptTimerRegistry.boundedDelay(
                milliseconds: delay,
                minimumMilliseconds: 16
            )
            func schedule() {
                guard timers.isActive(id) else { return }
                let item = DispatchWorkItem {
                    sandbox.performJavaScriptCallback {
                        guard timers.isActive(id) else { return }
                        callback.call(withArguments: [])
                        schedule()
                    }
                }
                guard timers.install(item, for: id) else { return }
                DispatchQueue.global(qos: .utility).asyncAfter(
                    deadline: .now() + interval,
                    execute: item
                )
            }

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

    func setupJavaScriptEnvironment(
        sandbox: ServiceSandboxState,
        serviceSession: URLSession
    ) {
        setupConsoleLogging(sandbox: sandbox)
        setupNativeFetch(sandbox: sandbox, serviceSession: serviceSession)
        setupNetworkFetch(sandbox: sandbox)
        setupNetworkFetchSimple(sandbox: sandbox)
        setupFetchV2(sandbox: sandbox, serviceSession: serviceSession)
        setupFetchAliases()
        setupSoraCompatibility()
        setupTimerFunctions(sandbox: sandbox)
        setupBase64Functions()
        setupScrapingUtilities()
    }
}
