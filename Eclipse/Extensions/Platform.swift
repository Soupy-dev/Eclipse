//
//  Platform.swift
//  Eclipse
//
//  Created by Dominic on 02.11.25.
//

import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

extension Notification.Name {
    static let playerDidClose = Notification.Name("playerDidClose")
    static let playerInterfaceCoverageDidChange = Notification.Name("playerInterfaceCoverageDidChange")
    static let homeInitialHydrationDidComplete = Notification.Name("homeInitialHydrationDidComplete")
    static let progressDataDidChange = Notification.Name("progressDataDidChange")
    static let eclipseScenePhaseDidChange = Notification.Name("eclipseScenePhaseDidChange")
}

enum PlayerInterfaceCoverageNotification {
    static let coveredKey = "covered"
    static let playerIdentifierKey = "playerIdentifier"
    static let sceneSessionIdentifierKey = "sceneSessionIdentifier"

    static func userInfo(
        covered: Bool,
        playerIdentifier: String,
        sceneSessionIdentifier: String?
    ) -> [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [
            coveredKey: covered,
            playerIdentifierKey: playerIdentifier
        ]
        if let sceneSessionIdentifier {
            userInfo[sceneSessionIdentifierKey] = sceneSessionIdentifier
        }
        return userInfo
    }
}

struct PlayerInterfaceCoverageState {
    private static let unscopedSceneKey = "__eclipse_unscoped_scene__"
    private var playerIdentifiersByScene: [String: Set<String>] = [:]

    mutating func consume(_ notification: Notification) {
        guard let covered = notification.userInfo?[PlayerInterfaceCoverageNotification.coveredKey] as? Bool else {
            return
        }

        let playerIdentifier: String
        if let explicitIdentifier = notification.userInfo?[PlayerInterfaceCoverageNotification.playerIdentifierKey] as? String {
            playerIdentifier = explicitIdentifier
        } else if let object = notification.object {
            playerIdentifier = "legacy-\(ObjectIdentifier(object as AnyObject).hashValue)"
        } else {
            playerIdentifier = "legacy-player"
        }

        for key in Array(playerIdentifiersByScene.keys) {
            playerIdentifiersByScene[key]?.remove(playerIdentifier)
            if playerIdentifiersByScene[key]?.isEmpty == true {
                playerIdentifiersByScene[key] = nil
            }
        }

        guard covered else { return }
        let sceneIdentifier = notification.userInfo?[PlayerInterfaceCoverageNotification.sceneSessionIdentifierKey] as? String
        playerIdentifiersByScene[sceneIdentifier ?? Self.unscopedSceneKey, default: []].insert(playerIdentifier)
    }

    func isCovered(in sceneSessionIdentifier: String?) -> Bool {
        if let sceneSessionIdentifier {
            return playerIdentifiersByScene[sceneSessionIdentifier]?.isEmpty == false
                || playerIdentifiersByScene[Self.unscopedSceneKey]?.isEmpty == false
        }

        return playerIdentifiersByScene.values.contains { !$0.isEmpty }
    }
}

private struct EclipseWindowSceneSessionIdentifierKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var eclipseWindowSceneSessionIdentifier: String? {
        get { self[EclipseWindowSceneSessionIdentifierKey.self] }
        set { self[EclipseWindowSceneSessionIdentifierKey.self] = newValue }
    }
}

#if os(iOS)

struct EclipseWindowSceneScopeModifier: ViewModifier {
    @State private var sceneSessionIdentifier: String?

    func body(content: Content) -> some View {
        content
            .environment(\.eclipseWindowSceneSessionIdentifier, sceneSessionIdentifier)
            .background {
                EclipseWindowSceneSessionReader { identifier in
                    if sceneSessionIdentifier != identifier {
                        sceneSessionIdentifier = identifier
                    }
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

private struct EclipseWindowSceneSessionReader: UIViewRepresentable {
    let onChange: (String?) -> Void

    func makeUIView(context: Context) -> EclipseWindowSceneSessionProbeView {
        EclipseWindowSceneSessionProbeView(onChange: onChange)
    }

    func updateUIView(_ uiView: EclipseWindowSceneSessionProbeView, context: Context) {
        uiView.onChange = onChange
        uiView.reportSceneIfNeeded()
    }
}

private final class EclipseWindowSceneSessionProbeView: UIView {
    var onChange: (String?) -> Void
    private var lastReportedIdentifier: String?

    init(onChange: @escaping (String?) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportSceneIfNeeded()
    }

    func reportSceneIfNeeded() {
        let identifier = window?.windowScene?.session.persistentIdentifier
        guard identifier != lastReportedIdentifier else { return }
        lastReportedIdentifier = identifier
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lastReportedIdentifier == identifier else { return }
            self.onChange(identifier)
        }
    }
}
#endif

var isIPad: Bool {
    #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
    #else
        false
    #endif
}

var iPadScale: CGFloat {
    isIPad ? 1.45 : 1.0
}

var iPadScaleSmall: CGFloat {
    isIPad ? 1.25 : 1.0
}

extension View {
    @ViewBuilder
    func tvos<Content: View, ElseContent: View>(
        _ transform: (Self) -> Content,
        else elseTransform: (Self) -> ElseContent
    ) -> some View {
        #if os(tvOS)
            transform(self)
        #else
            elseTransform(self)
        #endif
    }

    @ViewBuilder
    func tvos<Content: View>(
        _ transform: (Self) -> Content
    ) -> some View {
        #if os(tvOS)
            transform(self)
        #endif
    }

    var isTvOS: Bool {
        #if os(tvOS)
            true
        #else
            false
        #endif
    }

    func onChangeComp<V: Equatable>(
        of value: V,
        perform action: @escaping (V?, V) -> Void
    ) -> some View {
        if #available(tvOS 17.0, iOS 17.0, macOS 14.0, *) {
            return self.onChange(of: value) { oldValue, newValue in
                action(oldValue, newValue)
            }
        } else {
            return self.onChange(of: value) { newValue in
                action(nil, newValue)
            }
        }
    }
}
