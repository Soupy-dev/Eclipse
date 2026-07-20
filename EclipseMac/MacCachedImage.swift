import AppKit
import ImageIO
import SwiftUI

/// A small, Mac-specific image surface for dense catalog UIs.
///
/// `AsyncImage` decodes the source asset at its original dimensions. Catalog art is often
/// several thousand pixels wide, so doing that for every card can produce visible scroll
/// hitching. This view downloads through the shared URL cache, downsamples off the main
/// actor to the size the view actually needs, and keeps the decoded result in a bounded
/// in-memory cache.
struct MacCachedImage: View {
    let url: URL?
    let targetSize: CGSize
    var placeholderSystemImage = "photo"

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.055)
                    Image(systemName: placeholderSystemImage)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: loadIdentity) {
            image = nil
            guard let requestedURL = url else { return }
            let loaded = await MacImagePipeline.shared.image(
                at: requestedURL,
                targetSize: targetSize
            )
            guard !Task.isCancelled, requestedURL == url else { return }
            image = loaded?.value
        }
    }

    private var loadIdentity: String {
        "\(url?.absoluteString ?? "none")|\(Int(targetSize.width))x\(Int(targetSize.height))"
    }

    static func preheat(urls: [URL], targetSize: CGSize) async {
        await withTaskGroup(of: Void.self) { group in
            for url in Array(Set(urls)).prefix(2) {
                group.addTask {
                    _ = await MacImagePipeline.shared.image(at: url, targetSize: targetSize)
                }
            }
        }
    }
}

private final class MacSendableImage: @unchecked Sendable {
    let value: NSImage

    init(_ value: NSImage) {
        self.value = value
    }
}

private actor MacImagePipeline {
    static let shared = MacImagePipeline()

    private let cache = NSCache<NSString, MacSendableImage>()
    private var inFlight: [NSString: Task<MacSendableImage?, Never>] = [:]

    private init() {
        cache.countLimit = 180
        cache.totalCostLimit = 128 * 1_024 * 1_024
    }

    func image(at url: URL, targetSize: CGSize) async -> MacSendableImage? {
        let pixelWidth = max(96, Int(targetSize.width * 2))
        let pixelHeight = max(96, Int(targetSize.height * 2))
        let cacheKey = "\(url.absoluteString)|\(pixelWidth)x\(pixelHeight)" as NSString

        if let cached = cache.object(forKey: cacheKey) {
            return cached
        }

        if let existing = inFlight[cacheKey] {
            return await existing.value
        }

        let task = Task.detached(priority: .utility) { () -> MacSendableImage? in
            do {
                var request = URLRequest(url: url)
                request.cachePolicy = .returnCacheDataElseLoad
                request.timeoutInterval = 20
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      let image = Self.downsample(
                          data: data,
                          maxPixelSize: max(pixelWidth, pixelHeight)
                      ) else {
                    return nil
                }
                return MacSendableImage(image)
            } catch {
                return nil
            }
        }
        inFlight[cacheKey] = task
        let result = await task.value
        inFlight.removeValue(forKey: cacheKey)
        if let result {
            cache.setObject(
                result,
                forKey: cacheKey,
                cost: max(1, pixelWidth * pixelHeight * 4)
            )
        }
        return result
    }

    private nonisolated static func downsample(data: Data, maxPixelSize: Int) -> NSImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else {
            return nil
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}
