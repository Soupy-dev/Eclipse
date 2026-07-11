// Kanzen-owned Aidoku source bridge. This intentionally avoids importing
// Aidoku's app/CoreData layer; only AidokuRunner source packages are used.

#if !os(tvOS)
import AidokuRunner
import Combine
import Foundation
import SwiftUI
import ZIPFoundation
import UIKit

// MARK: - Public Route Models

enum MangaContentRoute: Codable, Equatable, Hashable {
    case legacyModule(moduleUUID: String, contentParams: String, isNovel: Bool)
    case aidoku(sourceId: String, mangaKey: String)

    enum RouteKind: String, Codable {
        case legacyModule
        case aidoku
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case moduleUUID
        case contentParams
        case isNovel
        case sourceId
        case mangaKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(RouteKind.self, forKey: .kind)
        switch kind {
        case .legacyModule:
            self = .legacyModule(
                moduleUUID: try container.decode(String.self, forKey: .moduleUUID),
                contentParams: try container.decode(String.self, forKey: .contentParams),
                isNovel: try container.decodeIfPresent(Bool.self, forKey: .isNovel) ?? false
            )
        case .aidoku:
            self = .aidoku(
                sourceId: try container.decode(String.self, forKey: .sourceId),
                mangaKey: try container.decode(String.self, forKey: .mangaKey)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .legacyModule(let moduleUUID, let contentParams, let isNovel):
            try container.encode(RouteKind.legacyModule, forKey: .kind)
            try container.encode(moduleUUID, forKey: .moduleUUID)
            try container.encode(contentParams, forKey: .contentParams)
            try container.encode(isNovel, forKey: .isNovel)
        case .aidoku(let sourceId, let mangaKey):
            try container.encode(RouteKind.aidoku, forKey: .kind)
            try container.encode(sourceId, forKey: .sourceId)
            try container.encode(mangaKey, forKey: .mangaKey)
        }
    }

    var stableKey: String {
        switch self {
        case .legacyModule(let moduleUUID, let contentParams, _):
            return "module:\(moduleUUID):\(contentParams)"
        case .aidoku(let sourceId, let mangaKey):
            return "aidoku:\(sourceId):\(mangaKey)"
        }
    }

    var stableNegativeId: Int {
        let hash = stableKey.utf8.reduce(into: 5381) { h, c in
            h = ((h &<< 5) &+ h) &+ Int(c)
        }
        return hash < 0 ? hash : -hash - 1
    }
}

struct AidokuChapterPayload {
    let sourceId: String
    let manga: AidokuRunner.Manga
    let chapter: AidokuRunner.Chapter
}

// MARK: - Persisted Source Models

struct AidokuInstalledSource: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var version: Int
    var languages: [String]
    var iconPath: String?
    var externalIconURL: String?
    var contentRatingRawValue: Int
    var sourceListURL: String?
    var packageURL: String?
    var isEnabled: Bool
    var order: Int
    var lastUpdated: Date?
    var lastError: String?

    var iconURLString: String {
        if let iconPath, FileManager.default.fileExists(atPath: iconPath) {
            return URL(fileURLWithPath: iconPath).absoluteString
        }
        return externalIconURL ?? ""
    }

    var contentRating: AidokuRunner.SourceContentRating {
        AidokuRunner.SourceContentRating(rawValue: contentRatingRawValue) ?? .safe
    }

    var isMature: Bool {
        contentRating != .safe
    }
}

struct AidokuSourceListRecord: Codable, Identifiable, Equatable {
    var id: String { url }
    let url: String
    var name: String
    var sourceCount: Int
    var lastRefresh: Date?
    var lastError: String?
}

struct AidokuSourceListEntry: Identifiable, Equatable {
    var id: String { info.id }
    let info: AidokuExternalSourceInfo
    let listURL: URL
    let listName: String

    var isMature: Bool {
        info.resolvedContentRating != .safe
    }

    var downloadURL: URL? {
        if let downloadURL = info.downloadURL {
            return URL(string: downloadURL, relativeTo: listURL)?.absoluteURL
        }
        if let file = info.file {
            return URL(string: "sources/\(file)", relativeTo: listURL)?.absoluteURL
        }
        return nil
    }

    var iconURLString: String {
        if let iconURL = info.iconURL,
           let url = URL(string: iconURL, relativeTo: listURL)?.absoluteURL {
            return url.absoluteString
        }
        if let icon = info.icon,
           let url = URL(string: "icons/\(icon)", relativeTo: listURL)?.absoluteURL {
            return url.absoluteString
        }
        return ""
    }
}

struct AidokuExternalSourceInfo: Codable, Hashable {
    let id: String
    let name: String
    let version: Int
    let iconURL: String?
    let downloadURL: String?
    let languages: [String]?
    let contentRating: AidokuRunner.SourceContentRating?
    let altNames: [String]?
    let baseURL: String?
    let minAppVersion: String?
    let maxAppVersion: String?

    let lang: String?
    let nsfw: Int?
    let file: String?
    let icon: String?

    var resolvedContentRating: AidokuRunner.SourceContentRating {
        if let contentRating {
            return contentRating
        }
        if let nsfw, let rating = AidokuRunner.SourceContentRating(rawValue: nsfw) {
            return rating
        }
        return .safe
    }

    var resolvedLanguages: [String] {
        languages ?? lang.map { [$0] } ?? []
    }
}

private struct AidokuCodableSourceList: Codable {
    let name: String
    let feedbackURL: String?
    let sources: [AidokuExternalSourceInfo]
}

enum AidokuBackupBridge {
    static let sourceListsKey = "kanzenAidokuSourceLists"
    static let installedSourcesKey = "kanzenAidokuInstalledSources"
    static let matureSourcesKey = "kanzenAidokuShowMatureSources"
    static let autoUpdateKey = "kanzenAidokuAutoUpdateSources"
    static let lastAutoUpdateKey = "kanzenAidokuLastAutoUpdate"

    private static let rootDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("KanzenAidoku", isDirectory: true)

    private static var sourcesDirectory: URL {
        rootDirectory.appendingPathComponent("Sources", isDirectory: true)
    }

    static func backupSnapshotFromDisk() -> BackupAidokuState {
        let defaults = UserDefaults.standard
        let decoder = JSONDecoder()
        let sourceLists: [AidokuSourceListRecord]
        if let data = defaults.data(forKey: sourceListsKey),
           let decoded = try? decoder.decode([AidokuSourceListRecord].self, from: data) {
            sourceLists = decoded
        } else {
            sourceLists = []
        }

        let installedSources: [AidokuInstalledSource]
        if let data = defaults.data(forKey: installedSourcesKey),
           let decoded = try? decoder.decode([AidokuInstalledSource].self, from: data) {
            installedSources = decoded
        } else {
            installedSources = []
        }

        let backupSources = installedSources.map { source in
            BackupAidokuInstalledSource(
                id: source.id,
                name: source.name,
                version: source.version,
                languages: source.languages,
                iconPath: nil,
                externalIconURL: source.externalIconURL,
                contentRatingRawValue: source.contentRatingRawValue,
                sourceListURL: source.sourceListURL,
                packageURL: source.packageURL,
                isEnabled: source.isEnabled,
                order: source.order,
                lastUpdated: source.lastUpdated,
                lastError: source.lastError,
                payloadArchiveData: archivePayload(sourceId: source.id)
            )
        }

        return BackupAidokuState(
            sourceLists: sourceLists.map {
                BackupAidokuSourceListRecord(
                    url: $0.url,
                    name: $0.name,
                    sourceCount: $0.sourceCount,
                    lastRefresh: $0.lastRefresh,
                    lastError: $0.lastError
                )
            },
            installedSources: backupSources,
            showMatureSources: defaults.bool(forKey: matureSourcesKey),
            autoUpdateSources: defaults.object(forKey: autoUpdateKey) == nil ? true : defaults.bool(forKey: autoUpdateKey),
            lastAutoUpdate: defaults.object(forKey: lastAutoUpdateKey) as? Date
        )
    }

    static func restoreBackupSnapshotToDisk(_ state: BackupAidokuState) {
        let defaults = UserDefaults.standard
        let sourceLists = state.sourceLists.map {
            AidokuSourceListRecord(
                url: $0.url,
                name: $0.name,
                sourceCount: $0.sourceCount,
                lastRefresh: $0.lastRefresh,
                lastError: $0.lastError
            )
        }

        let installedSources = state.installedSources.map {
            AidokuInstalledSource(
                id: $0.id,
                name: $0.name,
                version: $0.version,
                languages: $0.languages,
                iconPath: nil,
                externalIconURL: $0.externalIconURL,
                contentRatingRawValue: $0.contentRatingRawValue,
                sourceListURL: $0.sourceListURL,
                packageURL: $0.packageURL,
                isEnabled: $0.isEnabled,
                order: $0.order,
                lastUpdated: $0.lastUpdated,
                lastError: $0.lastError
            )
        }

        let encoder = JSONEncoder()
        if let data = try? encoder.encode(sourceLists) {
            defaults.set(data, forKey: sourceListsKey)
        }
        if let data = try? encoder.encode(installedSources) {
            defaults.set(data, forKey: installedSourcesKey)
        }
        defaults.set(state.showMatureSources, forKey: matureSourcesKey)
        defaults.set(state.autoUpdateSources, forKey: autoUpdateKey)
        if let lastAutoUpdate = state.lastAutoUpdate {
            defaults.set(lastAutoUpdate, forKey: lastAutoUpdateKey)
        } else {
            defaults.removeObject(forKey: lastAutoUpdateKey)
        }

        ensureDirectories()
        for source in state.installedSources {
            guard let payloadArchiveData = source.payloadArchiveData else { continue }
            restorePayload(sourceId: source.id, archiveData: payloadArchiveData)
        }
    }

    private static func archivePayload(sourceId: String) -> Data? {
        let sourceDirectory = sourcesDirectory.appendingPathComponent(sourceId, isDirectory: true)
        guard FileManager.default.fileExists(atPath: sourceDirectory.path) else { return nil }
        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kanzen-aidoku-backup-\(sourceId)-\(UUID().uuidString)")
            .appendingPathExtension("zip")
        defer {
            try? FileManager.default.removeItem(at: archiveURL)
        }

        do {
            try FileManager.default.zipItem(at: sourceDirectory, to: archiveURL, shouldKeepParent: false)
            return try Data(contentsOf: archiveURL)
        } catch {
            ReaderLogger.shared.log("Failed to archive Aidoku source \(sourceId) for backup: \(error.localizedDescription)", type: "AidokuBackup")
            return nil
        }
    }

    private static func restorePayload(sourceId: String, archiveData: Data) {
        guard isValidSourceKey(sourceId) else {
            ReaderLogger.shared.log("Skipped Aidoku restore for invalid source id \(sourceId)", type: "AidokuBackup")
            return
        }
        guard UInt64(archiveData.count) <= AidokuSourceManager.maxPackageBytes else {
            ReaderLogger.shared.log("Skipped Aidoku restore for \(sourceId): archive too large", type: "AidokuBackup")
            return
        }

        let archiveURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kanzen-aidoku-restore-\(sourceId)-\(UUID().uuidString)")
            .appendingPathExtension("zip")
        let extractionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kanzen-aidoku-restore-\(sourceId)-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: archiveURL)
            try? FileManager.default.removeItem(at: extractionDirectory)
        }

        do {
            try archiveData.write(to: archiveURL, options: .atomic)
            try validateArchivePaths(at: archiveURL)
            try FileManager.default.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)
            try FileManager.default.unzipItem(at: archiveURL, to: extractionDirectory)

            let destination = sourcesDirectory.appendingPathComponent(sourceId, isDirectory: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: extractionDirectory, to: destination)
        } catch {
            ReaderLogger.shared.log("Failed to restore Aidoku source \(sourceId): \(error.localizedDescription)", type: "AidokuBackup")
        }
    }

    private static func validateArchivePaths(at url: URL) throws {
        guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil) else {
            throw AidokuSourceError.missingPayload
        }
        var totalUncompressed: UInt64 = 0
        for entry in archive {
            let path = entry.path.replacingOccurrences(of: "\\", with: "/")
            if path.hasPrefix("/") || path.contains("../") || path.contains("/../") {
                throw AidokuSourceError.unsafeArchivePath(path)
            }
            totalUncompressed += UInt64(entry.uncompressedSize)
            if totalUncompressed > AidokuSourceManager.maxPackageBytes {
                throw AidokuSourceError.packageTooLarge
            }
        }
    }

    private static func ensureDirectories() {
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)
    }

    private static func isValidSourceKey(_ sourceKey: String) -> Bool {
        guard !sourceKey.isEmpty else { return false }
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        return sourceKey.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
    }
}

enum AidokuSourceError: LocalizedError {
    case invalidURL
    case duplicateSourceList
    case sourceListLoadFailed
    case missingDownloadURL
    case unsupportedSourceVersion
    case unsafeArchivePath(String)
    case packageTooLarge
    case missingPayload
    case invalidSourceKey(String)
    case sourceNotInstalled
    case sourceRuntimeUnavailable
    case blockedRequest(String)
    case unsupportedPage

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The source URL is invalid."
        case .duplicateSourceList:
            return "That source list is already added."
        case .sourceListLoadFailed:
            return "The source list could not be loaded."
        case .missingDownloadURL:
            return "This source does not include a downloadable package URL."
        case .unsupportedSourceVersion:
            return "This source targets an unsupported Aidoku version."
        case .unsafeArchivePath(let path):
            return "The source package contains an unsafe path: \(path)"
        case .packageTooLarge:
            return "The source package is too large."
        case .missingPayload:
            return "The source package is missing Payload/source.json or Payload/main.wasm."
        case .invalidSourceKey(let key):
            return "The source id is invalid: \(key)"
        case .sourceNotInstalled:
            return "The source is not installed."
        case .sourceRuntimeUnavailable:
            return "The source runtime is unavailable."
        case .blockedRequest(let host):
            return "Blocked reader source request to \(host)."
        case .unsupportedPage:
            return "This page type is not supported."
        }
    }
}

// MARK: - Network

actor AidokuNetworkSessionStore {
    static let shared = AidokuNetworkSessionStore()
    private var sessions: [String: URLSession] = [:]

    func session(for sourceId: String) -> URLSession {
        if let session = sessions[sourceId] {
            return session
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 60
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .onlyFromMainDocumentDomain
        configuration.httpAdditionalHeaders = [
            "DNT": "1",
            "Sec-GPC": "1"
        ]

        let session = URLSession(configuration: configuration)
        sessions[sourceId] = session
        return session
    }
}

enum AidokuNetworkClient {
    private static let blockedHostFragments = [
        "google-analytics.com",
        "googletagmanager.com",
        "doubleclick.net",
        "facebook.com/tr",
        "analytics",
        "segment.io",
        "sentry.io",
        "datadog",
        "mixpanel"
    ]

    static func prepare(_ request: URLRequest) throws -> URLRequest {
        guard let url = request.url else { return request }
        let host = url.host?.lowercased() ?? ""
        if blockedHostFragments.contains(where: { host.contains($0) || url.absoluteString.lowercased().contains($0) }) {
            throw AidokuSourceError.blockedRequest(host.isEmpty ? url.absoluteString : host)
        }

        var request = request
        request.setValue("1", forHTTPHeaderField: "DNT")
        request.setValue("1", forHTTPHeaderField: "Sec-GPC")
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue("Eclipse Reader/Aidoku", forHTTPHeaderField: "User-Agent")
        }
        return request
    }

    static func perform(_ request: URLRequest, sourceId: String, operation: String) async throws -> (Data, URLResponse) {
        let request = try prepare(request)
        let started = Date()
        let redactedURL = redact(url: request.url)
        do {
            let session = await AidokuNetworkSessionStore.shared.session(for: sourceId)
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            ReaderLogger.shared.log(
                "\(operation) \(redactedURL) status=\(status) bytes=\(data.count) elapsedMs=\(elapsed)",
                type: "AidokuNetwork"
            )
            return (data, response)
        } catch {
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            ReaderLogger.shared.log(
                "\(operation) failed \(redactedURL) elapsedMs=\(elapsed) error=\(error.localizedDescription)",
                type: "AidokuNetwork"
            )
            throw error
        }
    }

    static func redact(url: URL?) -> String {
        guard let url else { return "<nil>" }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if components?.queryItems?.isEmpty == false {
            components?.queryItems = [URLQueryItem(name: "query", value: "<redacted>")]
        }
        return components?.url?.absoluteString ?? url.absoluteString
    }
}

// MARK: - Source Manager

@MainActor
final class AidokuSourceManager: ObservableObject {
    static let shared = AidokuSourceManager()

    nonisolated static let maxPackageBytes: UInt64 = 80 * 1024 * 1024
    static let rootDirectory = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("KanzenAidoku", isDirectory: true)
    private static let autoUpdateKey = AidokuBackupBridge.autoUpdateKey
    private static let lastAutoUpdateKey = AidokuBackupBridge.lastAutoUpdateKey
    private static let autoUpdateCooldown: TimeInterval = 24 * 60 * 60

    @Published private(set) var sourceLists: [AidokuSourceListRecord] = []
    @Published private(set) var availableSources: [AidokuSourceListEntry] = []
    @Published private(set) var installedSources: [AidokuInstalledSource] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isRuntimeReady = false
    @Published private(set) var isRuntimeLoading = false
    @Published private(set) var isUpdatingSources = false
    @Published private(set) var lastAutoUpdate: Date?
    @Published var showMatureSources: Bool {
        didSet {
            UserDefaults.standard.set(showMatureSources, forKey: matureSourcesKey)
        }
    }
    @Published var autoUpdateSources: Bool {
        didSet {
            UserDefaults.standard.set(autoUpdateSources, forKey: Self.autoUpdateKey)
        }
    }

    private let sourceListsKey = AidokuBackupBridge.sourceListsKey
    private let installedSourcesKey = AidokuBackupBridge.installedSourcesKey
    private let matureSourcesKey = AidokuBackupBridge.matureSourcesKey
    private var runtimeSources: [String: AidokuRunner.Source] = [:]

    private var sourcesDirectory: URL {
        Self.rootDirectory.appendingPathComponent("Sources", isDirectory: true)
    }

    private var packageCacheDirectory: URL {
        Self.rootDirectory.appendingPathComponent("PackageCache", isDirectory: true)
    }

    private init() {
        showMatureSources = UserDefaults.standard.bool(forKey: matureSourcesKey)
        autoUpdateSources = UserDefaults.standard.object(forKey: Self.autoUpdateKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: Self.autoUpdateKey)
        lastAutoUpdate = UserDefaults.standard.object(forKey: Self.lastAutoUpdateKey) as? Date
        loadPersistedState()
        ensureDirectories()
        Task {
            await ensureRuntimeReady()
            await autoUpdateInstalledSourcesIfNeeded(reason: "launch")
            await refreshSourceLists()
        }
    }

    func enabledSources() -> [AidokuInstalledSource] {
        installedSources
            .filter { $0.isEnabled }
            .filter { showMatureSources || !$0.isMature }
            .sorted {
                if $0.order != $1.order { return $0.order < $1.order }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
    }

    func source(id: String) -> AidokuRunner.Source? {
        runtimeSources[id]
    }

    func metadata(id: String) -> AidokuInstalledSource? {
        installedSources.first { $0.id == id }
    }

    func addSourceList(_ value: String) async throws {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw AidokuSourceError.invalidURL
        }
        guard !sourceLists.contains(where: { $0.url == url.absoluteString }) else {
            throw AidokuSourceError.duplicateSourceList
        }

        ReaderLogger.shared.log("Adding Aidoku source list \(AidokuNetworkClient.redact(url: url))", type: "AidokuSource")
        let loaded: (name: String, sources: [AidokuExternalSourceInfo])
        do {
            loaded = try await loadSourceList(url: url)
        } catch {
            ReaderLogger.shared.log("Failed to add Aidoku source list \(AidokuNetworkClient.redact(url: url)): \(error.localizedDescription)", type: "AidokuSource")
            throw error
        }
        sourceLists.append(
            AidokuSourceListRecord(
                url: url.absoluteString,
                name: loaded.name,
                sourceCount: loaded.sources.count,
                lastRefresh: Date(),
                lastError: nil
            )
        )
        availableSources = deduplicatedAvailableSources(availableSources + loaded.sources.map {
            AidokuSourceListEntry(info: $0, listURL: url, listName: loaded.name)
        })
        saveSourceLists()
        ReaderLogger.shared.log("Added Aidoku source list \(AidokuNetworkClient.redact(url: url)) count=\(loaded.sources.count)", type: "AidokuSource")
    }

    func removeSourceList(_ record: AidokuSourceListRecord) {
        sourceLists.removeAll { $0.url == record.url }
        availableSources.removeAll { $0.listURL.absoluteString == record.url }
        saveSourceLists()
        ReaderLogger.shared.log("Removed Aidoku source list \(AidokuNetworkClient.redact(url: URL(string: record.url)))", type: "AidokuSource")
    }

    func refreshSourceLists() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        ReaderLogger.shared.log("Refreshing Aidoku source lists count=\(sourceLists.count)", type: "AidokuSource")
        var refreshedEntries: [AidokuSourceListEntry] = []
        for index in sourceLists.indices {
            guard let url = URL(string: sourceLists[index].url) else { continue }
            do {
                let loaded = try await loadSourceList(url: url)
                sourceLists[index].name = loaded.name
                sourceLists[index].sourceCount = loaded.sources.count
                sourceLists[index].lastRefresh = Date()
                sourceLists[index].lastError = nil
                refreshedEntries.append(contentsOf: loaded.sources.map {
                    AidokuSourceListEntry(info: $0, listURL: url, listName: loaded.name)
                })
                ReaderLogger.shared.log("Refreshed Aidoku source list \(AidokuNetworkClient.redact(url: url)) count=\(loaded.sources.count)", type: "AidokuSource")
            } catch {
                sourceLists[index].lastError = error.localizedDescription
                ReaderLogger.shared.log("Failed to refresh Aidoku source list \(AidokuNetworkClient.redact(url: url)): \(error.localizedDescription)", type: "AidokuSource")
            }
        }

        availableSources = deduplicatedAvailableSources(refreshedEntries)
        saveSourceLists()
        ReaderLogger.shared.log("Finished refreshing Aidoku source lists available=\(availableSources.count)", type: "AidokuSource")
    }

    func install(_ entry: AidokuSourceListEntry) async throws {
        guard let downloadURL = entry.downloadURL else {
            throw AidokuSourceError.missingDownloadURL
        }
        try validateVersion(entry.info)
        ReaderLogger.shared.log("Installing Aidoku source \(entry.id) from \(entry.listName)", type: "AidokuSource")
        do {
            let installed = try await importSourcePackage(
                from: downloadURL,
                externalInfo: entry.info,
                sourceListURL: entry.listURL.absoluteString,
                packageURL: downloadURL.absoluteString,
                externalIconURL: entry.iconURLString
            )
            ReaderLogger.shared.log("Installed Aidoku source \(installed.id) \(installed.name) version=\(installed.version)", type: "AidokuSource")
        } catch {
            ReaderLogger.shared.log("Failed to install Aidoku source \(entry.id): \(error.localizedDescription)", type: "AidokuSource")
            throw error
        }
    }

    func ensureRuntimeReady() async {
        if isRuntimeReady { return }

        if isRuntimeLoading {
            while isRuntimeLoading && !isRuntimeReady {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return
        }

        isRuntimeLoading = true
        ReaderLogger.shared.log("Preparing Aidoku runtime sources count=\(installedSources.count)", type: "AidokuRuntime")
        await reloadInstalledSources()
        isRuntimeReady = true
        isRuntimeLoading = false
        ReaderLogger.shared.log("Aidoku runtime ready loaded=\(runtimeSources.count)", type: "AidokuRuntime")
    }

    func autoUpdateInstalledSourcesIfNeeded(reason: String) async {
        guard autoUpdateSources else { return }
        guard !installedSources.isEmpty else { return }
        if let lastAutoUpdate, Date().timeIntervalSince(lastAutoUpdate) < Self.autoUpdateCooldown {
            return
        }
        await updateAllInstalledSources(reason: reason)
    }

    func updateAllInstalledSources(reason: String = "manual") async {
        guard !isUpdatingSources else { return }
        isUpdatingSources = true
        defer { isUpdatingSources = false }

        await ensureRuntimeReady()
        let updateCandidates = installedSources.filter { $0.packageURL != nil }
        ReaderLogger.shared.log("Updating Aidoku sources reason=\(reason) count=\(updateCandidates.count)", type: "AidokuSource")

        for source in updateCandidates {
            await updateInstalledSource(source)
        }

        let now = Date()
        lastAutoUpdate = now
        UserDefaults.standard.set(now, forKey: Self.lastAutoUpdateKey)
        ReaderLogger.shared.log("Finished updating Aidoku sources reason=\(reason)", type: "AidokuSource")
    }

    func updateInstalledSource(_ source: AidokuInstalledSource) async {
        guard
            let packageURLString = source.packageURL,
            let packageURL = URL(string: packageURLString)
        else {
            updateError(sourceId: source.id, message: "No package URL is available for updates.")
            return
        }

        ReaderLogger.shared.log("Updating Aidoku source \(source.id)", type: "AidokuSource")
        do {
            let info = AidokuExternalSourceInfo(
                id: source.id,
                name: source.name,
                version: source.version,
                iconURL: source.externalIconURL,
                downloadURL: packageURLString,
                languages: source.languages,
                contentRating: source.contentRating,
                altNames: nil,
                baseURL: nil,
                minAppVersion: nil,
                maxAppVersion: nil,
                lang: nil,
                nsfw: nil,
                file: nil,
                icon: nil
            )
            _ = try await importSourcePackage(
                from: packageURL,
                externalInfo: info,
                sourceListURL: source.sourceListURL,
                packageURL: packageURLString,
                externalIconURL: source.externalIconURL
            )
            ReaderLogger.shared.log("Updated Aidoku source \(source.id)", type: "AidokuSource")
        } catch {
            updateError(sourceId: source.id, message: error.localizedDescription)
        }
    }

    @discardableResult
    func importSourcePackage(from url: URL) async throws -> AidokuInstalledSource {
        try await importSourcePackage(
            from: url,
            externalInfo: nil,
            sourceListURL: nil,
            packageURL: url.absoluteString,
            externalIconURL: nil
        )
    }

    func remove(_ source: AidokuInstalledSource) {
        runtimeSources.removeValue(forKey: source.id)
        installedSources.removeAll { $0.id == source.id }
        let destination = sourcesDirectory.appendingPathComponent(source.id, isDirectory: true)
        try? FileManager.default.removeItem(at: destination)
        saveInstalledSources()
        ReaderLogger.shared.log("Removed Aidoku source \(source.id)", type: "AidokuSource")
    }

    func toggle(_ source: AidokuInstalledSource) {
        guard let index = installedSources.firstIndex(where: { $0.id == source.id }) else { return }
        installedSources[index].isEnabled.toggle()
        saveInstalledSources()
        ReaderLogger.shared.log(
            "\(installedSources[index].isEnabled ? "Enabled" : "Disabled") Aidoku source \(source.id)",
            type: "AidokuSource"
        )
    }

    func move(from offsets: IndexSet, to destination: Int) {
        var ordered = installedSources.sorted {
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        ordered.move(fromOffsets: offsets, toOffset: destination)
        for index in ordered.indices {
            ordered[index].order = index
        }
        installedSources = ordered
        saveInstalledSources()
        ReaderLogger.shared.log("Reordered Aidoku sources moved=\(offsets.count) destination=\(destination)", type: "AidokuSource")
    }

    func reloadInstalledSources() async {
        ensureDirectories()
        var updatedMetadata = installedSources
        let installedIDs = Set(updatedMetadata.map(\.id))
        var loadedRuntime = runtimeSources.filter { installedIDs.contains($0.key) }

        for index in updatedMetadata.indices {
            let sourceId = updatedMetadata[index].id
            let directory = sourcesDirectory.appendingPathComponent(sourceId, isDirectory: true)
            do {
                let runtime = try await AidokuRunner.Source(
                    url: directory,
                    interpreterConfig: interpreterConfig(for: sourceId)
                )
                loadedRuntime[sourceId] = runtime
                updatedMetadata[index].lastError = nil
                updatedMetadata[index].name = runtime.name
                updatedMetadata[index].version = runtime.version
                updatedMetadata[index].languages = runtime.languages
                updatedMetadata[index].contentRatingRawValue = runtime.contentRating.rawValue
                updatedMetadata[index].iconPath = runtime.imageUrl?.path
            } catch {
                updatedMetadata[index].lastError = error.localizedDescription
                if loadedRuntime[sourceId] != nil {
                    ReaderLogger.shared.log("Preserving previous Aidoku runtime for \(sourceId) after reload failure: \(error.localizedDescription)", type: "AidokuRuntime")
                }
                ReaderLogger.shared.log("Failed to load Aidoku source \(sourceId): \(error.localizedDescription)", type: "AidokuRuntime")
            }
        }

        runtimeSources = loadedRuntime
        installedSources = updatedMetadata
        saveInstalledSources()
    }

    func reloadPersistedStateAfterRestore() async {
        loadPersistedState()
        showMatureSources = UserDefaults.standard.bool(forKey: matureSourcesKey)
        autoUpdateSources = UserDefaults.standard.object(forKey: Self.autoUpdateKey) == nil
            ? true
            : UserDefaults.standard.bool(forKey: Self.autoUpdateKey)
        lastAutoUpdate = UserDefaults.standard.object(forKey: Self.lastAutoUpdateKey) as? Date
        isRuntimeReady = false
        runtimeSources.removeAll()
        await ensureRuntimeReady()
        await refreshSourceLists()
        ReaderLogger.shared.log("Reloaded Aidoku source state after backup restore sources=\(installedSources.count)", type: "AidokuBackup")
    }

    func search(sourceId: String, query: String?, page: Int, filters: [AidokuRunner.FilterValue]) async throws -> AidokuRunner.MangaPageResult {
        await ensureRuntimeReady()
        guard let source = runtimeSources[sourceId] else {
            throw AidokuSourceError.sourceNotInstalled
        }
        let started = Date()
        let result = try await source.getSearchMangaList(query: query, page: page, filters: filters)
        logOperation("search", sourceId: sourceId, started: started, count: result.entries.count)
        return result
    }

    func mangaUpdate(sourceId: String, manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws -> AidokuRunner.Manga {
        await ensureRuntimeReady()
        guard let source = runtimeSources[sourceId] else {
            throw AidokuSourceError.sourceNotInstalled
        }
        let started = Date()
        let result = try await source.getMangaUpdate(manga: manga, needsDetails: needsDetails, needsChapters: needsChapters)
        logOperation("mangaUpdate", sourceId: sourceId, started: started, count: result.chapters?.count ?? 0)
        return result
    }

    func pageList(sourceId: String, manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter, nativePages: Bool = true) async throws -> [PageData] {
        await ensureRuntimeReady()
        guard let source = runtimeSources[sourceId] else {
            throw AidokuSourceError.sourceNotInstalled
        }
        let started = Date()
        let pages = try await source.getPageList(manga: manga, chapter: chapter)
        let mapped = try await pages.asyncCompactMap { page in
            try await makeReaderPage(page, source: source, sourceId: sourceId, nativePages: nativePages)
        }
        logOperation("pageList", sourceId: sourceId, started: started, count: mapped.count)
        return mapped
    }

    func home(sourceId: String) async throws -> AidokuRunner.Home {
        await ensureRuntimeReady()
        guard let source = runtimeSources[sourceId] else {
            throw AidokuSourceError.sourceNotInstalled
        }
        let started = Date()
        let result = try await source.getHome()
        logOperation("home", sourceId: sourceId, started: started, count: result.components.count)
        return result
    }

    func listings(sourceId: String) async throws -> [AidokuRunner.Listing] {
        await ensureRuntimeReady()
        guard let source = runtimeSources[sourceId] else {
            throw AidokuSourceError.sourceNotInstalled
        }
        let started = Date()
        let result = try await source.getListings()
        logOperation("listings", sourceId: sourceId, started: started, count: result.count)
        return result
    }

    func mangaList(sourceId: String, listing: AidokuRunner.Listing, page: Int) async throws -> AidokuRunner.MangaPageResult {
        await ensureRuntimeReady()
        guard let source = runtimeSources[sourceId] else {
            throw AidokuSourceError.sourceNotInstalled
        }
        let started = Date()
        let result = try await source.getMangaList(listing: listing, page: page)
        logOperation("mangaList", sourceId: sourceId, started: started, count: result.entries.count)
        return result
    }

    func filters(sourceId: String) async throws -> [AidokuRunner.Filter] {
        await ensureRuntimeReady()
        guard let source = runtimeSources[sourceId] else {
            throw AidokuSourceError.sourceNotInstalled
        }
        let started = Date()
        let result = try await source.getSearchFilters()
        logOperation("filters", sourceId: sourceId, started: started, count: result.count)
        return result
    }

    private func importSourcePackage(
        from url: URL,
        externalInfo: AidokuExternalSourceInfo?,
        sourceListURL: String?,
        packageURL: String?,
        externalIconURL: String?
    ) async throws -> AidokuInstalledSource {
        ensureDirectories()

        let localPackageURL = try await localPackageURL(for: url)
        try validatePackage(at: localPackageURL)

        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kanzen-aidoku-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        try FileManager.default.unzipItem(at: localPackageURL, to: tempDirectory)
        let payload = tempDirectory.appendingPathComponent("Payload", isDirectory: true)
        let runtime = try await AidokuRunner.Source(
            url: payload,
            interpreterConfig: interpreterConfig(for: externalInfo?.id ?? "install")
        )

        guard isValidSourceKey(runtime.key) else {
            throw AidokuSourceError.invalidSourceKey(runtime.key)
        }

        let destination = sourcesDirectory.appendingPathComponent(runtime.key, isDirectory: true)
        let backup = sourcesDirectory.appendingPathComponent("\(runtime.key)-backup-\(UUID().uuidString)", isDirectory: true)
        let hadExistingPayload = FileManager.default.fileExists(atPath: destination.path)
        if hadExistingPayload {
            try FileManager.default.moveItem(at: destination, to: backup)
        }
        do {
            try FileManager.default.moveItem(at: payload, to: destination)
            if hadExistingPayload {
                try? FileManager.default.removeItem(at: backup)
            }
        } catch {
            if hadExistingPayload, FileManager.default.fileExists(atPath: backup.path) {
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.moveItem(at: backup, to: destination)
            }
            throw error
        }

        let installedRuntime = try await AidokuRunner.Source(
            url: destination,
            interpreterConfig: interpreterConfig(for: runtime.key)
        )
        runtimeSources[installedRuntime.key] = installedRuntime

        var metadata = AidokuInstalledSource(
            id: installedRuntime.key,
            name: installedRuntime.name,
            version: installedRuntime.version,
            languages: installedRuntime.languages,
            iconPath: installedRuntime.imageUrl?.path,
            externalIconURL: externalIconURL,
            contentRatingRawValue: installedRuntime.contentRating.rawValue,
            sourceListURL: sourceListURL,
            packageURL: packageURL,
            isEnabled: true,
            order: installedSources.count,
            lastUpdated: Date(),
            lastError: nil
        )

        if let existingIndex = installedSources.firstIndex(where: { $0.id == metadata.id }) {
            metadata.isEnabled = installedSources[existingIndex].isEnabled
            metadata.order = installedSources[existingIndex].order
            installedSources[existingIndex] = metadata
        } else {
            installedSources.append(metadata)
        }

        isRuntimeReady = true
        saveInstalledSources()
        ReaderLogger.shared.log("Imported Aidoku source payload \(metadata.id) version=\(metadata.version)", type: "AidokuSource")
        return metadata
    }

    private func localPackageURL(for url: URL) async throws -> URL {
        if url.isFileURL {
            return url
        }

        let request = URLRequest(url: url)
        let (data, _) = try await AidokuNetworkClient.perform(request, sourceId: "installer", operation: "installPackage")
        let destination = packageCacheDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension.isEmpty ? "aix" : url.pathExtension)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    private func validatePackage(at url: URL) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        if fileSize > Self.maxPackageBytes {
            throw AidokuSourceError.packageTooLarge
        }

        guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil) else {
            throw AidokuSourceError.missingPayload
        }

        var hasSourceJSON = false
        var hasMainWasm = false
        var totalUncompressed: UInt64 = 0

        for entry in archive {
            let path = entry.path.replacingOccurrences(of: "\\", with: "/")
            if path.hasPrefix("/") || path.contains("../") || path.contains("/../") {
                throw AidokuSourceError.unsafeArchivePath(path)
            }
            if !path.hasPrefix("Payload/") {
                throw AidokuSourceError.unsafeArchivePath(path)
            }
            totalUncompressed += UInt64(entry.uncompressedSize)
            if totalUncompressed > Self.maxPackageBytes {
                throw AidokuSourceError.packageTooLarge
            }
            if path == "Payload/source.json" {
                hasSourceJSON = true
            } else if path == "Payload/main.wasm" {
                hasMainWasm = true
            }
        }

        guard hasSourceJSON, hasMainWasm else {
            throw AidokuSourceError.missingPayload
        }
    }

    private func validateVersion(_ info: AidokuExternalSourceInfo) throws {
        if let maxVersion = info.maxAppVersion, compareVersion(maxVersion, to: "0.8.3") == .orderedAscending {
            throw AidokuSourceError.unsupportedSourceVersion
        }
        if let minVersion = info.minAppVersion, compareVersion(minVersion, to: "0.8.3") == .orderedDescending {
            throw AidokuSourceError.unsupportedSourceVersion
        }
    }

    private func loadSourceList(url: URL) async throws -> (name: String, sources: [AidokuExternalSourceInfo]) {
        var request = URLRequest(url: url)
        let (data, _) = try await AidokuNetworkClient.perform(request, sourceId: "sourceList", operation: "sourceList")

        if let decoded = try? JSONDecoder().decode(AidokuCodableSourceList.self, from: data) {
            return (decoded.name, decoded.sources)
        }

        if let decoded = try? JSONDecoder().decode([AidokuExternalSourceInfo].self, from: data) {
            return ("Legacy Source List", decoded)
        }

        let fallbackURL = url.appendingPathComponent("index.min.json")
        request = URLRequest(url: fallbackURL)
        let (fallbackData, _) = try await AidokuNetworkClient.perform(request, sourceId: "sourceList", operation: "sourceListLegacy")
        if let decoded = try? JSONDecoder().decode([AidokuExternalSourceInfo].self, from: fallbackData) {
            return ("Legacy Source List", decoded)
        }

        throw AidokuSourceError.sourceListLoadFailed
    }

    private func deduplicatedAvailableSources(_ entries: [AidokuSourceListEntry]) -> [AidokuSourceListEntry] {
        var seen = Set<String>()
        return entries.filter { entry in
            guard !seen.contains(entry.id) else {
                ReaderLogger.shared.log("Ignored duplicate Aidoku source id=\(entry.id) from \(entry.listName)", type: "AidokuSource")
                return false
            }
            seen.insert(entry.id)
            return true
        }
    }

    private func makeReaderPage(
        _ page: AidokuRunner.Page,
        source: AidokuRunner.Source,
        sourceId: String,
        nativePages: Bool
    ) async throws -> PageData? {
        switch page.content {
        case .url(let url, let context):
            if nativePages {
                return PageData(aidokuURL: url, context: context, source: source, sourceId: sourceId)
            }

            var request = URLRequest(url: url)
            if source.features.providesImageRequests {
                request = (try? await source.getImageRequest(url: url.absoluteString, context: context)) ?? request
            }
            request = try AidokuNetworkClient.prepare(request)

            if source.features.processesPages {
                do {
                    let (data, response) = try await AidokuNetworkClient.perform(request, sourceId: sourceId, operation: "pageImage")
                    if let uiImage = UIImage(data: data) {
                        let pointer = try await source.store(value: uiImage)
                        defer {
                            Task { try? await source.remove(value: pointer) }
                        }
                        let http = response as? HTTPURLResponse
                        let headers = http?.allHeaderFields.reduce(into: [String: String]()) { result, item in
                            if let key = item.key as? String {
                                result[key] = String(describing: item.value)
                            }
                        } ?? [:]
                        let processed = try await source.processPageImage(
                            response: AidokuRunner.Response(
                                code: http?.statusCode ?? 200,
                                headers: headers,
                                request: AidokuRunner.Request(url: request.url, headers: request.allHTTPHeaderFields ?? [:]),
                                image: pointer
                            ),
                            context: context
                        )
                        if let data = processed?.jpegData(compressionQuality: 0.92) ?? processed?.pngData() {
                            return PageData(content: .imageData(data))
                        }
                    }
                } catch {
                    ReaderLogger.shared.log("Page processing failed for \(sourceId): \(error.localizedDescription). Falling back to URL.", type: "AidokuRuntime")
                }
            }

            return PageData(
                content: .url(
                    request.url?.absoluteString ?? url.absoluteString,
                    headers: request.allHTTPHeaderFields ?? [:]
                )
            )

        case .image(let image):
            guard let data = image.jpegData(compressionQuality: 0.92) ?? image.pngData() else {
                throw AidokuSourceError.unsupportedPage
            }
            return PageData(content: .imageData(data))

        case .text(let text):
            return PageData(content: .text(text))

        case .zipFile(let url, let filePath):
            if nativePages, !filePath.lowercased().hasSuffix(".txt") {
                return PageData(aidokuZipURL: url, filePath: filePath, sourceId: sourceId)
            }
            let data = try await zipEntryData(url: url, filePath: filePath, sourceId: sourceId)
            if filePath.lowercased().hasSuffix(".txt"),
               let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) {
                return PageData(content: .text(text))
            }
            return PageData(content: .imageData(data))
        }
    }

    private func zipEntryData(url: URL, filePath: String, sourceId: String) async throws -> Data {
        let localURL: URL
        if url.isFileURL {
            localURL = url
        } else {
            let cacheURL = packageCacheDirectory
                .appendingPathComponent("zip-\(abs(url.absoluteString.hashValue))")
                .appendingPathExtension(url.pathExtension.isEmpty ? "zip" : url.pathExtension)
            if !FileManager.default.fileExists(atPath: cacheURL.path) {
                let (data, _) = try await AidokuNetworkClient.perform(URLRequest(url: url), sourceId: sourceId, operation: "zipPage")
                try data.write(to: cacheURL, options: .atomic)
            }
            localURL = cacheURL
        }

        guard let archive = try? Archive(url: localURL, accessMode: .read, pathEncoding: nil),
              let entry = archive[filePath] else {
            throw AidokuSourceError.unsupportedPage
        }

        var data = Data()
        _ = try archive.extract(entry) { chunk in
            data.append(chunk)
        }
        return data
    }

    private func interpreterConfig(for sourceId: String) -> InterpreterConfiguration {
        InterpreterConfiguration(
            printHandler: { message in
                ReaderLogger.shared.log("[\(sourceId)] \(message)", type: "AidokuRuntime")
            },
            requestHandler: { originalRequest in
                try await AidokuNetworkClient.perform(originalRequest, sourceId: sourceId, operation: "runtime")
            }
        )
    }

    private func updateError(sourceId: String, message: String) {
        guard let index = installedSources.firstIndex(where: { $0.id == sourceId }) else { return }
        installedSources[index].lastError = message
        saveInstalledSources()
        ReaderLogger.shared.log("Aidoku source \(sourceId) error: \(message)", type: "AidokuSource")
    }

    private func logOperation(_ operation: String, sourceId: String, started: Date, count: Int) {
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        ReaderLogger.shared.log("\(operation) source=\(sourceId) count=\(count) elapsedMs=\(elapsed)", type: "AidokuRuntime")
    }

    private func isValidSourceKey(_ sourceKey: String) -> Bool {
        guard !sourceKey.isEmpty else { return false }
        let allowedCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        return sourceKey.unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
    }

    private func compareVersion(_ lhs: String, to rhs: String) -> ComparisonResult {
        let lhsParts = lhs.split(separator: ".").compactMap { Int($0) }
        let rhsParts = rhs.split(separator: ".").compactMap { Int($0) }
        let count = max(lhsParts.count, rhsParts.count)
        for index in 0..<count {
            let left = index < lhsParts.count ? lhsParts[index] : 0
            let right = index < rhsParts.count ? rhsParts[index] : 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }
        return .orderedSame
    }

    private func ensureDirectories() {
        try? FileManager.default.createDirectory(at: Self.rootDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: packageCacheDirectory, withIntermediateDirectories: true)
    }

    private func loadPersistedState() {
        if let data = UserDefaults.standard.data(forKey: sourceListsKey),
           let decoded = try? JSONDecoder().decode([AidokuSourceListRecord].self, from: data) {
            sourceLists = decoded
        }

        if let data = UserDefaults.standard.data(forKey: installedSourcesKey),
           let decoded = try? JSONDecoder().decode([AidokuInstalledSource].self, from: data) {
            installedSources = decoded
        }
    }

    private func saveSourceLists() {
        if let data = try? JSONEncoder().encode(sourceLists) {
            UserDefaults.standard.set(data, forKey: sourceListsKey)
        }
    }

    private func saveInstalledSources() {
        if let data = try? JSONEncoder().encode(installedSources) {
            UserDefaults.standard.set(data, forKey: installedSourcesKey)
        }
    }
}

private extension Array {
    func asyncCompactMap<T>(_ transform: (Element) async throws -> T?) async throws -> [T] {
        var result: [T] = []
        for element in self {
            if let mapped = try await transform(element) {
                result.append(mapped)
            }
        }
        return result
    }
}

extension AidokuRunner.SourceContentRating {
    var kanzenTitle: String {
        switch self {
        case .safe:
            return "Safe"
        case .containsNsfw:
            return "Contains Mature Content"
        case .primarilyNsfw:
            return "Mature"
        }
    }
}
#endif
