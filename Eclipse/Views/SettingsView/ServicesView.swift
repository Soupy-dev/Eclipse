import SwiftUI
import Kingfisher

struct ServicesView: View {
    @StateObject private var serviceManager = ServiceManager.shared
    @StateObject private var stremioManager = StremioAddonManager.shared
    @StateObject private var pluginManager = NuvioPluginManager.shared
    @StateObject private var healthStore = SourceHealthStore.shared
    @Environment(\.editMode) private var editMode
    @State private var showDownloadAlert = false
    @State private var downloadURL = ""
    @State private var serviceDownloadAlert: ServiceDownloadAlert?
    @AppStorage("autoUpdateServicesEnabled") private var autoUpdateEnabled = true
    @State private var showStremioAddAlert = false
    @State private var stremioURL = ""
    @State private var stremioError: String?
    @State private var showStremioError = false
    @AppStorage("servicesAutoModeEnabled") private var servicesAutoModeEnabled = false
    @AppStorage("servicesAutoSelectEpisodesEnabled") private var servicesAutoSelectEpisodesEnabled = false
    @AppStorage("servicesAutoModeQualityPreference") private var autoModeQualityPreferenceRaw = AutoModeQualityPreference.defaultPreference.rawValue
    @State private var selectedAutoModeSourceIds: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "servicesAutoModeSourceIds") ?? [])
    @State private var autoModeSourceOrderIds: [String] = UserDefaults.standard.stringArray(forKey: "servicesAutoModeSourceOrderIds") ?? []

    private var pluginsAllowed: Bool {
        Bundle.main.allowsNuvioPlugins
    }

    private var hasAnyInstalledSources: Bool {
        !serviceManager.services.isEmpty ||
        !stremioManager.addons.isEmpty ||
        (pluginsAllowed && !pluginManager.installedSources.isEmpty)
    }

    private var sourceSectionTitle: String {
        pluginsAllowed ? "Services, Addons & Plugins" : "Services & Addons"
    }

    private struct ServiceDownloadAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }
    
    var body: some View {
        ZStack {
            VStack {
                if !hasAnyInstalledSources {
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
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
#endif
            .refreshable {
                await serviceManager.updateServices()
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
            .onAppear {
                _ = healthStore.version
                if pluginsAllowed {
                    pluginManager.load()
                }
                reloadAutoModeSelectionFromDefaults()
            }
            .onChangeComp(of: pluginManager.state) { _, _ in
                reloadAutoModeSelectionFromDefaults()
            }
        }
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    /// A tagged union so services and Stremio addons can share one reorderable list.
    private enum UnifiedItem: Identifiable {
        case service(Service)
        case stremio(StremioAddon)
        case plugin(NuvioPluginSource)

        var id: String {
            switch self {
            case .service(let s): return "service:\(s.id.uuidString)"
            case .stremio(let a): return "stremio:\(a.id.uuidString)"
            case .plugin(let p): return p.id
            }
        }

        var sortIndex: Int64 {
            switch self {
            case .service(let s): return s.sortIndex
            case .stremio(let a): return a.sortIndex
            case .plugin: return Int64.max
            }
        }

        var isActive: Bool {
            switch self {
            case .service(let s): return s.isActive
            case .stremio(let a): return a.isActive
            case .plugin: return true
            }
        }

        var supportsAutoMode: Bool {
            switch self {
            case .service:
                return true
            case .stremio(let a):
                return a.manifest.supportsStreams
            case .plugin(let source):
                return !source.scrapers.isEmpty
            }
        }

        var displayName: String {
            switch self {
            case .service(let s): return s.metadata.sourceName
            case .stremio(let a): return a.manifest.name
            case .plugin(let source): return source.name
            }
        }

        var autoModeSourceId: String {
            switch self {
            case .service(let s): return "service:\(s.id.uuidString)"
            case .stremio(let a): return "stremio:\(a.id.uuidString)"
            case .plugin(let source): return source.id
            }
        }
    }

    private var unifiedItems: [UnifiedItem] {
        let services: [UnifiedItem] = serviceManager.services.map { .service($0) }
        let addons: [UnifiedItem] = stremioManager.addons.map { .stremio($0) }
        let plugins: [UnifiedItem] = pluginManager.installedSources.map { .plugin($0) }
        var orderRank: [String: Int] = [:]
        for (index, sourceId) in autoModeSourceOrderIds.enumerated() where orderRank[sourceId] == nil {
            orderRank[sourceId] = index
        }
        return (services + addons + plugins).sorted {
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
        case plugin(NuvioPluginSource)

        var id: String { autoModeSourceId }

        var isActive: Bool {
            switch self {
            case .service(let service): return service.isActive
            case .stremio(let addon): return addon.isActive
            case .plugin: return true
            }
        }

        var supportsAutoMode: Bool {
            switch self {
            case .service:
                return true
            case .stremio(let addon):
                return addon.manifest.supportsStreams
            case .plugin(let source):
                return !source.scrapers.isEmpty
            }
        }

        var displayName: String {
            switch self {
            case .service(let service): return service.metadata.sourceName
            case .stremio(let addon): return addon.manifest.name
            case .plugin(let source): return source.name
            }
        }

        var autoModeSourceId: String {
            switch self {
            case .service(let service): return "service:\(service.id.uuidString)"
            case .stremio(let addon): return "stremio:\(addon.id.uuidString)"
            case .plugin(let source): return source.id
            }
        }
    }

    private var orderedAutoModeListItems: [AutoModeSourceItem] {
        let unifiedSources: [AutoModeSourceItem] = unifiedItems.compactMap { item in
            switch item {
            case .service(let service): return .service(service)
            case .stremio(let addon): return .stremio(addon)
            case .plugin: return nil
            }
        }
        let pluginSources: [AutoModeSourceItem] = pluginManager.activeSources.map { .plugin($0) }
        let activeItems = (unifiedSources + pluginSources).filter { $0.isActive && $0.supportsAutoMode }
        let byId = Dictionary(uniqueKeysWithValues: activeItems.map { ($0.autoModeSourceId, $0) })
        var ordered = autoModeSourceOrderIds.compactMap { byId[$0] }
        let existing = Set(ordered.map(\.autoModeSourceId))
        ordered.append(contentsOf: activeItems.filter { !existing.contains($0.autoModeSourceId) })
        return ordered
    }

    private var orderedAutoModeItems: [AutoModeSourceItem] {
        orderedAutoModeListItems.filter { selectedAutoModeSourceIds.contains($0.autoModeSourceId) }
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
        List {
            Section {
                Toggle("Auto-Update Services", isOn: $autoUpdateEnabled)
            } footer: {
                Text("Automatically check for service updates when the app is opened.")
            }
            .eclipseExperimentalSettingsRows()
            .background(EclipseScrollTracker())

            Section {
                Toggle("Auto Mode", isOn: $servicesAutoModeEnabled)

                Toggle("Auto-Select Episodes", isOn: $servicesAutoSelectEpisodesEnabled)

                if servicesAutoModeEnabled {
                    Toggle("Auto Quality", isOn: autoModeQualityEnabledBinding)

                    if autoModeQualityPreference.usesAutomaticSelection {
                        Picker("Quality", selection: autoModeQualityPreferenceBinding) {
                            ForEach(AutoModeQualityPreference.allCases.filter(\.usesAutomaticSelection)) { preference in
                                Text(preference.title).tag(preference)
                            }
                        }
                    }

                    Text(autoModeQualityPreference.settingsDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if orderedAutoModeListItems.isEmpty {
                        Text("Activate at least one stream-capable source to use Auto Mode.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(orderedAutoModeListItems.indices, id: \.self) { index in
                            let item = orderedAutoModeListItems[index]
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
                                .disabled(index >= orderedAutoModeListItems.count - 1)
#endif
                            }
                        }
#if !os(tvOS)
                        .onMove(perform: moveAutoModeSources)
#endif
                    }
                }
            } footer: {
                Text("Auto-Select Episodes also applies when choosing a source manually. Auto Mode checks enabled sources from top to bottom. Drag to set priority, and turn Auto Quality off when you want to choose stream quality yourself.")
            }
            .eclipseExperimentalSettingsRows()

            Section(header: unifiedSectionHeader) {
                if !hasAnyInstalledSources {
                    Text(pluginsAllowed ? "No services, addons, or plugins installed" : "No services or addons installed")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(unifiedItems) { item in
                        switch item {
                        case .service(let service):
                            ServiceRow(service: service, serviceManager: serviceManager, healthStore: healthStore)
                        case .stremio(let addon):
                            StremioAddonRow(addon: addon, manager: stremioManager, healthStore: healthStore)
                        case .plugin(let source):
                            PluginSourceRow(source: source, manager: pluginManager, healthStore: healthStore)
                        }
                    }
                    .onDelete(perform: deleteUnifiedItems)
                    .onMove(perform: moveUnifiedItems)
                }
            }
            .eclipseExperimentalSettingsRows()
        }
    }

    @ViewBuilder
    private var unifiedSectionHeader: some View {
        Text(sourceSectionTitle)
    }

    private func deleteUnifiedItems(offsets: IndexSet) {
        let items = unifiedItems
        for index in offsets {
            switch items[index] {
            case .service(let service):
                serviceManager.removeService(service)
            case .stremio(let addon):
                stremioManager.removeAddon(addon)
            case .plugin(let source):
                pluginManager.setSourceEnabled(source, enabled: false)
            }
        }
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
            case .plugin:
                continue
            }
        }

        ServiceStore.shared.save()
        StremioAddonStore.shared.save()
        serviceManager.loadServicesFromCloud()
        stremioManager.loadAddons()
        persistUnifiedOrder(items)
        syncAutoModeSelectionWithInstalledSources()
    }
    
    private func addStremioAddon() {
        guard !stremioURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        Task {
            do {
                try await stremioManager.addAddon(from: stremioURL)
                await MainActor.run {
                    stremioURL = ""
                    reloadAutoModeSelectionFromDefaults()
                }
            } catch {
                await MainActor.run {
                    stremioError = error.localizedDescription
                    showStremioError = true
                }
            }
        }
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
        autoModeSourceOrderIds = orderedActive
        UserDefaults.standard.set(orderedActive, forKey: "servicesAutoModeSourceOrderIds")
    }

    private func persistUnifiedOrder(_ items: [UnifiedItem]) {
        let ids = items.map(\.autoModeSourceId)
        autoModeSourceOrderIds = ids
        UserDefaults.standard.set(ids, forKey: "servicesAutoModeSourceOrderIds")
    }

    private func reloadAutoModeSelectionFromDefaults() {
        selectedAutoModeSourceIds = Set(UserDefaults.standard.stringArray(forKey: "servicesAutoModeSourceIds") ?? [])
        autoModeSourceOrderIds = UserDefaults.standard.stringArray(forKey: "servicesAutoModeSourceOrderIds") ?? []
        autoModeQualityPreferenceRaw = AutoModeQualityPreference.sanitizedRawValue(autoModeQualityPreferenceRaw)
        syncAutoModeSelectionWithInstalledSources()
    }

    private func syncAutoModeSelectionWithInstalledSources() {
        let validIds = Set(orderedAutoModeListItems.map(\.autoModeSourceId))
        let previous = selectedAutoModeSourceIds
        selectedAutoModeSourceIds = selectedAutoModeSourceIds.intersection(validIds)
        let ordered = orderedAutoModeListItems.map(\.autoModeSourceId)
        if selectedAutoModeSourceIds != previous || ordered != autoModeSourceOrderIds {
            autoModeSourceOrderIds = ordered
            persistAutoModeSelection()
        }
    }

    private func moveAutoModeSources(fromOffsets: IndexSet, toOffset: Int) {
        var ids = orderedAutoModeListItems.map(\.autoModeSourceId)
        ids.move(fromOffsets: fromOffsets, toOffset: toOffset)
        autoModeSourceOrderIds = ids
        UserDefaults.standard.set(ids, forKey: "servicesAutoModeSourceOrderIds")
    }

    private func moveAutoModeSource(from index: Int, direction: Int) {
        let target = index + direction
        var ids = orderedAutoModeListItems.map(\.autoModeSourceId)
        guard ids.indices.contains(index), ids.indices.contains(target) else { return }
        ids.swapAt(index, target)
        autoModeSourceOrderIds = ids
        UserDefaults.standard.set(ids, forKey: "servicesAutoModeSourceOrderIds")
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
    @State private var showingSettings = false
    
    private var isServiceActive: Bool {
        if let managedService = serviceManager.services.first(where: { $0.id == service.id }) {
            return managedService.isActive
        }
        return service.isActive
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
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                if hasSettings {
                    Button(action: {
                        showingSettings = true
                    }) {
                        Image(systemName: "pencil")
                            .foregroundStyle(Color.secondary)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                
                if isServiceActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 20, height: 20)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) {
                serviceManager.setServiceState(service, isActive: !isServiceActive)
            }
        }
        .sheet(isPresented: $showingSettings) {
            ServiceSettingsView(service: service, serviceManager: serviceManager)
        }
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

struct PluginSourceRow: View {
    let source: NuvioPluginSource
    @ObservedObject var manager: NuvioPluginManager
    @ObservedObject var healthStore: SourceHealthStore

    private var isSourceEnabled: Bool {
        manager.isSourceEnabled(source)
    }

    private var canEnableSource: Bool {
        manager.canEnableSource(source)
    }

    private var sourceId: String {
        SourceHealth.pluginId(source)
    }

    private var healthState: SourceHealthDisplayState {
        _ = healthStore.version
        guard isSourceEnabled else { return .unchecked }
        return healthStore.displayState(for: sourceId)
    }

    private var subtitle: String {
        let repositoryName = source.repositoryUrl.flatMap { url in
            manager.repositories.first(where: { $0.manifestUrl == url })?.name
        }
        let providerText = "\(source.scrapers.count) provider\(source.scrapers.count == 1 ? "" : "s")"
        var seenTypes = Set<String>()
        let types = source.scrapers
            .flatMap { $0.supportedTypes }
            .map(NuvioPluginSupport.normalizeType)
            .filter { seenTypes.insert($0).inserted }
            .map { $0.uppercased() }
            .joined(separator: ", ")
        return [repositoryName, providerText, types.isEmpty ? nil : types]
            .compactMap { $0 }
            .joined(separator: " - ")
    }

    var body: some View {
        HStack {
            pluginIcon
                .padding(.trailing, 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.gray)
                    .lineLimit(1)

                healthStatusLabel
            }

            Spacer()

            if isSourceEnabled {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20, height: 20)
            } else if !canEnableSource {
                Image(systemName: "minus.circle")
                    .foregroundStyle(Color.secondary)
                    .frame(width: 20, height: 20)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard canEnableSource || isSourceEnabled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                manager.setSourceEnabled(source, enabled: !isSourceEnabled)
            }
        }
    }

    @ViewBuilder
    private var pluginIcon: some View {
        if let logo = source.logo, let logoURL = URL(string: logo) {
            KFImage(logoURL)
                .placeholder {
                    placeholderIcon
                }
                .resizable()
                .frame(width: 40, height: 40)
                .clipShape(Circle())
        } else {
            placeholderIcon
                .frame(width: 40, height: 40)
                .clipShape(Circle())
        }
    }

    private var placeholderIcon: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.gray.opacity(0.2))
            .overlay(
                Image(systemName: "puzzlepiece.extension")
                    .foregroundColor(.secondary)
            )
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
        if #available(iOS 16, *) {
            content
                .alert("Add Service", isPresented: $isPresented) {
                    TextField("JSON URL", text: $downloadURL)
                    Button("Cancel", role: .cancel) {
                        downloadURL = ""
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
                }
        }
    }
}

// MARK: - Stremio Addon Row

struct StremioAddonRow: View {
    let addon: StremioAddon
    @ObservedObject var manager: StremioAddonManager
    @ObservedObject var healthStore: SourceHealthStore
    @State private var showConfigure = false
    @State private var showReconfigure = false
    @State private var reconfigureURL = ""
    @State private var reconfigureError: String?
    @State private var showReconfigureError = false

    private var isAddonActive: Bool {
        if let managed = manager.addons.first(where: { $0.id == addon.id }) {
            return managed.isActive
        }
        return addon.isActive
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
        if addon.manifest.supportsCatalogs {
            labels.append(("Catalogs", "square.grid.2x2"))
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

            if isAddonActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 20, height: 20)
            }
        }
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
                reconfigureURL = ""
                showReconfigure = true
            } label: {
                Label("Update URL", systemImage: "link")
            }
        }
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
        if #available(iOS 16, *) {
            content
                .alert("Add Stremio Addon", isPresented: $isPresented) {
                    TextField("Addon URL", text: $addonURL)
                    Button("Cancel", role: .cancel) {
                        addonURL = ""
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
        if #available(iOS 16, *) {
            content
                .alert("Reconfigure Addon", isPresented: $isPresented) {
                    TextField("New Addon URL", text: $addonURL)
                    Button("Cancel", role: .cancel) {
                        addonURL = ""
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
                }
        }
    }
}
