#if os(macOS)
import AppKit
import ImageIO
#if !arch(x86_64)
import CoreImage
import CoreML
import Vision
#endif

actor MacReaderImagePipeline {
    static let shared = MacReaderImagePipeline()
    private final class CachedImage: NSObject {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }
    private let cache: NSCache<NSString, CachedImage> = {
        let cache = NSCache<NSString, CachedImage>()
        cache.totalCostLimit = 96 * 1_024 * 1_024
        cache.countLimit = 32
        return cache
    }()
    #if !arch(x86_64)
    private var models: [String: VNCoreMLModel] = [:]
    #endif

    func image(page: PageData, request: ReaderPinnedImageRequest?, settings: MacReaderSettingsSnapshot, width: CGFloat, scope: UUID, storageLocation: DownloadStorageLocation?) async throws -> CGImage {
        try Task.checkCancellation()
        let storageLease = try storageLocation.map { try DownloadStorageRegistry.shared.acquire($0) }
        defer { storageLease?.close() }
        let key = "\(scope):\(page.cacheKey):\(Int(width)):\(settings.downsample):\(settings.cropBorders):\(settings.upscale):\(settings.upscaleHeight):\(settings.modelURL.path):\(settings.modelRevision)" as NSString
        if let cached = cache.object(forKey: key) { return cached.image }
        let data: Data
        switch page.content {
        case .imageData(let value): data = value
        case .readerExtension(let resource): data = try await ReaderExtensionManager.shared.fetchPage(resource).body
        case .url:
            guard let request else { throw ReaderExtensionError.resultInvalid("The page has no usable image source.") }
            data = try await ReaderPinnedImageLoader.shared.data(for: request)
        case .text, .transition: throw ReaderExtensionError.resultInvalid("The page has no usable image source.")
        }
        try Task.checkCancellation()
        let decoded = try await Task.detached(priority: .userInitiated) {
            let metadata = try ReaderExtensionImageSafety.validate(data)
            guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { throw ReaderExtensionError.resultInvalid("Image decoding failed.") }
            let target = settings.downsample ? max(900, Int(width * 3)) : Int(max(metadata.pixelWidth, metadata.pixelHeight))
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true, kCGImageSourceThumbnailMaxPixelSize: min(target, Int(max(metadata.pixelWidth, metadata.pixelHeight)))]
            guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ReaderExtensionError.resultInvalid("Image decoding failed.") }
            return settings.cropBorders ? Self.cropBorders(decoded) ?? decoded : decoded
        }.value
        try Task.checkCancellation()
        var result = decoded
        #if !arch(x86_64)
        if PlatformCapabilities.current.intelMacCompatibility.supportsReaderImageUpscaling,
           settings.upscale, decoded.height <= settings.upscaleHeight, FileManager.default.fileExists(atPath: settings.modelURL.path) {
            do { result = try upscale(decoded, modelURL: settings.modelURL, revision: settings.modelRevision) } catch { ReaderLogger.shared.log("Reader model processing failed; displaying the original page.", type: "Reader") }
        }
        #endif
        try Task.checkCancellation()
        cache.setObject(CachedImage(result), forKey: key, cost: result.bytesPerRow * result.height)
        return result
    }

    #if !arch(x86_64)
    private func upscale(_ image: CGImage, modelURL: URL, revision: String) throws -> CGImage {
        let key = modelURL.path + ":" + revision
        let model: VNCoreMLModel
        if let existing = models[key] { model = existing }
        else {
            let compiled = try MLModel.compileModel(at: modelURL)
            defer { try? FileManager.default.removeItem(at: compiled) }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            model = try VNCoreMLModel(for: MLModel(contentsOf: compiled, configuration: configuration))
            models = [key: model]
        }
        let request = VNCoreMLRequest(model: model)
        request.imageCropAndScaleOption = .scaleFit
        try VNImageRequestHandler(cgImage: image).perform([request])
        let pixelBuffer = (request.results?.first as? VNPixelBufferObservation)?.pixelBuffer ?? (request.results?.first as? VNCoreMLFeatureValueObservation)?.featureValue.imageBufferValue
        guard let pixelBuffer else { throw ReaderExtensionError.resultInvalid("The model did not produce an image.") }
        try ReaderExtensionImageSafety.validateDimensions(pixelWidth: Int64(CVPixelBufferGetWidth(pixelBuffer)), pixelHeight: Int64(CVPixelBufferGetHeight(pixelBuffer)))
        let output = CIImage(cvPixelBuffer: pixelBuffer)
        guard let result = CIContext().createCGImage(output, from: output.extent) else { throw ReaderExtensionError.resultInvalid("The model output could not be displayed.") }
        return result
    }

    #endif

    nonisolated static func cropBorders(_ cgImage: CGImage) -> CGImage? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 8, height > 8 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        func pixel(atX x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let offset = y * bytesPerRow + x * bytesPerPixel
            return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]), Int(pixels[offset + 3]))
        }

        let borderStepX = max(1, width / 40)
        let borderStepY = max(1, height / 40)
        var samples: [(r: Int, g: Int, b: Int, a: Int)] = []
        for x in stride(from: 0, to: width, by: borderStepX) {
            samples.append(pixel(atX: x, y: 0))
            samples.append(pixel(atX: x, y: height - 1))
        }
        for y in stride(from: 0, to: height, by: borderStepY) {
            samples.append(pixel(atX: 0, y: y))
            samples.append(pixel(atX: width - 1, y: y))
        }
        guard !samples.isEmpty else { return nil }
        let borderColor = samples.reduce((r: 0, g: 0, b: 0, a: 0)) { partial, sample in
            (partial.r + sample.r, partial.g + sample.g, partial.b + sample.b, partial.a + sample.a)
        }
        let count = max(samples.count, 1)
        let average = (
            r: borderColor.r / count,
            g: borderColor.g / count,
            b: borderColor.b / count,
            a: borderColor.a / count
        )

        func isBorderPixel(_ sample: (r: Int, g: Int, b: Int, a: Int)) -> Bool {
            if sample.a <= 10 { return true }
            let distance = abs(sample.r - average.r) + abs(sample.g - average.g) + abs(sample.b - average.b)
            let nearWhite = sample.r >= 245 && sample.g >= 245 && sample.b >= 245
            let nearBlack = sample.r <= 10 && sample.g <= 10 && sample.b <= 10
            return distance <= 42 || nearWhite || nearBlack
        }

        func rowLooksLikeBorder(_ y: Int) -> Bool {
            let step = max(1, width / 180)
            var matches = 0
            var total = 0
            for x in stride(from: 0, to: width, by: step) {
                total += 1
                if isBorderPixel(pixel(atX: x, y: y)) {
                    matches += 1
                }
            }
            return total > 0 && Double(matches) / Double(total) >= 0.94
        }

        func columnLooksLikeBorder(_ x: Int, from top: Int, through bottom: Int) -> Bool {
            let step = max(1, height / 180)
            var matches = 0
            var total = 0
            for y in stride(from: top, through: bottom, by: step) {
                total += 1
                if isBorderPixel(pixel(atX: x, y: y)) {
                    matches += 1
                }
            }
            return total > 0 && Double(matches) / Double(total) >= 0.94
        }

        let maxVerticalCrop = Int(Double(height) * 0.35)
        let maxHorizontalCrop = Int(Double(width) * 0.35)
        var top = 0
        while top < maxVerticalCrop, rowLooksLikeBorder(top) {
            top += 1
        }

        var bottom = height - 1
        while height - 1 - bottom < maxVerticalCrop, bottom > top, rowLooksLikeBorder(bottom) {
            bottom -= 1
        }

        var left = 0
        while left < maxHorizontalCrop, columnLooksLikeBorder(left, from: top, through: bottom) {
            left += 1
        }

        var right = width - 1
        while width - 1 - right < maxHorizontalCrop, right > left, columnLooksLikeBorder(right, from: top, through: bottom) {
            right -= 1
        }

        let cropWidth = right - left + 1
        let cropHeight = bottom - top + 1
        guard cropWidth > 0, cropHeight > 0 else { return nil }
        let croppedArea = Double(cropWidth * cropHeight)
        let originalArea = Double(width * height)
        guard croppedArea / originalArea >= 0.45 else { return nil }
        guard left > 1 || top > 1 || width - 1 - right > 1 || height - 1 - bottom > 1 else { return nil }

        guard let cropped = cgImage.cropping(to: CGRect(x: left, y: top, width: cropWidth, height: cropHeight)) else {
            return nil
        }
        return cropped
    }

}
#endif
