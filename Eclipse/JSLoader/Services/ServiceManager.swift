import CryptoKit
import Foundation
import Network
#if os(tvOS)
import Security
#endif

private final class ServiceCallbackGate<Value>: @unchecked Sendable {
    private enum Outcome {
        case value(Value)
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?
    private var outcome: Outcome?

    /// Returns false when cancellation won before the continuation was
    /// installed. In that case the continuation is resumed immediately.
    func install(_ continuation: CheckedContinuation<Value, Never>) -> Bool {
        lock.lock()
        if let outcome {
            lock.unlock()
            switch outcome {
            case .value(let value):
                continuation.resume(returning: value)
            }
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    @discardableResult
    func finish(with value: Value) -> Bool {
        let continuationToResume: CheckedContinuation<Value, Never>?
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return false
        }
        outcome = .value(value)
        continuationToResume = continuation
        continuation = nil
        lock.unlock()
        continuationToResume?.resume(returning: value)
        return true
    }
}

private final class ServiceTimeoutWorkLimiter: @unchecked Sendable {
    static let shared = ServiceTimeoutWorkLimiter(maximumConcurrentWork: 64)

    private let lock = NSLock()
    private let maximumConcurrentWork: Int
    private var activeTokens = Set<UUID>()

    init(maximumConcurrentWork: Int) {
        precondition(maximumConcurrentWork > 0)
        self.maximumConcurrentWork = maximumConcurrentWork
    }

    func reserve() -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        guard activeTokens.count < maximumConcurrentWork else { return nil }
        let token = UUID()
        activeTokens.insert(token)
        return token
    }

    func release(_ token: UUID) {
        lock.lock()
        activeTokens.remove(token)
        lock.unlock()
    }

    var activeCount: Int {
        lock.lock()
        let count = activeTokens.count
        lock.unlock()
        return count
    }
}

private final class ServiceTimeoutRace<Value>: @unchecked Sendable {
    private enum Outcome {
        case value(Value?)
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?
    private var outcome: Outcome?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<Value?, Never>) {
        lock.lock()
        if let outcome {
            lock.unlock()
            switch outcome {
            case .value(let value):
                continuation.resume(returning: value)
            }
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func installTasks(operation: Task<Void, Never>, timeout: Task<Void, Never>) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            operation.cancel()
            timeout.cancel()
            return
        }
        operationTask = operation
        timeoutTask = timeout
        lock.unlock()
    }

    @discardableResult
    func finishFromOperation(_ value: Value?) -> Bool {
        finish(with: value, cancelOperation: false, cancelTimeout: true)
    }

    @discardableResult
    func finishFromTimeout() -> Bool {
        finish(with: nil, cancelOperation: true, cancelTimeout: false)
    }

    func cancelFromCaller() {
        _ = finish(with: nil, cancelOperation: true, cancelTimeout: true)
    }

    private func finish(
        with value: Value?,
        cancelOperation: Bool,
        cancelTimeout: Bool
    ) -> Bool {
        let continuationToResume: CheckedContinuation<Value?, Never>?
        let operationToCancel: Task<Void, Never>?
        let timeoutToCancel: Task<Void, Never>?

        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return false
        }
        outcome = .value(value)
        continuationToResume = continuation
        continuation = nil
        operationToCancel = cancelOperation ? operationTask : nil
        timeoutToCancel = cancelTimeout ? timeoutTask : nil
        operationTask = nil
        timeoutTask = nil
        lock.unlock()

        operationToCancel?.cancel()
        timeoutToCancel?.cancel()
        continuationToResume?.resume(returning: value)
        return true
    }
}

struct ServiceSetting {
    let key: String
    let value: String
    let type: SettingType
    let comment: String?
    let options: [String]?

    enum SettingType {
        case string, bool, int, float
    }

    var isSensitive: Bool {
#if os(tvOS)
        if type == .string && (options?.isEmpty ?? true) {
            return true
        }
#endif
        return ServiceSettingSecurity.isSensitive(key: key, comment: comment, value: value)
    }
}

enum ServiceSettingSecurity {
    static let keychainPlaceholder = "__ECLIPSE_KEYCHAIN_VALUE__"

    static func isSensitive(key: String, comment: String?, value: String) -> Bool {
#if os(tvOS)
        if value.contains(keychainPlaceholder) { return true }

        let normalizedKey = key.lowercased().replacingOccurrences(
            of: #"[^a-z0-9]+"#,
            with: "_",
            options: .regularExpression
        )
        let keyMarkers = [
            "token", "secret", "password", "passwd", "authorization",
            "cookie", "api_key", "apikey", "access_key", "private_key"
        ]
        if keyMarkers.contains(where: normalizedKey.contains) { return true }

        let normalizedComment = comment?.lowercased() ?? ""
        let commentMarkers = [
            "api key", "access token", "refresh token", "authorization",
            "password", "secret", "session cookie", "private key",
            "eclipse sensitive"
        ]
        if commentMarkers.contains(where: normalizedComment.contains) { return true }

        if let components = URLComponents(string: value),
           components.user != nil || components.password != nil {
            return true
        }
        let sensitiveQueryNames = [
            "token", "access_token", "refresh_token", "api_key", "apikey",
            "key", "secret", "password", "signature", "sig", "auth"
        ]
        if let items = URLComponents(string: value)?.queryItems,
           items.contains(where: { sensitiveQueryNames.contains($0.name.lowercased()) }) {
            return true
        }
#endif
        return false
    }

    static func javascriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return literal
    }
}

/// tvOS provider credentials are device-local and are only materialized into
/// an ephemeral script immediately before JavaScriptCore evaluation. The
/// persisted script contains a non-secret sentinel instead.
enum TVServiceSettingVault {
    static func resolve(serviceID: UUID, key: String, persistedValue: String) -> String {
#if os(tvOS)
        return load(serviceID: serviceID, key: key)
            ?? (persistedValue == ServiceSettingSecurity.keychainPlaceholder ? "" : persistedValue)
#else
        return persistedValue
#endif
    }

    @discardableResult
    static func protect(_ value: String, serviceID: UUID, key: String) -> Bool {
#if os(tvOS)
        if value.isEmpty {
            remove(serviceID: serviceID, key: key)
            return true
        }
        if value == ServiceSettingSecurity.keychainPlaceholder {
            return load(serviceID: serviceID, key: key) != nil
        }
        guard let data = value.data(using: .utf8) else { return false }
        var attributes = query(serviceID: serviceID, key: key)
        let updates: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(attributes as CFDictionary, updates as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
#else
        return true
#endif
    }

    static func remove(serviceID: UUID, key: String) {
#if os(tvOS)
        SecItemDelete(query(serviceID: serviceID, key: key) as CFDictionary)
#endif
    }

    static func hydrating(_ script: String, serviceID: UUID) -> String {
#if os(tvOS)
        var lines = script.components(separatedBy: .newlines)
        let settingRegex = try! NSRegularExpression(pattern: #"const\s+(\w+)\s*=\s*([^;]+);"#)
        var inSettingsSection = false

        for index in lines.indices {
            let line = lines[index]
            if line.contains("// Settings start") {
                inSettingsSection = true
                continue
            }
            if line.contains("// Settings end") {
                break
            }
            guard inSettingsSection else { continue }

            let range = NSRange(line.startIndex..., in: line)
            guard let match = settingRegex.firstMatch(in: line, range: range),
                  let keyRange = Range(match.range(at: 1), in: line),
                  let valueRange = Range(match.range(at: 2), in: line) else {
                continue
            }
            let key = String(line[keyRange])
            let persistedValue = String(line[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard ServiceSettingSecurity.isSensitive(key: key, comment: line, value: persistedValue) else {
                continue
            }

            let resolved = load(serviceID: serviceID, key: key) ?? ""
            var hydratedLine = line
            hydratedLine.replaceSubrange(
                valueRange,
                with: ServiceSettingSecurity.javascriptStringLiteral(resolved)
            )
            lines[index] = hydratedLine
        }
        return lines.joined(separator: "\n")
#else
        return script
#endif
    }

#if os(tvOS)
    private static let service = "app.Eclipse.Soupy.service-provider-setting"

    private static func account(serviceID: UUID, key: String) -> String {
        "\(serviceID.uuidString):\(key)"
    }

    private static func query(serviceID: UUID, key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(serviceID: serviceID, key: key)
        ]
    }

    private static func load(serviceID: UUID, key: String) -> String? {
        var attributes = query(serviceID: serviceID, key: key)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

#endif
}

enum ServiceProviderRequirement: String, Codable, Hashable {
    case browserAutomation
    case interactiveChallenge
    case torrentOnly
}

struct ServiceProviderCapabilities: Codable, Hashable {
    let requirements: Set<ServiceProviderRequirement>

    static let httpOnly = ServiceProviderCapabilities(requirements: [])

    var isSupportedOnCurrentPlatform: Bool {
#if os(tvOS)
        requirements.isEmpty
#else
        true
#endif
    }

    var compatibilityError: ServiceCompatibilityError? {
        if requirements.contains(.browserAutomation) {
            return .browserAutomationRequired
        }
        if requirements.contains(.interactiveChallenge) {
            return .interactiveChallengeRequired
        }
        if requirements.contains(.torrentOnly) {
            return .torrentTransportRequired
        }
        return nil
    }

    static func analyze(javaScript: String) -> ServiceProviderCapabilities {
        let source = javaScript.lowercased()
        let compactSource = source.components(separatedBy: .whitespacesAndNewlines).joined()
        var requirements = Set<ServiceProviderRequirement>()

        let browserMarkers = [
            "networkfetchwithclicks(",
            "networkfetchwithwaitandclick(",
            "networkfetchfromhtml(",
            "networkfetchsimplefromhtml(",
            "clickselectors:",
            "waitforselectors:",
            "document.queryselector(",
            "document.queryselectorall("
        ]
        if browserMarkers.contains(where: compactSource.contains) {
            requirements.insert(.browserAutomation)
        }

        let challengeMarkers = [
            "cf_clearance",
            "cf-turnstile",
            "challenges.cloudflare.com",
            "check.ddos-guard.net"
        ]
        if challengeMarkers.contains(where: source.contains) {
            requirements.insert(.interactiveChallenge)
        }

        // A mixed provider remains eligible because runtime filtering can keep
        // its direct rows. Only mark code that emits a torrent result without
        // any recognizable direct-media result.
        let torrentOutputMarkers = [
            "url:\"magnet:",
            "url:'magnet:",
            "url:`magnet:",
            "infohash:",
            "\"infohash\":",
            "'infohash':"
        ]
        let directMediaMarkers = [
            "url:\"http://",
            "url:\"https://",
            "url:'http://",
            "url:'https://",
            "url:`http://",
            "url:`https://",
            ".m3u8",
            ".mpd",
            ".mp4",
            ".mkv"
        ]
        let emitsTorrent = torrentOutputMarkers.contains(where: compactSource.contains)
        let emitsDirectMedia = directMediaMarkers.contains(where: compactSource.contains)
        if emitsTorrent && !emitsDirectMedia {
            requirements.insert(.torrentOnly)
        }

        return ServiceProviderCapabilities(requirements: requirements)
    }
}

enum ServiceCompatibilityError: LocalizedError, Equatable {
    case browserAutomationRequired
    case interactiveChallengeRequired
    case torrentTransportRequired
    case unsupportedTransport
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .browserAutomationRequired:
            return "This source requires browser automation, which is unavailable on Apple TV."
        case .interactiveChallengeRequired:
            return "This source requires an interactive security challenge, which is unavailable on Apple TV."
        case .torrentTransportRequired:
            return "This source only provides torrent transport, which Eclipse does not use on Apple TV."
        case .unsupportedTransport:
            return "This source did not provide an HTTP or HTTPS resource that Apple TV can use."
        case .responseTooLarge:
            return "This source returned more data than the Apple TV safety limit allows."
        }
    }
}

enum PlatformSourceActivation {
    private static let sourceOverridesKey = "tvOSServiceSourceActivationOverrides"

    static func isEnabled(sourceID: String, sharedValue: Bool) -> Bool {
#if os(tvOS)
        sourceOverrides()[sourceID] ?? sharedValue
#else
        sharedValue
#endif
    }

    static func setEnabled(_ enabled: Bool, sourceID: String) {
#if os(tvOS)
        var overrides = sourceOverrides()
        overrides[sourceID] = enabled
        UserDefaults.standard.set(overrides, forKey: sourceOverridesKey)
#endif
    }

    static func removeOverride(sourceID: String) {
#if os(tvOS)
        var overrides = sourceOverrides()
        overrides.removeValue(forKey: sourceID)
        UserDefaults.standard.set(overrides, forKey: sourceOverridesKey)
#endif
    }

    private static func sourceOverrides() -> [String: Bool] {
        UserDefaults.standard.dictionary(forKey: sourceOverridesKey)?.reduce(into: [String: Bool]()) { result, pair in
            if let value = pair.value as? Bool {
                result[pair.key] = value
            } else if let value = pair.value as? NSNumber {
                result[pair.key] = value.boolValue
            }
        } ?? [:]
    }
}

#if os(tvOS)
private final class ServiceProviderCapabilitiesCache: @unchecked Sendable {
    static let shared = ServiceProviderCapabilitiesCache()

    private struct Entry {
        let javaScript: String
        let capabilities: ServiceProviderCapabilities
    }

    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    func capabilities(for service: Service) -> ServiceProviderCapabilities {
        lock.lock()
        if let entry = entries[service.id], entry.javaScript == service.jsScript {
            lock.unlock()
            return entry.capabilities
        }
        lock.unlock()

        let capabilities = ServiceProviderCapabilities.analyze(javaScript: service.jsScript)
        lock.lock()
        entries[service.id] = Entry(javaScript: service.jsScript, capabilities: capabilities)
        lock.unlock()
        return capabilities
    }
}
#endif

extension Service {
    var providerCapabilities: ServiceProviderCapabilities {
#if os(tvOS)
        ServiceProviderCapabilitiesCache.shared.capabilities(for: self)
#else
        // Provider capability restrictions are specific to Apple TV. Avoid
        // repeatedly scanning and copying entire scripts on iPhone and iPad,
        // especially while SwiftUI is constructing the Services list.
        .httpOnly
#endif
    }

    var platformCompatibilityError: ServiceCompatibilityError? {
        providerCapabilities.isSupportedOnCurrentPlatform ? nil : providerCapabilities.compatibilityError
    }
}

enum SourceHealth {
    static func serviceId(_ service: Service) -> String {
        "service:\(service.id.uuidString)"
    }

    static func stremioId(_ addon: StremioAddon) -> String {
        "stremio:\(addon.id.uuidString)"
    }

}

enum AutoModeQualityPreference: String, CaseIterable, Identifiable {
    case manual
    case auto
    case highest
    case quality2160 = "2160p"
    case quality1080 = "1080p"
    case quality720 = "720p"
    case quality480 = "480p"
    case lowest

    static let storageKey = "servicesAutoModeQualityPreference"
    static let defaultPreference: AutoModeQualityPreference = .auto

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: return "Ask"
        case .auto: return "Auto"
        case .highest: return "Highest"
        case .quality2160: return "2160p"
        case .quality1080: return "1080p"
        case .quality720: return "720p"
        case .quality480: return "480p"
        case .lowest: return "Lowest"
        }
    }

    var settingsDescription: String {
        switch self {
        case .manual:
            return "Auto Mode asks when a source returns multiple stream qualities."
        case .auto:
            return "Auto Mode chooses the strongest stream quality it can identify."
        case .highest:
            return "Auto Mode picks the highest detected resolution."
        case .quality2160, .quality1080, .quality720, .quality480:
            return "Auto Mode picks this quality when available, otherwise the closest lower option."
        case .lowest:
            return "Auto Mode picks the lowest detected resolution."
        }
    }

    var targetResolutionHeight: Int? {
        switch self {
        case .quality2160: return 2160
        case .quality1080: return 1080
        case .quality720: return 720
        case .quality480: return 480
        default: return nil
        }
    }

    var usesAutomaticSelection: Bool {
        self != .manual
    }

    static var current: AutoModeQualityPreference {
        let raw = UserDefaults.standard.string(forKey: storageKey)
        return raw.flatMap(AutoModeQualityPreference.init(rawValue:)) ?? defaultPreference
    }

    static func sanitizedRawValue(_ value: String?) -> String {
        value.flatMap(AutoModeQualityPreference.init(rawValue:))?.rawValue ?? defaultPreference.rawValue
    }
}

enum SourceHealthStatus: String, Codable {
    case unchecked
    case healthy
    case unhealthy
}

enum SourceHealthDisplayState {
    case unchecked
    case healthy
    case stale
    case warning(String)
    case playbackIssue(String)
}

struct SourceHealthRecord: Codable {
    var sourceId: String
    var sourceName: String
    var endpointStatus: SourceHealthStatus
    var endpointReason: String?
    var lastEndpointCheckedAt: Date?
    var lastPlaybackSuccessAt: Date?
    var lastPlaybackFailureAt: Date?
    var playbackFailureReason: String?
    var lastNoInternetSkipAt: Date?
}

final class SourceHealthStore: ObservableObject {
    static let shared = SourceHealthStore()

    @Published private(set) var version = 0
    private var versionUpdateScheduled = false

    private let storageKey = "sourceHealthRecordsV1"
    private let queue = DispatchQueue(label: "eclipse.source.health.store")
    private var records: [String: SourceHealthRecord]

    private init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: SourceHealthRecord].self, from: data) {
            records = decoded
        } else {
            records = [:]
        }
    }

    func record(for sourceId: String) -> SourceHealthRecord? {
        queue.sync { records[sourceId] }
    }

    func displayState(for sourceId: String) -> SourceHealthDisplayState {
        guard let record = record(for: sourceId) else { return .unchecked }

        let endpointFresh = record.lastEndpointCheckedAt.map { Date().timeIntervalSince($0) < 36 * 60 * 60 } ?? false
        if record.endpointStatus == .unhealthy, endpointFresh {
            return .warning(record.endpointReason ?? "Source endpoint is unreachable")
        }

        if let failureDate = record.lastPlaybackFailureAt,
           Date().timeIntervalSince(failureDate) < 24 * 60 * 60,
           (record.lastPlaybackSuccessAt ?? .distantPast) < failureDate {
            return .playbackIssue(record.playbackFailureReason ?? "Recent playback failed")
        }

        if record.endpointStatus == .healthy, endpointFresh {
            return .healthy
        }

        if record.lastEndpointCheckedAt != nil {
            return .stale
        }

        return .unchecked
    }

    func warningText(for sourceId: String) -> String? {
        switch displayState(for: sourceId) {
        case .warning(let reason):
            return reason
        case .playbackIssue(let reason):
            return reason
        default:
            return nil
        }
    }

    func shouldSkipForAutoMode(sourceId: String) -> Bool {
        guard let record = record(for: sourceId),
              record.endpointStatus == .unhealthy,
              let checkedAt = record.lastEndpointCheckedAt else {
            return false
        }
        return Date().timeIntervalSince(checkedAt) < 36 * 60 * 60
    }

    func recordEndpoint(sourceId: String, sourceName: String, status: SourceHealthStatus, reason: String?) {
        update(sourceId: sourceId, sourceName: sourceName) { record in
            record.endpointStatus = status
            record.endpointReason = reason
            record.lastEndpointCheckedAt = Date()
        }
    }

    func recordNoInternetSkip(sourceId: String, sourceName: String) {
        update(sourceId: sourceId, sourceName: sourceName) { record in
            record.lastNoInternetSkipAt = Date()
        }
    }

    func recordPlaybackSuccess(sourceId: String, sourceName: String) {
        update(sourceId: sourceId, sourceName: sourceName) { record in
            record.lastPlaybackSuccessAt = Date()
            record.playbackFailureReason = nil
        }
    }

    func recordPlaybackFailure(sourceId: String, sourceName: String, reason: String, isSourceFailure: Bool) {
        update(sourceId: sourceId, sourceName: sourceName) { record in
            record.lastPlaybackFailureAt = Date()
            record.playbackFailureReason = reason
            if isSourceFailure {
                record.endpointReason = record.endpointReason ?? reason
            }
        }
    }

    private func update(sourceId: String, sourceName: String, mutate: @escaping (inout SourceHealthRecord) -> Void) {
        queue.async {
            var record = self.records[sourceId] ?? SourceHealthRecord(
                sourceId: sourceId,
                sourceName: sourceName,
                endpointStatus: .unchecked,
                endpointReason: nil,
                lastEndpointCheckedAt: nil,
                lastPlaybackSuccessAt: nil,
                lastPlaybackFailureAt: nil,
                playbackFailureReason: nil,
                lastNoInternetSkipAt: nil
            )
            record.sourceName = sourceName
            mutate(&record)
            self.records[sourceId] = record
            self.saveLocked()
            DispatchQueue.main.async {
                guard !self.versionUpdateScheduled else { return }
                self.versionUpdateScheduled = true
                DispatchQueue.main.async {
                    self.versionUpdateScheduled = false
                    self.version += 1
                }
            }
        }
    }

    private func saveLocked() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

enum AutoModeSourceSelection {
    private static let idsKey = "servicesAutoModeSourceIds"
    private static let orderKey = "servicesAutoModeSourceOrderIds"

    static func selectedSourceIds(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: idsKey) ?? [])
    }

    static func sourceOrderIds(defaults: UserDefaults = .standard) -> [String] {
        var seen = Set<String>()
        return (defaults.stringArray(forKey: orderKey) ?? []).filter {
            seen.insert($0).inserted
        }
    }

    /// Applies the saved selection and order to a caller-provided active-source list. Sources
    /// missing from the saved order retain the caller's stable fallback order.
    static func orderedSelectedSourceIds(
        availableSourceIds: [String],
        defaults: UserDefaults = .standard
    ) -> [String] {
        let selected = selectedSourceIds(defaults: defaults)
        let available = availableSourceIds.filter { selected.contains($0) }
        let availableSet = Set(available)
        let explicitlyOrdered = sourceOrderIds(defaults: defaults).filter { availableSet.contains($0) }
        let alreadyOrdered = Set(explicitlyOrdered)
        return explicitlyOrdered + available.filter { !alreadyOrdered.contains($0) }
    }

    static func appendSourceIfNeeded(_ sourceId: String) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: idsKey) ?? [])
        var order = UserDefaults.standard.stringArray(forKey: orderKey) ?? []

        ids.insert(sourceId)
        if !order.contains(sourceId) {
            order.append(sourceId)
        }

        UserDefaults.standard.set(Array(ids), forKey: idsKey)
        UserDefaults.standard.set(order, forKey: orderKey)
    }

    static func removeSource(_ sourceId: String) {
        var ids = Set(UserDefaults.standard.stringArray(forKey: idsKey) ?? [])
        var order = UserDefaults.standard.stringArray(forKey: orderKey) ?? []

        ids.remove(sourceId)
        order.removeAll { $0 == sourceId }

        UserDefaults.standard.set(Array(ids), forKey: idsKey)
        UserDefaults.standard.set(order, forKey: orderKey)
    }
}

final class SourceHealthMonitor {
    static let shared = SourceHealthMonitor()

    private let lastDailyCheckKey = "sourceHealthLastDailyCheckTimestamp"
    private let dailyInterval: TimeInterval = 24 * 60 * 60
    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        session = URLSession(configuration: config)
    }

    func runDailyEnabledSourceChecksIfNeeded(force: Bool = false) async {
        let now = Date()
        let last = UserDefaults.standard.double(forKey: lastDailyCheckKey)
        if !force, last > 0, now.timeIntervalSince1970 - last < dailyInterval {
            return
        }

        let services = ServiceStore.shared.getServices().filter {
            PlatformSourceActivation.isEnabled(sourceID: SourceHealth.serviceId($0), sharedValue: $0.isActive)
                && $0.providerCapabilities.isSupportedOnCurrentPlatform
        }
        let addons = StremioAddonStore.shared.getAddons().filter {
            PlatformSourceActivation.isEnabled(sourceID: SourceHealth.stremioId($0), sharedValue: $0.isActive)
        }
        guard !services.isEmpty || !addons.isEmpty else { return }

        guard await hasInternetConnection() else {
            for service in services {
                SourceHealthStore.shared.recordNoInternetSkip(
                    sourceId: SourceHealth.serviceId(service),
                    sourceName: service.metadata.sourceName
                )
            }
            for addon in addons {
                SourceHealthStore.shared.recordNoInternetSkip(
                    sourceId: SourceHealth.stremioId(addon),
                    sourceName: addon.manifest.name
                )
            }
            Logger.shared.log("SourceHealth: skipped daily source checks because internet is unavailable", type: "ServiceManager")
            return
        }

        for service in services {
            let result = await checkServiceEndpoint(service)
            SourceHealthStore.shared.recordEndpoint(
                sourceId: SourceHealth.serviceId(service),
                sourceName: service.metadata.sourceName,
                status: result.ok ? .healthy : .unhealthy,
                reason: result.ok ? nil : result.reason
            )
        }

        for addon in addons {
            let result = await checkAddonEndpoint(addon)
            SourceHealthStore.shared.recordEndpoint(
                sourceId: SourceHealth.stremioId(addon),
                sourceName: addon.manifest.name,
                status: result.ok ? .healthy : .unhealthy,
                reason: result.ok ? nil : result.reason
            )
        }

        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: lastDailyCheckKey)
    }

    func probeStream(url: URL, headers: [String: String]) async -> StreamProbeResult {
        guard await hasInternetConnection() else { return .networkUnavailable }
        guard ServiceSandboxState.validatedHTTPURL(url.absoluteString) != nil else {
            return .sourceFailed(ServiceCompatibilityError.unsupportedTransport.localizedDescription)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        for (key, value) in headers where !value.isEmpty {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (_, response) = try await session.boundedData(
                for: request,
                maximumResponseBytes: 64 * 1024
            )
            guard let http = response as? HTTPURLResponse else {
                return .sourceFailed("Stream did not return an HTTP response")
            }
            switch http.statusCode {
            case 200...299:
                return .reachable
            case 401, 403, 404, 410, 451:
                return .sourceFailed("Stream returned HTTP \(http.statusCode)")
            case 500...599:
                return .sourceFailed("Stream host returned HTTP \(http.statusCode)")
            default:
                return .slowOrIndeterminate("Stream returned HTTP \(http.statusCode)")
            }
        } catch is BoundedURLSessionError {
            // Crossing the probe cap proves that the host is actively returning
            // stream bytes even when it ignores the requested one-byte range.
            return .reachable
        } catch {
            if let urlError = error as? URLError {
                switch urlError.code {
                case .timedOut, .cannotFindHost, .dnsLookupFailed, .networkConnectionLost:
                    return .slowOrIndeterminate(urlError.localizedDescription)
                case .notConnectedToInternet:
                    return .networkUnavailable
                default:
                    break
                }
            }
            return .sourceFailed(error.localizedDescription)
        }
    }

    private func checkServiceEndpoint(_ service: Service) async -> (ok: Bool, reason: String?) {
        do {
            guard let metadataURL = ServiceSandboxState.validatedHTTPURL(service.url) else {
                return (false, "Invalid service metadata URL")
            }
            let (metadataData, metadataResponse) = try await session.boundedData(
                from: metadataURL,
                maximumResponseBytes: 1_000_000
            )
            guard let metadataHTTP = metadataResponse as? HTTPURLResponse,
                  (200...299).contains(metadataHTTP.statusCode) else {
                return (false, "Metadata returned HTTP \((metadataResponse as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            let metadata = try JSONDecoder().decode(ServiceMetadata.self, from: metadataData)
            guard let scriptURL = ServiceSandboxState.validatedHTTPURL(metadata.scriptUrl) else {
                return (false, "Invalid service script URL")
            }
            let (scriptData, scriptResponse) = try await session.boundedData(
                from: scriptURL,
                maximumResponseBytes: 5_000_000
            )
            guard let scriptHTTP = scriptResponse as? HTTPURLResponse,
                  (200...299).contains(scriptHTTP.statusCode) else {
                return (false, "Script returned HTTP \((scriptResponse as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            guard !scriptData.isEmpty else {
                return (false, "Service script is empty")
            }
            return (true, nil)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private func checkAddonEndpoint(_ addon: StremioAddon) async -> (ok: Bool, reason: String?) {
        do {
            let manifest = try await StremioClient.shared.fetchManifest(from: addon.configuredURL)
            guard manifest.supportsStreams else {
                return (false, "Addon manifest no longer supports streams")
            }
            return (true, nil)
        } catch {
            return (false, error.localizedDescription)
        }
    }

    private func hasInternetConnection() async -> Bool {
        guard await networkPathIsSatisfied() else { return false }
        guard let url = URL(string: "https://www.apple.com/library/test/success.html") else { return true }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        do {
            let (_, response) = try await session.boundedData(
                for: request,
                maximumResponseBytes: 64 * 1024
            )
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...399).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func networkPathIsSatisfied() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "eclipse.source.health.path")
            var didResume = false

            let finish: (Bool) -> Void = { satisfied in
                queue.async {
                    guard !didResume else { return }
                    didResume = true
                    monitor.cancel()
                    continuation.resume(returning: satisfied)
                }
            }

            monitor.pathUpdateHandler = { path in
                finish(path.status == .satisfied)
            }
            monitor.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 1.5) {
                finish(false)
            }
        }
    }
}

enum StreamProbeResult {
    case reachable
    case slowOrIndeterminate(String)
    case networkUnavailable
    case sourceFailed(String)
}

@MainActor
class ServiceManager: ObservableObject {
    static let shared = ServiceManager()

    @Published var services: [Service] = []
    private(set) var isDownloading = false
    private(set) var downloadProgress: Double = 0.0
    private(set) var downloadMessage: String = ""

    /// UserDefaults keys for auto-update
    private static let autoUpdateEnabledKey = "autoUpdateServicesEnabled"
    private static let lastAutoUpdateKey = "lastServiceAutoUpdateTimestamp"
    /// Minimum interval between auto-updates (1 hour)
    private static let autoUpdateInterval: TimeInterval = 3600

    var isAutoUpdateEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.autoUpdateEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.autoUpdateEnabledKey) }
    }

    /// Register default values so auto-update is on for new installs
    private static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            autoUpdateEnabledKey: true
        ])
    }

    private var lastAutoUpdateDate: Date? {
        get {
            let timestamp = UserDefaults.standard.double(forKey: Self.lastAutoUpdateKey)
            return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
        }
        set {
            UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Self.lastAutoUpdateKey)
        }
    }

    private init() {
        Self.registerDefaults()
        loadServicesFromCloud()
    }

    // MARK: - Public Functions

    let delay: UInt64 = 300_000_000 // 300ms

    /// Automatically updates services if auto-update is enabled and enough time has passed.
    /// Call this on app launch / foreground.
    func autoUpdateServicesIfNeeded() async {
        guard isAutoUpdateEnabled, !services.isEmpty, !isDownloading else { return }

        if let last = lastAutoUpdateDate, Date().timeIntervalSince(last) < Self.autoUpdateInterval {
            Logger.shared.log("Skipping auto-update, last update was \(Int(Date().timeIntervalSince(last)))s ago", type: "ServiceManager")
            return
        }

        Logger.shared.log("Starting automatic service update", type: "ServiceManager")
        await updateServices()
        guard !Task.isCancelled else { return }
        lastAutoUpdateDate = Date()
        Logger.shared.log("Automatic service update completed", type: "ServiceManager")
    }

    func updateServices() async {
        guard !services.isEmpty else { return }

        isDownloading = true
        downloadProgress = 0.0
        downloadMessage = "Updating services..."
        defer { isDownloading = false }

        let total = Double(services.count)
        var completed: Double = 0

        for service in services {
            guard !Task.isCancelled else { break }
            await updateProgress(downloadProgress, "Updating \(service.metadata.sourceName)...")
            try? await Task.sleep(nanoseconds: delay)

            do {
                // Download metadata
                await updateProgress(downloadProgress + 0.1 / total, "Downloading metadata for \(service.metadata.sourceName)...")
                let metadata = try await downloadAndParseMetadata(from: service.url)
                try? await Task.sleep(nanoseconds: delay)

                // Skip update if the version hasn't changed
                if metadata.version == service.metadata.version {
                    Logger.shared.log("Service \(service.metadata.sourceName) is already up to date (v\(metadata.version))", type: "ServiceManager")
                    completed += 1
                    downloadProgress = completed / total
                    continue
                }

                // Download JavaScript
                await updateProgress(downloadProgress + 0.5 / total, "Downloading JavaScript for \(service.metadata.sourceName)...")
                var jsContent = try await downloadJavaScript(from: metadata.scriptUrl)
                try? await Task.sleep(nanoseconds: delay)

                // Preserve user-modified settings from the existing script
                let existingScript = service.jsScript
                let existingSettings = await Task.detached(priority: .utility) {
                    Self.parseSettingsFromJS(existingScript)
                }.value
                if !existingSettings.isEmpty {
                    let downloadedScript = jsContent
                    jsContent = await Task.detached(priority: .utility) {
                        Self.updateSettingsInJS(downloadedScript, with: existingSettings)
                    }.value
                }
#if os(tvOS)
                guard let securedScript = secureScriptForPersistence(jsContent, serviceID: service.id) else {
                    throw ServiceError.credentialStorageFailed
                }
                jsContent = securedScript
#endif

                // Save service using existing ID
                await ServiceStore.shared.storeServiceAsync(
                    id: service.id,
                    url: service.url,
                    jsonMetadata: String(data: try JSONEncoder().encode(metadata), encoding: .utf8) ?? "",
                    jsScript: jsContent,
                    isActive: service.isActive
                )

                Logger.shared.log("Service \(service.metadata.sourceName) updated to v\(metadata.version)", type: "ServiceManager")
            } catch {
                Logger.shared.log("Failed to update service \(service.metadata.sourceName): \(error.localizedDescription)", type: "ServiceManager")
            }

            // Update global progress
            completed += 1
            downloadProgress = completed / total
            try? await Task.sleep(nanoseconds: delay)

        }

        await loadServicesFromCloudAsync()
        guard !Task.isCancelled else {
            downloadProgress = 0
            downloadMessage = ""
            return
        }
        downloadProgress = 1
        downloadMessage = "All services updated!"
    }

    // MARK: - Download single service from JSON URL
    func downloadService(from jsonURL: String) async throws {
        await updateProgress(0.0, "Starting download...")
        try? await Task.sleep(nanoseconds: delay)

        do {
            await updateProgress(0.2, "Downloading metadata...")
            let metadata = try await downloadAndParseMetadata(from: jsonURL)
            try? await Task.sleep(nanoseconds: delay)

            await updateProgress(0.5, "Downloading JavaScript...")
            var jsContent = try await downloadJavaScript(from: metadata.scriptUrl)
            try? await Task.sleep(nanoseconds: delay)

            await updateProgress(0.8, "Saving service...")
            let serviceId = generateServiceUUID(from: metadata)
#if os(tvOS)
            guard let securedScript = secureScriptForPersistence(jsContent, serviceID: serviceId) else {
                throw ServiceError.credentialStorageFailed
            }
            jsContent = securedScript
#endif
            await ServiceStore.shared.storeServiceAsync(
                id: serviceId,
                url: jsonURL,
                jsonMetadata: String(data: try JSONEncoder().encode(metadata), encoding: .utf8) ?? "",
                jsScript: jsContent,
                isActive: true
            )
            AutoModeSourceSelection.appendSourceIfNeeded("service:\(serviceId.uuidString)")
            try? await Task.sleep(nanoseconds: delay)

            await loadServicesFromCloudAsync()
            guard services.contains(where: { $0.id == serviceId }) else {
                throw ServiceError.saveFailed
            }

            await MainActor.run {
                self.downloadProgress = 1.0
                self.downloadMessage = "Service downloaded successfully!"
            }

            try? await Task.sleep(nanoseconds: delay)
            await resetDownloadState()
        } catch {
            await resetDownloadState()
            Logger.shared.log("Failed to download service: \(error.localizedDescription)", type: "ServiceManager")
            throw error
        }
    }

    func handlePotentialServiceURL(_ text: String) async throws -> Bool {
        guard isValidJSONURL(text) else { return false }
        try await downloadService(from: text)
        return true
    }

    func removeService(_ service: Service) {
#if os(tvOS)
        for setting in Self.parseSettingsFromJS(service.jsScript) where setting.isSensitive {
            TVServiceSettingVault.remove(serviceID: service.id, key: setting.key)
        }
#endif
        if let entity = ServiceStore.shared.getServices().first(where: { $0.id == service.id }) {
            ServiceStore.shared.remove(entity)
        }
        PlatformSourceActivation.removeOverride(sourceID: SourceHealth.serviceId(service))
        loadServicesFromCloud()
    }

    func toggleServiceState(_ service: Service) {
        setServiceState(service, isActive: !isServiceEnabled(service))
    }

    func setServiceState(_ service: Service, isActive: Bool) {
#if os(tvOS)
        guard service.platformCompatibilityError == nil || !isActive else { return }
        PlatformSourceActivation.setEnabled(isActive, sourceID: SourceHealth.serviceId(service))
        loadServicesFromCloud()
#else
        guard let entity = ServiceStore.shared.getEntities().first(where: { $0.id == service.id }) else { return }
        entity.isActive = isActive
        ServiceStore.shared.save()
        loadServicesFromCloud()
#endif
    }

    func isServiceEnabled(_ service: Service) -> Bool {
        guard service.platformCompatibilityError == nil else { return false }
        return PlatformSourceActivation.isEnabled(
            sourceID: SourceHealth.serviceId(service),
            sharedValue: service.isActive
        )
    }

    func moveServices(fromOffsets offsets: IndexSet, toOffset: Int) {
        var mutable = services
        mutable.move(fromOffsets: offsets, toOffset: toOffset)

        for (index, service) in mutable.enumerated() {
            if let entity = ServiceStore.shared.getEntities().first(where: { $0.id == service.id }) {
                entity.sortIndex = Int64(index)
            }
        }

        ServiceStore.shared.save()
        loadServicesFromCloud()
    }

    var activeServices: [Service] {
        services.filter(isServiceEnabled)
    }

    func searchInActiveServices(query: String) async -> [(service: Service, results: [SearchItem])] {
        let activeList = activeServices
        guard !activeList.isEmpty else { return [] }

        await updateProgress(0.0, "Searching...")

        var resultsMap: [UUID: [SearchItem]] = [:]

        await withTaskGroup(of: (UUID, [SearchItem]).self) { group in
            for service in activeList {
                group.addTask {
                    let timeoutSeconds: UInt64 = 20_000_000_000 // 20sec
                    return await self.withTimeout(nanoseconds: timeoutSeconds) {
                        let found = await self.searchInService(service: service, query: query)
                        return (service.id, found)
                    } ?? (service.id, [])
                }
            }

            for await (id, results) in group {
                resultsMap[id] = results
            }
        }

        let orderedResults = activeList.map { service in
            (service: service, results: resultsMap[service.id] ?? [])
        }

        await resetDownloadState()
        return orderedResults
    }

    func searchInActiveServicesProgressively(query: String,
                                             onResult: @escaping @MainActor (Service, [SearchItem]?) -> Void,
                                             onComplete: @escaping @MainActor () -> Void) async
    {
        let activeList = activeServices
        guard !activeList.isEmpty else {
            await MainActor.run { onComplete() }
            return
        }

        await withTaskGroup(of: (Service, [SearchItem]?).self) { group in
            for service in activeList {
                group.addTask {
                    let timeoutSeconds: UInt64 = 20_000_000_000 // 20sec
                    return await self.withTimeout(nanoseconds: timeoutSeconds) {
                        let found = await self.searchInService(service: service, query: query)
                        return (service, found)
                    } ?? (service, [])
                }
            }

            for await (service, results) in group {
                await MainActor.run { onResult(service, results) }
            }
        }

        await MainActor.run { onComplete() }
    }

    func searchSingleActiveService(service: Service, query: String) async -> [SearchItem] {
        let timeoutSeconds: UInt64 = 20_000_000_000 // 20sec
        return await withTimeout(nanoseconds: timeoutSeconds) {
            await self.searchInService(service: service, query: query)
        } ?? []
    }

    func getServiceSettings(_ service: Service) -> [ServiceSetting] {
        let parsed = Self.parseSettingsFromJS(service.jsScript)
#if os(tvOS)
        return parsed.map { setting in
            guard setting.isSensitive else { return setting }
            return ServiceSetting(
                key: setting.key,
                value: TVServiceSettingVault.resolve(
                    serviceID: service.id,
                    key: setting.key,
                    persistedValue: setting.value
                ),
                type: setting.type,
                comment: setting.comment,
                options: setting.options
            )
        }
#else
        return parsed
#endif
     }

     func updateServiceSettings(_ service: Service, settings: [ServiceSetting]) -> Bool {
#if os(tvOS)
         guard let persistedSettings = securedSettingsForPersistence(settings, serviceID: service.id) else {
             return false
         }
#else
         let persistedSettings = settings
#endif
         let jsScript = Self.updateSettingsInJS(service.jsScript, with: persistedSettings)

         guard let entity = ServiceStore.shared.getEntities().first(where: { $0.id == service.id }) else { return false }
         entity.jsScript = jsScript

         ServiceStore.shared.save()
         loadServicesFromCloud()

         return true
     }

    // MARK: - Private Helpers

    private func isValidJSONURL(_ text: String) -> Bool {
        guard let url = ServiceSandboxState.validatedHTTPURL(text) else { return false }
        return url.pathExtension.lowercased() == "json"
    }

    private func downloadAndParseMetadata(from urlString: String) async throws -> ServiceMetadata {
        guard let url = ServiceSandboxState.validatedHTTPURL(urlString) else { throw ServiceError.invalidURL }
        let (data, response) = try await downloadServiceInstallAsset(from: url, kind: "metadata")
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ServiceError.downloadFailed }
        return try JSONDecoder().decode(ServiceMetadata.self, from: data)
    }

    private func downloadJavaScript(from urlString: String) async throws -> String {
        guard let url = ServiceSandboxState.validatedHTTPURL(urlString) else { throw ServiceError.invalidScriptURL }
        let (data, response) = try await downloadServiceInstallAsset(from: url, kind: "script")
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ServiceError.scriptDownloadFailed }
        guard let jsContent = String(data: data, encoding: .utf8) else { throw ServiceError.invalidScriptContent }
        return jsContent
    }

    private func downloadServiceInstallAsset(from url: URL, kind: String) async throws -> (Data, URLResponse) {
        guard ServiceSandboxState.validatedHTTPURL(url.absoluteString) != nil else {
            Logger.shared.log(
                "Service install sandbox blocked non-HTTP \(kind) download target=unsupported-url",
                type: "ServiceSandbox"
            )
            throw ServiceError.unsupportedTransport
        }
        guard !ServiceSandboxState.isBlockedTrackingURL(url.absoluteString) else {
            Logger.shared.log("Service install sandbox blocked tracking \(kind) download target=\(ServiceSandboxState.redactedURL(url.absoluteString))", type: "ServiceSandbox")
            throw ServiceError.blockedTrackingEndpoint
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpAdditionalHeaders = [
            "User-Agent": URLSession.randomUserAgent,
            "DNT": "1",
            "Sec-GPC": "1"
        ]

        let session = URLSession(
            configuration: configuration,
            delegate: FetchDelegate(allowRedirects: true),
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(URLSession.randomUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("1", forHTTPHeaderField: "DNT")
        request.setValue("1", forHTTPHeaderField: "Sec-GPC")

        Logger.shared.log("Service install sandbox downloading \(kind) target=\(ServiceSandboxState.redactedURL(url.absoluteString))", type: "ServiceManager")
        return try await session.boundedData(
            for: request,
            maximumResponseBytes: kind == "metadata" ? 1_000_000 : 5_000_000
        )
    }

    func loadServicesFromCloud() {
#if os(tvOS)
        let loaded = ServiceStore.shared.getServices()
        var didMigrate = false
        let entities = ServiceStore.shared.getEntities()
        for service in loaded {
            guard let securedScript = secureScriptForPersistence(service.jsScript, serviceID: service.id),
                  securedScript != service.jsScript,
                  let entity = entities.first(where: { $0.id == service.id }) else {
                continue
            }
            entity.jsScript = securedScript
            didMigrate = true
        }
        if didMigrate {
            ServiceStore.shared.save()
        }
#endif
        services = ServiceStore.shared.getServices()
    }

    private func loadServicesFromCloudAsync() async {
        services = await ServiceStore.shared.getServicesAsync()
    }

    private func generateServiceUUID(from metadata: ServiceMetadata) -> UUID {
        let identifier = "\(metadata.sourceName)_\(metadata.author.name)_\(metadata.version)"
        let hash = identifier.sha256
        let uuidString = String(hash.prefix(32))
        let formattedUUID = "\(uuidString.prefix(8))-\(uuidString.dropFirst(8).prefix(4))-\(uuidString.dropFirst(12).prefix(4))-\(uuidString.dropFirst(16).prefix(4))-\(uuidString.dropFirst(20).prefix(12))"
        return UUID(uuidString: formattedUUID) ?? UUID()
    }

    private func searchInService(service: Service, query: String) async -> [SearchItem] {
        let jsController = JSController()
        jsController.loadScript(service.jsScript, service: service)

        let callbackGate = ServiceCallbackGate<[SearchItem]>()
        let results = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard callbackGate.install(continuation), !Task.isCancelled else {
                    callbackGate.finish(with: [])
                    return
                }

                jsController.fetchJsSearchResults(keyword: query, module: service) { results in
                    // A malicious thenable can invoke callbacks more than once;
                    // the gate keeps the Swift continuation exactly-once.
                    callbackGate.finish(with: results)
                }
            }
        } onCancel: {
            callbackGate.finish(with: [])
        }

        if Task.isCancelled {
            jsController.cancelPendingServiceOperation(reason: "cancelled-or-timed-out")
        }
        return results
    }

    private func updateProgress(_ progress: Double, _ message: String) async {
        await MainActor.run {
            self.isDownloading = true
            self.downloadProgress = progress
            self.downloadMessage = message
        }
    }

    private func resetDownloadState() async {
        await MainActor.run {
            self.isDownloading = false
            self.downloadProgress = 0.0
            self.downloadMessage = ""
        }
    }

    nonisolated private static func parseSettingsFromJS(_ jsContent: String) -> [ServiceSetting] {
        let lines = jsContent.components(separatedBy: .newlines)
        var settings: [ServiceSetting] = []
        var inSettingsSection = false

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            if trimmedLine.contains("// Settings start") {
                inSettingsSection = true
                continue
            } else if trimmedLine.contains("// Settings end") {
                break
            }

            if inSettingsSection && trimmedLine.hasPrefix("const "),
               let setting = Self.parseSettingLine(trimmedLine) {
                settings.append(setting)
            }
        }

        return settings
    }

    nonisolated private static func parseSettingLine(_ line: String) -> ServiceSetting? {
        let settingRegex = try! NSRegularExpression(pattern: #"const\s+(\w+)\s*=\s*([^;]+);"#)
        let commentRegex = try! NSRegularExpression(pattern: #"//\s*(.+)$"#)
        let range = NSRange(location: 0, length: line.utf16.count)

        guard let match = settingRegex.firstMatch(in: line, range: range),
              let keyRange = Range(match.range(at: 1), in: line),
              let valueRange = Range(match.range(at: 2), in: line) else {
            return nil
        }

        let key = String(line[keyRange])
        let valueString = String(line[valueRange]).trimmingCharacters(in: .whitespaces)

        let rawComment = commentRegex.firstMatch(in: line, range: range).flatMap { match in
            Range(match.range(at: 1), in: line).map { String(line[$0]) }
        }

        var comment: String? = nil
        var options: [String]? = nil
        if let rc = rawComment {
            if let start = rc.firstIndex(of: "["), let end = rc.firstIndex(of: "]"), end > start {
                let optsSub = rc[rc.index(after: start)..<end]
                let rawOpts = optsSub.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                let cleaned = rawOpts.map { opt -> String in
                    var s = opt.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let first = s.first, let last = s.last,
                       "\"'“”‘’".contains(first), "\"'“”‘’".contains(last) {
                        s = String(s[s.index(after: s.startIndex)..<s.index(before: s.endIndex)])
                    }
                    return s
                }.filter { !$0.isEmpty }

                if !cleaned.isEmpty {
                    options = cleaned
                }

                var temp = rc
                temp.removeSubrange(start...end)
                let trimmed = temp.trimmingCharacters(in: .whitespacesAndNewlines)
                comment = trimmed.isEmpty ? nil : trimmed
            } else {
                comment = rc.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let (type, cleanValue) = determineSettingType(from: valueString)

        return ServiceSetting(key: key, value: cleanValue, type: type, comment: comment, options: options)
    }

    nonisolated private static func determineSettingType(from valueString: String) -> (ServiceSetting.SettingType, String) {
        func stripQuotes(_ s: String) -> String {
            var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count >= 2, let first = t.first, let last = t.last,
               "\"'“”‘’".contains(first), "\"'“”‘’".contains(last) {
                t = String(t[t.index(after: t.startIndex)..<t.index(before: t.endIndex)])
            }
            return t
        }

        let trimmed = valueString.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.first, let last = trimmed.last, "\"'“”‘’".contains(first) && "\"'“”‘’".contains(last) {
            return (.string, stripQuotes(trimmed))
        } else if valueString.lowercased() == "true" || valueString.lowercased() == "false" {
            return (.bool, valueString.lowercased())
        } else if valueString.contains(".") {
            return (.float, valueString)
        } else if Int(valueString) != nil {
            return (.int, valueString)
        } else {
            return (.string, stripQuotes(valueString))
        }
    }

    nonisolated private static func updateSettingsInJS(_ jsContent: String, with settings: [ServiceSetting]) -> String {
        var lines = jsContent.components(separatedBy: .newlines)
        let settingRegex = try! NSRegularExpression(pattern: #"const\s+(\w+)\s*=\s*([^;]+);"#)
        let settingsMap = Dictionary(
            settings.map { ($0.key, $0) },
            uniquingKeysWith: { _, incoming in incoming }
        )

        var inSettingsSection = false

        for (index, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            if trimmedLine.contains("// Settings start") {
                inSettingsSection = true
                continue
            } else if trimmedLine.contains("// Settings end") {
                break
            }

            if inSettingsSection && trimmedLine.hasPrefix("const ") {
                let range = NSRange(location: 0, length: trimmedLine.utf16.count)

                if let match = settingRegex.firstMatch(in: trimmedLine, range: range),
                   let keyRange = Range(match.range(at: 1), in: trimmedLine) {
                    let key = String(trimmedLine[keyRange])

                    if let setting = settingsMap[key] {
                        let formattedValue = formatSettingValue(setting)

                        var commentParts: [String] = []
                        if let c = setting.comment, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            commentParts.append(c)
                        }
                        if let opts = setting.options, !opts.isEmpty {
                            let optsEscaped = opts.map { "\"\($0)\"" }.joined(separator: ", ")
                            commentParts.append("[\(optsEscaped)]")
                        }

                        let commentPart = commentParts.isEmpty ? "" : " // " + commentParts.joined(separator: " ")
                        let leadingWhitespace = String(line.prefix(while: \.isWhitespace))
                        lines[index] = "\(leadingWhitespace)const \(setting.key) = \(formattedValue);\(commentPart)"
                    }
                }
            }
        }

        return lines.joined(separator: "\n")
    }

#if os(tvOS)
    private func secureScriptForPersistence(_ script: String, serviceID: UUID) -> String? {
        let settings = Self.parseSettingsFromJS(script)
        guard settings.contains(where: \.isSensitive) else { return script }
        guard let securedSettings = securedSettingsForPersistence(settings, serviceID: serviceID) else {
            return nil
        }
        return Self.updateSettingsInJS(
            script,
            with: securedSettings
        )
    }

    private func securedSettingsForPersistence(
        _ settings: [ServiceSetting],
        serviceID: UUID
    ) -> [ServiceSetting]? {
        var persisted: [ServiceSetting] = []
        persisted.reserveCapacity(settings.count)

        for setting in settings {
            guard setting.isSensitive else {
                persisted.append(setting)
                continue
            }

            if !TVServiceSettingVault.protect(setting.value, serviceID: serviceID, key: setting.key) {
                Logger.shared.log(
                    "Service setting credential could not be stored securely service=\(serviceID.uuidString) key=\(setting.key)",
                    type: "Storage"
                )
                return nil
            }

            persisted.append(ServiceSetting(
                key: setting.key,
                value: ServiceSettingSecurity.keychainPlaceholder,
                type: .string,
                comment: setting.comment,
                options: setting.options
            ))
        }
        return persisted
    }
#endif

    nonisolated private static func formatSettingValue(_ setting: ServiceSetting) -> String {
        switch setting.type {
        case .string:
            return ServiceSettingSecurity.javascriptStringLiteral(setting.value)
        case .bool, .int, .float:
            return setting.value
        }
    }

    func withTimeout<T>(nanoseconds: UInt64, operation: @escaping @Sendable () async throws -> T) async -> T? {
        guard nanoseconds > 0, !Task.isCancelled else { return nil }

        // Unstructured work is necessary here: a structured task group cannot
        // leave scope until an uncooperative child finishes, even after
        // `cancelAll()`. Reservations remain held until the underlying work
        // actually exits, so legacy work that ignores cancellation is tracked
        // and globally bounded instead of accumulating without limit.
        let limiter = ServiceTimeoutWorkLimiter.shared
        guard let workToken = limiter.reserve() else {
            Logger.shared.log(
                "Service timeout work limit reached; skipping new legacy operation active=\(limiter.activeCount)",
                type: "Service"
            )
            return nil
        }

        let race = ServiceTimeoutRace<T>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.install(continuation)

                let operationTask = Task {
                    defer { limiter.release(workToken) }
                    let result = try? await operation()
                    race.finishFromOperation(result)
                }
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: nanoseconds)
                    } catch {
                        return
                    }
                    if race.finishFromTimeout() {
                        Logger.shared.log(
                            "Service operation timed out; cancellation requested active=\(limiter.activeCount)",
                            type: "Service"
                        )
                    }
                }
                race.installTasks(operation: operationTask, timeout: timeoutTask)
            }
        } onCancel: {
            race.cancelFromCaller()
        }
    }
}

// MARK: - Extensions

extension String {
    var sha256: String {
        let data = Data(self.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Service Errors

enum ServiceError: LocalizedError {
    case invalidURL, invalidScriptURL, downloadFailed, scriptDownloadFailed, invalidJSON, invalidScriptContent, blockedTrackingEndpoint, unsupportedTransport, credentialStorageFailed, saveFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL provided"
        case .invalidScriptURL: return "Invalid script URL in metadata"
        case .downloadFailed: return "Failed to download metadata"
        case .scriptDownloadFailed: return "Failed to download JavaScript file"
        case .invalidJSON: return "Invalid JSON format"
        case .invalidScriptContent: return "Invalid JavaScript content"
        case .blockedTrackingEndpoint: return "Service install blocked a tracking endpoint"
        case .unsupportedTransport: return "Service install URLs must use HTTP or HTTPS"
        case .credentialStorageFailed: return "A provider credential could not be stored securely"
        case .saveFailed: return "The service downloaded, but it could not be saved."
        }
    }
}
