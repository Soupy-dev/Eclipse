import SwiftUI

struct PlayerLanguageSelectionView: View {
    let title: String
    @Binding var selectedLanguage: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var accentColorManager = AccentColorManager.shared

    let languages: [(code: String, name: String)] = [
        ("eng", "English"),
        ("jpn", "Japanese"),
        ("zho", "Chinese"),
        ("kor", "Korean"),
        ("spa", "Spanish"),
        ("fra", "French"),
        ("deu", "German"),
        ("ita", "Italian"),
        ("por", "Portuguese"),
        ("rus", "Russian"),
        ("tha", "Thai"),
        ("ara", "Arabic"),
        ("heb", "Hebrew"),
        ("tur", "Turkish"),
        ("pol", "Polish"),
        ("swe", "Swedish"),
        ("dan", "Danish"),
        ("fin", "Finnish"),
        ("nor", "Norwegian"),
        ("nld", "Dutch")
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                GlassSection {
                    VStack(spacing: 0) {
                        ForEach(Array(languages.enumerated()), id: \.element.code) { index, language in
                            GlassSelectionRow(
                                title: language.name,
                                isSelected: selectedLanguage == language.code,
                                accent: accentColorManager.currentAccentColor
                            ) {
                                selectedLanguage = language.code
                                dismiss()
                            }

                            if index < languages.count - 1 {
                                GlassDivider(leadingInset: 16)
                            }
                        }
                    }
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
            .background(EclipseScrollTracker())
        }
        .navigationTitle(title)
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

#Preview {
    NavigationView {
        PlayerLanguageSelectionView(
            title: "Default Subtitle Language",
            selectedLanguage: .constant("eng")
        )
    }
}
