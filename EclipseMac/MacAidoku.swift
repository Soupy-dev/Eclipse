import AidokuRunner
import AppKit
import Foundation
import SwiftUI
import ZIPFoundation

struct MacAidokuInstalledSource: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var version: Int
    var languages: [String]
    var isEnabled: Bool
    var order: Int
}

struct MacAidokuAvailableSource: Identifiable, Hashable {
    let id: String
    let name: String
    let version: Int
    let languages: [String]
    let packageURL: URL
    let listURL: URL
}

struct MacAidokuSearchItem: Identifiable, Hashable, Codable {
    let sourceID: String
    let sourceName: String
    let manga: AidokuRunner.Manga
    var id: String { "\(sourceID):\(manga.key)" }
}

struct MacAidokuLibraryEntry: Identifiable, Hashable, Codable {
    var id: String { item.id }
    let item: MacAidokuSearchItem
    var dateAdded: Date
    var lastChapterKey: String?
    var lastChapterTitle: String?
    var lastReadAt: Date?
}

struct MacAidokuOfflineChapter: Identifiable, Hashable, Codable {
    struct Page: Hashable, Codable { let filename: String?; let text: String? }
    let id: UUID
    let item: MacAidokuSearchItem
    let chapterKey: String
    let chapterTitle: String
    let directoryName: String
    let pages: [Page]
    let downloadedAt: Date
    let trackingContext: MacReaderTrackingContext?
}

enum MacReaderPagePayload: Sendable {
    case remote(URL, headers: [String: String])
    case data(Data)
    case file(URL)
    case text(String)
}

enum MacAidokuContentLimits {
    static let sourceListBytes = 5_000_000
    static let runtimeResponseBytes = 40 * 1024 * 1024
    static let packageBytes = 80 * 1024 * 1024
    static let pageBytes = 40 * 1024 * 1024
    static let chapterBytes = 500 * 1024 * 1024
}

enum MacBoundedContent {
    private enum Failure: LocalizedError {
        case invalidURL
        case invalidResponse
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .invalidURL: "The source returned an unsupported URL."
            case .invalidResponse: "The source request returned an invalid response."
            case .tooLarge: "The source response exceeded the safe size limit."
            }
        }
    }

    static func httpData(
        for request: URLRequest,
        maximumBytes: Int,
        requiresSuccessfulStatus: Bool = true,
        session: URLSession = .shared
    ) async throws -> (Data, URLResponse) {
        guard maximumBytes > 0, isHTTP(request.url) else { throw Failure.invalidURL }

        let (bytes, response) = try await session.bytes(for: request)
        guard isHTTP(response.url), let http = response as? HTTPURLResponse else {
            throw Failure.invalidResponse
        }
        if requiresSuccessfulStatus, !(200..<300).contains(http.statusCode) {
            throw Failure.invalidResponse
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            throw Failure.tooLarge
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(maximumBytes, Int(response.expectedContentLength)))
        }
        for try await byte in bytes {
            if data.count.isMultiple(of: 64 * 1024) { try Task.checkCancellation() }
            guard data.count < maximumBytes else { throw Failure.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        return (data, response)
    }

    static func fileData(at url: URL, maximumBytes: Int) throws -> Data {
        guard maximumBytes > 0, url.isFileURL else { throw Failure.invalidURL }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw Failure.invalidURL }
        if let fileSize = values.fileSize, fileSize > maximumBytes { throw Failure.tooLarge }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        if let fileSize = values.fileSize { data.reserveCapacity(min(fileSize, maximumBytes)) }
        while true {
            let remaining = maximumBytes - data.count
            let chunk = try handle.read(upToCount: min(64 * 1024, remaining + 1)) ?? Data()
            guard !chunk.isEmpty else { break }
            guard chunk.count <= remaining else { throw Failure.tooLarge }
            data.append(chunk)
        }
        return data
    }

    static func isHTTP(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

@MainActor
final class MacAidokuStore: ObservableObject {
    static let shared = MacAidokuStore()

    @Published private(set) var installedSources: [MacAidokuInstalledSource] = []
    @Published private(set) var availableSources: [MacAidokuAvailableSource] = []
    @Published private(set) var sourceLists: [String] = []
    @Published private(set) var searchResults: [MacAidokuSearchItem] = []
    @Published private(set) var library: [MacAidokuLibraryEntry] = []
    @Published private(set) var offlineChapters: [MacAidokuOfflineChapter] = []
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    private static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("KanzenAidoku", isDirectory: true)
    private var sourcesDirectory: URL { Self.root.appendingPathComponent("Sources", isDirectory: true) }
    private var cacheDirectory: URL { Self.root.appendingPathComponent("PackageCache", isDirectory: true) }
    private var offlineDirectory: URL { Self.root.appendingPathComponent("OfflineChapters", isDirectory: true) }
    private let installedKey = "kanzenAidokuInstalledSources.mac.v1"
    private let listsKey = "kanzenAidokuSourceLists.mac.v1"
    private let libraryKey = "kanzenAidokuLibrary.mac.v1"
    private let offlineKey = "kanzenAidokuOffline.mac.v1"
    private var runtimes: [String: AidokuRunner.Source] = [:]
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var activeActivities = Set<UUID>()

    private init() {
        ensureDirectories()
        if let data = UserDefaults.standard.data(forKey: installedKey),
           let decoded = try? JSONDecoder().decode([MacAidokuInstalledSource].self, from: data) {
            installedSources = decoded.filter { Self.validSourceID($0.id) }
        }
        sourceLists = UserDefaults.standard.stringArray(forKey: listsKey) ?? []
        if let data = UserDefaults.standard.data(forKey: libraryKey),
           let decoded = try? JSONDecoder().decode([MacAidokuLibraryEntry].self, from: data) { library = decoded }
        if let data = UserDefaults.standard.data(forKey: offlineKey),
           let decoded = try? JSONDecoder().decode([MacAidokuOfflineChapter].self, from: data) {
            offlineChapters = decoded.filter(Self.validOfflineChapter)
        }
        Task { await reloadRuntimes(); await refreshLists() }
    }

    func addSourceList(_ value: String) async -> Bool {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            errorMessage = "Enter a valid HTTP or HTTPS Aidoku source-list URL."
            return false
        }
        if !sourceLists.contains(url.absoluteString) { sourceLists.append(url.absoluteString) }
        UserDefaults.standard.set(sourceLists, forKey: listsKey)
        await refreshLists()
        return errorMessage == nil
    }

    func removeSourceList(_ value: String) {
        sourceLists.removeAll { $0 == value }
        UserDefaults.standard.set(sourceLists, forKey: listsKey)
        Task { await refreshLists() }
    }

    func refreshLists() async {
        let activity = beginActivity()
        errorMessage = nil
        defer { endActivity(activity) }
        var entries: [MacAidokuAvailableSource] = []
        for value in sourceLists {
            guard let url = URL(string: value) else { continue }
            do { entries.append(contentsOf: try await fetchList(url)) }
            catch { errorMessage = "A source list could not be refreshed: \(error.localizedDescription)" }
        }
        var seen = Set<String>()
        availableSources = entries.filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func install(_ entry: MacAidokuAvailableSource) async {
        let activity = beginActivity()
        errorMessage = nil
        defer { endActivity(activity) }
        do {
            let package = try await download(entry.packageURL, maximumBytes: MacAidokuContentLimits.packageBytes)
            defer { try? FileManager.default.removeItem(at: package) }
            try validateArchive(package)
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("aidoku-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.unzipItem(at: package, to: temporary)
            let payload = temporary.appendingPathComponent("Payload", isDirectory: true)
            let payloadValues = try payload.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard payloadValues.isDirectory == true, payloadValues.isSymbolicLink != true,
                  Self.isContainedAfterResolving(payload, in: temporary) else { throw AidokuError.invalidPackage }
            let runtime = try await AidokuRunner.Source(url: payload, interpreterConfig: runtimeConfiguration(sourceID: entry.id))
            guard Self.validSourceID(runtime.key) else { throw AidokuError.invalidPackage }
            guard let destination = Self.directChild(
                named: runtime.key,
                of: sourcesDirectory,
                isDirectory: true
            ), let replacement = Self.directChild(
                named: "\(runtime.key)-replacement",
                of: sourcesDirectory,
                isDirectory: true
            ) else { throw AidokuError.invalidPackage }
            try? FileManager.default.removeItem(at: replacement)
            try FileManager.default.moveItem(at: payload, to: replacement)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: replacement, to: destination)
            let installedRuntime = try await AidokuRunner.Source(url: destination, interpreterConfig: runtimeConfiguration(sourceID: runtime.key))
            runtimes[runtime.key] = installedRuntime
            let metadata = MacAidokuInstalledSource(
                id: runtime.key, name: runtime.name, version: runtime.version, languages: runtime.languages,
                isEnabled: installedSources.first(where: { $0.id == runtime.key })?.isEnabled ?? true,
                order: installedSources.first(where: { $0.id == runtime.key })?.order ?? installedSources.count
            )
            installedSources.removeAll { $0.id == metadata.id }
            installedSources.append(metadata)
            persistInstalled()
        } catch { errorMessage = error.localizedDescription }
    }

    func toggle(_ source: MacAidokuInstalledSource) {
        guard let index = installedSources.firstIndex(where: { $0.id == source.id }) else { return }
        installedSources[index].isEnabled.toggle(); persistInstalled()
    }

    func remove(_ source: MacAidokuInstalledSource) {
        installedSources.removeAll { $0.id == source.id }; runtimes[source.id] = nil
        if Self.validSourceID(source.id),
           let directory = Self.directChild(named: source.id, of: sourcesDirectory, isDirectory: true) {
            try? FileManager.default.removeItem(at: directory)
        }
        persistInstalled()
    }

    func search(_ query: String) {
        searchTask?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }
        searchTask = Task {
            do { try await Task.sleep(for: .milliseconds(350)) }
            catch { return }
            guard !Task.isCancelled, generation == searchGeneration else { return }
            let activity = beginActivity()
            errorMessage = nil
            defer { endActivity(activity) }
            let sources = installedSources.filter(\.isEnabled).compactMap { metadata in runtimes[metadata.id].map { (metadata, $0) } }
            let results = await withTaskGroup(of: [MacAidokuSearchItem].self) { group in
                for (metadata, runtime) in sources {
                    group.addTask {
                        guard let page = try? await runtime.getSearchMangaList(query: trimmed, page: 1, filters: []) else { return [] }
                        return page.entries.prefix(40).map { MacAidokuSearchItem(sourceID: metadata.id, sourceName: metadata.name, manga: $0) }
                    }
                }
                var merged: [MacAidokuSearchItem] = []
                for await items in group { merged.append(contentsOf: items) }
                return merged
            }
            guard !Task.isCancelled, generation == searchGeneration else { return }
            searchResults = results.sorted { $0.manga.title.localizedStandardCompare($1.manga.title) == .orderedAscending }
        }
    }

    func details(for item: MacAidokuSearchItem) async throws -> AidokuRunner.Manga {
        guard let source = runtimes[item.sourceID] else { throw AidokuError.sourceUnavailable }
        return try await source.getMangaUpdate(manga: item.manga, needsDetails: true, needsChapters: true)
    }

    func isInLibrary(_ item: MacAidokuSearchItem) -> Bool { library.contains { $0.id == item.id } }

    func toggleLibrary(_ item: MacAidokuSearchItem) {
        if let index = library.firstIndex(where: { $0.id == item.id }) { library.remove(at: index) }
        else { library.append(.init(item: item, dateAdded: Date(), lastChapterKey: nil, lastChapterTitle: nil, lastReadAt: nil)) }
        persistLibrary()
    }

    func recordRead(item: MacAidokuSearchItem, chapter: AidokuRunner.Chapter) {
        if !isInLibrary(item) { toggleLibrary(item) }
        guard let index = library.firstIndex(where: { $0.id == item.id }) else { return }
        library[index].lastChapterKey = chapter.key
        library[index].lastChapterTitle = chapter.title
        library[index].lastReadAt = Date()
        persistLibrary()
    }

    func trackingContext(
        for manga: AidokuRunner.Manga,
        chapter: AidokuRunner.Chapter
    ) -> MacReaderTrackingContext? {
        guard let chapterNumber = chapter.chapterNumber, chapterNumber.isFinite else { return nil }
        return MacReaderTrackingContext(
            title: manga.title,
            chapterNumber: Double(chapterNumber),
            // A source's chapter array can contain duplicates, alternate languages,
            // or only a recent window, so it is not a trustworthy series total.
            totalChapters: nil
        )
    }

    func isDownloaded(item: MacAidokuSearchItem, chapter: AidokuRunner.Chapter) -> Bool {
        offlineChapters.contains { $0.item.id == item.id && $0.chapterKey == chapter.key }
    }

    func downloadChapter(item: MacAidokuSearchItem, manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async {
        guard !isDownloaded(item: item, chapter: chapter) else { return }
        let activity = beginActivity()
        errorMessage = nil
        defer { endActivity(activity) }
        let directoryName = UUID().uuidString
        let directory = offlineDirectory.appendingPathComponent(directoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let resolved = try await pages(sourceID: item.sourceID, manga: manga, chapter: chapter)
            guard !resolved.isEmpty else { throw AidokuError.network }
            var stored: [MacAidokuOfflineChapter.Page] = []
            var totalBytes = 0
            for (index, page) in resolved.enumerated() {
                switch page {
                case .text(let text):
                    let byteCount = text.utf8.count
                    try addToChapterTotal(byteCount, total: &totalBytes)
                    stored.append(.init(filename: nil, text: text))
                case .data(let data):
                    guard data.count <= MacAidokuContentLimits.pageBytes else { throw AidokuError.packageTooLarge }
                    try addToChapterTotal(data.count, total: &totalBytes)
                    let name = String(format: "%05d.page", index)
                    try data.write(to: directory.appendingPathComponent(name), options: .atomic)
                    stored.append(.init(filename: name, text: nil))
                case .file(let url):
                    let data = try MacBoundedContent.fileData(at: url, maximumBytes: MacAidokuContentLimits.pageBytes)
                    try addToChapterTotal(data.count, total: &totalBytes)
                    let name = String(format: "%05d.page", index)
                    try data.write(to: directory.appendingPathComponent(name), options: .atomic)
                    stored.append(.init(filename: name, text: nil))
                case .remote(let url, let headers):
                    var request = URLRequest(url: url, timeoutInterval: 45)
                    headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
                    let (data, _) = try await MacBoundedContent.httpData(
                        for: request,
                        maximumBytes: MacAidokuContentLimits.pageBytes
                    )
                    try addToChapterTotal(data.count, total: &totalBytes)
                    let name = String(format: "%05d.page", index)
                    try data.write(to: directory.appendingPathComponent(name), options: .atomic)
                    stored.append(.init(filename: name, text: nil))
                }
            }
            let entry = MacAidokuOfflineChapter(
                id: UUID(), item: item, chapterKey: chapter.key,
                chapterTitle: chapter.title ?? "Chapter", directoryName: directoryName,
                pages: stored, downloadedAt: Date(),
                trackingContext: trackingContext(for: manga, chapter: chapter)
            )
            offlineChapters.insert(entry, at: 0); persistOffline()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            errorMessage = error.localizedDescription
        }
    }

    func offlinePages(for chapter: MacAidokuOfflineChapter) -> [MacReaderPagePayload] {
        guard Self.validOfflineChapter(chapter),
              let directory = Self.directChild(named: chapter.directoryName, of: offlineDirectory, isDirectory: true),
              Self.isContainedAfterResolving(directory, in: offlineDirectory) else { return [] }
        return chapter.pages.compactMap { page in
            if let text = page.text { return .text(text) }
            guard let filename = page.filename, Self.validFilename(filename),
                  let url = Self.directChild(named: filename, of: directory, isDirectory: false),
                  FileManager.default.fileExists(atPath: url.path),
                  Self.isContainedAfterResolving(url, in: directory) else { return nil }
            return .file(url)
        }
    }

    func deleteOffline(_ chapter: MacAidokuOfflineChapter) {
        if Self.validOfflineDirectoryName(chapter.directoryName),
           let directory = Self.directChild(named: chapter.directoryName, of: offlineDirectory, isDirectory: true),
           Self.isContainedAfterResolving(directory, in: offlineDirectory) {
            try? FileManager.default.removeItem(at: directory)
        }
        offlineChapters.removeAll { $0.id == chapter.id }; persistOffline()
    }

    func revealOffline(_ chapter: MacAidokuOfflineChapter) {
        guard Self.validOfflineDirectoryName(chapter.directoryName),
              let directory = Self.directChild(named: chapter.directoryName, of: offlineDirectory, isDirectory: true),
              FileManager.default.fileExists(atPath: directory.path),
              Self.isContainedAfterResolving(directory, in: offlineDirectory) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    }

    func pages(sourceID: String, manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [MacReaderPagePayload] {
        guard let source = runtimes[sourceID] else { throw AidokuError.sourceUnavailable }
        let pages = try await source.getPageList(manga: manga, chapter: chapter)
        var result: [MacReaderPagePayload] = []
        var bufferedBytes = 0
        for page in pages {
            switch page.content {
            case .url(let url, let context):
                var request = URLRequest(url: url)
                if source.features.providesImageRequests {
                    request = (try? await source.getImageRequest(url: url.absoluteString, context: context)) ?? request
                }
                guard let resolvedURL = request.url, MacBoundedContent.isHTTP(resolvedURL) else { throw AidokuError.network }
                result.append(.remote(resolvedURL, headers: request.allHTTPHeaderFields ?? [:]))
            case .image(let image):
                if let data = image.pngData() {
                    guard data.count <= MacAidokuContentLimits.pageBytes else { throw AidokuError.packageTooLarge }
                    try addToChapterTotal(data.count, total: &bufferedBytes)
                    result.append(.data(data))
                }
            case .text(let text):
                let byteCount = text.utf8.count
                guard byteCount <= MacAidokuContentLimits.pageBytes else { throw AidokuError.packageTooLarge }
                try addToChapterTotal(byteCount, total: &bufferedBytes)
                result.append(.text(text))
            case .zipFile(let url, let path):
                let data = try await zipData(url: url, path: path)
                try addToChapterTotal(data.count, total: &bufferedBytes)
                result.append(.data(data))
            }
        }
        return result
    }

    private func reloadRuntimes() async {
        for metadata in installedSources {
            guard Self.validSourceID(metadata.id),
                  let directory = Self.directChild(named: metadata.id, of: sourcesDirectory, isDirectory: true),
                  Self.isContainedAfterResolving(directory, in: sourcesDirectory) else { continue }
            if let source = try? await AidokuRunner.Source(url: directory, interpreterConfig: runtimeConfiguration(sourceID: metadata.id)) {
                runtimes[metadata.id] = source
            }
        }
    }

    private func fetchList(_ url: URL) async throws -> [MacAidokuAvailableSource] {
        let (data, _) = try await MacBoundedContent.httpData(
            for: URLRequest(url: url, timeoutInterval: 30),
            maximumBytes: MacAidokuContentLimits.sourceListBytes
        )
        let decoded: [ExternalSource]
        if let list = try? JSONDecoder().decode(SourceList.self, from: data) { decoded = list.sources }
        else if let list = try? JSONDecoder().decode([ExternalSource].self, from: data) { decoded = list }
        else { throw AidokuError.invalidList }
        return decoded.compactMap { info in
            let package: URL?
            if let download = info.downloadURL { package = URL(string: download, relativeTo: url)?.absoluteURL }
            else if let file = info.file { package = URL(string: "sources/\(file)", relativeTo: url)?.absoluteURL }
            else { package = nil }
            guard let package, MacBoundedContent.isHTTP(package) else { return nil }
            return MacAidokuAvailableSource(
                id: info.id, name: info.name, version: info.version, languages: info.languages ?? info.lang.map { [$0] } ?? [],
                packageURL: package, listURL: url
            )
        }
    }

    private func runtimeConfiguration(sourceID: String) -> InterpreterConfiguration {
        InterpreterConfiguration(requestHandler: { request in
            guard MacBoundedContent.isHTTP(request.url) else { throw AidokuError.network }
            var request = request
            request.setValue("1", forHTTPHeaderField: "DNT")
            request.setValue("1", forHTTPHeaderField: "Sec-GPC")
            return try await MacBoundedContent.httpData(
                for: request,
                maximumBytes: MacAidokuContentLimits.runtimeResponseBytes,
                requiresSuccessfulStatus: false
            )
        })
    }

    private func download(_ url: URL, maximumBytes: Int) async throws -> URL {
        let (data, _) = try await MacBoundedContent.httpData(
            for: URLRequest(url: url, timeoutInterval: 60),
            maximumBytes: maximumBytes
        )
        let destination = cacheDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("aix")
        try data.write(to: destination, options: .atomic)
        return destination
    }

    private func validateArchive(_ url: URL) throws {
        guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil) else { throw AidokuError.invalidPackage }
        var sourceJSON = false, wasm = false
        var size: UInt64 = 0
        for entry in archive {
            guard entry.type == .file || entry.type == .directory else { throw AidokuError.invalidPackage }
            let path = entry.path.replacingOccurrences(of: "\\", with: "/")
            guard path.hasPrefix("Payload/"), !path.contains("../"), !path.hasPrefix("/") else { throw AidokuError.invalidPackage }
            let (newSize, overflow) = size.addingReportingOverflow(UInt64(entry.uncompressedSize))
            guard !overflow, newSize <= UInt64(MacAidokuContentLimits.packageBytes) else { throw AidokuError.invalidPackage }
            size = newSize
            sourceJSON = sourceJSON || path == "Payload/source.json"
            wasm = wasm || path == "Payload/main.wasm"
        }
        guard sourceJSON && wasm else { throw AidokuError.invalidPackage }
    }

    private func zipData(url: URL, path: String) async throws -> Data {
        let local: URL
        if url.isFileURL {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let fileSize = values.fileSize,
                  fileSize <= MacAidokuContentLimits.packageBytes else { throw AidokuError.invalidPackage }
            local = url
        } else {
            guard MacBoundedContent.isHTTP(url) else { throw AidokuError.network }
            local = try await download(url, maximumBytes: MacAidokuContentLimits.packageBytes)
        }
        defer { if !url.isFileURL { try? FileManager.default.removeItem(at: local) } }
        guard let archive = try? Archive(url: local, accessMode: .read, pathEncoding: nil),
              let entry = archive[path], entry.type == .file,
              UInt64(entry.uncompressedSize) <= UInt64(MacAidokuContentLimits.pageBytes) else {
            throw AidokuError.invalidPackage
        }
        var data = Data()
        data.reserveCapacity(Int(entry.uncompressedSize))
        _ = try archive.extract(entry) { chunk in
            guard chunk.count <= MacAidokuContentLimits.pageBytes - data.count else {
                throw AidokuError.packageTooLarge
            }
            data.append(chunk)
        }
        return data
    }

    private func addToChapterTotal(_ byteCount: Int, total: inout Int) throws {
        guard byteCount >= 0, byteCount <= MacAidokuContentLimits.chapterBytes - total else {
            throw AidokuError.packageTooLarge
        }
        total += byteCount
    }

    private func beginActivity() -> UUID {
        let token = UUID()
        activeActivities.insert(token)
        isWorking = true
        return token
    }

    private func endActivity(_ token: UUID) {
        activeActivities.remove(token)
        isWorking = !activeActivities.isEmpty
    }

    private func persistInstalled() {
        if let data = try? JSONEncoder().encode(installedSources) { UserDefaults.standard.set(data, forKey: installedKey) }
    }
    private func persistLibrary() {
        if let data = try? JSONEncoder().encode(library) { UserDefaults.standard.set(data, forKey: libraryKey) }
    }
    private func persistOffline() {
        if let data = try? JSONEncoder().encode(offlineChapters) { UserDefaults.standard.set(data, forKey: offlineKey) }
    }
    private func ensureDirectories() {
        try? FileManager.default.createDirectory(at: sourcesDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: offlineDirectory, withIntermediateDirectories: true)
    }
    private static func validSourceID(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).contains($0)
        }
    }
    private static func validOfflineChapter(_ chapter: MacAidokuOfflineChapter) -> Bool {
        validOfflineDirectoryName(chapter.directoryName) && chapter.pages.allSatisfy { page in
            page.filename.map(validFilename) ?? true
        }
    }
    private static func validOfflineDirectoryName(_ value: String) -> Bool {
        guard let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.caseInsensitiveCompare(value) == .orderedSame
    }
    private static func validFilename(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." &&
            !value.contains("/") && !value.contains("\\") &&
            URL(fileURLWithPath: value).lastPathComponent == value
    }
    private static func directChild(named name: String, of root: URL, isDirectory: Bool) -> URL? {
        guard validFilename(name) else { return nil }
        let standardizedRoot = root.standardizedFileURL
        let candidate = standardizedRoot.appendingPathComponent(name, isDirectory: isDirectory).standardizedFileURL
        guard candidate.deletingLastPathComponent().path == standardizedRoot.path else { return nil }
        return candidate
    }
    private static func isContainedAfterResolving(_ candidate: URL, in root: URL) -> Bool {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        return resolvedCandidate.hasPrefix(resolvedRoot + "/")
    }
}

private extension MacAidokuStore {
    struct SourceList: Decodable { let sources: [ExternalSource] }
    struct ExternalSource: Decodable {
        let id: String; let name: String; let version: Int
        let downloadURL: String?; let languages: [String]?; let lang: String?; let file: String?
    }
    enum AidokuError: LocalizedError {
        case network, invalidList, invalidPackage, sourceUnavailable, packageTooLarge
        var errorDescription: String? {
            switch self {
            case .network: "The Aidoku source request failed."
            case .invalidList: "The URL did not return a valid Aidoku source list."
            case .invalidPackage: "The Aidoku source package is invalid or unsafe."
            case .sourceUnavailable: "The selected Aidoku source is unavailable."
            case .packageTooLarge: "The chapter is too large to save safely."
            }
        }
    }
}
