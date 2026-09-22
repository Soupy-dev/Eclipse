import AppKit
import XCTest
@testable import EclipseMac

final class MacPlayerKeyboardPolicyTests: XCTestCase {
    func testInlinePlayerReceivesPlaybackKeys() {
        XCTAssertEqual(action(49), .togglePlayback)
        XCTAssertEqual(action(123), .seekBackward)
        XCTAssertEqual(action(124), .seekForward)
        XCTAssertEqual(action(125), .volumeDown)
        XCTAssertEqual(action(126), .volumeUp)
        XCTAssertEqual(action(53), .escape)
        XCTAssertNil(action(48))
    }

    func testPictureInPictureOtherWindowsSheetsAndEditorsKeepTheirKeys() {
        for key: UInt16 in [49, 53, 123, 124, 125, 126] {
            XCTAssertNil(action(key, inline: false))
            XCTAssertNil(action(key, focused: false))
            XCTAssertNil(action(key, keyWindow: false))
            XCTAssertNil(action(key, sheet: true))
            XCTAssertNil(action(key, editing: true))
            XCTAssertNil(action(key, modified: true))
        }
    }

    func testFocusedSliderOwnsArrowsAndSpaceDoesNotToggleRepeatedly() {
        for key: UInt16 in [123, 124, 125, 126] { XCTAssertNil(action(key, slider: true)) }
        XCTAssertEqual(action(49, slider: true), .togglePlayback)
        XCTAssertNil(action(49, repeating: true))
        XCTAssertNil(action(53, repeating: true))
        XCTAssertEqual(action(124, repeating: true), .seekForward)
    }

    @MainActor
    func testNativeFocusPersistsUntilUserMovesItAndReleasesForPictureInPicture() async throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: window.contentRect(forFrameRect: window.frame))
        let capture = MacPlayerKeyboardCaptureView(frame: CGRect(x: 120, y: 0, width: 520, height: 360))
        let sidebar = NSSlider(frame: CGRect(x: 0, y: 0, width: 120, height: 30))
        var enabled = true
        capture.isEnabled = { enabled }
        root.addSubview(capture)
        root.addSubview(sidebar)
        window.contentView = root
        defer { capture.stop(); window.contentView = nil; window.close() }
        guard NSApp.isActive else {
            throw XCTSkip("The XCTest unit host is in the background and cannot acquire an active key window. Native focus ownership requires the UI runner; pure playback-key policies still execute.")
        }
        window.makeKeyAndOrderFront(nil)
        let keyWindowDeadline = Date().addingTimeInterval(2)
        while !window.isKeyWindow, Date() < keyWindowDeadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard window.isKeyWindow else {
            throw XCTSkip("The XCTest unit host did not obtain its fixture key window. Native focus ownership remains pending a foreground UI runner.")
        }
        capture.updateFocusRequest(1)
        try await waitForFocus(capture, in: window, phase: "initial presentation")
        XCTAssertEqual(capture.accessibilityLabel(), "Video playback")
        XCTAssertEqual(capture.accessibilityRole(), .group)
        XCTAssertTrue(capture.isAccessibilityElement())
        XCTAssertTrue(capture.isAccessibilityFocused())
        XCTAssertNil(capture.hitTest(CGPoint(x: 200, y: 100)))
        capture.updateFocusRequest(1)
        root.needsLayout = true
        root.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.firstResponder === capture)
        XCTAssertTrue(window.makeFirstResponder(sidebar))
        capture.updateFocusRequest(1)
        await Task.yield()
        XCTAssertTrue(window.firstResponder === sidebar)
        capture.updateFocusRequest(2)
        try await waitForFocus(capture, in: window, phase: "explicit return from sidebar")
        enabled = false
        capture.updateFocusRequest(3)
        XCTAssertFalse(window.firstResponder === capture)
        XCTAssertFalse(capture.isAccessibilityFocused())
        XCTAssertFalse(capture.isAccessibilityElement())
        enabled = true
        capture.updateFocusRequest(4)
        try await waitForFocus(capture, in: window, phase: "return from Picture in Picture")
    }

    @MainActor
    private func waitForFocus(_ responder: NSResponder, in window: NSWindow, phase: String) async throws {
        let deadline = Date().addingTimeInterval(2)
        while window.firstResponder !== responder, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let actual = window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
        XCTAssertTrue(window.firstResponder === responder,
            "Focus phase=\(phase) window=\(window.windowNumber) key=\(window.isKeyWindow) visible=\(window.isVisible) active=\(NSApp.isActive) appKeyWindow=\(NSApp.keyWindow?.windowNumber ?? 0) responder=\(actual) accepts=\(responder.acceptsFirstResponder)")
    }

    private func action(_ code: UInt16, inline: Bool = true, focused: Bool = true, keyWindow: Bool = true,
                        sheet: Bool = false, editing: Bool = false, slider: Bool = false,
                        modified: Bool = false, repeating: Bool = false) -> MacPlayerKeyAction? {
        MacPlayerKeyboardPolicy.action(keyCode: code, isRepeat: repeating, hasShortcutModifiers: modified,
            inlinePlayerIsCurrent: inline, playerHasFocus: focused, eventTargetsKeyWindow: keyWindow,
            hasChildSheet: sheet, isEditingText: editing, sliderIsFocused: slider)
    }
}

final class MacIntelPlayerSettingsTests: XCTestCase {
    func testIntelSearchKeepsAVPlayerPictureInPictureAndHidesUnsupportedMPVControls() {
        let compatibility = IntelMacCompatibilityPolicy(platform: .macOS, isX86_64: true)
        let excluded: [PlayerSettingsSearchTarget] = [.moltenVKQuality, .upscaling, .neuralUpscaling, .hdrOutput, .dolbyAtmos]
        for target in excluded {
            for engine in PlaybackEngine.allCases {
                XCTAssertFalse(target.isAvailable(compatibility: compatibility, playbackEngine: engine))
            }
        }
        XCTAssertFalse(PlayerSettingsSearchTarget.pictureInPicture.isAvailable(compatibility: compatibility, playbackEngine: .mpv))
        XCTAssertTrue(PlayerSettingsSearchTarget.pictureInPicture.isAvailable(compatibility: compatibility, playbackEngine: .avPlayer))
        XCTAssertTrue(PlayerSettingsSearchTarget.pictureInPicture.isAvailable(compatibility: compatibility, playbackEngine: .automatic))
        let retained: [PlayerSettingsSearchTarget] = [.dolbyVision, .performanceOverlay, .surroundSound, .comfortAudio, .streamWarmupCache, .nextEpisodeStaging, .subtitleDefaults, .subtitleAppearance]
        for target in retained {
            XCTAssertTrue(target.isAvailable(compatibility: compatibility, playbackEngine: .mpv))
        }
    }

    func testIntelSearchRestrictionsDoNotApplyToOtherPlatformsOrArchitectures() {
        let targets: [PlayerSettingsSearchTarget] = [.moltenVKQuality, .upscaling, .neuralUpscaling, .hdrOutput, .dolbyAtmos, .pictureInPicture]
        let platforms: [EclipsePlatform] = [.iOS, .tvOS, .visionOS, .macOS]
        for platform in platforms {
            for isX86_64 in [false, true] where platform != .macOS || !isX86_64 {
                let compatibility = IntelMacCompatibilityPolicy(platform: platform, isX86_64: isX86_64)
                for target in targets {
                    XCTAssertTrue(target.isAvailable(compatibility: compatibility, playbackEngine: .mpv))
                }
            }
        }
    }
}
