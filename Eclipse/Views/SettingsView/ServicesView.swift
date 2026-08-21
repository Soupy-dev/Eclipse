//
//  ServicesView.swift
//  Sora
//
//  Created by Francesco on 09/08/25.
//

import SwiftUI
import Kingfisher

enum ServicesSettingsSearchTarget: Hashable {
    case autoUpdateServices
    case autoMode
    case autoSelectEpisodes
    case autoQuality
    case autoQualityPreference
    case autoModeErrorIntelligence
    case blockAddonSubtitles
    case blockAddonCatalogs
    case stremioStyleSheet
    case rankingSimilarity
    case dropMismatchedResults
    case languagesToInclude
    case languagesToExclude
    case assumeOriginalAudio
    case treatDubbedAnimeAsEnglish
    case missingLanguageData
    case qualitiesToHide
    case hideStreamsWithoutDetectedQuality
    case applyExtraRulesTo
    case installedSource(String)

    var anchorID: String {
        switch self {
        case .autoUpdateServices: return "services-settings-search-autoUpdateServices"
        case .autoMode: return "services-settings-search-autoMode"
        case .autoSelectEpisodes: return "services-settings-search-autoSelectEpisodes"
        case .autoQuality: return "services-settings-search-autoQuality"
        case .autoQualityPreference: return "services-settings-search-autoQualityPreference"
        case .autoModeErrorIntelligence: return "services-settings-search-autoModeErrorIntelligence"
        case .blockAddonSubtitles: return "services-settings-search-blockAddonSubtitles"
        case .blockAddonCatalogs: return "services-settings-search-blockAddonCatalogs"
        case .stremioStyleSheet: return "services-settings-search-stremioStyleSheet"
        case .rankingSimilarity: return "services-settings-search-rankingSimilarity"
        case .dropMismatchedResults: return "services-settings-search-dropMismatchedResults"
        case .languagesToInclude: return "services-settings-search-languagesToInclude"
        case .languagesToExclude: return "services-settings-search-languagesToExclude"
        case .assumeOriginalAudio: return "services-settings-search-assumeOriginalAudio"
        case .treatDubbedAnimeAsEnglish: return "services-settings-search-treatDubbedAnimeAsEnglish"
        case .missingLanguageData: return "services-settings-search-missingLanguageData"
        case .qualitiesToHide: return "services-settings-search-qualitiesToHide"
        case .hideStreamsWithoutDetectedQuality: return "services-settings-search-hideStreamsWithoutDetectedQuality"
        case .applyExtraRulesTo: return "services-settings-search-applyExtraRulesTo"
        case .installedSource(let sourceID): return "services-settings-source-\(sourceID)"
        }
    }

    var opensExtraServiceSettings: Bool {
        switch self {
        case .stremioStyleSheet,
             .languagesToInclude,
             .languagesToExclude,
             .assumeOriginalAudio,
             .treatDubbedAnimeAsEnglish,
             .missingLanguageData,
             .rankingSimilarity,
             .dropMismatchedResults,
             .qualitiesToHide,
             .hideStreamsWithoutDetectedQuality,
             .blockAddonSubtitles,
             .blockAddonCatalogs,
             .applyExtraRulesTo:
            true
        case .autoUpdateServices,
             .autoMode,
             .autoSelectEpisodes,
             .autoQuality,
             .autoQualityPreference,
             .autoModeErrorIntelligence,
             .installedSource:
            false
        }
    }

    var opensAutoModeSettings: Bool {
        switch self {
        case .autoMode,
             .autoSelectEpisodes,
             .autoQuality,
             .autoQualityPreference,
             .autoModeErrorIntelligence:
            true
        case .autoUpdateServices,
             .blockAddonSubtitles,
             .blockAddonCatalogs,
             .stremioStyleSheet,
             .rankingSimilarity,
             .dropMismatchedResults,
             .languagesToInclude,
             .languagesToExclude,
             .assumeOriginalAudio,
             .treatDubbedAnimeAsEnglish,
             .missingLanguageData,
             .qualitiesToHide,
             .hideStreamsWithoutDetectedQuality,
             .applyExtraRulesTo,
             .installedSource:
            false
        }
    }
}

struct ServicesView: View {
    let initialSearchTarget: ServicesSettingsSearchTarget?
    @StateObject private var serviceManager = ServiceManager.shared
    @StateObject private var stremioManager = StremioAddonManager.shared
    @StateObject private var skyStreamManager = SkyStreamPluginManager.shared
#if os(iOS) && !targetEnvironment(macCatalyst)
    @StateObject private var nuvioManager = NuvioPluginManager.shared
#endif
    @StateObject private var healthStore = SourceHealthStore.shared
    @StateObject private var profileManager = ProfileManager.shared
#if !os(tvOS)
    @Environment(\.editMode) private var editMode
#endif
    @State private var showDownloadAlert = false
    @State private var downloadURL = ""
    @State private var serviceDownloadAlert: ServiceDownloadAlert?
    @AppStorage("autoUpdateServicesEnabled", store: ProfileSettingsStore.services) private var autoUpdateEnabled = true
    @State private var showStremioAddAlert = false
    @State private var stremioURL = ""
    @State private var stremioError: String?
    @State private var showStremioError = false
    @State private var pendingConfigureAddon: StremioAddon?

    @State private var pendingSkyStreamUninstall: PendingSkyStreamUninstall?
    @State private var skyStreamUninstallError: String?
    @AppStorage(AutoModeSettings.enabledKey, store: ProfileSettingsStore.services) private var servicesAutoModeEnabled = AutoModeSettings.defaultEnabled
    @AppStorage("servicesAutoSelectEpisodesEnabled", store: ProfileSettingsStore.services) private var servicesAutoSelectEpisodesEnabled = false
    @AppStorage("servicesAutoModeQualityPreference", store: ProfileSettingsStore.services) private var autoModeQualityPreferenceRaw = AutoModeQualityPreference.defaultPreference.rawValue
    @AppStorage(AutoModeErrorIntelligenceSettings.enabledKey, store: ProfileSettingsStore.services) private var autoModeErrorIntelligenceEnabled = AutoModeErrorIntelligenceSettings.defaultEnabled
    @State private var selectedAutoModeSourceIds: Set<String> = Set(ProfileSettingsStore.services.stringArray(forKey: "servicesAutoModeSourceIds") ?? [])
    @State private var autoModeSourceOrderIds: [String] = ProfileSettingsStore.services.stringArray(forKey: "servicesAutoModeSourceOrderIds") ?? []
    @State private var didFocusInitialSearchTarget = false
    @State private var didScheduleInitialExtraSettingsNavigation = false
    @State private var didScheduleInitialAutoModeSettingsNavigation = false
    @State private var showAutoModeSettings = false
    @State private var showExtraServiceSettings = false
    @State private var bulkSourceActivationError: String?
    @State private var showSkyStreamManager = false
#if os(iOS) && !targetEnvironment(macCatalyst)
    @State private var showNuvioManager = false
#endif

    init(initialSearchTarget: ServicesSettingsSearchTarget? = nil) {
        self.initialSearchTarget = initialSearchTarget
    }

    private var isAdministrable: Bool {
        profileManager.activeProfile?.isKidsProfile != true
    }

    private var hasAnyInstalledSources: Bool {
        !serviceManager.services.isEmpty ||
        !stremioManager.addons.isEmpty ||
        !skyStreamManager.providers.isEmpty ||
        hasInstalledNuvioSources
    }

    private var hasInstalledNuvioSources: Bool {
#if os(iOS) && !targetEnvironment(macCatalyst)
        !nuvioManager.repositories.isEmpty || !nuvioManager.scrapers.isEmpty
#else
        false
#endif
    }

    private struct ServiceDownloadAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var body: some View {
        ZStack {
            VStack {
                if !hasAnyInstalledSources && initialSearchTarget == nil {
                    emptyStateView
                } else {
                    servicesList
                }
            }
            .navigationTitle("Services")
            .eclipseSettingsStyle()
#if !os(tvOS)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isAdministrable {
                    Button {
                        withAnimation {
                            editMode?.wrappedValue =
                            (editMode?.wrappedValue == .active) ? .inactive : .active
                        }
                    } label: {
                        Image(systemName:
                                editMode?.wrappedValue == .active ? "checkmark" : "pencil")
                    }
                    .accessibilityLabel(
                        editMode?.wrappedValue == .active
                            ? "Finish Editing Services"
                            : "Edit Services"
                    )
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isAdministrable {
                    Menu {
                        addSourceActions
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Source")
                    }
                }
            }
#endif
            .refreshable {
                guard isAdministrable else { return }
                await serviceManager.updateServices()
                await stremioManager.refreshAddons()
#if os(iOS) && !targetEnvironment(macCatalyst)
                if PlatformCapabilities.current.supportsSkyStreamPlugins {
                    await skyStreamManager.refreshRepositoriesAndInstalledPlugins(autoUpdate: autoUpdateEnabled)
                }
                if PlatformCapabilities.current.supportsNuvioPlugins {
                    await nuvioManager.refreshRepositoriesAndInstalledPlugins(autoUpdate: autoUpdateEnabled)
                }
#endif
            }
            .modifier(AddServiceInputModifier(
                isPresented: $showDownloadAlert,
                downloadURL: $downloadURL,
                onAdd: { downloadServiceFromURL() }
            ))
            .modifier(AddStremioAddonInputModifier(
                isPresented: $showStremioAddAlert,
                addonURL: $stremioURL,
                onAdd: { addStremioAddon() }
            ))
            .alert(item: $serviceDownloadAlert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
            .alert("Stremio Error", isPresented: $showStremioError) {
                Button("OK", role: .cancel) { stremioError = nil }
            } message: {
                if let error = stremioError {
                    Text(error)
                }
            }
            .alert(item: $pendingSkyStreamUninstall) { pending in
                Alert(
                    title: Text(pending.title),
                    message: Text(pending.message),
                    primaryButton: .destructive(Text(pending.confirmationTitle)) {
                        uninstallSkyStreamPlugins(packageNames: pending.packageNames)
                    },
                    secondaryButton: .cancel()
                )
            }
            .alert("Couldn't Remove Plugin", isPresented: .constant(skyStreamUninstallError != nil)) {
                Button("OK", role: .cancel) { skyStreamUninstallError = nil }
            } message: {
                if let error = skyStreamUninstallError {
                    Text(error)
                }
            }
            .alert("Couldn't Update All Sources", isPresented: Binding(
                get: { bulkSourceActivationError != nil },
                set: { if !$0 { bulkSourceActivationError = nil } }
            )) {
                Button("OK", role: .cancel) { bulkSourceActivationError = nil }
            } message: {
                Text(bulkSourceActivationError ?? "One or more sources could not be updated.")
            }
            .sheet(item: $pendingConfigureAddon) { addon in
                StremioConfigureView(addon: addon, manager: stremioManager)
            }
#if os(iOS) && !targetEnvironment(macCatalyst)
            .sheet(isPresented: $showSkyStreamManager) {
                SkyStreamManagerView()
            }
            .sheet(isPresented: $showNuvioManager) {
                NuvioPluginManagerView()
            }
#endif
            .onAppear {
                _ = healthStore.version
                reloadAutoModeSelectionFromDefaults()
                if initialSearchTarget?.opensAutoModeSettings == true,
                   !didScheduleInitialAutoModeSettingsNavigation {
                    didScheduleInitialAutoModeSettingsNavigation = true
                    DispatchQueue.main.async {
                        showAutoModeSettings = true
                    }
                }
                if initialSearchTarget?.opensExtraServiceSettings == true,
                   !didScheduleInitialExtraSettingsNavigation {
                    didScheduleInitialExtraSettingsNavigation = true
                    DispatchQueue.main.async {
                        showExtraServiceSettings = true
                    }
                }
            }
        }
        .accessibilityIdentifier("tv.settings.services.screen")
    }

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Services")
                .font(.title2)
                .fontWeight(.semibold)
#if !os(tvOS)
            if isAdministrable {
                Menu {
                    addSourceActions
                } label: {
                    Label("Add Source", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Add Source")
            }
#endif
#if os(tvOS)
            if isAdministrable {
                HStack(spacing: 24) {
                    Button {
                        showDownloadAlert = true
                    } label: {
                        Label("Add Service", systemImage: "doc.badge.plus")
                    }
                    .accessibilityIdentifier("tv.services.addService")

                    Button {
                        showStremioAddAlert = true
                    } label: {
                        Label("Add Stremio Addon", systemImage: "play.circle")
                    }
                    .accessibilityIdentifier("tv.services.addStremio")
                }
            }
#endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

#if !os(tvOS)
    @ViewBuilder
    private var addSourceActions: some View {
        Button {
            showDownloadAlert = true
        } label: {
            Label("Add Service", systemImage: "doc.badge.plus")
        }
        Button {
            showStremioAddAlert = true
        } label: {
            Label("Add Stremio Addon", systemImage: "play.circle")
        }
#if os(iOS) && !targetEnvironment(macCatalyst)
        if PlatformCapabilities.current.supportsSkyStreamPlugins {
            Button {
                showSkyStreamManager = true
            } label: {
                Label("Add SkyStream Plugin", systemImage: "shippingbox")
            }
        }
        if PlatformCapabilities.current.supportsNuvioPlugins {
            Button {
                showNuvioManager = true
            } label: {
                Label("Add Nuvio Plugin", systemImage: "puzzlepiece.extension")
            }
        }
#endif
    }
#endif

    private enum UnifiedItem: Identifiable {
        case service(Service)
        case stremio(StremioAddon)
        case skyStream(SkyStreamProviderDescriptor)
#if os(iOS) && !targetEnvironment(macCatalyst)
        case nuvio(NuvioPluginScraper)
#endif

        var id: String {
            switch self {
            case .service(let s): return "service:\(s.id.uuidString)"
            case .stremio(let a): return "stremio:\(a.id.uuidString)"
            case .skyStream(let provider): return provider.id
#if os(iOS) && !targetEnvironment(macCatalyst)
            case .nuvio(let scraper): return scraper.id
#endif
            }
        }

        var sortIndex: Int64 {
            switch self {
            case .service(let s): return s.sortIndex
            case .stremio(let a): return a.sortIndex
            case .skyStream(let provider): return Int64(provider.sortIndex)
#if os(iOS) && !targetEnvironment(macCatalyst)
            case .nuvio: return Int64.max
#endif
            }
        }

        @MainActor var isActive: Bool {
            switch self {
            case .service(let s):
                return PlatformSourceActivation.isEnabled(sourceID: SourceHealth.serviceId(s), sharedValue: s.isActive)
                    && s.providerCapabilities.isSupportedOnCurrentPlatform
            case .stremio(let a):
                return PlatformSourceActivation.isEnabled(sourceID: SourceHealth.stremioId(a), sharedValue: a.isActive)
            case .skyStream(let provider):
                return provider.isEnabled
#if os(iOS) && !targetEnvironment(macCatalyst)
            case .nuvio(let scraper):
                return scraper.isRunnable
#endif
            }
        }

        var supportsAutoMode: Bool {
            switch self {
            case .service(let service):
                return service.providerCapabilities.isSupportedOnCurrentPlatform
            case .stremio(let a):
                return a.manifest.supportsStreams
            case .skyStream(let provider):
                return provider.compatibility.status != .incompatible
#if os(iOS) && !targetEnvironment(macCatalyst)
            case .nuvio:
                return true
#endif
            }
        }

        var isStremio: Bool {
            if case .stremio = self { return true }
            return false
        }

        var isCompatible: Bool {
            switch self {
            case .service(let service):
                return service.providerCapabilities.isSupportedOnCurrentPlatform
            case .stremio:
                return true
            case .skyStream(let provider):
                return provider.compatibility.status != .incompatible
#if os(iOS) && !targetEnvironment(macCatalyst)
            case .nuvio:
                return true
#endif
            }
        }

        var displayName: String {
            switch self {
            case .service(let s): return s.metadata.sourceName
            case .stremio(let a): return a.manifest.name
            case .skyStream(let provider): return provider.displayName
#if os(iOS) && !targetEnvironment(macCatalyst)
            case .nuvio(let scraper): return scraper.displayName
#endif
            }
        }

        var autoModeSourceId: String {
            switch self {
            case .service(let s): return "service:\(s.id.uuidString)"
            case .stremio(let a): return "stremio:\(a.id.uuidString)"
            case .skyStream(let provider): return provider.id
#if os(iOS) && !targetEnvironment(macCatalyst)
            case .nuvio(let scraper): return scraper.id
#endif
            }
        }

        var settingsSearchAnchorID: String {
            "services-settings-source-\(id)"
        }
    }

    private var unifiedItems: [UnifiedItem] {
        let services: [UnifiedItem] = serviceManager.services.map { .service($0) }
        let addons: [UnifiedItem] = stremioManager.addons.map { .stremio($0) }
        let skyStreamProviders: [UnifiedItem] = PlatformCapabilities.current.supportsSkyStreamPlugins
            ? skyStreamManager.providers.map { .skyStream($0) }
            : []
#if os(iOS) && !targetEnvironment(macCatalyst)
        let nuvioScrapers: [UnifiedItem] = PlatformCapabilities.current.supportsNuvioPlugins
            ? nuvioManager.activeScrapers.map { .nuvio($0) }
            : []
#else
        let nuvioScrapers: [UnifiedItem] = []
#endif
        var orderRank: [String: Int] = [:]
        for (index, sourceId) in autoModeSourceOrderIds.enumerated() where orderRank[sourceId] == nil {
            orderRank[sourceId] = index
        }
        return (services + addons + skyStreamProviders + nuvioScrapers).sorted {
            let lhsRank = orderRank[$0.autoModeSourceId]
            let rhsRank = orderRank[$1.autoModeSourceId]
            if let lhsRank, let rhsRank, lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            if lhsRank != nil {
                return true
            }
            if rhsRank != nil {
                return false
            }
            if $0.sortIndex == $1.sortIndex {
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            return $0.sortIndex < $1.sortIndex
        }
    }

    private var hasEnabledSource: Bool {
        if serviceManager.services.contains(where: serviceManager.isServiceEnabled) {
            return true
        }
        if stremioManager.addons.contains(where: stremioManager.isAddonEnabled) {
            return true
        }
        if skyStreamManager.providers.contains(where: { $0.isEnabled }) {
            return true
        }
#if os(iOS) && !targetEnvironment(macCatalyst)
        if !nuvioManager.activeScrapers.isEmpty {
            return true
        }
#endif
        return false
    }

    private var hasDisabledEnableableSource: Bool {
        if serviceManager.services.contains(where: {
            $0.platformCompatibilityError == nil && !serviceManager.isServiceEnabled($0)
        }) {
            return true
        }
        if stremioManager.addons.contains(where: { !stremioManager.isAddonEnabled($0) }) {
            return true
        }
        if skyStreamManager.providers.contains(where: {
            $0.compatibility.status != .incompatible && !$0.isEnabled
        }) {
            return true
        }
#if os(iOS) && !targetEnvironment(macCatalyst)
        if PlatformCapabilities.current.supportsNuvioPlugins {
            let activeIDs = Set(nuvioManager.activeScrapers.map(\.id))
            if nuvioManager.scrapers.contains(where: {
                $0.manifestEnabled && !activeIDs.contains($0.id)
            }) {
                return true
            }
        }
#endif
        return false
    }

    private enum AutoModeSourceItem: Identifiable {
        case service(Service)
        case stremio(StremioAddon)
        case skyStream(SkyStreamProviderDescriptor)
#if os(iOS) && !targetEnvironment(macCatalyst)
        case nuvio(NuvioPluginScraper)
#endif

        var id: String { autoModeSourceId }

        @MainActor var isActive: Bool {
            switch self {
            case .service(let service):
                return PlatformSourceActivation.isEnabled(sourceID: SourceHealth.serviceId(service), sharedValue: service.isActive)
                    && service.providerCapabilities.isSupportedOnCurrentPlatform
            case .stremio(let addon):
                return PlatformSourceActivation.isEnabled(sourceID: SourceHealth.stremioId(addon), sharedValue: addon.isActive)
            case .skyStream(let provider):
                return provider.isEnabled
#if os(iOS) && !targetEnvironment(macCatalyst)
            case .nuvio(let scraper):
                return scraper.isRunnable
#endif
            }
        }

        var supportsAutoMode: Bool {
            switch self {
            case .service(let service):
                return service.providerCapabilities.isSupportedOnCurrentPlatform
            case .stremio(let addon):
                return addon.manifest.supportsStreams
            case .skyStream(let provider):
                return provider.compatibility.status != .incompatible
#if os(iOS) && !targetEnvironment(macCatalyst)
            case .nuvio:
                return true
#endif
            }
        }

        var displayName: String {
            switch self {
            case .service(let service): return service.metadata.sourceName
            case .stremio(let addon): return addon.manifest.name
            case .skyStream(let provider): return provider.displayName
#if os(iOS) && !targetEnvironment(macCatalyst)
            case .nuvio(let scraper): return scraper.displayName
#endif
            }
        }

        var autoModeSourceId: String {
            switch self {
            case .service(let service): return "service:\(service.id.uuidString)"
            case .stremio(let addon): return "stremio:\(addon.id.uuidString)"
            case .skyStream(let provider): return provider.id
#if os(iOS) && !targetEnvironment(macCatalyst)
            case .nuvio(let scraper): return scraper.id
#endif
            }
        }
    }

    private func orderedAutoModeListItems(from items: [UnifiedItem]) -> [AutoModeSourceItem] {
        let activeItems: [AutoModeSourceItem] = items.compactMap { item in
            switch item {
            case .service(let service): return .service(service)
            case .stremio(let addon): return .stremio(addon)
            case .skyStream(let provider): return .skyStream(provider)
#if os(iOS) && !targetEnvironment(macCatalyst)
            case .nuvio(let scraper): return .nuvio(scraper)
#endif
            }
        }
        .filter { $0.isActive && $0.supportsAutoMode }
        let byId = activeItems.reduce(into: [String: AutoModeSourceItem]()) { result, item in
            if result[item.autoModeSourceId] == nil {
                result[item.autoModeSourceId] = item
            }
        }
        var ordered = autoModeSourceOrderIds.compactMap { byId[$0] }
        let existing = Set(ordered.map(\.autoModeSourceId))
        ordered.append(contentsOf: activeItems.filter { !existing.contains($0.autoModeSourceId) })
        return ordered
    }

    private var orderedAutoModeItems: [AutoModeSourceItem] {
        orderedAutoModeListItems(from: unifiedItems)
            .filter { selectedAutoModeSourceIds.contains($0.autoModeSourceId) }
    }

    private var autoModeQualityPreference: AutoModeQualityPreference {
        AutoModeQualityPreference(rawValue: autoModeQualityPreferenceRaw) ?? AutoModeQualityPreference.defaultPreference
    }

    private var autoModeQualityEnabledBinding: Binding<Bool> {
        Binding(
            get: { autoModeQualityPreference.usesAutomaticSelection },
            set: { enabled in
                guard isAdministrable else { return }
                if enabled {
                    if !autoModeQualityPreference.usesAutomaticSelection {
                        autoModeQualityPreferenceRaw = AutoModeQualityPreference.defaultPreference.rawValue
                    }
                } else {
                    autoModeQualityPreferenceRaw = AutoModeQualityPreference.manual.rawValue
                }
            }
        )
    }

    private var autoModeQualityPreferenceBinding: Binding<AutoModeQualityPreference> {
        Binding(
            get: { autoModeQualityPreference.usesAutomaticSelection ? autoModeQualityPreference : AutoModeQualityPreference.defaultPreference },
            set: { preference in
                guard isAdministrable else { return }
                let resolved = preference.usesAutomaticSelection ? preference : AutoModeQualityPreference.defaultPreference
                autoModeQualityPreferenceRaw = resolved.rawValue
            }
        )
    }

    private func administrableBinding(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding(
            get: { binding.wrappedValue },
            set: { value in
                guard isAdministrable else { return }
                binding.wrappedValue = value
            }
        )
    }

    private var autoModeSettingsSummary: String {
        guard servicesAutoModeEnabled else { return "Off" }
        let selectedCount = selectedAutoModeSourceIds.intersection(currentPlatformAutoModeSourceIDs).count
        return selectedCount == 1 ? "1 Source" : "\(selectedCount) Sources"
    }

    @ViewBuilder
    private var autoModeSettingsView: some View {
        ScrollViewReader { scrollProxy in
            let autoModeItems = orderedAutoModeListItems(from: unifiedItems)
            List {
                Section {
                    Toggle("Auto Mode", isOn: administrableBinding($servicesAutoModeEnabled))
                        .id(ServicesSettingsSearchTarget.autoMode.anchorID)

                    Toggle("Auto-Select Episodes", isOn: administrableBinding($servicesAutoSelectEpisodesEnabled))
                        .id(ServicesSettingsSearchTarget.autoSelectEpisodes.anchorID)
                } footer: {
                    Text("Auto-Select Episodes also applies when choosing a source manually.")
                }
                .eclipseExperimentalSettingsRows()

                Section {
                    Toggle("Auto Quality", isOn: autoModeQualityEnabledBinding)
                        .id(ServicesSettingsSearchTarget.autoQuality.anchorID)

                    if autoModeQualityPreference.usesAutomaticSelection {
                        Picker("Quality", selection: autoModeQualityPreferenceBinding) {
                            ForEach(AutoModeQualityPreference.allCases.filter(\.usesAutomaticSelection)) { preference in
                                Text(preference.title).tag(preference)
                            }
                        }
                        .id(ServicesSettingsSearchTarget.autoQualityPreference.anchorID)
                    }

                    Text(autoModeQualityPreference.settingsDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Toggle("Auto Mode Error Intelligence", isOn: administrableBinding($autoModeErrorIntelligenceEnabled))
                        .id(ServicesSettingsSearchTarget.autoModeErrorIntelligence.anchorID)
                } header: {
                    Text("Selection")
                } footer: {
                    Text("Turn Auto Quality off when you want to choose stream quality yourself. Error Intelligence skips sources that are known to be unavailable.")
                }
                .eclipseExperimentalSettingsRows()
                .disabled(!servicesAutoModeEnabled)

                Section {
                    Button {
                        setAllAutoModeSourcesSelected(true)
                    } label: {
                        Label("Include All Sources in Auto Mode", systemImage: "checkmark.circle")
                    }
                    .disabled(currentPlatformAutoModeSourceIDs.isSubset(of: selectedAutoModeSourceIds))

                    Button {
                        setAllAutoModeSourcesSelected(false)
                    } label: {
                        Label("Exclude All Sources from Auto Mode", systemImage: "circle.slash")
                    }
                    .disabled(selectedAutoModeSourceIds.isDisjoint(with: currentPlatformAutoModeSourceIDs))

                    if autoModeItems.isEmpty {
                        Text("Enable at least one stream-capable source to set its priority.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(autoModeItems.indices, id: \.self) { index in
                            let item = autoModeItems[index]
                            HStack {
                                Image(systemName: "line.3.horizontal")
                                    .foregroundColor(.secondary)
                                Text(item.displayName)
                                Spacer()
                                Toggle("", isOn: autoModeSelectionBinding(for: item))
                                    .labelsHidden()
                                    .accessibilityLabel("Include \(item.displayName) in Auto Mode")
#if os(tvOS)
                                Button {
                                    moveAutoModeSource(from: index, direction: -1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .accessibilityLabel("Move \(item.displayName) Up")
                                .disabled(index == 0)

                                Button {
                                    moveAutoModeSource(from: index, direction: 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .accessibilityLabel("Move \(item.displayName) Down")
                                .disabled(index >= autoModeItems.count - 1)
#endif
                            }
                        }
#if !os(tvOS)
                        .onMove(perform: moveAutoModeSources)
#endif
                    }
                } header: {
                    Text("Sources")
                } footer: {
#if os(tvOS)
                    Text("Auto Mode checks included, enabled sources from top to bottom. Use the arrow buttons to set priority. Include All and Exclude All also update installed sources that are currently disabled on this Apple TV, without changing sources that exist only on another platform.")
#else
                    Text("Auto Mode checks included, enabled sources from top to bottom. Drag to set priority. Include All and Exclude All also update installed sources that are currently disabled on this device, without changing sources that exist only on another platform.")
#endif
                }
                .eclipseExperimentalSettingsRows()
                .disabled(!servicesAutoModeEnabled)
            }
            .disabled(!isAdministrable)
            .navigationTitle("Auto Mode")
            .eclipseSettingsStyle()
            .onAppear {
                reloadAutoModeSelectionFromDefaults()
                focusInitialAutoModeSearchTarget(using: scrollProxy)
            }
        }
    }

    @ViewBuilder
    private var sourceActivationBulkControls: some View {
        Button {
            setAllSourcesEnabled(true)
        } label: {
            Label("Enable All Sources", systemImage: "checkmark.circle")
        }
        .disabled(!isAdministrable || !hasDisabledEnableableSource)

        Button {
            setAllSourcesEnabled(false)
        } label: {
            Label("Disable All Sources", systemImage: "pause.circle")
        }
        .disabled(!isAdministrable || !hasEnabledSource)
    }

    @ViewBuilder
    private var servicesList: some View {
        ScrollViewReader { scrollProxy in
            let unifiedItemsSnapshot = unifiedItems
            List {
#if os(tvOS)
            Section("Manage Sources") {
                if isAdministrable {
                    Button {
                        showDownloadAlert = true
                    } label: {
                        Label("Add Service", systemImage: "doc.badge.plus")
                    }
                    .accessibilityIdentifier("tv.services.addService")

                    Button {
                        showStremioAddAlert = true
                    } label: {
                        Label("Add Stremio Addon", systemImage: "play.circle")
                    }
                    .accessibilityIdentifier("tv.services.addStremio")
                }

                Button {
                    Task {
                        await serviceManager.updateServices()
                        await stremioManager.refreshAddons()
                    }
                } label: {
                    Label("Refresh Sources", systemImage: "arrow.clockwise")
                }
            }
            .eclipseExperimentalSettingsRows()
#endif

            Section {
                Toggle("Auto-Update Sources", isOn: $autoUpdateEnabled)
                    .id(ServicesSettingsSearchTarget.autoUpdateServices.anchorID)
            } footer: {
                Text("Automatically check for source updates when the app is opened.")
            }
            .eclipseExperimentalSettingsRows()
            .background(EclipseScrollTracker())

            Section {
                NavigationLink(isActive: $showAutoModeSettings) {
                    autoModeSettingsView
                } label: {
                    HStack {
                        Text("Auto Mode")
                        Spacer()
                        Text(autoModeSettingsSummary)
                            .foregroundColor(.secondary)
                    }
                }
            } footer: {
                Text("Choose how Eclipse automatically selects sources, episodes, and stream quality.")
            }
            .eclipseExperimentalSettingsRows()

            Section {
                NavigationLink(isActive: $showExtraServiceSettings) {
                    ExtraServiceSettingsView(
                        initialSearchTarget: initialSearchTarget,
                        isAdministrable: isAdministrable
                    )
                } label: {
                    Label("Extra Source Settings", systemImage: "slider.horizontal.3")
                }
            } footer: {
                Text(isAdministrable
                     ? "Configure the stream list layout, language, quality, and source rules."
                     : "The stream list layout, language, quality, and source rules. These are shared by everyone on this device, so a kids profile cannot change them. Switch to a grown-up profile to make those changes.")
            }
            .eclipseExperimentalSettingsRows()
            .disabled(!isAdministrable)

            Section(header: unifiedSectionHeader) {
                if !hasAnyInstalledSources {
                    Text("No stream sources installed")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                } else {
                    sourceActivationBulkControls

                    ForEach(Array(unifiedItemsSnapshot.enumerated()), id: \.element.id) { index, item in
                        switch item {
                        case .service(let service):
#if os(tvOS)
                            NavigationLink {
                                ServiceRow(
                                    service: service,
                                    serviceManager: serviceManager,
                                    healthStore: healthStore,
                                    canMoveUp: index > 0,
                                    canMoveDown: index < unifiedItemsSnapshot.count - 1,
                                    onMoveUp: { moveUnifiedItem(withID: item.id, direction: -1) },
                                    onMoveDown: { moveUnifiedItem(withID: item.id, direction: 1) },
                                    onRemove: isAdministrable ? { removeUnifiedItem(item) } : nil
                                )
                                .padding(60)
                                .navigationTitle(service.metadata.sourceName)
                            } label: {
                                tvUnifiedSourceLabel(item)
                            }
#else
                            ServiceRow(service: service, serviceManager: serviceManager, healthStore: healthStore)
                                .id(item.settingsSearchAnchorID)
#endif
                        case .stremio(let addon):
#if os(tvOS)
                            NavigationLink {
                                StremioAddonRow(
                                    addon: addon,
                                    manager: stremioManager,
                                    healthStore: healthStore,
                                    canAdminister: isAdministrable,
                                    canMoveUp: index > 0,
                                    canMoveDown: index < unifiedItemsSnapshot.count - 1,
                                    onMoveUp: { moveUnifiedItem(withID: item.id, direction: -1) },
                                    onMoveDown: { moveUnifiedItem(withID: item.id, direction: 1) },
                                    onRemove: isAdministrable ? { removeUnifiedItem(item) } : nil
                                )
                                .padding(60)
                                .navigationTitle(addon.manifest.name)
                            } label: {
                                tvUnifiedSourceLabel(item)
                            }
#else
                            StremioAddonRow(
                                addon: addon,
                                manager: stremioManager,
                                healthStore: healthStore,
                                canAdminister: isAdministrable
                            )
                            .id(item.settingsSearchAnchorID)
#endif
                        case .skyStream(let provider):
#if os(iOS) && !targetEnvironment(macCatalyst)
                            SkyStreamProviderRow(
                                provider: provider,
                                manager: skyStreamManager,
                                healthStore: healthStore,
                                canAdminister: isAdministrable
                            )
                            .id(item.settingsSearchAnchorID)
#else
                            EmptyView()
#endif
#if os(iOS) && !targetEnvironment(macCatalyst)
                        case .nuvio(let scraper):
                            NuvioProviderRow(
                                scraper: scraper,
                                manager: nuvioManager,
                                healthStore: healthStore,
                                canAdminister: isAdministrable
                            )
                            .id(item.settingsSearchAnchorID)
#endif
                        }
                    }
#if !os(tvOS)

                    .onDelete(perform: isAdministrable ? deleteUnifiedItems : nil)
                    .onMove(perform: isAdministrable ? moveUnifiedItems : nil)
#endif
                }
            }
            .eclipseExperimentalSettingsRows()
            }
            .onAppear {
                focusInitialSearchTarget(using: scrollProxy)
            }
        }
    }

    private func focusInitialSearchTarget(using scrollProxy: ScrollViewProxy) {
        guard !didFocusInitialSearchTarget,
              let initialSearchTarget,
              !initialSearchTarget.opensExtraServiceSettings,
              !initialSearchTarget.opensAutoModeSettings else { return }
        didFocusInitialSearchTarget = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeInOut(duration: 0.28)) {
                scrollProxy.scrollTo(initialSearchTarget.anchorID, anchor: .center)
            }
        }
    }

    private func focusInitialAutoModeSearchTarget(using scrollProxy: ScrollViewProxy) {
        guard !didFocusInitialSearchTarget,
              let initialSearchTarget,
              initialSearchTarget.opensAutoModeSettings else { return }
        didFocusInitialSearchTarget = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeInOut(duration: 0.28)) {
                scrollProxy.scrollTo(initialSearchTarget.anchorID, anchor: .center)
            }
        }
    }

    @ViewBuilder
    private var unifiedSectionHeader: some View {
        Text("Sources")
    }

#if os(tvOS)
    private func tvUnifiedSourceLabel(_ item: UnifiedItem) -> some View {
        HStack(spacing: 14) {
            Image(systemName: item.isStremio ? "play.circle" : "shippingbox")
                .foregroundColor(item.isCompatible ? .accentColor : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName)
                    .font(.headline)
                Text(item.isCompatible ? (item.isActive ? "Enabled" : "Disabled") : "Not compatible with Apple TV")
                    .font(.caption)
                    .foregroundColor(item.isCompatible ? .secondary : .orange)
            }
            Spacer()
            Text("Manage")
                .foregroundColor(.secondary)
        }
    }
#endif

    private func deleteUnifiedItems(offsets: IndexSet) {
        guard isAdministrable else { return }
        let items = unifiedItems

        var skyStreamProviders: [SkyStreamProviderDescriptor] = []
        for index in offsets {
            let item = items[index]
            if case .skyStream(let provider) = item {
                skyStreamProviders.append(provider)
                continue
            }
#if os(iOS) && !targetEnvironment(macCatalyst)
            if case .nuvio(let scraper) = item {
                disableNuvioScraper(scraper.id)
                continue
            }
#endif
            let sourceID = item.autoModeSourceId
            selectedAutoModeSourceIds.remove(sourceID)
            autoModeSourceOrderIds.removeAll { $0 == sourceID }
            AutoModeSourceSelection.removeSourceAuthoritatively(sourceID)
            switch item {
            case .service(let service):
                serviceManager.removeService(service)
            case .stremio(let addon):
                stremioManager.removeAddon(addon)
            case .skyStream:
                break
#if os(iOS) && !targetEnvironment(macCatalyst)
            case .nuvio:
                break
#endif
            }
        }
        requestSkyStreamUninstall(skyStreamProviders)
        syncAutoModeSelectionWithInstalledSources()
    }

    private func moveUnifiedItems(fromOffsets: IndexSet, toOffset: Int) {
        var items = unifiedItems
        items.move(fromOffsets: fromOffsets, toOffset: toOffset)

        let serviceEntities = ServiceStore.shared.getEntities()
        let stremioEntities = StremioAddonStore.shared.getEntities()

        for (index, item) in items.enumerated() {
            switch item {
            case .service(let service):
                if let entity = serviceEntities.first(where: { $0.id == service.id }) {
                    entity.sortIndex = Int64(index)
                }
            case .stremio(let addon):
                if let entity = stremioEntities.first(where: { $0.id == addon.id }) {
                    entity.sortIndex = Int64(index)
                }
            case .skyStream:
                break
#if os(iOS) && !targetEnvironment(macCatalyst)
            case .nuvio:
                break
#endif
            }
        }

        ServiceStore.shared.save()
        StremioAddonStore.shared.save()
        serviceManager.loadServicesFromCloud()
        stremioManager.loadAddons()
        persistUnifiedOrder(items)
        syncAutoModeSelectionWithInstalledSources()
    }

    private func moveUnifiedItem(at index: Int, direction: Int) {
        let destination = index + direction
        var items = unifiedItems
        guard items.indices.contains(index), items.indices.contains(destination) else { return }
        items.swapAt(index, destination)
        persistUnifiedItems(items)
    }

    private func moveUnifiedItem(withID id: String, direction: Int) {
        guard let index = unifiedItems.firstIndex(where: { $0.id == id }) else { return }
        moveUnifiedItem(at: index, direction: direction)
    }

    private func persistUnifiedItems(_ items: [UnifiedItem]) {
        let serviceEntities = ServiceStore.shared.getEntities()
        let stremioEntities = StremioAddonStore.shared.getEntities()
        for (index, item) in items.enumerated() {
            switch item {
            case .service(let service):
                serviceEntities.first(where: { $0.id == service.id })?.sortIndex = Int64(index)
            case .stremio(let addon):
                stremioEntities.first(where: { $0.id == addon.id })?.sortIndex = Int64(index)
            case .skyStream:
                break
#if os(iOS) && !targetEnvironment(macCatalyst)
            case .nuvio:
                break
#endif
            }
        }
        ServiceStore.shared.save()
        StremioAddonStore.shared.save()
        serviceManager.loadServicesFromCloud()
        stremioManager.loadAddons()
        persistUnifiedOrder(items)
        syncAutoModeSelectionWithInstalledSources()
    }

    private func removeUnifiedItem(_ item: UnifiedItem) {
        guard isAdministrable else { return }
        if case .skyStream(let provider) = item {
            requestSkyStreamUninstall([provider])
            return
        }
#if os(iOS) && !targetEnvironment(macCatalyst)
        if case .nuvio(let scraper) = item {
            disableNuvioScraper(scraper.id)
            return
        }
#endif
        selectedAutoModeSourceIds.remove(item.autoModeSourceId)
        autoModeSourceOrderIds.removeAll { $0 == item.autoModeSourceId }
        AutoModeSourceSelection.removeSourceAuthoritatively(item.autoModeSourceId)
        switch item {
        case .service(let service):
            serviceManager.removeService(service)
        case .stremio(let addon):
            stremioManager.removeAddon(addon)
        case .skyStream:
            break
#if os(iOS) && !targetEnvironment(macCatalyst)
        case .nuvio:
            break
#endif
        }
        syncAutoModeSelectionWithInstalledSources()
    }

    struct PendingSkyStreamUninstall: Identifiable {
        let packageNames: [String]
        let providerNames: [String]

        let siblingCount: Int

        var id: String { packageNames.joined(separator: "\u{1F}") }

        var title: String {
            providerNames.count == 1
                ? "Remove \(providerNames[0])?"
                : "Remove \(providerNames.count) sources?"
        }

        var confirmationTitle: String {
            packageNames.count == 1 ? "Remove Package" : "Remove Packages"
        }

        var message: String {
            let others = "\(siblingCount) other source\(siblingCount == 1 ? "" : "s")"
            if providerNames.count == 1 {
                return siblingCount == 0
                    ? "This uninstalls its plugin package, including its saved data and cookies."
                    : "\(providerNames[0]) is part of a plugin package that also provides \(others). Removing it uninstalls the whole package — all of them will disappear, along with its saved data and cookies."
            }
            let packages = "\(packageNames.count) plugin package\(packageNames.count == 1 ? "" : "s")"
            let names = providerNames.joined(separator: ", ")
            return siblingCount == 0
                ? "\(names) come from \(packages). Removing them uninstalls every one of those packages, along with their saved data and cookies."
                : "\(names) come from \(packages) that also provide \(others). Removing them uninstalls every one of those packages — all of those sources will disappear too, along with their saved data and cookies."
        }
    }

    private func requestSkyStreamUninstall(_ providers: [SkyStreamProviderDescriptor]) {
#if os(iOS) && !targetEnvironment(macCatalyst)
        guard isAdministrable, !providers.isEmpty else { return }
        var packageNames: [String] = []
        for provider in providers where !packageNames.contains(provider.packageName) {
            packageNames.append(provider.packageName)
        }
        let selectedIDs = Set(providers.map(\.id))
        let siblings = skyStreamManager.providers.filter {
            packageNames.contains($0.packageName) && !selectedIDs.contains($0.id)
        }
        pendingSkyStreamUninstall = PendingSkyStreamUninstall(
            packageNames: packageNames,
            providerNames: providers.map(\.displayName),
            siblingCount: siblings.count
        )
#endif
    }

    private func uninstallSkyStreamPlugins(packageNames: [String]) {
#if os(iOS) && !targetEnvironment(macCatalyst)
        guard isAdministrable else { return }
        Task {
            var failures: [String] = []
            for packageName in packageNames {
                do {
                    try await skyStreamManager.uninstall(packageName: packageName)
                } catch {

                    failures.append(error.localizedDescription)
                }
            }
            if !failures.isEmpty {
                skyStreamUninstallError = failures.joined(separator: "\n")
            }
            reloadAutoModeSelectionFromDefaults()
        }
#endif
    }

#if os(iOS) && !targetEnvironment(macCatalyst)
    private func disableNuvioScraper(_ scraperID: String) {
        guard isAdministrable else { return }
        nuvioManager.setScraperEnabled(scraperID, enabled: false)
        reloadAutoModeSelectionFromDefaults()
    }
#endif

    private func addStremioAddon() {
        guard isAdministrable,
              !stremioURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        Task {
            do {
                let addon = try await stremioManager.addAddon(from: stremioURL)
                await MainActor.run {
                    stremioURL = ""
                    reloadAutoModeSelectionFromDefaults()
                    if shouldPromptForStremioConfiguration(addon) {
                        pendingConfigureAddon = addon
                    }
                }
            } catch {
                await MainActor.run {
                    stremioError = error.localizedDescription
                    showStremioError = true
                }
            }
        }
    }

    private func shouldPromptForStremioConfiguration(_ addon: StremioAddon) -> Bool {
        let hints = addon.manifest.behaviorHints
        guard hints?.configurable == true else { return false }
        if hints?.configurationRequired == true {
            return true
        }
        return addon.manifest.supportsCatalogs && addon.manifest.homeCatalogs.isEmpty
    }

    private func autoModeSelectionBinding(for item: AutoModeSourceItem) -> Binding<Bool> {
        Binding(
            get: { selectedAutoModeSourceIds.contains(item.autoModeSourceId) },
            set: { isSelected in
                guard isAdministrable else { return }
                if isSelected {
                    selectedAutoModeSourceIds.insert(item.autoModeSourceId)
                } else {
                    selectedAutoModeSourceIds.remove(item.autoModeSourceId)
                }
                persistAutoModeSelection()
            }
        )
    }

    private func setAllAutoModeSourcesSelected(_ selected: Bool) {
        guard isAdministrable else { return }
        let sourceIDs = currentPlatformAutoModeSourceIDs
        if selected {
            selectedAutoModeSourceIds.formUnion(sourceIDs)
        } else {
            selectedAutoModeSourceIds.subtract(sourceIDs)
        }
        persistAutoModeSelection()
    }

    private func setAllSourcesEnabled(_ enabled: Bool) {
        guard isAdministrable else { return }
        let expectedProfileID = ProfileManager.shared.activeProfileID
        let expectedScopeGeneration = ServiceStoreScope.generation
        let services = serviceManager.services
        for service in services where !enabled || service.platformCompatibilityError == nil {
            serviceManager.setServiceState(service, isActive: enabled)
        }

        let addons = stremioManager.addons
        for addon in addons {
            stremioManager.setAddonState(addon, isActive: enabled)
        }

#if os(iOS) && !targetEnvironment(macCatalyst)
        if PlatformCapabilities.current.supportsNuvioPlugins {
            if enabled {
                nuvioManager.setPluginsEnabled(true)
            }
            for repository in nuvioManager.repositories {
                if enabled {
                    nuvioManager.setRepositoryEnabled(repository.id, enabled: true)
                }
                nuvioManager.setAllScrapersEnabled(enabled, inRepository: repository.id)
            }
        }
#endif

#if os(iOS) && !targetEnvironment(macCatalyst)
        let providers = skyStreamManager.providers.filter {
            !enabled || $0.compatibility.status != .incompatible
        }
        Task { @MainActor in
            var failures: [String] = []
            for provider in providers {
                guard ProfileManager.shared.activeProfileID == expectedProfileID,
                      ServiceStoreScope.isCurrent(expectedScopeGeneration) else { return }
                do {
                    try await skyStreamManager.setProviderEnabled(
                        sourceID: provider.id,
                        enabled: enabled,
                        expectedScopeGeneration: expectedScopeGeneration
                    )
                } catch {
                    guard ProfileManager.shared.activeProfileID == expectedProfileID,
                          ServiceStoreScope.isCurrent(expectedScopeGeneration) else { return }
                    failures.append("\(provider.displayName): \(error.localizedDescription)")
                }
            }
            guard ProfileManager.shared.activeProfileID == expectedProfileID,
                  ServiceStoreScope.isCurrent(expectedScopeGeneration) else { return }
            if !failures.isEmpty {
                bulkSourceActivationError = failures.joined(separator: "\n")
            }
            captureSkyStreamSourceDefaults()
        }
#endif
    }

    private func persistAutoModeSelection() {
        guard isAdministrable else { return }
        let orderedActive = orderedAutoModeListItems(from: unifiedItems).map(\.autoModeSourceId)
        ProfileSettingsStore.services.set(Array(selectedAutoModeSourceIds), forKey: "servicesAutoModeSourceIds")
        autoModeSourceOrderIds = mergedAutoModeOrder(visibleSourceIDs: orderedActive)
        ProfileSettingsStore.services.set(autoModeSourceOrderIds, forKey: "servicesAutoModeSourceOrderIds")
        captureSkyStreamSourceDefaults()
    }

    private func persistUnifiedOrder(_ items: [UnifiedItem]) {
        guard isAdministrable else { return }
        let ids = items.map(\.autoModeSourceId)
        autoModeSourceOrderIds = mergedAutoModeOrder(visibleSourceIDs: ids)
        ProfileSettingsStore.services.set(autoModeSourceOrderIds, forKey: "servicesAutoModeSourceOrderIds")
        captureSkyStreamSourceDefaults()
    }

    private func captureSkyStreamSourceDefaults() {
        guard isAdministrable else { return }
        let expectedProfileID = ProfileManager.shared.activeProfileID
        let expectedScopeGeneration = ServiceStoreScope.generation
        Task { @MainActor in
            guard ProfileManager.shared.activeProfileID == expectedProfileID,
                  ServiceStoreScope.isCurrent(expectedScopeGeneration) else { return }
            await skyStreamManager.captureSourceDefaultsState(
                expectedScopeGeneration: expectedScopeGeneration
            )
        }
    }

    private func reloadAutoModeSelectionFromDefaults() {
        let storedSelection = Set(ProfileSettingsStore.services.stringArray(forKey: "servicesAutoModeSourceIds") ?? [])
        if selectedAutoModeSourceIds != storedSelection {
            selectedAutoModeSourceIds = storedSelection
        }
        let storedOrder = ProfileSettingsStore.services.stringArray(forKey: "servicesAutoModeSourceOrderIds") ?? []
        if autoModeSourceOrderIds != storedOrder {
            autoModeSourceOrderIds = storedOrder
        }
        let sanitizedPreference = AutoModeQualityPreference.sanitizedRawValue(autoModeQualityPreferenceRaw)
        if autoModeQualityPreferenceRaw != sanitizedPreference {
            autoModeQualityPreferenceRaw = sanitizedPreference
        }
        syncAutoModeSelectionWithInstalledSources()
    }

    private func syncAutoModeSelectionWithInstalledSources() {
        let activeItems = orderedAutoModeListItems(from: unifiedItems)
        let validIds = installedAutoModeSourceIDs
        let previous = selectedAutoModeSourceIds
        let unavailablePlatformScopedIds = selectedAutoModeSourceIds.filter {
            StreamLanguageFilter.isPlatformScopedProviderSourceID($0)
        }
        selectedAutoModeSourceIds = selectedAutoModeSourceIds
            .intersection(validIds)
            .union(unavailablePlatformScopedIds)
        let ordered = mergedAutoModeOrder(
            visibleSourceIDs: activeItems.map(\.autoModeSourceId)
        )
        if selectedAutoModeSourceIds != previous || ordered != autoModeSourceOrderIds {
            autoModeSourceOrderIds = ordered
            persistAutoModeSelection()
        }
    }

    private var installedAutoModeSourceIDs: Set<String> {
        var ids = Set(serviceManager.services.map { "service:\($0.id.uuidString)" })
        ids.formUnion(stremioManager.addons.compactMap {
            $0.manifest.supportsStreams ? "stremio:\($0.id.uuidString)" : nil
        })
        ids.formUnion(skyStreamManager.providers.map(\.id))
#if os(iOS) && !targetEnvironment(macCatalyst)
        if PlatformCapabilities.current.supportsNuvioPlugins {
            ids.formUnion(nuvioManager.scrapers.filter(\.manifestEnabled).map(\.id))
        }
#endif
        return ids
    }

    private var currentPlatformAutoModeSourceIDs: Set<String> {
        var ids = Set(serviceManager.services.compactMap {
            $0.providerCapabilities.isSupportedOnCurrentPlatform
                ? "service:\($0.id.uuidString)"
                : nil
        })
        ids.formUnion(stremioManager.addons.compactMap {
            $0.manifest.supportsStreams ? "stremio:\($0.id.uuidString)" : nil
        })
        ids.formUnion(skyStreamManager.providers.compactMap {
            $0.compatibility.status != .incompatible ? $0.id : nil
        })
#if os(iOS) && !targetEnvironment(macCatalyst)
        if PlatformCapabilities.current.supportsNuvioPlugins {
            ids.formUnion(nuvioManager.scrapers.filter(\.manifestEnabled).map(\.id))
        }
#endif
        return ids
    }

    private func mergedAutoModeOrder(visibleSourceIDs: [String]) -> [String] {
        var seenVisible = Set<String>()
        let visible = visibleSourceIDs.filter { seenVisible.insert($0).inserted }
        let visibleSet = Set(visible)
        var remainingVisible = visible.makeIterator()
        var seenPrior = Set<String>()
        var result: [String] = []

        for sourceID in autoModeSourceOrderIds where seenPrior.insert(sourceID).inserted {
            if visibleSet.contains(sourceID) {
                if let replacement = remainingVisible.next() {
                    result.append(replacement)
                }
            } else {
                result.append(sourceID)
            }
        }

        while let sourceID = remainingVisible.next() {
            if !result.contains(sourceID) {
                result.append(sourceID)
            }
        }
        return result
    }

    private func moveAutoModeSources(fromOffsets: IndexSet, toOffset: Int) {
        guard isAdministrable else { return }
        var ids = orderedAutoModeListItems(from: unifiedItems).map(\.autoModeSourceId)
        ids.move(fromOffsets: fromOffsets, toOffset: toOffset)
        autoModeSourceOrderIds = mergedAutoModeOrder(visibleSourceIDs: ids)
        ProfileSettingsStore.services.set(autoModeSourceOrderIds, forKey: "servicesAutoModeSourceOrderIds")
        captureSkyStreamSourceDefaults()
    }

    private func moveAutoModeSource(from index: Int, direction: Int) {
        guard isAdministrable else { return }
        let target = index + direction
        var ids = orderedAutoModeListItems(from: unifiedItems).map(\.autoModeSourceId)
        guard ids.indices.contains(index), ids.indices.contains(target) else { return }
        ids.swapAt(index, target)
        autoModeSourceOrderIds = mergedAutoModeOrder(visibleSourceIDs: ids)
        ProfileSettingsStore.services.set(autoModeSourceOrderIds, forKey: "servicesAutoModeSourceOrderIds")
        captureSkyStreamSourceDefaults()
    }

    private func downloadServiceFromURL() {
        guard isAdministrable,
              !downloadURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        Task {
            do {
                let wasHandled = try await serviceManager.handlePotentialServiceURL(downloadURL)
                if wasHandled {
                    await MainActor.run {
                        downloadURL = ""
                        reloadAutoModeSelectionFromDefaults()
                        serviceDownloadAlert = ServiceDownloadAlert(
                            title: "Service Downloaded",
                            message: "The service has been successfully downloaded and saved."
                        )
                    }
                } else {
                    await MainActor.run {
                        serviceDownloadAlert = ServiceDownloadAlert(
                            title: "Service Download Failed",
                            message: "Enter a direct JSON service URL."
                        )
                    }
                }
            } catch {
                await MainActor.run {
                    serviceDownloadAlert = ServiceDownloadAlert(
                        title: "Service Download Failed",
                        message: error.localizedDescription
                    )
                }
            }
        }
    }
}

struct ServiceRow: View {
    let service: Service
    @ObservedObject var serviceManager: ServiceManager
    @ObservedObject var healthStore: SourceHealthStore
    var canMoveUp = false
    var canMoveDown = false
    var onMoveUp: (() -> Void)? = nil
    var onMoveDown: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil
    @State private var showingSettings = false
#if os(tvOS)
    @Environment(\.dismiss) private var dismiss
    @State private var showingRemoveConfirmation = false
#endif

    private var isServiceActive: Bool {
        if let managedService = serviceManager.services.first(where: { $0.id == service.id }) {
            return serviceManager.isServiceEnabled(managedService)
        }
        return serviceManager.isServiceEnabled(service)
    }

    private var hasSettings: Bool {
        service.metadata.settings == true
    }

    private var sourceId: String {
        SourceHealth.serviceId(service)
    }

    private var healthState: SourceHealthDisplayState {
        guard isServiceActive else { return .unchecked }
        return healthStore.displayStates[sourceId] ?? .unchecked
    }

    private var isQuarantined: Bool {
        ServiceJavaScriptQuarantineStore.shared.isQuarantined(service)
    }

    var body: some View {
        HStack {
            PinnedProviderImage(URL(string: service.metadata.iconUrl)) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .overlay(
                        Image(systemName: "app.dashed")
                            .foregroundColor(.secondary)
                    )
            }
                .frame(width: 40, height: 40)
                .clipShape(Circle())
                .padding(.trailing, 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(service.metadata.sourceName)
                    .font(.headline)
                    .foregroundStyle(.primary)

                HStack(spacing: 8) {
                    Text(service.metadata.author.name)
                        .font(.caption)
                        .foregroundStyle(.gray)

                    Text("•")
                        .font(.caption)
                        .foregroundStyle(.gray)

                    Text(service.metadata.language)
                        .font(.caption)
                        .foregroundStyle(.gray)

                    Text("•")
                        .font(.caption)
                        .foregroundStyle(.gray)

                    Text("v\(service.metadata.version)")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }

                healthStatusLabel

                if let compatibilityError = service.platformCompatibilityError {
                    Label(compatibilityError.localizedDescription, systemImage: "appletvremote.gen4.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                } else if let advisory = service.platformCompatibilityAdvisory {
                    Label(advisory.localizedDescription, systemImage: "exclamationmark.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if isQuarantined {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(
                            "Turned off because this source repeatedly stopped responding.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .lineLimit(3)

                        Button("Turn Back On") {
                            serviceManager.setServiceState(service, isActive: true)
                        }
                        .font(.caption2)
#if !os(tvOS)
                        .buttonStyle(.borderless)
#endif
                    }
                }
            }

            Spacer()

            HStack(spacing: 12) {
                if hasSettings {
                    Button(action: {
                        showingSettings = true
                    }) {
#if os(tvOS)
                        Label("Edit Settings", systemImage: "gearshape")
#else
                        Image(systemName: "pencil")
                            .foregroundStyle(Color.secondary)
                            .frame(width: 20, height: 20)
#endif
                    }
#if !os(tvOS)
                    .buttonStyle(PlainButtonStyle())
#endif
                }

#if os(tvOS)
                Button {
                    serviceManager.setServiceState(service, isActive: !isServiceActive)
                } label: {
                    Label(isServiceActive ? "Disable" : "Enable", systemImage: isServiceActive ? "pause.circle" : "play.circle")
                }
                .disabled(service.platformCompatibilityError != nil)

                Button(action: { onMoveUp?() }) {
                    Label("Move Up", systemImage: "chevron.up")
                }
                .disabled(!canMoveUp)

                Button(action: { onMoveDown?() }) {
                    Label("Move Down", systemImage: "chevron.down")
                }
                .disabled(!canMoveDown)

                if onRemove != nil {
                    Button(role: .destructive, action: { showingRemoveConfirmation = true }) {
                        Label("Remove", systemImage: "trash")
                    }
                }
#else
                if isServiceActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 20, height: 20)
                }
#endif
            }
        }
#if !os(tvOS)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                serviceManager.setServiceState(service, isActive: !isServiceActive)
            }
        }
#endif
        .sheet(isPresented: $showingSettings) {
            ServiceSettingsView(service: service, serviceManager: serviceManager)
        }
#if os(tvOS)
        .alert("Remove Service?", isPresented: $showingRemoveConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                onRemove?()
                dismiss()
            }
        } message: {
            Text("Remove \(service.metadata.sourceName) from this Apple TV?")
        }
#endif
    }

    @ViewBuilder
    private var healthStatusLabel: some View {
        switch healthState {
        case .healthy:
            Label("Reachable", systemImage: "checkmark.circle")
                .font(.caption2)
                .foregroundStyle(.green)
        case .warning(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(1)
        case .playbackIssue(let reason):
            Label(reason, systemImage: "play.slash")
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(1)
        case .stale:
            Label("Health check pending", systemImage: "clock")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .unchecked:
            EmptyView()
        }
    }
}

private struct AddServiceInputModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var downloadURL: String
    var onAdd: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 16, tvOS 16, *) {
            content
                .alert("Add Service", isPresented: $isPresented) {
                    TextField("JSON URL", text: $downloadURL)
                    Button("Cancel", role: .cancel) {
#if !os(tvOS)
                        downloadURL = ""
#endif
                    }
                    Button("Add") {
                        onAdd()
                    }
                } message: {
                    Text("Enter the direct JSON file URL")
                }
        } else {
            content
                .sheet(isPresented: $isPresented) {
                    NavigationView {
                        Form {
                            Section {
                                TextField("JSON URL", text: $downloadURL)
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                            } header: {
                                Text("Enter the direct JSON file URL")
                            }
                        }
                        .navigationTitle("Add Service")
                        #if !os(tvOS)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") {
                                    downloadURL = ""
                                    isPresented = false
                                }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Add") {
                                    isPresented = false
                                    onAdd()
                                }
                            }
                        }
                        #endif
                    }
                    .navigationViewStyle(StackNavigationViewStyle())
                }
        }
    }
}

struct StremioAddonRow: View {
    let addon: StremioAddon
    @ObservedObject var manager: StremioAddonManager
    @ObservedObject var healthStore: SourceHealthStore

    var canAdminister = true
    var canMoveUp = false
    var canMoveDown = false
    var onMoveUp: (() -> Void)? = nil
    var onMoveDown: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil
    @State private var showConfigure = false
    @State private var showReconfigure = false
    @State private var reconfigureURL = ""
    @State private var reconfigureError: String?
    @State private var showReconfigureError = false
    @State private var componentStateVersion = 0
#if os(tvOS)
    @Environment(\.dismiss) private var dismiss
    @State private var showingRemoveConfirmation = false
#endif

    private func componentEnabled(_ component: StremioAddonComponent) -> Bool {
        _ = componentStateVersion
        return StremioAddonComponentSettings.isEnabled(sourceID: sourceId, component: component)
    }

    private func toggleComponent(_ component: StremioAddonComponent) {
        let newValue = !componentEnabled(component)
        StremioAddonComponentSettings.setEnabled(newValue, sourceID: sourceId, component: component)
        componentStateVersion += 1
        if component == .catalogs {
            NotificationCenter.default.post(name: .catalogDataDidChange, object: nil)
        }
    }

    private var hasCatalogComponent: Bool {
        addon.manifest.supportsCatalogs && !addon.manifest.homeCatalogs.isEmpty
    }

    private var isAddonActive: Bool {
        if let managed = manager.addons.first(where: { $0.id == addon.id }) {
            return manager.isAddonEnabled(managed)
        }
        return manager.isAddonEnabled(addon)
    }

    private var isConfigurable: Bool {
        addon.manifest.behaviorHints?.configurable == true
    }

    private var resourceLabels: [(title: String, systemImage: String, dimmed: Bool)] {
        var labels: [(title: String, systemImage: String, dimmed: Bool)] = []
        if addon.manifest.supportsStreams {
            labels.append(("Streams", "play.rectangle", false))
        }
        if addon.manifest.supportsSubtitles {
            labels.append(("Subtitles", "captions.bubble", !componentEnabled(.subtitles)))
        }
        if !addon.manifest.homeCatalogs.isEmpty {
            labels.append(("Catalogs", "square.grid.2x2", !componentEnabled(.catalogs)))
        } else if addon.manifest.supportsCatalogs,
                  addon.manifest.behaviorHints?.configurable == true {
            labels.append(("Needs Config", "gearshape", false))
        }
        return labels
    }

    private var sourceId: String {
        SourceHealth.stremioId(addon)
    }

    private var healthState: SourceHealthDisplayState {
        guard isAddonActive else { return .unchecked }
        return healthStore.displayStates[sourceId] ?? .unchecked
    }

    var body: some View {
        HStack {
            if addon.manifest.logo != nil {
                PinnedProviderImage(
                    stremioResource: addon.manifest.logo,
                    configuredBaseURL: addon.configuredURL
                ) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.2))
                        .overlay(
                            Image(systemName: "play.circle")
                                .foregroundColor(.secondary)
                        )
                }
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                    .padding(.trailing, 10)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .overlay(
                        Image(systemName: "play.circle")
                            .foregroundColor(.secondary)
                    )
                    .frame(width: 40, height: 40)
                    .clipShape(Circle())
                    .padding(.trailing, 10)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(addon.manifest.name)
                    .font(.headline)
                    .foregroundStyle(.primary)

                HStack(spacing: 8) {
                    if let version = addon.manifest.version {
                        Text("v\(version)")
                            .font(.caption)
                            .foregroundStyle(.gray)
                    }

                    if let desc = addon.manifest.description, !desc.isEmpty {
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(.gray)

                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.gray)
                            .lineLimit(1)
                    }
                }

                if !resourceLabels.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(resourceLabels.indices, id: \.self) { index in
                            let label = resourceLabels[index]
                            Label(label.dimmed ? "\(label.title) (Off)" : label.title, systemImage: label.systemImage)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .opacity(label.dimmed ? 0.4 : 1)
                        }
                    }
                }

                healthStatusLabel
            }

            Spacer()

#if os(tvOS)
            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 10) {
                    if isConfigurable && canAdminister {
                        Button {
                            showConfigure = true
                        } label: {
                            Label("Configure", systemImage: "gearshape")
                        }
                    }

                    if canAdminister {
                        Button {
                            showReconfigure = true
                        } label: {
                            Label("Update URL", systemImage: "link")
                        }
                    }

                    Button {
                        manager.setAddonState(addon, isActive: !isAddonActive)
                    } label: {
                        Label(isAddonActive ? "Disable" : "Enable", systemImage: isAddonActive ? "pause.circle" : "play.circle")
                    }
                }

                if addon.manifest.supportsSubtitles || hasCatalogComponent {
                    HStack(spacing: 10) {
                        if addon.manifest.supportsSubtitles {
                            Button {
                                toggleComponent(.subtitles)
                            } label: {
                                Label(componentEnabled(.subtitles) ? "Disable Subtitles" : "Enable Subtitles", systemImage: "captions.bubble")
                            }
                        }
                        if hasCatalogComponent {
                            Button {
                                toggleComponent(.catalogs)
                            } label: {
                                Label(componentEnabled(.catalogs) ? "Disable Catalogs" : "Enable Catalogs", systemImage: "square.grid.2x2")
                            }
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button(action: { onMoveUp?() }) {
                        Label("Move Up", systemImage: "chevron.up")
                    }
                    .disabled(!canMoveUp)

                    Button(action: { onMoveDown?() }) {
                        Label("Move Down", systemImage: "chevron.down")
                    }
                    .disabled(!canMoveDown)

                    if onRemove != nil {
                        Button(role: .destructive, action: { showingRemoveConfirmation = true }) {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
            }
#else
            if isAddonActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20, height: 20)
            }
#endif
        }
#if !os(tvOS)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                manager.setAddonState(addon, isActive: !isAddonActive)
            }
        }
        .contextMenu {
            if isConfigurable && canAdminister {
                Button {
                    showConfigure = true
                } label: {
                    Label("Configure", systemImage: "gearshape")
                }
            }
            if canAdminister {
                Button {
                    showReconfigure = true
                } label: {
                    Label("Update URL", systemImage: "link")
                }
            }
            if addon.manifest.supportsSubtitles {
                Button {
                    toggleComponent(.subtitles)
                } label: {
                    Label(
                        componentEnabled(.subtitles) ? "Disable Subtitles" : "Enable Subtitles",
                        systemImage: "captions.bubble"
                    )
                }
            }
            if hasCatalogComponent {
                Button {
                    toggleComponent(.catalogs)
                } label: {
                    Label(
                        componentEnabled(.catalogs) ? "Disable Catalogs" : "Enable Catalogs",
                        systemImage: "square.grid.2x2"
                    )
                }
            }
        }
#endif
        .sheet(isPresented: $showConfigure) {
            StremioConfigureView(addon: addon, manager: manager)
        }
        .modifier(ReconfigureStremioAddonModifier(
            isPresented: $showReconfigure,
            addonURL: $reconfigureURL,
            onReconfigure: { reconfigureAddon() }
        ))
        .alert("Reconfigure Error", isPresented: $showReconfigureError) {
            Button("OK", role: .cancel) { reconfigureError = nil }
        } message: {
            if let error = reconfigureError {
                Text(error)
            }
        }
#if os(tvOS)
        .alert("Remove Stremio Addon?", isPresented: $showingRemoveConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                onRemove?()
                dismiss()
            }
        } message: {
            Text("Remove \(addon.manifest.name) from this Apple TV? The configured URL is also removed from Keychain.")
        }
#endif
    }

    @ViewBuilder
    private var healthStatusLabel: some View {
        switch healthState {
        case .healthy:
            Label("Reachable", systemImage: "checkmark.circle")
                .font(.caption2)
                .foregroundStyle(.green)
        case .warning(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(1)
        case .playbackIssue(let reason):
            Label(reason, systemImage: "play.slash")
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(1)
        case .stale:
            Label("Health check pending", systemImage: "clock")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .unchecked:
            EmptyView()
        }
    }

    private func reconfigureAddon() {
        guard canAdminister,
              !reconfigureURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            do {
                try await manager.reconfigureAddon(addon, newURL: reconfigureURL)
                await MainActor.run {
                    reconfigureURL = ""
                }
            } catch {
                await MainActor.run {
                    reconfigureError = error.localizedDescription
                    showReconfigureError = true
                }
            }
        }
    }
}

private struct AddStremioAddonInputModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var addonURL: String
    var onAdd: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 16, tvOS 16, *) {
            content
                .alert("Add Stremio Addon", isPresented: $isPresented) {
                    TextField("Addon URL", text: $addonURL)
                    Button("Cancel", role: .cancel) {
#if !os(tvOS)
                        addonURL = ""
#endif
                    }
                    Button("Add") {
                        onAdd()
                    }
                } message: {
                    Text("Enter the Stremio addon manifest URL")
                }
        } else {
            content
                .sheet(isPresented: $isPresented) {
                    NavigationView {
                        Form {
                            Section {
                                TextField("Addon URL", text: $addonURL)
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                            } header: {
                                Text("Enter the Stremio addon manifest URL")
                            }
                        }
                        .navigationTitle("Add Stremio Addon")
                        #if !os(tvOS)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") {
                                    addonURL = ""
                                    isPresented = false
                                }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Add") {
                                    isPresented = false
                                    onAdd()
                                }
                            }
                        }
                        #endif
                    }
                    .navigationViewStyle(StackNavigationViewStyle())
                }
        }
    }
}

private struct ReconfigureStremioAddonModifier: ViewModifier {
    @Binding var isPresented: Bool
    @Binding var addonURL: String
    var onReconfigure: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 16, tvOS 16, *) {
            content
                .alert("Reconfigure Addon", isPresented: $isPresented) {
                    TextField("New Addon URL", text: $addonURL)
                    Button("Cancel", role: .cancel) {
#if !os(tvOS)
                        addonURL = ""
#endif
                    }
                    Button("Save") {
                        onReconfigure()
                    }
                } message: {
                    Text("Paste the new configured addon URL")
                }
        } else {
            content
                .sheet(isPresented: $isPresented) {
                    NavigationView {
                        Form {
                            Section {
                                TextField("New Addon URL", text: $addonURL)
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                            } header: {
                                Text("Paste the new configured addon URL")
                            }
                        }
                        .navigationTitle("Reconfigure Addon")
                        #if !os(tvOS)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") {
                                    addonURL = ""
                                    isPresented = false
                                }
                            }
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Save") {
                                    isPresented = false
                                    onReconfigure()
                                }
                            }
                        }
                        #endif
                    }
                    .navigationViewStyle(StackNavigationViewStyle())
                }
        }
    }
}


private struct ExtraServiceSettingsView: View {
    let initialSearchTarget: ServicesSettingsSearchTarget?
    let isAdministrable: Bool

    @StateObject private var serviceManager = ServiceManager.shared
    @StateObject private var stremioManager = StremioAddonManager.shared
    @StateObject private var skyStreamManager = SkyStreamPluginManager.shared
#if os(iOS) && !targetEnvironment(macCatalyst)
    @StateObject private var nuvioManager = NuvioPluginManager.shared
#endif
    @AppStorage(ServicesSheetPresentationSettings.stremioStyleEnabledKey, store: ProfileSettingsStore.services) private var stremioStyleSheetEnabled = ServicesSheetPresentationSettings.defaultStremioStyleEnabled
    @AppStorage(ServicesResultRankingSettings.minimumSimilarityKey, store: ProfileSettingsStore.services) private var serviceResultMinimumSimilarity = ServicesResultRankingSettings.defaultMinimumSimilarity
    @AppStorage(ServicesResultRankingSettings.dropMismatchedResultsKey, store: ProfileSettingsStore.services) private var dropMismatchedServiceResults = ServicesResultRankingSettings.defaultDropMismatchedResults
    @AppStorage(StreamLanguageFilter.assumeOriginalAudioKey, store: ProfileSettingsStore.services) private var assumeOriginalAudio = false
    @AppStorage(StreamLanguageFilter.treatDubbedAnimeAsEnglishKey, store: ProfileSettingsStore.services) private var treatDubbedAnimeAsEnglish = false
    @AppStorage(StreamLanguageFilter.hideUnknownLanguageStreamsKey, store: ProfileSettingsStore.services) private var hideStreamsWithoutLanguageData = false
    @AppStorage(StreamLanguageFilter.hideUnknownQualityStreamsKey, store: ProfileSettingsStore.services) private var hideStreamsWithoutDetectedQuality = false
    @AppStorage(ContentBlockingSettings.blockAddonSubtitlesKey, store: ProfileSettingsStore.services) private var blockAddonSubtitles = ContentBlockingSettings.defaultBlockAddonSubtitles
    @AppStorage(ContentBlockingSettings.blockAddonCatalogsKey, store: ProfileSettingsStore.services) private var blockAddonCatalogs = ContentBlockingSettings.defaultBlockAddonCatalogs
    @State private var includedStreamLanguages: [String] = StreamLanguageFilter.includedLanguages()
    @State private var includedStreamLanguageText = StreamLanguageFilter.editorText(from: StreamLanguageFilter.includedLanguages())
    @State private var hiddenStreamLanguages: [String] = StreamLanguageFilter.hiddenLanguages()
    @State private var hiddenStreamLanguageText = StreamLanguageFilter.editorText(from: StreamLanguageFilter.hiddenLanguages())
    @State private var hiddenStreamQualities = Set(StreamLanguageFilter.hiddenQualityHeights())
    @State private var extraRulesSourceIds: Set<String>? = StreamLanguageFilter.extraRulesSourceIds().map { Set($0) }
    @State private var didFocusInitialSearchTarget = false

    private var sanitizedServiceResultMinimumSimilarity: Double {
        ServicesResultRankingSettings.clampedMinimumSimilarity(serviceResultMinimumSimilarity)
    }

    private var serviceResultMinimumSimilarityBinding: Binding<Double> {
        Binding(
            get: { sanitizedServiceResultMinimumSimilarity },
            set: { serviceResultMinimumSimilarity = ServicesResultRankingSettings.clampedMinimumSimilarity($0) }
        )
    }

    var body: some View {
        extraServiceSettingsView
    }

    private struct ExtraRulesSourceItem: Identifiable {
        let id: String
        let displayName: String
        let kind: String
        let isActive: Bool
    }

    private var connectedServiceRuleSources: [ExtraRulesSourceItem] {
        serviceManager.services.map { service in
            ExtraRulesSourceItem(
                id: SourceHealth.serviceId(service),
                displayName: service.metadata.sourceName,
                kind: "Service",
                isActive: serviceManager.isServiceEnabled(service)
            )
        }
    }

    private var connectedStremioRuleSources: [ExtraRulesSourceItem] {
        stremioManager.addons
            .filter { $0.manifest.supportsStreams }
            .map { addon in
                ExtraRulesSourceItem(
                    id: SourceHealth.stremioId(addon),
                    displayName: addon.manifest.name,
                    kind: "Stremio Addon",
                    isActive: stremioManager.isAddonEnabled(addon)
                )
            }
    }

    private var connectedSkyStreamRuleSources: [ExtraRulesSourceItem] {
        guard PlatformCapabilities.current.supportsSkyStreamPlugins else { return [] }
        return skyStreamManager.providers.map { provider in
            ExtraRulesSourceItem(
                id: provider.id,
                displayName: provider.displayName,
                kind: "SkyStream Plugin",
                isActive: provider.isEnabled
            )
        }
    }

    private var connectedNuvioRuleSources: [ExtraRulesSourceItem] {
#if os(iOS) && !targetEnvironment(macCatalyst)
        guard PlatformCapabilities.current.supportsNuvioPlugins else { return [] }
        return nuvioManager.activeScrapers.map { scraper in
            ExtraRulesSourceItem(
                id: scraper.id,
                displayName: scraper.displayName,
                kind: "Nuvio Provider",
                isActive: scraper.isRunnable
            )
        }
#else
        []
#endif
    }

    private var connectedExtraRulesSources: [ExtraRulesSourceItem] {
        connectedServiceRuleSources + connectedStremioRuleSources + connectedSkyStreamRuleSources
            + connectedNuvioRuleSources
    }

    @ViewBuilder
    private var extraServiceSettingsView: some View {
        ScrollViewReader { scrollProxy in
            List {
                Section {
                    Toggle("Stremio-Style Stream List", isOn: $stremioStyleSheetEnabled)
                        .id(ServicesSettingsSearchTarget.stremioStyleSheet.anchorID)
                } footer: {
                    Text("Shows one compact, filterable list of results and streams instead of grouping them into separate source sections.")
                }
                .eclipseExperimentalSettingsRows()
                .disabled(!isAdministrable)

                Section {
                    Toggle(isOn: $blockAddonSubtitles) {
                        Label("Block Add-on Subtitles", systemImage: "captions.bubble.fill")
                    }
                    .id(ServicesSettingsSearchTarget.blockAddonSubtitles.anchorID)

                    Toggle(isOn: $blockAddonCatalogs) {
                        Label("Block Add-on Catalogs", systemImage: "square.grid.2x2.fill")
                    }
                    .id(ServicesSettingsSearchTarget.blockAddonCatalogs.anchorID)
                    .onChangeComp(of: blockAddonCatalogs) { _, _ in
                        NotificationCenter.default.post(name: .catalogDataDidChange, object: nil)
                    }
                } header: {
                    Text("Content Blocking")
                } footer: {
                    Text(isAdministrable
                         ? "Master switches that block all add-on subtitles or catalogs, no matter how individual sources are configured. The built-in OpenSubtitles v3 provider and the app's default catalogs are never affected."
                         : "Master switches that block all add-on subtitles or catalogs. This is a kids profile, so it can see them but not change them. Switch to a grown-up profile to make those changes.")
                }
                .eclipseExperimentalSettingsRows()
                .disabled(!isAdministrable)

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Ranking Similarity")
                            Spacer()
                            Text("\(Int(sanitizedServiceResultMinimumSimilarity * 100))%")
                                .foregroundColor(.secondary)
                        }
                        .id(ServicesSettingsSearchTarget.rankingSimilarity.anchorID)

#if os(tvOS)

                        HStack(spacing: 18) {
                            Button {
                                serviceResultMinimumSimilarity = max(
                                    ServicesResultRankingSettings.minimumSimilarityRange.lowerBound,
                                    sanitizedServiceResultMinimumSimilarity - 0.01
                                )
                            } label: {
                                Label("Decrease", systemImage: "minus")
                            }
                            .disabled(sanitizedServiceResultMinimumSimilarity <= ServicesResultRankingSettings.minimumSimilarityRange.lowerBound)

                            Button {
                                serviceResultMinimumSimilarity = min(
                                    ServicesResultRankingSettings.minimumSimilarityRange.upperBound,
                                    sanitizedServiceResultMinimumSimilarity + 0.01
                                )
                            } label: {
                                Label("Increase", systemImage: "plus")
                            }
                            .disabled(sanitizedServiceResultMinimumSimilarity >= ServicesResultRankingSettings.minimumSimilarityRange.upperBound)
                        }
                        .accessibilityValue("\(Int(sanitizedServiceResultMinimumSimilarity * 100)) percent")
#else
                        Slider(
                            value: serviceResultMinimumSimilarityBinding,
                            in: ServicesResultRankingSettings.minimumSimilarityRange,
                            step: 0.01
                        )
                        .accessibilityValue("\(Int(sanitizedServiceResultMinimumSimilarity * 100)) percent")
#endif
                    }

                    Toggle("Drop Unmatched Search Results", isOn: $dropMismatchedServiceResults)
                        .id(ServicesSettingsSearchTarget.dropMismatchedResults.anchorID)
                } footer: {
                    Text("Results at or above this percentage are prioritized by similarity. When dropping is enabled, search results below this percentage are hidden, Auto Mode skips them instead of using a weaker match, and plugin sources tighten to the same percentage. Percentages under 85% apply to Service sources only, because plugin sources never accept a match below 85%.")
                }
                .eclipseExperimentalSettingsRows()
                .disabled(!isAdministrable)

                Section {
                    Text("Languages to Include")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .id(ServicesSettingsSearchTarget.languagesToInclude.anchorID)

                    TextField("English, Hindi, Japanese", text: $includedStreamLanguageText)
#if os(iOS)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
#endif
                        .onSubmit {
                            saveIncludedStreamLanguages()
                        }

                    Button {
                        saveIncludedStreamLanguages()
                    } label: {
                        Label("Save Included Languages", systemImage: "checkmark.circle")
                    }
                    .disabled(StreamLanguageFilter.editorText(from: includedStreamLanguages) == StreamLanguageFilter.editorText(from: StreamLanguageFilter.languages(from: includedStreamLanguageText)))

                    ForEach(includedStreamLanguages, id: \.self) { language in
                        HStack {
                            Text(language)
                            Spacer()
                            Button(role: .destructive) {
                                removeIncludedStreamLanguage(language)
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    if !includedStreamLanguages.isEmpty {
                        Button(role: .destructive) {
                            clearIncludedStreamLanguages()
                        } label: {
                            Label("Clear Included Languages", systemImage: "trash")
                        }
                    }

                    Text("Languages to Exclude")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .id(ServicesSettingsSearchTarget.languagesToExclude.anchorID)

                    TextField("English, Hindi, Japanese", text: $hiddenStreamLanguageText)
#if os(iOS)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
#endif
                        .onSubmit {
                            saveHiddenStreamLanguages()
                        }

                    Button {
                        saveHiddenStreamLanguages()
                    } label: {
                        Label("Save Excluded Languages", systemImage: "checkmark.circle")
                    }
                    .disabled(StreamLanguageFilter.editorText(from: hiddenStreamLanguages) == StreamLanguageFilter.editorText(from: StreamLanguageFilter.languages(from: hiddenStreamLanguageText)))

                    ForEach(hiddenStreamLanguages, id: \.self) { language in
                        HStack {
                            Text(language)
                            Spacer()
                            Button(role: .destructive) {
                                removeHiddenStreamLanguage(language)
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    Toggle("Hide Streams Without Language Data", isOn: $hideStreamsWithoutLanguageData)
                        .id(ServicesSettingsSearchTarget.missingLanguageData.anchorID)

                    Toggle("Assume Original Language for Untagged Streams", isOn: $assumeOriginalAudio)
                        .id(ServicesSettingsSearchTarget.assumeOriginalAudio.anchorID)

                    Toggle("Treat Dubbed Anime Streams as English", isOn: $treatDubbedAnimeAsEnglish)
                        .id(ServicesSettingsSearchTarget.treatDubbedAnimeAsEnglish.anchorID)

                    if !hiddenStreamLanguages.isEmpty {
                        Button(role: .destructive) {
                            clearHiddenStreamLanguages()
                        } label: {
                            Label("Clear Excluded Languages", systemImage: "trash")
                        }
                    }

#if os(tvOS)
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Qualities to Hide")
                            Spacer()
                            if !hiddenStreamQualities.isEmpty {
                                Text("\(hiddenStreamQualities.count)")
                                    .foregroundColor(.secondary)
                            }
                        }
                        ForEach(StreamLanguageFilter.supportedQualityHeights, id: \.self) { height in
                            Toggle(
                                StreamLanguageFilter.qualityLabel(for: height),
                                isOn: hiddenQualityBinding(for: height)
                            )
                        }
                    }
#else
                    DisclosureGroup {
                        ForEach(StreamLanguageFilter.supportedQualityHeights, id: \.self) { height in
                            Toggle(
                                StreamLanguageFilter.qualityLabel(for: height),
                                isOn: hiddenQualityBinding(for: height)
                            )
                        }
                    } label: {
                        HStack {
                            Text("Qualities to Hide")
                            Spacer()
                            if !hiddenStreamQualities.isEmpty {
                                Text("\(hiddenStreamQualities.count)")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .id(ServicesSettingsSearchTarget.qualitiesToHide.anchorID)
#endif

                    Toggle("Hide Streams Without Detected Quality", isOn: $hideStreamsWithoutDetectedQuality)
                        .id(ServicesSettingsSearchTarget.hideStreamsWithoutDetectedQuality.anchorID)

#if os(tvOS)
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Apply Extra Rules To")
                            Spacer()
                            Text(extraRulesSourceSummary)
                                .foregroundColor(.secondary)
                        }
                        extraRulesSourceControls
                    }
#else
                    DisclosureGroup {
                        extraRulesSourceControls
                    } label: {
                        HStack {
                            Text("Apply Extra Rules To")
                            Spacer()
                            Text(extraRulesSourceSummary)
                                .foregroundColor(.secondary)
                        }
                    }
                    .id(ServicesSettingsSearchTarget.applyExtraRulesTo.anchorID)
#endif
                } footer: {
                    Text("Best-effort stream rules for the selected sources. An Include list only keeps streams with a matching detected language; Exclude takes priority when the same language appears in both lists. When Assume Original Language for Untagged Streams is enabled, a stream with no language data is evaluated using the media's TMDB original language before Include and Exclude rules run. When Treat Dubbed Anime Streams as English is enabled, anime streams labeled dubbed or dub match English filters and count as having language data. Quality and language detection use stream tags, filenames, and labels; a stream URL contributes only its path, and two-letter codes count only when a source reports them as language data.")
                }
                .eclipseExperimentalSettingsRows()
                .disabled(!isAdministrable)
            }
            .navigationTitle("Extra Source Settings")
            .eclipseSettingsStyle()
            .onAppear {
                let storedSimilarity = ServicesResultRankingSettings.minimumSimilarity()
                if serviceResultMinimumSimilarity != storedSimilarity {
                    serviceResultMinimumSimilarity = storedSimilarity
                }
                let storedDropMismatched = ServicesResultRankingSettings.dropsMismatchedResults()
                if dropMismatchedServiceResults != storedDropMismatched {
                    dropMismatchedServiceResults = storedDropMismatched
                }
                reloadHiddenStreamLanguagesFromDefaults()
                reloadExtraRulesSettingsFromDefaults()
                focusExtraServiceSettingsTarget(using: scrollProxy)
            }
            .onDisappear {
                guard isAdministrable else { return }
                saveIncludedStreamLanguages()
                saveHiddenStreamLanguages()
            }
        }
    }

    private func focusExtraServiceSettingsTarget(using scrollProxy: ScrollViewProxy) {
        guard !didFocusInitialSearchTarget,
              let initialSearchTarget,
              initialSearchTarget.opensExtraServiceSettings else { return }
        didFocusInitialSearchTarget = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeInOut(duration: 0.28)) {
                scrollProxy.scrollTo(initialSearchTarget.anchorID, anchor: .center)
            }
        }
    }

    private func captureSkyStreamSourceDefaults() {
        Task {
            await skyStreamManager.captureSourceDefaultsState()
        }
    }

    private func reloadHiddenStreamLanguagesFromDefaults() {
        let included = StreamLanguageFilter.includedLanguages()
        if includedStreamLanguages != included {
            includedStreamLanguages = included
        }
        let includedText = StreamLanguageFilter.editorText(from: included)
        if includedStreamLanguageText != includedText {
            includedStreamLanguageText = includedText
        }
        let hidden = StreamLanguageFilter.hiddenLanguages()
        if hiddenStreamLanguages != hidden {
            hiddenStreamLanguages = hidden
        }
        let hiddenText = StreamLanguageFilter.editorText(from: hidden)
        if hiddenStreamLanguageText != hiddenText {
            hiddenStreamLanguageText = hiddenText
        }
    }

    private func saveIncludedStreamLanguages() {
        let languages = StreamLanguageFilter.languages(from: includedStreamLanguageText)
        StreamLanguageFilter.setIncludedLanguages(languages)
        reloadHiddenStreamLanguagesFromDefaults()
    }

    private func removeIncludedStreamLanguage(_ language: String) {
        let languages = includedStreamLanguages.filter { $0 != language }
        StreamLanguageFilter.setIncludedLanguages(languages)
        reloadHiddenStreamLanguagesFromDefaults()
    }

    private func clearIncludedStreamLanguages() {
        StreamLanguageFilter.setIncludedLanguages([])
        reloadHiddenStreamLanguagesFromDefaults()
    }

    private func reloadExtraRulesSettingsFromDefaults() {
        let storedQualities = Set(StreamLanguageFilter.hiddenQualityHeights())
        if hiddenStreamQualities != storedQualities {
            hiddenStreamQualities = storedQualities
        }
        let storedSourceIds = StreamLanguageFilter.extraRulesSourceIds().map { Set($0) }
        if extraRulesSourceIds != storedSourceIds {
            extraRulesSourceIds = storedSourceIds
        }
    }

    private func hiddenQualityBinding(for height: Int) -> Binding<Bool> {
        Binding(
            get: { hiddenStreamQualities.contains(height) },
            set: { shouldHide in
                if shouldHide {
                    hiddenStreamQualities.insert(height)
                } else {
                    hiddenStreamQualities.remove(height)
                }
                StreamLanguageFilter.setHiddenQualityHeights(Array(hiddenStreamQualities))
                hiddenStreamQualities = Set(StreamLanguageFilter.hiddenQualityHeights())
            }
        )
    }

    @ViewBuilder
    private var extraRulesSourceControls: some View {
        if connectedExtraRulesSources.isEmpty {
            Text("No connected stream sources.")
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            if !connectedServiceRuleSources.isEmpty {
                Text("Services")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                ForEach(connectedServiceRuleSources) { source in
                    extraRulesSourceToggle(source)
                }
            }

            if !connectedStremioRuleSources.isEmpty {
                Text("Stremio Addons")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                ForEach(connectedStremioRuleSources) { source in
                    extraRulesSourceToggle(source)
                }
            }

#if os(iOS) && !targetEnvironment(macCatalyst)
            if !connectedNuvioRuleSources.isEmpty {
                Text("Nuvio Plugins")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                ForEach(connectedNuvioRuleSources) { source in
                    extraRulesSourceToggle(source)
                }
            }
#endif
            if !connectedSkyStreamRuleSources.isEmpty {
                Text("SkyStream Plugins")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                ForEach(connectedSkyStreamRuleSources) { source in
                    extraRulesSourceToggle(source)
                }
            }

        }

        if extraRulesSourceIds != nil {
            Button {
                StreamLanguageFilter.setExtraRulesSourceIds(nil)
                reloadExtraRulesSettingsFromDefaults()
                captureSkyStreamSourceDefaults()
            } label: {
                Label("Apply to All Connected Sources", systemImage: "checkmark.circle")
            }
        }
    }

    @ViewBuilder
    private func extraRulesSourceToggle(_ source: ExtraRulesSourceItem) -> some View {
        Toggle(isOn: extraRulesSourceBinding(for: source.id)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName)
                Text(source.isActive ? source.kind : "\(source.kind) · Disabled")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func extraRulesSourceBinding(for sourceId: String) -> Binding<Bool> {
        Binding(
            get: { extraRulesSourceIds?.contains(sourceId) ?? true },
            set: { isSelected in
                let visibleConnectedIDs = Set(connectedExtraRulesSources.map(\.id))

                let preservedHiddenProviderIDs = Set(
                    (ProfileSettingsStore.services.stringArray(forKey: "servicesAutoModeSourceOrderIds") ?? [])
                        .filter {
                            StreamLanguageFilter.isPlatformScopedProviderSourceID($0)
                        }
                ).subtracting(visibleConnectedIDs)
                var selected = extraRulesSourceIds
                    ?? visibleConnectedIDs.union(preservedHiddenProviderIDs)
                if isSelected {
                    selected.insert(sourceId)
                } else {
                    selected.remove(sourceId)
                }

                let allConnectedIds = visibleConnectedIDs
                let storedSelection: [String]? = selected.isSuperset(of: allConnectedIds) ? nil : Array(selected)
                StreamLanguageFilter.setExtraRulesSourceIds(storedSelection)
                reloadExtraRulesSettingsFromDefaults()
                captureSkyStreamSourceDefaults()
            }
        )
    }

    private var extraRulesSourceSummary: String {
        guard let selected = extraRulesSourceIds else { return "All" }
        return "\(selected.intersection(Set(connectedExtraRulesSources.map(\.id))).count) of \(connectedExtraRulesSources.count)"
    }

    private func saveHiddenStreamLanguages() {
        let languages = StreamLanguageFilter.languages(from: hiddenStreamLanguageText)
        StreamLanguageFilter.setHiddenLanguages(languages)
        reloadHiddenStreamLanguagesFromDefaults()
    }

    private func removeHiddenStreamLanguage(_ language: String) {
        let languages = hiddenStreamLanguages.filter { $0 != language }
        StreamLanguageFilter.setHiddenLanguages(languages)
        reloadHiddenStreamLanguagesFromDefaults()
    }

    private func clearHiddenStreamLanguages() {
        StreamLanguageFilter.setHiddenLanguages([])
        reloadHiddenStreamLanguagesFromDefaults()
    }
}
