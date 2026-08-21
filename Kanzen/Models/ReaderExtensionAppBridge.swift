#if !os(tvOS)
import Foundation
import ImageIO
import SwiftSoup
import SwiftUI
import UIKit

/// Ephemeral bridge from the provider-neutral extension runtime into Kanzen's
/// existing chapter/reader pipeline. It is never encoded or synced.
struct ReaderExtensionChapterPayload {
    let sourceID: ReaderExtensionSourceID
    let mediaType: ReaderExtensionMediaType
    let item: ReaderExtensionItem
    let chapter: ReaderExtensionChapter
}

enum ReaderContentRating: Int, Codable, Sendable {
    // These values deliberately preserve the historical on-disk Aidoku rating
    // representation used by libraries, progress, and download manifests.
    case unknown = 0
    case safe = 1
    case suggestive = 2
    case nsfw = 3

    init(maturity: ReaderExtensionMaturity) {
        switch maturity {
        case .safe: self = .safe
        case .mature: self = .nsfw
        case .unknown: self = .unknown
        }
    }
}

extension ReaderExtensionItem {
    var eclipseContentRating: ReaderContentRating {
        ReaderContentRating(maturity: maturity)
    }

    /// Mangayomi-compatible providers commonly return detail-only fields and
    /// omit the list item's title, cover, or URL. Preserve the trusted list or
    /// persisted seed while applying richer detail fields.
    func mergingDetail(_ detail: ReaderExtensionItem) -> ReaderExtensionItem {
        let detailTitle = detail.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let usableDetailTitle = !detailTitle.isEmpty
            && detailTitle != detail.key
            && detailTitle != key
        return ReaderExtensionItem(
            key: detail.key.isEmpty ? key : detail.key,
            title: usableDetailTitle ? detail.title : title,
            url: detail.url ?? url,
            coverURL: detail.coverURL ?? coverURL,
            description: detail.description ?? description,
            author: detail.author ?? author,
            artist: detail.artist ?? artist,
            status: detail.status == .unknown ? status : detail.status,
            tags: detail.tags.isEmpty ? tags : detail.tags,
            maturity: detail.maturity == .unknown ? maturity : detail.maturity
        )
    }
}

extension ReaderExtensionChapter {
    func kanzenChapter(
        sourceID: ReaderExtensionSourceID,
        mediaType: ReaderExtensionMediaType,
        item: ReaderExtensionItem,
        index: Int
    ) -> Chapter {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayNumber = trimmedTitle.isEmpty ? "Chapter \(index + 1)" : trimmedTitle
        return Chapter(
            chapterNumber: displayNumber,
            idx: index,
            chapterData: [
                ChapterData(
                    params: ReaderExtensionChapterPayload(
                        sourceID: sourceID,
                        mediaType: mediaType,
                        item: item,
                        chapter: self
                    ),
                    title: trimmedTitle,
                    scanlationGroup: scanlator ?? ""
                )
            ]
        )
    }
}

enum ReaderExtensionWebNovelSanitizer {
    private static let maximumHTMLBytes = 4 * 1_024 * 1_024

    /// Eclipse's text reader never executes chapter markup. Parse only bounded
    /// UTF-8 HTML, discard active elements, and hand UIKit inert plain text.
    static func plainText(from html: String) throws -> String {
        guard html.utf8.count <= maximumHTMLBytes else {
            throw ReaderExtensionError.contentTooLarge
        }
        try ReaderExtensionHTMLPreflight.validate(
            html,
            maximumBytes: maximumHTMLBytes,
            maximumNodeTokens: ReaderExtensionNovelSanitizer.maximumDOMElements - 4
        )
        let document = try SwiftSoup.parse(html)
        let elements = try document.getAllElements()
        guard elements.size() <= ReaderExtensionNovelSanitizer.maximumDOMElements else {
            throw ReaderExtensionError.contentTooLarge
        }
        try document.select("script,iframe,frame,form,input,button,object,embed,style,link,meta,svg,math").remove()
        for element in elements {
            for attribute in element.getAttributes()?.asList() ?? []
            where attribute.getKey().lowercased().hasPrefix("on") {
                try element.removeAttr(attribute.getKey())
            }
        }
        let text = try document.text().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ReaderExtensionError.resultInvalid("The novel chapter did not contain readable text.")
        }
        return text
    }
}

extension ReaderExtensionPageResource {
    var pageData: PageData {
        PageData(content: .readerExtension(self))
    }
}

enum ReaderExtensionImageSafety {
    static let maximumPixelDimension: Int64 = 32_768
    static let maximumPixelsPerFrame: Int64 = 40_000_000
    static let maximumAggregatePixels: Int64 = 80_000_000
    static let maximumFrameCount = 120

    struct Metadata: Equatable, Sendable {
        let pixelWidth: Int64
        let pixelHeight: Int64
        let frameCount: Int
    }

    @discardableResult
    static func validate(_ data: Data) throws -> Metadata {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
            throw ReaderExtensionError.resultInvalid("image data could not be inspected")
        }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0, frameCount <= maximumFrameCount else {
            throw ReaderExtensionError.resultInvalid("image frame count exceeded the safety limit")
        }

        var totalPixels: Int64 = 0
        var firstWidth: Int64 = 0
        var firstHeight: Int64 = 0
        for index in 0..<frameCount {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
                  let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value else {
                throw ReaderExtensionError.resultInvalid("image dimensions were unavailable")
            }
            try validateDimensions(pixelWidth: width, pixelHeight: height, frameCount: frameCount)
            let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
            guard !overflow else { throw ReaderExtensionError.contentTooLarge }
            let (nextTotal, totalOverflow) = totalPixels.addingReportingOverflow(pixels)
            guard !totalOverflow, nextTotal <= maximumAggregatePixels else {
                throw ReaderExtensionError.contentTooLarge
            }
            totalPixels = nextTotal
            if index == 0 { firstWidth = width; firstHeight = height }
        }
        return Metadata(pixelWidth: firstWidth, pixelHeight: firstHeight, frameCount: frameCount)
    }

    static func validateDimensions(pixelWidth: Int64, pixelHeight: Int64, frameCount: Int = 1) throws {
        guard pixelWidth > 0, pixelHeight > 0, frameCount > 0, frameCount <= maximumFrameCount,
              pixelWidth <= maximumPixelDimension, pixelHeight <= maximumPixelDimension else {
            throw ReaderExtensionError.contentTooLarge
        }
        let (pixels, overflow) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        guard !overflow, pixels <= maximumPixelsPerFrame else {
            throw ReaderExtensionError.contentTooLarge
        }
    }

    static func decodedImage(_ data: Data, maximumPixelSize: Int) async throws -> UIImage {
        try await Task.detached(priority: .userInitiated) {
            let metadata = try validate(data)
            let options = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
                throw ReaderExtensionError.resultInvalid("image data could not be decoded")
            }
            let boundedSize = max(1, min(maximumPixelSize, Int(max(metadata.pixelWidth, metadata.pixelHeight))))
            let thumbnailOptions = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: boundedSize
            ] as [CFString: Any] as CFDictionary
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
                throw ReaderExtensionError.resultInvalid("image data could not be decoded")
            }
            return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
        }.value
    }
}

@MainActor
private final class ReaderExtensionAssetImageCache {
    static let shared = ReaderExtensionAssetImageCache()
    let images: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.name = "Eclipse.ReaderExtensions.AssetImages"
        cache.countLimit = 200
        cache.totalCostLimit = 64 * 1_024 * 1_024
        return cache
    }()
    private var inFlight: [String: Task<UIImage, Error>] = [:]

    func image(
        cacheKey: String,
        url: URL,
        sourceID: ReaderExtensionSourceID,
        maximumPixelSize: Int
    ) async throws -> UIImage {
        if let cached = images.object(forKey: cacheKey as NSString) { return cached }
        if let existing = inFlight[cacheKey] { return try await existing.value }
        let task = Task<UIImage, Error> {
            let response = try await ReaderExtensionManager.shared.fetchAsset(
                at: url,
                sourceID: sourceID
            )
            try Task.checkCancellation()
            return try await ReaderExtensionImageSafety.decodedImage(
                response.body,
                maximumPixelSize: maximumPixelSize
            )
        }
        inFlight[cacheKey] = task
        defer { inFlight[cacheKey] = nil }
        let image = try await task.value
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        images.setObject(image, forKey: cacheKey as NSString, cost: cost)
        return image
    }
}

/// A drop-in resizable image surface that sends both legacy module artwork and
/// Reader Extension assets through numeric-address-pinned transports.
struct ReaderScopedRemoteImage<Placeholder: View>: View {
    let url: URL?
    let readerExtensionSourceID: ReaderExtensionSourceID?
    let onImage: ((UIImage) -> Void)?
    let maximumPixelSize: Int
    let placeholder: () -> Placeholder

    @State private var secureImage: UIImage?
    @State private var secureLoadFailed = false
    @State private var cacheGeneration = UUID()

    init(
        url: URL?,
        readerExtensionSourceID: ReaderExtensionSourceID?,
        onImage: ((UIImage) -> Void)? = nil,
        maximumPixelSize: Int = 2_400,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.readerExtensionSourceID = readerExtensionSourceID
        self.onImage = onImage
        self.maximumPixelSize = max(1, min(maximumPixelSize, 2_400))
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if readerExtensionSourceID != nil {
                if let secureImage {
                    Image(uiImage: secureImage).resizable()
                } else {
                    placeholder()
                }
            } else {
                ReaderPinnedRemoteImage(
                    url: url,
                    onImage: onImage,
                    maximumPixelSize: maximumPixelSize
                ) {
                    placeholder()
                }
            }
        }
        .task(id: "\(secureTaskID)|\(cacheGeneration.uuidString)") {
            guard let sourceID = readerExtensionSourceID, let url else { return }
            secureImage = nil
            secureLoadFailed = false
            let scopeID = ReaderExtensionManager.shared.assetCacheScopeID()
            let cacheKey = secureCacheKey(scopeID: scopeID, sourceID: sourceID, url: url)
            do {
                let image = try await ReaderExtensionAssetImageCache.shared.image(
                    cacheKey: cacheKey,
                    url: url,
                    sourceID: sourceID,
                    maximumPixelSize: maximumPixelSize
                )
                secureImage = image
                onImage?(image)
            } catch {
                guard !Task.isCancelled else { return }
                secureLoadFailed = true
            }
        }
        .accessibilityValue(secureLoadFailed ? "Image failed to load" : "")
        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in
            invalidateSecureCache()
        }
        .onReceive(NotificationCenter.default.publisher(for: .readerExtensionAuthenticationDidChange)) { _ in
            invalidateSecureCache()
        }
        .onReceive(NotificationCenter.default.publisher(for: .readerExtensionResourceHeadersDidChange)) { _ in
            invalidateSecureCache()
        }
    }

    private var secureTaskID: String {
        guard let sourceID = readerExtensionSourceID, let url else { return "legacy" }
        return "\(sourceID.rawValue)|\(url.absoluteString)"
    }

    private func secureCacheKey(scopeID: String, sourceID: ReaderExtensionSourceID, url: URL) -> String {
        "\(scopeID)|\(sourceID.rawValue)|\(maximumPixelSize)|\(url.absoluteString)"
    }

    private func invalidateSecureCache() {
        ReaderExtensionAssetImageCache.shared.images.removeAllObjects()
        secureImage = nil
        secureLoadFailed = false
        cacheGeneration = UUID()
    }
}
#endif
