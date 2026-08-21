//
//  circularLoading.swift
//  Kanzen
//
//  Created by Dawud Osman on 24/10/2025.
//

// circular progress bar
import SwiftUI

struct CircularLoader: View {
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            VStack{
                Text("LOADING...")
                Circle()
                    .trim(from: 0, to: 0.8)
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 50, height: 50)
                    .rotationEffect(.degrees(rotation))
                    .onAppear {
                        withAnimation(Animation.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                            rotation = 360
                        }
                    }
            }

        }
    }
}
