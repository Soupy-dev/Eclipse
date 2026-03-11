//
//  HeroTransition.swift
//  Luna
//
//  matchedGeometryEffect helpers for card-to-detail hero transitions
//

import SwiftUI

// MARK: - Namespace Environment Key

private struct HeroNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var heroNamespace: Namespace.ID? {
        get { self[HeroNamespaceKey.self] }
        set { self[HeroNamespaceKey.self] = newValue }
    }
}

extension View {
    func heroNamespace(_ namespace: Namespace.ID) -> some View {
        self.environment(\.heroNamespace, namespace)
    }
}

// MARK: - Hero Source & Destination Modifiers

extension View {
    /// Apply to the source card's poster image
    @ViewBuilder
    func heroSource(id: String, namespace: Namespace.ID?) -> some View {
        if #available(iOS 18.0, tvOS 18.0, *), let ns = namespace {
            self.matchedTransitionSource(id: id, in: ns)
        } else {
            self
        }
    }
    
    /// Apply to the destination detail view
    @ViewBuilder
    func heroDestination(id: String, namespace: Namespace.ID?) -> some View {
        if #available(iOS 18.0, tvOS 18.0, *), let ns = namespace {
            self.navigationTransition(.zoom(sourceID: id, in: ns))
        } else {
            self
        }
    }
}
