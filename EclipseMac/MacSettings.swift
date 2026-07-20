import AppKit
import StoreKit
import SwiftUI
import UserNotifications

struct MacSettingsView: View {
    @EnvironmentObject private var reader: MacReaderController
    @EnvironmentObject private var services: MacStremioStore
    @EnvironmentObject private var legacyServices: MacLegacyServiceStore
    @EnvironmentObject private var cloudLibrary: MacCloudLibrarySync
    @EnvironmentObject private var trackers: MacTrackerStore
    @EnvironmentObject private var aidoku: MacAidokuStore
    @EnvironmentObject private var mediaState: MacMediaStateStore
    @AppStorage("macPlayerSeekSeconds") private var seekSeconds = 10.0
    @AppStorage("defaultPlaybackSpeed") private var defaultPlaybackSpeed = 1.0
    @AppStorage("enableSubtitlesByDefault") private var enableSubtitlesByDefault = false
    @AppStorage("defaultSubtitleLanguage") private var defaultSubtitleLanguage = "eng"
    @AppStorage("preferredAutoAudioLanguage") private var preferredAudioLanguage = "eng"
    @AppStorage("subtitles_fontSize") private var subtitleFontSize = 30.0
    @AppStorage("subtitles_strokeWidth") private var subtitleStrokeWidth = 1.0
    @AppStorage("playerSubtitleOverlayBottomConstant") private var subtitleVerticalOffset = -6.0
    @AppStorage("subtitles_closedCaptionBackground") private var subtitleBackgroundEnabled = false
    @AppStorage("mpvPictureInPictureEnabled") private var pictureInPictureEnabled = true
    @AppStorage("mpvPlayerSkin") private var playerSkin = "default"
    @AppStorage("mpvPlayerSkinTintControlsOnly") private var playerSkinTintControlsOnly = false
    @AppStorage("experimentalMPVShowRemainingTime") private var showRemainingTime = true
    @AppStorage("experimentalMPVPreciseProgress") private var preciseProgress = true
    @AppStorage("experimentalMPVIgnoreSpecialSubtitleStyles") private var ignoreEmbeddedSubtitleStyles = false
    @AppStorage("audioComfortMode") private var audioComfortMode = "original"
    @AppStorage("macMPVStreamCacheEnabled") private var streamCacheEnabled = true
    @AppStorage("macMPVStreamCacheLimitMB") private var streamCacheLimitMB = 128
    @AppStorage("mpvHDRMode") private var hdrMode = "auto"
    @AppStorage("mpvMetalQualityProfile") private var qualityProfile = "auto"
    @AppStorage("mpvUpscalingMode") private var upscalingMode = "off"
    @AppStorage("appearancePalette") private var appearancePalette = "midnightPurple"
    @AppStorage("atmosphereStyle") private var atmosphereStyle = "multiGradient"
    @AppStorage("appearanceBleedStrength") private var appearanceBleedStrength = 1.0
    @AppStorage("appearanceBackgroundIntensity") private var backgroundIntensity = 1.0
    @AppStorage("homeAnimatedBackgroundEnabled") private var animatedBackgroundEnabled = true
    @AppStorage("homeAnimatedBackgroundQuality") private var animatedBackgroundQuality = "low"
    @AppStorage("homeAnimatedBackgroundFrameRate") private var animatedBackgroundFrameRate = "fps20"
    @AppStorage("experimentalMediaDesignPreset") private var designPreset = "cinematic"
    @AppStorage("experimentalHomeCardShape") private var homeCardShape = "automatic"
    @AppStorage("experimentalMediaCardScale") private var mediaCardScale = 1.0
    @AppStorage("experimentalHeroHeightScale") private var heroHeightScale = 1.0
    @AppStorage("experimentalSectionSpacingScale") private var sectionSpacingScale = 1.0
    @AppStorage("experimentalCardRadiusScale") private var cardRadiusScale = 1.0
    @AppStorage("heroBannerCatalogId") private var heroBannerCatalogID = MacHomeCatalogID.trending.rawValue
    @AppStorage("heroBannerBehavior") private var heroBannerBehavior = "carousel"
    @AppStorage("performanceModeEnabled") private var performanceModeEnabled = true
    @AppStorage("defaultScheduleMode") private var defaultScheduleMode = "anime"
    @AppStorage("scheduleWindowDays") private var scheduleWindowDays = 7
    @AppStorage("localNotificationEpisodeLeadTime") private var episodeLeadTime = 0
    @AppStorage("localNotificationSeasonLeadTime") private var seasonLeadTime = 86_400
    @AppStorage("localNotificationIncludeAnimeSpecials") private var includeAnimeSpecials = false
    @AppStorage("macScheduleNotificationsEnabled") private var scheduleNotificationsEnabled = false
    @AppStorage("macHomeShowTrending") private var showTrending = true
    @AppStorage("macHomeShowTrendingAnime") private var showTrendingAnime = true
    @AppStorage("macHomeShowPopularMovies") private var showPopularMovies = true
    @AppStorage("macHomeShowPopularAnime") private var showPopularAnime = true
    @AppStorage("macHomeShowPopularShows") private var showPopularShows = true
    @AppStorage("macHomeShowAiringAnime") private var showAiringAnime = false
    @AppStorage("macHomeShowUpcomingAnime") private var showUpcomingAnime = false
    @AppStorage("macHomeShowTopRated") private var showTopRated = true
    @AppStorage("macHomeShowTopRatedAnime") private var showTopRatedAnime = true
    @AppStorage("macHomeCatalogOrder") private var homeCatalogOrderRaw = MacHomeCatalogID.allCases.map(\.rawValue).joined(separator: ",")
    @AppStorage("autoUpdateServicesEnabled") private var autoUpdateServices = true
    @AppStorage("servicesAutoModeEnabled") private var autoModeEnabled = false
    @AppStorage("servicesAutoModeQualityPreference") private var autoQualityPreference = "auto"
    @AppStorage("servicesResultMinimumSimilarity") private var resultSimilarity = 0.85
    @AppStorage("servicesDropMismatchedResults") private var dropMismatchedResults = true
    @AppStorage("servicesHideStreamsWithoutLanguageData") private var hideUnknownLanguage = false
    @AppStorage("servicesHideStreamsWithoutDetectedQuality") private var hideUnknownQuality = false
    @AppStorage("macTrackerSyncEnabled") private var trackerSyncEnabled = true
    @AppStorage("macTrackerAutoSyncRatings") private var trackerAutoSyncRatings = false
    @AppStorage("macTrackerReaderSyncEnabled") private var trackerReaderSyncEnabled = true
    @AppStorage("macLiveTraktScrobbling") private var liveTraktScrobbling = true
    @AppStorage("autoClearCacheEnabled") private var autoClearCache = false
    @AppStorage("autoClearCacheThresholdMB") private var cacheThreshold = 500.0
    @AppStorage("readerFontSize") private var readerFontSize = 16.0
    @AppStorage("readerFontFamily") private var readerFontFamily = "-apple-system"
    @AppStorage("readerFontWeight") private var readerFontWeight = "normal"
    @AppStorage("readerTextAlignment") private var readerTextAlignment = "left"
    @AppStorage("readerLineSpacing") private var readerLineSpacing = 1.6
    @AppStorage("readerMargin") private var readerMargin = 4.0
    @State private var navigationPath: [SettingsDestination] = []
    @State private var searchText = ""
    @State private var pendingSearchAnchor: String?
    @State private var addonURL = ""
    @State private var legacyServiceURL = ""
    @State private var aidokuListURL = ""
    @State private var notificationStatus = "Checking…"
    @State private var storageSummary = "Calculating…"
    @State private var backupMessage: String?
    @State private var logText = ""
    @State private var cloudAccountStatus = "Checking…"
    @State private var selectedAutoModeSourceIDs = Set(UserDefaults.standard.stringArray(forKey: "servicesAutoModeSourceIds") ?? [])
    @State private var autoModeSourceOrderIDs = UserDefaults.standard.stringArray(forKey: "servicesAutoModeSourceOrderIds") ?? []
    @State private var includedLanguagesText = (UserDefaults.standard.stringArray(forKey: "servicesIncludedStreamLanguages") ?? []).joined(separator: ", ")
    @State private var hiddenLanguagesText = (UserDefaults.standard.stringArray(forKey: "servicesHiddenStreamLanguages") ?? []).joined(separator: ", ")
    @State private var hiddenQualityHeights = Set((UserDefaults.standard.array(forKey: "servicesHiddenStreamQualities") ?? []).compactMap { ($0 as? NSNumber)?.intValue })

    var body: some View {
        NavigationStack(path: $navigationPath) {
            settingsRoot
                .navigationDestination(for: SettingsDestination.self) { destination in
                    settingsDetail(destination)
                }
        }
        .task {
            normalizeAppearanceSettingsIfNeeded()
            normalizeLegacyNotificationTimingIfNeeded()
        }
        .onChange(of: scheduleNotificationsEnabled) { _, _ in
            Task { await MacCatalogStore.shared.syncScheduleNotifications() }
        }
        .onChange(of: defaultScheduleMode) { _, _ in
            Task { await MacCatalogStore.shared.syncScheduleNotifications() }
        }
        .onChange(of: scheduleWindowDays) { _, _ in
            Task { await MacCatalogStore.shared.syncScheduleNotifications() }
        }
        .onChange(of: episodeLeadTime) { _, _ in
            Task { await MacCatalogStore.shared.syncScheduleNotifications() }
        }
        .onChange(of: seasonLeadTime) { _, _ in
            Task { await MacCatalogStore.shared.syncScheduleNotifications() }
        }
        .onChange(of: includeAnimeSpecials) { _, _ in
            Task { await MacCatalogStore.shared.syncScheduleNotifications() }
        }
        .onChange(of: includedLanguagesText) { _, value in
            UserDefaults.standard.set(sanitizedLanguageTokens(value), forKey: "servicesIncludedStreamLanguages")
        }
        .onChange(of: hiddenLanguagesText) { _, value in
            UserDefaults.standard.set(sanitizedLanguageTokens(value), forKey: "servicesHiddenStreamLanguages")
        }
        .onChange(of: homeCatalogVisibilitySignature) { _, _ in
            ensureHeroCatalogIsEnabled()
        }
    }

    private var settingsRoot: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Settings")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                    Text("Make Eclipse feel right on this Mac.")
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search settings", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear Search")
                    }
                }
                .padding(.horizontal, 13)
                .frame(height: 38)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(.white.opacity(0.09), lineWidth: 1)
                }

                if trimmedSearchText.isEmpty {
                    ForEach(SettingsDestination.groups, id: \.name) { group in
                        settingsDestinationGroup(group.name, destinations: group.items)
                    }
                } else if matchingSearchItems.isEmpty && matchingDestinations.isEmpty {
                    ContentUnavailableView(
                        "No Settings Found",
                        systemImage: "magnifyingglass",
                        description: Text("No setting matches “\(trimmedSearchText)”.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 55)
                } else {
                    searchResults
                }
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 26)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .navigationTitle("Settings")
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matchingDestinations: [SettingsDestination] {
        SettingsDestination.ordered.filter {
            $0.searchText.localizedCaseInsensitiveContains(trimmedSearchText)
        }
    }

    private var matchingSearchItems: [MacSettingsSearchItem] {
        MacSettingsSearchItem.all.filter {
            $0.searchText.localizedCaseInsensitiveContains(trimmedSearchText)
        }
    }

    private func settingsDestinationGroup(_ title: String, destinations: [SettingsDestination]) -> some View {
        MacSettingsGroup(title) {
            ForEach(Array(destinations.enumerated()), id: \.element.id) { index, destination in
                NavigationLink(value: destination) {
                    MacSettingsRow(
                        icon: destination.icon,
                        color: destination.color,
                        title: destination.title,
                        detail: destination.subtitle
                    ) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                if index < destinations.count - 1 { MacSettingsDivider() }
            }
        }
    }

    private var searchResults: some View {
        VStack(spacing: 18) {
            if !matchingSearchItems.isEmpty {
                MacSettingsGroup("Settings") {
                    ForEach(Array(matchingSearchItems.enumerated()), id: \.element.id) { index, item in
                        Button {
                            pendingSearchAnchor = item.anchor
                            navigationPath.append(item.destination)
                        } label: {
                            MacSettingsRow(
                                icon: item.destination.icon,
                                color: item.destination.color,
                                title: item.title,
                                detail: "\(item.destination.title) · \(item.detail)"
                            ) {
                                Image(systemName: "arrow.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                        if index < matchingSearchItems.count - 1 { MacSettingsDivider() }
                    }
                }
            }

            let exactDestinationIDs = Set(matchingSearchItems.map(\.destination.id))
            let categoryMatches = matchingDestinations.filter { !exactDestinationIDs.contains($0.id) }
            if !categoryMatches.isEmpty {
                settingsDestinationGroup("Categories", destinations: categoryMatches)
            }
        }
    }

    private func settingsDetail(_ destination: SettingsDestination) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    settingsPageHeader(destination)
                    selectedPage(destination)
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 26)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .navigationTitle(destination.title)
            .task {
                await prepare(destination)
                guard let anchor = pendingSearchAnchor else { return }
                await Task.yield()
                withAnimation(.easeOut(duration: 0.24)) {
                    proxy.scrollTo(anchor, anchor: .top)
                }
                pendingSearchAnchor = nil
            }
        }
    }

    private func settingsPageHeader(_ destination: SettingsDestination) -> some View {
        HStack(spacing: 15) {
            ZStack {
                Circle().fill(destination.color.opacity(0.28))
                Image(systemName: destination.icon).font(.system(size: 22, weight: .semibold)).foregroundStyle(destination.color)
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(destination.title).font(.system(size: 30, weight: .bold, design: .rounded))
                Text(destination.subtitle).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func selectedPage(_ destination: SettingsDestination) -> some View {
        switch destination {
        case .support: supportPage
        case .player: playerPage
        case .appearance: appearancePage
        case .performance: performancePage
        case .schedule: schedulePage
        case .notifications: notificationsPage
        case .catalogs: catalogsPage
        case .services: servicesPage
        case .trackers: trackersPage
        case .storage: storagePage
        case .backup: backupPage
        case .cloud: cloudPage
        case .logger: loggerPage
        case .reader: readerPage
        case .readerSources: readerSourcesPage
        case .legal: legalPage
        }
    }

    @MainActor
    private func prepare(_ destination: SettingsDestination) async {
        switch destination {
        case .notifications:
            await refreshNotificationStatus()
        case .storage:
            await refreshStorageSummary()
        case .cloud:
            cloudAccountStatus = await cloudLibrary.accountStatusLabel()
        case .logger:
            logText = await Logger.shared.getLogsAsync()
        case .services:
            initializeAutoModeSourcesIfNeeded()
        default:
            break
        }
    }

    private var supportPage: some View { MacSupportView() }

    private var playerPage: some View {
        VStack(spacing: 18) {
            MacSettingsGroup("Playback") {
                settingPicker("Default Playback Speed", detail: "Speed used when a video starts.", icon: "speedometer", color: .cyan, selection: $defaultPlaybackSpeed, values: [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]) { String(format: "%.2gx", $0) }
                MacSettingsDivider()
                MacSettingsRow(icon: "gobackward", color: .blue, title: "Seek Amount", detail: "Used by player buttons and the left/right arrow keys.") {
                    Stepper("\(Int(seekSeconds)) sec", value: $seekSeconds, in: 5...60, step: 5).frame(width: 125)
                }
                MacSettingsDivider()
                settingToggle("Precise Seeking", detail: "Scrub in tenths of a second and use Option–Left/Right for one-second keyboard seeks.", icon: "scope", color: .mint, isOn: $preciseProgress)
                MacSettingsDivider()
                settingToggle("Show Remaining Time", detail: "Show time left beside the player timeline instead of total duration.", icon: "timer", color: .orange, isOn: $showRemainingTime)
                MacSettingsDivider()
                settingToggle("Picture in Picture", detail: "Show PiP controls when the stream and renderer support them.", icon: "pip", color: .purple, isOn: $pictureInPictureEnabled)
            }
            .id(MacSettingsAnchor.playerPlayback)
            MacSettingsGroup("Player Style") {
                stringPickerRow("Player Skin", detail: "Use Eclipse's player color presets for the timeline and playback controls.", icon: "paintpalette.fill", color: .pink, selection: $playerSkin, values: [("default", "Default"), ("blackAndGold", "Black & Gold"), ("prismatic", "Prismatic"), ("cyberpunk", "Cyberpunk")])
                if playerSkin != "default" {
                    MacSettingsDivider()
                    settingToggle("Tint Controls Only", detail: "Keep the black control backdrop while applying the skin to buttons and the timeline.", icon: "slider.horizontal.3", color: .cyan, isOn: $playerSkinTintControlsOnly)
                }
            }
            .id(MacSettingsAnchor.playerStyle)
            MacSettingsGroup("Subtitles & Audio") {
                settingToggle("Enable Subtitles by Default", detail: "Automatically select subtitles when available.", icon: "captions.bubble.fill", color: .indigo, isOn: $enableSubtitlesByDefault)
                MacSettingsDivider()
                languageRow("Default Subtitle Language", icon: "captions.bubble", selection: $defaultSubtitleLanguage)
                MacSettingsDivider()
                languageRow("Auto Audio Language", icon: "waveform", selection: $preferredAudioLanguage)
                MacSettingsDivider()
                stringPickerRow("Comfort Audio", detail: comfortAudioDetail, icon: "waveform.badge.magnifyingglass", color: .orange, selection: $audioComfortMode, values: [("original", "Original"), ("comfort", "Comfort"), ("dialogue", "Dialogue"), ("night", "Night")])
            }
            .id(MacSettingsAnchor.playerLanguages)
            MacSettingsGroup("Subtitle Appearance") {
                settingPicker("Font Size", detail: "Subtitle size used by the Mac MPV renderer.", icon: "textformat.size", color: .cyan, selection: $subtitleFontSize, values: [20, 24, 30, 34, 38, 42, 46]) { "\(Int($0)) pt" }
                MacSettingsDivider()
                MacSettingsRow(icon: "circle.dotted.circle", color: .white, title: "Outline", detail: "Increase contrast around subtitle text.") {
                    HStack(spacing: 8) {
                        Slider(value: $subtitleStrokeWidth, in: 0...4, step: 0.5)
                            .frame(width: 120)
                            .accessibilityLabel("Subtitle Outline")
                            .accessibilityValue(String(format: "%.1f points", subtitleStrokeWidth))
                        Text(String(format: "%.1f", subtitleStrokeWidth)).monospacedDigit().foregroundStyle(.secondary).frame(width: 28)
                    }
                }
                MacSettingsDivider()
                MacSettingsRow(icon: "arrow.up.and.down.text.horizontal", color: .purple, title: "Vertical Position", detail: "Move subtitles up or down from Eclipse's default.") {
                    HStack(spacing: 8) {
                        Slider(value: $subtitleVerticalOffset, in: -24...24, step: 1)
                            .frame(width: 120)
                            .accessibilityLabel("Subtitle Vertical Position")
                            .accessibilityValue("\(Int(subtitleVerticalOffset)) points")
                        Text("\(Int(subtitleVerticalOffset))").monospacedDigit().foregroundStyle(.secondary).frame(width: 28)
                    }
                }
                MacSettingsDivider()
                settingToggle("Caption Background", detail: "Draw a translucent dark box behind subtitles.", icon: "captions.bubble.fill", color: .gray, isOn: $subtitleBackgroundEnabled)
                MacSettingsDivider()
                settingToggle("Ignore Embedded Subtitle Styles", detail: "Force Eclipse's readable subtitle appearance instead of special ASS effects. Applies on the next player session.", icon: "textformat", color: .pink, isOn: $ignoreEmbeddedSubtitleStyles)
            }
            .id(MacSettingsAnchor.playerSubtitleAppearance)
            MacSettingsGroup("MPVKit") {
                MacSettingsRow(icon: "play.rectangle.fill", color: .white, title: "Renderer", detail: "Native MPVKit gpu-next with VideoToolbox decoding.") { Text("MPVKit").foregroundStyle(.secondary) }
                MacSettingsDivider()
                stringPickerRow("Quality Profile", detail: "Balance sharpness, heat, and power use.", icon: "dial.medium", color: .green, selection: $qualityProfile, values: [("auto", "Auto"), ("balanced", "Balanced"), ("lowHeat", "Low Heat"), ("sharp", "Sharp")])
                MacSettingsDivider()
                stringPickerRow("Upscaling", detail: "Optional Lanczos upscaling and debanding. If you experience issues, disable upscaling.", icon: "arrow.up.left.and.arrow.down.right", color: .mint, selection: $upscalingMode, values: [("off", "Off"), ("upscaleTo1080", "To 1080p"), ("upscaleTo4K", "To 4K"), ("oneLevelAlways", "One Level"), ("auto", "Full")])
                MacSettingsDivider()
                stringPickerRow("HDR", detail: "Choose passthrough or tone mapping behavior.", icon: "sun.max.fill", color: .yellow, selection: $hdrMode, values: [("auto", "Auto"), ("hdr", "Always HDR"), ("sdr", "Always SDR")])
            }
            .id(MacSettingsAnchor.playerMPVKit)
            MacSettingsGroup("Stream Buffer") {
                settingToggle("MPV Stream Cache", detail: "Keep a bounded in-memory buffer for smoother seeking and short network interruptions.", icon: "arrow.down.circle.fill", color: .blue, isOn: $streamCacheEnabled)
                if streamCacheEnabled {
                    MacSettingsDivider()
                    MacSettingsRow(icon: "memorychip", color: .teal, title: "Buffer Limit", detail: "Maximum forward demux buffer. Applies on the next player session.") {
                        Stepper("\(streamCacheLimitMB) MB", value: $streamCacheLimitMB, in: 32...512, step: 32).frame(width: 130)
                    }
                }
            }
            .id(MacSettingsAnchor.playerCache)
            MacSettingsFootnote("Touch gestures, force-landscape, orientation lock, cellular cache controls, and iOS external-player schemes are intentionally omitted on Mac.")
        }
    }

    private var appearancePage: some View {
        VStack(spacing: 18) {
            MacSettingsGroup("Theme") {
                stringPickerRow("Palette", detail: "The same atmosphere palette names used by Eclipse on iPhone and iPad.", icon: "paintpalette.fill", color: .purple, selection: $appearancePalette, values: [("midnightPurple", "Midnight Purple"), ("nocturne", "Nocturne"), ("velvet", "Velvet"), ("mutedAurora", "Muted Aurora")])
                MacSettingsDivider()
                stringPickerRow("Background Style", detail: "Multi-gradient blends Eclipse's palette; Classic uses a single-color gradient; Solid is flat.", icon: "circle.lefthalf.filled", color: .indigo, selection: atmosphereStyleBinding, values: [("multiGradient", "Multi Gradient"), ("gradient", "Classic Gradient"), ("solid", "Solid")])
                if normalizedAtmosphereStyle != "solid" {
                    MacSettingsDivider()
                    MacSettingsRow(icon: "drop.fill", color: .purple, title: "Color Bleed", detail: "Adjust how strongly the palette washes down Eclipse surfaces.") {
                        Slider(value: appearanceBleedBinding, in: 0...1.2, step: 0.05)
                            .frame(width: 160)
                            .accessibilityLabel("Color Bleed")
                            .accessibilityValue("\(Int(appearanceBleedStrength * 100)) percent")
                    }
                    MacSettingsDivider()
                    MacSettingsRow(icon: "sun.max", color: .orange, title: "Background Intensity", detail: "Adjust the strength of Eclipse's ambient color.") {
                        Slider(value: $backgroundIntensity, in: 0.6...1.3, step: 0.05)
                            .frame(width: 160)
                            .accessibilityLabel("Background Intensity")
                            .accessibilityValue("\(Int(backgroundIntensity * 100)) percent")
                    }
                    MacSettingsDivider()
                    settingToggle("Animated Background", detail: "Use subtle ambient motion behind Eclipse surfaces. Reduce Motion always takes precedence.", icon: "sparkles", color: .pink, isOn: $animatedBackgroundEnabled)
                    if animatedBackgroundEnabled {
                        MacSettingsDivider()
                        stringPickerRow("Animation Quality", detail: "Low matches Eclipse's battery-friendly default; Medium and High add richer ambient layers.", icon: "wand.and.stars", color: .purple, selection: $animatedBackgroundQuality, values: [("low", "Low"), ("medium", "Medium"), ("high", "High")])
                        MacSettingsDivider()
                        stringPickerRow("Animation Frame Rate", detail: "Use battery-friendly 20 FPS or smoother 30 FPS atmosphere motion.", icon: "speedometer", color: .cyan, selection: $animatedBackgroundFrameRate, values: [("fps20", "20 FPS"), ("fps30", "30 FPS")])
                    }
                }
            }
            .id(MacSettingsAnchor.appearanceTheme)

            MacSettingsGroup("Home Layout") {
                stringPickerRow("Layout Density", detail: "Controls the hero scale, shelf spacing, and base card sizing together.", icon: "rectangle.3.group.bubble", color: .indigo, selection: $designPreset, values: [("cinematic", "Cinematic"), ("balanced", "Balanced"), ("compact", "Compact")])
                MacSettingsDivider()
                stringPickerRow("Card Shape", detail: "Choose poster, landscape, or automatic artwork.", icon: "rectangle.3.group", color: .blue, selection: $homeCardShape, values: [("automatic", "Automatic"), ("poster", "Poster"), ("landscape", "Landscape")])
                MacSettingsDivider()
                MacSettingsRow(icon: "rectangle.expand.vertical", color: .cyan, title: "Card Size", detail: "Scale media cards for the current Mac window.") {
                    Slider(value: $mediaCardScale, in: 0.75...1.35)
                        .frame(width: 160)
                        .accessibilityLabel("Card Size")
                        .accessibilityValue("\(Int(mediaCardScale * 100)) percent")
                }
                MacSettingsDivider()
                MacSettingsRow(icon: "square.on.square", color: .mint, title: "Card Roundness", detail: "Adjust the corner radius of Home artwork.") {
                    Slider(value: $cardRadiusScale, in: 0.7...1.4, step: 0.05)
                        .frame(width: 160)
                        .accessibilityLabel("Card Roundness")
                        .accessibilityValue("\(Int(cardRadiusScale * 100)) percent")
                }
                MacSettingsDivider()
                MacSettingsRow(icon: "arrow.up.and.down.text.horizontal", color: .orange, title: "Section Spacing", detail: "Adjust the vertical rhythm between Home shelves.") {
                    Slider(value: $sectionSpacingScale, in: 0.75...1.35, step: 0.05)
                        .frame(width: 160)
                        .accessibilityLabel("Section Spacing")
                        .accessibilityValue("\(Int(sectionSpacingScale * 100)) percent")
                }
            }
            .id(MacSettingsAnchor.appearanceLayout)

            MacSettingsGroup("Hero") {
                stringPickerRow(
                    "Hero Banner",
                    detail: "Choose which enabled Home catalog supplies the large banner, matching iPhone and iPad.",
                    icon: "photo.on.rectangle.angled",
                    color: .purple,
                    selection: $heroBannerCatalogID,
                    values: selectableHeroCatalogs.map { ($0.rawValue, $0.title) }
                )
                MacSettingsDivider()
                stringPickerRow("Hero Behavior", detail: "Keep one title visible or rotate through the selected catalog.", icon: "rectangle.stack", color: .pink, selection: $heroBannerBehavior, values: [("static", "Static"), ("carousel", "Carousel")])
                MacSettingsDivider()
                MacSettingsRow(icon: "arrow.up.left.and.arrow.down.right", color: .cyan, title: "Hero Size", detail: "Scale the height of the large Home banner.") {
                    Slider(value: $heroHeightScale, in: 0.75...1.15, step: 0.05)
                        .frame(width: 160)
                        .accessibilityLabel("Hero Size")
                        .accessibilityValue("\(Int(heroHeightScale * 100)) percent")
                }
            }
            .id(MacSettingsAnchor.appearanceHero)

            Button(role: .destructive) {
                resetHomeAppearance()
            } label: {
                MacSettingsRow(icon: "arrow.counterclockwise", color: .red, title: "Reset Home Appearance", detail: "Restore Eclipse's iPhone and iPad defaults.") {
                    EmptyView()
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var performancePage: some View {
        VStack(spacing: 18) {
            MacSettingsGroup("Performance Mode") {
                settingToggle(
                    "Performance Mode",
                    detail: "Keep anime-heavy Home catalogs on Eclipse's faster path while full metadata loads only when needed.",
                    icon: "bolt.fill",
                    color: .yellow,
                    isOn: $performanceModeEnabled
                )
            }
            .id(MacSettingsAnchor.performanceMode)
            MacSettingsFootnote("Enabled by default, matching Eclipse on iPhone and iPad.")

            MacSettingsGroup("Affected Home Catalogs") {
                ForEach(Array(MacHomeCatalogID.allCases.filter(\.isAnime).enumerated()), id: \.element.id) { index, catalog in
                    MacSettingsRow(icon: "bolt.fill", color: .yellow, title: catalog.title, detail: nil) {
                        Text(catalogVisibilityBinding(catalog).wrappedValue ? "Enabled" : "Hidden")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if index < MacHomeCatalogID.allCases.filter(\.isAnime).count - 1 { MacSettingsDivider() }
                }
            }
        }
    }

    private var schedulePage: some View {
        VStack(spacing: 18) {
            MacSettingsGroup("Schedule Tab") {
                stringPickerRow("Default Schedule", detail: "Choose which schedule opens first.", icon: "calendar", color: .red, selection: $defaultScheduleMode, values: [("anime", "Anime"), ("western", "TV"), ("combined", "Combined")])
                MacSettingsDivider()
                MacSettingsRow(icon: "calendar.badge.clock", color: .purple, title: "Schedule Range", detail: "Longer ranges load more metadata.") {
                    Picker("Schedule Range", selection: $scheduleWindowDays) {
                        ForEach([7, 14, 21, 30], id: \.self) { Text("\($0) days").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 115)
                    .accessibilityLabel("Schedule Range")
                    .accessibilityValue("\(scheduleWindowDays) days")
                }
            }
            .id(MacSettingsAnchor.schedule)
            MacSettingsFootnote("Anime follows AniList with MyAnimeList fallback. TV follows Trakt with TVMaze fallback. Combined keeps both schedules visible, with times shown in your selected time zone.")
        }
    }

    private var notificationsPage: some View {
        VStack(spacing: 18) {
            MacSettingsGroup("Access") {
                MacSettingsRow(icon: notificationStatus == "Allowed" ? "bell.fill" : "bell.slash.fill", color: notificationStatus == "Allowed" ? .green : .orange, title: "Notification Access", detail: "macOS controls final delivery in System Settings.") {
                    HStack {
                        Text(notificationStatus).foregroundStyle(.secondary)
                        if notificationStatus == "Not Requested" {
                            Button("Request") { Task { await requestNotificationAccess() } }
                        } else {
                            Button("Open Settings") { openNotificationSettings() }
                        }
                    }
                }
            }
            .id(MacSettingsAnchor.notificationAccess)
            MacSettingsGroup("Timing") {
                MacSettingsRow(icon: "clock.badge", color: .orange, title: "Episode Lead Time", detail: "How early to alert before an episode airs.") {
                    Picker("Episode Lead Time", selection: $episodeLeadTime) {
                        Text("At airtime").tag(0)
                        Text("15 min").tag(900)
                        Text("30 min").tag(1_800)
                        Text("1 hr").tag(3_600)
                        Text("1 day").tag(86_400)
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    .accessibilityLabel("Episode Lead Time")
                    .accessibilityValue(notificationLeadTimeLabel(episodeLeadTime, zeroLabel: "At airtime"))
                }
                MacSettingsDivider()
                MacSettingsRow(icon: "calendar.badge.clock", color: .purple, title: "Season Premiere Lead Time", detail: "How early to alert before a known premiere.") {
                    Picker("Season Premiere Lead Time", selection: $seasonLeadTime) {
                        Text("On premiere day").tag(0)
                        Text("6 hr").tag(21_600)
                        Text("12 hr").tag(43_200)
                        Text("1 day").tag(86_400)
                        Text("2 days").tag(172_800)
                        Text("1 week").tag(604_800)
                    }
                    .labelsHidden()
                    .frame(width: 130)
                    .accessibilityLabel("Season Premiere Lead Time")
                    .accessibilityValue(notificationLeadTimeLabel(seasonLeadTime, zeroLabel: "On premiere day"))
                }
                MacSettingsDivider()
                settingToggle("Anime Specials & OVAs", detail: "Include specials when Eclipse has an exact air date.", icon: "sparkles.tv", color: .pink, isOn: $includeAnimeSpecials)
            }
            .id(MacSettingsAnchor.notificationTiming)
            MacSettingsGroup("Upcoming Airings") {
                settingToggle("Schedule Reminders", detail: "Schedule a bounded set of native alerts for exact upcoming episode dates. Off by default.", icon: "calendar.badge.clock", color: .purple, isOn: $scheduleNotificationsEnabled)
            }
            .id(MacSettingsAnchor.notificationReminders)
        }
    }

    private var catalogsPage: some View {
        MacSettingsGroup("Home Catalogs") {
            ForEach(Array(orderedHomeCatalogs.enumerated()), id: \.element.id) { index, catalogID in
                HStack(spacing: 12) {
                    Toggle(isOn: catalogVisibilityBinding(catalogID)) {
                        Label(catalogID.title, systemImage: catalogIcon(catalogID))
                    }
                    Spacer()
                    Button { moveHomeCatalog(at: index, by: -1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0)
                    Button { moveHomeCatalog(at: index, by: 1) } label: { Image(systemName: "chevron.down") }.disabled(index == orderedHomeCatalogs.count - 1)
                }
                .padding(14)
                if index < orderedHomeCatalogs.count - 1 { MacSettingsDivider() }
            }
        }
        .id(MacSettingsAnchor.catalogs)
    }

    private var orderedHomeCatalogs: [MacHomeCatalogID] {
        var seen = Set<MacHomeCatalogID>()
        let saved = homeCatalogOrderRaw.split(separator: ",").compactMap { MacHomeCatalogID(rawValue: String($0)) }.filter { seen.insert($0).inserted }
        return saved + MacHomeCatalogID.allCases.filter { seen.insert($0).inserted }
    }

    private var selectableHeroCatalogs: [MacHomeCatalogID] {
        let enabled = MacHomeCatalogID.allCases.filter { catalogVisibilityBinding($0).wrappedValue }
        return enabled.isEmpty ? [.trending] : enabled
    }

    private var homeCatalogVisibilitySignature: String {
        MacHomeCatalogID.allCases
            .map { catalogVisibilityBinding($0).wrappedValue ? "1" : "0" }
            .joined()
    }

    private func ensureHeroCatalogIsEnabled() {
        guard let selected = MacHomeCatalogID(rawValue: heroBannerCatalogID),
              selectableHeroCatalogs.contains(selected) else {
            heroBannerCatalogID = selectableHeroCatalogs.first?.rawValue
                ?? MacHomeCatalogID.trending.rawValue
            return
        }
    }

    private func catalogVisibilityBinding(_ catalog: MacHomeCatalogID) -> Binding<Bool> {
        switch catalog {
        case .trending: $showTrending
        case .trendingAnime: $showTrendingAnime
        case .popularMovies: $showPopularMovies
        case .popularAnime: $showPopularAnime
        case .popularShows: $showPopularShows
        case .airingAnime: $showAiringAnime
        case .upcomingAnime: $showUpcomingAnime
        case .topRated: $showTopRated
        case .topRatedAnime: $showTopRatedAnime
        }
    }

    private func catalogIcon(_ catalog: MacHomeCatalogID) -> String {
        switch catalog {
        case .trending: "flame.fill"
        case .trendingAnime: "sparkles.tv.fill"
        case .popularMovies: "film.fill"
        case .popularAnime: "heart.fill"
        case .popularShows: "tv.fill"
        case .airingAnime: "dot.radiowaves.left.and.right"
        case .upcomingAnime: "calendar.badge.clock"
        case .topRated: "star.fill"
        case .topRatedAnime: "star.circle.fill"
        }
    }

    private func moveHomeCatalog(at index: Int, by offset: Int) {
        var values = orderedHomeCatalogs
        let target = index + offset
        guard values.indices.contains(index), values.indices.contains(target) else { return }
        values.swapAt(index, target)
        homeCatalogOrderRaw = values.map(\.rawValue).joined(separator: ",")
    }

    private var servicesPage: some View {
        VStack(spacing: 18) {
            MacSettingsGroup("Behavior") {
                settingToggle("Auto-update Services", detail: "Check installed Eclipse Services for compatible updates.", icon: "arrow.triangle.2.circlepath", color: .green, isOn: $autoUpdateServices)
                MacSettingsDivider()
                settingToggle("Auto Mode", detail: "Automatically rank playable results from enabled sources.", icon: "wand.and.stars", color: .indigo, isOn: $autoModeEnabled)
                MacSettingsDivider()
                stringPickerRow("Selection", detail: "Manual shows the picker; automatic modes rank streams by quality.", icon: "dial.medium", color: .blue, selection: $autoQualityPreference, values: [("manual", "Manual"), ("auto", "Auto"), ("highest", "Highest"), ("2160p", "4K"), ("1080p", "1080p"), ("720p", "720p"), ("480p", "480p"), ("lowest", "Lowest")])
                MacSettingsDivider()
                MacSettingsRow(icon: "chart.bar.xaxis", color: .orange, title: "Result Similarity", detail: "Minimum title-match confidence.") {
                    Slider(value: $resultSimilarity, in: 0.5...1)
                        .frame(width: 150)
                        .accessibilityLabel("Result Similarity")
                        .accessibilityValue("\(Int(resultSimilarity * 100)) percent")
                }
                MacSettingsDivider()
                settingToggle("Drop Mismatched Results", detail: "Hide service matches below the similarity threshold.", icon: "line.3.horizontal.decrease.circle", color: .orange, isOn: $dropMismatchedResults)
                MacSettingsDivider()
                settingToggle("Hide Unknown Languages", detail: "Hide streams without detected language data.", icon: "questionmark.bubble", color: .red, isOn: $hideUnknownLanguage)
                MacSettingsDivider()
                settingToggle("Hide Unknown Qualities", detail: "Hide streams without a detected resolution.", icon: "eye.slash", color: .red, isOn: $hideUnknownQuality)
            }
            .id(MacSettingsAnchor.servicesBehavior)
            MacSettingsGroup("Language & Quality Filters") {
                MacSettingsRow(icon: "checkmark.bubble.fill", color: .green, title: "Include Languages", detail: "Allowlist. When nonempty, a stream must match at least one entry.") {
                    TextField("english, japanese", text: $includedLanguagesText).textFieldStyle(.roundedBorder).frame(width: 230)
                }
                MacSettingsDivider()
                MacSettingsRow(icon: "xmark.bubble.fill", color: .red, title: "Exclude Languages", detail: "Denylist. Exclusions win if a stream matches both lists.") {
                    TextField("hindi, russian", text: $hiddenLanguagesText).textFieldStyle(.roundedBorder).frame(width: 230)
                }
                MacSettingsDivider()
                MacSettingsRow(icon: "4k.tv.fill", color: .blue, title: "Hidden Qualities", detail: "Hide selected detected resolutions.") {
                    Menu(hiddenQualitySummary) {
                        ForEach([(2160, "4K"), (1440, "1440p"), (1080, "1080p"), (720, "720p"), (480, "480p"), (360, "360p")], id: \.0) { height, label in
                            Button { toggleHiddenQuality(height) } label: {
                                Label(label, systemImage: hiddenQualityHeights.contains(height) ? "checkmark" : "circle")
                            }
                        }
                    }
                }
            }
            .id(MacSettingsAnchor.servicesFilters)
            if !autoModeSources.isEmpty {
                MacSettingsGroup("Auto Mode Sources") {
                    ForEach(Array(autoModeSources.enumerated()), id: \.element.id) { index, source in
                        HStack(spacing: 12) {
                            Toggle(isOn: autoModeSourceBinding(source.id)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.name).font(.headline)
                                    Text(source.kind + (source.isActive ? "" : " · Disabled")).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(!source.isActive)
                            Spacer()
                            Button { moveAutoModeSource(at: index, by: -1) } label: { Image(systemName: "chevron.up") }
                                .disabled(index == 0)
                            Button { moveAutoModeSource(at: index, by: 1) } label: { Image(systemName: "chevron.down") }
                                .disabled(index == autoModeSources.count - 1)
                        }
                        .padding(14)
                        if index < autoModeSources.count - 1 { MacSettingsDivider() }
                    }
                }
                .id(MacSettingsAnchor.servicesSources)
            }
            MacSettingsGroup("Install Eclipse Service") {
                installField($legacyServiceURL, placeholder: "https://example.com/service.json") {
                    if await legacyServices.install(from: legacyServiceURL) { legacyServiceURL = "" }
                }
                HStack {
                    Button("Update All") { Task { await legacyServices.updateAll() } }.disabled(legacyServices.services.isEmpty || legacyServices.isWorking)
                    if legacyServices.isWorking { ProgressView().controlSize(.small) }
                    if let error = legacyServices.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
                }.padding(14)
            }
            .id(MacSettingsAnchor.servicesInstall)
            MacSettingsGroup("Installed Eclipse Services") { installedServices }
            MacSettingsGroup("Install Stremio Addon") {
                installField($addonURL, placeholder: "https://example.com/manifest.json") {
                    if await services.install(from: addonURL) { addonURL = "" }
                }
                if let error = services.lastError { Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 14).padding(.bottom, 12) }
            }
            .id(MacSettingsAnchor.servicesInstall)
            MacSettingsGroup("Installed Stremio Addons") { installedAddons }
            MacSettingsFootnote("Direct HTTP and HTTPS streams are supported. Torrent, magnet, and info-hash-only results remain excluded from Eclipse playback on Mac.")
        }
    }

    private var trackersPage: some View {
        VStack(spacing: 18) {
            MacSettingsGroup("Accounts") {
                ForEach(Array(MacTrackerService.allCases.enumerated()), id: \.element.id) { index, service in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(service.name).font(.headline)
                            Text(trackers.connectionDetail(for: service))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if trackers.account(for: service) != nil {
                            if trackers.needsReconnect(service) {
                                Button("Reconnect") { trackers.connect(service) }
                                    .disabled(trackers.isAuthenticating || trackers.importService != nil)
                            }
                            Button("Disconnect", role: .destructive) { trackers.disconnect(service) }
                                .disabled(trackers.importService != nil)
                        } else {
                            Button("Connect") { trackers.connect(service) }
                                .disabled(trackers.isAuthenticating || trackers.importService != nil)
                        }
                    }.padding(14)
                    if index < MacTrackerService.allCases.count - 1 { MacSettingsDivider() }
                }
            }
            .id(MacSettingsAnchor.trackerAccounts)
            MacSettingsGroup("Synchronization") {
                settingToggle("Enable Tracker Sync", detail: "Keep supported anime playback progress in sync with connected AniList and MyAnimeList accounts.", icon: "arrow.triangle.2.circlepath", color: .purple, isOn: $trackerSyncEnabled)
                MacSettingsDivider()
                settingToggle("Auto Sync Ratings", detail: "Send Eclipse anime ratings to connected AniList and MyAnimeList accounts. Off by default.", icon: "star.bubble.fill", color: .yellow, isOn: $trackerAutoSyncRatings)
                    .disabled(!trackerSyncEnabled)
                MacSettingsDivider()
                settingToggle("Sync Reader Progress", detail: "Keep supported reader progress in sync with connected AniList and MyAnimeList accounts.", icon: "book.pages.fill", color: .orange, isOn: $trackerReaderSyncEnabled)
                    .disabled(!trackerSyncEnabled)
            }
            .id(MacSettingsAnchor.trackerSync)
            MacSettingsGroup("Playback") {
                settingToggle("Live Trakt Scrobbling", detail: "Report starts, pauses, and completion while a Trakt account is connected.", icon: "dot.radiowaves.left.and.right", color: .red, isOn: $liveTraktScrobbling)
            }
            .id(MacSettingsAnchor.trackerPlayback)
            if !connectedImportServices.isEmpty || trackers.importService != nil {
                MacSettingsGroup("Import Anime Library") {
                    if let importService = trackers.importService {
                        HStack(spacing: 12) {
                            ProgressView().controlSize(.small)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Importing from \(importService.name)…").font(.headline)
                                if let importMessage = trackers.importMessage {
                                    Text(importMessage).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Cancel") { trackers.cancelImport() }
                        }
                        .padding(14)
                    } else {
                        ForEach(Array(connectedImportServices.enumerated()), id: \.element.id) { index, service in
                            Button { trackers.importLibrary(from: service) } label: {
                                MacSettingsRow(
                                    icon: "square.and.arrow.down",
                                    color: service == .anilist ? .blue : .indigo,
                                    title: "Import from \(service.name)",
                                    detail: "Add matched anime titles to the flat Mac Library. Existing items are never deleted or downgraded."
                                ) {
                                    Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(trackers.isAuthenticating)
                            if index < connectedImportServices.count - 1 { MacSettingsDivider() }
                        }
                    }
                }
                .id(MacSettingsAnchor.trackerImport)
            }
            if trackers.isAuthenticating { ProgressView("Waiting for tracker sign-in…") }
            if let message = trackers.lastActivity { MacSettingsFootnote(message) }
            if trackers.importService == nil, let message = trackers.importMessage { MacSettingsFootnote(message) }
            if let error = trackers.errorMessage { MacSettingsFootnote(error, color: .red) }
            MacSettingsFootnote("OAuth credentials remain in the Keychain and are excluded from Eclipse backups. AniList and MyAnimeList imports are additive: matched anime are added to the flat Mac Library without deleting or downgrading existing state.")
        }
    }

    private var connectedImportServices: [MacTrackerService] {
        MacTrackerService.allCases.filter {
            $0 != .trakt && trackers.account(for: $0) != nil
        }
    }

    private var storagePage: some View {
        VStack(spacing: 18) {
            MacSettingsGroup("Eclipse Storage") {
                MacSettingsRow(icon: "internaldrive", color: .gray, title: "App Data", detail: "Downloads, reader chapters, logs, metadata, and cache.") { Text(storageSummary).foregroundStyle(.secondary) }
                MacSettingsDivider()
                Button { revealApplicationSupport() } label: { MacSettingsRow(icon: "folder", color: .blue, title: "Show Eclipse Data in Finder", detail: "Reveal the sandbox's Application Support folder.") { Image(systemName: "chevron.right").foregroundStyle(.tertiary) } }.buttonStyle(.plain)
            }
            .id(MacSettingsAnchor.storageData)
            MacSettingsGroup("Cache") {
                settingToggle("Auto-clear Cache", detail: "Clear temporary cache after it grows past the threshold.", icon: "trash.slash", color: .orange, isOn: $autoClearCache)
                MacSettingsDivider()
                MacSettingsRow(icon: "gauge.with.dots.needle.bottom.50percent", color: .yellow, title: "Threshold", detail: "Temporary cache size before automatic cleanup.") { Stepper("\(Int(cacheThreshold)) MB", value: $cacheThreshold, in: 100...5000, step: 100).frame(width: 135) }
                MacSettingsDivider()
                Button(role: .destructive) { clearCaches() } label: { MacSettingsRow(icon: "trash.fill", color: .red, title: "Clear Cache Now", detail: "Keeps downloads, libraries, settings, and logs.") { EmptyView() } }.buttonStyle(.plain)
            }
            .id(MacSettingsAnchor.storageCache)
        }
    }

    private var backupPage: some View {
        VStack(spacing: 18) {
            MacSettingsGroup("Backup & Restore") {
                Button { exportBackup() } label: { MacSettingsRow(icon: "square.and.arrow.up", color: .teal, title: "Export Eclipse Backup", detail: "Save supported Mac settings, library, ratings, and progress.") { Image(systemName: "chevron.right").foregroundStyle(.tertiary) } }.buttonStyle(.plain)
                MacSettingsDivider()
                Button { importBackup() } label: { MacSettingsRow(icon: "square.and.arrow.down", color: .blue, title: "Restore Eclipse Backup", detail: "Import a backup created by this Mac target.") { Image(systemName: "chevron.right").foregroundStyle(.tertiary) } }.buttonStyle(.plain)
            }
            .id(MacSettingsAnchor.backup)
            MacSettingsFootnote("Tracker credentials, token-bearing addon URLs, downloaded media, caches, and logs are excluded from backups.")
            if let backupMessage { MacSettingsFootnote(backupMessage, color: backupMessage.contains("failed") ? .red : .secondary) }
        }
    }

    private var cloudPage: some View {
        MacSettingsGroup("iCloud") {
            MacSettingsRow(icon: "icloud", color: .blue, title: "Account", detail: "Private CloudKit media-state storage.") { Text(cloudAccountStatus).foregroundStyle(.secondary) }
            MacSettingsDivider()
            MacSettingsRow(icon: "arrow.triangle.2.circlepath", color: .cyan, title: "Media Library", detail: "Bookmarks, ratings, and playback progress.") { Text(cloudLibrary.phase.label).foregroundStyle(.secondary) }
            if let date = cloudLibrary.lastSyncDate { MacSettingsDivider(); MacSettingsRow(icon: "clock", color: .gray, title: "Last Sync", detail: nil) { Text(date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary) } }
            MacSettingsDivider()
            Button {
                Task {
                    async let bookmarks: Void = MacCatalogStore.shared.refreshCloudLibrary()
                    async let state: Void = mediaState.refreshFromCloud()
                    _ = await (bookmarks, state)
                    cloudAccountStatus = await cloudLibrary.accountStatusLabel()
                }
            } label: {
                MacSettingsRow(icon: "arrow.clockwise", color: .green, title: "Sync Library Now", detail: "Fetch bookmarks, ratings, and playback progress.") { EmptyView() }
            }
            .buttonStyle(.plain)
            .disabled(cloudLibrary.phase == .syncing)
        }
        .id(MacSettingsAnchor.cloud)
    }

    private var loggerPage: some View {
        VStack(spacing: 18) {
            MacSettingsGroup("Player & Provider Logs") {
                ScrollView { Text(logText.isEmpty ? "No logs available." : logText).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(14) }.frame(minHeight: 250, maxHeight: 360)
                MacSettingsDivider()
                HStack { Button("Refresh") { Task { logText = await Logger.shared.getLogsAsync() } }; Button("Export…") { exportLogs() }; Button("Clear", role: .destructive) { Task { await Logger.shared.clearLogsAsync(); logText = "" } }; Spacer() }.padding(14)
            }
            .id(MacSettingsAnchor.logger)
        }
    }

    private var readerPage: some View {
        VStack(spacing: 18) {
            MacSettingsGroup("Reading") {
                MacSettingsRow(icon: "rectangle.split.1x2", color: .orange, title: "Reading Direction", detail: "Webtoon, left-to-right, or right-to-left pages.") {
                    Picker("Reading Direction", selection: $reader.direction) {
                        ForEach(MacReaderDirection.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 135)
                    .accessibilityLabel("Reading Direction")
                    .accessibilityValue(reader.direction.rawValue)
                }
                MacSettingsDivider()
                MacSettingsRow(icon: "circle.lefthalf.filled", color: .purple, title: "Background", detail: "Reader canvas color.") {
                    Picker("Reader Background", selection: $reader.background) {
                        ForEach(MacReaderBackground.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    .accessibilityLabel("Reader Background")
                    .accessibilityValue(reader.background.rawValue)
                }
                MacSettingsDivider()
                MacSettingsRow(icon: "arrow.up.and.down", color: .blue, title: "Page Gap", detail: "Spacing between vertical pages.") { Stepper("\(Int(reader.pageGap)) pt", value: $reader.pageGap, in: 0...40, step: 2).frame(width: 115) }
            }
            .id(MacSettingsAnchor.readerReading)
            MacSettingsGroup("Reader Text") {
                MacSettingsRow(icon: "textformat.size", color: .cyan, title: "Font Size", detail: "Used for text pages returned by reader sources.") {
                    HStack(spacing: 8) {
                        Slider(value: $readerFontSize, in: 12...32, step: 1)
                            .frame(width: 120)
                            .accessibilityLabel("Reader Font Size")
                            .accessibilityValue("\(Int(readerFontSize)) points")
                        Text("\(Int(readerFontSize))").monospacedDigit().foregroundStyle(.secondary).frame(width: 24)
                    }
                }
                MacSettingsDivider()
                stringPickerRow("Font", detail: "Match Kanzen's system, serif, monospace, or rounded text.", icon: "textformat", color: .orange, selection: $readerFontFamily, values: [("-apple-system", "System"), ("Georgia", "Serif"), ("Menlo", "Monospace"), ("ui-rounded", "Rounded")])
                MacSettingsDivider()
                stringPickerRow("Weight", detail: "Text-page font weight.", icon: "bold", color: .pink, selection: $readerFontWeight, values: [("normal", "Regular"), ("500", "Medium"), ("700", "Bold")])
                MacSettingsDivider()
                stringPickerRow("Alignment", detail: "Text-page paragraph alignment.", icon: "text.alignleft", color: .indigo, selection: $readerTextAlignment, values: [("left", "Left"), ("center", "Center")])
                MacSettingsDivider()
                MacSettingsRow(icon: "text.line.spacing", color: .green, title: "Line Spacing", detail: "Space between lines on text pages.") {
                    HStack(spacing: 8) {
                        Slider(value: $readerLineSpacing, in: 1...3, step: 0.1)
                            .frame(width: 120)
                            .accessibilityLabel("Reader Line Spacing")
                            .accessibilityValue(String(format: "%.1f times", readerLineSpacing))
                        Text(String(format: "%.1f", readerLineSpacing)).monospacedDigit().foregroundStyle(.secondary).frame(width: 30)
                    }
                }
                MacSettingsDivider()
                MacSettingsRow(icon: "arrow.left.and.right", color: .blue, title: "Margin", detail: "Horizontal padding around text pages.") {
                    HStack(spacing: 8) {
                        Slider(value: $readerMargin, in: 0...30, step: 1)
                            .frame(width: 120)
                            .accessibilityLabel("Reader Margin")
                            .accessibilityValue("\(Int(readerMargin)) points")
                        Text("\(Int(readerMargin))").monospacedDigit().foregroundStyle(.secondary).frame(width: 24)
                    }
                }
            }
            .id(MacSettingsAnchor.readerText)
        }
    }

    private var readerSourcesPage: some View {
        VStack(spacing: 18) {
            MacSettingsGroup("Aidoku Source Lists") {
                installField($aidokuListURL, placeholder: "https://example.com/source-list.json") { if await aidoku.addSourceList(aidokuListURL) { aidokuListURL = "" } }
                HStack { Button("Refresh Lists") { Task { await aidoku.refreshLists() } }.disabled(aidoku.isWorking); if aidoku.isWorking { ProgressView().controlSize(.small) } }.padding(14)
                ForEach(aidoku.sourceLists, id: \.self) { list in MacSettingsDivider(); HStack { Text(list).lineLimit(1).truncationMode(.middle); Spacer(); Button(role: .destructive) { aidoku.removeSourceList(list) } label: { Image(systemName: "trash") } }.padding(14) }
            }
            .id(MacSettingsAnchor.readerSourceLists)
            MacSettingsGroup("Available Sources") {
                if aidoku.availableSources.isEmpty { Text("No sources available. Add or refresh a source list.").foregroundStyle(.secondary).padding(14) }
                ForEach(Array(aidoku.availableSources.enumerated()), id: \.element.id) { index, source in
                    HStack { VStack(alignment: .leading) { Text(source.name).font(.headline); Text(source.languages.map { $0.uppercased() }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }; Spacer(); if aidoku.installedSources.contains(where: { $0.id == source.id }) { Text("Installed").foregroundStyle(.secondary) } else { Button("Install") { Task { await aidoku.install(source) } }.disabled(aidoku.isWorking) } }.padding(14)
                    if index < aidoku.availableSources.count - 1 { MacSettingsDivider() }
                }
            }
            .id(MacSettingsAnchor.readerAvailableSources)
            MacSettingsGroup("Installed Sources") {
                if aidoku.installedSources.isEmpty { Text("No reader sources installed.").foregroundStyle(.secondary).padding(14) }
                ForEach(Array(aidoku.installedSources.enumerated()), id: \.element.id) { index, source in
                    HStack { Toggle(source.name, isOn: Binding(get: { source.isEnabled }, set: { _ in aidoku.toggle(source) })); Button(role: .destructive) { aidoku.remove(source) } label: { Image(systemName: "trash") } }.padding(14)
                    if index < aidoku.installedSources.count - 1 { MacSettingsDivider() }
                }
            }
            .id(MacSettingsAnchor.readerInstalledSources)
            if let error = aidoku.errorMessage { MacSettingsFootnote(error, color: .red) }
        }
    }

    private var legalPage: some View {
        VStack(spacing: 18) {
            MacSettingsGroup("Eclipse") {
                MacSettingsRow(icon: "info.circle", color: .blue, title: "Version", detail: "Eclipse v\(appVersion) (\(buildNumber))") { Text("macOS 15+").foregroundStyle(.secondary) }
                MacSettingsDivider()
                Link(destination: URL(string: "https://github.com/Soupy-dev/Eclipse")!) { MacSettingsRow(icon: "chevron.left.forwardslash.chevron.right", color: .green, title: "Source Code", detail: "Soupy-dev/Eclipse") { Image(systemName: "arrow.up.right").foregroundStyle(.tertiary) } }
                MacSettingsDivider()
                Link(destination: URL(string: "https://soupy-dev.github.io/Eclipse/privacy-policy/")!) { MacSettingsRow(icon: "hand.raised.fill", color: .purple, title: "Privacy Policy", detail: nil) { Image(systemName: "arrow.up.right").foregroundStyle(.tertiary) } }
                MacSettingsDivider()
                Link(destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!) { MacSettingsRow(icon: "doc.text.fill", color: .cyan, title: "Terms of Use", detail: "Apple Standard EULA") { Image(systemName: "arrow.up.right").foregroundStyle(.tertiary) } }
            }
            .id(MacSettingsAnchor.legal)
            MacSettingsGroup("License & Credits") {
                Text("Eclipse is free software distributed under GPLv3. MPVKit, Aidoku, SoraCore, FFmpeg, and bundled playback components retain their respective licenses and notices. Eclipse is provided without warranty.").foregroundStyle(.white.opacity(0.72)).padding(16)
            }
        }
    }

    private var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development" }
    private var buildNumber: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Local" }

    private var comfortAudioDetail: String {
        switch audioComfortMode {
        case "comfort":
            return "Gently levels dialogue and loud moments with MPV audio filters."
        case "dialogue":
            return "Reduces low rumble and brings speech forward."
        case "night":
            return "Uses the strongest leveling and peak limiting for quiet viewing."
        default:
            return "Play the stream's original audio mix without processing."
        }
    }

    private func notificationLeadTimeLabel(_ seconds: Int, zeroLabel: String) -> String {
        switch seconds {
        case 0: zeroLabel
        case 900: "15 minutes"
        case 1_800: "30 minutes"
        case 3_600: "1 hour"
        case 21_600: "6 hours"
        case 43_200: "12 hours"
        case 86_400: "1 day"
        case 172_800: "2 days"
        case 604_800: "1 week"
        default: "\(seconds) seconds"
        }
    }

    private var normalizedAtmosphereStyle: String {
        switch atmosphereStyle {
        case "gradient", "solid": atmosphereStyle
        default: "multiGradient"
        }
    }

    private var atmosphereStyleBinding: Binding<String> {
        Binding(
            get: { normalizedAtmosphereStyle },
            set: { atmosphereStyle = $0 }
        )
    }

    private var appearanceBleedBinding: Binding<Double> {
        Binding(
            get: { min(max(appearanceBleedStrength, 0), 1.2) },
            set: { appearanceBleedStrength = min(max($0, 0), 1.2) }
        )
    }

    private func normalizeAppearanceSettingsIfNeeded() {
        let resolvedAtmosphereStyle = normalizedAtmosphereStyle
        if atmosphereStyle != resolvedAtmosphereStyle { atmosphereStyle = resolvedAtmosphereStyle }
        let resolvedBleed = min(max(appearanceBleedStrength, 0), 1.2)
        if appearanceBleedStrength != resolvedBleed { appearanceBleedStrength = resolvedBleed }
        let resolvedIntensity = min(max(backgroundIntensity, 0.6), 1.3)
        if backgroundIntensity != resolvedIntensity { backgroundIntensity = resolvedIntensity }
        if !["low", "medium", "high"].contains(animatedBackgroundQuality) { animatedBackgroundQuality = "low" }
        if animatedBackgroundFrameRate != "fps20" && animatedBackgroundFrameRate != "fps30" { animatedBackgroundFrameRate = "fps20" }
        if !["cinematic", "balanced", "compact"].contains(designPreset) { designPreset = "cinematic" }
        if !["automatic", "poster", "landscape"].contains(homeCardShape) { homeCardShape = "automatic" }
        let resolvedCardScale = min(max(mediaCardScale, 0.75), 1.35)
        if mediaCardScale != resolvedCardScale { mediaCardScale = resolvedCardScale }
        let resolvedHeroScale = min(max(heroHeightScale, 0.75), 1.15)
        if heroHeightScale != resolvedHeroScale { heroHeightScale = resolvedHeroScale }
        let resolvedSpacing = min(max(sectionSpacingScale, 0.75), 1.35)
        if sectionSpacingScale != resolvedSpacing { sectionSpacingScale = resolvedSpacing }
        let resolvedRadius = min(max(cardRadiusScale, 0.7), 1.4)
        if cardRadiusScale != resolvedRadius { cardRadiusScale = resolvedRadius }
        if MacHomeCatalogID(rawValue: heroBannerCatalogID) == nil {
            heroBannerCatalogID = MacHomeCatalogID.trending.rawValue
        }
        ensureHeroCatalogIsEnabled()
        if heroBannerBehavior != "static" && heroBannerBehavior != "carousel" { heroBannerBehavior = "carousel" }
    }

    private func resetHomeAppearance() {
        designPreset = "cinematic"
        homeCardShape = "automatic"
        mediaCardScale = 1
        heroHeightScale = 1
        sectionSpacingScale = 1
        cardRadiusScale = 1
        heroBannerCatalogID = MacHomeCatalogID.trending.rawValue
        heroBannerBehavior = "carousel"
        animatedBackgroundEnabled = true
        animatedBackgroundQuality = "low"
        animatedBackgroundFrameRate = "fps20"
    }

    private func settingToggle(_ title: String, detail: String, icon: String, color: Color, isOn: Binding<Bool>) -> some View {
        MacSettingsRow(icon: icon, color: color, title: title, detail: detail) {
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .accessibilityLabel(Text(title))
                .accessibilityValue(Text(isOn.wrappedValue ? "On" : "Off"))
        }
    }

    private func settingPicker<Value: Hashable>(_ title: String, detail: String, icon: String, color: Color, selection: Binding<Value>, values: [Value], label: @escaping (Value) -> String) -> some View {
        MacSettingsRow(icon: icon, color: color, title: title, detail: detail) {
            Picker(title, selection: selection) {
                ForEach(values, id: \.self) { Text(label($0)).tag($0) }
            }
            .labelsHidden()
            .frame(width: 120)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(label(selection.wrappedValue)))
        }
    }

    private func stringPickerRow(_ title: String, detail: String, icon: String, color: Color, selection: Binding<String>, values: [(String, String)]) -> some View {
        MacSettingsRow(icon: icon, color: color, title: title, detail: detail) {
            Picker(title, selection: selection) {
                ForEach(values, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden()
            .frame(width: 135)
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(values.first(where: { $0.0 == selection.wrappedValue })?.1 ?? selection.wrappedValue))
        }
    }

    private func languageRow(_ title: String, icon: String, selection: Binding<String>) -> some View {
        stringPickerRow(title, detail: "ISO language preference used by the Mac MPV renderer.", icon: icon, color: .indigo, selection: selection, values: [("eng", "English"), ("jpn", "Japanese"), ("spa", "Spanish"), ("fra", "French"), ("deu", "German"), ("ita", "Italian"), ("por", "Portuguese"), ("kor", "Korean"), ("zho", "Chinese")])
    }

    private func installField(_ value: Binding<String>, placeholder: String, action: @escaping () async -> Void) -> some View {
        HStack { TextField(placeholder, text: value).textFieldStyle(.roundedBorder); Button("Install") { Task { await action() } }.disabled(value.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }.padding(14)
    }

    private var installedServices: some View {
        VStack(spacing: 0) {
            if legacyServices.services.isEmpty { Text("No Eclipse Services installed.").foregroundStyle(.secondary).padding(14) }
            ForEach(Array(legacyServices.services.enumerated()), id: \.element.id) { index, service in
                HStack { Toggle(isOn: Binding(get: { service.isActive }, set: { legacyServices.setActive(service, active: $0) })) { VStack(alignment: .leading) { Text(service.metadata.sourceName); Text("v\(service.metadata.version) · \(service.metadata.language.uppercased())").font(.caption).foregroundStyle(.secondary) } }; Button { legacyServices.move(from: IndexSet(integer: index), to: max(0, index - 1)) } label: { Image(systemName: "chevron.up") }.disabled(index == 0); Button { legacyServices.move(from: IndexSet(integer: index), to: min(legacyServices.services.count, index + 2)) } label: { Image(systemName: "chevron.down") }.disabled(index == legacyServices.services.count - 1); Button(role: .destructive) { legacyServices.remove(service) } label: { Image(systemName: "trash") } }.padding(14)
                if index < legacyServices.services.count - 1 { MacSettingsDivider() }
            }
        }
    }

    private var installedAddons: some View {
        VStack(spacing: 0) {
            if services.addons.isEmpty { Text("No Stremio addons installed.").foregroundStyle(.secondary).padding(14) }
            ForEach(Array(services.addons.enumerated()), id: \.element.id) { index, addon in
                HStack { Toggle(isOn: Binding(get: { addon.isActive }, set: { services.setActive(addon, active: $0) })) { VStack(alignment: .leading) { Text(addon.name); if let summary = addon.summary { Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(2) } } }; Button { services.move(from: IndexSet(integer: index), to: max(0, index - 1)) } label: { Image(systemName: "chevron.up") }.disabled(index == 0); Button { services.move(from: IndexSet(integer: index), to: min(services.addons.count, index + 2)) } label: { Image(systemName: "chevron.down") }.disabled(index == services.addons.count - 1); Button(role: .destructive) { services.remove(addon) } label: { Image(systemName: "trash") } }.padding(14)
                if index < services.addons.count - 1 { MacSettingsDivider() }
            }
            if !services.addons.isEmpty {
                MacSettingsDivider()
                HStack { Button("Update All") { Task { await services.updateAll() } }.disabled(services.isInstalling); if services.isInstalling { ProgressView().controlSize(.small) }; Spacer() }.padding(14)
            }
        }
    }

    private var autoModeSources: [MacSettingsServiceSource] {
        let values = legacyServices.services.map {
            MacSettingsServiceSource(id: "service:\($0.id.uuidString)", name: $0.metadata.sourceName, kind: "Eclipse Service", isActive: $0.isActive)
        } + services.addons.map {
            MacSettingsServiceSource(id: "stremio:\($0.id.uuidString)", name: $0.name, kind: "Stremio", isActive: $0.isActive)
        }
        var seenOrderIDs = Set<String>()
        let normalizedOrder = autoModeSourceOrderIDs.filter { seenOrderIDs.insert($0).inserted }
        let order = Dictionary(uniqueKeysWithValues: normalizedOrder.enumerated().map { ($0.element, $0.offset) })
        return values.enumerated().sorted { lhs, rhs in
            let left = order[lhs.element.id]
            let right = order[rhs.element.id]
            if let left, let right, left != right { return left < right }
            if left != nil { return true }
            if right != nil { return false }
            return lhs.offset < rhs.offset
        }.map { $0.element }
    }

    private func initializeAutoModeSourcesIfNeeded() {
        let defaults = UserDefaults.standard
        let sources = autoModeSources
        guard !sources.isEmpty else { return }
        if defaults.object(forKey: "servicesAutoModeSourceIds") == nil {
            selectedAutoModeSourceIDs = Set(sources.filter(\.isActive).map(\.id))
            defaults.set(Array(selectedAutoModeSourceIDs), forKey: "servicesAutoModeSourceIds")
        }
        if defaults.object(forKey: "servicesAutoModeSourceOrderIds") == nil {
            autoModeSourceOrderIDs = sources.map(\.id)
            defaults.set(autoModeSourceOrderIDs, forKey: "servicesAutoModeSourceOrderIds")
        }
    }

    private func autoModeSourceBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { selectedAutoModeSourceIDs.contains(id) },
            set: { enabled in
                if enabled { selectedAutoModeSourceIDs.insert(id) }
                else { selectedAutoModeSourceIDs.remove(id) }
                UserDefaults.standard.set(Array(selectedAutoModeSourceIDs), forKey: "servicesAutoModeSourceIds")
            }
        )
    }

    private func moveAutoModeSource(at index: Int, by offset: Int) {
        var visible = autoModeSources.map(\.id)
        let target = index + offset
        guard visible.indices.contains(index), visible.indices.contains(target) else { return }
        visible.swapAt(index, target)
        let visibleSet = Set(visible)
        autoModeSourceOrderIDs = visible + autoModeSourceOrderIDs.filter { !visibleSet.contains($0) }
        UserDefaults.standard.set(autoModeSourceOrderIDs, forKey: "servicesAutoModeSourceOrderIds")
    }

    private func sanitizedLanguageTokens(_ text: String) -> [String] {
        var seen = Set<String>()
        return text
            .components(separatedBy: CharacterSet(charactersIn: ",;\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && $0.count <= 40 && seen.insert($0).inserted }
            .prefix(40)
            .map { $0 }
    }

    private var hiddenQualitySummary: String {
        if hiddenQualityHeights.isEmpty { return "None" }
        return hiddenQualityHeights.sorted(by: >).map { $0 == 2160 ? "4K" : "\($0)p" }.joined(separator: ", ")
    }

    private func toggleHiddenQuality(_ height: Int) {
        if hiddenQualityHeights.contains(height) { hiddenQualityHeights.remove(height) }
        else { hiddenQualityHeights.insert(height) }
        UserDefaults.standard.set(hiddenQualityHeights.sorted(by: >), forKey: "servicesHiddenStreamQualities")
    }

    private func refreshNotificationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        notificationStatus = switch settings.authorizationStatus { case .authorized, .provisional: "Allowed"; case .denied: "Denied"; case .notDetermined: "Not Requested"; @unknown default: "Unknown" }
    }

    private func requestNotificationAccess() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        await refreshNotificationStatus()
        await MacCatalogStore.shared.refreshScheduleNotificationsFromStoredPreferences()
    }

    private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    private func normalizeLegacyNotificationTimingIfNeeded() {
        if [15, 30, 60, 120].contains(episodeLeadTime) { episodeLeadTime *= 60 }
        if [1, 6, 12, 24, 48, 168].contains(seasonLeadTime) { seasonLeadTime *= 3_600 }
    }

    private func refreshStorageSummary() async {
        let roots = [FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first, FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first, FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first].compactMap { $0 }
        let bytes = await Task.detached { roots.reduce(Int64(0)) { $0 + Self.directorySize($1) } }.value
        storageSummary = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    nonisolated private static func directorySize(_ root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator { if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true { total += Int64(values.fileSize ?? 0) } }
        return total
    }

    private func revealApplicationSupport() { if let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    private func clearCaches() { if let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first { try? FileManager.default.removeItem(at: url); try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); Task { await refreshStorageSummary() } } }

    private func exportBackup() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Eclipse-Mac-Backup.plist"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try MacBackupCoordinator.export(to: url); backupMessage = "Backup exported successfully." } catch { backupMessage = "Backup failed: \(error.localizedDescription)" }
    }

    private func importBackup() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try MacBackupCoordinator.restore(from: url); backupMessage = "Backup restored. Reopen Eclipse to refresh every surface." } catch { backupMessage = "Restore failed: \(error.localizedDescription)" }
    }

    private func exportLogs() {
        Task {
            guard let source = try? await Logger.shared.exportLogsToTempFile() else { return }
            let panel = NSSavePanel(); panel.nameFieldStringValue = source.lastPathComponent
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            try? FileManager.default.removeItem(at: destination); try? FileManager.default.copyItem(at: source, to: destination)
        }
    }
}

private struct MacSettingsServiceSource: Identifiable {
    let id: String
    let name: String
    let kind: String
    let isActive: Bool
}

private enum SettingsDestination: String, CaseIterable, Hashable, Identifiable {
    case support, performance, player, appearance, schedule, notifications, catalogs, services, trackers, storage, backup, cloud, logger, reader, readerSources, legal
    var id: String { rawValue }
    var title: String { switch self { case .support: "Support Eclipse"; case .performance: "Performance Mode"; case .player: "Media Player"; case .appearance: "Appearance"; case .schedule: "Schedule"; case .notifications: "Notifications"; case .catalogs: "Catalogs"; case .services: "Services"; case .trackers: "Trackers"; case .storage: "Storage"; case .backup: "Backup & Restore"; case .cloud: "Cloud Sync"; case .logger: "Logger"; case .reader: "Reader"; case .readerSources: "Reader Sources"; case .legal: "Legal & Source" } }
    var icon: String { switch self { case .support: "heart.fill"; case .performance: "bolt.fill"; case .player: "play.fill"; case .appearance: "paintbrush.fill"; case .schedule: "calendar"; case .notifications: "bell.badge.fill"; case .catalogs: "square.grid.2x2"; case .services: "server.rack"; case .trackers: "chart.bar.fill"; case .storage: "internaldrive"; case .backup: "arrow.triangle.2.circlepath"; case .cloud: "cloud"; case .logger: "doc.text"; case .reader: "book.fill"; case .readerSources: "books.vertical.fill"; case .legal: "scroll.fill" } }
    var color: Color { switch self { case .support: .pink; case .performance: .yellow; case .player: .white; case .appearance: .purple; case .schedule: .red; case .notifications: .orange; case .catalogs: .green; case .services: .indigo; case .trackers: .pink; case .storage: .gray; case .backup: .teal; case .cloud: .blue; case .logger: .yellow; case .reader: .orange; case .readerSources: .mint; case .legal: .cyan } }
    var subtitle: String { switch self { case .support: "Optional purchases and Eclipse community links."; case .performance: "Faster AniList-powered Home catalog mapping."; case .player: "MPVKit playback, audio, subtitles, and PiP."; case .appearance: "Eclipse atmosphere, Home layout, and hero behavior."; case .schedule: "Default schedule and upcoming range."; case .notifications: "Native macOS notification access and timing."; case .catalogs: "Choose and order the shelves shown on Home."; case .services: "Eclipse Services, Stremio, ranking, and filters."; case .trackers: "AniList, MyAnimeList, and Trakt sign-in, sync, imports, and scrobbling."; case .storage: "Downloads, cache, reader data, and logs."; case .backup: "Export and restore supported local Eclipse data."; case .cloud: "Private iCloud media-state synchronization."; case .logger: "Inspect and export redacted player/provider logs."; case .reader: "Kanzen reading and text appearance."; case .readerSources: "Aidoku source lists and installed reader sources."; case .legal: "Version, privacy, source, licenses, and warranty." } }
    var keywords: String {
        switch self {
        case .support: "tip donate purchase restore discord community"
        case .performance: "fast speed home anime details anilist traversal catalog optimization stutter"
        case .player: "speed seek precise remaining time subtitles ass captions language comfort audio normalization night pip skin tint black gold prismatic cyberpunk picture quality sharp balanced heat upscaling hdr renderer mpv stream buffer cache"
        case .appearance: "palette theme background style classic multi gradient solid color bleed intensity animated motion frame rate fps quality card shape poster landscape size density spacing roundness hero banner carousel"
        case .schedule: "anime western range upcoming airing days"
        case .notifications: "permission access alert episode season lead time specials ova system settings reminders"
        case .catalogs: "home trending popular movies shows top rated shelves"
        case .services: "auto mode quality similarity mismatch language filters install stremio addon provider source update torrent magnet"
        case .trackers: "anilist myanimelist mal trakt oauth connect disconnect sync anime playback progress rating reader manga import library additive scrobble"
        case .storage: "disk data finder cache threshold clear downloads logs"
        case .backup: "export import restore plist local data ratings progress"
        case .cloud: "icloud cloudkit account sync bookmarks ratings progress"
        case .logger: "logs provider player refresh export clear"
        case .reader: "kanzen reading direction webtoon left right background page gap font weight alignment line spacing margin"
        case .readerSources: "aidoku source list install refresh enable remove manga"
        case .legal: "version build source github privacy terms eula license credits warranty"
        }
    }
    var searchText: String { "\(title) \(subtitle) \(rawValue) \(keywords)" }
    static let groups: [(name: String, items: [SettingsDestination])] = [
        ("Basic", [.performance, .player, .appearance]),
        ("Content", [.schedule, .notifications, .catalogs, .services, .trackers]),
        ("Data", [.storage, .backup, .cloud, .logger]),
        ("Reader", [.reader, .readerSources]),
        ("About", [.support, .legal])
    ]
    static var ordered: [SettingsDestination] { groups.flatMap(\.items) }
}

private extension MacHomeCatalogID {
    var isAnime: Bool {
        switch self {
        case .trendingAnime, .popularAnime, .airingAnime, .upcomingAnime, .topRatedAnime:
            true
        default:
            false
        }
    }
}

private enum MacSettingsAnchor {
    static let support = "support"
    static let performanceMode = "performance-mode"
    static let playerPlayback = "player-playback"
    static let playerStyle = "player-style"
    static let playerLanguages = "player-languages"
    static let playerSubtitleAppearance = "player-subtitle-appearance"
    static let playerMPVKit = "player-mpvkit"
    static let playerCache = "player-cache"
    static let appearanceTheme = "appearance-theme"
    static let appearanceLayout = "appearance-layout"
    static let appearanceHero = "appearance-hero"
    static let schedule = "schedule"
    static let notificationAccess = "notification-access"
    static let notificationTiming = "notification-timing"
    static let notificationReminders = "notification-reminders"
    static let catalogs = "catalogs"
    static let servicesBehavior = "services-behavior"
    static let servicesFilters = "services-filters"
    static let servicesSources = "services-sources"
    static let servicesInstall = "services-install"
    static let trackerAccounts = "tracker-accounts"
    static let trackerSync = "tracker-sync"
    static let trackerPlayback = "tracker-playback"
    static let trackerImport = "tracker-import"
    static let storageData = "storage-data"
    static let storageCache = "storage-cache"
    static let backup = "backup"
    static let cloud = "cloud"
    static let logger = "logger"
    static let readerReading = "reader-reading"
    static let readerText = "reader-text"
    static let readerSourceLists = "reader-source-lists"
    static let readerAvailableSources = "reader-available-sources"
    static let readerInstalledSources = "reader-installed-sources"
    static let legal = "legal"
}

private struct MacSettingsSearchItem: Identifiable {
    let id: String
    let title: String
    let detail: String
    let destination: SettingsDestination
    let anchor: String
    let keywords: String

    init(_ title: String, detail: String, destination: SettingsDestination, anchor: String, keywords: String = "") {
        id = "\(destination.rawValue)-\(title)"
        self.title = title
        self.detail = detail
        self.destination = destination
        self.anchor = anchor
        self.keywords = keywords
    }

    var searchText: String {
        "\(title) \(detail) \(destination.searchText) \(keywords)"
    }

    static let all: [MacSettingsSearchItem] = [
        .init("Performance Mode", detail: "Use the faster anime-heavy Home path.", destination: .performance, anchor: MacSettingsAnchor.performanceMode, keywords: "speed stutter fast catalog"),

        .init("Default Playback Speed", detail: "Speed used when playback starts.", destination: .player, anchor: MacSettingsAnchor.playerPlayback),
        .init("Seek Amount", detail: "Arrow-key and player-button seek interval.", destination: .player, anchor: MacSettingsAnchor.playerPlayback),
        .init("Precise Seeking", detail: "Tenths-of-a-second scrubbing.", destination: .player, anchor: MacSettingsAnchor.playerPlayback),
        .init("Picture in Picture", detail: "Native PiP controls.", destination: .player, anchor: MacSettingsAnchor.playerPlayback, keywords: "pip"),
        .init("Player Skin", detail: "Player colors and control styling.", destination: .player, anchor: MacSettingsAnchor.playerStyle),
        .init("Subtitles", detail: "Default language, audio, and comfort modes.", destination: .player, anchor: MacSettingsAnchor.playerLanguages, keywords: "captions audio language"),
        .init("Subtitle Appearance", detail: "Font, outline, position, and background.", destination: .player, anchor: MacSettingsAnchor.playerSubtitleAppearance, keywords: "ass style captions"),
        .init("MPVKit Quality", detail: "Renderer quality, upscaling, and HDR.", destination: .player, anchor: MacSettingsAnchor.playerMPVKit, keywords: "metal video"),
        .init("Stream Buffer", detail: "MPV stream cache and memory limit.", destination: .player, anchor: MacSettingsAnchor.playerCache),

        .init("Palette", detail: "Eclipse atmosphere colors.", destination: .appearance, anchor: MacSettingsAnchor.appearanceTheme),
        .init("Background Style", detail: "Multi-gradient, classic gradient, or solid.", destination: .appearance, anchor: MacSettingsAnchor.appearanceTheme),
        .init("Animated Background", detail: "Ambient Eclipse motion.", destination: .appearance, anchor: MacSettingsAnchor.appearanceTheme),
        .init("Animation Quality", detail: "Low, Medium, or High ambient layers.", destination: .appearance, anchor: MacSettingsAnchor.appearanceTheme),
        .init("Animation Frame Rate", detail: "20 or 30 FPS ambient motion.", destination: .appearance, anchor: MacSettingsAnchor.appearanceTheme),
        .init("Layout Density", detail: "Cinematic, Balanced, or Compact Home layout.", destination: .appearance, anchor: MacSettingsAnchor.appearanceLayout),
        .init("Card Shape", detail: "Automatic, poster, or landscape artwork.", destination: .appearance, anchor: MacSettingsAnchor.appearanceLayout),
        .init("Card Size", detail: "Scale Home media cards.", destination: .appearance, anchor: MacSettingsAnchor.appearanceLayout),
        .init("Card Roundness", detail: "Adjust Home artwork corners.", destination: .appearance, anchor: MacSettingsAnchor.appearanceLayout),
        .init("Section Spacing", detail: "Adjust spacing between Home shelves.", destination: .appearance, anchor: MacSettingsAnchor.appearanceLayout),
        .init("Hero Banner", detail: "Choose the Home catalog used by the banner.", destination: .appearance, anchor: MacSettingsAnchor.appearanceHero),
        .init("Hero Behavior", detail: "Static or carousel banner.", destination: .appearance, anchor: MacSettingsAnchor.appearanceHero),
        .init("Hero Size", detail: "Scale the Home banner height.", destination: .appearance, anchor: MacSettingsAnchor.appearanceHero),

        .init("Default Schedule", detail: "Anime, TV, or Combined schedule.", destination: .schedule, anchor: MacSettingsAnchor.schedule, keywords: "anilist myanimelist mal trakt tvmaze"),
        .init("Schedule Range", detail: "Number of upcoming days to load.", destination: .schedule, anchor: MacSettingsAnchor.schedule),
        .init("Notification Access", detail: "macOS notification permission.", destination: .notifications, anchor: MacSettingsAnchor.notificationAccess),
        .init("Episode Lead Time", detail: "How early an episode reminder arrives.", destination: .notifications, anchor: MacSettingsAnchor.notificationTiming),
        .init("Season Premiere Lead Time", detail: "How early a premiere reminder arrives.", destination: .notifications, anchor: MacSettingsAnchor.notificationTiming),
        .init("Anime Specials & OVAs", detail: "Include exact-date specials in reminders.", destination: .notifications, anchor: MacSettingsAnchor.notificationTiming),
        .init("Schedule Reminders", detail: "Native upcoming-airing alerts.", destination: .notifications, anchor: MacSettingsAnchor.notificationReminders),

        .init("Home Catalogs", detail: "Show, hide, and reorder Home shelves.", destination: .catalogs, anchor: MacSettingsAnchor.catalogs, keywords: "trending popular top rated airing upcoming anime movie shows"),

        .init("Auto Mode", detail: "Automatically rank playable service results.", destination: .services, anchor: MacSettingsAnchor.servicesBehavior),
        .init("Result Similarity", detail: "Minimum title-match confidence.", destination: .services, anchor: MacSettingsAnchor.servicesBehavior),
        .init("Language Filters", detail: "Include and exclude stream languages.", destination: .services, anchor: MacSettingsAnchor.servicesFilters),
        .init("Quality Filters", detail: "Hide selected stream resolutions.", destination: .services, anchor: MacSettingsAnchor.servicesFilters),
        .init("Auto Mode Sources", detail: "Enable and prioritize service sources.", destination: .services, anchor: MacSettingsAnchor.servicesSources),
        .init("Install Eclipse Service", detail: "Install a compatible service URL.", destination: .services, anchor: MacSettingsAnchor.servicesInstall),
        .init("Install Stremio Addon", detail: "Install a Stremio manifest URL.", destination: .services, anchor: MacSettingsAnchor.servicesInstall),

        .init("AniList Account", detail: "Connect, sync, or import AniList.", destination: .trackers, anchor: MacSettingsAnchor.trackerAccounts),
        .init("MyAnimeList Account", detail: "Connect, sync, or import MyAnimeList.", destination: .trackers, anchor: MacSettingsAnchor.trackerAccounts, keywords: "mal"),
        .init("Trakt Account", detail: "Connect Trakt for media sync and scrobbling.", destination: .trackers, anchor: MacSettingsAnchor.trackerAccounts),
        .init("Tracker Sync", detail: "Playback, ratings, and reader synchronization.", destination: .trackers, anchor: MacSettingsAnchor.trackerSync),
        .init("Live Trakt Scrobbling", detail: "Report playback state to Trakt.", destination: .trackers, anchor: MacSettingsAnchor.trackerPlayback),
        .init("Import Anime Library", detail: "Add matched AniList or MyAnimeList titles.", destination: .trackers, anchor: MacSettingsAnchor.trackerImport),

        .init("App Data", detail: "Inspect Eclipse storage usage.", destination: .storage, anchor: MacSettingsAnchor.storageData),
        .init("Auto-clear Cache", detail: "Automatically clear large temporary caches.", destination: .storage, anchor: MacSettingsAnchor.storageCache),
        .init("Clear Cache Now", detail: "Remove temporary cache immediately.", destination: .storage, anchor: MacSettingsAnchor.storageCache),
        .init("Export Eclipse Backup", detail: "Save supported settings and media state.", destination: .backup, anchor: MacSettingsAnchor.backup),
        .init("Restore Eclipse Backup", detail: "Restore a Mac Eclipse backup.", destination: .backup, anchor: MacSettingsAnchor.backup),
        .init("iCloud Account", detail: "Private CloudKit media-state status.", destination: .cloud, anchor: MacSettingsAnchor.cloud),
        .init("Sync Library Now", detail: "Refresh cloud bookmarks, ratings, and progress.", destination: .cloud, anchor: MacSettingsAnchor.cloud),
        .init("Player & Provider Logs", detail: "Inspect, export, or clear Eclipse logs.", destination: .logger, anchor: MacSettingsAnchor.logger),

        .init("Reading Direction", detail: "Webtoon, left-to-right, or right-to-left.", destination: .reader, anchor: MacSettingsAnchor.readerReading),
        .init("Reader Background", detail: "Reader canvas color.", destination: .reader, anchor: MacSettingsAnchor.readerReading),
        .init("Reader Text", detail: "Font, weight, alignment, spacing, and margin.", destination: .reader, anchor: MacSettingsAnchor.readerText),
        .init("Aidoku Source Lists", detail: "Add and refresh reader source lists.", destination: .readerSources, anchor: MacSettingsAnchor.readerSourceLists),
        .init("Available Reader Sources", detail: "Install reader sources.", destination: .readerSources, anchor: MacSettingsAnchor.readerAvailableSources),
        .init("Installed Reader Sources", detail: "Enable or remove reader sources.", destination: .readerSources, anchor: MacSettingsAnchor.readerInstalledSources),

        .init("Support Purchases", detail: "Tips, subscription, and purchase restore.", destination: .support, anchor: MacSettingsAnchor.support),
        .init("Version", detail: "Eclipse version and build number.", destination: .legal, anchor: MacSettingsAnchor.legal),
        .init("Privacy Policy", detail: "Read Eclipse's privacy policy.", destination: .legal, anchor: MacSettingsAnchor.legal),
        .init("Source Code", detail: "Open Soupy-dev/Eclipse on GitHub.", destination: .legal, anchor: MacSettingsAnchor.legal)
    ]
}

enum MacStorageMaintenance {
    static func runIfNeeded(defaults: UserDefaults = .standard) async {
        guard defaults.bool(forKey: "autoClearCacheEnabled") else { return }
        let threshold = max(100, defaults.object(forKey: "autoClearCacheThresholdMB") as? Double ?? 500)
        guard let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let size = await Task.detached { directorySize(cache) }.value
        guard Double(size) >= threshold * 1_000_000 else { return }
        try? FileManager.default.removeItem(at: cache)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    }

    nonisolated private static func directorySize(_ root: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in files {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

private struct MacSettingsGroup<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View { VStack(alignment: .leading, spacing: 8) { Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.5)).padding(.leading, 8); MacGlassPanel { content } }.frame(maxWidth: .infinity, alignment: .leading) }
}

private struct MacSettingsRow<Accessory: View>: View {
    let icon: String; let color: Color; let title: String; let detail: String?; let accessory: Accessory
    init(icon: String, color: Color, title: String, detail: String?, @ViewBuilder accessory: () -> Accessory) { self.icon = icon; self.color = color; self.title = title; self.detail = detail; self.accessory = accessory() }
    var body: some View { HStack(spacing: 13) { ZStack { Circle().fill(color.opacity(0.24)); Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(color) }.frame(width: 31, height: 31); VStack(alignment: .leading, spacing: 2) { Text(title).font(.headline); if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) } }; Spacer(minLength: 16); accessory }.padding(.horizontal, 14).padding(.vertical, 12).contentShape(Rectangle()) }
}

private struct MacSettingsDivider: View { var body: some View { Divider().overlay(.white.opacity(0.08)).padding(.leading, 58) } }
private struct MacSettingsFootnote: View { let text: String; let color: Color; init(_ text: String, color: Color = .secondary) { self.text = text; self.color = color }; var body: some View { Text(text).font(.caption).foregroundStyle(color).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8) } }

private enum MacBackupCoordinator {
    static let keys = [
        "performanceModeEnabled", "performanceModeSkipAniListTraversalForAnimeDetails", "macPlayerSeekSeconds", "defaultPlaybackSpeed",
        "enableSubtitlesByDefault", "defaultSubtitleLanguage", "preferredAutoAudioLanguage", "preferredAnimeAudioLanguage",
        "subtitles_fontSize", "subtitles_strokeWidth", "playerSubtitleOverlayBottomConstant", "subtitles_closedCaptionBackground",
        "mpvPictureInPictureEnabled", "mpvPlayerSkin", "mpvPlayerSkinTintControlsOnly", "experimentalMPVShowRemainingTime",
        "experimentalMPVPreciseProgress", "experimentalMPVIgnoreSpecialSubtitleStyles", "audioComfortMode", "macMPVStreamCacheEnabled",
        "macMPVStreamCacheLimitMB", "mpvHDRMode", "mpvMetalQualityProfile", "mpvUpscalingMode", "appearancePalette",
        "atmosphereStyle", "appearanceBleedStrength", "appearanceBackgroundIntensity", "homeAnimatedBackgroundEnabled",
        "homeAnimatedBackgroundQuality", "homeAnimatedBackgroundFrameRate", "experimentalMediaDesignPreset",
        "experimentalHomeCardShape", "experimentalMediaCardScale", "experimentalHeroHeightScale",
        "experimentalSectionSpacingScale", "experimentalCardRadiusScale", "heroBannerCatalogId", "heroBannerBehavior", "defaultScheduleMode",
        "scheduleWindowDays", "localNotificationEpisodeLeadTime", "localNotificationSeasonLeadTime", "localNotificationIncludeAnimeSpecials",
        "macScheduleNotificationsEnabled", "macHomeShowTrending", "macHomeShowTrendingAnime", "macHomeShowPopularMovies",
        "macHomeShowPopularAnime", "macHomeShowPopularShows", "macHomeShowAiringAnime", "macHomeShowUpcomingAnime",
        "macHomeShowTopRated", "macHomeShowTopRatedAnime", "macHomeCatalogOrder", "autoUpdateServicesEnabled",
        "servicesAutoModeEnabled", "servicesAutoSelectEpisodesEnabled", "servicesAutoModeSourceIds", "servicesAutoModeSourceOrderIds",
        "servicesAutoModeQualityPreference", "servicesResultMinimumSimilarity", "servicesDropMismatchedResults",
        "servicesIncludedStreamLanguages", "servicesHiddenStreamLanguages", "servicesHiddenStreamQualities",
        "servicesHideStreamsWithoutLanguageData", "servicesHideStreamsWithoutDetectedQuality", "macTrackerSyncEnabled",
        "macTrackerAutoSyncRatings", "macTrackerReaderSyncEnabled", "macLiveTraktScrobbling", "autoClearCacheEnabled",
        "autoClearCacheThresholdMB", "macReaderDirection", "macReaderBackground", "macReaderPageGap", "readerFontSize",
        "readerFontFamily", "readerFontWeight", "readerTextAlignment", "readerLineSpacing", "readerMargin", "macMediaLibrary.v1",
        "macPlaybackProgress.v1", "macMediaRatings.v1"
    ]
    private static let boolKeys: Set<String> = [
        "performanceModeEnabled", "performanceModeSkipAniListTraversalForAnimeDetails",
        "enableSubtitlesByDefault", "subtitles_closedCaptionBackground", "mpvPictureInPictureEnabled",
        "mpvPlayerSkinTintControlsOnly", "experimentalMPVShowRemainingTime", "experimentalMPVPreciseProgress",
        "experimentalMPVIgnoreSpecialSubtitleStyles", "macMPVStreamCacheEnabled", "homeAnimatedBackgroundEnabled",
        "localNotificationIncludeAnimeSpecials", "macScheduleNotificationsEnabled", "macHomeShowTrending", "macHomeShowTrendingAnime",
        "macHomeShowPopularMovies", "macHomeShowPopularAnime", "macHomeShowPopularShows", "macHomeShowAiringAnime",
        "macHomeShowUpcomingAnime", "macHomeShowTopRated", "macHomeShowTopRatedAnime", "autoUpdateServicesEnabled",
        "servicesAutoModeEnabled", "servicesAutoSelectEpisodesEnabled", "servicesDropMismatchedResults",
        "servicesHideStreamsWithoutLanguageData", "servicesHideStreamsWithoutDetectedQuality",
        "macTrackerSyncEnabled", "macTrackerAutoSyncRatings", "macTrackerReaderSyncEnabled",
        "macLiveTraktScrobbling", "autoClearCacheEnabled"
    ]
    private static let doubleRanges: [String: ClosedRange<Double>] = [
        "macPlayerSeekSeconds": 5...60, "defaultPlaybackSpeed": 0.25...4,
        "subtitles_fontSize": 12...72, "subtitles_strokeWidth": 0...4,
        "playerSubtitleOverlayBottomConstant": -24...24,
        "appearanceBleedStrength": 0...1.2, "appearanceBackgroundIntensity": 0.6...1.3,
        "experimentalMediaCardScale": 0.75...1.35, "experimentalHeroHeightScale": 0.75...1.15,
        "experimentalSectionSpacingScale": 0.75...1.35, "experimentalCardRadiusScale": 0.7...1.4,
        "servicesResultMinimumSimilarity": 0.5...1, "autoClearCacheThresholdMB": 100...5_000,
        "macReaderPageGap": 0...40, "readerFontSize": 12...32,
        "readerLineSpacing": 1...3, "readerMargin": 0...30
    ]
    private static let integerRanges: [String: ClosedRange<Int>] = [
        "scheduleWindowDays": 1...30, "localNotificationEpisodeLeadTime": 0...86_400,
        "localNotificationSeasonLeadTime": 0...604_800, "macMPVStreamCacheLimitMB": 32...512
    ]
    private static let stringValues: [String: Set<String>] = [
        "mpvHDRMode": ["auto", "hdr", "sdr"],
        "mpvMetalQualityProfile": ["auto", "balanced", "lowHeat", "sharp"],
        "mpvUpscalingMode": ["off", "upscaleTo1080", "upscaleTo4K", "oneLevelAlways", "auto"],
        "mpvPlayerSkin": ["default", "blackAndGold", "prismatic", "cyberpunk"],
        "audioComfortMode": ["original", "comfort", "dialogue", "night"],
        "appearancePalette": ["midnightPurple", "nocturne", "velvet", "mutedAurora"],
        "atmosphereStyle": ["multiGradient", "gradient", "solid"],
        "homeAnimatedBackgroundQuality": ["low", "medium", "high"],
        "homeAnimatedBackgroundFrameRate": ["fps20", "fps30"],
        "experimentalMediaDesignPreset": ["cinematic", "balanced", "compact"],
        "experimentalHomeCardShape": ["automatic", "poster", "landscape"],
        "heroBannerCatalogId": Set(MacHomeCatalogID.allCases.map(\.rawValue)),
        "heroBannerBehavior": ["static", "carousel"],
        "defaultScheduleMode": ["anime", "western", "combined"],
        "servicesAutoModeQualityPreference": ["manual", "auto", "best", "highest", "2160p", "1080p", "720p", "480p", "lowest"],
        "macReaderDirection": Set(MacReaderDirection.allCases.map(\.rawValue)),
        "macReaderBackground": Set(MacReaderBackground.allCases.map(\.rawValue)),
        "readerFontFamily": ["-apple-system", "Georgia", "Menlo", "ui-rounded"],
        "readerFontWeight": ["normal", "500", "700"],
        "readerTextAlignment": ["left", "center"]
    ]
    private static let languageKeys: Set<String> = ["defaultSubtitleLanguage", "preferredAutoAudioLanguage", "preferredAnimeAudioLanguage"]
    private static let dataKeys: Set<String> = ["macMediaLibrary.v1", "macPlaybackProgress.v1", "macMediaRatings.v1"]
    private static let stringArrayKeys: Set<String> = ["servicesAutoModeSourceIds", "servicesAutoModeSourceOrderIds", "servicesIncludedStreamLanguages", "servicesHiddenStreamLanguages"]
    private static let integerArrayKeys: Set<String> = ["servicesHiddenStreamQualities"]

    static func export(to url: URL) throws {
        let defaults = UserDefaults.standard
        let values = Dictionary(uniqueKeysWithValues: keys.compactMap { key in defaults.object(forKey: key).map { (key, $0) } })
        let payload: [String: Any] = ["format": "EclipseMacBackup", "version": 1, "createdAt": Date(), "values": values]
        let data = try PropertyListSerialization.data(fromPropertyList: payload, format: .xml, options: 0)
        guard data.count <= 12 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: url, options: .atomic)
    }

    static func restore(from url: URL) throws {
        let resources = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard resources.isRegularFile == true, (resources.fileSize ?? 0) <= 12 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let payload = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              payload["format"] as? String == "EclipseMacBackup",
              (payload["version"] as? NSNumber)?.intValue == 1,
              let values = payload["values"] as? [String: Any],
              values.count <= keys.count else { throw CocoaError(.fileReadCorruptFile) }

        var sanitized: [String: Any] = [:]
        for (key, value) in values where keys.contains(key) {
            guard let clean = sanitizedValue(value, for: key) else { throw CocoaError(.fileReadCorruptFile) }
            sanitized[key] = clean
        }
        for (key, value) in sanitized { UserDefaults.standard.set(value, forKey: key) }
    }

    private static func sanitizedValue(_ value: Any, for key: String) -> Any? {
        if boolKeys.contains(key) {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }
        if let range = doubleRanges[key] {
            guard let number = value as? NSNumber, number.doubleValue.isFinite, range.contains(number.doubleValue) else { return nil }
            return number.doubleValue
        }
        if let range = integerRanges[key] {
            guard let number = value as? NSNumber, range.contains(number.intValue), number.doubleValue == Double(number.intValue) else { return nil }
            return number.intValue
        }
        if let allowed = stringValues[key] {
            guard let string = value as? String, allowed.contains(string) else { return nil }
            return string
        }
        if languageKeys.contains(key) {
            guard let string = value as? String, (2...12).contains(string.count), string.unicodeScalars.allSatisfy({ CharacterSet.letters.union(CharacterSet(charactersIn: "-_" )).contains($0) }) else { return nil }
            return string
        }
        if key == "macHomeCatalogOrder" {
            guard let string = value as? String else { return nil }
            var seen = Set<MacHomeCatalogID>()
            let values = string.split(separator: ",").compactMap { MacHomeCatalogID(rawValue: String($0)) }.filter { seen.insert($0).inserted }
            guard !values.isEmpty else { return nil }
            let completed = values + MacHomeCatalogID.allCases.filter { seen.insert($0).inserted }
            return completed.map(\.rawValue).joined(separator: ",")
        }
        if dataKeys.contains(key) {
            guard let data = value as? Data, data.count <= 8 * 1024 * 1024 else { return nil }
            return data
        }
        if stringArrayKeys.contains(key) {
            guard let raw = value as? [Any], raw.count <= 100 else { return nil }
            var seen = Set<String>()
            let strings = raw.compactMap { $0 as? String }.filter { !$0.isEmpty && $0.count <= 160 && seen.insert($0).inserted }
            guard strings.count == raw.count else { return nil }
            return strings
        }
        if integerArrayKeys.contains(key) {
            guard let raw = value as? [Any], raw.count <= 12 else { return nil }
            let supported = Set([2160, 1440, 1080, 720, 480, 360])
            let values = raw.compactMap { ($0 as? NSNumber)?.intValue }
            guard values.count == raw.count, values.allSatisfy(supported.contains) else { return nil }
            return Array(Set(values)).sorted(by: >)
        }
        return nil
    }
}

@MainActor
private final class MacSupportStore: ObservableObject {
    @Published var products: [Product] = []
    @Published var isLoading = false
    @Published var purchasingID: String?
    @Published var message: String?
    private let ids = ["idkbruh", "idkbruh2", "idkbruh3", "idkbruh4"]

    func load() async {
        guard !isLoading else { return }
        isLoading = true; defer { isLoading = false }
        do {
            let loaded = try await Product.products(for: ids)
            products = loaded.sorted { (ids.firstIndex(of: $0.id) ?? .max) < (ids.firstIndex(of: $1.id) ?? .max) }
            message = products.isEmpty ? "Prices will appear when these purchases become available for Eclipse." : nil
        } catch { message = "Support purchases are temporarily unavailable." }
    }

    func purchase(_ product: Product) async {
        purchasingID = product.id; message = nil; defer { purchasingID = nil }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else { throw StoreError.unverified }
                await transaction.finish(); message = "Thanks for supporting Eclipse."
            case .pending: message = "Purchase pending approval."
            case .userCancelled: break
            @unknown default: message = "Purchase could not be completed."
            }
        } catch { message = "Purchase could not be completed." }
    }

    func restore() async {
        do { try await AppStore.sync(); message = "Purchases restored." }
        catch { message = "Restore could not be completed." }
    }

    private enum StoreError: Error { case unverified }
}

private struct MacSupportView: View {
    @StateObject private var store = MacSupportStore()
    private let fallback: [(String, String, String)] = [
        ("idkbruh", "Tip", "$1"), ("idkbruh2", "Big Tip", "$5"),
        ("idkbruh3", "Huge Tip", "$10"), ("idkbruh4", "Monthly Support", "$3/month")
    ]

    var body: some View {
        VStack(spacing: 18) {
            MacSettingsGroup("Support") {
                Text("Choose an optional way to support Eclipse. Purchases do not unlock features.")
                    .foregroundStyle(.secondary)
                    .padding(14)

                if store.isLoading && store.products.isEmpty {
                    MacSettingsDivider()
                    ProgressView("Loading App Store prices…")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                } else if store.products.isEmpty {
                    ForEach(Array(fallback.enumerated()), id: \.element.0) { index, item in
                        if index > 0 || !store.isLoading { MacSettingsDivider() }
                        MacSettingsRow(icon: "heart.fill", color: .pink, title: item.1, detail: "App Store purchase") {
                            Text(item.2).foregroundStyle(.secondary)
                        }
                    }
                    MacSettingsDivider()
                    Button { Task { await store.load() } } label: {
                        MacSettingsRow(icon: "arrow.clockwise", color: .blue, title: "Reload Prices", detail: nil) { EmptyView() }
                    }
                    .buttonStyle(.plain)
                } else {
                    ForEach(Array(store.products.enumerated()), id: \.element.id) { index, product in
                        if index > 0 { MacSettingsDivider() }
                        Button { Task { await store.purchase(product) } } label: {
                            MacSettingsRow(
                                icon: "heart.fill",
                                color: .pink,
                                title: product.displayName.isEmpty ? (fallback.first { $0.0 == product.id }?.1 ?? "Support") : product.displayName,
                                detail: product.description.isEmpty ? "Optional support purchase" : product.description
                            ) {
                                if store.purchasingID == product.id { ProgressView().controlSize(.small) }
                                else { Text(product.displayPrice) }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(store.purchasingID != nil)
                    }
                    MacSettingsDivider()
                    Button { Task { await store.restore() } } label: {
                        MacSettingsRow(icon: "arrow.clockwise.circle", color: .cyan, title: "Restore Purchases", detail: nil) { EmptyView() }
                    }
                    .buttonStyle(.plain)
                }

                if let message = store.message {
                    MacSettingsDivider()
                    Text(message).font(.caption).foregroundStyle(.secondary).padding(14)
                }
            }
            .id(MacSettingsAnchor.support)

            MacSettingsGroup("Community") {
                Link(destination: URL(string: "https://discord.gg/UjHgGaEbn")!) {
                    MacSettingsRow(icon: "bubble.left.and.bubble.right.fill", color: .indigo, title: "Join Discord", detail: "News, help, and the Eclipse community.") {
                        Image(systemName: "arrow.up.right").foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .task { await store.load() }
    }
}
