import Foundation

struct MPVScalerSelection: Equatable {
    let scale: String
    let cscale: String
    let dscale: String
    let deband: String
    let qualityScaling: Bool
}

struct MPVUpscalingStatus: Equatable {
    let isActive: Bool
    let isThermallyLimited: Bool
    let summary: String
}

struct MPVNeuralUpscalerStatus: Equatable {
    let isEngaged: Bool
    let isConfirmedRunning: Bool
    let summary: String
}

enum MPVScalerPolicy {

    static func inlineScalers(
        mode: MPVUpscalingMode,
        neuralActive: Bool,
        isPad: Bool,
        isLowHeat: Bool,
        sourceHeight: Int
    ) -> MPVScalerSelection {
        let cheap = MPVScalerSelection(scale: "bilinear", cscale: "bilinear", dscale: "mitchell", deband: "no", qualityScaling: false)
        let quality = MPVScalerSelection(
            scale: "ewa_lanczossharp",
            cscale: "lanczos",
            dscale: "mitchell",
            deband: "yes",
            qualityScaling: true
        )
        let fourK = MPVScalerSelection(scale: "lanczos", cscale: "lanczos", dscale: "mitchell", deband: "yes", qualityScaling: true)

        if isLowHeat { return cheap }
        var resolved: MPVScalerSelection
        switch mode {
        case .off:
            resolved = cheap
        case .upscaleTo1080:
            resolved = (sourceHeight > 0 && sourceHeight < 1080) ? quality : cheap
        case .upscaleTo4K:
            resolved = (sourceHeight > 0 && sourceHeight < 2160) ? fourK : cheap
        case .oneLevelAlways, .auto:
            resolved = quality
        }
        guard neuralActive else { return resolved }

        var scale = resolved.scale == "bilinear" ? "lanczos" : resolved.scale
        var cscale = resolved.cscale == "bilinear" ? "lanczos" : resolved.cscale
        if isPad {
            if scale.hasPrefix("ewa_") { scale = "lanczos" }
            if cscale.hasPrefix("ewa_") { cscale = "lanczos" }
        }
        return MPVScalerSelection(scale: scale, cscale: cscale, dscale: resolved.dscale, deband: "yes", qualityScaling: true)
    }

    static func concreteUpscaler(
        selected: MPVNeuralUpscaler,
        isAnimation: Bool,
        supportsConvolutional: Bool
    ) -> MPVNeuralUpscaler {
        guard selected == .automatic else { return selected }
        guard isAnimation, supportsConvolutional else { return .general }
        return .anime
    }

    static func supportsSelection(_ upscaler: MPVNeuralUpscaler, supportsConvolutional: Bool) -> Bool {
        !upscaler.isConvolutional || supportsConvolutional
    }

    static func eligibleInlineNeuralUpscaler(
        selected: MPVNeuralUpscaler,
        mode: MPVUpscalingMode,
        isAnimation: Bool,
        supportsConvolutional: Bool,
        isLowHeat: Bool,
        isThermallyReduced: Bool,
        sourceHeight: Int
    ) -> MPVNeuralUpscaler {
        guard selected != .off, mode != .off, !isLowHeat, !isThermallyReduced, sourceHeight <= 1440 else { return .off }
        let concrete = concreteUpscaler(
            selected: selected,
            isAnimation: isAnimation,
            supportsConvolutional: supportsConvolutional
        )
        guard supportsSelection(concrete, supportsConvolutional: supportsConvolutional) else { return .off }
        return concrete
    }

    static func reachesActivationThreshold(_ upscaler: MPVNeuralUpscaler, outputScale: Double?) -> Bool {
        guard upscaler != .off else { return false }
        guard let outputScale else { return true }
        return outputScale > neuralActivationThreshold(for: upscaler)
    }

    static func inlineNeuralUpscaler(
        selected: MPVNeuralUpscaler,
        mode: MPVUpscalingMode,
        isAnimation: Bool,
        supportsConvolutional: Bool,
        isLowHeat: Bool,
        isThermallyReduced: Bool,
        sourceHeight: Int,
        outputScale: Double?
    ) -> MPVNeuralUpscaler {
        let eligible = eligibleInlineNeuralUpscaler(
            selected: selected,
            mode: mode,
            isAnimation: isAnimation,
            supportsConvolutional: supportsConvolutional,
            isLowHeat: isLowHeat,
            isThermallyReduced: isThermallyReduced,
            sourceHeight: sourceHeight
        )
        guard reachesActivationThreshold(eligible, outputScale: outputScale) else { return .off }
        return eligible
    }

    static func tvScalers(neuralActive: Bool, qualityChroma: Bool) -> MPVScalerSelection {
        MPVScalerSelection(
            scale: neuralActive ? "lanczos" : "bilinear",
            cscale: qualityChroma ? "lanczos" : "bilinear",
            dscale: "mitchell",
            deband: neuralActive ? "yes" : "no",
            qualityScaling: neuralActive
        )
    }

    static func tvNeuralUpscaler(
        selected: MPVNeuralUpscaler,
        isAnimation: Bool,
        supportsConvolutional: Bool,
        sourceHeight: Int,
        outputScale: Double?
    ) -> MPVNeuralUpscaler {
        guard selected != .off, sourceHeight <= 1440 else { return .off }
        let concrete = concreteUpscaler(
            selected: selected,
            isAnimation: isAnimation,
            supportsConvolutional: supportsConvolutional
        )
        guard supportsSelection(concrete, supportsConvolutional: supportsConvolutional) else { return .off }
        guard reachesActivationThreshold(concrete, outputScale: outputScale) else { return .off }
        return concrete
    }

    static func tvSupportsQualityChroma(memoryGB: Double) -> Bool {
        memoryGB >= 2.5
    }

    static func scalerStageName(_ scale: String) -> String {
        switch scale {
        case "ewa_lanczossharp": return "EWA Lanczos"
        case "ewa_lanczossoft": return "EWA Lanczos Soft"
        case "lanczos": return "Lanczos"
        case "bilinear": return "Bilinear"
        case "mitchell": return "Mitchell"
        default: return scale
        }
    }

    static func neuralStageName(_ upscaler: MPVNeuralUpscaler) -> String {
        switch upscaler {
        case .off: return "Off"
        case .automatic: return "Auto"
        case .anime: return "ArtCNN"
        case .animeLowBitrate: return "ArtCNN DS"
        case .general: return "FSR 1"
        }
    }

    static func status(
        mode: MPVUpscalingMode,
        scalers: MPVScalerSelection,
        isLowHeat: Bool,
        sourceHeight: Int
    ) -> MPVUpscalingStatus {
        guard scalers.qualityScaling else {
            if isLowHeat {
                return MPVUpscalingStatus(isActive: false, isThermallyLimited: true, summary: "Off · Low Heat")
            }
            if mode == .off {
                return MPVUpscalingStatus(isActive: false, isThermallyLimited: false, summary: "Off")
            }
            guard sourceHeight > 0 else {
                return MPVUpscalingStatus(isActive: false, isThermallyLimited: false, summary: "Off · source pending")
            }
            return MPVUpscalingStatus(isActive: false, isThermallyLimited: false, summary: "Off · \(sourceHeight)p source")
        }
        return MPVUpscalingStatus(
            isActive: true,
            isThermallyLimited: false,
            summary: scalerStageName(scalers.scale)
        )
    }

    static func neuralActivationThreshold(for upscaler: MPVNeuralUpscaler) -> Double {
        switch upscaler {
        case .automatic, .anime, .animeLowBitrate, .general:
            return 1.05
        case .off:
            return .infinity
        }
    }

    static func neuralStatus(
        selected: MPVNeuralUpscaler,
        resolved: MPVNeuralUpscaler,
        mode: MPVUpscalingMode,
        shaderLoaded: Bool,
        shaderListAccepted: Bool,
        executionConfirmed: Bool,
        isSupported: Bool,
        isLowHeat: Bool,
        isThermallyReduced: Bool,
        sourceHeight: Int,
        outputScale: Double?
    ) -> MPVNeuralUpscalerStatus? {
        guard selected != .off else { return nil }
        let name = neuralStageName(resolved == .off ? selected : resolved)

        guard mode != .off else {
            return MPVNeuralUpscalerStatus(isEngaged: false, isConfirmedRunning: false, summary: "\(name) · off, Upscaling off")
        }
        guard isSupported else {
            return MPVNeuralUpscalerStatus(isEngaged: false, isConfirmedRunning: false, summary: "\(name) · off, needs more memory")
        }
        guard !isLowHeat else {
            return MPVNeuralUpscalerStatus(isEngaged: false, isConfirmedRunning: false, summary: "\(name) · off, Low Heat")
        }
        guard !isThermallyReduced else {
            return MPVNeuralUpscalerStatus(isEngaged: false, isConfirmedRunning: false, summary: "\(name) · off, device warm")
        }
        guard sourceHeight <= 1440 else {
            return MPVNeuralUpscalerStatus(isEngaged: false, isConfirmedRunning: false, summary: "\(name) · off, \(sourceHeight)p source")
        }
        guard resolved != .off else {
            return MPVNeuralUpscalerStatus(isEngaged: false, isConfirmedRunning: false, summary: "\(name) · off")
        }
        guard shaderLoaded else {
            return MPVNeuralUpscalerStatus(isEngaged: false, isConfirmedRunning: false, summary: "\(name) · off, shader missing")
        }
        guard shaderListAccepted else {
            return MPVNeuralUpscalerStatus(isEngaged: false, isConfirmedRunning: false, summary: "\(name) · off, renderer rejected shader")
        }
        guard let outputScale else {
            return MPVNeuralUpscalerStatus(isEngaged: false, isConfirmedRunning: false, summary: "\(name) · configured, video pending")
        }
        let ratio = String(format: "%.2f", outputScale)
        guard outputScale > neuralActivationThreshold(for: resolved) else {
            return MPVNeuralUpscalerStatus(isEngaged: false, isConfirmedRunning: false, summary: "\(name) · idle, \(ratio)x output")
        }
        guard executionConfirmed else {
            return MPVNeuralUpscalerStatus(isEngaged: true, isConfirmedRunning: false, summary: "\(name) · on, \(ratio)x output")
        }
        return MPVNeuralUpscalerStatus(isEngaged: true, isConfirmedRunning: true, summary: "\(name) · running, \(ratio)x output")
    }
}
