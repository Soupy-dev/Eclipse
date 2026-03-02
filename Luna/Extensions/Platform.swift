//
//  Platform.swift
//  Luna
//
//  Created by Dominic on 02.11.25.
//

import SwiftUI

// MARK: - iPad Scaling Utilities

/// Returns `true` when running on an iPad (or Mac Catalyst with iPad idiom).
var isIPad: Bool {
    #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
    #else
        false
    #endif
}

/// A multiplier used to proportionally scale hard-coded dimensions on iPad.
/// iPhone ≈ 1.0, iPad ≈ 1.45.
var iPadScale: CGFloat {
    isIPad ? 1.45 : 1.0
}

/// A smaller multiplier for elements that should grow on iPad but not as
/// aggressively (e.g. episode thumbnails, spacing).
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
