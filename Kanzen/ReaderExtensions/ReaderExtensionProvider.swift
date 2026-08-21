// Copyright 2026 Eclipse contributors
// SPDX-License-Identifier: Apache-2.0
//
// Provider-neutral Reader Extensions API. The method names mirror the public
// Mangayomi extension contract at commit
// 4eec7aca6f1c8bd563d0bc79bcf895f46bb30b74, with Eclipse-owned Swift models.
// See Eclipse/Legal/ReaderExtensions/NOTICE.txt for provenance and notices.

import Foundation

extension Notification.Name {
    static let readerExtensionResourceHeadersDidChange = Notification.Name(
        "Eclipse.ReaderExtensions.ResourceHeadersDidChange"
    )
}

protocol ReaderSourceProvider: AnyObject {
    var source: ReaderExtensionInstalledSource { get }

    func popular(page: Int) async throws -> ReaderExtensionPagedResult
    func latest(page: Int) async throws -> ReaderExtensionPagedResult
    func search(query: String, page: Int, filters: [ReaderExtensionFilter]) async throws -> ReaderExtensionPagedResult
    func detail(itemKey: String) async throws -> ReaderExtensionItem
    func chapters(itemKey: String) async throws -> [ReaderExtensionChapter]
    func pages(chapterKey: String) async throws -> [ReaderExtensionPage]
    func chapterHTML(chapterKey: String, chapterTitle: String) async throws -> String
    /// Source-wide request headers used by Mangayomi for covers and page
    /// images. These remain process-local and are sanitized again for the
    /// destination origin by the secure transport immediately before use.
    func resourceHeaders() async throws -> [String: String]
    func filters() async throws -> [ReaderExtensionFilter]
    func preferences() async throws -> [ReaderExtensionPreference]
}

/// One bounded, redacted diagnostic identity shared by repository, runtime,
/// and resource-loading logs. Provider-owned strings never enter the log
/// without passing through `safeLabel`, and operation names are host-owned.
struct ReaderExtensionDiagnosticContext: Sendable {
    let sourceID: String
    let sourceName: String
    let runtimeKind: String

    init(source: ReaderExtensionInstalledSource) {
        sourceID = String(source.id.rawValue.prefix(12))
        sourceName = source.name
        runtimeKind = Self.runtimeKind(source.implementation)
    }

    init(catalog: ReaderExtensionCatalogSource) {
        sourceID = String(catalog.id.rawValue.prefix(12))
        sourceName = catalog.name
        runtimeKind = Self.runtimeKind(catalog.implementation)
    }

    init(repositoryID: String, name: String) {
        sourceID = String(repositoryID.prefix(12))
        sourceName = name
        runtimeKind = "repository"
    }

    init(sourceID: ReaderExtensionSourceID, name: String = "Unknown Source", runtimeKind: String = "unknown") {
        self.sourceID = String(sourceID.rawValue.prefix(12))
        sourceName = name
        self.runtimeKind = runtimeKind
    }

    private static func runtimeKind(_ implementation: ReaderExtensionImplementation) -> String {
        switch implementation {
        case .javascript: return "mangayomi-js"
        case .madara: return "mangayomi-native-madara"
        case .mangaReader: return "mangayomi-native-mangareader"
        case .mangaBox: return "mangayomi-native-mangabox"
        case .mmrcms: return "mangayomi-native-mmrcms"
        case .nepNep: return "mangayomi-native-nepnep"
        case .unsupportedNative: return "unsupported"
        }
    }
}

enum ReaderExtensionDiagnostics {
    static let lifecycleType = "ReaderExtensionLifecycle"
    static let repositoryType = "ReaderExtensionRepository"
    static let runtimeType = "ReaderExtensionRuntime"
    static let networkType = "ReaderExtensionNetwork"

    @discardableResult
    static func operation<Value>(
        context: ReaderExtensionDiagnosticContext,
        name: String,
        type: String = runtimeType,
        resultCount: ((Value) -> Int?)? = nil,
        _ body: () async throws -> Value
    ) async throws -> Value {
        let startedAt = Date()
        record(context: context, operation: name, event: "started", type: type)
        do {
            let value = try await body()
            record(
                context: context,
                operation: name,
                event: "succeeded",
                type: type,
                elapsedMs: elapsedMilliseconds(since: startedAt),
                count: resultCount?(value) ?? nil
            )
            return value
        } catch {
            recordFailure(
                context: context,
                operation: name,
                error: error,
                type: type,
                elapsedMs: elapsedMilliseconds(since: startedAt)
            )
            throw error
        }
    }

    static func record(
        context: ReaderExtensionDiagnosticContext,
        operation: String,
        event: String,
        type: String,
        stage: String? = nil,
        elapsedMs: Int? = nil,
        count: Int? = nil
    ) {
        var fields = baseFields(context: context, operation: operation, event: event)
        if let stage { fields.append("stage=\(safeToken(stage))") }
        if let elapsedMs { fields.append("elapsedMs=\(max(0, elapsedMs))") }
        if let count { fields.append("count=\(max(0, count))") }
        ReaderLogger.shared.log(fields.joined(separator: " "), type: type)
    }

    static func recordFailure(
        context: ReaderExtensionDiagnosticContext,
        operation: String,
        error: Error,
        type: String,
        stage: String? = nil,
        elapsedMs: Int? = nil
    ) {
        var fields = baseFields(context: context, operation: operation, event: "failed")
        if let stage { fields.append("stage=\(safeToken(stage))") }
        if let elapsedMs { fields.append("elapsedMs=\(max(0, elapsedMs))") }
        fields.append("error=\(errorCode(error))")
        ReaderLogger.shared.log(fields.joined(separator: " "), type: type)
    }

    static func safeLabel(_ rawValue: String) -> String {
        let withoutURLs = rawValue.replacingOccurrences(
            of: #"(?i)https?://[^\s]+"#,
            with: "<url>",
            options: .regularExpression
        )
        let withoutControls = withoutURLs.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        let collapsed = String(String.UnicodeScalarView(withoutControls))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let redacted = ReaderLogger.redact(collapsed)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return String(redacted.prefix(96))
    }

    static func errorCode(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let urlError = error as? URLError {
            return "transport-\(urlError.code.rawValue)"
        }
        guard let error = error as? ReaderExtensionError else { return "system-error" }
        switch error {
        case .invalidRepositoryURL: return "invalid-repository-url"
        case .invalidManifest: return "invalid-manifest"
        case .sourceNotFound: return "source-not-found"
        case .unsupportedSource: return "unsupported-source"
        case .restrictiveLicense: return "restrictive-license"
        case .unknownLicenseNeedsConsent: return "license-consent-required"
        case .updateConsentRequired: return "update-consent-required"
        case .insecureURL: return "insecure-url"
        case .privateNetworkDestination: return "private-network-destination"
        case .domainConsentRequired: return "domain-consent-required"
        case .contentTooLarge: return "content-too-large"
        case .unsupportedArchive: return "unsupported-archive"
        case .invalidScriptEncoding: return "invalid-script-encoding"
        case .prohibitedScriptConstruct: return "prohibited-script-construct"
        case .runtimeUnavailable: return "runtime-unavailable"
        case .runtimeTimedOut: return "runtime-timeout"
        case .sourceQuarantined: return "source-quarantined"
        case .runtimeIntegrityFailed: return "runtime-integrity-failed"
        case .runtimeFailed: return "runtime-failed"
        case .resultInvalid: return "invalid-result"
        case .persistenceFailed(let reason):
            let normalized = reason.lowercased()
            if normalized.contains("metadata"), normalized.contains("validation") {
                return "metadata-validation-failed"
            }
            return "persistence-failed"
        case .browserVerificationRequired: return "browser-verification-required"
        }
    }

    private static func baseFields(
        context: ReaderExtensionDiagnosticContext,
        operation: String,
        event: String
    ) -> [String] {
        [
            "event=\(safeToken(event))",
            "runtime=\(safeToken(context.runtimeKind))",
            "sourceID=\(safeToken(context.sourceID))",
            "sourceName=\"\(safeLabel(context.sourceName))\"",
            "operation=\(safeToken(operation))"
        ]
    }

    private static func safeToken(_ value: String) -> String {
        let permitted = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = value.unicodeScalars.filter { permitted.contains($0) }
        let result = String(String.UnicodeScalarView(scalars))
        return String((result.isEmpty ? "unknown" : result).prefix(64))
    }

    static func elapsedMilliseconds(since date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date) * 1_000))
    }
}

/// Central operation instrumentation for both JavaScript and native
/// Mangayomi-compatible providers. This intentionally logs operation-level
/// counts only: search text, item/chapter keys, URLs, headers, cookies, script
/// bytes, and page contents never cross the diagnostic boundary.
final class ReaderExtensionLoggingProvider: ReaderSourceProvider {
    let source: ReaderExtensionInstalledSource
    private let wrapped: any ReaderSourceProvider
    private let context: ReaderExtensionDiagnosticContext

    init(wrapping provider: any ReaderSourceProvider) {
        wrapped = provider
        source = provider.source
        context = ReaderExtensionDiagnosticContext(source: provider.source)
    }

    func popular(page: Int) async throws -> ReaderExtensionPagedResult {
        try await ReaderExtensionDiagnostics.operation(
            context: context,
            name: "popular",
            resultCount: { $0.items.count }
        ) { try await wrapped.popular(page: page) }
    }

    func latest(page: Int) async throws -> ReaderExtensionPagedResult {
        try await ReaderExtensionDiagnostics.operation(
            context: context,
            name: "latest",
            resultCount: { $0.items.count }
        ) { try await wrapped.latest(page: page) }
    }

    func search(query: String, page: Int, filters: [ReaderExtensionFilter]) async throws -> ReaderExtensionPagedResult {
        try await ReaderExtensionDiagnostics.operation(
            context: context,
            name: "search",
            resultCount: { $0.items.count }
        ) { try await wrapped.search(query: query, page: page, filters: filters) }
    }

    func detail(itemKey: String) async throws -> ReaderExtensionItem {
        try await ReaderExtensionDiagnostics.operation(context: context, name: "detail") {
            try await wrapped.detail(itemKey: itemKey)
        }
    }

    func chapters(itemKey: String) async throws -> [ReaderExtensionChapter] {
        try await ReaderExtensionDiagnostics.operation(
            context: context,
            name: "chapters",
            resultCount: { $0.count }
        ) { try await wrapped.chapters(itemKey: itemKey) }
    }

    func pages(chapterKey: String) async throws -> [ReaderExtensionPage] {
        try await ReaderExtensionDiagnostics.operation(
            context: context,
            name: "pages",
            resultCount: { $0.count }
        ) { try await wrapped.pages(chapterKey: chapterKey) }
    }

    func chapterHTML(chapterKey: String, chapterTitle: String) async throws -> String {
        try await ReaderExtensionDiagnostics.operation(context: context, name: "chapter-html") {
            try await wrapped.chapterHTML(chapterKey: chapterKey, chapterTitle: chapterTitle)
        }
    }

    func resourceHeaders() async throws -> [String: String] {
        try await ReaderExtensionDiagnostics.operation(
            context: context,
            name: "resource-headers",
            resultCount: { $0.count }
        ) { try await wrapped.resourceHeaders() }
    }

    func filters() async throws -> [ReaderExtensionFilter] {
        try await ReaderExtensionDiagnostics.operation(
            context: context,
            name: "filters",
            resultCount: { $0.count }
        ) { try await wrapped.filters() }
    }

    func preferences() async throws -> [ReaderExtensionPreference] {
        try await ReaderExtensionDiagnostics.operation(
            context: context,
            name: "preferences",
            resultCount: { $0.count }
        ) { try await wrapped.preferences() }
    }
}

extension ReaderSourceProvider {
    func latest(page: Int) async throws -> ReaderExtensionPagedResult {
        try await popular(page: page)
    }

    func chapterHTML(chapterKey: String, chapterTitle: String) async throws -> String {
        throw ReaderExtensionError.unsupportedSource
    }

    func resourceHeaders() async throws -> [String: String] { [:] }
    func filters() async throws -> [ReaderExtensionFilter] { [] }
    func preferences() async throws -> [ReaderExtensionPreference] { [] }
}

/// Composes host defaults, source-wide Mangayomi headers, and per-page
/// overrides without allowing differently-cased duplicate HTTP field names.
/// Later layers win, matching the upstream resource-loading behavior.
enum ReaderExtensionResourceHeaderPolicy {
    static func merging(_ layers: [[String: String]]) throws -> [String: String] {
        var merged: [String: String] = [:]
        var canonicalNames: [String: String] = [:]

        for layer in layers {
            let sanitized = try ReaderExtensionSecurityPolicy.sanitizedHeaders(
                layer,
                crossOrigin: false
            )
            // JSON objects become unordered Swift dictionaries. Sorting makes
            // pathological case-only duplicates deterministic.
            for name in sanitized.keys.sorted() {
                guard let value = sanitized[name] else { continue }
                let lower = name.lowercased()
                if let priorName = canonicalNames[lower] {
                    merged.removeValue(forKey: priorName)
                }
                canonicalNames[lower] = name
                merged[name] = value
            }
        }

        return try ReaderExtensionSecurityPolicy.sanitizedHeaders(
            merged,
            crossOrigin: false
        )
    }
}

protocol ReaderExtensionNetworkClient: AnyObject, Sendable {
    func request(_ request: ReaderExtensionNetworkRequest) async throws -> ReaderExtensionNetworkResponse
}

struct ReaderExtensionNetworkRequest: Sendable {
    enum Method: String, Sendable {
        case head = "HEAD"
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case patch = "PATCH"
        case delete = "DELETE"
        case options = "OPTIONS"
    }

    /// Provider/runtime calls are source-scoped and may intentionally share
    /// authentication across approved hosts. Remote sign-in documents are a
    /// browser trust boundary and may use ambient cookies only on their exact
    /// initiating host; this distinction prevents approved-origin CSRF.
    enum CookieAccessPolicy: Sendable {
        case sourceScoped
        case sameOriginHostOnly
    }

    /// Repository indexes are public, cookie-free documents and commonly sit
    /// behind HTTPS vanity/CDN redirects. Provider traffic remains restricted
    /// to explicitly approved domains. Passive page/cover fetches that start
    /// on an approved host use the mixed policy: approved hops keep their
    /// cookie scope while a redirect onto an outside image CDN degrades to a
    /// cookie-free public-HTTPS hop instead of failing on consent — the
    /// strict policy punished exactly the hosts the user had approved.
    enum RedirectPolicy: Sendable, Equatable {
        case approvedDomainsOnly
        case approvedDomainsThenPublicHTTPS
        case publicHTTPS
    }

    var method: Method
    var url: URL
    var headers: [String: String]
    var body: Data?
    var sourceID: ReaderExtensionSourceID
    var approvedDomains: Set<String>
    var baseDomain: String?
    /// A host-owned capability used only for native image/asset hotlinking.
    /// The secure client validates and reduces it to an origin before adding
    /// the header. Provider/JavaScript header dictionaries cannot grant this.
    var hostGeneratedOriginReferer: URL?
    var allowsCookies: Bool
    var cookieAccessPolicy: CookieAccessPolicy
    var redirectPolicy: RedirectPolicy
    /// The decoded response-body bound for this operation. Ordinary runtime,
    /// catalog, and HTML calls use 8 MiB; the image-page facade may explicitly
    /// opt into the transport's separately validated 32 MiB ceiling.
    var maximumResponseBytes: Int

    init(
        method: Method = .get,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil,
        sourceID: ReaderExtensionSourceID,
        approvedDomains: Set<String>,
        baseDomain: String? = nil,
        hostGeneratedOriginReferer: URL? = nil,
        allowsCookies: Bool = true,
        cookieAccessPolicy: CookieAccessPolicy = .sourceScoped,
        redirectPolicy: RedirectPolicy = .approvedDomainsOnly,
        maximumResponseBytes: Int = ReaderExtensionSecurityPolicy.maximumResponseBytes
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.sourceID = sourceID
        self.approvedDomains = approvedDomains
        self.baseDomain = baseDomain
        self.hostGeneratedOriginReferer = hostGeneratedOriginReferer
        self.allowsCookies = allowsCookies
        self.cookieAccessPolicy = cookieAccessPolicy
        self.redirectPolicy = redirectPolicy
        self.maximumResponseBytes = maximumResponseBytes
    }
}

struct ReaderExtensionNetworkResponse: Sendable {
    var statusCode: Int
    var finalURL: URL
    var headers: [String: String]
    var body: Data
    /// Narrow Mangayomi compatibility view of host-added request material.
    /// The secure transport may expose only the source-scoped Cookie header
    /// it actually sent. Provider Authorization and other credential-like
    /// headers are deliberately never reflected here.
    var extensionVisibleRequestHeaders: [String: String] = [:]

    var bodyString: String {
        String(data: body, encoding: .utf8) ?? ""
    }
}

protocol ReaderExtensionPreferenceStore: AnyObject, Sendable {
    func value(for key: String) -> ReaderExtensionPreferenceValue?
    func setValue(_ value: ReaderExtensionPreferenceValue, for key: String) throws
    func secret(for key: String) throws -> String?
    func setSecret(_ value: String?, for key: String) throws
    func shouldStoreAsSecret(_ key: String) -> Bool
    func mayReadSecret(_ key: String) -> Bool
}

extension ReaderExtensionPreferenceStore {
    func shouldStoreAsSecret(_ key: String) -> Bool {
        ReaderExtensionSecurityPolicy.isCredentialLikePreferenceKey(key)
    }

    // Secret reads are a capability granted only by the current, validated
    // source schema. Credential-like naming is a storage-safety heuristic,
    // never authorization to recover an older schema's Keychain value.
    func mayReadSecret(_: String) -> Bool { false }
}

final class ReaderExtensionInMemoryPreferenceStore: ReaderExtensionPreferenceStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: ReaderExtensionPreferenceValue]
    private var secrets: [String: String]

    init(values: [String: ReaderExtensionPreferenceValue] = [:], secrets: [String: String] = [:]) {
        self.values = values
        self.secrets = secrets
    }

    func value(for key: String) -> ReaderExtensionPreferenceValue? {
        lock.withReaderExtensionLock { values[key] }
    }

    func setValue(_ value: ReaderExtensionPreferenceValue, for key: String) throws {
        try ReaderExtensionSecurityPolicy.validatePreference(key: key, value: value)
        try lock.withReaderExtensionLock {
            guard values[key] != nil || values.count < ReaderExtensionSecurityPolicy.maximumPreferenceCount else {
                throw ReaderExtensionError.contentTooLarge
            }
            values[key] = value
        }
    }

    func secret(for key: String) throws -> String? {
        lock.withReaderExtensionLock { secrets[key] }
    }

    func setSecret(_ value: String?, for key: String) throws {
        try ReaderExtensionSecurityPolicy.validatePreferenceSecret(key: key, value: value)
        try lock.withReaderExtensionLock {
            guard value == nil || secrets[key] != nil || secrets.count < ReaderExtensionSecurityPolicy.maximumPreferenceCount else {
                throw ReaderExtensionError.contentTooLarge
            }
            secrets[key] = value
        }
    }
}

extension NSLock {
    fileprivate func withReaderExtensionLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}
