//
//  ServiceManager.swift
//  Sora
//
//  Created by Francesco on 09/08/25.
//

import CryptoKit
import Foundation
import Network

struct ServiceSetting {
    let key: String
    let value: String
    let type: SettingType
    let comment: String?
    let options: [String]?

    enum SettingType {
        case string, bool, int, float
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

    private let storageKey = "sourceHealthRecordsV1"
    private let queue = DispatchQueue(label: "luna.source.health.store")
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
                self.version += 1
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

        let services = ServiceStore.shared.getServices().filter(\.isActive)
        let addons = StremioAddonStore.shared.getAddons().filter(\.isActive)
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

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        for (key, value) in headers where !value.isEmpty {
            request.setValue(value, forHTTPHeaderField: key)
        }

        do {
            let (_, response) = try await session.data(for: request)
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
            guard let metadataURL = URL(string: service.url) else {
                return (false, "Invalid service metadata URL")
            }
            let (metadataData, metadataResponse) = try await session.data(from: metadataURL)
            guard let metadataHTTP = metadataResponse as? HTTPURLResponse,
                  (200...299).contains(metadataHTTP.statusCode) else {
                return (false, "Metadata returned HTTP \((metadataResponse as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            let metadata = try JSONDecoder().decode(ServiceMetadata.self, from: metadataData)
            guard let scriptURL = URL(string: metadata.scriptUrl) else {
                return (false, "Invalid service script URL")
            }
            let (scriptData, scriptResponse) = try await session.data(from: scriptURL)
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
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...399).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func networkPathIsSatisfied() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "luna.source.health.path")
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
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0.0
    @Published var downloadMessage: String = ""

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
        lastAutoUpdateDate = Date()
        Logger.shared.log("Automatic service update completed", type: "ServiceManager")
    }

    func updateServices() async {
        guard !services.isEmpty else { return }

        isDownloading = true
        downloadProgress = 0.0
        downloadMessage = "Updating services..."

        let total = Double(services.count)
        var completed: Double = 0

        for service in services {
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
                let existingSettings = parseSettingsFromJS(service.jsScript)
                if !existingSettings.isEmpty {
                    jsContent = updateSettingsInJS(jsContent, with: existingSettings)
                }

                // Save service using existing ID
                ServiceStore.shared.storeService(
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

            // Cleanup
            loadServicesFromCloud()
            await resetDownloadState()
            downloadMessage = "All services updated!"
        }
    }

    // MARK: - Download single service from JSON URL
    func downloadService(from jsonURL: String) async {
        await updateProgress(0.0, "Starting download...")
        try? await Task.sleep(nanoseconds: delay)

        do {
            await updateProgress(0.2, "Downloading metadata...")
            let metadata = try await downloadAndParseMetadata(from: jsonURL)
            try? await Task.sleep(nanoseconds: delay)

            await updateProgress(0.5, "Downloading JavaScript...")
            let jsContent = try await downloadJavaScript(from: metadata.scriptUrl)
            try? await Task.sleep(nanoseconds: delay)

            await updateProgress(0.8, "Saving service...")
            let serviceId = generateServiceUUID(from: metadata)
            ServiceStore.shared.storeService(
                id: serviceId,
                url: jsonURL,
                jsonMetadata: String(data: try JSONEncoder().encode(metadata), encoding: .utf8) ?? "",
                jsScript: jsContent,
                isActive: true
            )
            AutoModeSourceSelection.appendSourceIfNeeded("service:\(serviceId.uuidString)")
            try? await Task.sleep(nanoseconds: delay)

            loadServicesFromCloud()

            await MainActor.run {
                self.downloadProgress = 1.0
                self.downloadMessage = "Service downloaded successfully!"
            }

            try? await Task.sleep(nanoseconds: delay)
            await resetDownloadState()
        } catch {
            await resetDownloadState()
            Logger.shared.log("Failed to download service: \(error.localizedDescription)", type: "ServiceManager")
        }
    }

    func handlePotentialServiceURL(_ text: String) async -> Bool {
        guard isValidJSONURL(text) else { return false }
        await downloadService(from: text)
        return true
    }

    func removeService(_ service: Service) {
        if let entity = ServiceStore.shared.getServices().first(where: { $0.id == service.id }) {
            ServiceStore.shared.remove(entity)
        }
        loadServicesFromCloud()
    }

    func toggleServiceState(_ service: Service) {
        guard let entity = ServiceStore.shared.getEntities().first(where: { $0.id == service.id }) else { return }
        entity.isActive.toggle()
        ServiceStore.shared.save()
        loadServicesFromCloud()
    }

    func setServiceState(_ service: Service, isActive: Bool) {
        guard let entity = ServiceStore.shared.getEntities().first(where: { $0.id == service.id }) else { return }
        entity.isActive = isActive
        ServiceStore.shared.save()
        loadServicesFromCloud()
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
        services.filter(\.isActive)
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
        return parseSettingsFromJS(service.jsScript)
     }

     func updateServiceSettings(_ service: Service, settings: [ServiceSetting]) -> Bool {
         let jsScript = updateSettingsInJS(service.jsScript, with: settings)

         guard let entity = ServiceStore.shared.getEntities().first(where: { $0.id == service.id }) else { return false }
         entity.jsScript = jsScript

         ServiceStore.shared.save()
         loadServicesFromCloud()

         return true
     }

    // MARK: - Private Helpers

    private func isValidJSONURL(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme != nil else { return false }
        return url.pathExtension.lowercased() == "json" || text.lowercased().contains(".json")
    }

    private func downloadAndParseMetadata(from urlString: String) async throws -> ServiceMetadata {
        guard let url = URL(string: urlString) else { throw ServiceError.invalidURL }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ServiceError.downloadFailed }
        return try JSONDecoder().decode(ServiceMetadata.self, from: data)
    }

    private func downloadJavaScript(from urlString: String) async throws -> String {
        guard let url = URL(string: urlString) else { throw ServiceError.invalidScriptURL }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ServiceError.scriptDownloadFailed }
        guard let jsContent = String(data: data, encoding: .utf8) else { throw ServiceError.invalidScriptContent }
        return jsContent
    }

    func loadServicesFromCloud() {
        services = ServiceStore.shared.getServices()
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
        jsController.loadScript(service.jsScript)

        return await withCheckedContinuation { continuation in
            jsController.fetchJsSearchResults(keyword: query, module: service) { results in
                continuation.resume(returning: results)
            }
        }
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

    private func parseSettingsFromJS(_ jsContent: String) -> [ServiceSetting] {
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
               let setting = parseSettingLine(trimmedLine) {
                settings.append(setting)
            }
        }

        return settings
    }

    private func parseSettingLine(_ line: String) -> ServiceSetting? {
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

    private func determineSettingType(from valueString: String) -> (ServiceSetting.SettingType, String) {
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

    private func updateSettingsInJS(_ jsContent: String, with settings: [ServiceSetting]) -> String {
        var lines = jsContent.components(separatedBy: .newlines)
        let settingRegex = try! NSRegularExpression(pattern: #"const\s+(\w+)\s*=\s*([^;]+);"#)
        let settingsMap = Dictionary(uniqueKeysWithValues: settings.map { ($0.key, $0) })

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

    private func formatSettingValue(_ setting: ServiceSetting) -> String {
        switch setting.type {
        case .string:
            return "\"\(setting.value)\""
        case .bool, .int, .float:
            return setting.value
        }
    }

    func withTimeout<T>(nanoseconds: UInt64, operation: @escaping @Sendable () async throws -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in

            // Main task
            group.addTask {
                try? await operation()
            }

            // Timeout task
            group.addTask {
                try? await Task.sleep(nanoseconds: nanoseconds)
                return nil
            }

            // Return the first completed result and cancel all other tasks
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
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
    case invalidURL, invalidScriptURL, downloadFailed, scriptDownloadFailed, invalidJSON, invalidScriptContent

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL provided"
        case .invalidScriptURL: return "Invalid script URL in metadata"
        case .downloadFailed: return "Failed to download metadata"
        case .scriptDownloadFailed: return "Failed to download JavaScript file"
        case .invalidJSON: return "Invalid JSON format"
        case .invalidScriptContent: return "Invalid JavaScript content"
        }
    }
}
