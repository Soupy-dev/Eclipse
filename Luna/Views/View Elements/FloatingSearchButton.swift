//
//  FloatingSettingsButton.swift
//  Luna
//
//  Created on 27/02/26.
//

import SwiftUI

struct FloatingSettingsButton: View {
    @Binding var isPresented: Bool
    
    var body: some View {
        Button(action: {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                isPresented = true
            }
        }) {
            Image(systemName: "gear")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .applyLiquidGlassBackground(cornerRadius: 22)
        }
        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
    }
}

struct FloatingSettingsOverlay: View {
    @Binding var showingSettings: Bool
    
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
                .allowsHitTesting(false)
            
            FloatingSettingsButton(isPresented: $showingSettings)
                .padding(.trailing, 16)
                .padding(.top, 8)
        }
    }
}
