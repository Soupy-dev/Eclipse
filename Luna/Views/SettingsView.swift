//
//  SettingsView.swift
//  Sora
//
//  Created by Francesco on 07/08/25.
//

import SwiftUI

struct SettingsView: View {
    @AppStorage("tmdbLanguage") private var selectedLanguage = "en-US"
    @AppStorage("githubReleaseAutoCheckEnabled") private var autoCheckGitHubReleases = true
    @AppStorage("githubReleaseUpdateAvailable") private var githubReleaseUpdateAvailable = false
    @AppStorage("githubReleaseLatestVersion") private var githubReleaseLatestVersion = ""
    @AppStorage("githubReleaseURL") private var githubReleaseURL = ""

    @StateObject private var algorithmManager = AlgorithmManager.shared
    @AppStorage("showKanzen") private var showKanzen: Bool = false
    @State private var scrollOffset: CGFloat = 0
    @State private var isCheckingGitHubRelease = false
    
    let languages = [
        ("en-US", "English (US)"),
        ("en-GB", "English (UK)"),
        ("es-ES", "Spanish (Spain)"),
        ("es-MX", "Spanish (Mexico)"),
        ("fr-FR", "French"),
        ("de-DE", "German"),
        ("it-IT", "Italian"),
        ("pt-BR", "Portuguese (Brazil)"),
        ("ja-JP", "Japanese"),
        ("ko-KR", "Korean"),
        ("zh-CN", "Chinese (Simplified)"),
        ("zh-TW", "Chinese (Traditional)"),
        ("ru-RU", "Russian"),
        ("ar-SA", "Arabic"),
        ("hi-IN", "Hindi"),
        ("th-TH", "Thai"),
        ("tr-TR", "Turkish"),
        ("pl-PL", "Polish"),
        ("nl-NL", "Dutch"),
        ("sv-SE", "Swedish"),
        ("da-DK", "Danish"),
        ("no-NO", "Norwegian"),
        ("fi-FI", "Finnish")
    ]
    
    var body: some View {
        #if os(tvOS)
            HStack(spacing: 0) {
                VStack(spacing: 30) {
                    Image("Luna")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 500, height: 500)
                        .clipShape(RoundedRectangle(cornerRadius: 100, style: .continuous))
                        .shadow(radius: 10)

                    VStack(spacing: 15) {
                        Text("Version \(Bundle.main.appVersion) (\(Bundle.main.buildNumber))")
                            .font(.footnote)
                            .fontWeight(.regular)
                            .foregroundColor(.secondary)

                        Text("Copyright © \(String(Calendar.current.component(.year, from: Date()))) Eclipse by Cranci")
                            .font(.footnote)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                    }
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                NavigationStack {
                    settingsContent
                        // prevent row clipping
                        .padding(.horizontal, 20)
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        #else
            if #available(iOS 16.0, *) {
                NavigationStack {
                    settingsContent
                }
            } else {
                NavigationView {
                    settingsContent
                }
                .navigationViewStyle(StackNavigationViewStyle())
            }
        #endif
    }

    private var settingsContent: some View {
        #if os(tvOS)
        List {
            settingsListContent
        }
        .listStyle(.grouped)
        .scrollClipDisabled()
        #else
        ScrollView {
            VStack(spacing: 28) {
                // MARK: - Basic
                GlassSection(header: "Basic") {
                    VStack(spacing: 0) {
                        NavigationLink(destination: LanguageSelectionView(selectedLanguage: $selectedLanguage, languages: languages)) {
                            GlassSettingsRow(icon: "globe", iconColor: .blue, title: "Language") {
                                HStack(spacing: 4) {
                                    Text(languages.first { $0.0 == selectedLanguage }?.1 ?? "English (US)")
                                        .font(.subheadline)
                                        .foregroundColor(.white.opacity(0.5))
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.3))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        
                        GlassDivider()
                        
                        NavigationLink(destination: TMDBFiltersView()) {
                            GlassSettingsRow(icon: "line.3.horizontal.decrease.circle", iconColor: .orange, title: "Content Filters")
                        }
                        .buttonStyle(.plain)
                        
                        GlassDivider()
                        
                        NavigationLink(destination: AlgorithmSelectionView()) {
                            GlassSettingsRow(icon: "magnifyingglass", iconColor: .cyan, title: "Matching Algorithm") {
                                HStack(spacing: 4) {
                                    Text(algorithmManager.selectedAlgorithm.displayName)
                                        .font(.subheadline)
                                        .foregroundColor(.white.opacity(0.5))
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.3))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        
                        GlassDivider()
                        
                        NavigationLink(destination: PlayerSettingsView()) {
                            GlassSettingsRow(icon: "play.fill", iconColor: .white, title: "Media Player")
                        }
                        .buttonStyle(.plain)
                        
                        GlassDivider()
                        
                        NavigationLink(destination: AlternativeUIView()) {
                            GlassSettingsRow(icon: "paintbrush.fill", iconColor: .purple, title: "Appearance")
                        }
                        .buttonStyle(.plain)
                        
                        GlassDivider()
                        
                        NavigationLink(destination: CatalogsSettingsView()) {
                            GlassSettingsRow(icon: "square.grid.2x2", iconColor: .green, title: "Catalogs")
                        }
                        .buttonStyle(.plain)
                        
                        GlassDivider()
                        
                        NavigationLink(destination: ServicesView()) {
                            GlassSettingsRow(icon: "server.rack", iconColor: .indigo, title: "Services")
                        }
                        .buttonStyle(.plain)
                        
                        GlassDivider()
                        
                        NavigationLink(destination: TrackersSettingsView()) {
                            GlassSettingsRow(icon: "chart.bar.fill", iconColor: .pink, title: "Trackers")
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                // MARK: - Data
                GlassSection(header: "Data") {
                    VStack(spacing: 0) {
                        NavigationLink(destination: StorageView()) {
                            GlassSettingsRow(icon: "internaldrive", iconColor: .gray, title: "Storage")
                        }
                        .buttonStyle(.plain)
                        
                        GlassDivider()
                        
                        NavigationLink(destination: BackupManagementView()) {
                            GlassSettingsRow(icon: "arrow.triangle.2.circlepath", iconColor: .teal, title: "Backup & Restore")
                        }
                        .buttonStyle(.plain)
                        
                        GlassDivider()
                        
                        NavigationLink(destination: LoggerView()) {
                            GlassSettingsRow(icon: "doc.text", iconColor: .yellow, title: "Logger")
                        }
                        .buttonStyle(.plain)
                    }
                }
                
                // MARK: - Others
                GlassSection(header: "Others") {
                    VStack(spacing: 0) {
                        Button {
                            showKanzen = true
                        } label: {
                            GlassSettingsRow(icon: "book.fill", iconColor: .orange, title: "Switch to Reader Mode")
                        }
                        .buttonStyle(.plain)
                    }
                }

                // MARK: - Updates
                GlassSection(header: "Updates") {
                    VStack(spacing: 0) {
                        GlassSettingsRow(icon: "arrow.triangle.2.circlepath", iconColor: .mint, title: "Auto-check GitHub Releases") {
                            Toggle("", isOn: $autoCheckGitHubReleases)
                                .labelsHidden()
                                .tint(.mint)
                        }

                        GlassDivider()

                        Button {
                            performManualGitHubReleaseCheck()
                        } label: {
                            GlassSettingsRow(icon: "arrow.clockwise", iconColor: .cyan, title: "Check for Updates") {
                                if isCheckingGitHubRelease {
                                    ProgressView()
                                        .progressViewStyle(.circular)
                                        .tint(.white.opacity(0.6))
                                } else {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.white.opacity(0.3))
                                }
                            }
                        }
                        .disabled(isCheckingGitHubRelease)
                        .buttonStyle(.plain)

                        if githubReleaseUpdateAvailable {
                            GlassDivider()

                            if let releaseURL = URL(string: githubReleaseURL), !githubReleaseURL.isEmpty {
                                Link(destination: releaseURL) {
                                    GlassSettingsRow(icon: "arrow.down.circle.fill", iconColor: .green, title: "Open Latest Release") {
                                        Text(githubReleaseLatestVersion.isEmpty ? "Update Available" : githubReleaseLatestVersion)
                                            .font(.subheadline)
                                            .foregroundColor(.green.opacity(0.9))
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                
                // MARK: - Version Info
                VStack(spacing: 4) {
                    Text("Eclipse v\(Bundle.main.appVersion) (\(Bundle.main.buildNumber))")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.3))

                    if githubReleaseUpdateAvailable {
                        Text(githubReleaseLatestVersion.isEmpty ? "Update available on GitHub" : "Update available: \(githubReleaseLatestVersion)")
                            .font(.footnote)
                            .foregroundColor(.green.opacity(0.85))
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
            .padding(.top, 16)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: ScrollOffsetPreferenceKey.self,
                        value: -geo.frame(in: .named("settingsScroll")).origin.y
                    )
                }
            )
        }
        .coordinateSpace(name: "settingsScroll")
        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { scrollOffset = $0 }
        .navigationTitle("Settings")
        .background(SettingsGradientBackground(scrollOffset: scrollOffset).ignoresSafeArea())
        .lunaDarkToolbar()
        #endif
    }
    
    // Keep tvOS list-based layout as fallback
    @ViewBuilder
    private var settingsListContent: some View {
        Section {
            NavigationLink(destination: LanguageSelectionView(selectedLanguage: $selectedLanguage, languages: languages)) {
                HStack {
                    Text("Informations Language")
                    Spacer()
                    Text(languages.first { $0.0 == selectedLanguage }?.1 ?? "English (US)")
                        .foregroundColor(.secondary)
                }
            }
            NavigationLink(destination: TMDBFiltersView()) {
                Text("Content Filters")
            }
        } header: {
            Text("TMDB Settings")
        }
        
        Section {
            NavigationLink(destination: AlgorithmSelectionView()) {
                HStack {
                    Text("Matching Algorithm")
                    Spacer()
                    Text(algorithmManager.selectedAlgorithm.displayName)
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Search Settings")
        }
        
        Section {
            NavigationLink(destination: PlayerSettingsView()) { Text("Media Player") }
            NavigationLink(destination: AlternativeUIView()) { Text("Appearance") }
            NavigationLink(destination: CatalogsSettingsView()) { Text("Catalogs") }
            NavigationLink(destination: ServicesView()) { Text("Services") }
            NavigationLink(destination: TrackersSettingsView()) { Text("Trackers") }
        }
        
        Section {
            NavigationLink(destination: StorageView()) { Text("Storage") }
            NavigationLink(destination: BackupManagementView()) { Text("Backup & Restore") }
            NavigationLink(destination: LoggerView()) { Text("Logger") }
        } header: {
            Text("Data")
        }

        Section {
            Toggle("Auto-check GitHub Releases", isOn: $autoCheckGitHubReleases)

            Button(isCheckingGitHubRelease ? "Checking..." : "Check for Updates") {
                performManualGitHubReleaseCheck()
            }
            .disabled(isCheckingGitHubRelease)

            if githubReleaseUpdateAvailable,
               let releaseURL = URL(string: githubReleaseURL),
               !githubReleaseURL.isEmpty {
                Link("Open Latest Release (\(githubReleaseLatestVersion.isEmpty ? "Update Available" : githubReleaseLatestVersion))", destination: releaseURL)
            }
        } header: {
            Text("App Updates")
        }
        
        Section {
            Text("Switch to Reader Mode")
                .onTapGesture { showKanzen = true }
        } header: {
            Text("Others")
        }
    }

    private func performManualGitHubReleaseCheck() {
        guard !isCheckingGitHubRelease else { return }
        Task {
            await MainActor.run {
                isCheckingGitHubRelease = true
            }
            await GitHubReleaseChecker.checkForUpdates(force: true)
            await MainActor.run {
                isCheckingGitHubRelease = false
            }
        }
    }
}

struct LanguageSelectionView: View {
    @StateObject private var accentColorManager = AccentColorManager.shared
    @Binding var selectedLanguage: String
    let languages: [(String, String)]
    
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                GlassSection {
                    VStack(spacing: 0) {
                        ForEach(Array(languages.enumerated()), id: \.element.0) { index, language in
                            Button {
                                selectedLanguage = language.0
                            } label: {
                                HStack {
                                    Text(language.1)
                                        .foregroundColor(.white)
                                    Spacer()
                                    if selectedLanguage == language.0 {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(accentColorManager.currentAccentColor)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 13)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            
                            if index < languages.count - 1 {
                                Rectangle()
                                    .fill(LunaTheme.shared.separatorColor)
                                    .frame(height: 0.5)
                                    .padding(.leading, 16)
                            }
                        }
                    }
                }
            }
            .padding(.top, 16)
            .background(LunaScrollTracker())
        }
        .navigationTitle("Language")
        .lunaGradientBackground()
        .lunaDarkToolbar()
    }
}
