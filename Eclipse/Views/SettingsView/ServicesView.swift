import SwiftUI
import Kingfisher

enum ServicesSettingsSearchTarget: Hashable {
    case autoUpdateServices
    case autoMode
    case autoSelectEpisodes
    case autoQuality
    case autoQualityPreference
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
             .applyExtraRulesTo:
            true
        case .autoUpdateServices, .autoMode, .autoSelectEpisodes, .autoQuality, .autoQualityPreference, .installedSource:
            false
        }
    }
}

struct ServicesView: View {
    let initialSearchTarget: ServicesSettingsSearchTarget?
    @StateObject private var serviceManager = ServiceManager.shared
    @StateObject private var stremioManager = StremioAddonManager.shared
    @StateObject private var skyStreamManager = SkyStreamPluginManager.shared
    @StateObject private var healthStore = SourceHealthStore.shared
#if !os(tvOS)
    @Environment(\.editMode) private var editMode
#endif
    @State private var showDownloadAlert = false
    @State private var downloadURL = ""
    @State private var serviceDownloadAlert: ServiceDownloadAlert?
    @AppStorage("autoUpdateServicesEnabled") private var autoUpdateEnabled = true
    @State private var showStremioAddAlert = false
    @State private var stremioURL = ""
    @State private var stremioError: String?
    @State private var showStremioError = false
    @State private var pendingConfigureAddon: StremioAddon?
    @AppStorage("servicesAutoModeEnabled") private var servicesAutoModeEnabled = false
    @AppStorage("servicesAutoSelectEpisodesEnabled") private var servicesAutoSelectEpisodesEnabled = false
    @AppStorage("servicesAutoModeQualityPreference") private var autoModeQualityPreferenceRaw = AutoModeQualityPreference.defaultPreference.rawValue
    @AppStorage(ServicesSheetPresentationSettings.stremioStyleEnabledKey) private var stremioStyleSheetEnabled = ServicesSheetPresentationSettings.defaultStremioStyleEnabled
    @AppStorage(ServicesResultRankingSettings.minimumSimilarityKey) private var serviceResultMinimumSimilarity = ServicesResultRankingSettings.defaultMinimumSimilarity
    @AppStorage(ServicesResultRankingSettings.dropMismatchedResultsKey) private var dropMismatchedServiceResults = ServicesResultRankingSettings.defaultDropMismatchedResults
    @AppStorage(StreamLanguageFilter.assumeOriginalAudioKey) private var assumeOriginalAudio = false
    @AppStorage(StreamLanguageFilter.treatDubbedAnimeAsEnglishKey) private var treatDubbedAnimeAsEnglish = false
    @AppStorage(StreamLanguageFilter.hideUnknownLanguageStreamsKey) private var hideStreamsWithoutLanguageData = false
    @AppStorage(StreamLanguageFilter.hideUnknownQualityStreamsKey) private var hideStreamsWithoutDetectedQuality = false
    @State private var selectedAutoModeSourceIds: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "servicesAutoModeSourceIds") ?? [])
    @State private var autoModeSourceOrderIds: [String] = UserDefaults.standard.stringArray(forKey: "servicesAutoModeSourceOrderIds") ?? []
    @State private var includedStreamLanguages: [String] = StreamLanguageFilter.includedLanguages()
    @State private var includedStreamLanguageText = StreamLanguageFilter.editorText(from: StreamLanguageFilter.includedLanguages())
    @State private var hiddenStreamLanguages: [String] = StreamLanguageFilter.hiddenLanguages()
    @State private var hiddenStreamLanguageText = StreamLanguageFilter.editorText(from: StreamLanguageFilter.hiddenLanguages())
    @State private var hiddenStreamQualities = Set(StreamLanguageFilter.hiddenQualityHeights())
    @State private var extraRulesSourceIds: Set<String>? = StreamLanguageFilter.extraRulesSourceIds().map { Set($0) }
    @State private var didFocusInitialSearchTarget = false
    @State private var didScheduleInitialExtraSettingsNavigation = false
    @State private var showExtraServiceSettings = false
    @State private var showSkyStreamManager = false
    @State private var pendingSkyStreamUninstallPackageName: String?

    init(initialSearchTarget: ServicesSettingsSearchTarget? = nil) {
        self.initialSearchTarget = initialSearchTarget
    }

    private var hasAnyInstalledSources: Bool {
        !serviceManager.services.isEmpty ||
        !stremioManager.addons.isEmpty ||
        !skyStreamManager.providers.isEmpty
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
                    Button {
                        withAnimation {
                            editMode?.wrappedValue =
                            (editMode?.wrappedValue == .active) ? .inactive : .active
                        }
                    } label: {
                        Image(systemName:
                                editMode?.wrappedValue == .active ? "checkmark" : "pencil")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
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
#endif
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
#endif
            .refreshable {
                await serviceManager.updateServices()
                await stremioManager.refreshAddons()
#if os(iOS) && !targetEnvironment(macCatalyst)
                if PlatformCapabilities.current.supportsSkyStreamPlugins {
                    await skyStreamManager.refreshRepositoriesAndInstalledPlugins(autoUpdate: autoUpdateEnabled)
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
            .sheet(item: $pendingConfigureAddon) { addon in
                StremioConfigureView(addon: addon, manager: stremioManager)
            }
#if os(iOS) && !targetEnvironment(macCatalyst)
            .sheet(isPresented: $showSkyStreamManager) {
                SkyStreamManagerView()
            }
            .confirmationDialog(
                "Uninstall SkyStream Plugin?",
                isPresented: Binding(
                    get: { pendingSkyStreamUninstallPackageName != nil },
                    set: { if !$0 { pendingSkyStreamUninstallPackageName = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Uninstall Plugin", role: .destructive) {
                    guard let packageName = pendingSkyStreamUninstallPackageName else { return }
                    pendingSkyStreamUninstallPackageName = nil
                    Task {
                        try? await skyStreamManager.uninstall(packageName: packageName)
                        reloadAutoModeSelectionFromDefaults()
                        reloadExtraRulesSettingsFromDefaults()
                    }
                }
                Button("Cancel", role: .cancel) { pendingSkyStreamUninstallPackageName = nil }
            } message: {
                Text("This removes the whole package and every provider row. Installed repositories are unchanged.")
            }
#endif
            .onAppear {
                _ = healthStore.version
                reloadAutoModeSelectionFromDefaults()
                reloadHiddenStreamLanguagesFromDefaults()
                reloadExtraRulesSettingsFromDefaults()
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
#if os(tvOS)
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
#endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    /// A tagged union so every stream source family can share one reorderable list.
    private enum UnifiedItem: Identifiable {
        case service(Service)
        case stremio(StremioAddon)
        case skyStream(SkyStreamProviderDescriptor)

        var id: String {
            switch self {
            case .service(let s): return "service:\(s.id.uuidString)"
            case .stremio(let a): return "stremio:\(a.id.uuidString)"
            case .skyStream(let provider): return provider.id
            }
        }

        var sortIndex: Int64 {
            switch self {
            case .service(let s): return s.sortIndex
            case .stremio(let a): return a.sortIndex
            case .skyStream(let provider): return Int64(provider.sortIndex)
            }
        }

        var isActive: Bool {
            switch self {
            case .service(let s):
                return PlatformSourceActivation.isEnabled(sourceID: SourceHealth.serviceId(s), sharedValue: s.isActive)
                    && s.providerCapabilities.isSupportedOnCurrentPlatform
            case .stremio(let a):
                return PlatformSourceActivation.isEnabled(sourceID: SourceHealth.stremioId(a), sharedValue: a.isActive)
            case .skyStream(let provider):
                return provider.isEnabled
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
            }
        }

        var displayName: String {
            switch self {
            case .service(let s): return s.metadata.sourceName
            case .stremio(let a): return a.manifest.name
            case .skyStream(let provider): return provider.displayName
            }
        }

        var autoModeSourceId: String {
            switch self {
            case .service(let s): return "service:\(s.id.uuidString)"
            case .stremio(let a): return "stremio:\(a.id.uuidString)"
            case .skyStream(let provider): return provider.id
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
        var orderRank: [String: Int] = [:]
        for (index, sourceId) in autoModeSourceOrderIds.enumerated() where orderRank[sourceId] == nil {
            orderRank[sourceId] = index
        }
        return (services + addons + skyStreamProviders).sorted {
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

    private enum AutoModeSourceItem: Identifiable {
        case service(Service)
        case stremio(StremioAddon)
        case skyStream(SkyStreamProviderDescriptor)

        var id: String { autoModeSourceId }

        var isActive: Bool {
            switch self {
            case .service(let service):
                return PlatformSourceActivation.isEnabled(sourceID: SourceHealth.serviceId(service), sharedValue: service.isActive)
                    && service.providerCapabilities.isSupportedOnCurrentPlatform
            case .stremio(let addon):
                return PlatformSourceActivation.isEnabled(sourceID: SourceHealth.stremioId(addon), sharedValue: addon.isActive)
            case .skyStream(let provider):
                return provider.isEnabled
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
            }
        }

        var displayName: String {
            switch self {
            case .service(let service): return service.metadata.sourceName
            case .stremio(let addon): return addon.manifest.name
            case .skyStream(let provider): return provider.displayName
            }
        }

        var autoModeSourceId: String {
            switch self {
            case .service(let service): return "service:\(service.id.uuidString)"
            case .stremio(let addon): return "stremio:\(addon.id.uuidString)"
            case .skyStream(let provider): return provider.id
            }
        }
    }

    private var orderedAutoModeListItems: [AutoModeSourceItem] {
        let activeItems: [AutoModeSourceItem] = unifiedItems.compactMap { item in
            switch item {
            case .service(let service): return .service(service)
            case .stremio(let addon): return .stremio(addon)
            case .skyStream(let provider): return .skyStream(provider)
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
        orderedAutoModeListItems.filter { selectedAutoModeSourceIds.contains($0.autoModeSourceId) }
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

    private var connectedExtraRulesSources: [ExtraRulesSourceItem] {
        connectedServiceRuleSources + connectedStremioRuleSources + connectedSkyStreamRuleSources
    }

    private var autoModeQualityPreference: AutoModeQualityPreference {
        AutoModeQualityPreference(rawValue: autoModeQualityPreferenceRaw) ?? AutoModeQualityPreference.defaultPreference
    }

    private var autoModeQualityEnabledBinding: Binding<Bool> {
        Binding(
            get: { autoModeQualityPreference.usesAutomaticSelection },
            set: { enabled in
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
                let resolved = preference.usesAutomaticSelection ? preference : AutoModeQualityPreference.defaultPreference
                autoModeQualityPreferenceRaw = resolved.rawValue
            }
        )
    }

    @ViewBuilder
    private var servicesList: some View {
        ScrollViewReader { scrollProxy in
            let unifiedItemsSnapshot = unifiedItems
            List {
#if os(tvOS)
            Section("Manage Sources") {
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
                Toggle("Auto Mode", isOn: $servicesAutoModeEnabled)
                    .id(ServicesSettingsSearchTarget.autoMode.anchorID)

                Toggle("Auto-Select Episodes", isOn: $servicesAutoSelectEpisodesEnabled)
                    .id(ServicesSettingsSearchTarget.autoSelectEpisodes.anchorID)

                if servicesAutoModeEnabled {
                    let autoModeItems = orderedAutoModeListItems
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

                    if autoModeItems.isEmpty {
                        Text("Activate at least one stream-capable source to use Auto Mode.")
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
#if os(tvOS)
                                Button {
                                    moveAutoModeSource(from: index, direction: -1)
                                } label: {
                                    Image(systemName: "chevron.up")
                                }
                                .disabled(index == 0)

                                Button {
                                    moveAutoModeSource(from: index, direction: 1)
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .disabled(index >= autoModeItems.count - 1)
#endif
                            }
                        }
#if !os(tvOS)
                        .onMove(perform: moveAutoModeSources)
#endif
                    }
                }
            } footer: {
#if os(tvOS)
                Text("Auto-Select Episodes also applies when choosing a source manually. Auto Mode checks enabled sources from top to bottom. Use the arrow buttons to set priority, and turn Auto Quality off when you want to choose stream quality yourself.")
#else
                Text("Auto-Select Episodes also applies when choosing a source manually. Auto Mode checks enabled sources from top to bottom. Drag to set priority, and turn Auto Quality off when you want to choose stream quality yourself.")
#endif
            }
            .eclipseExperimentalSettingsRows()

            Section {
                NavigationLink(isActive: $showExtraServiceSettings) {
                    extraServiceSettingsView
                } label: {
                    Label("Extra Source Settings", systemImage: "slider.horizontal.3")
                }
            } footer: {
                Text("Configure the stream list layout, language, quality, and source rules.")
            }
            .eclipseExperimentalSettingsRows()

            Section(header: unifiedSectionHeader) {
                if !hasAnyInstalledSources {
                    Text("No stream sources installed")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                } else {
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
                                    onRemove: { removeUnifiedItem(item) }
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
                                    canMoveUp: index > 0,
                                    canMoveDown: index < unifiedItemsSnapshot.count - 1,
                                    onMoveUp: { moveUnifiedItem(withID: item.id, direction: -1) },
                                    onMoveDown: { moveUnifiedItem(withID: item.id, direction: 1) },
                                    onRemove: { removeUnifiedItem(item) }
                                )
                                .padding(60)
                                .navigationTitle(addon.manifest.name)
                            } label: {
                                tvUnifiedSourceLabel(item)
                            }
#else
                            StremioAddonRow(addon: addon, manager: stremioManager, healthStore: healthStore)
                                .id(item.settingsSearchAnchorID)
#endif
                        case .skyStream(let provider):
#if os(iOS) && !targetEnvironment(macCatalyst)
                            SkyStreamProviderRow(
                                provider: provider,
                                manager: skyStreamManager,
                                healthStore: healthStore
                            )
                            .id(item.settingsSearchAnchorID)
#else
                            EmptyView()
#endif
                        }
                    }
#if !os(tvOS)
                    .onDelete(perform: deleteUnifiedItems)
                    .onMove(perform: moveUnifiedItems)
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

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Ranking Similarity")
                            Spacer()
                            Text("\(Int(serviceResultMinimumSimilarity * 100))%")
                                .foregroundColor(.secondary)
                        }
                        .id(ServicesSettingsSearchTarget.rankingSimilarity.anchorID)

                        Slider(
                            value: $serviceResultMinimumSimilarity,
                            in: ServicesResultRankingSettings.minimumSimilarityRange,
                            step: 0.01
                        )
                        .accessibilityValue("\(Int(serviceResultMinimumSimilarity * 100)) percent")
                    }

                    Toggle("Drop Unmatched Search Results", isOn: $dropMismatchedServiceResults)
                        .id(ServicesSettingsSearchTarget.dropMismatchedResults.anchorID)
                } footer: {
                    Text("Results at or above this percentage are prioritized by similarity. When dropping is enabled, search results below this percentage are hidden and Auto Mode skips them instead of using a weaker match.")
                }
                .eclipseExperimentalSettingsRows()

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
                    Text("Best-effort stream rules for the selected sources. An Include list only keeps streams with a matching detected language; Exclude takes priority when the same language appears in both lists. When Assume Original Language for Untagged Streams is enabled, a stream with no language data is evaluated using the media's TMDB original language before Include and Exclude rules run. When Treat Dubbed Anime Streams as English is enabled, anime streams labeled dubbed or dub match English filters and count as having language data. Quality and language detection use stream tags, filenames, URLs, and labels.")
                }
                .eclipseExperimentalSettingsRows()
            }
            .navigationTitle("Extra Source Settings")
            .eclipseSettingsStyle()
            .onAppear {
                serviceResultMinimumSimilarity = ServicesResultRankingSettings.minimumSimilarity()
                dropMismatchedServiceResults = ServicesResultRankingSettings.dropsMismatchedResults()
                reloadHiddenStreamLanguagesFromDefaults()
                reloadExtraRulesSettingsFromDefaults()
                focusExtraServiceSettingsTarget(using: scrollProxy)
            }
        }
    }

    private func focusInitialSearchTarget(using scrollProxy: ScrollViewProxy) {
        guard !didFocusInitialSearchTarget,
              let initialSearchTarget,
              !initialSearchTarget.opensExtraServiceSettings else { return }
        didFocusInitialSearchTarget = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeInOut(duration: 0.28)) {
                scrollProxy.scrollTo(initialSearchTarget.anchorID, anchor: .center)
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
        let items = unifiedItems
        for index in offsets {
            let item = items[index]
            if case .skyStream(let provider) = item {
                pendingSkyStreamUninstallPackageName = provider.packageName
                continue
            }
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
            }
        }
        reloadExtraRulesSettingsFromDefaults()
        syncAutoModeSelectionWithInstalledSources()
    }

    private func moveUnifiedItems(fromOffsets: IndexSet, toOffset: Int) {
        var items = unifiedItems
        items.move(fromOffsets: fromOffsets, toOffset: toOffset)

        // Persist new sortIndex for each item across both stores
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
        if case .skyStream(let provider) = item {
            pendingSkyStreamUninstallPackageName = provider.packageName
            return
        }
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
        }
        reloadExtraRulesSettingsFromDefaults()
        syncAutoModeSelectionWithInstalledSources()
    }
    
    private func addStremioAddon() {
        guard !stremioURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

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
                if isSelected {
                    selectedAutoModeSourceIds.insert(item.autoModeSourceId)
                } else {
                    selectedAutoModeSourceIds.remove(item.autoModeSourceId)
                }
                persistAutoModeSelection()
            }
        )
    }

    private func persistAutoModeSelection() {
        let orderedActive = orderedAutoModeListItems.map(\.autoModeSourceId)
        UserDefaults.standard.set(Array(selectedAutoModeSourceIds), forKey: "servicesAutoModeSourceIds")
        autoModeSourceOrderIds = mergedAutoModeOrder(visibleSourceIDs: orderedActive)
        UserDefaults.standard.set(autoModeSourceOrderIds, forKey: "servicesAutoModeSourceOrderIds")
        captureSkyStreamSourceDefaults()
    }

    private func persistUnifiedOrder(_ items: [UnifiedItem]) {
        let ids = items.map(\.autoModeSourceId)
        autoModeSourceOrderIds = mergedAutoModeOrder(visibleSourceIDs: ids)
        UserDefaults.standard.set(autoModeSourceOrderIds, forKey: "servicesAutoModeSourceOrderIds")
        captureSkyStreamSourceDefaults()
    }

    private func captureSkyStreamSourceDefaults() {
        Task { await skyStreamManager.captureSourceDefaultsState() }
    }

    private func reloadAutoModeSelectionFromDefaults() {
        selectedAutoModeSourceIds = Set(UserDefaults.standard.stringArray(forKey: "servicesAutoModeSourceIds") ?? [])
        autoModeSourceOrderIds = UserDefaults.standard.stringArray(forKey: "servicesAutoModeSourceOrderIds") ?? []
        autoModeQualityPreferenceRaw = AutoModeQualityPreference.sanitizedRawValue(autoModeQualityPreferenceRaw)
        syncAutoModeSelectionWithInstalledSources()
    }

    private func reloadHiddenStreamLanguagesFromDefaults() {
        includedStreamLanguages = StreamLanguageFilter.includedLanguages()
        includedStreamLanguageText = StreamLanguageFilter.editorText(from: includedStreamLanguages)
        hiddenStreamLanguages = StreamLanguageFilter.hiddenLanguages()
        hiddenStreamLanguageText = StreamLanguageFilter.editorText(from: hiddenStreamLanguages)
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
        hiddenStreamQualities = Set(StreamLanguageFilter.hiddenQualityHeights())
        extraRulesSourceIds = StreamLanguageFilter.extraRulesSourceIds().map { Set($0) }
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
                // `nil` means every connected source, including a SkyStream domain this target or
                // emergency-disabled build intentionally cannot display. Materializing that value
                // while toggling one visible source must retain those opaque IDs for a later iPhone.
                let preservedHiddenSkyStreamIDs = Set(
                    (UserDefaults.standard.stringArray(forKey: "servicesAutoModeSourceOrderIds") ?? [])
                        .filter(StreamLanguageFilter.isValidSkyStreamSourceID)
                ).subtracting(visibleConnectedIDs)
                var selected = extraRulesSourceIds
                    ?? visibleConnectedIDs.union(preservedHiddenSkyStreamIDs)
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

    private func syncAutoModeSelectionWithInstalledSources() {
#if os(tvOS)
        let validIds = installedAutoModeSourceIDs
#else
        let validIds = Set(orderedAutoModeListItems.map(\.autoModeSourceId))
#endif
        let previous = selectedAutoModeSourceIds
        let unavailableSkyStreamIds = selectedAutoModeSourceIds.filter {
            StreamLanguageFilter.isValidSkyStreamSourceID($0)
        }
        selectedAutoModeSourceIds = selectedAutoModeSourceIds
            .intersection(validIds)
            .union(unavailableSkyStreamIds)
        let ordered = mergedAutoModeOrder(
            visibleSourceIDs: orderedAutoModeListItems.map(\.autoModeSourceId)
        )
        if selectedAutoModeSourceIds != previous || ordered != autoModeSourceOrderIds {
            autoModeSourceOrderIds = ordered
            persistAutoModeSelection()
        }
    }

#if os(tvOS)
    private var installedAutoModeSourceIDs: Set<String> {
        Set(unifiedItems.compactMap { item in
            switch item {
            case .service:
                return item.autoModeSourceId
            case .stremio(let addon):
                return addon.manifest.supportsStreams ? item.autoModeSourceId : nil
            case .skyStream:
                return nil
            }
        })
    }

#endif

    /// Reorders currently visible sources in place while retaining every inactive,
    /// platform-hidden, or not-yet-loaded source ID from the prior shared order.
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
        var ids = orderedAutoModeListItems.map(\.autoModeSourceId)
        ids.move(fromOffsets: fromOffsets, toOffset: toOffset)
        autoModeSourceOrderIds = mergedAutoModeOrder(visibleSourceIDs: ids)
        UserDefaults.standard.set(autoModeSourceOrderIds, forKey: "servicesAutoModeSourceOrderIds")
        captureSkyStreamSourceDefaults()
    }

    private func moveAutoModeSource(from index: Int, direction: Int) {
        let target = index + direction
        var ids = orderedAutoModeListItems.map(\.autoModeSourceId)
        guard ids.indices.contains(index), ids.indices.contains(target) else { return }
        ids.swapAt(index, target)
        autoModeSourceOrderIds = mergedAutoModeOrder(visibleSourceIDs: ids)
        UserDefaults.standard.set(autoModeSourceOrderIds, forKey: "servicesAutoModeSourceOrderIds")
        captureSkyStreamSourceDefaults()
    }
    
    private func downloadServiceFromURL() {
        guard !downloadURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
        _ = healthStore.version
        guard isServiceActive else { return .unchecked }
        return healthStore.displayState(for: sourceId)
    }
    
    var body: some View {
        HStack {
            KFImage(URL(string: service.metadata.iconUrl))
                .placeholder {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.2))
                        .overlay(
                            Image(systemName: "app.dashed")
                                .foregroundColor(.secondary)
                        )
                }
                .resizable()
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

                Button(role: .destructive, action: { showingRemoveConfirmation = true }) {
                    Label("Remove", systemImage: "trash")
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

// MARK: - iOS 15 compatible Add Service input

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

// MARK: - Stremio Addon Row

struct StremioAddonRow: View {
    let addon: StremioAddon
    @ObservedObject var manager: StremioAddonManager
    @ObservedObject var healthStore: SourceHealthStore
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
#if os(tvOS)
    @Environment(\.dismiss) private var dismiss
    @State private var showingRemoveConfirmation = false
#endif

    private var isAddonActive: Bool {
        if let managed = manager.addons.first(where: { $0.id == addon.id }) {
            return manager.isAddonEnabled(managed)
        }
        return manager.isAddonEnabled(addon)
    }

    private var isConfigurable: Bool {
        addon.manifest.behaviorHints?.configurable == true
    }

    private var resourceLabels: [(title: String, systemImage: String)] {
        var labels: [(title: String, systemImage: String)] = []
        if addon.manifest.supportsStreams {
            labels.append(("Streams", "play.rectangle"))
        }
        if addon.manifest.supportsSubtitles {
            labels.append(("Subtitles", "captions.bubble"))
        }
        if !addon.manifest.homeCatalogs.isEmpty {
            labels.append(("Catalogs", "square.grid.2x2"))
        } else if addon.manifest.supportsCatalogs,
                  addon.manifest.behaviorHints?.configurable == true {
            labels.append(("Needs Config", "gearshape"))
        }
        return labels
    }

    private var sourceId: String {
        SourceHealth.stremioId(addon)
    }

    private var healthState: SourceHealthDisplayState {
        _ = healthStore.version
        guard isAddonActive else { return .unchecked }
        return healthStore.displayState(for: sourceId)
    }

    var body: some View {
        HStack {
            if let logo = addon.manifest.logo, let logoURL = URL(string: logo) {
                KFImage(logoURL)
                    .placeholder {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.2))
                            .overlay(
                                Image(systemName: "play.circle")
                                    .foregroundColor(.secondary)
                            )
                    }
                    .resizable()
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
                            Label(label.title, systemImage: label.systemImage)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                healthStatusLabel
            }

            Spacer()

#if os(tvOS)
            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 10) {
                    if isConfigurable {
                        Button {
                            showConfigure = true
                        } label: {
                            Label("Configure", systemImage: "gearshape")
                        }
                    }

                    Button {
                        showReconfigure = true
                    } label: {
                        Label("Update URL", systemImage: "link")
                    }

                    Button {
                        manager.setAddonState(addon, isActive: !isAddonActive)
                    } label: {
                        Label(isAddonActive ? "Disable" : "Enable", systemImage: isAddonActive ? "pause.circle" : "play.circle")
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

                    Button(role: .destructive, action: { showingRemoveConfirmation = true }) {
                        Label("Remove", systemImage: "trash")
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
            if isConfigurable {
                Button {
                    showConfigure = true
                } label: {
                    Label("Configure", systemImage: "gearshape")
                }
            }
            Button {
                showReconfigure = true
            } label: {
                Label("Update URL", systemImage: "link")
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
        guard !reconfigureURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
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

// MARK: - iOS 15 compatible Add Stremio Addon input

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

// MARK: - iOS 15 compatible Reconfigure Stremio Addon input

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
