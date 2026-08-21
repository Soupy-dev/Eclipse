import Foundation

enum MPVUserShaderLibrary {

    private static let subdirectory = "Shaders"

    private static let lock = NSLock()

    private static var cachedPaths: [MPVNeuralUpscaler: String?] = [:]

    private static var warnedUpscalers: Set<MPVNeuralUpscaler> = []

    static func shaderPath(for upscaler: MPVNeuralUpscaler) -> String? {
        guard let resource = upscaler.shaderResource else { return nil }

        lock.lock()
        defer { lock.unlock() }

        if let cached = cachedPaths[upscaler] { return cached }

        let path = locateBundledShader(name: resource.name, extension: resource.extension)
        cachedPaths[upscaler] = path

        if path == nil, warnedUpscalers.insert(upscaler).inserted {
            Logger.shared.log(
                "[MPVUserShaderLibrary] missing bundled shader upscaler=\(upscaler.rawValue) resource=\(resource.name).\(resource.extension) - check the Shaders folder reference is in the app target's Copy Bundle Resources phase",
                type: "MPV"
            )
        }
        return path
    }

    private static func locateBundledShader(name: String, extension ext: String) -> String? {
        let filename = "\(name).\(ext)"

        if let candidate = Bundle.main.resourceURL?
            .appendingPathComponent(subdirectory, isDirectory: true)
            .appendingPathComponent(filename)
            .path,
            FileManager.default.fileExists(atPath: candidate) {
            return candidate
        }

        return Bundle.main.path(
            forResource: name,
            ofType: ext,
            inDirectory: subdirectory
        ) ?? Bundle.main.path(
            forResource: name,
            ofType: ext
        )
    }

    static var supportsConvolutionalUpscalers: Bool {
        let memoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        return memoryGB >= 2.5
    }

    static func supportsUpscaler(_ upscaler: MPVNeuralUpscaler) -> Bool {
        MPVScalerPolicy.supportsSelection(upscaler, supportsConvolutional: supportsConvolutionalUpscalers)
    }

    static var availableUpscalers: [MPVNeuralUpscaler] {
        MPVNeuralUpscaler.offeredUpscalers.filter { upscaler in
            switch upscaler {
            case .off:
                return true
            case .automatic:
                return shaderPath(for: .general) != nil
            case .anime, .animeLowBitrate, .general:
                return shaderPath(for: upscaler) != nil && supportsUpscaler(upscaler)
            }
        }
    }

    static func pickerUpscalers(including selection: MPVNeuralUpscaler) -> [MPVNeuralUpscaler] {
        var offered = availableUpscalers
        guard !offered.contains(selection) else { return offered }
        if let index = offered.firstIndex(of: .general) {
            offered.insert(selection, at: index)
        } else {
            offered.append(selection)
        }
        return offered
    }

    static var isAvailable: Bool {
        availableUpscalers.contains { $0 != .off }
    }
}
