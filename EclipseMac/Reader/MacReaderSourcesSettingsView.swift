#if os(macOS)
import AppKit
import CloudKit
import SwiftUI

@MainActor
final class MacReaderRemovalAdmission {
    private let isCurrent: () -> Bool
    private var consumed = false

    init(isCurrent: @escaping () -> Bool) { self.isCurrent = isCurrent }

    static func capture() -> MacReaderRemovalAdmission? {
        guard let authority = MacDownloadStorageAuthority.capture(), NSApp.isActive,
              let window = NSApp.keyWindow ?? NSApp.mainWindow, window.isVisible, !window.isMiniaturized else { return nil }
        let generation = MacLaunchProfileAccess.windowGeneration
        return MacReaderRemovalAdmission { [weak window] in
            guard let window else { return false }
            return authority.isCurrent() && generation == MacLaunchProfileAccess.windowGeneration
                && NSApp.isActive && window.isVisible && !window.isMiniaturized
        }
    }

    func invalidate() { consumed = true }

    @discardableResult
    func perform(_ operation: () throws -> Void) throws -> Bool {
        guard !consumed else { return false }
        consumed = true
        guard isCurrent() else { return false }
        try operation()
        return true
    }
}

struct MacReaderSourcesSettingsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var manager = ReaderExtensionManager.shared
    @ObservedObject private var profiles = ProfileManager.shared
    @State private var repositoryURL = ""
    @State private var selectedRepository: ReaderExtensionRepositoryRecord?
    @State private var error: String?
    @State private var adding = false
    @State private var administrativeTasks: [UUID: Task<Void, Never>] = [:]
    @State private var administrativeGeneration = UUID()
    @State private var removal: ReaderExtensionInstalledSource?
    @State private var repositoryRemoval: ReaderExtensionRepositoryRecord?
    @State private var removalAdmission: MacReaderRemovalAdmission?
    @State private var readerSettings = false
    @State private var appearance = false
    @State private var trackers = false
    @State private var logs = false
    @State private var updateReview: ReaderExtensionMacUpdateReview?
    @State private var updateTask: Task<Void, Never>?
    @State private var updateGeneration = UUID()
    @State private var updatingSource: ReaderExtensionSourceID?
    @State private var defaultsSession = MacReaderSession()
    var body: some View {
        Form {
            Section("Reading") {
                Button("Reader Appearance") { appearance = true }
                Button("Page Behavior and Novel Typography") { readerSettings = true }
                Button("Reader Trackers") { trackers = true }
                if !profiles.isKidsModeActive { MacReaderCatalogSettingsView() }
            }
            if profiles.isKidsModeActive {
                Section("Reader Sources") { Text("Switch to a grown-up profile to manage Reader sources.").foregroundStyle(.secondary) }
            } else {
                Section("Repositories") {
                    HStack {
                        TextField("HTTPS repository URL", text: $repositoryURL)
                        Button("Add") { addRepository() }.disabled(adding || repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if adding { ProgressView().controlSize(.small) }
                    }
                    ForEach(manager.repositories) { repository in
                        HStack {
                            Button { selectedRepository = repository } label: {
                                VStack(alignment: .leading) { Text(repository.displayName); Text(repository.errorMessage ?? "\(repository.sourceCount) sources").font(.caption).foregroundStyle(.secondary) }
                            }.buttonStyle(.plain)
                            Spacer()
                            Button { perform { try await manager.refreshRepository(id: repository.id) } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh repository")
                            Button(role: .destructive) { proposeRemoval(repository: repository) } label: { Image(systemName: "trash") }
                        }
                    }
                }
                Section("Installed Sources") {
                    if manager.installedSources.isEmpty { Text("Add a repository to install manga and novel sources.").foregroundStyle(.secondary) }
                    ForEach(Array(manager.installedSources.enumerated()), id: \.element.id) { index, source in
                        HStack {
                            Toggle(isOn: Binding(get: { source.enabled }, set: { value in attempt { try manager.setEnabled(value, for: source.id) } })) {
                                VStack(alignment: .leading) {
                                    Text(source.name)
                                    Text("\(ReaderExtensionLanguageInfo.displayName(source.language)) · \(source.mediaType.rawValue.capitalized)").font(.caption).foregroundStyle(.secondary)
                                    if !source.isRunnable { Text("Source code needs repair. Use Update Source to retry.").font(.caption).foregroundStyle(.orange) }
                                    if let issue = source.lastError { Text(issue).font(.caption).foregroundStyle(.orange) }
                                }
                            }
                            Spacer()
                            Button { attempt { try manager.moveInstalledSources(from: IndexSet(integer: index), to: index - 1) } } label: { Image(systemName: "arrow.up") }.disabled(index == 0).help("Move source up")
                            Button { attempt { try manager.moveInstalledSources(from: IndexSet(integer: index), to: index + 2) } } label: { Image(systemName: "arrow.down") }.disabled(index == manager.installedSources.count - 1).help("Move source down")
                            Button { update(source.id) } label: { if updatingSource == source.id { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") } }.disabled(updatingSource != nil || manager.isUpdatingSources).help("Update source")
                            Button(role: .destructive) { proposeRemoval(source: source) } label: { Image(systemName: "trash") }
                        }
                    }
                    Button("Update All Sources") { perform { await manager.updateAll() } }.disabled(manager.isUpdatingSources)
                    Toggle("Automatic Source Updates", isOn: Binding(get: { manager.autoUpdateSources }, set: { value in attempt { try manager.setAutoUpdateSources(value) } }))
                    Toggle("Show Mature Sources", isOn: Binding(get: { manager.showMatureSources }, set: { value in attempt { try manager.setShowMatureSources(value) } }))
                }
                MacReaderLegacyModuleSettingsView()
            }
            Section("Diagnostics") { Button("Reader Logs") { logs = true } }
        }.formStyle(.grouped).navigationTitle("Reader Settings")
        .sheet(item: $selectedRepository) { MacReaderRepositoryView(repository: $0).frame(minWidth: 620, minHeight: 600) }
        .sheet(isPresented: $readerSettings) { MacReaderSettingsView(session: defaultsSession).frame(width: 620, height: 720) }
        .sheet(isPresented: $appearance) { MacReaderAppearanceSettingsView().frame(width: 640, height: 720) }
        .sheet(isPresented: $trackers) { MacReaderTrackerSettingsView().frame(width: 640, height: 640) }
        .sheet(isPresented: $logs) { NavigationStack { ReaderLoggerView().toolbar { Button("Done") { logs = false } } }.frame(width: 780, height: 650) }
        .sheet(item: $updateReview) { review in
            MacReaderSourceUpdateReviewView(review: review, cancel: { updateReview = nil }, approve: { commit(review) }).frame(width: 680, height: 700)
        }
        .alert("Reader Sources", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        .confirmationDialog("Remove Reader source?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { cancelRemoval() } }), titleVisibility: .visible) {
            Button("Remove Source", role: .destructive) { commitRemoval() }
            Button("Cancel", role: .cancel) { cancelRemoval() }
        } message: { Text("Completed downloads remain readable. Source code and authentication are removed.") }
        .confirmationDialog("Remove repository and installed sources?", isPresented: Binding(get: { repositoryRemoval != nil }, set: { if !$0 { cancelRemoval() } }), titleVisibility: .visible) {
            Button("Remove Repository", role: .destructive) { commitRemoval() }
            Button("Cancel", role: .cancel) { cancelRemoval() }
        } message: { Text("Completed downloads remain readable.") }
        .onChange(of: profiles.activeProfileID) { _ in selectedRepository = nil; removal = nil; repositoryRemoval = nil; adding = false; error = nil; cancelUpdate(); cancelAdministrativeTasks() }
        .onDisappear { cancelUpdate(); cancelAdministrativeTasks() }
        .onChange(of: scenePhase) { phase in if phase != .active { cancelUpdate(); cancelAdministrativeTasks() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in cancelUpdate(); cancelAdministrativeTasks() }
        .onReceive(NotificationCenter.default.publisher(for: .macMainWindowClosed)) { _ in cancelUpdate(); cancelAdministrativeTasks() }
        .onReceive(NotificationCenter.default.publisher(for: ServiceStoreScope.didChangeNotification)) { _ in cancelUpdate(); cancelAdministrativeTasks() }
        .onReceive(NotificationCenter.default.publisher(for: .mediaStateWillChangeCurrentUser)) { _ in cancelUpdate(); cancelAdministrativeTasks() }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in cancelUpdate(); cancelAdministrativeTasks() }
        .onReceive(NotificationCenter.default.publisher(for: .NSUbiquityIdentityDidChange)) { _ in cancelUpdate(); cancelAdministrativeTasks() }
        .onReceive(MacWindowCoordinator.shared.$isTerminating) { terminating in if terminating { cancelUpdate(); cancelAdministrativeTasks() } }
    }
    private func proposeRemoval(source: ReaderExtensionInstalledSource? = nil, repository: ReaderExtensionRepositoryRecord? = nil) {
        cancelRemoval()
        guard scenePhase == .active, let admission = MacReaderRemovalAdmission.capture() else { return }
        removalAdmission = admission
        removal = source
        repositoryRemoval = repository
    }
    private func commitRemoval() {
        guard let admission = removalAdmission else { return }
        defer { cancelRemoval() }
        do {
            try admission.perform {
                if let removal { try manager.uninstall(sourceID: removal.id) }
                else if let repositoryRemoval { try manager.removeRepository(id: repositoryRemoval.id) }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func cancelRemoval() {
        removalAdmission?.invalidate()
        removalAdmission = nil
        removal = nil
        repositoryRemoval = nil
    }
    private func addRepository() {
        guard let authority = MacDownloadStorageAuthority.capture(), scenePhase == .active, NSApp.isActive else { return }
        do {
            let urls = try ReaderExtensionRepositoryInput.repositoryURLs(from: repositoryURL)
            let generation = administrativeGeneration
            let id = UUID()
            adding = true
            administrativeTasks[id] = Task { @MainActor in
                defer { if generation == administrativeGeneration { adding = false; administrativeTasks[id] = nil } }
                do {
                    for url in urls {
                        try Task.checkCancellation()
                        guard authority.isCurrent(), generation == administrativeGeneration else { return }
                        try await manager.addRepository(url)
                    }
                    guard !Task.isCancelled, authority.isCurrent(), generation == administrativeGeneration else { return }
                    repositoryURL = ""
                } catch { if !Task.isCancelled, authority.isCurrent(), generation == administrativeGeneration { self.error = error.localizedDescription } }
            }
        } catch { self.error = error.localizedDescription }
    }
    private func attempt(_ action: () throws -> Void) { do { try action() } catch { self.error = error.localizedDescription } }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard let authority = MacDownloadStorageAuthority.capture(), scenePhase == .active, NSApp.isActive else { return }
        let generation = administrativeGeneration
        let id = UUID()
        administrativeTasks[id] = Task { @MainActor in
            defer { if generation == administrativeGeneration { administrativeTasks[id] = nil } }
            guard !Task.isCancelled, authority.isCurrent(), generation == administrativeGeneration else { return }
            do { try await action() }
            catch { if !Task.isCancelled, authority.isCurrent(), generation == administrativeGeneration { self.error = error.localizedDescription } }
        }
    }
    private func cancelAdministrativeTasks() {
        cancelRemoval()
        administrativeGeneration = UUID()
        administrativeTasks.values.forEach { $0.cancel() }
        administrativeTasks = [:]
        adding = false
    }
    private func update(_ sourceID: ReaderExtensionSourceID) {
        guard scenePhase == .active, NSApp.isActive, let window = NSApp.mainWindow ?? NSApp.keyWindow,
              window.isVisible, !window.isMiniaturized,
              let authority = MacDownloadStorageAuthority.capture(), updatingSource == nil else { return }
        let generation = UUID()
        updateGeneration = generation
        updatingSource = sourceID
        updateTask = Task { @MainActor in
            defer { if generation == updateGeneration { updatingSource = nil; updateTask = nil } }
            do {
                try await manager.update(sourceID: sourceID)
            } catch ReaderExtensionError.updateConsentRequired {
                do {
                    try Task.checkCancellation()
                    guard authority.isCurrent() else { return }
                    let review = try await manager.prepareMacSourceUpdateReview(sourceID: sourceID)
                    guard !Task.isCancelled, authority.isCurrent(), generation == updateGeneration,
                          NSApp.isActive, window.isVisible, !window.isMiniaturized else { return }
                    updateReview = review
                } catch { if !Task.isCancelled, authority.isCurrent(), generation == updateGeneration, NSApp.isActive, window.isVisible { self.error = error.localizedDescription } }
            } catch { if !Task.isCancelled, authority.isCurrent(), generation == updateGeneration, NSApp.isActive, window.isVisible { self.error = error.localizedDescription } }
        }
    }
    private func commit(_ review: ReaderExtensionMacUpdateReview) {
        guard scenePhase == .active, NSApp.isActive, let window = NSApp.mainWindow ?? NSApp.keyWindow,
              window.isVisible, !window.isMiniaturized,
              let authority = MacDownloadStorageAuthority.capture() else { updateReview = nil; return }
        let generation = UUID()
        updateGeneration = generation
        updateReview = nil
        updatingSource = review.current.id
        updateTask = Task { @MainActor in
            defer { if generation == updateGeneration { updatingSource = nil; updateTask = nil } }
            do { try await manager.commitMacSourceUpdateReview(review) }
            catch { if !Task.isCancelled, authority.isCurrent(), generation == updateGeneration, NSApp.isActive, window.isVisible { self.error = error.localizedDescription } }
        }
    }
    private func cancelUpdate() { updateGeneration = UUID(); updateTask?.cancel(); updateTask = nil; updateReview = nil; updatingSource = nil }
}

private struct MacReaderSourceUpdateReviewView: View {
    let review: ReaderExtensionMacUpdateReview
    let cancel: () -> Void
    let approve: () -> Void
    private var oldDomains: Set<String> {
        ReaderExtensionSecurityPolicy.canonicalHosts([review.current.repositoryURL.host, review.current.sourceCodeURL?.host, review.current.baseURL.host, review.current.apiURL?.host].compactMap { $0 })
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Review Source Update").font(.title2.bold()); Spacer(); Button("Cancel", action: cancel) }.padding()
            Form {
                Section(review.current.name) {
                    LabeledContent("Version", value: "\(review.current.version) → \(review.catalog.version)")
                    LabeledContent("Content Rating", value: "\(review.current.maturity.rawValue) → \(review.catalog.maturity.rawValue)")
                    LabeledContent("License", value: "\(review.current.license.kind.rawValue) → \(review.license.kind.rawValue)")
                    LabeledContent("Current Code", value: (review.current.sourceCodeURL ?? review.current.repositoryURL).absoluteString).textSelection(.enabled)
                    LabeledContent("Proposed Code", value: (review.catalog.sourceCodeURL ?? review.catalog.repositoryURL).absoluteString).textSelection(.enabled)
                }
                Section("Network Domains") {
                    ForEach(review.domains.sorted(), id: \.self) { domain in LabeledContent(domain, value: oldDomains.contains(domain) ? "Existing" : "New") }
                    ForEach(oldDomains.subtracting(review.domains).sorted(), id: \.self) { domain in LabeledContent(domain, value: "Removed") }
                }
                Section("Runtime Permissions") {
                    let capabilities = review.validation?.capabilities ?? []
                    if capabilities.isEmpty { Text("No runtime capabilities requested.") }
                    ForEach(capabilities.sorted { $0.rawValue < $1.rawValue }, id: \.self) { capability in LabeledContent(capability.rawValue, value: review.current.runtimeCapabilities.contains(capability) ? "Existing" : "New") }
                }
                Section("Secret Preference Access") {
                    let keys = review.validation?.secretPreferenceKeys ?? []
                    if keys.isEmpty { Text("No secret preference fields requested.") }
                    ForEach(keys.sorted(), id: \.self) { key in LabeledContent(key, value: review.current.secretPreferenceKeys.contains(key) ? "Existing" : "New") }
                    Text("Only field names are shown. Existing secret values stay private.").font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            HStack { Text("Install the reviewed source version and allow these permissions.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Approve and Update", action: approve).buttonStyle(.borderedProminent) }.padding()
        }
    }
}

private struct MacReaderAppearanceSettingsView: View {
    @ObservedObject private var settings = Settings.shared
    @ObservedObject private var theme = EclipseTheme.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ReaderDetailElement.orderStorageKey) private var order = ReaderDetailElement.defaultOrderRawValue
    @AppStorage(ReaderDetailElement.hiddenStorageKey) private var hidden = ""
    private var elements: [ReaderDetailElement] { ReaderDetailElement.orderedElements(from: order) }
    var body: some View {
        VStack {
            HStack { Text("Reader Appearance").font(.title2.bold()); Spacer(); Button("Done") { dismiss() } }.padding()
            Form {
                Section("Interface") {
                    Toggle("Global Appearance", isOn: $theme.globalAppearanceEnabled).onChange(of: theme.globalAppearanceEnabled) { _ in settings.updateAppearance() }
                    Picker("Appearance", selection: Binding(get: { theme.globalAppearanceEnabled ? settings.selectedAppearance : settings.readerSelectedAppearance }, set: { value in if theme.globalAppearanceEnabled { settings.selectedAppearance = value } else { settings.readerSelectedAppearance = value } })) {
                        Text("System").tag(Appearance.system); Text("Light").tag(Appearance.light); Text("Dark").tag(Appearance.dark)
                    }
                    ColorPicker("Accent Color", selection: Binding(get: { theme.globalAppearanceEnabled ? settings.accentColor : settings.readerAccentColor }, set: { color in if theme.globalAppearanceEnabled { settings.accentColor = color; AccentColorManager.shared.saveAccentColor(color) } else { settings.readerAccentColor = color } }))
                    ColorPicker("Theme Color", selection: Binding(get: { theme.globalAppearanceEnabled ? theme.settingsGradientColor : theme.readerSettingsGradientColor }, set: { color in if theme.globalAppearanceEnabled { theme.settingsGradientColor = color } else { theme.readerSettingsGradientColor = color } }))
                    Picker("Atmosphere", selection: Binding(get: { theme.globalAppearanceEnabled ? theme.atmosphereStyle : theme.readerAtmosphereStyle }, set: { value in if theme.globalAppearanceEnabled { theme.atmosphereStyle = value } else { theme.readerAtmosphereStyle = value } })) { ForEach(AtmosphereStyle.allCases) { Text($0.displayName).tag($0) } }
                    if (theme.globalAppearanceEnabled ? theme.atmosphereStyle : theme.readerAtmosphereStyle) == .solid {
                        Picker("Solid Color Source", selection: Binding(get: { theme.globalAppearanceEnabled ? theme.atmosphereSolidColorSource : theme.readerAtmosphereSolidColorSource }, set: { value in if theme.globalAppearanceEnabled { theme.atmosphereSolidColorSource = value } else { theme.readerAtmosphereSolidColorSource = value } })) { ForEach(AtmosphereSolidColorSource.allCases) { Text($0.displayName).tag($0) } }
                        if (theme.globalAppearanceEnabled ? theme.atmosphereSolidColorSource : theme.readerAtmosphereSolidColorSource) == .custom {
                            ColorPicker("Custom Atmosphere Color", selection: Binding(get: { theme.globalAppearanceEnabled ? theme.atmosphereSolidColor : theme.readerAtmosphereSolidColor }, set: { value in if theme.globalAppearanceEnabled { theme.atmosphereSolidColor = value } else { theme.readerAtmosphereSolidColor = value } }))
                        }
                    }
                }
                Section("Detail Page") {
                    ForEach(Array(elements.enumerated()), id: \.element.id) { index, element in
                        HStack {
                            Toggle(element.displayName, isOn: Binding(get: { ReaderDetailElement.isVisible(element, hiddenRawValue: hidden) }, set: { visible in
                                var values = ReaderDetailElement.hiddenElements()
                                if visible { values.remove(element) } else { values.insert(element) }
                                ReaderDetailElement.saveHiddenElements(values)
                            }))
                            Button { move(index, direction: -1) } label: { Image(systemName: "arrow.up") }.disabled(index == 0).help("Move up")
                            Button { move(index, direction: 1) } label: { Image(systemName: "arrow.down") }.disabled(index == elements.count - 1).help("Move down")
                        }
                    }
                    Button("Reset Detail Layout") { ReaderDetailElement.saveOrder(ReaderDetailElement.defaultOrder); ReaderDetailElement.saveHiddenElements([]) }
                }
            }.formStyle(.grouped)
        }.onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in dismiss() }
    }
    private func move(_ index: Int, direction: Int) { var values = elements; values.swapAt(index, index + direction); ReaderDetailElement.saveOrder(values) }
}

private struct MacReaderTrackerSettingsView: View {
    @ObservedObject private var tracker = TrackerManager.shared
    @ObservedObject private var profiles = ProfileManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var importing: TrackerService?
    @State private var presentedImport: TrackerImportPresentation?
    @State private var authority: MacAccountInteractionAuthority?
    var body: some View {
        VStack {
            HStack { Text("Reader Trackers").font(.title2.bold()); Spacer(); Button("Done") { dismiss() } }.padding()
            if profiles.isKidsModeActive { ContentUnavailableView("Reader Trackers", systemImage: "lock", description: Text("Switch to a grown-up profile to manage trackers and import lists.")) }
            else {
                Form {
                    Section("Reader Sync") {
                        Toggle("Enable Reader Sync", isOn: Binding(get: { tracker.trackerState.readerSyncEnabled }, set: { tracker.setReaderSyncEnabled($0) }))
                        Toggle("Auto Sync Reader Ratings", isOn: Binding(get: { tracker.trackerState.autoSyncReaderRatings }, set: { tracker.setAutoSyncReaderRatings($0) }))
                        Text("Reader sync is independent from Media mode. Ratings sync after a confident manga match. Notes sync only through the tracker button on a detail page.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Accounts") {
                        ForEach([TrackerService.anilist, .myAnimeList], id: \.self) { service in
                            HStack {
                                Text(service.displayName)
                                Spacer()
                                if let account = tracker.trackerState.getAccount(for: service) {
                                    Text(account.username).foregroundStyle(.secondary)
                                    Button("Disconnect") { guard MacAccountInteractionAuthority.capture() != nil else { return }; tracker.disconnectTracker(service) }
                                    Button(tracker.importState(for: service)?.isImporting == true ? "View Progress" : "Import Library") {
                                        authority = MacAccountInteractionAuthority.capture()
                                        guard authority != nil else { return }
                                        if tracker.importState(for: service)?.isImporting == true {
                                            presentedImport = TrackerImportPresentation(service: service)
                                        } else {
                                            importing = service
                                        }
                                    }
                                } else { Button("Connect") { guard MacAccountInteractionAuthority.capture() != nil else { return }; if service == .anilist { tracker.startAniListAuth() } else { tracker.startMALAuth() } } }
                            }
                            if let state = tracker.importState(for: service) {
                                Button(state.isImporting ? state.message : "\(state.title) · View Result") {
                                    presentedImport = TrackerImportPresentation(service: service)
                                }
                                .font(.caption)
                                .foregroundStyle(state.needsAttention ? .orange : .secondary)
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if let error = tracker.authError { Text(error).foregroundStyle(.orange) }
                }.formStyle(.grouped)
            }
        }.confirmationDialog("Import Reader Library?", isPresented: Binding(get: { importing != nil }, set: { if !$0 { importing = nil; authority = nil } }), titleVisibility: .visible) {
            Button("Import") { guard let importing, authority?.isCurrent == true else { self.importing = nil; return }; if importing == .anilist { tracker.importAniListToLibrary() } else { tracker.importMALToLibrary() }; presentedImport = TrackerImportPresentation(service: importing); self.importing = nil; authority = nil }
            Button("Cancel", role: .cancel) { importing = nil; authority = nil }
        } message: { Text("This imports manga lists and progress without deleting or downgrading local entries.") }
        .sheet(item: $presentedImport) { selection in
            TrackerImportProgressView(service: selection.service)
                .frame(width: 520, height: 500)
        }
        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in importing = nil; presentedImport = nil; authority = nil; dismiss() }
    }
}

private struct MacReaderLegacyModuleSettingsView: View {
    @ObservedObject private var modules = ModuleManager.shared
    @State private var url = ""
    @State private var loading = false
    @State private var proposal: ModuleData?
    @State private var proposalURL = ""
    @State private var authority: MacDownloadStorageAuthority?
    @State private var error: String?
    @State private var generation = UUID()
    @State private var operation: Task<Void, Never>?
    @State private var automaticUpdates = ModuleManager.isAutoUpdateEnabled

    var body: some View {
        Section("Legacy JavaScript Modules") {
            Text("Existing JavaScript modules remain available for compatible sources.").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Module metadata URL", text: $url)
                Button("Add Module", action: prepare).disabled(loading || url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if loading { ProgressView().controlSize(.small) }
            }
            ForEach(modules.modules) { module in
                HStack {
                    VStack(alignment: .leading) {
                        Text(module.moduleData.sourceName).font(.headline)
                        Text("\(module.moduleData.language) · \(module.moduleData.author.name) · \(module.moduleData.version)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Copy URL") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(module.moduleurl, forType: .string) }
                    Button(role: .destructive) { guard MacDownloadStorageAuthority.capture() != nil else { return }; modules.deleteModule(module) } label: { Image(systemName: "trash") }
                }
            }
            Toggle("Automatic Module Updates", isOn: $automaticUpdates)
                .onChange(of: automaticUpdates) { value in guard MacDownloadStorageAuthority.capture() != nil else { return }; ModuleManager.isAutoUpdateEnabled = value }
        }
        .confirmationDialog("Install Legacy Reader Module?", isPresented: Binding(get: { proposal != nil }, set: { if !$0 { proposal = nil; authority = nil } }), titleVisibility: .visible) {
            Button("Install Module", action: install)
            Button("Cancel", role: .cancel) { proposal = nil; authority = nil }
        } message: { Text(proposal.map { "\($0.sourceName) by \($0.author.name) will install and execute JavaScript from its configured source." } ?? "") }
        .alert("Reader Modules", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        .onDisappear(perform: cancel)
        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in cancel() }
    }

    private func cancel() { generation = UUID(); operation?.cancel(); operation = nil; proposal = nil; authority = nil; loading = false }

    private func prepare() {
        guard let captured = MacDownloadStorageAuthority.capture() else { return }
        let token = generation
        let candidate = url.trimmingCharacters(in: .whitespacesAndNewlines)
        loading = true
        operation = Task { @MainActor in
            defer { if token == generation { loading = false; operation = nil } }
            do {
                let metadata = try await modules.validateModuleUrl(candidate)
                guard !Task.isCancelled, token == generation, captured.isCurrent() else { return }
                proposal = metadata
                proposalURL = candidate
                authority = captured
            } catch { if !Task.isCancelled, token == generation, captured.isCurrent() { self.error = error.localizedDescription } }
        }
    }

    private func install() {
        guard let proposal, let authority, authority.isCurrent() else { self.proposal = nil; return }
        let candidate = proposalURL
        let token = generation
        self.proposal = nil
        loading = true
        operation = Task { @MainActor in
            defer { if token == generation { loading = false; operation = nil } }
            do { try await modules.addModules(candidate, metaData: proposal); if token == generation, authority.isCurrent() { url = "" } }
            catch { if !Task.isCancelled, token == generation, authority.isCurrent() { self.error = error.localizedDescription } }
        }
    }
}

private struct MacReaderRepositoryView: View {
    let repository: ReaderExtensionRepositoryRecord
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = ReaderExtensionManager.shared
    @State private var query = ""
    @State private var language = "all"
    @State private var media = "all"
    @State private var error: String?
    @State private var pending: ReaderExtensionCatalogSource?
    @State private var approvedAuthority: MacDownloadStorageAuthority?
    @State private var profileGeneration = UUID()
    private var sources: [ReaderExtensionCatalogSource] {
        manager.sources(inRepository: repository.id).filter { source in
            (query.isEmpty || source.name.localizedCaseInsensitiveContains(query)) && (language == "all" || source.language == language) && (media == "all" || source.mediaType.rawValue == media) && (manager.showMatureSources || source.maturity != .mature)
        }
    }
    var body: some View {
        VStack {
            HStack { Text(repository.displayName).font(.title2.bold()); Spacer(); Button("Done") { dismiss() } }.padding()
            HStack {
                TextField("Search sources", text: $query)
                Picker("Language", selection: $language) { Text("All Languages").tag("all"); ForEach(Array(Set(manager.sources(inRepository: repository.id).map(\.language))).sorted(), id: \.self) { Text(ReaderExtensionLanguageInfo.displayName($0)).tag($0) } }
                Picker("Format", selection: $media) { Text("All").tag("all"); Text("Manga").tag("manga"); Text("Novel").tag("novel") }
            }.padding(.horizontal)
            List(sources) { source in
                HStack {
                    VStack(alignment: .leading) { Text(source.name).font(.headline); Text("\(ReaderExtensionLanguageInfo.displayName(source.language)) · \(source.mediaType.rawValue.capitalized) · \(source.version)").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if manager.installingSourceIDs.contains(source.id) { ProgressView().controlSize(.small) }
                    else if manager.blockedSourceIDs.contains(source.id) { Button("Unblock") { guard let authority = MacDownloadStorageAuthority.capture(), authority.isCurrent() else { return }; do { try manager.unblock(sourceID: source.id) } catch { self.error = error.localizedDescription } } }
                    else if manager.source(for: source.id) != nil { Label("Installed", systemImage: "checkmark.circle").foregroundStyle(.secondary) }
                    else { Button("Install") { approvedAuthority = MacDownloadStorageAuthority.capture(); if approvedAuthority != nil { pending = source } }.disabled(!source.isInstallable) }
                }
            }
        }.task { do { try await manager.hydrateRepositoryCatalogIfNeeded(id: repository.id) } catch { self.error = error.localizedDescription } }
        .confirmationDialog("Install Reader Source", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button("Install and Allow Listed Domains") {
                guard let source = pending, approvedAuthority?.isCurrent() == true else { pending = nil; return }
                let generation = profileGeneration
                let domains = manager.requiredDomains(for: source.id)
                pending = nil
                Task { do { try await manager.install(sourceID: source.id, allowUnknownLicense: source.license.kind == .unknown, approvedDomains: domains) } catch { if generation == profileGeneration { self.error = error.localizedDescription } } }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: { Text(pending.map { source in "\(source.name) will execute source code and contact:\n\(manager.requiredDomains(for: source.id).sorted().joined(separator: "\n"))\nLicense: \(source.license.kind.rawValue)" } ?? "") }
        .alert("Reader Sources", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in profileGeneration = UUID(); pending = nil; dismiss() }
    }
}

private struct MacReaderCatalogSettingsView: View {
    @ObservedObject private var catalogs = KanzenCustomCatalogManager.shared
    @State private var editing: KanzenCustomCatalog?
    @State private var showPresets = false
    @State private var showBuilder = false
    @State private var name = ""
    @State private var error: String?
    var body: some View {
        DisclosureGroup("Discover Catalogs") {
            HStack {
                Button("New Catalog…") { showBuilder = true }
                Button("Add Catalog Presets…") { showPresets = true }
            }.disabled(MacDownloadStorageAuthority.capture() == nil)
            if catalogs.catalogs.isEmpty { Text("Create a catalog or save an advanced search to add it to Discover.").foregroundStyle(.secondary) }
            ForEach(catalogs.catalogs) { catalog in
                HStack {
                    Toggle(catalog.title, isOn: Binding(get: { catalog.isEnabled }, set: { catalogs.setEnabled($0, id: catalog.id) }))
                    Spacer()
                    Button { move(catalog, delta: -1) } label: { Image(systemName: "arrow.up") }.help("Move catalog up")
                    Button { move(catalog, delta: 1) } label: { Image(systemName: "arrow.down") }.help("Move catalog down")
                    Picker("Display", selection: Binding(get: { catalog.displayStyle }, set: { style in var value = catalog; value.displayStyle = style; do { _ = try catalogs.save(value) } catch { self.error = error.localizedDescription } })) { ForEach(KanzenCatalogDisplayStyle.allCases, id: \.self) { Text($0.displayName).tag($0) } }.frame(width: 170)
                    Button("Rename") { editing = catalog; name = catalog.title }
                    Button(role: .destructive) { catalogs.remove(id: catalog.id) } label: { Image(systemName: "trash") }
                }
            }
        }
        .sheet(isPresented: $showBuilder) { MacReaderCatalogBuilderView().frame(width: 660, height: 680) }
        .sheet(isPresented: $showPresets) { MacReaderCatalogPresetsView().frame(width: 620, height: 620) }
        .alert("Rename Catalog", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("Name", text: $name)
            Button("Save") { guard var editing else { return }; editing.title = name; do { _ = try catalogs.save(editing) } catch { self.error = error.localizedDescription }; self.editing = nil }
            Button("Cancel", role: .cancel) { editing = nil }
        }
        .alert("Catalog", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
    private func move(_ catalog: KanzenCustomCatalog, delta: Int) {
        let rows = catalogs.catalogs(for: catalog.sourceID)
        guard let index = rows.firstIndex(where: { $0.id == catalog.id }), rows.indices.contains(index + delta) else { return }
        catalogs.move(from: IndexSet(integer: index), to: delta > 0 ? index + 2 : index - 1, within: catalog.sourceID)
    }

}

private struct MacReaderCatalogBuilderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var manager = ReaderExtensionManager.shared
    @State private var selectedSource = ""
    @State private var name = ""
    @State private var query = ""
    @State private var displayStyle = KanzenCatalogDisplayStyle.poster
    @State private var filters: [ReaderExtensionFilter] = []
    @State private var initialFilters: [ReaderExtensionFilter] = []
    @State private var loading = false
    @State private var error: String?
    @State private var filterRevision = 0
    @State private var authority: MacDownloadStorageAuthority?
    @State private var loadedRequest: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Catalog").font(.title2.bold())
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") { save() }.buttonStyle(.borderedProminent).disabled(selectedSource.isEmpty || loading || authority?.isCurrent() != true)
            }.padding()
            if let error { Text(error).foregroundStyle(.secondary).padding(.horizontal) }
            Form {
                Picker("Source", selection: $selectedSource) { Text("Choose Source").tag(""); ForEach(manager.enabledSources) { Text($0.name).tag($0.id.rawValue) } }
                TextField("Catalog Name", text: $name, prompt: Text(KanzenCustomCatalog.suggestedTitle(query: query, filters: filters)))
                Picker("Display", selection: $displayStyle) { ForEach(KanzenCatalogDisplayStyle.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                Text(displayStyle.summary).font(.caption).foregroundStyle(.secondary)
                if displayStyle.isQueryBacked {
                    TextField("Search Query", text: $query)
                    Section("Source Filters") {
                        if loading { ProgressView("Loading filters…") }
                        if !selectedSource.isEmpty {
                            HStack {
                                Button("Reload Filters") { filterRevision += 1 }.disabled(loading)
                                Button("Reset Filters") { filters = initialFilters }.disabled(loading || filters == initialFilters)
                            }
                        }
                        ReaderExtensionFilterEditorList(filters: $filters).disabled(loading)
                    }
                }
            }.formStyle(.grouped)
        }
        .task(id: "\(selectedSource):\(filterRevision):\(scenePhase)") { await loadFilters() }
        .onChange(of: selectedSource) { _ in filters = []; initialFilters = []; error = nil; authority = nil; loadedRequest = nil }
        .onChange(of: scenePhase) { phase in if phase != .active { loading = false; ReaderExtensionCloudflareVerificationCoordinator.shared.cancel() } }
        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in dismiss() }
        .onReceive(NotificationCenter.default.publisher(for: ServiceStoreScope.didChangeNotification)) { _ in dismiss() }
        .onDisappear { ReaderExtensionCloudflareVerificationCoordinator.shared.cancel() }
    }

    private func loadFilters() async {
        guard scenePhase == .active, !selectedSource.isEmpty, let captured = MacDownloadStorageAuthority.capture() else { return }
        let sourceID = ReaderExtensionSourceID(rawValue: selectedSource)
        let request = "\(selectedSource):\(filterRevision)"
        authority = captured
        guard loadedRequest != request else { return }
        loading = true
        error = nil
        defer { if !Task.isCancelled { loading = false } }
        do {
            let provider = try manager.provider(for: sourceID, allowsAutomaticBrowserVerification: true)
            let loaded = try await provider.filters()
            try Task.checkCancellation()
            guard captured.isCurrent(), sourceID.rawValue == selectedSource else { return }
            filters = loaded
            initialFilters = loaded
            loadedRequest = request
        } catch {
            if !Task.isCancelled, captured.isCurrent(), sourceID.rawValue == selectedSource { self.error = error.localizedDescription }
        }
    }

    private func save() {
        guard scenePhase == .active, authority?.isCurrent() == true, !selectedSource.isEmpty, !loading else { return }
        let sourceID = ReaderExtensionSourceID(rawValue: selectedSource)
        guard manager.enabledSources.contains(where: { $0.id == sourceID }) else { return }
        do {
            _ = try KanzenCustomCatalogManager.shared.save(KanzenCustomCatalog(title: name, sourceID: sourceID, query: query, filters: filters, displayStyle: displayStyle))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct MacReaderCatalogPresetsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var manager = ReaderExtensionManager.shared
    @ObservedObject private var catalogs = KanzenCustomCatalogManager.shared
    @State private var selected = ""
    @State private var resolutions: [KanzenCatalogPresetResolution] = []
    @State private var loading = false
    @State private var error: String?
    var body: some View {
        VStack {
            HStack { Text("Catalog Presets").font(.title2.bold()); Spacer(); Button("Done") { dismiss() } }.padding()
            Picker("Source", selection: $selected) { Text("Choose Source").tag(""); ForEach(manager.enabledSources) { Text($0.name).tag($0.id.rawValue) } }.padding(.horizontal)
            if loading { ProgressView("Loading available filters…") }
            if let error { Text(error).foregroundStyle(.secondary).padding() }
            List(resolutions, id: \.preset.id) { resolution in
                HStack {
                    VStack(alignment: .leading) { Text(resolution.title).font(.headline); Text(resolution.matchedLabel).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    let source = ReaderExtensionSourceID(rawValue: selected)
                    if catalogs.catalog(forPresetID: resolution.preset.id, sourceID: source) != nil { Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary) }
                    else { Button("Add") { do { _ = try catalogs.save(resolution.catalog(for: source)) } catch { self.error = error.localizedDescription } }.disabled(ProfileManager.shared.isKidsModeActive || !catalogs.canAddCatalog(for: source)) }
                }
            }
        }.task(id: selected) {
            resolutions = []
            error = nil
            guard !selected.isEmpty, !ProfileManager.shared.isKidsModeActive else { return }
            loading = true
            defer { if !Task.isCancelled { loading = false } }
            do {
                let provider = try manager.provider(for: ReaderExtensionSourceID(rawValue: selected))
                let filters = try await provider.filters()
                try Task.checkCancellation()
                resolutions = KanzenCatalogPresetResolver.resolutions(against: filters, builtInRows: KanzenCatalogBuiltInRows(source: provider.source))
                if resolutions.isEmpty { error = "This source does not offer filters for the catalog presets." }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in dismiss() }
    }
}
#endif
