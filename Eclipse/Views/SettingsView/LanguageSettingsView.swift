import SwiftUI

enum AppLanguageOption: String, CaseIterable, Identifiable {
    case en
    case es

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .en: return "English (US)"
        case .es: return "Español"
        }
    }

    var tmdbLanguageCode: String {
        switch self {
        case .en: return "en-US"
        case .es: return "es-MX"
        }
    }

    static func from(tmdbLanguageCode: String) -> AppLanguageOption {
        tmdbLanguageCode.hasPrefix("es") ? .es : .en
    }

    static var current: AppLanguageOption {
        let stored = ProfileSettingsStore.active.string(forKey: LocalizationManager.tmdbLanguageKey)
            ?? LocalizationManager.defaultTMDBCode
        return from(tmdbLanguageCode: stored)
    }
}

struct LanguageSettingsView: View {
    @AppStorage(LocalizationManager.tmdbLanguageKey, store: ProfileSettingsStore.active)
    private var tmdbLanguage = LocalizationManager.defaultTMDBCode
    @StateObject private var accentColorManager = AccentColorManager.shared

    private var accent: Color { accentColorManager.currentAccentColor }

    private var selected: AppLanguageOption {
        AppLanguageOption.from(tmdbLanguageCode: tmdbLanguage)
    }

    var body: some View {
        List {
            Section {
                ForEach(AppLanguageOption.allCases) { option in
                    Button {
                        tmdbLanguage = option.tmdbLanguageCode
                    } label: {
                        HStack {
                            Text(option.displayName)
                                .foregroundColor(.primary)
                            Spacer()
                            if option == selected {
                                Image(systemName: "checkmark")
                                    .foregroundColor(accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("This also sets the language Eclipse requests movie and show info in. Translations are community-contributed and still a work in progress, so some screens may still show English text.")
            }
        }
        .eclipsePageTitle("Language")
        .accessibilityIdentifier("tv.settings.language.screen")
        .eclipseSettingsStyle()
    }
}
