import XCTest
@testable import Eclipse

final class MPVScalerPolicyTests: XCTestCase {

    private func inline(
        mode: MPVUpscalingMode,
        neuralActive: Bool = false,
        isPad: Bool = false,
        isLowHeat: Bool = false,
        sourceHeight: Int = 1080
    ) -> MPVScalerSelection {
        MPVScalerPolicy.inlineScalers(
            mode: mode,
            neuralActive: neuralActive,
            isPad: isPad,
            isLowHeat: isLowHeat,
            sourceHeight: sourceHeight
        )
    }

    func testOffModeStaysOnCheapPath() {
        let s = inline(mode: .off)
        XCTAssertEqual(s, MPVScalerSelection(scale: "bilinear", cscale: "bilinear", dscale: "mitchell", deband: "no", qualityScaling: false))
    }

    func testLowHeatForcesCheapPathInEveryMode() {
        for mode in MPVUpscalingMode.allCases {
            let s = inline(mode: mode, isLowHeat: true, sourceHeight: 720)
            XCTAssertEqual(s.scale, "bilinear", "mode \(mode.rawValue)")
            XCTAssertEqual(s.deband, "no", "mode \(mode.rawValue)")
            XCTAssertFalse(s.qualityScaling, "mode \(mode.rawValue)")
        }
    }

    func testUpscaleTo1080AppliesQualityOnlyBelowHD() {
        let below = inline(mode: .upscaleTo1080, sourceHeight: 720)
        XCTAssertEqual(below.scale, "ewa_lanczossharp")
        XCTAssertEqual(below.cscale, "lanczos")
        XCTAssertTrue(below.qualityScaling)
        let at = inline(mode: .upscaleTo1080, sourceHeight: 1080)
        XCTAssertEqual(at.scale, "bilinear")
        XCTAssertFalse(at.qualityScaling)
        let unknown = inline(mode: .upscaleTo1080, sourceHeight: 0)
        XCTAssertEqual(unknown.scale, "bilinear")
    }

    func testUpscaleTo4KUsesQualityChroma() {
        let s = inline(mode: .upscaleTo4K, sourceHeight: 1080)
        XCTAssertEqual(s, MPVScalerSelection(scale: "lanczos", cscale: "lanczos", dscale: "mitchell", deband: "yes", qualityScaling: true))
        let uhd = inline(mode: .upscaleTo4K, sourceHeight: 2160)
        XCTAssertEqual(uhd.scale, "bilinear")
        XCTAssertFalse(uhd.qualityScaling)
    }

    func testQualityModesOnPadDemoteChromaToLanczos() {
        for mode in [MPVUpscalingMode.oneLevelAlways, .auto] {
            let s = inline(mode: mode, isPad: true)
            XCTAssertEqual(s.scale, "ewa_lanczossharp", "mode \(mode.rawValue)")
            XCTAssertEqual(s.cscale, "lanczos", "mode \(mode.rawValue)")
            XCTAssertTrue(s.qualityScaling, "mode \(mode.rawValue)")
        }
    }

    func testNeuralUpgradesTheCheapResamplerWhereverItRuns() {
        let s = inline(mode: .upscaleTo1080, neuralActive: true, sourceHeight: 1080)
        XCTAssertEqual(s, MPVScalerSelection(scale: "lanczos", cscale: "lanczos", dscale: "mitchell", deband: "yes", qualityScaling: true))
    }

    func testNeuralOnPadDemotesEWAScalers() {
        let s = inline(mode: .auto, neuralActive: true, isPad: true)
        XCTAssertEqual(s.scale, "lanczos")
        XCTAssertEqual(s.cscale, "lanczos")
    }

    func testNeuralOnPhoneKeepsEWAScalers() {
        let s = inline(mode: .auto, neuralActive: true)
        XCTAssertEqual(s.scale, "ewa_lanczossharp")
        XCTAssertEqual(s.cscale, "lanczos")
    }

    private func inlineNeural(
        selected: MPVNeuralUpscaler,
        mode: MPVUpscalingMode = .auto,
        isAnimation: Bool = false,
        supportsConvolutional: Bool = true,
        isLowHeat: Bool = false,
        isThermallyReduced: Bool = false,
        sourceHeight: Int = 1080,
        outputScale: Double? = 2.0
    ) -> MPVNeuralUpscaler {
        MPVScalerPolicy.inlineNeuralUpscaler(
            selected: selected,
            mode: mode,
            isAnimation: isAnimation,
            supportsConvolutional: supportsConvolutional,
            isLowHeat: isLowHeat,
            isThermallyReduced: isThermallyReduced,
            sourceHeight: sourceHeight,
            outputScale: outputScale
        )
    }

    func testInlineNeuralUpscalerGates() {
        XCTAssertEqual(inlineNeural(selected: .anime), .anime)
        XCTAssertEqual(inlineNeural(selected: .off, sourceHeight: 720), .off)
        XCTAssertEqual(inlineNeural(selected: .anime, supportsConvolutional: false, sourceHeight: 720), .off)
        XCTAssertEqual(inlineNeural(selected: .anime, isLowHeat: true, sourceHeight: 720), .off)
        XCTAssertEqual(inlineNeural(selected: .general, sourceHeight: 1440), .general)
        XCTAssertEqual(inlineNeural(selected: .general, sourceHeight: 1441), .off)
    }

    func testEnhancedUpscalingIsOffWhenUpscalingModeIsOff() {
        XCTAssertEqual(inlineNeural(selected: .anime, mode: .off), .off)
        XCTAssertEqual(inlineNeural(selected: .general, mode: .off), .off)
        XCTAssertEqual(inlineNeural(selected: .automatic, mode: .off, isAnimation: true), .off)
        for mode in MPVUpscalingMode.allCases where mode != .off {
            XCTAssertNotEqual(inlineNeural(selected: .general, mode: mode), .off, mode.rawValue)
        }
    }

    func testAutomaticPicksArtCNNForAnimationAndFSRForLiveAction() {
        XCTAssertEqual(inlineNeural(selected: .automatic, isAnimation: true), .anime)
        XCTAssertEqual(inlineNeural(selected: .automatic, isAnimation: false), .general)
        XCTAssertEqual(
            MPVScalerPolicy.tvNeuralUpscaler(selected: .automatic, isAnimation: true, supportsConvolutional: true, sourceHeight: 1080, outputScale: 2.0),
            .anime
        )
        XCTAssertEqual(
            MPVScalerPolicy.tvNeuralUpscaler(selected: .automatic, isAnimation: false, supportsConvolutional: true, sourceHeight: 1080, outputScale: 2.0),
            .general
        )
    }

    func testAutomaticFallsBackToFSRWhenTheDeviceCannotRunArtCNN() {
        XCTAssertEqual(inlineNeural(selected: .automatic, isAnimation: true, supportsConvolutional: false), .general)
        XCTAssertEqual(
            MPVScalerPolicy.tvNeuralUpscaler(selected: .automatic, isAnimation: true, supportsConvolutional: false, sourceHeight: 1080, outputScale: 2.0),
            .general
        )
    }

    func testAnExplicitChoiceIsNeverOverriddenByContentType() {
        XCTAssertEqual(inlineNeural(selected: .anime, isAnimation: false), .anime)
        XCTAssertEqual(inlineNeural(selected: .general, isAnimation: true), .general)
        XCTAssertEqual(inlineNeural(selected: .animeLowBitrate, isAnimation: false), .animeLowBitrate)
    }

    func testTVScalersUpgradeChromaOnCapableHardware() {
        let capable = MPVScalerPolicy.tvScalers(neuralActive: false, qualityChroma: true)
        XCTAssertEqual(capable, MPVScalerSelection(scale: "bilinear", cscale: "lanczos", dscale: "mitchell", deband: "no", qualityScaling: false))
        let constrained = MPVScalerPolicy.tvScalers(neuralActive: false, qualityChroma: false)
        XCTAssertEqual(constrained.cscale, "bilinear")
        let neural = MPVScalerPolicy.tvScalers(neuralActive: true, qualityChroma: true)
        XCTAssertEqual(neural, MPVScalerSelection(scale: "lanczos", cscale: "lanczos", dscale: "mitchell", deband: "yes", qualityScaling: true))
    }

    func testTVQualityChromaMemoryBoundary() {
        XCTAssertTrue(MPVScalerPolicy.tvSupportsQualityChroma(memoryGB: 2.5))
        XCTAssertTrue(MPVScalerPolicy.tvSupportsQualityChroma(memoryGB: 3.0))
        XCTAssertFalse(MPVScalerPolicy.tvSupportsQualityChroma(memoryGB: 2.0))
    }

    func testTVNeuralUpscalerGates() {
        XCTAssertEqual(
            MPVScalerPolicy.tvNeuralUpscaler(selected: .anime, isAnimation: true, supportsConvolutional: true, sourceHeight: 1080, outputScale: 2.0),
            .anime
        )
        XCTAssertEqual(
            MPVScalerPolicy.tvNeuralUpscaler(selected: .anime, isAnimation: true, supportsConvolutional: true, sourceHeight: 2160, outputScale: 2.0),
            .off
        )
        XCTAssertEqual(
            MPVScalerPolicy.tvNeuralUpscaler(selected: .anime, isAnimation: true, supportsConvolutional: false, sourceHeight: 1080, outputScale: 2.0),
            .off
        )
    }

    private func neural(
        selected: MPVNeuralUpscaler,
        resolved: MPVNeuralUpscaler? = nil,
        mode: MPVUpscalingMode = .auto,
        shaderLoaded: Bool = true,
        shaderListAccepted: Bool = true,
        executionConfirmed: Bool = false,
        isSupported: Bool = true,
        isLowHeat: Bool = false,
        isThermallyReduced: Bool = false,
        sourceHeight: Int = 720,
        outputScale: Double? = 2.0
    ) -> MPVNeuralUpscalerStatus? {
        MPVScalerPolicy.neuralStatus(
            selected: selected,
            resolved: resolved ?? selected,
            mode: mode,
            shaderLoaded: shaderLoaded,
            shaderListAccepted: shaderListAccepted,
            executionConfirmed: executionConfirmed,
            isSupported: isSupported,
            isLowHeat: isLowHeat,
            isThermallyReduced: isThermallyReduced,
            sourceHeight: sourceHeight,
            outputScale: outputScale
        )
    }

    func testStatusNamesTheActiveScaler() {
        let status = MPVScalerPolicy.status(
            mode: .auto,
            scalers: inline(mode: .auto),
            isLowHeat: false,
            sourceHeight: 1080
        )
        XCTAssertTrue(status.isActive)
        XCTAssertFalse(status.isThermallyLimited)
        XCTAssertEqual(status.summary, "EWA Lanczos")
    }

    func testStatusBlamesLowHeatBeforeAnythingElse() {
        let status = MPVScalerPolicy.status(
            mode: .auto,
            scalers: inline(mode: .auto, isLowHeat: true, sourceHeight: 720),
            isLowHeat: true,
            sourceHeight: 720
        )
        XCTAssertFalse(status.isActive)
        XCTAssertTrue(status.isThermallyLimited)
        XCTAssertEqual(status.summary, "Off · Low Heat")
    }

    func testStatusBlamesSourceHeightWhenModeCannotUpscaleIt() {
        let status = MPVScalerPolicy.status(
            mode: .upscaleTo1080,
            scalers: inline(mode: .upscaleTo1080, sourceHeight: 1080),
            isLowHeat: false,
            sourceHeight: 1080
        )
        XCTAssertFalse(status.isActive)
        XCTAssertFalse(status.isThermallyLimited)
        XCTAssertEqual(status.summary, "Off · 1080p source")
    }

    func testStatusDistinguishesDisabledFromPendingSource() {
        let disabled = MPVScalerPolicy.status(
            mode: .off,
            scalers: inline(mode: .off),
            isLowHeat: false,
            sourceHeight: 1080
        )
        XCTAssertEqual(disabled.summary, "Off")
        let pending = MPVScalerPolicy.status(
            mode: .upscaleTo1080,
            scalers: inline(mode: .upscaleTo1080, sourceHeight: 0),
            isLowHeat: false,
            sourceHeight: 0
        )
        XCTAssertEqual(pending.summary, "Off · source pending")
    }

    func testNeuralStatusIsAbsentWhenNothingIsSelected() {
        XCTAssertNil(neural(selected: .off))
    }

    func testNeuralStatusDoesNotClaimExecutionFromEligibilityAlone() {
        let status = neural(selected: .anime, outputScale: 1.8)
        XCTAssertEqual(status?.isEngaged, true)
        XCTAssertEqual(status?.isConfirmedRunning, false)
        XCTAssertEqual(status?.summary, "ArtCNN · on, 1.80x output")
    }

    func testNeuralStatusReportsUpscalingModeOffBeforeAnythingElse() {
        let status = neural(selected: .anime, resolved: .off, mode: .off)
        XCTAssertEqual(status?.isEngaged, false)
        XCTAssertEqual(status?.summary, "ArtCNN · off, Upscaling off")
    }

    func testNeuralStatusNamesTheUpscalerAutomaticResolvedTo() {
        let status = neural(selected: .automatic, resolved: .general, outputScale: 1.8)
        XCTAssertEqual(status?.summary, "FSR 1 · on, 1.80x output")
        let idle = neural(selected: .automatic, resolved: .off, mode: .off)
        XCTAssertEqual(idle?.summary, "Auto · off, Upscaling off")
    }

    func testNeuralStatusReportsRunningOnlyWithPassConfirmation() {
        let status = neural(selected: .anime, executionConfirmed: true, outputScale: 1.8)
        XCTAssertEqual(status?.isConfirmedRunning, true)
        XCTAssertEqual(status?.summary, "ArtCNN · running, 1.80x output")
    }

    func testNeuralStatusReportsIdleAtTheShaderActivationThreshold() {
        let threshold = MPVScalerPolicy.neuralActivationThreshold(for: .anime)
        let below = neural(selected: .anime, outputScale: threshold)
        XCTAssertEqual(below?.isConfirmedRunning, false)
        XCTAssertEqual(below?.summary, "ArtCNN · idle, 1.05x output")
        let above = neural(selected: .anime, outputScale: 1.06)
        XCTAssertEqual(above?.isConfirmedRunning, false)
        XCTAssertEqual(above?.summary, "ArtCNN · on, 1.06x output")
    }

    func testFSR1AllowsModestPhoneEnlargement() {
        XCTAssertEqual(MPVScalerPolicy.neuralActivationThreshold(for: .general), 1.05)
        XCTAssertEqual(neural(selected: .general, outputScale: 1.05)?.summary, "FSR 1 · idle, 1.05x output")
        XCTAssertEqual(neural(selected: .general, outputScale: 1.06)?.summary, "FSR 1 · on, 1.06x output")
    }

    func testNeuralStatusBlamesUnsupportedHardware() {
        let status = neural(selected: .anime, resolved: .off, isSupported: false)
        XCTAssertEqual(status?.isConfirmedRunning, false)
        XCTAssertEqual(status?.summary, "ArtCNN · off, needs more memory")
    }

    func testNeuralStatusBlamesLowHeat() {
        let status = neural(selected: .animeLowBitrate, resolved: .off, isLowHeat: true)
        XCTAssertEqual(status?.isConfirmedRunning, false)
        XCTAssertEqual(status?.summary, "ArtCNN DS · off, Low Heat")
    }

    func testNeuralStatusBlamesSourceAboveTheGate() {
        let status = neural(selected: .anime, resolved: .off, sourceHeight: 2160)
        XCTAssertEqual(status?.isConfirmedRunning, false)
        XCTAssertEqual(status?.summary, "ArtCNN · off, 2160p source")
    }

    func testNeuralStatusBlamesMissingShader() {
        let status = neural(selected: .general, shaderLoaded: false)
        XCTAssertEqual(status?.isConfirmedRunning, false)
        XCTAssertEqual(status?.summary, "FSR 1 · off, shader missing")
    }

    func testNeuralStatusReportsRendererRejection() {
        let status = neural(selected: .general, shaderListAccepted: false)
        XCTAssertEqual(status?.isConfirmedRunning, false)
        XCTAssertEqual(status?.summary, "FSR 1 · off, renderer rejected shader")
    }

    func testNeuralStatusDoesNotClaimRunningBeforeVideoDimensionsExist() {
        let status = neural(selected: .general, outputScale: nil)
        XCTAssertEqual(status?.isConfirmedRunning, false)
        XCTAssertEqual(status?.summary, "FSR 1 · configured, video pending")
    }

    func testNeuralStatusMatchesTheBundledShaderActivationThreshold() throws {
        for upscaler in [MPVNeuralUpscaler.anime, .animeLowBitrate, .general] {
            let path = try XCTUnwrap(MPVUserShaderLibrary.shaderPath(for: upscaler), upscaler.rawValue)
            let contents = try String(contentsOfFile: path, encoding: .utf8)
            let threshold = String(format: "%g", MPVScalerPolicy.neuralActivationThreshold(for: upscaler))
            for line in contents.components(separatedBy: .newlines) where line.hasPrefix("//!WHEN") {
                XCTAssertTrue(line.contains(threshold), "\(upscaler.rawValue): \(line)")
            }
        }
    }

    func testNoisyAnimeUsesDenoiseAndSharpenModel() throws {
        let path = try XCTUnwrap(MPVUserShaderLibrary.shaderPath(for: .animeLowBitrate))
        XCTAssertEqual((path as NSString).lastPathComponent, "ArtCNN_C4F16_DS.glsl")
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(contents.contains("//!DESC ArtCNN C4F16 DS"))
        XCTAssertFalse(contents.contains("//!DESC ArtCNN C4F16 DN"))
    }

    func testBundledArtCNNShadersUseRelaxedActivationThreshold() throws {
        for upscaler in [MPVNeuralUpscaler.anime, .animeLowBitrate] {
            let path = try XCTUnwrap(MPVUserShaderLibrary.shaderPath(for: upscaler), upscaler.rawValue)
            let contents = try String(contentsOfFile: path, encoding: .utf8)
            let whenLines = contents
                .components(separatedBy: .newlines)
                .filter { $0.hasPrefix("//!WHEN") }
            XCTAssertFalse(whenLines.isEmpty, upscaler.rawValue)
            for line in whenLines {
                XCTAssertTrue(line.contains("1.05"), "\(upscaler.rawValue): \(line)")
                XCTAssertFalse(line.contains("1.3"), "\(upscaler.rawValue): \(line)")
            }
        }
    }

    func testBundledFSR1ShaderUsesFixedAppPolicy() throws {
        let path = try XCTUnwrap(MPVUserShaderLibrary.shaderPath(for: .general))
        XCTAssertEqual((path as NSString).lastPathComponent, "AMD_FSR1_EASU_RCAS.glsl")
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        let whenLines = contents
            .components(separatedBy: .newlines)
            .filter { $0.hasPrefix("//!WHEN") }
        XCTAssertFalse(whenLines.isEmpty)
        for line in whenLines {
            XCTAssertTrue(line.contains("1.05"), line)
            XCTAssertFalse(line.contains("1.300"), line)
        }
        XCTAssertTrue(contents.contains("Copyright (c) 2021 Advanced Micro Devices"))
        XCTAssertTrue(contents.contains("adapted to mpv GLSL from mpv_PlayKit"))
        XCTAssertTrue(contents.contains("//!HOOK MAIN"))
        XCTAssertTrue(contents.contains("EASU (Edge-Adaptive Spatial Upsampling)"))
        XCTAssertTrue(contents.contains("RCAS (Robust Contrast-Adaptive Sharpening)"))
        XCTAssertTrue(contents.contains("#define SHARP           0.2"))
        XCTAssertTrue(contents.contains("#define NDS             1"))
        XCTAssertFalse(contents.contains("//!PARAM"))
        XCTAssertFalse(contents.contains("fsr_sharpness"))
        XCTAssertFalse(contents.contains("fsr_pq"))
    }

    func testTheAdaptiveSharpenShaderIsNoLongerBundled() {
        XCTAssertNil(Bundle(for: type(of: self)).path(forResource: "EclipseCAS", ofType: "glsl", inDirectory: "Shaders"))
    }

    func testThermalReductionDisablesTheNeuralUpscalerOutright() {
        XCTAssertEqual(inlineNeural(selected: .anime, isThermallyReduced: true), .off)
        XCTAssertEqual(inlineNeural(selected: .general, isThermallyReduced: true, outputScale: 4.0), .off)
        XCTAssertEqual(inlineNeural(selected: .anime, isThermallyReduced: false), .anime)
        for mode in MPVUpscalingMode.allCases {
            XCTAssertEqual(inlineNeural(selected: .anime, mode: mode, isThermallyReduced: true), .off, mode.rawValue)
        }
    }

    func testThermalReductionLeavesTheScalerSelectionAlone() {
        for mode in MPVUpscalingMode.allCases {
            XCTAssertEqual(inline(mode: mode), inline(mode: mode), mode.rawValue)
        }
        let quality = inline(mode: .oneLevelAlways)
        XCTAssertEqual(quality.scale, "ewa_lanczossharp")
        XCTAssertEqual(quality.deband, "yes")
    }

    func testNeuralStatusBlamesAWarmDeviceBeforeSourceHeight() {
        let status = neural(selected: .anime, resolved: .off, isThermallyReduced: true, sourceHeight: 2160)
        XCTAssertEqual(status?.isEngaged, false)
        XCTAssertEqual(status?.isConfirmedRunning, false)
        XCTAssertEqual(status?.summary, "ArtCNN · off, device warm")
    }

    func testLowHeatOutranksAWarmDeviceInTheStatusString() {
        let status = neural(selected: .anime, resolved: .off, isLowHeat: true, isThermallyReduced: true)
        XCTAssertEqual(status?.summary, "ArtCNN · off, Low Heat")
    }

    func testInlineNeuralUpscalerStaysOffBelowTheShaderActivationThreshold() {
        XCTAssertEqual(inlineNeural(selected: .anime, outputScale: 1.0833), .anime)
        XCTAssertEqual(inlineNeural(selected: .anime, outputScale: 0.888), .off)
        XCTAssertEqual(inlineNeural(selected: .anime, outputScale: 1.05), .off)
        XCTAssertEqual(inlineNeural(selected: .anime, outputScale: 0.6094), .off)
    }

    func testInlineNeuralUpscalerStaysSelectedWhileTheOutputSizeIsUnknown() {
        XCTAssertEqual(inlineNeural(selected: .anime, outputScale: nil), .anime)
        XCTAssertEqual(inlineNeural(selected: .automatic, isAnimation: true, outputScale: nil), .anime)
    }

    func testTVNeuralUpscalerRespectsTheShaderActivationThreshold() {
        XCTAssertEqual(
            MPVScalerPolicy.tvNeuralUpscaler(selected: .anime, isAnimation: true, supportsConvolutional: true, sourceHeight: 1080, outputScale: 1.0),
            .off
        )
        XCTAssertEqual(
            MPVScalerPolicy.tvNeuralUpscaler(selected: .anime, isAnimation: true, supportsConvolutional: true, sourceHeight: 1080, outputScale: nil),
            .anime
        )
    }







#if os(iOS)
    func testOnlyAnAutomaticReductionCountsAsThermallyReduced() {
        XCTAssertFalse(MPVMetalSampleBufferQualityProfile.balanced(reason: "manual").isThermallyReduced)
        XCTAssertTrue(MPVMetalSampleBufferQualityProfile.balanced(reason: "auto", isAutomatic: true).isThermallyReduced)
        XCTAssertFalse(MPVMetalSampleBufferQualityProfile.sharp(reason: "auto", isAutomatic: true).isThermallyReduced)
        XCTAssertFalse(
            MPVMetalSampleBufferQualityProfile.balanced(reason: "manual")
                .hasSameRenderSettings(as: .balanced(reason: "auto", isAutomatic: true))
        )
    }
#endif

    func testAutomaticIsOfferedAndTheDenoiseVariantIsNot() {
        let offered = MPVNeuralUpscaler.offeredUpscalers
        XCTAssertEqual(offered, [.off, .automatic, .anime, .general])
        XCTAssertFalse(offered.contains(.animeLowBitrate))
        XCTAssertTrue(MPVUserShaderLibrary.pickerUpscalers(including: .animeLowBitrate).contains(.animeLowBitrate))
        XCTAssertFalse(MPVUserShaderLibrary.pickerUpscalers(including: .general).contains(.animeLowBitrate))
    }
}
