//
//  pageData.swift
//  Kanzen
//
//  Created by Dawud Osman on 15/07/2025.
//

import CryptoKit
import Foundation
import SwiftUI

private var kanzenReaderCanvasSwiftUIColor: Color {
    ExperimentalFeatureState.isEnabledAtLaunch
        ? Color(red: 0.055, green: 0.050, blue: 0.090)
        : .black
}

private var kanzenReaderCanvasUIColor: UIColor {
    ExperimentalFeatureState.isEnabledAtLaunch
        ? UIColor(red: 0.055, green: 0.050, blue: 0.090, alpha: 1)
        : .black
}

enum ChapterPosition {
    case prev
    case curr
    case next
}

enum ReaderPageContent: Equatable {
    case url(String, headers: [String: String] = [:])
    case readerExtension(ReaderExtensionPageResource)
    case imageData(Data)
    case text(String)
    case transition
}

struct PageData: Identifiable, Equatable {
    let id = UUID()
    let content: ReaderPageContent

    init(content: String) {
        if content == "CHAPTER_END" {
            self.content = .transition
        } else {
            self.content = .url(content)
        }
    }

    init(content: ReaderPageContent) {
        self.content = content
    }

    var urlString: String? {
        if case .url(let value, _) = content {
            return value
        }
        return nil
    }

    var headers: [String: String] {
        if case .url(_, let headers) = content {
            return headers
        }
        return [:]
    }

    var readerExtensionResource: ReaderExtensionPageResource? {
        if case .readerExtension(let resource) = content {
            return resource
        }
        return nil
    }

    var imageData: Data? {
        if case .imageData(let data) = content {
            return data
        }
        return nil
    }

    var textContent: String? {
        if case .text(let text) = content {
            return text
        }
        return nil
    }

    var isTransition: Bool {
        if case .transition = content {
            return true
        }
        return false
    }

    var isImageLike: Bool {
        imageData != nil || urlString != nil || readerExtensionResource != nil
    }

    var cacheKey: String {
        switch content {
        case .url(let value, let headers):
            return ReaderPinnedImageIdentity.cacheKey(
                urlString: value,
                headers: headers,
                maximumResponseBytes: ReaderPinnedImageLimits.pageResponseBytes,
                maximumPixelSize: ReaderPinnedImageLimits.pagePixelSize
            )
        case .readerExtension(let resource):
            return "reader-extension-\(resource.sourceID.rawValue)-\(resource.key)-\(resource.requestID.uuidString)"
        case .imageData:
            return "image-data-\(id.uuidString)"
        case .text(let text):
            return "text-\(text.hashValue)-\(id.uuidString)"
        case .transition:
            return "transition-\(id.uuidString)"
        }
    }

    var body: chapterView {
        chapterView(page: self, index: "0")
    }

    static func == (lhs: PageData, rhs: PageData) -> Bool {
        lhs.id == rhs.id
    }
}

struct Chapters: Identifiable {
    let id = UUID()
    let language: String
    var chapters: [Chapter]
}

struct Chapter: Identifiable {
    let id = UUID()
    let chapterNumber: String
    let idx: Int
    let chapterData: [ChapterData]?
}

enum ChapterIdentityNormalizer {
    private static let numberPattern = #"(\d+(?:\.\d+)?)"#
    private static let volumeChapterRegex = try? NSRegularExpression(
        pattern: #"\bvol(?:ume)?\.?\s*\#(numberPattern).*?\b(?:ch(?:apter)?|ep(?:isode)?|episode)\.?\s*\#(numberPattern)"#
    )
    private static let chapterRegex = try? NSRegularExpression(
        pattern: #"\b(?:ch(?:apter)?|ep(?:isode)?|episode)\.?\s*\#(numberPattern)"#
    )
    private static let leadingNumberRegex = try? NSRegularExpression(
        pattern: #"^\s*\#(numberPattern)\b"#
    )

    static func key(for chapterNumber: String) -> String {
        let lowered = chapterNumber
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if let match = firstMatch(
            in: lowered,
            regex: volumeChapterRegex
        ),
           let volumeRange = Range(match.range(at: 1), in: lowered),
           let chapterRange = Range(match.range(at: 2), in: lowered) {
            let chapter = normalizedNumericString(String(lowered[chapterRange]))
            return "v\(normalizedNumericString(String(lowered[volumeRange]))):c\(chapter)"
        }

        if let match = firstMatch(
            in: lowered,
            regex: chapterRegex
        ),
           let chapterRange = Range(match.range(at: 1), in: lowered) {
            return "c\(normalizedNumericString(String(lowered[chapterRange])))"
        }

        if let match = firstMatch(in: lowered, regex: leadingNumberRegex),
           let chapterRange = Range(match.range(at: 1), in: lowered) {
            return "c\(normalizedNumericString(String(lowered[chapterRange])))"
        }

        return lowered.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func numericValue(in value: String) -> Double? {
        var token = ""
        var lastValue: Double?

        func finishToken() {
            if let parsed = Double(token) {
                lastValue = parsed
            }
            token.removeAll(keepingCapacity: true)
        }

        for character in value {
            if character.isNumber {
                token.append(character)
            } else if character == ".", !token.isEmpty, !token.contains(".") {
                token.append(character)
            } else if !token.isEmpty {
                finishToken()
            }
        }
        if !token.isEmpty {
            finishToken()
        }
        return lastValue
    }

    static func deduplicatedNumbers(_ numbers: [String]) -> [String] {
        var seen = Set<String>()
        return numbers.filter { number in
            seen.insert(key(for: number)).inserted
        }
    }

    static func deduplicatedChapters(_ chapters: [Chapter], reindex: Bool = false) -> [Chapter] {
        var seen = Set<String>()
        let unique = chapters.filter { chapter in
            seen.insert(key(for: chapter.chapterNumber)).inserted
        }

        guard reindex else { return unique }
        return unique.enumerated().map { index, chapter in
            Chapter(
                chapterNumber: chapter.chapterNumber,
                idx: index,
                chapterData: chapter.chapterData
            )
        }
    }

    private static func normalizedNumericString(_ value: String) -> String {
        guard let number = Double(value) else { return value }
        if number.isFinite,
           number.truncatingRemainder(dividingBy: 1) == 0,
           let integer = Int(exactly: number) {
            return String(integer)
        }
        return String(number)
    }

    private static func firstMatch(in value: String, regex: NSRegularExpression?) -> NSTextCheckingResult? {
        guard let regex else { return nil }
        return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value))
    }
}

struct ChapterData: Identifiable {
    let id = UUID()
    var scanlationGroup: String = ""
    var title: String = ""
    let params: Any?

    init?(dict: [String: Any]) {
        if let scanlationGroup = dict["scanlation_group"] as? String, let params = dict["id"] {
            self.scanlationGroup = scanlationGroup
            self.params = params
            self.title = dict["title"] as? String ?? ""
            return
        }

        if let href = dict["href"] as? String {
            self.params = href
            self.title = dict["title"] as? String ?? ""
            self.scanlationGroup = ""
            return
        }

        return nil
    }

    init(params: Any?, title: String = "", scanlationGroup: String = "") {
        self.params = params
        self.title = title
        self.scanlationGroup = scanlationGroup
    }
}

struct chapterView: View {
    let page: PageData
    let index: String

    var body: some View {
        if page.isTransition {
            TransitionPage(index: index)
        } else if let text = page.textContent {
            ReaderTextPageView(text: text)
        } else if let data = page.imageData, let image = UIImage(data: data) {
            ReaderDataImageView(image: image)
        } else if let resource = page.readerExtensionResource {
            ReaderExtensionPageImageView(resource: resource)
        } else if let urlString = page.urlString, let url = URL(string: urlString) {
            ReaderPinnedPageImage(url: url, page: page)
        } else {
            ReaderPageFailureView()
        }
    }
}

private struct ReaderExtensionPageImageView: View {
    let resource: ReaderExtensionPageResource

    private enum LoadState {
        case loading
        case loaded(UIImage)
        case failed
    }

    @State private var state: LoadState = .loading

    var body: some View {
        Group {
            switch state {
            case .loading:
                CircularLoader()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let image):
                ReaderDataImageView(image: image)
            case .failed:
                ReaderPageFailureView()
            }
        }
        .background(kanzenReaderCanvasSwiftUIColor)
        .task(id: resource.requestID) {
            state = .loading
            do {
                let response = try await ReaderExtensionManager.shared.fetchPage(resource)
                try Task.checkCancellation()
                let image = try await ReaderExtensionImageSafety.decodedImage(response.body, maximumPixelSize: 8_192)
                state = .loaded(image)
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed
            }
        }
    }
}

private struct ReaderPageFailureView: View {
    var body: some View {
        Text("Page failed to load")
            .foregroundColor(.white.opacity(0.75))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(kanzenReaderCanvasSwiftUIColor)
    }
}

private struct ReaderTextPageView: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.body)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
        }
        .background(kanzenReaderCanvasSwiftUIColor)
    }
}

private struct ReaderDataImageView: View {
    let image: UIImage

    var body: some View {
        GeometryReader { proxy in
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: max(proxy.size.width, 1))
                .frame(maxHeight: .infinity)
                .background(kanzenReaderCanvasSwiftUIColor)
        }
        .background(kanzenReaderCanvasSwiftUIColor)
    }
}

enum ReaderPinnedImageLimits {
    static let artworkResponseBytes = 4 * 1_024 * 1_024
    static let pageResponseBytes = 12 * 1_024 * 1_024
    static let artworkPixelSize = 2_400
    static let pagePixelSize = 8_192
}

enum ReaderPinnedImageIdentity {
    static func cacheKey(
        urlString: String,
        headers: [String: String],
        maximumResponseBytes: Int,
        maximumPixelSize: Int,
        namespace: String = ""
    ) -> String {
        digest([
            "reader-pinned-image-v1",
            namespace,
            urlString,
            canonicalHeaders(headers),
            String(maximumResponseBytes),
            String(maximumPixelSize)
        ])
    }

    static func digest(_ components: [String]) -> String {
        var input = Data()
        for component in components {
            let bytes = Data(component.utf8)
            input.append(Data(String(bytes.count).utf8))
            input.append(0x3A)
            input.append(bytes)
            input.append(0x1F)
        }
        return SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalHeaders(_ headers: [String: String]) -> String {
        headers
            .map { ($0.key.lowercased(), $0.value) }
            .sorted {
                if $0.0 == $1.0 { return $0.1 < $1.1 }
                return $0.0 < $1.0
            }
            .map { name, value in
                "\(name.utf8.count):\(name)\(value.utf8.count):\(value)"
            }
            .joined(separator: "\u{1E}")
    }
}

struct ReaderPinnedImageRequest: Sendable {
    let url: URL
    let headers: SkyStreamSanitizedHeaders
    let maximumResponseBytes: Int
    let maximumPixelSize: Int
    let cacheKey: String
    let clientScopeKey: String

    static func make(
        url: URL,
        headers rawHeaders: [String: String] = [:],
        maximumResponseBytes: Int = ReaderPinnedImageLimits.artworkResponseBytes,
        maximumPixelSize: Int = ReaderPinnedImageLimits.artworkPixelSize,
        profileScopeID: String
    ) throws -> ReaderPinnedImageRequest {
        let boundedResponseBytes = max(
            1,
            min(maximumResponseBytes, ReaderPinnedImageLimits.pageResponseBytes)
        )
        let boundedPixelSize = max(1, min(maximumPixelSize, ReaderPinnedImageLimits.pagePixelSize))
        let sanitizedHeaders = try SkyStreamHeaderSanitizer.sanitize(
            rawHeaders,
            purpose: .pluginRequest
        )
        let origin = originIdentity(for: url)
        let clientScopeKey = ReaderPinnedImageIdentity.digest([
            "reader-pinned-client-v1",
            profileScopeID,
            origin,
            ReaderPinnedImageIdentity.cacheKey(
                urlString: "",
                headers: sanitizedHeaders.values,
                maximumResponseBytes: 1,
                maximumPixelSize: 1
            )
        ])
        return ReaderPinnedImageRequest(
            url: url,
            headers: sanitizedHeaders,
            maximumResponseBytes: boundedResponseBytes,
            maximumPixelSize: boundedPixelSize,
            cacheKey: ReaderPinnedImageIdentity.cacheKey(
                urlString: url.absoluteString,
                headers: sanitizedHeaders.values,
                maximumResponseBytes: boundedResponseBytes,
                maximumPixelSize: boundedPixelSize,
                namespace: profileScopeID
            ),
            clientScopeKey: clientScopeKey
        )
    }

    private static func originIdentity(for url: URL) -> String {
        if url.isFileURL { return "file" }
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        let defaultPort = scheme == "https" ? 443 : (scheme == "http" ? 80 : -1)
        return "\(scheme)|\(host)|\(url.port ?? defaultPort)"
    }
}

private enum ReaderPinnedImageError: Error {
    case invalidLocalFile
    case invalidResponse
}

actor ReaderPinnedImageLoader {
    struct LoadedImage: @unchecked Sendable {
        let image: UIImage
    }

    static let shared = ReaderPinnedImageLoader()

    private let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.name = "Eclipse.Kanzen.LegacyPinnedImages"
        cache.countLimit = 200
        cache.totalCostLimit = 128 * 1_024 * 1_024
        return cache
    }()
    private var clients: [String: SkyStreamPinnedHTTPClient] = [:]
    private var clientOrder: [String] = []
    private var inFlightData: [String: Task<Data, Error>] = [:]
    private var inFlightImages: [String: Task<LoadedImage, Error>] = [:]
    private let maximumClientScopes = 64

    func image(for request: ReaderPinnedImageRequest) async throws -> LoadedImage {
        if let cached = images.object(forKey: request.cacheKey as NSString) {
            return LoadedImage(image: cached)
        }
        if let existing = inFlightImages[request.cacheKey] {
            let loaded = try await existing.value
            try Task.checkCancellation()
            return loaded
        }

        let task = Task<LoadedImage, Error> { [self] in
            let data = try await data(for: request)
            try Task.checkCancellation()
            let image = try await ReaderExtensionImageSafety.decodedImage(
                data,
                maximumPixelSize: request.maximumPixelSize
            )
            return LoadedImage(image: image)
        }
        inFlightImages[request.cacheKey] = task
        do {
            let loaded = try await task.value
            inFlightImages[request.cacheKey] = nil
            images.setObject(
                loaded.image,
                forKey: request.cacheKey as NSString,
                cost: Self.cacheCost(for: loaded.image)
            )
            return loaded
        } catch {
            inFlightImages[request.cacheKey] = nil
            throw error
        }
    }

    func data(for request: ReaderPinnedImageRequest) async throws -> Data {
        let dataKey = ReaderPinnedImageIdentity.digest([
            "reader-pinned-data-v1",
            request.cacheKey,
            String(request.maximumResponseBytes)
        ])
        if let existing = inFlightData[dataKey] {
            let data = try await existing.value
            try Task.checkCancellation()
            return data
        }

        let task: Task<Data, Error>
        if request.url.isFileURL {
            task = Task.detached(priority: .userInitiated) {
                let data = try Self.readLocalFile(
                    at: request.url,
                    maximumBytes: request.maximumResponseBytes
                )
                _ = try ReaderExtensionImageSafety.validate(data)
                return data
            }
        } else {
            let client = client(for: request.clientScopeKey)
            task = Task {
                let response = try await client.fetch(
                    request.url.absoluteString,
                    purpose: .pluginRequest,
                    headers: request.headers,
                    allowsCookies: true,
                    maximumRedirects: 5,
                    maximumResponseBytes: request.maximumResponseBytes,
                    timeout: 45
                )
                guard (200...299).contains(response.response.statusCode),
                      !response.data.isEmpty else {
                    throw ReaderPinnedImageError.invalidResponse
                }
                _ = try await Task.detached(priority: .userInitiated) {
                    try ReaderExtensionImageSafety.validate(response.data)
                }.value
                return response.data
            }
        }
        inFlightData[dataKey] = task
        do {
            let data = try await task.value
            inFlightData[dataKey] = nil
            try Task.checkCancellation()
            return data
        } catch {
            inFlightData[dataKey] = nil
            throw error
        }
    }

    func removeAll() {
        inFlightData.values.forEach { $0.cancel() }
        inFlightImages.values.forEach { $0.cancel() }
        inFlightData.removeAll()
        inFlightImages.removeAll()
        clients.removeAll()
        clientOrder.removeAll()
        images.removeAllObjects()
    }

    private func client(for scopeKey: String) -> SkyStreamPinnedHTTPClient {
        if let existing = clients[scopeKey] { return existing }
        while clients.count >= maximumClientScopes, let oldest = clientOrder.first {
            clientOrder.removeFirst()
            clients[oldest] = nil
        }
        let client = SkyStreamPinnedHTTPClient()
        clients[scopeKey] = client
        clientOrder.append(scopeKey)
        return client
    }

    private static func readLocalFile(at url: URL, maximumBytes: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize > 0,
              fileSize <= maximumBytes else {
            throw ReaderPinnedImageError.invalidLocalFile
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw ReaderPinnedImageError.invalidLocalFile
        }
        return data
    }

    private static func cacheCost(for image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        let (pixels, pixelOverflow) = cgImage.width.multipliedReportingOverflow(by: cgImage.height)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        return pixelOverflow || byteOverflow ? 0 : bytes
    }
}

struct ReaderPinnedRemoteImage<Placeholder: View>: View {
    let url: URL?
    let headers: [String: String]
    let onImage: ((UIImage) -> Void)?
    let maximumPixelSize: Int
    let maximumResponseBytes: Int
    private let placeholder: () -> Placeholder

    @State private var image: UIImage?
    @State private var loadFailed = false
    @State private var profileGeneration = UUID()

    init(
        url: URL?,
        headers: [String: String] = [:],
        onImage: ((UIImage) -> Void)? = nil,
        maximumPixelSize: Int = ReaderPinnedImageLimits.artworkPixelSize,
        maximumResponseBytes: Int = ReaderPinnedImageLimits.artworkResponseBytes,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.headers = headers
        self.onImage = onImage
        self.maximumPixelSize = maximumPixelSize
        self.maximumResponseBytes = maximumResponseBytes
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable()
            } else {
                placeholder()
            }
        }
        .task(id: taskID) {
            image = nil
            loadFailed = false
            guard let url else { return }
            do {
                let request = try ReaderPinnedImageRequest.make(
                    url: url,
                    headers: headers,
                    maximumResponseBytes: maximumResponseBytes,
                    maximumPixelSize: maximumPixelSize,
                    profileScopeID: ProfileManager.shared.activeProfileID.uuidString
                )
                let loaded = try await ReaderPinnedImageLoader.shared.image(for: request)
                try Task.checkCancellation()
                image = loaded.image
                onImage?(loaded.image)
            } catch {
                guard !Task.isCancelled else { return }
                loadFailed = true
            }
        }
        .accessibilityValue(loadFailed ? "Image failed to load" : "")
        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in
            image = nil
            loadFailed = false
            profileGeneration = UUID()
        }
    }

    private var taskID: String {
        ReaderPinnedImageIdentity.cacheKey(
            urlString: url?.absoluteString ?? "",
            headers: headers,
            maximumResponseBytes: maximumResponseBytes,
            maximumPixelSize: maximumPixelSize,
            namespace: "\(ProfileManager.shared.activeProfileID.uuidString)|\(profileGeneration.uuidString)"
        )
    }
}

private struct ReaderPinnedPageImage: View {
    let url: URL
    let page: PageData

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            ReaderPinnedRemoteImage(
                url: url,
                headers: page.headers,
                maximumPixelSize: ReaderPageImageOptions.displayMaximumPixelSize(),
                maximumResponseBytes: ReaderPinnedImageLimits.pageResponseBytes
            ) {
                CircularLoader()
            }
            .scaledToFit()
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .background(kanzenReaderCanvasSwiftUIColor)
        }
        .background(kanzenReaderCanvasSwiftUIColor)
    }
}

enum ReaderPageImageOptions {
    static func makePrefetchers(
        for pages: [PageData],
        targetSize: CGSize? = nil,
        scaleFactor: CGFloat? = nil
    ) -> [ReaderPinnedImagePrefetcher] {
        var seen = Set<String>()
        var groups: [String: [ReaderPinnedImageRequest]] = [:]
        let maximumPixelSize = resolvedMaximumPixelSize(
            targetSize: targetSize,
            scaleFactor: scaleFactor
        )
        let profileScopeID = ProfileManager.shared.activeProfileID.uuidString

        for page in pages {
            guard page.readerExtensionResource == nil else { continue }
            guard let value = page.urlString,
                  let url = URL(string: value) else { continue }
            guard let request = try? ReaderPinnedImageRequest.make(
                url: url,
                headers: page.headers,
                maximumResponseBytes: ReaderPinnedImageLimits.pageResponseBytes,
                maximumPixelSize: maximumPixelSize,
                profileScopeID: profileScopeID
            ), seen.insert(request.cacheKey).inserted else { continue }
            groups[request.clientScopeKey, default: []].append(request)
        }

        return groups.values.map { requests in
            ReaderPinnedImagePrefetcher(requests: requests)
        }
    }

    static func start(_ prefetchers: [ReaderPinnedImagePrefetcher]) {
        prefetchers.forEach { $0.start() }
    }

    static func stop(_ prefetchers: inout [ReaderPinnedImagePrefetcher]) {
        prefetchers.forEach { $0.stop() }
        prefetchers.removeAll()
    }

    static func request(
        for page: PageData,
        targetSize: CGSize?,
        scaleFactor: CGFloat?
    ) throws -> ReaderPinnedImageRequest {
        guard let value = page.urlString, let url = URL(string: value) else {
            throw ReaderPinnedImageError.invalidResponse
        }
        return try ReaderPinnedImageRequest.make(
            url: url,
            headers: page.headers,
            maximumResponseBytes: ReaderPinnedImageLimits.pageResponseBytes,
            maximumPixelSize: resolvedMaximumPixelSize(
                targetSize: targetSize,
                scaleFactor: scaleFactor
            ),
            profileScopeID: ProfileManager.shared.activeProfileID.uuidString
        )
    }

    static func displayMaximumPixelSize(scaleFactor: CGFloat? = nil) -> Int {
        resolvedMaximumPixelSize(targetSize: nil, scaleFactor: scaleFactor)
    }

    private static func defaultReaderTargetSize(scaleFactor: CGFloat?) -> CGSize? {
        let screen = UIScreen.main
        let scale = scaleFactor ?? screen.scale
        let viewportWidth = max(screen.bounds.width, 1)
        let viewportHeight = max(screen.bounds.height, viewportWidth * 1.45)
        let targetWidth = max(viewportWidth * scale, 900)
        let targetHeight = max(viewportHeight * scale * 3, targetWidth * 6)
        return CGSize(width: targetWidth, height: targetHeight)
    }

    private static func resolvedMaximumPixelSize(
        targetSize: CGSize?,
        scaleFactor: CGFloat?
    ) -> Int {
        let scale = scaleFactor ?? UIScreen.main.scale
        let defaultDimension = defaultReaderTargetSize(scaleFactor: scaleFactor).map {
            max($0.width, $0.height)
        } ?? 0
        let requestedDimension = targetSize.map {
            max($0.width, $0.height) * max(scale, 1)
        } ?? 0
        let dimension = max(defaultDimension, requestedDimension)
        guard dimension.isFinite else { return ReaderPinnedImageLimits.pagePixelSize }
        return max(1, min(Int(dimension.rounded(.up)), ReaderPinnedImageLimits.pagePixelSize))
    }
}

final class ReaderPinnedImagePrefetcher: @unchecked Sendable {
    private let requests: [ReaderPinnedImageRequest]
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(requests: [ReaderPinnedImageRequest]) {
        self.requests = requests
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil, !requests.isEmpty else { return }
        let requests = self.requests
        task = Task {
            await withTaskGroup(of: Void.self) { group in
                var nextIndex = 0
                let initialCount = min(3, requests.count)
                for _ in 0..<initialCount {
                    let request = requests[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        _ = try? await ReaderPinnedImageLoader.shared.image(for: request)
                    }
                }
                while await group.next() != nil {
                    guard !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    if nextIndex < requests.count {
                        let request = requests[nextIndex]
                        nextIndex += 1
                        group.addTask {
                            _ = try? await ReaderPinnedImageLoader.shared.image(for: request)
                        }
                    }
                }
            }
        }
    }

    func stop() {
        lock.lock()
        let task = self.task
        self.task = nil
        lock.unlock()
        task?.cancel()
    }
}

struct ZoomablePageView: UIViewRepresentable {
    let page: PageData

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 3.0
        scrollView.delegate = context.coordinator
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.backgroundColor = kanzenReaderCanvasUIColor

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = kanzenReaderCanvasUIColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.heightAnchor),
            imageView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor)
        ])

        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView
        context.coordinator.load(page: page)

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.load(page: page)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        weak var scrollView: UIScrollView?
        private var currentPageKey: String?
        private var authorizationTask: Task<Void, Never>?

        deinit {
            authorizationTask?.cancel()
        }

        func load(page: PageData) {
            guard currentPageKey != page.cacheKey else { return }
            currentPageKey = page.cacheKey
            authorizationTask?.cancel()
            authorizationTask = nil

            if let data = page.imageData {
                imageView?.image = UIImage(data: data)
                return
            }

            if let resource = page.readerExtensionResource {
                imageView?.image = nil
                let pageKey = page.cacheKey
                authorizationTask = Task { @MainActor [weak self] in
                    do {
                        let response = try await ReaderExtensionManager.shared.fetchPage(resource)
                        try Task.checkCancellation()
                        guard let self,
                              self.currentPageKey == pageKey else { return }
                        let image = try await ReaderExtensionImageSafety.decodedImage(
                            response.body,
                            maximumPixelSize: 8_192
                        )
                        self.imageView?.image = image
                    } catch {
                        guard !Task.isCancelled else { return }
                        self?.imageView?.image = nil
                    }
                }
                return
            }

            guard page.urlString != nil else {
                imageView?.image = nil
                return
            }

            let scale = scrollView?.window?.screen.scale ?? UIScreen.main.scale
            imageView?.image = nil

            let pageKey = page.cacheKey
            authorizationTask = Task { @MainActor [weak self] in
                do {
                    let request = try ReaderPageImageOptions.request(
                        for: page,
                        targetSize: self?.scrollView?.bounds.size,
                        scaleFactor: scale
                    )
                    let loaded = try await ReaderPinnedImageLoader.shared.image(for: request)
                    try Task.checkCancellation()
                    guard let self, self.currentPageKey == pageKey else { return }
                    self.imageView?.image = loaded.image
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.imageView?.image = nil
                }
            }
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > 1.0 {
                scrollView.setZoomScale(1.0, animated: true)
            } else {
                let location = gesture.location(in: imageView)
                let rect = CGRect(x: location.x - 50, y: location.y - 50, width: 100, height: 100)
                scrollView.zoom(to: rect, animated: true)
            }
        }
    }
}

struct TransitionPage: View {
    var index: String

    var body: some View {
        Text("Chapter \(index) End")
            .frame(maxWidth: .infinity)
            .clipped()
    }
}
