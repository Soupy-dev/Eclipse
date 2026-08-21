//
//  AccentColorManager.swift
//  Sora
//
//  Created by Francesco on 20/08/25.
//

import SwiftUI

class AccentColorManager: ObservableObject {
    static let shared = AccentColorManager()

    static let defaultAccentColor = Color(red: 0.25, green: 0.12, blue: 0.45)

    @Published var currentAccentColor: Color = AccentColorManager.defaultAccentColor

    private init() {
        loadAccentColor()
    }

    func saveAccentColor(_ color: Color) {
        currentAccentColor = color

        do {
            let colorData = try NSKeyedArchiver.archivedData(withRootObject: UIColor(color), requiringSecureCoding: true)
            ProfileSettingsStore.active.set(colorData, forKey: "accentColor")
        } catch {
            Logger.shared.log("Failed to save accent color", type: "Error")
        }
    }

    func reloadForActiveProfile() {
        loadAccentColor()
    }

    private func loadAccentColor() {
        guard let colorData = ProfileSettingsStore.active.data(forKey: "accentColor"), !colorData.isEmpty else {
            currentAccentColor = Self.defaultAccentColor
            return
        }

        do {
            if let uiColor = try NSKeyedUnarchiver.unarchivedObject(ofClass: UIColor.self, from: colorData) {
                currentAccentColor = Color(uiColor)
            }
        } catch {
            currentAccentColor = Self.defaultAccentColor
        }
    }
}
