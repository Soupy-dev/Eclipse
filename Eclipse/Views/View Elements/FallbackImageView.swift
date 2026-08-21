//
//  FallbackImageView.swift
//  Sora
//
//  Created by Francesco on 07/08/25.
//

import CryptoKit
import ImageIO
import SwiftUI
import UIKit

/// Loads untrusted provider artwork through the same numeric-address-pinned
/// transport used by provider requests. Passing provider URLs directly to an
/// image library would re-resolve DNS and could turn merely displaying a row
/// into a request to a loopback or private-network address.
struct PinnedProviderImage<Placeholder: View>: View {
    private let request: PinnedProviderImageRequest?
    private let placeholder: () -> Placeholder

    @State private var image: UIImage?

    init(
        _ url: URL?,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.request = url.map(PinnedProviderImageRequest.publicResource)
        self.placeholder = placeholder
    }

    init(
        stremioResource rawValue: String?,
        configuredBaseURL: String,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.request = PinnedProviderImageRequest.stremioResource(
            rawValue,
            configuredBaseURL: configuredBaseURL
        )
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
            } else {
                placeholder()
            }
        }
        .task(id: request?.cacheKey) {
            image = nil
            guard let request else { return }
            if let cached = PinnedProviderImageLoader.cachedImage(for: request) {
                image = cached
                return
            }
            guard let loaded = await PinnedProviderImageLoader.load(request),
                  !Task.isCancelled,
                  self.request == request else {
                return
            }
            image = loaded.image
        }
    }
}

struct PinnedProviderImageRequest: Sendable, Hashable {
    let url: URL
    let stremioAuthority: SkyStreamPinnedOriginAuthority?
    let stremioConfiguredBaseURL: String?
    let cacheKey: String

    static func publicResource(_ url: URL) -> Self {
        Self(
            url: url,
            stremioAuthority: nil,
            stremioConfiguredBaseURL: nil,
            cacheKey: opaqueCacheKey("public\u{0}\(url.absoluteString)")
        )
    }

    static func stremioResource(
        _ rawValue: String?,
        configuredBaseURL: String
    ) -> Self? {
        guard let rawValue,
              let authority = try? SkyStreamPinnedOriginAuthority.stremio(
                configuredBaseURL: configuredBaseURL
              ),
              let url = try? authority.resolveResourceURL(rawValue) else {
            return nil
        }
        return Self(
            url: url,
            stremioAuthority: authority,
            stremioConfiguredBaseURL: configuredBaseURL,
            cacheKey: opaqueCacheKey(
                "stremio\u{0}\(ProfileManager.shared.activeProfileID.uuidString.lowercased())"
                    + "\u{0}\(configuredBaseURL)\u{0}\(url.absoluteString)"
            )
        )
    }

    private static func opaqueCacheKey(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum PinnedProviderImageLoader {
    struct LoadedImage: @unchecked Sendable {
        let image: UIImage
    }

    private final class ImageCache: @unchecked Sendable {
        private let storage: NSCache<NSString, UIImage> = {
            let cache = NSCache<NSString, UIImage>()
            cache.countLimit = 256
            cache.totalCostLimit = 64 * 1_024 * 1_024
            return cache
        }()

        func image(for key: String) -> UIImage? {
            storage.object(forKey: key as NSString)
        }

        func store(_ image: UIImage, for key: String, cost: Int) {
            storage.setObject(image, forKey: key as NSString, cost: cost)
        }
    }

    private static let maximumResponseBytes = 4 * 1_024 * 1_024
    private static let maximumSourceDimension = 8_192
    private static let maximumSourcePixels = 40_000_000
    private static let thumbnailDimension = 768
    private static let client = SkyStreamPinnedHTTPClient()
    private static let cache = ImageCache()

    static func cachedImage(for url: URL) -> UIImage? {
        cachedImage(for: .publicResource(url))
    }

    static func cachedImage(for request: PinnedProviderImageRequest) -> UIImage? {
        cache.image(for: request.cacheKey)
    }

    static func load(_ url: URL) async -> LoadedImage? {
        await load(.publicResource(url))
    }

    static func load(_ request: PinnedProviderImageRequest) async -> LoadedImage? {
        let response: SkyStreamPinnedHTTPClient.Response
        do {
            if let configuredBaseURL = request.stremioConfiguredBaseURL {
                response = try await StremioClient.shared.fetchProviderResource(
                    request.url,
                    configuredBaseURL: configuredBaseURL,
                    maximumResponseBytes: maximumResponseBytes
                )
            } else {
                response = try await client.fetch(
                    request.url.absoluteString,
                    purpose: .pluginRequest,
                    allowsCookies: false,
                    maximumRedirects: 5,
                    maximumResponseBytes: maximumResponseBytes,
                    timeout: 15
                )
            }
        } catch {
            return nil
        }
        guard (200...299).contains(response.response.statusCode),
              !response.data.isEmpty else {
            return nil
        }
        if let mimeType = response.response.mimeType?.lowercased(),
           !mimeType.hasPrefix("image/"),
           mimeType != "application/octet-stream" {
            return nil
        }
        guard let image = decodedImage(from: response.data) else { return nil }
        let decodedCost: Int = {
            guard let cgImage = image.cgImage else { return response.data.count }
            let (pixels, pixelOverflow) = cgImage.width.multipliedReportingOverflow(by: cgImage.height)
            let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
            return pixelOverflow || byteOverflow ? response.data.count : bytes
        }()
        cache.store(image, for: request.cacheKey, cost: decodedCost)
        return LoadedImage(image: image)
    }

    static func decodedImage(from data: Data) -> UIImage? {
        guard !data.isEmpty,
              data.count <= maximumResponseBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0,
              width <= maximumSourceDimension,
              height <= maximumSourceDimension else {
            return nil
        }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= maximumSourcePixels else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailDimension
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }
        return UIImage(cgImage: thumbnail)
    }
}

struct FallbackImageView: View {
    let isMovie: Bool
    let size: CGSize

    init(isMovie: Bool, size: CGSize = CGSize(width: 120, height: 180)) {
        self.isMovie = isMovie
        self.size = size
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(
                LinearGradient(
                    gradient: Gradient(colors: gradientColors),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                VStack(spacing: iconSpacing) {
                    Image(systemName: iconName)
                        .font(iconFont)
                        .foregroundColor(.white)
                    Text(mediaTypeText)
                        .font(textFont)
                        .fontWeight(.medium)
                        .foregroundColor(.white.opacity(0.9))
                }
            )
            .frame(width: size.width, height: size.height)
            .aspectRatio(2/3, contentMode: .fill)
    }

    private var gradientColors: [Color] {
        if isMovie {
            return [Color.blue.opacity(0.8), Color.purple.opacity(0.8)]
        } else {
            return [Color.green.opacity(0.8), Color.teal.opacity(0.8)]
        }
    }

    private var iconName: String {
        isMovie ? "film" : "tv"
    }

    private var mediaTypeText: String {
        isMovie ? "Movie" : "TV"
    }

    private var iconFont: Font {
        if size.width <= 60 {
            return .title2
        } else if size.width <= 120 {
            return .title
        } else {
            return .largeTitle
        }
    }

    private var textFont: Font {
        if size.width <= 60 {
            return .caption2
        } else if size.width <= 120 {
            return .caption
        } else {
            return .body
        }
    }

    private var iconSpacing: CGFloat {
        if size.width <= 60 {
            return 2
        } else if size.width <= 120 {
            return 4
        } else {
            return 8
        }
    }
}
