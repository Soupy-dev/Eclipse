import SwiftUI
#if os(tvOS)
import CoreImage.CIFilterBuiltins
import Network
#endif
#if canImport(StoreKit)
import StoreKit
#endif

struct SettingsView: View {
#if os(tvOS)
    private enum TVFocusTarget: Hashable {
        case services
        case diagnostics
    }
#endif

    /// Provided by full-screen Settings hosts. Sheet and tvOS presentations
    /// continue to use their native dismissal behavior.
    private let onRootDismiss: (() -> Void)?

    init(onRootDismiss: (() -> Void)? = nil) {
        self.onRootDismiss = onRootDismiss
    }

    @AppStorage("githubReleaseAutoCheckEnabled") private var autoCheckGitHubReleases = true
    @AppStorage("githubReleaseUpdateAvailable") private var githubReleaseUpdateAvailable = false
    @AppStorage("githubReleaseLatestVersion") private var githubReleaseLatestVersion = ""
    @AppStorage("githubReleaseURL") private var githubReleaseURL = ""
    @AppStorage("defaultScheduleMode") private var defaultScheduleModeRaw = ScheduleMode.anime.rawValue
    @AppStorage(PerformanceModeSettings.skipAniListTraversalForAnimeDetailsKey) private var skipAniListTraversalForAnimeDetails = false

    @StateObject private var catalogManager = CatalogManager.shared
#if !os(tvOS)
    @AppStorage("showKanzen") private var showKanzen: Bool = false
    @State private var settingsSearchText = ""
#else
    @FocusState private var tvFocusTarget: TVFocusTarget?
#endif
    @State private var isCheckingGitHubRelease = false

    private let koFiURL = URL(string: "https://ko-fi.com/soupydev")!
    private let discordURL = URL(string: "https://discord.gg/UjHgGaEbn")!
    private let sourceCodeURL = URL(string: "https://github.com/Soupy-dev/Eclipse")!
    private let originalProjectURL = URL(string: "https://github.com/cranci1/Luna")!
    private let licenseURL = URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!
    private let privacyPolicyURL = URL(string: "https://soupy-dev.github.io/Eclipse/privacy-policy/")!

    private var defaultScheduleMode: ScheduleMode {
        ScheduleMode.sanitized(defaultScheduleModeRaw)
    }

    private var supportsGitHubReleaseUpdates: Bool {
        PlatformCapabilities.current.supportsGitHubUpdates
    }

#if !os(tvOS)
    private var filteredSettingsSearchEntries: [SettingsSearchEntry] {
        let query = settingsSearchText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !query.isEmpty else { return [] }

        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return settingsSearchEntries
            .filter { entry in
                let haystack = ([entry.title, entry.location] + entry.keywords)
                    .joined(separator: " ")
                    .lowercased()
                return terms.allSatisfy(haystack.contains)
            }
            .sorted { lhs, rhs in
                let lhsTitle = lhs.title.lowercased()
                let rhsTitle = rhs.title.lowercased()
                let lhsStarts = lhsTitle.hasPrefix(query)
                let rhsStarts = rhsTitle.hasPrefix(query)
                if lhsStarts != rhsStarts { return lhsStarts }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    private var settingsSearchEntries: [SettingsSearchEntry] {
        var entries: [SettingsSearchEntry] = [
            .init(id: "performance-mode", title: "Performance Mode", location: "Basic", icon: "bolt.fill", color: .yellow, keywords: ["fast", "AniList", "catalog"], action: .destination(.performance)),
            .init(id: "media-player", title: "Media Player", location: "Basic", icon: "play.fill", color: .white, keywords: ["MPV", "VLC", "AVPlayer", "default player"], action: .destination(.player)),
            .init(id: "playback-speed", title: "Default Playback Speed", location: "Media Player > Default Player", icon: "gauge.with.dots.needle.50percent", color: .orange, keywords: ["playback speed", "rate", "speed"], action: .destination(.playerTarget(.defaultPlaybackSpeed))),
            .init(id: "subtitles", title: "Subtitle Defaults", location: "Media Player > MPV Player", icon: "captions.bubble", color: .cyan, keywords: ["subtitle settings", "captions", "OpenSubtitles", "default subtitle language"], action: .destination(.playerTarget(.subtitleDefaults))),
            .init(id: "anime-audio", title: "Preferred Anime Audio", location: "Media Player > Subtitle Defaults", icon: "waveform", color: .pink, keywords: ["anime audio", "sub", "dub", "Japanese", "English"], action: .destination(.playerTarget(.preferredAnimeAudio))),
            .init(id: "auto-language", title: "Auto Audio Language", location: "Media Player > Subtitle Defaults", icon: "character.bubble", color: .mint, keywords: ["auto language", "audio", "non-anime", "movies", "shows", "preferred language"], action: .destination(.playerTarget(.autoAudioLanguage))),
            .init(id: "player-gestures", title: "Playback Gestures", location: "Media Player > MPV Player", icon: "hand.tap", color: .purple, keywords: ["player gestures", "double tap", "seek", "brightness", "volume"], action: .destination(.playerTarget(.playbackGestures))),
            .init(id: "picture-in-picture", title: "Picture in Picture", location: "Media Player > MPV Rendering", icon: "pip", color: .indigo, keywords: ["PiP", "background playback"], action: .destination(.playerTarget(.pictureInPicture))),
            .init(id: "upscaling", title: "Upscaling", location: "Media Player > MPV Rendering", icon: "sparkles.rectangle.stack", color: .cyan, keywords: ["upscale", "resolution", "1080p", "4K", "MoltenVK"], action: .destination(.playerTarget(.upscaling))),
            .init(id: "player-skin", title: "Player Skin", location: "Media Player > MPV Player", icon: "paintpalette.fill", color: .pink, keywords: ["MPV UI", "theme", "Black and Gold", "Prismatic", "Cyberpunk", "Custom"], action: .destination(.playerTarget(.playerSkin))),
            .init(id: "watch-together", title: "Watch Together", location: "Basic", icon: "person.2.wave.2", color: .green, keywords: ["SharePlay", "FaceTime", "sync", "secure", "group", "enable", "disable", "MPV", "MoltenVK"], action: .destination(.watchTogether)),
            .init(id: "appearance", title: "Appearance", location: "Basic", icon: "paintbrush.fill", color: .purple, keywords: ["theme", "layout", "home", "details", "artwork", "UI"], action: .destination(.appearance)),
            .init(id: "schedule", title: "Schedule", location: "Basic", icon: "calendar", color: .red, keywords: ["calendar", "anime", "western", "default tab"], action: .destination(.schedule)),
            .init(id: "catalogs", title: "Catalogs", location: "Basic", icon: "square.grid.2x2", color: .green, keywords: ["home rows", "discover", "TMDB"], action: .destination(.catalogs)),
            .init(id: "services-auto-update", title: "Auto-Update Services", location: "Services", icon: "arrow.triangle.2.circlepath", color: .mint, keywords: ["service updates", "update sources", "startup"], action: .destination(.servicesTarget(.autoUpdateServices))),
            .init(id: "services-auto-mode", title: "Auto Mode", location: "Services", icon: "wand.and.stars", color: .indigo, keywords: ["automatic source", "source order", "auto download"], action: .destination(.servicesTarget(.autoMode))),
            .init(id: "services-include-language", title: "Languages to Include", location: "Services > Extra Service Settings", icon: "checkmark.bubble", color: .green, keywords: ["include language", "allow", "whitelist", "streams", "Stremio"], action: .destination(.servicesTarget(.languagesToInclude))),
            .init(id: "services-exclude-language", title: "Languages to Exclude", location: "Services > Extra Service Settings", icon: "xmark.bubble", color: .red, keywords: ["exclude language", "block", "hide", "streams", "Stremio"], action: .destination(.servicesTarget(.languagesToExclude))),
            .init(id: "services-stremio-style", title: "Stremio-Style Stream List", location: "Services > Extra Service Settings", icon: "rectangle.grid.1x2", color: .blue, keywords: ["stream list", "layout", "flat", "results", "Stremio"], action: .destination(.servicesTarget(.stremioStyleSheet))),
            .init(id: "services-missing-language", title: "Hide Streams Without Language Data", location: "Services > Extra Service Settings", icon: "questionmark.bubble", color: .orange, keywords: ["unknown", "missing", "untagged"], action: .destination(.servicesTarget(.missingLanguageData))),
            .init(id: "stremio-addons", title: "Stremio Addons", location: "Services", icon: "shippingbox", color: .blue, keywords: ["addon", "configure", "install"], action: .destination(.services)),
            .init(id: "trackers", title: "Trackers", location: "Basic", icon: "chart.bar.fill", color: .pink, keywords: ["Trakt", "MyAnimeList", "MAL", "AniList", "SIMKL"], action: .destination(.trackers)),
            .init(id: "storage", title: "Storage", location: "Data", icon: "internaldrive", color: .gray, keywords: ["downloads", "cache", "files", "clear"], action: .destination(.storage)),
            .init(id: "backup", title: "Backup & Restore", location: "Data", icon: "arrow.triangle.2.circlepath", color: .teal, keywords: ["export", "import", "settings"], action: .destination(.backup)),
            .init(id: "logger", title: "Logger", location: "Data", icon: "doc.text", color: .yellow, keywords: ["logs", "diagnostics", "errors", "export"], action: .destination(.logger)),
            .init(id: "support", title: "Support Eclipse", location: "Support", icon: "heart.fill", color: .pink, keywords: ["tip", "subscription", "Ko-fi", "Discord"], action: .anchor("settings-support")),
            .init(id: "reader-mode", title: "Switch to Reader Mode", location: "Others", icon: "book.fill", color: .orange, keywords: ["Kanzen", "manga", "reader"], action: .readerMode),
            .init(id: "legal", title: "Legal & Source", location: "Others", icon: "scroll.fill", color: .cyan, keywords: ["privacy", "license", "GitHub", "source code"], action: .destination(.legal))
        ]

        if ExperimentalFeatureState.isEnabledAtLaunch {
            entries.append(.init(id: "cloud-sync", title: "Cloud Sync", location: "Data", icon: "cloud", color: .blue, keywords: ["iCloud", "sync", "library", "progress"], action: .destination(.cloud)))
        }
        if !WatchTogetherSettings.isAvailableInCurrentBuild {
            entries.removeAll { $0.id == "watch-together" }
        }
        if supportsGitHubReleaseUpdates {
            entries.append(.init(id: "updates", title: "App Updates", location: "Updates", icon: "arrow.triangle.2.circlepath", color: .mint, keywords: ["GitHub releases", "check", "auto check", "latest version"], action: .anchor("settings-updates")))
        }
        return entries
    }
#endif

    var body: some View {
        #if os(tvOS)
            settingsContent
        #else
            if #available(iOS 16.0, *) {
                NavigationStack {
                    settingsRootContent
                }
            } else {
                NavigationView {
                    settingsRootContent
                }
                .navigationViewStyle(StackNavigationViewStyle())
            }
        #endif
    }

#if !os(tvOS)
    /// The exit gesture lives on the Settings root rather than its full-screen
    /// host, so scrolling and a pushed settings page keep their native gestures.
    @ViewBuilder
    private var settingsRootContent: some View {
        if let onRootDismiss {
            settingsContent
                .simultaneousGesture(
                    DragGesture(minimumDistance: 10, coordinateSpace: .global)
                        .onEnded { value in
                            let horizontalDistance = value.translation.width
                            let verticalDistance = abs(value.translation.height)
                            let projectedDistance = value.predictedEndTranslation.width
                            let startedAtLeadingEdge = value.startLocation.x <= 36
                            let isMostlyHorizontal = horizontalDistance > verticalDistance * 1.5
                            let reachesDismissDistance = horizontalDistance >= 80
                            let isFastRightFlick = horizontalDistance >= 32 && projectedDistance >= 112

                            guard startedAtLeadingEdge,
                                  horizontalDistance > 0,
                                  isMostlyHorizontal,
                                  (reachesDismissDistance || isFastRightFlick) else {
                                return
                            }

                            onRootDismiss()
                        }
                )
        } else {
            settingsContent
        }
    }
#endif

    private var settingsContent: some View {
        #if os(tvOS)
        List {
            settingsListContent
        }
        .listStyle(.grouped)
        .scrollClipDisabled()
        #else
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(spacing: ExperimentalFeatureState.isEnabledAtLaunch ? 22 : 28) {
                    if settingsSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // MARK: - Support
                GlassSection(header: "Support") {
                    VStack(spacing: 0) {
                        if Bundle.main.allowsExternalDonationLinks {
                            Text("Help support the app. Any amount helps keep the app free for everyone. Thanks for using the app and supporting development!")
                                .font(.subheadline)
                                .foregroundColor(.white.opacity(0.62))
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)

                            GlassDivider(leadingInset: 14)

                            Link(destination: koFiURL) {
                                GlassSettingsRow(icon: "cup.and.saucer.fill", iconColor: .cyan, title: "Support on Ko-fi") {
                                    Text("Optional")
                                        .font(.subheadline)
                                        .foregroundColor(.white.opacity(0.5))
                                }
                            }
                            .buttonStyle(.plain)

                            GlassDivider()
                        } else {
                            #if canImport(StoreKit)
                            NavigationLink(destination: StoreKitSupportView()) {
                                GlassSettingsRow(icon: "heart.fill", iconColor: .pink, title: "Support Eclipse") {
                                    HStack(spacing: 4) {
                                        Text("Tips & subscription")
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
                            #endif
                        }

                        Link(destination: discordURL) {
                            GlassSettingsRow(icon: "bubble.left.and.bubble.right.fill", iconColor: .indigo, title: "Join Discord") {
                                Text("Community")
                                    .font(.subheadline)
                                    .foregroundColor(.white.opacity(0.5))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .id("settings-support")

                // MARK: - Basic
                GlassSection(header: "Basic") {
                    VStack(spacing: 0) {
                        NavigationLink(destination: PerformanceModeSettingsView()) {
                            GlassSettingsRow(icon: "bolt.fill", iconColor: .yellow, title: "Performance Mode") {
                                HStack(spacing: 4) {
                                    Text(catalogManager.performanceModeEnabled || skipAniListTraversalForAnimeDetails ? "On" : "Off")
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

                        if WatchTogetherSettings.isAvailableInCurrentBuild {
                            NavigationLink(destination: WatchTogetherSettingsView()) {
                                GlassSettingsRow(icon: "person.2.wave.2", iconColor: .green, title: "Watch Together") {
                                    HStack(spacing: 4) {
                                        Text("SharePlay")
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
                        }

                        NavigationLink(destination: AlternativeUIView()) {
                            GlassSettingsRow(icon: "paintbrush.fill", iconColor: .purple, title: "Appearance")
                        }
                        .buttonStyle(.plain)

                        GlassDivider()

                        NavigationLink(destination: ScheduleSettingsView()) {
                            GlassSettingsRow(icon: "calendar", iconColor: .red, title: "Schedule") {
                                HStack(spacing: 4) {
                                    Text(defaultScheduleMode.displayName)
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

                        if ExperimentalFeatureState.isEnabledAtLaunch {
                            GlassDivider()

                            NavigationLink(destination: ExperimentalCloudSyncView()) {
                                GlassSettingsRow(icon: "cloud", iconColor: .blue, title: "Cloud Sync") {
                                    Text("Available")
                                        .font(.subheadline)
                                        .foregroundColor(.white.opacity(0.5))
                                }
                            }
                            .buttonStyle(.plain)
                        }

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

                        GlassDivider()

                        NavigationLink(destination: LegalNoticeView(
                            sourceCodeURL: sourceCodeURL,
                            originalProjectURL: originalProjectURL,
                            licenseURL: licenseURL,
                            privacyPolicyURL: privacyPolicyURL
                        )) {
                            GlassSettingsRow(icon: "scroll.fill", iconColor: .cyan, title: "Legal & Source")
                        }
                        .buttonStyle(.plain)
                    }
                }

                // MARK: - Updates
                if supportsGitHubReleaseUpdates {
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
                                        EclipseLoadingIndicator()
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
                    .id("settings-updates")
                }

                // MARK: - Version Info
                VStack(spacing: 4) {
                    Text("Eclipse v\(Bundle.main.appVersion) (\(Bundle.main.buildNumber))")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.3))

                    if supportsGitHubReleaseUpdates && githubReleaseUpdateAvailable {
                        Text(githubReleaseLatestVersion.isEmpty ? "Update available on GitHub" : "Update available: \(githubReleaseLatestVersion)")
                            .font(.footnote)
                            .foregroundColor(.green.opacity(0.85))
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 30)
                    } else {
                        settingsSearchResults(scrollProxy: scrollProxy)
                    }
                }
                .padding(.top, ExperimentalFeatureState.isEnabledAtLaunch ? 12 : 16)
            }
            .searchable(
                text: $settingsSearchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search settings"
            )
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .navigationTitle("Settings")
            .background(SettingsGradientBackground().ignoresSafeArea())
            .eclipseDarkToolbar()
        }
        #endif
    }

#if !os(tvOS)
    @ViewBuilder
    private func settingsSearchResults(scrollProxy: ScrollViewProxy) -> some View {
        if filteredSettingsSearchEntries.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                Text("No Settings Found")
                    .font(.headline)
                    .foregroundColor(.white)
                Text("Try a setting name, feature, or service.")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 70)
        } else {
            GlassSection(header: "Search Results") {
                VStack(spacing: 0) {
                    ForEach(Array(filteredSettingsSearchEntries.enumerated()), id: \.element.id) { index, entry in
                        settingsSearchLink(for: entry, scrollProxy: scrollProxy)
                        if index < filteredSettingsSearchEntries.count - 1 {
                            GlassDivider()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func settingsSearchLink(for entry: SettingsSearchEntry, scrollProxy: ScrollViewProxy) -> some View {
        switch entry.action {
        case .destination(let destination):
            NavigationLink(destination: settingsSearchDestination(destination)) {
                settingsSearchRow(entry)
            }
            .buttonStyle(.plain)
        case .anchor(let anchor):
            Button {
                settingsSearchText = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation(.easeInOut(duration: 0.28)) {
                        scrollProxy.scrollTo(anchor, anchor: .top)
                    }
                }
            } label: {
                settingsSearchRow(entry)
            }
            .buttonStyle(.plain)
        case .readerMode:
            Button {
                settingsSearchText = ""
                showKanzen = true
            } label: {
                settingsSearchRow(entry)
            }
            .buttonStyle(.plain)
        }
    }

    private func settingsSearchRow(_ entry: SettingsSearchEntry) -> some View {
        GlassSettingsRow(icon: entry.icon, iconColor: entry.color, title: entry.title) {
            HStack(spacing: 6) {
                Text(entry.location)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
    }

    @ViewBuilder
    private func settingsSearchDestination(_ destination: SettingsSearchDestination) -> some View {
        switch destination {
        case .performance:
            PerformanceModeSettingsView()
        case .player:
            PlayerSettingsView()
        case .playerTarget(let target):
            PlayerSettingsView(initialSearchTarget: target)
        case .watchTogether:
            WatchTogetherSettingsView()
        case .appearance:
            AlternativeUIView()
        case .schedule:
            ScheduleSettingsView()
        case .catalogs:
            CatalogsSettingsView()
        case .services:
            ServicesView()
        case .servicesTarget(let target):
            ServicesView(initialSearchTarget: target)
        case .trackers:
            TrackersSettingsView()
        case .storage:
            StorageView()
        case .backup:
            BackupManagementView()
        case .cloud:
            ExperimentalCloudSyncView()
        case .logger:
            LoggerView()
        case .legal:
            LegalNoticeView(
                sourceCodeURL: sourceCodeURL,
                originalProjectURL: originalProjectURL,
                licenseURL: licenseURL,
                privacyPolicyURL: privacyPolicyURL
            )
        }
    }
#endif

    // Keep tvOS list-based layout as fallback
    @ViewBuilder
    private var settingsListContent: some View {
#if os(tvOS) && canImport(StoreKit)
        TVSupportSettingsSection()
#endif

        Section {
            NavigationLink(destination: PerformanceModeSettingsView()) {
                Text("Performance Mode")
            }
        } header: {
            Text("TMDB Settings")
        }

        Section {
            NavigationLink(destination: PlayerSettingsView()) { Text("Media Player") }
            NavigationLink(destination: AlternativeUIView()) { Text("Appearance") }
                .accessibilityIdentifier("tv.settings.appearance")
            NavigationLink(destination: ScheduleSettingsView()) { Text("Schedule") }
            NavigationLink(destination: CatalogsSettingsView()) { Text("Catalogs") }
                .accessibilityIdentifier("tv.settings.catalogs")
            #if os(tvOS)
            NavigationLink(destination: ServicesView()
                .onAppear {
                    tvFocusTarget = nil
                }
                .onDisappear {
                    restoreTVFocus(to: .services)
                }
            ) { Text("Services") }
            .focused($tvFocusTarget, equals: .services)
            .accessibilityIdentifier("tv.settings.services")
            #else
            NavigationLink(destination: ServicesView()) { Text("Services") }
            #endif
            NavigationLink(destination: TrackersSettingsView()) { Text("Trackers") }
        }

        Section {
#if os(tvOS)
            NavigationLink(destination: TVDataSettingsView()) { Text("Cloud Sync & Cache") }
#endif
        } header: {
            Text("Data")
        }

        Section {
#if os(tvOS)
            NavigationLink(destination: TVDiagnosticsView()
                .onAppear {
                    // The destination owns Remote focus while it is visible.
                    // Keeping the source link focused leaves a hidden focus
                    // item behind the pushed screen and prevents Menu/Back.
                    tvFocusTarget = nil
                }
                .onDisappear {
                    restoreTVFocus(to: .diagnostics)
                }
            ) {
                Text("Diagnostics")
            }
            .focused($tvFocusTarget, equals: .diagnostics)
            .accessibilityIdentifier("tv.settings.diagnostics")
#endif
            NavigationLink(destination: LegalNoticeView(
                sourceCodeURL: sourceCodeURL,
                originalProjectURL: originalProjectURL,
                licenseURL: licenseURL,
                privacyPolicyURL: privacyPolicyURL
            )) {
                Text("Legal & Source")
            }
        } header: {
            Text("About")
        } footer: {
            Text("Eclipse v\(Bundle.main.appVersion) (\(Bundle.main.buildNumber)). Updates are delivered by the App Store.")
        }
    }

    private func performManualGitHubReleaseCheck() {
        guard supportsGitHubReleaseUpdates, !isCheckingGitHubRelease else { return }
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

#if os(tvOS)
    private func restoreTVFocus(to target: TVFocusTarget) {
        Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(180))
            tvFocusTarget = target
        }
    }
#endif
}

#if !os(tvOS)
private enum SettingsSearchDestination: Hashable {
    case performance
    case player
    case playerTarget(PlayerSettingsSearchTarget)
    case watchTogether
    case appearance
    case schedule
    case catalogs
    case services
    case servicesTarget(ServicesSettingsSearchTarget)
    case trackers
    case storage
    case backup
    case cloud
    case logger
    case legal
}

private enum SettingsSearchAction: Hashable {
    case destination(SettingsSearchDestination)
    case anchor(String)
    case readerMode
}

private struct SettingsSearchEntry: Identifiable, Hashable {
    let id: String
    let title: String
    let location: String
    let icon: String
    let color: Color
    let keywords: [String]
    let action: SettingsSearchAction

    static func == (lhs: SettingsSearchEntry, rhs: SettingsSearchEntry) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

private struct WatchTogetherSettingsView: View {
    @AppStorage(WatchTogetherSettings.enabledKey)
    private var watchTogetherEnabled = WatchTogetherSettings.defaultEnabled

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 12) {
                    Image(systemName: "person.2.wave.2.fill")
                        .font(.system(size: 46, weight: .semibold))
                        .foregroundColor(.green)
                    Text("Watch Together")
                        .font(.title2.bold())
                        .foregroundColor(.white)
                    Text("Secure, synchronized playback through Apple SharePlay.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white.opacity(0.62))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 18)

                GlassSection(header: "Availability") {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Enable Watch Together")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(.white)
                            Text("Available only when playing with MPV's MoltenVK renderer. The player button stays hidden in AVPlayer and while this setting is off.")
                                .font(.footnote)
                                .foregroundColor(.white.opacity(0.58))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 8)
                        Toggle("", isOn: $watchTogetherEnabled)
                            .labelsHidden()
                            .tint(.green)
                    }
                    .padding(14)
                }

                GlassSection(header: "How It Works") {
                    VStack(spacing: 0) {
                        WatchTogetherInfoRow(
                            icon: "1.circle.fill",
                            title: "Use MPV with MoltenVK",
                            detail: "Start the movie or episode with the MoltenVK MPV renderer. Watch Together is not available in Normal AVPlayer."
                        )
                        GlassDivider()
                        WatchTogetherInfoRow(
                            icon: "2.circle.fill",
                            title: "Tap Watch Together",
                            detail: "Use the group button in the player and choose SharePlay."
                        )
                        GlassDivider()
                        WatchTogetherInfoRow(
                            icon: "3.circle.fill",
                            title: "Open the same title",
                            detail: "Each participant resolves and plays their own stream; controls then stay synchronized."
                        )
                    }
                }

                GlassSection(header: "Privacy & Security") {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("SharePlay messages are limited to people in the Apple group session.", systemImage: "lock.shield.fill")
                        Label("SharePlay displays the title; sync messages contain only play, pause, seek, and an opaque media identifier.", systemImage: "arrow.left.arrow.right")
                        Label("Stream URLs, request headers, cookies, subtitles, and provider credentials never leave your device.", systemImage: "eye.slash.fill")
                    }
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.72))
                    .padding(14)
                }

                Text("Requires SharePlay. Eclipse can start an invitation, or join an existing FaceTime or Messages group. Participants need access to the same title in Eclipse.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.48))
                    .padding(.horizontal, 12)
            }
            .padding(.top, 10)
            .padding(.bottom, 30)
        }
        .navigationTitle("Watch Together")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
        .onChange(of: watchTogetherEnabled) { enabled in
            guard !enabled else { return }
            WatchTogetherCoordinator.shared.leaveSession()
        }
    }
}

private struct WatchTogetherInfoRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.green)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                Text(detail)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }
}
#endif

#if os(tvOS)
private struct TVDiagnosticsView: View {
    @StateObject private var network = TVNetworkStatusMonitor()
    @StateObject private var syncManager = MediaStateSyncManager.shared

    var body: some View {
        List {
            Section("Build") {
                LabeledContent("App", value: "Eclipse")
                    .focusable()
                LabeledContent("Version", value: Bundle.main.appVersion)
                    .focusable()
                LabeledContent("Build", value: Bundle.main.buildNumber)
                    .focusable()
            }

            Section("Playback") {
                LabeledContent("Selected Engine", value: PlaybackEngine.selected.displayName)
                    .focusable()
                LabeledContent("MPV Metal", value: MPVTVRenderer.isAvailable ? "Available" : "Unavailable")
                    .focusable()
                LabeledContent("Fallback", value: "AVPlayer")
                    .focusable()
            }

            Section("Status") {
                LabeledContent("Network", value: network.summary)
                    .focusable()
                LabeledContent("Cloud Sync", value: syncManager.phase.title)
                    .focusable()
                if syncManager.lastErrorMessage != nil {
                    LabeledContent("Last Sync Error", value: "CloudKit availability")
                        .focusable()
                }
            }

            Section {
                Text("Provider URLs, authorization tokens, cookies, and request headers are intentionally omitted.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .focusable()
            } header: {
                Text("Privacy")
            }
        }
        .navigationTitle("Diagnostics")
        .accessibilityIdentifier("tv.settings.diagnostics.screen")
    }
}

@MainActor
private final class TVNetworkStatusMonitor: ObservableObject {
    @Published private(set) var summary = "Checking"

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "app.eclipse.tv.network-status")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                switch path.status {
                case .satisfied:
                    self.summary = path.isExpensive ? "Online (constrained route)" : "Online"
                case .requiresConnection:
                    self.summary = "Connection required"
                case .unsatisfied:
                    self.summary = "Offline"
                @unknown default:
                    self.summary = "Unknown"
                }
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}

private struct TVDataSettingsView: View {
    @StateObject private var syncManager = MediaStateSyncManager.shared
    @State private var cacheMessage = ""

    var body: some View {
        List {
            Section {
                Label(syncManager.phase.title, systemImage: syncManager.phase == .ready ? "checkmark.icloud.fill" : "icloud.fill")
                Text(syncManager.phase.message)
                    .font(.footnote)
                    .foregroundColor(.secondary)

                Button(syncManager.phase == .ready ? "Sync Now" : "Retry Sync") {
                    syncManager.syncNow()
                }
            } header: {
                Text("Cloud Sync")
            } footer: {
                Text("Library, playback progress, and TV-safe preferences use your private iCloud database. Service and tracker credentials stay in this Apple TV user's Keychain.")
            }

            Section {
                Button("Reset TV Cache", role: .destructive) {
                    let purgeResult = TVPurgeableCache.clear()
                    syncManager.resetLocalCacheWithoutDeletingRemoteState()
                    cacheMessage = "\(purgeResult) Media state is being restored from iCloud when available."
                }
                if !cacheMessage.isEmpty {
                    Text(cacheMessage)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("This removes temporary artwork, metadata, player files, and the local sync cache. It refetches media state without creating CloudKit deletion records or removing the remote library.")
            }
        }
        .navigationTitle("Cloud Sync & Cache")
    }
}

private enum TVPurgeableCache {
    static func clear() -> String {
        let fileManager = FileManager.default
        guard let cacheDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return "The cache directory is unavailable."
        }

        do {
            for item in try fileManager.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
                try? fileManager.removeItem(at: item)
            }
            URLCache.shared.removeAllCachedResponses()
            return "Purgeable cache cleared."
        } catch {
            Logger.shared.log("tvOS cache clear failed: \(error.localizedDescription)", type: "Storage")
            return "Eclipse could not clear every cache file."
        }
    }
}
#endif

#if canImport(StoreKit)
private enum SupportProductKind {
    case tip
    case subscription
}

private struct SupportProductDefinition {
    let id: String
    let fallbackName: String
    let fallbackPrice: String
    let icon: String
    let color: Color
    let kind: SupportProductKind

    var isConfigured: Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private enum SupportPurchaseCatalog {
    static let definitions: [SupportProductDefinition] = [
        SupportProductDefinition(
            id: "idkbruh",
            fallbackName: "Tip",
            fallbackPrice: "$1",
            icon: "heart.fill",
            color: .pink,
            kind: .tip
        ),
        SupportProductDefinition(
            id: "idkbruh2",
            fallbackName: "Big Tip",
            fallbackPrice: "$5",
            icon: "heart.circle.fill",
            color: .purple,
            kind: .tip
        ),
        SupportProductDefinition(
            id: "idkbruh3",
            fallbackName: "Huge Tip",
            fallbackPrice: "$10",
            icon: "sparkles",
            color: .orange,
            kind: .tip
        ),
        SupportProductDefinition(
            id: "idkbruh4",
            fallbackName: "Monthly Support",
            fallbackPrice: "$3/month",
            icon: "arrow.triangle.2.circlepath.circle.fill",
            color: .cyan,
            kind: .subscription
        )
    ]

    static var productIDs: [String] {
        configuredDefinitions.map(\.id)
    }

    static var configuredProductCount: Int {
        configuredDefinitions.count
    }

    static var configuredDefinitions: [SupportProductDefinition] {
        definitions.filter(\.isConfigured)
    }

    static func definition(for productID: String) -> SupportProductDefinition? {
        definitions.first { $0.id == productID }
    }

    static func order(for productID: String) -> Int {
        definitions.firstIndex { $0.id == productID } ?? Int.max
    }
}

@MainActor
private final class SupportPurchaseStore: ObservableObject {
    @Published private(set) var products: [Product] = []
    @Published private(set) var isLoading = false
    @Published private(set) var purchasingProductID: String?
    @Published private(set) var message: String?

    var hasConfiguredProducts: Bool {
        SupportPurchaseCatalog.configuredProductCount > 0
    }

    func loadProducts() async {
        guard !isLoading, hasConfiguredProducts else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let loadedProducts = try await Product.products(for: SupportPurchaseCatalog.productIDs)
            products = loadedProducts.sorted {
                SupportPurchaseCatalog.order(for: $0.id) < SupportPurchaseCatalog.order(for: $1.id)
            }
            message = products.isEmpty
                ? "StoreKit did not return these products yet. Tap a row to try again."
                : nil
        } catch {
            message = "Unable to load support purchases. Tap a row to try again."
        }
    }

    func reloadProducts() async {
        guard !isLoading else { return }
        products = []
        await loadProducts()
    }

    func purchase(_ product: Product) async {
        purchasingProductID = product.id
        message = nil
        defer { purchasingProductID = nil }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try verifiedTransaction(from: verification)
                await transaction.finish()
                message = "Thanks for supporting Eclipse."
            case .pending:
                message = "Purchase pending approval."
            case .userCancelled:
                message = nil
            @unknown default:
                message = "Purchase could not be completed."
            }
        } catch {
            message = "Purchase could not be completed."
        }
    }

    func restorePurchases() async {
        message = nil
        do {
            try await AppStore.sync()
            message = "Purchases restored."
        } catch {
            message = "Restore could not be completed."
        }
    }

    private func verifiedTransaction(
        from result: VerificationResult<StoreKit.Transaction>
    ) throws -> StoreKit.Transaction {
        switch result {
        case .verified(let transaction):
            return transaction
        case .unverified(_, _):
            throw SupportPurchaseError.unverifiedTransaction
        }
    }
}

#if os(tvOS)
private struct TVSupportSettingsSection: View {
    @StateObject private var store = SupportPurchaseStore()

    var body: some View {
        Group {
            if !Bundle.main.allowsExternalDonationLinks, !store.products.isEmpty {
                Section {
                    NavigationLink("Support Eclipse", destination: StoreKitSupportView())
                } header: {
                    Text("Support")
                } footer: {
                    Text("Purchases use the App Store on this Apple TV. External donation and community links are not shown in the TV app.")
                }
            }
        }
        .task { await store.loadProducts() }
    }
}
#endif

private enum SupportPurchaseError: Error {
    case unverifiedTransaction
}

private let supportTermsOfUseURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
private let supportPrivacyPolicyURL = URL(string: "https://soupy-dev.github.io/Eclipse/privacy-policy/")!

private struct StoreKitSupportView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                GlassSection(header: "Support") {
                    StoreKitSupportSection()
                }

                GlassSectionFooter("Support purchases are optional and do not unlock features.")

                GlassSection(header: "Legal") {
                    VStack(spacing: 0) {
                        storeLinkRow(title: "Terms of Use (EULA)", icon: "doc.text.fill", color: .blue, url: supportTermsOfUseURL)
                        GlassDivider(leadingInset: 16)
                        storeLinkRow(title: "Privacy Policy", icon: "hand.raised.fill", color: .teal, url: supportPrivacyPolicyURL)
                    }
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("Support Eclipse")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
    }

    private func storeLinkRow(title: String, icon: String, color: Color, url: URL) -> some View {
#if os(tvOS)
        VStack(alignment: .leading, spacing: 12) {
            GlassDetailRow(icon: icon, iconColor: color, title: title) {
                Text("Scan QR")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
            }

            HStack(spacing: 18) {
                if let image = supportQRCode(for: url) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 150, height: 150)
                        .background(Color.white)
                        .accessibilityLabel("QR code for \(title)")
                }
                Text(url.absoluteString)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.68))
                    .lineLimit(4)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
#else
        Link(destination: url) {
            GlassDetailRow(icon: icon, iconColor: color, title: title) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .buttonStyle(.plain)
#endif
    }

#if os(tvOS)
    private func supportQRCode(for url: URL) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
#endif
}

private struct StoreKitSupportSection: View {
    @StateObject private var store = SupportPurchaseStore()

    var body: some View {
        VStack(spacing: 0) {
            Text("Choose an optional way to support Eclipse.")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            GlassDivider(leadingInset: 14)

            if !store.hasConfiguredProducts {
                SupportPurchaseStatusRow(
                    icon: "exclamationmark.triangle.fill",
                    color: .orange,
                    title: "Tips Unavailable",
                    subtitle: "Product IDs need to be configured."
                )
            } else if store.isLoading && store.products.isEmpty {
                SupportPurchaseStatusRow(
                    icon: "hourglass",
                    color: .blue,
                    title: "Loading Tips",
                    subtitle: "Checking App Store availability."
                )
            } else if store.products.isEmpty {
                ForEach(Array(SupportPurchaseCatalog.configuredDefinitions.enumerated()), id: \.element.id) { index, definition in
                    Button {
                        Task { await store.reloadProducts() }
                    } label: {
                        StoreKitSupportPreviewRow(definition: definition)
                    }
                    .buttonStyle(.plain)

                    if index < SupportPurchaseCatalog.configuredProductCount - 1 {
                        GlassDivider()
                    }
                }

                GlassDivider(leadingInset: 14)

                Text("Prices load from the App Store when these purchases become available.")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.56))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(store.products.enumerated()), id: \.element.id) { index, product in
                    StoreKitSupportButton(product: product, store: store)

                    if index < store.products.count - 1 {
                        GlassDivider()
                    }
                }

                GlassDivider()

                Button {
                    Task { await store.restorePurchases() }
                } label: {
                    GlassSettingsRow(icon: "arrow.clockwise.circle.fill", iconColor: .green, title: "Restore Purchases") {
                        Text("Optional")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                .buttonStyle(.plain)
            }

            if let message = store.message, !message.isEmpty {
                GlassDivider(leadingInset: 14)
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.56))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
        .task {
            await store.loadProducts()
        }
    }
}

private struct StoreKitSupportPreviewRow: View {
    let definition: SupportProductDefinition

    var body: some View {
        GlassSettingsRow(icon: definition.icon, iconColor: definition.color, title: definition.fallbackName) {
            HStack(spacing: 6) {
                Text(definition.fallbackPrice)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.32))
            }
        }
    }
}

private struct StoreKitSupportButton: View {
    let product: Product
    @ObservedObject var store: SupportPurchaseStore

    private var definition: SupportProductDefinition? {
        SupportPurchaseCatalog.definition(for: product.id)
    }

    private var isPurchasing: Bool {
        store.purchasingProductID == product.id
    }

    private var displayTitle: String {
        product.displayName.isEmpty ? (definition?.fallbackName ?? "Tip") : product.displayName
    }

    private var priceText: String {
        guard let period = product.subscription?.subscriptionPeriod else {
            return product.displayPrice
        }
        return "\(product.displayPrice) / \(period.billingUnitText)"
    }

    private var subscriptionLengthText: String? {
        product.subscription?.subscriptionPeriod.renewalLengthText
    }

    var body: some View {
        Button {
            Task { await store.purchase(product) }
        } label: {
            GlassSettingsRow(
                icon: definition?.icon ?? "heart.fill",
                iconColor: definition?.color ?? .pink,
                title: displayTitle
            ) {
                HStack(spacing: 6) {
                    if isPurchasing {
                        EclipseLoadingIndicator(diameter: 16)
                    }

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(isPurchasing ? "Purchasing" : priceText)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)

                        if !isPurchasing, let subscriptionLengthText {
                            Text(subscriptionLengthText)
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.42))
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isPurchasing || store.purchasingProductID != nil)
    }
}

private extension Product.SubscriptionPeriod {
    var billingUnitText: String {
        switch unit {
        case .day:
            return value == 1 ? "day" : "\(value) days"
        case .week:
            return value == 1 ? "week" : "\(value) weeks"
        case .month:
            return value == 1 ? "month" : "\(value) months"
        case .year:
            return value == 1 ? "year" : "\(value) years"
        @unknown default:
            return value == 1 ? "period" : "\(value) periods"
        }
    }

    var renewalLengthText: String {
        switch unit {
        case .day:
            return value == 1 ? "Renews daily" : "Renews every \(value) days"
        case .week:
            return value == 1 ? "Renews weekly" : "Renews every \(value) weeks"
        case .month:
            return value == 1 ? "Renews monthly" : "Renews every \(value) months"
        case .year:
            return value == 1 ? "Renews yearly" : "Renews every \(value) years"
        @unknown default:
            return value == 1 ? "Auto-renewable" : "Renews every \(value) periods"
        }
    }
}

private struct SupportPurchaseStatusRow: View {
    let icon: String
    let color: Color
    let title: String
    let subtitle: String

    var body: some View {
        GlassSettingsRow(icon: icon, iconColor: color, title: title) {
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.5))
        }
    }
}

#endif

struct ScheduleSettingsView: View {
    @AppStorage("defaultScheduleMode") private var defaultScheduleModeRaw = ScheduleMode.anime.rawValue
    @StateObject private var accentColorManager = AccentColorManager.shared

    private var selectedMode: ScheduleMode {
        ScheduleMode.sanitized(defaultScheduleModeRaw)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                GlassSection(header: "Schedule Tab") {
                    VStack(spacing: 0) {
                        ForEach(Array(ScheduleMode.allCases.enumerated()), id: \.element.id) { index, mode in
                            GlassSelectionRow(
                                title: mode.displayName,
                                subtitle: mode.description,
                                isSelected: selectedMode == mode,
                                accent: accentColorManager.currentAccentColor
                            ) {
                                defaultScheduleModeRaw = mode.rawValue
                            }

                            if index < ScheduleMode.allCases.count - 1 {
                                GlassDivider(leadingInset: 16)
                            }
                        }
                    }
                }

                GlassSectionFooter("Choose which schedule opens first when you select the Schedule tab. You can still switch modes inside the tab.")
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("Schedule")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
    }
}

struct LegalNoticeView: View {
    let sourceCodeURL: URL
    let originalProjectURL: URL
    let licenseURL: URL
    let privacyPolicyURL: URL

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                GlassSection(header: "License") {
                    VStack(spacing: 0) {
                        infoText("Eclipse is released under the GNU General Public License version 3.")
                        GlassDivider(leadingInset: 16)
                        linkRow(title: "View GPLv3 License", icon: "doc.plaintext.fill", color: .blue, url: licenseURL)
                    }
                }

                GlassSection(header: "Privacy") {
                    VStack(spacing: 0) {
                        infoText("Eclipse's privacy policy explains what data the app stores locally and how optional third-party services are handled.")
#if os(tvOS)
                        GlassDivider(leadingInset: 16)
                        infoText("On Apple TV, media state may sync through your private iCloud database. Tracker tokens and token-bearing addon URLs stay in the active Apple TV user's Keychain and are excluded from CloudKit, diagnostics, and backups. Eclipse adds no analytics SDK.")
#endif
                        GlassDivider(leadingInset: 16)
                        linkRow(title: "Privacy Policy", icon: "hand.raised.fill", color: .teal, url: privacyPolicyURL)
                    }
                }

                GlassSection(header: "Source") {
                    VStack(spacing: 0) {
                        infoText("Eclipse is a GPL-licensed media app with substantial original changes by Soupy-dev.")
                        GlassDivider(leadingInset: 16)
                        linkRow(title: "Eclipse Source Code", icon: "chevron.left.forwardslash.chevron.right", color: .cyan, url: sourceCodeURL)
                        GlassDivider()
                        linkRow(title: "Original Upstream Project", icon: "arrow.up.right.square.fill", color: .indigo, url: originalProjectURL)
                    }
                }

#if !os(tvOS)
                GlassSection(header: "Credits") {
                    VStack(spacing: 0) {
                        infoText("Reader mode includes Aidoku source compatibility work inspired by the Aidoku project.")
                        GlassDivider(leadingInset: 16)
                        linkRow(title: "Aidoku/Aidoku", icon: "book.fill", color: .orange, url: URL(string: "https://github.com/Aidoku/Aidoku")!)
                    }
                }
#endif

                GlassSection(header: "Warranty") {
                    infoText("This program comes with no warranty, to the extent permitted by law.")
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("Legal & Source")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
    }

    private func infoText(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundColor(.white.opacity(0.7))
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }

    private func linkRow(title: String, icon: String, color: Color, url: URL) -> some View {
#if os(tvOS)
        VStack(alignment: .leading, spacing: 12) {
            GlassDetailRow(icon: icon, iconColor: color, title: title) {
                Text("Scan QR")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.5))
            }

            HStack(spacing: 18) {
                if let image = qrCode(for: url) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 150, height: 150)
                        .background(Color.white)
                        .accessibilityLabel("QR code for \(title)")
                }

                Text(url.absoluteString)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.68))
                    .lineLimit(4)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
#else
        Link(destination: url) {
            GlassDetailRow(icon: icon, iconColor: color, title: title) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .buttonStyle(.plain)
#endif
    }

#if os(tvOS)
    private func qrCode(for url: URL) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
#endif
}

struct PerformanceModeSettingsView: View {
    @ObservedObject private var catalogManager = CatalogManager.shared
    @AppStorage(PerformanceModeSettings.skipAniListTraversalForAnimeDetailsKey) private var skipAniListTraversalForAnimeDetails = false
    @StateObject private var accentColorManager = AccentColorManager.shared

    private var accent: Color { accentColorManager.currentAccentColor }

    private var performanceModeBinding: Binding<Bool> {
        Binding(
            get: { catalogManager.performanceModeEnabled },
            set: { catalogManager.setPerformanceModeEnabled($0) }
        )
    }

    private var animeCatalogs: [Catalog] {
        catalogManager.catalogs.filter { PerformanceModeSettings.isAnimeCatalog($0) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                GlassSection {
                    GlassDetailRow(icon: "bolt.fill", iconColor: .yellow, title: "Performance Mode") {
                        Toggle("", isOn: performanceModeBinding)
                            .labelsHidden()
                            .tint(accent)
                    }
                }
                GlassSectionFooter("Performance Mode keeps anime-heavy home catalogs on the faster AniList-backed path and locks those anime catalog rows to their performance-safe source. Detail pages still load full metadata when opened.")

                GlassSection {
                    GlassDetailRow(icon: "hare.fill", iconColor: .orange, title: "Skip AniList Traversal for Anime Details") {
                        Toggle("", isOn: $skipAniListTraversalForAnimeDetails)
                            .labelsHidden()
                            .tint(accent)
                    }
                }
                GlassSectionFooter("Some anime services, season mappings, specials, OVAs, and tracker matching may be less accurate or unavailable.")

                if !animeCatalogs.isEmpty {
                    GlassSection(header: "Affected Catalogs") {
                        VStack(spacing: 0) {
                            ForEach(Array(animeCatalogs.enumerated()), id: \.element.id) { index, catalog in
                                GlassDetailRow(icon: "bolt.fill", iconColor: .yellow, title: catalog.name) {
                                    Text(catalogManager.isCatalogEffectivelyEnabled(catalog) ? "Enabled" : "Hidden")
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.5))
                                }

                                if index < animeCatalogs.count - 1 {
                                    GlassDivider()
                                }
                            }
                        }
                    }
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("Performance Mode")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
    }
}

#if !os(tvOS)
struct ExperimentalCloudSyncView: View {
    @AppStorage(ExperimentalFeatureState.iCloudSyncEnabledKey) private var iCloudSyncEnabled = false
    @AppStorage(CloudSyncProvider.googleDrive.syncEnabledKey) private var googleDriveSyncEnabled = false
    @AppStorage(CloudSyncProvider.oneDrive.syncEnabledKey) private var oneDriveSyncEnabled = false
    @StateObject private var cloudSyncManager = ExperimentalCloudSyncManager.shared
    @StateObject private var accentColorManager = AccentColorManager.shared

    private var availability: ExperimentalCloudSyncAvailability {
        ExperimentalCloudSyncAvailability.current
    }

    private var accent: Color { accentColorManager.currentAccentColor }

    private var includedData: [(String, String)] {
        [
            ("Settings", "gearshape"),
            ("Libraries and collections", "books.vertical"),
            ("Watch and read progress", "play.rectangle"),
            ("Catalogs, services, and addons", "server.rack"),
            ("Tracker connections and preferences", "chart.bar")
        ]
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                GlassSection {
                    HStack(spacing: 14) {
                        Image(systemName: "cloud.fill")
                            .font(.title2)
                            .foregroundColor(accent)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Cloud Sync")
                                .font(.headline)
                                .foregroundColor(.white)
                            Text("Sync selected Eclipse data through iCloud, Google Drive, or OneDrive.")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.55))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }

                providerSection(.iCloud)
                providerSection(.googleDrive)
                providerSection(.oneDrive)

                GlassSection(header: "Notice") {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title3)
                            .foregroundColor(.orange)
                            .frame(width: 30)

                        Text("Eclipse is not responsible for changes, loss, restrictions, suspension, or other issues affecting your chosen cloud service. Use Cloud Sync at your own risk. iCloud, Google Drive, OneDrive, Apple, Google, and Microsoft are trademarks of their respective owners and are not affiliated with Eclipse.")
                            .font(.footnote)
                            .foregroundColor(.white.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }

                GlassSectionFooter("Downloaded media, preload caches, images, logs, temporary files, cloud account tokens, and unsafe source secrets are excluded.")

                GlassSection(header: "Included Data") {
                    VStack(spacing: 0) {
                        ForEach(Array(includedData.enumerated()), id: \.offset) { index, item in
                            GlassDetailRow(icon: item.1, iconColor: .blue, title: item.0) {
                                EmptyView()
                            }

                            if index < includedData.count - 1 {
                                GlassDivider()
                            }
                        }
                    }
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .navigationTitle("Cloud Sync")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
        .onAppear {
            if !availability.isAvailable, iCloudSyncEnabled {
                iCloudSyncEnabled = false
            }
        }
        .onChange(of: iCloudSyncEnabled) { enabled in
            if enabled {
                cloudSyncManager.syncSnapshot(provider: .iCloud, reason: "enabled")
            }
        }
        .onChange(of: googleDriveSyncEnabled) { enabled in
            if enabled {
                cloudSyncManager.syncSnapshot(provider: .googleDrive, reason: "enabled")
            }
        }
        .onChange(of: oneDriveSyncEnabled) { enabled in
            if enabled {
                cloudSyncManager.syncSnapshot(provider: .oneDrive, reason: "enabled")
            }
        }
    }

    @ViewBuilder
    private func providerSection(_ provider: CloudSyncProvider) -> some View {
        let connected = cloudSyncManager.isProviderConnected(provider)
        let enabled = syncEnabled(for: provider)
        let canUse = cloudSyncManager.canUseProvider(provider)

        GlassSection(header: provider.displayName) {
            VStack(spacing: 0) {
                GlassDetailRow(icon: provider.iconName, iconColor: providerColor(provider), title: providerTitle(provider)) {
                    Text(providerStateText(provider, connected: connected, enabled: enabled))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(providerStateColor(provider, connected: connected, enabled: enabled))
                }

                if provider.requiresAccountConnection {
                    GlassDivider()

                    Button {
                        if connected {
                            cloudSyncManager.disconnectProvider(provider)
                        } else {
                            cloudSyncManager.connectProvider(provider)
                        }
                    } label: {
                        GlassDetailRow(
                            icon: connected ? "xmark.circle" : "link",
                            iconColor: connected ? .red : providerColor(provider),
                            title: connected ? "Disconnect" : "Connect"
                        ) {
                            providerAccessory(provider)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(cloudSyncManager.isSyncing)
                }

                GlassDivider()

                GlassDetailRow(icon: "arrow.triangle.2.circlepath", iconColor: providerColor(provider), title: "Sync with \(provider.displayName)") {
                    Toggle("", isOn: syncBinding(for: provider))
                        .labelsHidden()
                        .tint(accent)
                        .disabled(!canUse || cloudSyncManager.isSyncing)
                }

                GlassDivider()

                Button {
                    cloudSyncManager.syncSnapshot(provider: provider, reason: "manual")
                } label: {
                    GlassDetailRow(icon: "arrow.up.doc", iconColor: .cyan, title: "Sync Now") {
                        providerAccessory(provider)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!enabled || !canUse || cloudSyncManager.isSyncing)

                GlassDivider()

                Button {
                    cloudSyncManager.restoreRemoteSnapshot(provider: provider)
                } label: {
                    GlassDetailRow(icon: "arrow.down.doc", iconColor: .indigo, title: "Restore from \(provider.displayName)") {
                        providerAccessory(provider)
                    }
                }
                .buttonStyle(.plain)
                .disabled(!enabled || !canUse || cloudSyncManager.isSyncing)

                let status = cloudSyncManager.statusMessage(for: provider)
                if !status.isEmpty {
                    GlassDivider(leadingInset: 16)
                    Text(status)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                } else if provider == .iCloud && !availability.isAvailable {
                    GlassDivider(leadingInset: 16)
                    Text(availability.statusMessage)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
            }
        }
    }

    @ViewBuilder
    private func providerAccessory(_ provider: CloudSyncProvider) -> some View {
        if cloudSyncManager.isBusy(provider) {
            EclipseLoadingIndicator()
                .tint(.white.opacity(0.6))
        } else {
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.3))
        }
    }

    private func providerTitle(_ provider: CloudSyncProvider) -> String {
        switch provider {
        case .iCloud:
            return availability.statusTitle
        case .googleDrive, .oneDrive:
            return provider.displayName
        }
    }

    private func providerStateText(_ provider: CloudSyncProvider, connected: Bool, enabled: Bool) -> String {
        switch provider {
        case .iCloud:
            guard connected else { return "Unavailable" }
            return enabled ? "On" : "Off"
        case .googleDrive, .oneDrive:
            guard connected else { return "Not Connected" }
            return enabled ? "On" : "Connected"
        }
    }

    private func providerStateColor(_ provider: CloudSyncProvider, connected: Bool, enabled: Bool) -> Color {
        guard connected else { return .orange }
        return enabled ? .green : .white.opacity(0.55)
    }

    private func providerColor(_ provider: CloudSyncProvider) -> Color {
        switch provider {
        case .iCloud:
            return .blue
        case .googleDrive:
            return .green
        case .oneDrive:
            return .cyan
        }
    }

    private func syncEnabled(for provider: CloudSyncProvider) -> Bool {
        switch provider {
        case .iCloud:
            return iCloudSyncEnabled
        case .googleDrive:
            return googleDriveSyncEnabled
        case .oneDrive:
            return oneDriveSyncEnabled
        }
    }

    private func syncBinding(for provider: CloudSyncProvider) -> Binding<Bool> {
        switch provider {
        case .iCloud:
            return $iCloudSyncEnabled
        case .googleDrive:
            return $googleDriveSyncEnabled
        case .oneDrive:
            return $oneDriveSyncEnabled
        }
    }
}
#endif
