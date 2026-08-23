#if !os(tvOS)
import SwiftUI
import UIKit
import WebKit

/// Reader source administration intentionally stays in the existing Reader Sources
/// settings location. Eclipse does not bundle or recommend a repository.
struct ReaderExtensionsSettingsView: View {
    @StateObject private var manager = ReaderExtensionManager.shared
    @StateObject private var contentFilter = ReaderContentFilter.shared
    @State private var repositoryURL = ""
    @State private var isAddingRepository = false
    @State private var pendingRepositoryRemoval: ReaderExtensionRepositoryRecord?
    @State private var pendingSourceRemoval: ReaderExtensionInstalledSource?
    @State private var errorMessage: String?
    @State private var editMode: EditMode = .inactive

    var body: some View {
        Group {
            if contentFilter.isKidsProfileActive {
                restrictedContent
            } else {
                administrationContent
            }
        }
        .preferredColorScheme(.dark)
    }

    private var restrictedContent: some View {
        List {
            Section {
                Text("This is a kids profile, so it cannot add, edit, or remove reader extensions. Switch to a grown-up profile to manage sources.")
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Reader Sources")
        .navigationBarTitleDisplayMode(.inline)
        .eclipseSettingsStyle()
    }

    private var administrationContent: some View {
        List {
            repositorySection
            installedSection
        }
        .navigationTitle("Reader Sources")
        .navigationBarTitleDisplayMode(.inline)
        .eclipseSettingsStyle()
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(editMode.isEditing ? "Done" : "Edit") {
                    withAnimation {
                        editMode = editMode.isEditing ? .inactive : .active
                    }
                }
                .disabled(manager.repositories.isEmpty && manager.installedSources.isEmpty)
            }
        }
        .alert("Reader Extensions", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "Remove this repository?",
            isPresented: Binding(
                get: { pendingRepositoryRemoval != nil },
                set: { if !$0 { pendingRepositoryRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Repository and Sources", role: .destructive) {
                guard let repository = pendingRepositoryRemoval else { return }
                pendingRepositoryRemoval = nil
                do {
                    try manager.removeRepository(id: repository.id)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) { pendingRepositoryRemoval = nil }
        } message: {
            Text("Installed sources from this repository will also be removed. Completed downloads remain readable offline.")
        }
        .confirmationDialog(
            "Remove this reader source?",
            isPresented: Binding(
                get: { pendingSourceRemoval != nil },
                set: { if !$0 { pendingSourceRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove Source", role: .destructive) {
                guard let source = pendingSourceRemoval else { return }
                pendingSourceRemoval = nil
                do {
                    try manager.uninstall(sourceID: source.id)
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) { pendingSourceRemoval = nil }
        } message: {
            Text("Completed downloads remain readable. The source code and authentication state will be removed.")
        }
    }

    private var repositorySection: some View {
        Section(
            header: Text("Repositories"),
            footer: Text("Eclipse includes no catalog or provider scripts. Add a direct HTTPS index.json or novel_index.json URL, or a Mangayomi add-repo link, that you trust. Repository and provider terms remain your responsibility.")
        ) {
            HStack {
                TextField("https://example.com/index.json", text: $repositoryURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .onSubmit { addRepository(repositoryURL) }

                Button("Add") {
                    addRepository(repositoryURL)
                }
                .disabled(repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAddingRepository)
            }

            if manager.repositories.isEmpty {
                Text("No repositories added")
                    .foregroundColor(.secondary)
            } else {
                ForEach(manager.repositories) { repository in
                    NavigationLink(destination: ReaderExtensionRepositoryView(repositoryID: repository.id)) {
                        ReaderExtensionRepositoryRow(repository: repository)
                    }
                }
                .onDelete(perform: requestRepositoryRemoval)
            }

            Button {
                Task { await refreshAllRepositories() }
            } label: {
                Label(manager.isRefreshing ? "Refreshing…" : "Refresh Repositories", systemImage: "arrow.clockwise")
            }
            .disabled(manager.isRefreshing || manager.repositories.isEmpty)
        }
        .eclipseExperimentalSettingsRows()
        .background(EclipseScrollTracker())
    }

    private var installedSection: some View {
        Section(
            header: Text("Installed Sources"),
            footer: Text("This list is the installed-software index. Disabled sources do not appear in Discover or Search. Mature-source visibility still follows the existing Reader setting.")
        ) {
            Toggle("Show Mature Sources", isOn: Binding(
                get: { manager.showMatureSources },
                set: {
                    do { try manager.setShowMatureSources($0) }
                    catch { errorMessage = error.localizedDescription }
                }
            ))

            Toggle("Auto-Update Sources", isOn: Binding(
                get: { manager.autoUpdateSources },
                set: {
                    do { try manager.setAutoUpdateSources($0) }
                    catch { errorMessage = error.localizedDescription }
                }
            ))

            Button {
                Task { await updateAllSources() }
            } label: {
                Label(manager.isUpdatingSources ? "Updating Sources…" : "Update All Sources", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(manager.isUpdatingSources || manager.installedSources.isEmpty)

            if manager.installedSources.isEmpty {
                Text("No reader extensions installed")
                    .foregroundColor(.secondary)
            } else {
                ForEach(sortedInstalledSources) { source in
                    HStack(spacing: 12) {
                        ReaderExtensionInstalledSourceRow(source: source)
                        Spacer(minLength: 8)
                        Toggle("", isOn: Binding(
                            get: { manager.source(for: source.id)?.enabled ?? false },
                            set: { setSourceEnabled($0, sourceID: source.id) }
                        ))
                        .labelsHidden()
                        .accessibilityLabel("Enable \(source.name)")
                    }
                }
                .onDelete(perform: requestSourceRemoval)
                .onMove { offsets, destination in
                    do { try manager.moveInstalledSources(from: offsets, to: destination) }
                    catch { errorMessage = error.localizedDescription }
                }
            }
        }
        .eclipseExperimentalSettingsRows()
        .background(EclipseScrollTracker())
    }

    private var sortedInstalledSources: [ReaderExtensionInstalledSource] {
        manager.installedSources.sorted {
            if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func requestRepositoryRemoval(at offsets: IndexSet) {
        guard let index = offsets.first,
              manager.repositories.indices.contains(index) else { return }
        pendingRepositoryRemoval = manager.repositories[index]
    }

    private func requestSourceRemoval(at offsets: IndexSet) {
        let sources = sortedInstalledSources
        guard let index = offsets.first,
              sources.indices.contains(index) else { return }
        pendingSourceRemoval = sources[index]
    }

    private func setSourceEnabled(_ enabled: Bool, sourceID: ReaderExtensionSourceID) {
        do {
            try manager.setEnabled(enabled, for: sourceID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addRepository(_ rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isAddingRepository else { return }
        let urls: [URL]
        do {
            urls = try ReaderExtensionRepositoryInput.repositoryURLs(from: value)
        } catch {
            errorMessage = ReaderExtensionError.invalidRepositoryURL.localizedDescription
            return
        }
        isAddingRepository = true
        Task {
            do {
                for url in urls {
                    try await manager.addRepository(url, allowUnknownLicense: true)
                }
                repositoryURL = ""
                isAddingRepository = false
            } catch {
                isAddingRepository = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshAllRepositories() async {
        await manager.refreshAllRepositories()
    }

    private func updateAllSources() async {
        await manager.updateAll()
    }
}

private struct ReaderExtensionRepositoryRow: View {
    let repository: ReaderExtensionRepositoryRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(repository.displayName)
                .font(.subheadline)
                .fontWeight(.medium)
            Text(repository.indexURL.absoluteString)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            if let error = repository.errorMessage {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(2)
            } else {
                Text("\(repository.sourceCount) source\(repository.sourceCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct ReaderExtensionRepositoryView: View {
    let repositoryID: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = ReaderExtensionManager.shared
    @StateObject private var contentFilter = ReaderContentFilter.shared
    @State private var pendingRepositoryUpdateConsent: String?
    @State private var errorMessage: String?
    @State private var catalogSearchText = ""
    @State private var catalogEntries: [ReaderExtensionCatalogSearchIndex.Entry] = []
    @State private var displayedCatalogEntries: [ReaderExtensionCatalogSearchIndex.Entry] = []
    @State private var catalogPage = 0
    @State private var catalogIndexRevision = 0
    @State private var catalogIndexGeneration = 0
    @State private var catalogIndexTask: Task<Void, Never>?

    private var repository: ReaderExtensionRepositoryRecord? {
        manager.repository(id: repositoryID)
    }

    var body: some View {
        Group {
            if contentFilter.isKidsProfileActive {
                restrictedView
            } else {
                unrestrictedBody
            }
        }
        .preferredColorScheme(.dark)
    }

    private var restrictedView: some View {
        ScrollView {
            VStack(spacing: 24) {
                GlassSection(header: "Reader Sources") {
                    Text("Reader extensions cannot be managed from a kids profile. Switch to a grown-up profile to continue.")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.68))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .background(GlobalGradientBackground().ignoresSafeArea())
        .navigationTitle("Reader Sources")
        .navigationBarTitleDisplayMode(.inline)
        .eclipseDarkToolbar()
    }

    private var unrestrictedBody: some View {
        let installedSourceIDs = Set(manager.installedSources.map(\.id))
        let installingSourceIDs = manager.installingSourceIDs

        return ScrollView {
            VStack(spacing: 24) {
                if let repository {
                    GlassSection(header: "Repository") {
                        VStack(spacing: 0) {
                            repositoryMetadataRow("Index", repository.indexURL.absoluteString)
                            if let website = ReaderExtensionSecurityPolicy.sanitizedMetadataDisplayURL(
                                repository.websiteURL
                            ) {
                                GlassDivider(leadingInset: 16)
                                Link(destination: website) {
                                    GlassSettingsRow(
                                        icon: "safari.fill",
                                        iconColor: .blue,
                                        title: "Open Repository Website"
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                            if let refreshed = repository.lastRefreshedAt {
                                GlassDivider(leadingInset: 16)
                                repositoryMetadataRow(
                                    "Last Refreshed",
                                    refreshed.formatted(date: .abbreviated, time: .shortened)
                                )
                            }
                            GlassDivider(leadingInset: 16)
                            Button {
                                Task { await refreshRepository() }
                            } label: {
                                GlassSettingsRow(
                                    icon: "arrow.clockwise",
                                    iconColor: .teal,
                                    title: manager.isRefreshing ? "Refreshing…" : "Refresh"
                                ) {
                                    if manager.isRefreshing {
                                        ProgressView().tint(.white.opacity(0.7))
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(manager.isRefreshing)
                        }
                    }

                    ReaderExtensionRepositoryCatalogSection(
                        entries: displayedCatalogEntries,
                        currentPage: $catalogPage,
                        hasSearchQuery: !catalogSearchText
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty,
                        installedSourceIDs: installedSourceIDs,
                        installingSourceIDs: installingSourceIDs,
                        blockedSourceIDs: manager.blockedSourceIDs,
                        install: install,
                        unblock: unblock
                    )
                } else {
                    GlassSection(header: "Repository") {
                        Text("This repository is no longer installed.")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.62))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .background(GlobalGradientBackground().ignoresSafeArea())
        .navigationTitle(repository?.displayName ?? "Repository")
        .navigationBarTitleDisplayMode(.inline)
        .eclipseDarkToolbar()
        .searchable(
            text: $catalogSearchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search sources or languages"
        )
        .task(id: repositoryID) {
            do {
                try await manager.hydrateRepositoryCatalogIfNeeded(id: repositoryID)
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
        .onReceive(manager.$catalogSources) { sources in
            rebuildCatalogIndex(from: sources, showMatureSources: manager.showMatureSources)
        }
        .onReceive(manager.$showMatureSources) { showMatureSources in
            rebuildCatalogIndex(from: manager.catalogSources, showMatureSources: showMatureSources)
        }
        .task(id: ReaderExtensionCatalogSearchRequest(
            query: catalogSearchText,
            indexRevision: catalogIndexRevision
        )) {
            await updateDisplayedCatalogEntries()
        }
        .onDisappear {
            catalogIndexTask?.cancel()
            catalogIndexTask = nil
        }
        .alert("Approve Repository Change", isPresented: Binding(
            get: { pendingRepositoryUpdateConsent != nil },
            set: { if !$0 { pendingRepositoryUpdateConsent = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingRepositoryUpdateConsent = nil }
            Button("Accept Change", role: .destructive) {
                guard !ProfileManager.shared.isKidsModeActive else { return }
                pendingRepositoryUpdateConsent = nil
                Task { await refreshRepository(allowScopeExpansion: true) }
            }
        } message: {
            Text("The repository changed \(displayedRepositoryUpdateReason). Review its index and website before accepting.")
        }
        .alert("Reader Extensions", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func repositoryMetadataRow(_ label: String, _ value: String) -> some View {
        ReaderExtensionMetadataRow(label: label, value: value)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }

    private var displayedRepositoryUpdateReason: String {
        guard let reason = pendingRepositoryUpdateConsent else { return "its published metadata" }
        return reason.localizedCaseInsensitiveContains("license") ? "its published metadata" : reason
    }

    private func refreshRepository(allowScopeExpansion: Bool = false) async {
        guard !ProfileManager.shared.isKidsModeActive else { return }
        do {
            try await manager.refreshRepository(id: repositoryID, allowScopeExpansion: allowScopeExpansion)
        } catch ReaderExtensionError.updateConsentRequired(let reason) {
            if !allowScopeExpansion, reason.localizedCaseInsensitiveContains("license") {
                await refreshRepository(allowScopeExpansion: true)
            } else {
                pendingRepositoryUpdateConsent = reason
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func install(_ sourceID: ReaderExtensionSourceID) {
        guard !ProfileManager.shared.isKidsModeActive else { return }
        // Adding the repository is the trust decision. Installation still passes
        // exactly the source's declared/canonical domains to the manager, which
        // rejects missing, extra, insecure, and private-network destinations.
        let declaredDomains = manager.requiredDomains(for: sourceID)
        Task {
            guard !ProfileManager.shared.isKidsModeActive else { return }
            do {
                try await manager.install(
                    sourceID: sourceID,
                    allowUnknownLicense: true,
                    approvedDomains: declaredDomains
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func rebuildCatalogIndex(
        from sources: [ReaderExtensionCatalogSource],
        showMatureSources: Bool
    ) {
        catalogIndexGeneration &+= 1
        let generation = catalogIndexGeneration
        let repositoryID = repositoryID
        let localeIdentifier = Locale.current.identifier
        let preferredLanguageIdentifiers = Locale.preferredLanguages

        catalogIndexTask?.cancel()
        catalogIndexTask = Task { @MainActor in
            let entries = await Task.detached(priority: .userInitiated) {
                ReaderExtensionCatalogSearchIndex.build(
                    sources: sources,
                    repositoryID: repositoryID,
                    showMatureSources: showMatureSources,
                    localeIdentifier: localeIdentifier,
                    preferredLanguageIdentifiers: preferredLanguageIdentifiers
                )
            }.value

            guard !Task.isCancelled, generation == catalogIndexGeneration else { return }
            catalogEntries = entries
            catalogIndexRevision &+= 1
        }
    }

    @MainActor
    private func updateDisplayedCatalogEntries() async {
        let query = catalogSearchText
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            do {
                try await Task.sleep(nanoseconds: 175_000_000)
            } catch {
                return
            }
        }

        let entries = catalogEntries
        let localeIdentifier = Locale.current.identifier
        let filtered = await Task.detached(priority: .userInitiated) {
            ReaderExtensionCatalogSearchIndex.filter(
                entries,
                query: query,
                localeIdentifier: localeIdentifier
            )
        }.value
        guard !Task.isCancelled else { return }
        displayedCatalogEntries = filtered
        catalogPage = 0
    }

    private func unblock(_ sourceID: ReaderExtensionSourceID) {
        guard !ProfileManager.shared.isKidsModeActive else { return }
        do {
            try manager.unblock(sourceID: sourceID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct ReaderExtensionCatalogSearchIndex: Sendable {
    struct Entry: Identifiable, Hashable, Sendable {
        let source: ReaderExtensionCatalogSource
        let languageDisplayName: String
        fileprivate let searchText: String
        fileprivate let languageRank: Int
        fileprivate let languageCode: String
        fileprivate let nameSortKey: String

        var id: ReaderExtensionSourceID { source.id }
    }

    static func build(
        sources: [ReaderExtensionCatalogSource],
        repositoryID: String,
        showMatureSources: Bool,
        localeIdentifier: String,
        preferredLanguageIdentifiers: [String]
    ) -> [Entry] {
        let locale = Locale(identifier: localeIdentifier)
        let preferredLanguageCodes = canonicalPreferredLanguageCodes(
            preferredLanguageIdentifiers
        )

        return sources.lazy
            .filter { source in
                source.repositoryID == repositoryID
                    && (showMatureSources || source.maturity != .mature)
            }
            .map { source in
                let languageCode = canonicalLanguageCode(source.language)
                let languageDisplayName = displayName(
                    for: source.language,
                    languageCode: languageCode,
                    locale: locale
                )
                return Entry(
                    source: source,
                    languageDisplayName: languageDisplayName,
                    searchText: normalizedSearchText(
                        [source.name, source.language, languageDisplayName].joined(separator: " "),
                        locale: locale
                    ),
                    languageRank: languagePriority(
                        languageCode,
                        preferredLanguageCodes: preferredLanguageCodes
                    ),
                    languageCode: languageCode,
                    nameSortKey: normalizedSearchText(source.name, locale: locale)
                )
            }
            .sorted { lhs, rhs in
                if lhs.languageRank != rhs.languageRank {
                    return lhs.languageRank < rhs.languageRank
                }
                if lhs.languageCode != rhs.languageCode {
                    return lhs.languageCode < rhs.languageCode
                }
                if lhs.nameSortKey != rhs.nameSortKey {
                    return lhs.nameSortKey < rhs.nameSortKey
                }
                return lhs.id.rawValue < rhs.id.rawValue
            }
    }

    static func filter(
        _ entries: [Entry],
        query: String,
        localeIdentifier: String
    ) -> [Entry] {
        let locale = Locale(identifier: localeIdentifier)
        let terms = normalizedSearchText(query, locale: locale)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !terms.isEmpty else { return entries }
        return entries.filter { entry in
            terms.allSatisfy(entry.searchText.contains)
        }
    }

    private static func displayName(
        for rawValue: String,
        languageCode: String,
        locale: Locale
    ) -> String {
        let identifier = normalizedLanguageIdentifier(rawValue)
        if let localized = locale.localizedString(forIdentifier: identifier),
           !localized.isEmpty {
            return localized
        }
        if let localized = locale.localizedString(forLanguageCode: languageCode),
           !localized.isEmpty {
            return localized
        }
        return rawValue.uppercased()
    }

    private static func canonicalPreferredLanguageCodes(_ identifiers: [String]) -> [String] {
        var seen = Set<String>()
        return identifiers.compactMap { identifier in
            let code = canonicalLanguageCode(identifier)
            return code.isEmpty || !seen.insert(code).inserted ? nil : code
        }
    }

    private static func languagePriority(
        _ languageCode: String,
        preferredLanguageCodes: [String]
    ) -> Int {
        if languageCode == preferredLanguageCodes.first { return 0 }
        if languageCode == "en" {
            return preferredLanguageCodes.first == "en" ? 0 : 1
        }
        if let preferredIndex = preferredLanguageCodes.firstIndex(of: languageCode) {
            return preferredLanguageCodes.first == "en" ? preferredIndex : preferredIndex + 1
        }
        return preferredLanguageCodes.count + 2
    }

    private static func normalizedLanguageIdentifier(_ rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
    }

    private static func canonicalLanguageCode(_ rawValue: String) -> String {
        let identifier = normalizedLanguageIdentifier(rawValue)
        let localeCode = Locale(identifier: identifier).languageCode
        let fallback = identifier.split(separator: "-", maxSplits: 1).first.map(String.init)
            ?? identifier
        return (localeCode ?? fallback).lowercased()
    }

    private static func normalizedSearchText(_ rawValue: String, locale: Locale) -> String {
        rawValue
            .precomposedStringWithCanonicalMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: locale
            )
            .lowercased(with: locale)
    }
}

private struct ReaderExtensionCatalogSearchRequest: Hashable {
    let query: String
    let indexRevision: Int
}

private struct ReaderExtensionRepositoryCatalogSection: View {
    static let pageSize = 40

    let entries: [ReaderExtensionCatalogSearchIndex.Entry]
    @Binding var currentPage: Int
    let hasSearchQuery: Bool
    let installedSourceIDs: Set<ReaderExtensionSourceID>
    let installingSourceIDs: Set<ReaderExtensionSourceID>
    let blockedSourceIDs: Set<ReaderExtensionSourceID>
    let install: (ReaderExtensionSourceID) -> Void
    let unblock: (ReaderExtensionSourceID) -> Void

    private var pageCount: Int {
        max(1, (entries.count + Self.pageSize - 1) / Self.pageSize)
    }

    private var safeCurrentPage: Int {
        min(max(0, currentPage), pageCount - 1)
    }

    private var pageStartIndex: Int {
        safeCurrentPage * Self.pageSize
    }

    private var pageEndIndex: Int {
        min(entries.count, pageStartIndex + Self.pageSize)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Catalog")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(EclipseTheme.shared.sectionHeaderColor)
                .padding(.horizontal, 18)

            if entries.isEmpty {
                GlassCardGroup {
                    Text(hasSearchQuery
                        ? "No sources match your search."
                        : "No supported sources are available from this repository.")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.62))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .padding(.horizontal, 14)
            } else {
                VStack(spacing: 8) {
                    ForEach(entries[pageStartIndex..<pageEndIndex]) { entry in
                        GlassCardGroup {
                            ReaderExtensionCatalogSourceRow(
                                source: entry.source,
                                languageDisplayName: entry.languageDisplayName,
                                installed: installedSourceIDs.contains(entry.id),
                                installing: installingSourceIDs.contains(entry.id),
                                blocked: blockedSourceIDs.contains(entry.id),
                                install: { install(entry.id) },
                                unblock: { unblock(entry.id) }
                            )
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                        }
                    }

                    if pageCount > 1 {
                        HStack(spacing: 12) {
                            Button("Previous") {
                                currentPage = max(0, safeCurrentPage - 1)
                            }
                            .disabled(safeCurrentPage == 0)

                            Spacer(minLength: 8)

                            Text("\(pageStartIndex + 1)–\(pageEndIndex) of \(entries.count)")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Spacer(minLength: 8)

                            Button("Next") {
                                currentPage = min(pageCount - 1, safeCurrentPage + 1)
                            }
                            .disabled(safeCurrentPage == pageCount - 1)
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 14)
            }
        }
    }
}

private struct ReaderExtensionCatalogSourceRow: View {
    let source: ReaderExtensionCatalogSource
    let languageDisplayName: String
    let installed: Bool
    let installing: Bool
    let blocked: Bool
    let install: () -> Void
    let unblock: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: source.mediaType == .manga ? "books.vertical" : "text.book.closed")
                .foregroundColor(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(source.name) — \(languageDisplayName)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("\(source.language.uppercased()) · \(source.mediaType.displayName) · v\(source.version)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if source.implementation == .unsupportedNative {
                    Text("Requires an Eclipse update")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }

            Spacer()

            if blocked {
                Button("Unblock", action: unblock)
                    .buttonStyle(.borderless)
            } else if installed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .accessibilityLabel("Installed")
            } else if source.license.kind == .restrictive {
                Text("Blocked")
                    .font(.caption)
                    .foregroundColor(.red)
            } else if source.implementation == .unsupportedNative {
                Text("Unavailable")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else if !source.isInstallable {
                Text("Unavailable")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Button(action: install) {
                    if installing {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Installing…")
                                .font(.caption)
                        }
                    } else {
                        Text("Install")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(installing)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct ReaderExtensionInstalledSourceRow: View {
    let source: ReaderExtensionInstalledSource

    @ObservedObject private var compatibilityStore = ReaderExtensionCompatibilityStore.shared

    private var compatibilityReport: ReaderExtensionCompatibilityReport? {
        compatibilityStore.currentReport(
            for: source,
            profileID: ProfileManager.shared.activeProfileID,
            approvedDomains: ReaderExtensionManager.shared.approvedDomains(for: source.id)
        )
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: source.mediaType == .manga ? "books.vertical" : "text.book.closed")
                .foregroundColor(source.enabled ? .accentColor : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(source.enabled ? .primary : .secondary)
                Text("\(source.effectiveLanguage.uppercased()) · \(source.mediaType.displayName) · v\(source.version)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if source.requiresReinstall {
                    Text("Needs reinstall")
                        .font(.caption2)
                        .foregroundColor(.orange)
                } else if let error = source.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(1)
                } else {
                    Text(source.enabled ? "Enabled" : "Disabled")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                if let compatibilityReport {
                    Label(
                        compatibilityReport.classification.displayName,
                        systemImage: compatibilityIcon(compatibilityReport.classification)
                    )
                    .font(.caption2)
                    .foregroundColor(compatibilityColor(compatibilityReport.classification))
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func compatibilityIcon(_ classification: ReaderExtensionCompatibilityClassification) -> String {
        switch classification {
        case .certified: return "checkmark.seal.fill"
        case .runtimeCompatible: return "checkmark.circle.fill"
        case .limited: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private func compatibilityColor(_ classification: ReaderExtensionCompatibilityClassification) -> Color {
        switch classification {
        case .certified: return .green
        case .runtimeCompatible: return .blue
        case .limited: return .orange
        case .failed: return .red
        }
    }
}

private struct ReaderExtensionSourceDetailView: View {
    let sourceID: ReaderExtensionSourceID

    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = ReaderExtensionManager.shared
    @StateObject private var contentFilter = ReaderContentFilter.shared
    @ObservedObject private var compatibilityStore = ReaderExtensionCompatibilityStore.shared
    @ObservedObject private var compatibilityCoordinator = ReaderExtensionCompatibilityCoordinator.shared
    @State private var declaredPreferences: [ReaderExtensionPreference] = []
    @State private var preferenceValues: [String: ReaderExtensionPreferenceValue] = [:]
    @State private var isLoadingPreferences = false
    @State private var isResettingPreferences = false
    @State private var isUpdating = false
    @State private var pendingUpdateConsentReason: String?
    @State private var confirmUninstall = false
    @State private var confirmBlock = false
    @State private var errorMessage: String?

    private var source: ReaderExtensionInstalledSource? {
        manager.source(for: sourceID)
    }

    var body: some View {
        Group {
            if contentFilter.isKidsProfileActive {
                restrictedView
            } else {
                unrestrictedBody
            }
        }
    }

    private var restrictedView: some View {
        List {
            Section {
                Text("Reader extensions cannot be managed from a kids profile. Switch to a grown-up profile to continue.")
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle("Reader Source")
        .navigationBarTitleDisplayMode(.inline)
        .eclipseSettingsStyle()
    }

    private var unrestrictedBody: some View {
        List {
            if let source {
                statusSection(source)
                    .eclipseExperimentalSettingsRows()
                compatibilitySection(source)
                    .eclipseExperimentalSettingsRows()
                preferenceSection(source)
                    .eclipseExperimentalSettingsRows()
                advancedSection(source)
                    .eclipseExperimentalSettingsRows()
                actionSection(source)
                    .eclipseExperimentalSettingsRows()
            } else {
                Section {
                    Text(manager.blockedSourceIDs.contains(sourceID) ? "This source is blocked." : "This source is no longer installed.")
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle(source?.name ?? "Reader Source")
        .navigationBarTitleDisplayMode(.inline)
        .eclipseSettingsStyle()
        .task(id: source?.activeContentDigest) {
            await loadPreferences()
        }
        .alert("Approve Source Update", isPresented: Binding(
            get: { pendingUpdateConsentReason != nil },
            set: { if !$0 { pendingUpdateConsentReason = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingUpdateConsentReason = nil }
            Button("Update Anyway", role: .destructive) {
                pendingUpdateConsentReason = nil
                updateSource(allowScopeExpansion: true)
            }
        } message: {
            Text(updateConsentMessage)
        }
        .confirmationDialog("Remove this reader source?", isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button("Remove Source", role: .destructive) {
                guard !ProfileManager.shared.isKidsModeActive else { return }
                do {
                    try manager.uninstall(sourceID: sourceID)
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Completed downloads remain readable. The source code and authentication state will be removed.")
        }
        .confirmationDialog("Block this reader source?", isPresented: $confirmBlock, titleVisibility: .visible) {
            Button("Block Source", role: .destructive) {
                guard !ProfileManager.shared.isKidsModeActive else { return }
                do {
                    try manager.block(sourceID: sourceID)
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Blocking disables and removes this source and prevents it from being installed again until you explicitly unblock it.")
        }
        .alert("Reader Extensions", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func statusSection(_ source: ReaderExtensionInstalledSource) -> some View {
        Section("Status") {
            Toggle("Enabled", isOn: Binding(
                get: { source.enabled },
                set: {
                    guard !ProfileManager.shared.isKidsModeActive else { return }
                    do { try manager.setEnabled($0, for: source.id) }
                    catch { errorMessage = error.localizedDescription }
                }
            ))
            ReaderExtensionMetadataRow(label: "State", value: source.requiresReinstall ? "Needs reinstall" : (source.enabled ? "Enabled" : "Disabled"))
            if let error = source.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
            Button {
                updateSource(allowScopeExpansion: false)
            } label: {
                Label(isUpdating ? "Updating…" : "Check for Update", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(isUpdating || manager.isUpdatingSources)
        }
    }

    private func compatibilitySection(_ source: ReaderExtensionInstalledSource) -> some View {
        let profileID = ProfileManager.shared.activeProfileID
        let approvedDomains = manager.approvedDomains(for: source.id)
        let currentReport = compatibilityStore.currentReport(
            for: source,
            profileID: profileID,
            approvedDomains: approvedDomains
        )
        let latestReport = compatibilityStore.latestReport(
            sourceID: source.id,
            profileID: profileID
        )
        let report = currentReport ?? latestReport
        let isRunning = compatibilityCoordinator.runningSourceIDs.contains(source.id)

        return Section("Compatibility") {
            if let report {
                HStack(spacing: 10) {
                    Image(systemName: compatibilityIcon(report.classification))
                        .foregroundColor(compatibilityColor(report.classification))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(currentReport == nil ? "Previous result is outdated" : report.classification.displayName)
                            .font(.subheadline.weight(.semibold))
                        Text("\(report.passedCount) checks passed · \(report.checkedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                ForEach(report.checks) { check in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: compatibilityCheckIcon(check.state))
                            .foregroundColor(compatibilityCheckColor(check.state))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.kind.displayName)
                                .font(.subheadline)
                            Text(check.summary)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(report.siteParity.displayName)
                        .font(.subheadline.weight(.semibold))
                    ForEach(Array(report.siteParityNotes.enumerated()), id: \.offset) { _, note in
                        Text("• \(note)")
                            .font(.caption)
                            .foregroundColor(report.siteParity == .knownLimitations ? .orange : .secondary)
                    }
                }
            } else {
                Text("Not checked yet")
                    .foregroundColor(.secondary)
            }

            Button {
                Task { await compatibilityCoordinator.run(sourceID: source.id) }
            } label: {
                if isRunning {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Running Compatibility Check…")
                    }
                } else {
                    Label(report == nil ? "Run Compatibility Check" : "Run Again", systemImage: "checkmark.shield")
                }
            }
            .disabled(isRunning || !source.enabled || !source.isRunnable)

            Text("Checks run only when requested for this source and exercise real source operations. A timeout can trigger the normal safety quarantine. Runtime and filter-shape success prove local Eclipse paths only; they never establish live-site parity.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func compatibilityIcon(_ classification: ReaderExtensionCompatibilityClassification) -> String {
        switch classification {
        case .certified: return "checkmark.seal.fill"
        case .runtimeCompatible: return "checkmark.circle.fill"
        case .limited: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private func compatibilityColor(_ classification: ReaderExtensionCompatibilityClassification) -> Color {
        switch classification {
        case .certified: return .green
        case .runtimeCompatible: return .blue
        case .limited: return .orange
        case .failed: return .red
        }
    }

    private func compatibilityCheckIcon(_ state: ReaderExtensionCompatibilityCheckState) -> String {
        switch state {
        case .passed: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        case .skipped: return "minus.circle"
        }
    }

    private func compatibilityCheckColor(_ state: ReaderExtensionCompatibilityCheckState) -> Color {
        switch state {
        case .passed: return .green
        case .warning: return .orange
        case .failed: return .red
        case .skipped: return .secondary
        }
    }

    @ViewBuilder
    private func preferenceSection(_ source: ReaderExtensionInstalledSource) -> some View {
        if isLoadingPreferences || !declaredPreferences.isEmpty {
            Section("Source Options") {
                if isLoadingPreferences {
                    HStack {
                        ProgressView()
                        Text("Loading source options…")
                            .foregroundColor(.secondary)
                    }
                } else {
                    Button {
                        resetPreferences(source: source)
                    } label: {
                        Label(
                            isResettingPreferences ? "Resetting Options…" : "Reset Non-Secret Options",
                            systemImage: "arrow.counterclockwise"
                        )
                    }
                    .disabled(isResettingPreferences)

                    ForEach(declaredPreferences) { preference in
                        ReaderExtensionPreferenceRow(
                            preference: preference,
                            value: preferenceValues[preference.key] ?? preference.defaultValue,
                            save: { value in savePreference(value, preference: preference, source: source) }
                        )
                    }
                }
            }
        }
    }

    private func advancedSection(_ source: ReaderExtensionInstalledSource) -> some View {
        Section("Advanced") {
            NavigationLink(
                destination: ReaderExtensionSourceTechnicalDetailsView(
                    sourceID: source.id,
                    onDomainsApproved: { Task { await loadPreferences() } }
                )
            ) {
                Label("Technical Details", systemImage: "info.circle")
            }
        }
    }

    private func actionSection(_ source: ReaderExtensionInstalledSource) -> some View {
        Section("Actions") {
            Link(destination: source.sourceCodeURL ?? source.repositoryURL) {
                Label("View Source", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            if let reportURL = manager.reportURL(for: source.id) {
                Link(destination: reportURL) {
                    Label("Report Source", systemImage: "exclamationmark.bubble")
                }
            }
            Button(source.enabled ? "Disable Source" : "Enable Source") {
                guard !ProfileManager.shared.isKidsModeActive else { return }
                do { try manager.setEnabled(!source.enabled, for: source.id) }
                catch { errorMessage = error.localizedDescription }
            }
            Button("Block Source", role: .destructive) {
                guard !ProfileManager.shared.isKidsModeActive else { return }
                confirmBlock = true
            }
            Button("Remove Source", role: .destructive) {
                guard !ProfileManager.shared.isKidsModeActive else { return }
                confirmUninstall = true
            }
        }
    }

    private func loadPreferences() async {
        guard !ProfileManager.shared.isKidsModeActive else { return }
        guard source != nil else { return }
        isLoadingPreferences = true
        do {
            // Configuration providers can inspect declared options while a source is
            // disabled, but receive a deny-all network client.
            let provider = try manager.configurationProvider(for: sourceID)
            let preferences = try await provider.preferences()
            declaredPreferences = preferences
            var loadedValues: [String: ReaderExtensionPreferenceValue] = [:]
            for preference in preferences where loadedValues[preference.key] == nil {
                let persisted = manager.preferenceValue(for: preference.key, sourceID: sourceID)
                loadedValues[preference.key] = preference.kind == .secret
                    ? preference.defaultValue
                    : (persisted ?? preference.defaultValue)
            }
            preferenceValues = loadedValues
            isLoadingPreferences = false
        } catch ReaderExtensionError.domainConsentRequired {
            isLoadingPreferences = false
            declaredPreferences = []
        } catch ReaderExtensionError.unsupportedSource {
            declaredPreferences = []
            isLoadingPreferences = false
        } catch {
            isLoadingPreferences = false
            errorMessage = error.localizedDescription
        }
    }

    private func savePreference(
        _ value: ReaderExtensionPreferenceValue,
        preference: ReaderExtensionPreference,
        source: ReaderExtensionInstalledSource
    ) {
        guard !ProfileManager.shared.isKidsModeActive else { return }
        do {
            try manager.setPreference(value, for: preference.key, sourceID: source.id)
            preferenceValues[preference.key] = preference.kind == .secret ? preference.defaultValue : value
            Task { await loadPreferences() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func resetPreferences(source: ReaderExtensionInstalledSource) {
        guard !ProfileManager.shared.isKidsModeActive, !isResettingPreferences else { return }
        isResettingPreferences = true
        do {
            var defaults: [String: ReaderExtensionPreferenceValue] = [:]
            for preference in declaredPreferences
                where preference.kind != .secret && defaults[preference.key] == nil {
                defaults[preference.key] = preference.defaultValue
            }
            try manager.resetOrdinaryPreferences(to: defaults, sourceID: source.id)
            for (key, value) in defaults { preferenceValues[key] = value }
            isResettingPreferences = false
            Task { await loadPreferences() }
        } catch {
            isResettingPreferences = false
            errorMessage = error.localizedDescription
        }
    }

    private func updateSource(allowScopeExpansion: Bool) {
        guard !ProfileManager.shared.isKidsModeActive else { return }
        guard !isUpdating else { return }
        isUpdating = true
        Task {
            do {
                try await manager.update(sourceID: sourceID, allowScopeExpansion: allowScopeExpansion)
                isUpdating = false
            } catch let error as ReaderExtensionError {
                isUpdating = false
                if error == .unknownLicenseNeedsConsent {
                    updateSource(allowScopeExpansion: true)
                } else if case .domainConsentRequired = error,
                          let reason = ReaderExtensionSourceUpdateConsentPolicy.reason(for: error) {
                    pendingUpdateConsentReason = reason
                } else if let reason = ReaderExtensionSourceUpdateConsentPolicy.reason(for: error),
                          reason.localizedCaseInsensitiveContains("license") {
                    updateSource(allowScopeExpansion: true)
                } else if let reason = ReaderExtensionSourceUpdateConsentPolicy.reason(for: error) {
                    pendingUpdateConsentReason = reason
                } else {
                    errorMessage = error.localizedDescription
                }
            } catch {
                isUpdating = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private var updateConsentMessage: String {
        guard let current = source,
              let available = manager.catalogSource(for: sourceID) else {
            return "This update expands the source's metadata, maturity, or network scope. Review it before continuing."
        }
        let oldDomains = ReaderExtensionSecurityPolicy.canonicalHosts([
            current.repositoryURL.host,
            current.sourceCodeURL?.host,
            current.baseURL.host,
            current.apiURL?.host,
            current.license.url?.host
        ].compactMap { $0 })
        let newDomains = ReaderExtensionSecurityPolicy.canonicalHosts([
            available.repositoryURL.host,
            available.sourceCodeURL?.host,
            available.baseURL.host,
            available.apiURL?.host,
            available.license.url?.host
        ].compactMap { $0 })
        let additions = newDomains.subtracting(oldDomains).sorted()
        var details = "Reason: \(pendingUpdateConsentReason ?? "scope change")."
        if current.sourceCodeURL != available.sourceCodeURL {
            details += "\nSource path: \(current.sourceCodeURL?.absoluteString ?? "Built in") → \(available.sourceCodeURL?.absoluteString ?? "Built in")."
        }
        if current.maturity != available.maturity {
            details += "\nMaturity: \(current.maturity.displayName) → \(available.maturity.displayName)."
        }
        if !additions.isEmpty {
            details += "\nNew domains:\n" + additions.map { "• \($0)" }.joined(separator: "\n")
        }
        return details + "\n\nContinuing approves the changed scope for this source."
    }
}

private struct ReaderExtensionSourceTechnicalDetailsView: View {
    let sourceID: ReaderExtensionSourceID
    let onDomainsApproved: () -> Void

    @StateObject private var manager = ReaderExtensionManager.shared
    @StateObject private var contentFilter = ReaderContentFilter.shared
    @State private var pendingDomainApproval: ReaderExtensionDomainConsentRequest?
    @State private var pendingMissingDomainApprovals: [String]?
    @State private var pendingMissingDomainApprovalProfileID: UUID?
    @State private var pendingSignInAfterDomainApproval = false
    @State private var signInSession: ReaderExtensionSignInSession?
    @State private var errorMessage: String?

    private var source: ReaderExtensionInstalledSource? {
        manager.source(for: sourceID)
    }

    var body: some View {
        Group {
            if contentFilter.isKidsProfileActive {
                restrictedView
            } else {
                unrestrictedBody
            }
        }
        .preferredColorScheme(.dark)
        .onChange(of: contentFilter.isKidsProfileActive) { isKids in
            guard isKids else { return }
            signInSession = nil
            if let request = pendingDomainApproval {
                ReaderExtensionDomainConsentCoordinator.shared.defer(request)
            }
            pendingDomainApproval = nil
            pendingMissingDomainApprovals = nil
            pendingMissingDomainApprovalProfileID = nil
            pendingSignInAfterDomainApproval = false
        }
    }

    private var restrictedView: some View {
        List {
            Section {
                Text("Reader extensions cannot be managed from a kids profile. Switch to a grown-up profile to continue.")
                    .foregroundColor(.secondary)
            }
            .eclipseExperimentalSettingsRows()
        }
        .navigationTitle("Technical Details")
        .navigationBarTitleDisplayMode(.inline)
        .eclipseSettingsStyle()
    }

    private var unrestrictedBody: some View {
        List {
            if let source {
                identitySection(source)
                securitySection(source)
            } else {
                Section {
                    Text(manager.blockedSourceIDs.contains(sourceID) ? "This source is blocked." : "This source is no longer installed.")
                        .foregroundColor(.secondary)
                }
                .eclipseExperimentalSettingsRows()
            }
        }
        .navigationTitle("Technical Details")
        .navigationBarTitleDisplayMode(.inline)
        .eclipseSettingsStyle()
        .sheet(item: Binding(
            get: { signInSession.map(ReaderExtensionSignInPresentation.init) },
            set: { if $0 == nil { signInSession = nil } }
        )) { presentation in
            ReaderExtensionSignInView(session: presentation.session)
        }
        .alert("Approve Domain", isPresented: Binding(
            get: { pendingDomainApproval != nil },
            set: { if !$0 { pendingDomainApproval = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                if let request = pendingDomainApproval {
                    ReaderExtensionDomainConsentCoordinator.shared.defer(request)
                }
                pendingDomainApproval = nil
                pendingSignInAfterDomainApproval = false
            }
            Button("Approve") {
                guard !ProfileManager.shared.isKidsModeActive else { return }
                guard let request = pendingDomainApproval else { return }
                pendingDomainApproval = nil
                do {
                    try manager.approve(request)
                    if pendingSignInAfterDomainApproval {
                        pendingSignInAfterDomainApproval = false
                        beginSignIn()
                    } else {
                        onDomainsApproved()
                    }
                } catch {
                    pendingSignInAfterDomainApproval = false
                    errorMessage = error.localizedDescription
                }
            }
        } message: {
            Text("Allow this reader source to contact \(pendingDomainApproval?.host ?? "this domain")? Approval applies only to this source, profile, and device. The source may send requests and matching authentication cookies to it.")
        }
        .confirmationDialog(
            "Approve Missing Declared Domains?",
            isPresented: Binding(
                get: { pendingMissingDomainApprovals != nil },
                set: {
                    if !$0 {
                        pendingMissingDomainApprovals = nil
                        pendingMissingDomainApprovalProfileID = nil
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Approve All Missing Domains") {
                approveMissingDeclaredDomains()
            }
            Button("Cancel", role: .cancel) {
                pendingMissingDomainApprovals = nil
                pendingMissingDomainApprovalProfileID = nil
            }
        } message: {
            Text(missingDomainApprovalMessage)
        }
        .alert("Reader Extensions", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func identitySection(_ source: ReaderExtensionInstalledSource) -> some View {
        Section("Installed Software") {
            ReaderExtensionMetadataRow(label: "Repository", value: source.repositoryURL.absoluteString)
            ReaderExtensionMetadataRow(label: "Source", value: source.sourceCodeURL?.absoluteString ?? source.baseURL.absoluteString)
            ReaderExtensionMetadataRow(label: "Version", value: source.version)
            ReaderExtensionMetadataRow(label: "Type", value: source.mediaType.displayName)
            ReaderExtensionMetadataRow(label: "Language", value: source.effectiveLanguage.uppercased())
            ReaderExtensionMetadataRow(label: "Implementation", value: source.implementation.displayName)
            ReaderExtensionMetadataRow(label: "Maturity", value: source.maturity.displayName)
            ReaderExtensionMetadataRow(label: "Installed", value: source.installedAt.formatted(date: .abbreviated, time: .shortened))
            ReaderExtensionMetadataRow(label: "Updated", value: source.updatedAt.formatted(date: .abbreviated, time: .shortened))
            ReaderExtensionMetadataRow(
                label: "SHA-256",
                value: source.activeContentDigest
                    ?? (source.implementation == .javascript ? "Unavailable — reinstall required" : "Built into Eclipse")
            )
        }
        .eclipseExperimentalSettingsRows()
    }

    private func securitySection(_ source: ReaderExtensionInstalledSource) -> some View {
        let declared = ReaderExtensionSecurityPolicy.canonicalHosts(source.declaredDomains)
        let approvedSet = ReaderExtensionSecurityPolicy.canonicalHosts(
            manager.approvedDomains(for: source.id)
        )
        let approved = approvedSet.sorted()
        let missing = declared.subtracting(approvedSet).sorted()
        return Section("Domains & Authentication") {
            ReaderExtensionMetadataRow(
                label: "Declared Domains",
                value: declared.isEmpty ? "None" : declared.sorted().joined(separator: ", ")
            )
            if !source.runtimeCapabilities.isEmpty {
                ReaderExtensionMetadataRow(
                    label: "Capabilities",
                    value: source.runtimeCapabilities.map(\.rawValue).sorted().joined(separator: ", ")
                )
            }
            if !source.secretPreferenceKeys.isEmpty {
                ReaderExtensionMetadataRow(
                    label: "Device-Only Secret Fields",
                    value: source.secretPreferenceKeys.sorted().joined(separator: ", ")
                )
            }
            if approved.isEmpty {
                Text("No domains approved")
                    .foregroundColor(.secondary)
            } else {
                ForEach(approved, id: \.self) { domain in
                    Label(domain, systemImage: "checkmark.shield")
                        .font(.subheadline)
                }
            }

            if !missing.isEmpty {
                Button {
                    pendingMissingDomainApprovals = missing
                    pendingMissingDomainApprovalProfileID = ProfileManager.shared.activeProfileID
                } label: {
                    Label("Review Missing Domain Approvals", systemImage: "shield.lefthalf.filled")
                }
                Text("This source is missing device-local approval for \(missing.count) declared domain\(missing.count == 1 ? "" : "s"). Review them to restore its network access for this profile and device.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Button {
                beginSignIn()
            } label: {
                Label("Sign In", systemImage: "key.fill")
            }
            Text("Sign-in pages run in an isolated browser. Eclipse routes their web requests through this source's approved-domain and private-network protections, stores matching server cookies only on this device, and does not share cookies between approved domains.")
                .font(.caption)
                .foregroundColor(.secondary)

            Button {
                openSourceWebsite(source.baseURL)
            } label: {
                Label("Open Website", systemImage: "safari")
            }
            Text(ReaderExtensionExternalBrowserBoundary.disclosure)
                .font(.caption)
                .foregroundColor(.secondary)

            Button(role: .destructive) {
                guard !ProfileManager.shared.isKidsModeActive else { return }
                do { try manager.clearAuthentication(for: source.id) }
                catch { errorMessage = error.localizedDescription }
            } label: {
                Label("Clear Authentication", systemImage: "lock.slash")
            }
        }
        .eclipseExperimentalSettingsRows()
    }

    private var missingDomainApprovalMessage: String {
        guard let domains = pendingMissingDomainApprovals, !domains.isEmpty else {
            return "Review the source's declared domains before approving access."
        }
        let sourceName = source?.name ?? "This reader source"
        let list = domains.map { "• \($0)" }.joined(separator: "\n")
        return "Allow \(sourceName) to contact all of these declared domains?\n\n\(list)\n\nApproval applies only to this source, profile, and device. The source may send requests and matching authentication cookies to these domains."
    }

    private func approveMissingDeclaredDomains() {
        guard !ProfileManager.shared.isKidsModeActive else {
            pendingMissingDomainApprovals = nil
            pendingMissingDomainApprovalProfileID = nil
            return
        }
        guard let requestedDomains = pendingMissingDomainApprovals,
              let ownerProfileID = pendingMissingDomainApprovalProfileID,
              let source else {
            pendingMissingDomainApprovals = nil
            pendingMissingDomainApprovalProfileID = nil
            return
        }
        pendingMissingDomainApprovals = nil
        pendingMissingDomainApprovalProfileID = nil
        guard ProfileManager.shared.isStillActive(ownerProfileID) else {
            errorMessage = "The active profile changed. Review the missing domains again before approving them."
            return
        }

        // Revalidate against the current installed record so an update cannot
        // cause the confirmation to approve a domain the source no longer declares.
        let declared = ReaderExtensionSecurityPolicy.canonicalHosts(source.declaredDomains)
        let approved = ReaderExtensionSecurityPolicy.canonicalHosts(
            manager.approvedDomains(for: source.id)
        )
        let stillMissing = Set(requestedDomains)
            .intersection(declared)
            .subtracting(approved)
            .sorted()
        do {
            for domain in stillMissing {
                try manager.approve(domain: domain, for: source.id)
            }
            onDomainsApproved()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openSourceWebsite(_ sourceURL: URL) {
        guard !ProfileManager.shared.isKidsModeActive else { return }
        guard let url = ReaderExtensionExternalBrowserBoundary.validatedURL(sourceURL) else {
            errorMessage = "This source does not provide a valid HTTP or HTTPS website."
            return
        }
        UIApplication.shared.open(url, options: [:]) { opened in
            guard !opened else { return }
            DispatchQueue.main.async {
                errorMessage = "The website could not be opened in your browser."
            }
        }
    }

    private func beginSignIn() {
        guard !ProfileManager.shared.isKidsModeActive else { return }
        guard let source else { return }
        guard source.baseURL.scheme?.lowercased() == "https",
              let host = ReaderExtensionSecurityPolicy.canonicalHost(of: source.baseURL) else {
            errorMessage = "Reader source sign-in requires a valid HTTPS website."
            return
        }
        guard manager.approvedDomains(for: source.id).contains(host) else {
            let request = manager.domainConsentRequest(domain: host, for: source.id)
            guard ReaderExtensionDomainConsentCoordinator.shared.claim(request) else {
                errorMessage = "This domain request is already being reviewed."
                return
            }
            pendingSignInAfterDomainApproval = true
            pendingDomainApproval = request
            return
        }
        do {
            signInSession = try manager.makeSignInSession(for: source.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ReaderExtensionPreferenceRow: View {
    let preference: ReaderExtensionPreference
    let value: ReaderExtensionPreferenceValue
    let save: (ReaderExtensionPreferenceValue) -> Void

    @State private var textValue = ""
    @State private var secretValue = ""

    var body: some View {
        switch preference.kind {
        case .header:
            VStack(alignment: .leading, spacing: 2) {
                Text(preference.title)
                    .font(.headline)
                if let summary = preference.summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        case .toggle:
            VStack(alignment: .leading, spacing: 3) {
                Toggle(preference.title, isOn: Binding(
                    get: { value.boolValue ?? false },
                    set: { save(.bool($0)) }
                ))
                preferenceSummary
            }
        case .select:
            if case .stringList(let selectedValues) = value {
                VStack(alignment: .leading, spacing: 6) {
                    Text(preference.title)
                        .font(.subheadline)
                    preferenceSummary
                    ForEach(preference.options) { option in
                        Toggle(option.label, isOn: Binding(
                            get: { selectedValues.contains(option.value) },
                            set: { isSelected in
                                var updated = Set(selectedValues)
                                if isSelected { updated.insert(option.value) }
                                else { updated.remove(option.value) }
                                save(.stringList(updated.sorted()))
                            }
                        ))
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Picker(preference.title, selection: Binding(
                        get: { value.stringValue ?? preference.options.first?.value ?? "" },
                        set: { save(.string($0)) }
                    )) {
                        ForEach(preference.options) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    preferenceSummary
                }
            }
        case .text:
            VStack(alignment: .leading, spacing: 4) {
                Text(preference.dialogTitle ?? preference.title)
                    .font(.subheadline)
                if let dialogMessage = preference.dialogMessage, !dialogMessage.isEmpty {
                    Text(dialogMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    preferenceSummary
                }
                TextField(preference.inputHint ?? preference.summary ?? "Value", text: $textValue)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { save(.string(textValue)) }
                Button("Save") { save(.string(textValue)) }
                    .font(.caption)
            }
            .onAppear { textValue = value.stringValue ?? "" }
            .onChange(of: value) { newValue in textValue = newValue.stringValue ?? "" }
        case .secret:
            VStack(alignment: .leading, spacing: 4) {
                Text(preference.title)
                    .font(.subheadline)
                SecureField(preference.summary ?? "Stored only on this device", text: $secretValue)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { saveSecret() }
                Button("Save Secret") { saveSecret() }
                    .font(.caption)
                    .disabled(secretValue.isEmpty)
            }
        }
    }

    @ViewBuilder
    private var preferenceSummary: some View {
        if let summary = preference.summary, !summary.isEmpty {
            Text(summary)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func saveSecret() {
        guard !secretValue.isEmpty else { return }
        save(.secretReference(secretValue))
        secretValue = ""
    }
}

private struct ReaderExtensionMetadataRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundColor(.white.opacity(0.55))
            Text(value)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.92))
                .textSelection(.enabled)
        }
    }
}

private struct ReaderExtensionSignInPresentation: Identifiable {
    let session: ReaderExtensionSignInSession
    var id: String { session.sourceID.rawValue }
}

/// WebKit sees only this application-owned scheme. Sign-in is HTTPS-only; the
/// original transport identity never needs an insecure proxy variant.
enum ReaderExtensionSignInURLProxy {
    static let secureScheme = "eclipse-reader-auth-secure"
    static let schemes: Set<String> = [secureScheme]
    static let maximumURLBytes = 16 * 1_024

    static let contentSecurityPolicy = [
        "default-src 'none'",
        "base-uri \(secureScheme):",
        "connect-src \(secureScheme):",
        "form-action \(secureScheme):",
        "navigate-to \(secureScheme): about:",
        "script-src 'unsafe-inline' \(secureScheme):",
        "style-src 'unsafe-inline' \(secureScheme):",
        "img-src data: blob: \(secureScheme):",
        "font-src data: \(secureScheme):",
        "media-src blob: \(secureScheme):",
        "frame-src \(secureScheme):",
        "worker-src 'none'",
        "object-src 'none'",
        "frame-ancestors \(secureScheme):"
    ].joined(separator: "; ")

    static func proxyURL(for originalURL: URL) throws -> URL {
        guard originalURL.absoluteString.utf8.count <= maximumURLBytes else {
            throw ReaderExtensionError.contentTooLarge
        }
        try ReaderExtensionSecurityPolicy.validatePublicURLSyntax(
            originalURL,
            requireHTTPS: true
        )
        guard var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false),
              originalURL.scheme?.lowercased() == "https" else {
            throw ReaderExtensionError.insecureURL
        }
        components.scheme = secureScheme
        guard let result = components.url else { throw ReaderExtensionError.insecureURL }
        return result
    }

    static func originalURL(
        from proxyURL: URL,
        approvedDomains: Set<String>
    ) throws -> URL {
        guard proxyURL.absoluteString.utf8.count <= maximumURLBytes else {
            throw ReaderExtensionError.contentTooLarge
        }
        guard var components = URLComponents(url: proxyURL, resolvingAgainstBaseURL: false),
              let proxyScheme = proxyURL.scheme?.lowercased(),
              schemes.contains(proxyScheme) else {
            throw ReaderExtensionError.insecureURL
        }
        components.scheme = "https"
        guard let original = components.url else { throw ReaderExtensionError.insecureURL }
        guard original.absoluteString.utf8.count <= maximumURLBytes else {
            throw ReaderExtensionError.contentTooLarge
        }
        try ReaderExtensionSecurityPolicy.validatePublicURLSyntax(
            original,
            requireHTTPS: true
        )
        try ReaderExtensionSecurityPolicy.validateApprovedDomain(
            original,
            approvedDomains: approvedDomains
        )
        return original
    }

    static func isProxyURL(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return schemes.contains(scheme)
    }
}

enum ReaderExtensionSignInContentRewriter {
    static let maximumMarkupInputBytes = 2 * 1_024 * 1_024
    static let maximumSVGInputBytes = 1 * 1_024 * 1_024
    static let maximumTransformedBytes = 4 * 1_024 * 1_024
    static let maximumRewriteCandidates = 20_000

    static func rewrittenBody(
        _ body: Data,
        contentType: String,
        finalURL: URL,
        visibleCookies: [String: String] = [:]
    ) throws -> Data {
        let lowerType = contentType.lowercased()
        let prefix = String(data: body.prefix(512), encoding: .utf8)?.lowercased() ?? ""
        if lowerType.contains("text/html") || lowerType.contains("application/xhtml")
            || prefix.contains("<html") || prefix.contains("<!doctype html") {
            guard body.count <= maximumMarkupInputBytes else {
                throw ReaderExtensionError.contentTooLarge
            }
            guard let html = String(data: body, encoding: .utf8) else {
                throw ReaderExtensionError.invalidScriptEncoding
            }
            let transformed = Data(try rewriteHTML(
                html,
                baseURL: finalURL,
                visibleCookies: visibleCookies
            ).utf8)
            guard transformed.count <= maximumTransformedBytes else {
                throw ReaderExtensionError.contentTooLarge
            }
            return transformed
        }
        if lowerType.contains("text/css") {
            guard body.count <= maximumMarkupInputBytes else {
                throw ReaderExtensionError.contentTooLarge
            }
            guard let css = String(data: body, encoding: .utf8) else {
                throw ReaderExtensionError.invalidScriptEncoding
            }
            let transformed = Data(try rewriteCSS(css, baseURL: finalURL).utf8)
            guard transformed.count <= maximumTransformedBytes else {
                throw ReaderExtensionError.contentTooLarge
            }
            return transformed
        }
        if lowerType.contains("image/svg+xml") {
            guard body.count <= maximumSVGInputBytes else {
                throw ReaderExtensionError.contentTooLarge
            }
            guard let markup = String(data: body, encoding: .utf8) else {
                throw ReaderExtensionError.invalidScriptEncoding
            }
            try validateRewriteComplexity(markup)
            let transformed = Data(try rewriteMarkupAttributes(markup, baseURL: finalURL).utf8)
            guard transformed.count <= maximumTransformedBytes else {
                throw ReaderExtensionError.contentTooLarge
            }
            return transformed
        }
        return body
    }

    static func rewriteHTML(
        _ rawHTML: String,
        baseURL: URL,
        visibleCookies: [String: String] = [:]
    ) throws -> String {
        guard rawHTML.utf8.count <= maximumMarkupInputBytes else {
            throw ReaderExtensionError.contentTooLarge
        }
        try validateRewriteComplexity(rawHTML)
        var html = rawHTML
        html = try replacingMatches(
            in: html,
            pattern: #"(?is)<meta\b[^>]*http-equiv\s*=\s*([\"'])?content-security-policy(?:-report-only)?\1?[^>]*>"#
        ) { _ in "" }
        html = try replacingMatches(in: html, pattern: #"(?is)<base\b[^>]*>"#) { _ in "" }
        html = try rewriteMarkupAttributes(html, baseURL: baseURL)
        html = try rewriteMetaRefresh(html, baseURL: baseURL)
        html = try replacingMatches(
            in: html,
            pattern: #"(?is)(\bstyle\s*=\s*)([\"'])(.*?)([\"'])"#
        ) { match in
            guard match.groups.count == 5, match.groups[2] == match.groups[4] else { return match.full }
            return try boundedConcatenation([
                match.groups[1],
                match.groups[2],
                try rewriteCSSUnchecked(match.groups[3], baseURL: baseURL),
                match.groups[4]
            ])
        }

        let proxiedBase = (try? ReaderExtensionSignInURLProxy.proxyURL(for: baseURL))?.absoluteString ?? ""
        let bootstrap = bootstrapScript(visibleCookies: visibleCookies)
        let injection = try boundedConcatenation([
            "<meta http-equiv=\"Content-Security-Policy\" content=\"",
            htmlEscaped(ReaderExtensionSignInURLProxy.contentSecurityPolicy),
            "\"><base href=\"",
            htmlEscaped(proxiedBase),
            "\"><script>",
            bootstrap,
            "</script>"
        ])
        // Prefix the policy and host shims before every byte supplied by the
        // remote document. A crafted script placed before its own <head> can
        // therefore never execute before the CSP and URL wrappers.
        return try boundedConcatenation(["<!doctype html><head>", injection, "</head>", html])
    }

    static func rewriteCSS(_ css: String, baseURL: URL) throws -> String {
        guard css.utf8.count <= maximumMarkupInputBytes else {
            throw ReaderExtensionError.contentTooLarge
        }
        try validateRewriteComplexity(css)
        return try rewriteCSSUnchecked(css, baseURL: baseURL)
    }

    private static func rewriteCSSUnchecked(_ css: String, baseURL: URL) throws -> String {
        var output = try replacingMatches(
            in: css,
            pattern: #"(?is)url\(\s*([\"']?)(.*?)\1\s*\)"#
        ) { match in
            guard match.groups.count >= 3,
                  let translated = translatedReference(match.groups[2], baseURL: baseURL) else {
                return match.full
            }
            let quote = match.groups[1].isEmpty ? "\"" : match.groups[1]
            return "url(\(quote)\(translated)\(quote))"
        }
        output = try replacingMatches(
            in: output,
            pattern: #"(?is)(@import\s+)([\"'])(.*?)([\"'])"#
        ) { match in
            guard match.groups.count == 5, match.groups[2] == match.groups[4],
                  let translated = translatedReference(match.groups[3], baseURL: baseURL) else {
                return match.full
            }
            return match.groups[1] + match.groups[2] + translated + match.groups[4]
        }
        return output
    }

    private static func rewriteMarkupAttributes(_ markup: String, baseURL: URL) throws -> String {
        var output = try replacingMatches(
            in: markup,
            pattern: #"(?is)(\b(?:src|href|action|formaction|poster|data|xlink:href)\s*=\s*)([\"'])(.*?)([\"'])"#
        ) { match in
            guard match.groups.count == 5, match.groups[2] == match.groups[4],
                  let translated = translatedReference(match.groups[3], baseURL: baseURL) else {
                return match.full
            }
            return match.groups[1] + match.groups[2] + translated + match.groups[4]
        }
        output = try replacingMatches(
            in: output,
            pattern: #"(?is)(\b(?:src|href|action|formaction|poster|data|xlink:href)\s*=\s*)([^\s\"'=<>`]+)"#
        ) { match in
            guard match.groups.count == 3,
                  let translated = translatedReference(match.groups[2], baseURL: baseURL) else {
                return match.full
            }
            return match.groups[1] + translated
        }
        output = try replacingMatches(
            in: output,
            pattern: #"(?is)(\bsrcset\s*=\s*)([\"'])(.*?)([\"'])"#
        ) { match in
            guard match.groups.count == 5, match.groups[2] == match.groups[4] else { return match.full }
            return try boundedConcatenation([
                match.groups[1],
                match.groups[2],
                try rewriteSrcsetValue(match.groups[3], baseURL: baseURL),
                match.groups[4]
            ])
        }
        return output
    }

    private static func rewriteSrcsetValue(_ value: String, baseURL: URL) throws -> String {
        let entries = value.split(separator: ",", omittingEmptySubsequences: false)
        guard entries.count <= maximumRewriteCandidates else {
            throw ReaderExtensionError.contentTooLarge
        }
        var output = ""
        var outputByteCount = 0
        for (index, entry) in entries.enumerated() {
            if index > 0 {
                try appendBounded(", ", to: &output, byteCount: &outputByteCount)
            }
            let components = entry.split(whereSeparator: \Character.isWhitespace)
            let transformed: String
            if let first = components.first,
               let translated = translatedReference(String(first), baseURL: baseURL) {
                transformed = ([translated] + components.dropFirst().map(String.init))
                    .joined(separator: " ")
            } else {
                transformed = String(entry)
            }
            try appendBounded(transformed, to: &output, byteCount: &outputByteCount)
        }
        return output
    }

    private static func rewriteMetaRefresh(_ html: String, baseURL: URL) throws -> String {
        try replacingMatches(
            in: html,
            pattern: #"(?is)(<meta\b[^>]*http-equiv\s*=\s*([\"'])?refresh\2?[^>]*content\s*=\s*)([\"'])(.*?)([\"'])"#
        ) { match in
            guard match.groups.count == 6, match.groups[3] == match.groups[5] else { return match.full }
            let content = try replacingMatches(
                in: match.groups[4],
                pattern: #"(?is)(\burl\s*=\s*)(.*)$"#
            ) { nested in
                guard nested.groups.count == 3,
                      let translated = translatedReference(
                        nested.groups[2].trimmingCharacters(in: CharacterSet(charactersIn: " \\\"'")),
                        baseURL: baseURL
                      ) else { return nested.full }
                return nested.groups[1] + translated
            }
            return try boundedConcatenation([
                match.groups[1], match.groups[3], content, match.groups[5]
            ])
        }
    }

    private static func translatedReference(_ raw: String, baseURL: URL) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        if let scheme = URL(string: trimmed)?.scheme?.lowercased() {
            if scheme == "http" { return "about:blank#blocked-insecure-reader-auth-load" }
            if scheme != "https" {
                if scheme == ReaderExtensionSignInURLProxy.secureScheme
                    || scheme == "data" || scheme == "blob" || scheme == "about" {
                    return nil
                }
                return "about:blank#blocked-reader-auth-scheme"
            }
        }
        guard let resolved = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL else {
            return "about:blank#blocked-reader-auth-url"
        }
        guard let proxied = try? ReaderExtensionSignInURLProxy.proxyURL(for: resolved) else {
            return "about:blank#blocked-reader-auth-target"
        }
        return proxied.absoluteString
    }

    private static func bootstrapScript(visibleCookies: [String: String]) -> String {
        let cookieData = (try? JSONSerialization.data(
            withJSONObject: visibleCookies,
            options: [.sortedKeys]
        )) ?? Data("{}".utf8)
        let cookieJSON = (String(data: cookieData, encoding: .utf8) ?? "{}")
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: ">", with: "\\u003e")
            .replacingOccurrences(of: "&", with: "\\u0026")
        return #"""
        (() => {
          'use strict';
          const secureScheme = '\#(ReaderExtensionSignInURLProxy.secureScheme):';
          const cookieJar = Object.assign(Object.create(null), \#(cookieJSON));
          const cookieWriteBudget = { count: 0, characters: 0 };
          const proxy = value => {
            try {
              const url = new URL(String(value), document.baseURI);
              if (url.protocol === 'https:') url.protocol = secureScheme;
              else if (url.protocol === 'http:') return 'about:blank#blocked-insecure-reader-auth-load';
              return url.href;
            } catch (_) { return String(value); }
          };
          Object.defineProperty(window, '__eclipseReaderAuthProxy', { value: proxy });
          Object.defineProperty(window, '__eclipseReplaceReaderCookies', {
            value: next => {
              for (const key of Object.keys(cookieJar)) delete cookieJar[key];
              if (next && typeof next === 'object') {
                for (const [key, value] of Object.entries(next)) cookieJar[String(key)] = String(value);
              }
            }
          });
          const cookieDescriptor = {
            configurable: false,
            get: () => Object.entries(cookieJar).map(([key, value]) => `${key}=${value}`).join('; '),
            set: value => {
              const raw = String(value).slice(0, 4096);
              cookieWriteBudget.count += 1;
              cookieWriteBudget.characters += raw.length;
              if (cookieWriteBudget.count > 128 || cookieWriteBudget.characters > 256 * 1024) return;
              const pair = raw.split(';', 1)[0];
              const split = pair.indexOf('=');
              if (split > 0) cookieJar[pair.slice(0, split).trim()] = pair.slice(split + 1).trim();
              try { window.webkit.messageHandlers.readerExtensionAuthCookie.postMessage({ cookie: raw }); } catch (_) {}
            }
          };
          let installedCookieShim = false;
          try {
            Object.defineProperty(Document.prototype, 'cookie', cookieDescriptor);
            installedCookieShim = true;
          } catch (_) {}
          if (!installedCookieShim) {
            try { Object.defineProperty(document, 'cookie', cookieDescriptor); } catch (_) {}
          }
          const nativeFetch = window.fetch && window.fetch.bind(window);
          if (nativeFetch) window.fetch = (input, init) => {
            if (input instanceof Request) return nativeFetch(new Request(proxy(input.url), input), init);
            return nativeFetch(proxy(input), init);
          };
          const nativeOpen = XMLHttpRequest.prototype.open;
          XMLHttpRequest.prototype.open = function(method, url, ...rest) {
            return nativeOpen.call(this, method, proxy(url), ...rest);
          };
          if (navigator.sendBeacon) {
            const nativeBeacon = navigator.sendBeacon.bind(navigator);
            navigator.sendBeacon = (url, data) => nativeBeacon(proxy(url), data);
          }
          const nativeSetAttribute = Element.prototype.setAttribute;
          const urlAttributes = new Set(['src', 'href', 'action', 'formaction', 'poster', 'data', 'xlink:href']);
          Element.prototype.setAttribute = function(name, value) {
            return nativeSetAttribute.call(this, name, urlAttributes.has(String(name).toLowerCase()) ? proxy(value) : value);
          };
          const rewriteNode = node => {
            if (!node || node.nodeType !== 1) return;
            for (const attribute of urlAttributes) if (node.hasAttribute(attribute)) nativeSetAttribute.call(node, attribute, proxy(node.getAttribute(attribute)));
            for (const child of node.querySelectorAll('[src],[href],[action],[formaction],[poster],[data]')) rewriteNode(child);
          };
          new MutationObserver(records => records.forEach(record => record.addedNodes.forEach(rewriteNode)))
            .observe(document.documentElement, { childList: true, subtree: true });
          const rewriteFormTarget = (form, submitter) => {
            if (form && form.action) form.action = proxy(form.action);
            if (submitter && submitter.formAction) submitter.formAction = proxy(submitter.formAction);
          };
          const nativeSubmit = HTMLFormElement.prototype.submit;
          HTMLFormElement.prototype.submit = function() { rewriteFormTarget(this, null); return nativeSubmit.call(this); };
          const nativeRequestSubmit = HTMLFormElement.prototype.requestSubmit;
          if (nativeRequestSubmit) HTMLFormElement.prototype.requestSubmit = function(submitter) {
            rewriteFormTarget(this, submitter);
            return nativeRequestSubmit.call(this, submitter);
          };
          document.addEventListener('submit', event => rewriteFormTarget(event.target, event.submitter), true);
          const nativeOpenWindow = window.open;
          window.open = (url, ...rest) => nativeOpenWindow.call(window, proxy(url), ...rest);
        })();
        """#
    }

    private struct Match {
        let full: String
        let groups: [String]
    }

    private static func replacingMatches(
        in input: String,
        pattern: String,
        transform: (Match) throws -> String
    ) throws -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            throw ReaderExtensionError.runtimeUnavailable
        }
        let nsInput = input as NSString
        let matches = expression.matches(
            in: input,
            range: NSRange(location: 0, length: nsInput.length)
        )
        var output = ""
        output.reserveCapacity(min(input.utf8.count, maximumTransformedBytes))
        var outputByteCount = 0
        var cursor = 0
        for result in matches {
            guard result.range.location >= cursor,
                  result.range.location <= nsInput.length,
                  result.range.length <= nsInput.length - result.range.location else {
                throw ReaderExtensionError.runtimeUnavailable
            }
            try appendBounded(
                nsInput.substring(with: NSRange(
                    location: cursor,
                    length: result.range.location - cursor
                )),
                to: &output,
                byteCount: &outputByteCount
            )
            var groups: [String] = []
            for index in 0..<result.numberOfRanges {
                let range = result.range(at: index)
                if range.location == NSNotFound { groups.append("") }
                else { groups.append(nsInput.substring(with: range)) }
            }
            try appendBounded(
                try transform(Match(full: groups.first ?? "", groups: groups)),
                to: &output,
                byteCount: &outputByteCount
            )
            cursor = result.range.location + result.range.length
        }
        try appendBounded(
            nsInput.substring(with: NSRange(location: cursor, length: nsInput.length - cursor)),
            to: &output,
            byteCount: &outputByteCount
        )
        return output
    }

    private static func boundedConcatenation(_ parts: [String]) throws -> String {
        var output = ""
        var outputByteCount = 0
        for part in parts {
            try appendBounded(part, to: &output, byteCount: &outputByteCount)
        }
        return output
    }

    private static func appendBounded(
        _ value: String,
        to output: inout String,
        byteCount: inout Int
    ) throws {
        let additionalBytes = value.utf8.count
        guard additionalBytes <= maximumTransformedBytes - byteCount else {
            throw ReaderExtensionError.contentTooLarge
        }
        output.append(value)
        byteCount += additionalBytes
    }

    private static func validateRewriteComplexity(_ input: String) throws {
        let pattern = #"(?is)(?:\b(?:src|href|action|formaction|poster|data|xlink:href|srcset|style)\s*=|url\s*\(|@import\b|<meta\b|<base\b)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            throw ReaderExtensionError.runtimeUnavailable
        }
        let length = (input as NSString).length
        var count = 0
        expression.enumerateMatches(
            in: input,
            range: NSRange(location: 0, length: length)
        ) { _, _, stop in
            count += 1
            if count > maximumRewriteCandidates { stop.pointee = true }
        }
        guard count <= maximumRewriteCandidates else {
            throw ReaderExtensionError.contentTooLarge
        }
    }

    private static func htmlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

enum ReaderExtensionCloudflareBrowserPolicy {
    static func allowsNavigation(
        to url: URL,
        session: ReaderExtensionSignInSession
    ) -> Bool {
        guard url.absoluteString.utf8.count <= ReaderExtensionSignInURLProxy.maximumURLBytes,
              let scheme = url.scheme?.lowercased() else {
            return false
        }
        if scheme == "about" || scheme == "blob" { return true }
        guard scheme == "https",
              url.user == nil,
              url.password == nil,
              (try? ReaderExtensionSecurityPolicy.validatePublicURLSyntax(
                url,
                requireHTTPS: true
              )) != nil,
              let host = ReaderExtensionSecurityPolicy.canonicalHost(of: url) else {
            return false
        }
        return session.networkDomains.contains(host)
    }

    static func isSourcePage(
        _ url: URL,
        session: ReaderExtensionSignInSession
    ) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = ReaderExtensionSecurityPolicy.canonicalHost(of: url) else {
            return false
        }
        return session.approvedDomains.contains(host)
    }

    static func sourceCookies(
        from cookies: [HTTPCookie],
        approvedDomains: Set<String>
    ) -> [HTTPCookie] {
        let approved = ReaderExtensionSecurityPolicy.canonicalHosts(approvedDomains)
        return cookies.filter { cookie in
            guard let domain = ReaderExtensionSecurityPolicy.canonicalHost(cookie.domain),
                  ReaderExtensionKeychainStore.validatedCookieIdentity(cookie) != nil else {
                return false
            }
            return approved.contains {
                ReaderExtensionSecurityPolicy.host(domain, isEqualToOrSubdomainOf: $0)
            }
        }
    }

    static func mergingSourceCookies(
        _ incoming: [HTTPCookie],
        existing: [HTTPCookie],
        approvedDomains: Set<String>
    ) -> [HTTPCookie]? {
        let accepted = sourceCookies(
            from: incoming,
            approvedDomains: approvedDomains
        )
        guard !accepted.isEmpty else { return nil }
        let identities = Set(accepted.compactMap(
            ReaderExtensionKeychainStore.validatedCookieIdentity
        ))
        return existing.filter {
            guard let identity = ReaderExtensionKeychainStore.validatedCookieIdentity($0) else {
                return false
            }
            return !identities.contains(identity)
        } + accepted
    }

    @MainActor
    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        return configuration
    }

    @MainActor
    static func install(
        _ cookies: [HTTPCookie],
        in store: WKHTTPCookieStore
    ) async {
        for cookie in cookies {
            await withCheckedContinuation { continuation in
                store.setCookie(cookie) {
                    continuation.resume()
                }
            }
        }
    }

    @MainActor
    static func cookies(in store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }
}

struct ReaderExtensionCloudflareVerificationView: View {
    let session: ReaderExtensionSignInSession
    let userAgent: String
    var onDismiss: (() -> Void)? = nil
    var onVerificationSolved: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08))
                }
                ReaderExtensionCloudflareVerificationWebView(
                    session: session,
                    userAgent: userAgent,
                    onVerificationSolved: {
                        if let onVerificationSolved { onVerificationSolved() }
                        else { dismiss() }
                    },
                    reportError: { errorMessage = $0 }
                )
            }
            .navigationTitle("Reader Verification")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if let onDismiss { onDismiss() }
                        else { dismiss() }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .interactiveDismissDisabled()
    }
}

@MainActor
struct ReaderExtensionCloudflareVerificationWebView: UIViewRepresentable {
    let session: ReaderExtensionSignInSession
    let userAgent: String
    let onVerificationSolved: () -> Void
    let reportError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            session: session,
            onVerificationSolved: onVerificationSolved,
            reportError: reportError
        )
    }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(
            frame: UIScreen.main.bounds,
            configuration: ReaderExtensionCloudflareBrowserPolicy.makeConfiguration()
        )
        webView.customUserAgent = userAgent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        context.coordinator.start(webView)
        return webView
    }

    func updateUIView(_: WKWebView, context _: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stop()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let session: ReaderExtensionSignInSession
        private let onVerificationSolved: () -> Void
        private let reportError: (String) -> Void
        private weak var webView: WKWebView?
        private var monitorTask: Task<Void, Never>?
        private var mainStatusCode = 0
        private var mainHeaders: [String: String] = [:]
        private var didComplete = false

        init(
            session: ReaderExtensionSignInSession,
            onVerificationSolved: @escaping () -> Void,
            reportError: @escaping (String) -> Void
        ) {
            self.session = session
            self.onVerificationSolved = onVerificationSolved
            self.reportError = reportError
        }

        func start(_ webView: WKWebView) {
            self.webView = webView
            monitorTask = Task { @MainActor [weak self, weak webView] in
                guard let self, let webView else { return }
                do {
                    try ReaderExtensionManager.shared.validateSignInSession(session)
                    let seedCookies = ReaderExtensionCloudflareBrowserPolicy.sourceCookies(
                        from: session.authenticationStore.cookies(),
                        approvedDomains: session.approvedDomains
                    )
                    await ReaderExtensionCloudflareBrowserPolicy.install(
                        seedCookies,
                        in: webView.configuration.websiteDataStore.httpCookieStore
                    )
                    try Task.checkCancellation()
                    try ReaderExtensionManager.shared.validateSignInSession(session)
                    webView.load(URLRequest(
                        url: session.startURL,
                        cachePolicy: .reloadIgnoringLocalCacheData,
                        timeoutInterval: 45
                    ))
                    while !Task.isCancelled, !didComplete {
                        try await Task.sleep(nanoseconds: 300_000_000)
                        if try await inspectSolvedState(in: webView) { return }
                    }
                } catch is CancellationError {
                } catch {
                    reportError(error.localizedDescription)
                }
            }
        }

        func stop() {
            monitorTask?.cancel()
            monitorTask = nil
            webView = nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url,
                  ReaderExtensionCloudflareBrowserPolicy.allowsNavigation(
                    to: url,
                    session: session
                  ) else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            guard let url = navigationResponse.response.url,
                  ReaderExtensionCloudflareBrowserPolicy.allowsNavigation(
                    to: url,
                    session: session
                  ) else {
                decisionHandler(.cancel)
                return
            }
            if navigationResponse.isForMainFrame,
               let response = navigationResponse.response as? HTTPURLResponse {
                mainStatusCode = response.statusCode
                mainHeaders = response.allHeaderFields.reduce(into: [:]) { output, pair in
                    output[String(describing: pair.key)] = String(describing: pair.value)
                }
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith _: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures _: WKWindowFeatures
        ) -> WKWebView? {
            guard let url = navigationAction.request.url,
                  ReaderExtensionCloudflareBrowserPolicy.allowsNavigation(
                    to: url,
                    session: session
                  ) else {
                return nil
            }
            webView.load(navigationAction.request)
            return nil
        }

        func webView(
            _: WKWebView,
            didFailProvisionalNavigation _: WKNavigation?,
            withError error: Error
        ) {
            guard (error as? URLError)?.code != .cancelled else { return }
            reportError(error.localizedDescription)
        }

        func webView(
            _: WKWebView,
            didFail _: WKNavigation?,
            withError error: Error
        ) {
            guard (error as? URLError)?.code != .cancelled else { return }
            reportError(error.localizedDescription)
        }

        private func inspectSolvedState(in webView: WKWebView) async throws -> Bool {
            guard !didComplete,
                  (200..<400).contains(mainStatusCode),
                  let currentURL = webView.url,
                  ReaderExtensionCloudflareBrowserPolicy.isSourcePage(
                    currentURL,
                    session: session
                  ) else {
                return false
            }
            let result = try await webView.evaluateJavaScript(
                "String(document.documentElement ? document.documentElement.outerHTML : '').slice(0, 65536)"
            )
            let html = result as? String ?? ""
            guard !ReaderExtensionChallengeDetector.isChallenge(
                status: mainStatusCode,
                headers: mainHeaders,
                body: Data(html.utf8)
            ) else {
                return false
            }
            let browserCookies = await ReaderExtensionCloudflareBrowserPolicy.cookies(
                in: webView.configuration.websiteDataStore.httpCookieStore
            )
            let sourceCookies = ReaderExtensionCloudflareBrowserPolicy.sourceCookies(
                from: browserCookies,
                approvedDomains: session.approvedDomains
            )
            guard ReaderExtensionBrowserChallengeSessionPolicy.hasUsableClearance(
                in: sourceCookies,
                for: session.startURL,
                approvedDomains: session.approvedDomains
            ) else {
                return false
            }
            try ReaderExtensionManager.shared.validateSignInSession(session)
            try session.authenticationStore.updateCookies { existing in
                ReaderExtensionCloudflareBrowserPolicy.mergingSourceCookies(
                    sourceCookies,
                    existing: existing,
                    approvedDomains: session.approvedDomains
                )
            }
            try ReaderExtensionManager.shared.validateSignInSession(session)
            didComplete = true
            onVerificationSolved()
            return true
        }
    }
}

@MainActor
final class ReaderExtensionCloudflareVerificationCoordinator {
    static let shared = ReaderExtensionCloudflareVerificationCoordinator()

    private struct FlowKey: Hashable {
        let namespace: String
        let sourceID: ReaderExtensionSourceID
        let host: String
    }

    private struct CompletedFlow {
        let serial: UInt64
        let result: Bool
    }

    private var activeKey: FlowKey?
    private var activeToken: UUID?
    private var activeContext: ReaderExtensionBrowserChallengeContext?
    private var activeWindow: UIWindow?
    private var activeContinuation: CheckedContinuation<Bool, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var completionSerial: UInt64 = 0
    private var completedFlows: [FlowKey: CompletedFlow] = [:]

    private init() {}

    func solve(_ context: ReaderExtensionBrowserChallengeContext) async -> Bool {
        guard let host = ReaderExtensionSecurityPolicy.canonicalHost(of: context.challengedURL) else {
            return false
        }
        let key = FlowKey(
            namespace: context.authenticationAdmission.namespace,
            sourceID: context.sourceID,
            host: host
        )
        let observedCompletion = completedFlows[key]?.serial ?? 0
        var joinedMatchingFlow = false
        while activeKey != nil {
            if Task.isCancelled { return false }
            if activeKey == key { joinedMatchingFlow = true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if joinedMatchingFlow,
           let completed = completedFlows[key],
           completed.serial > observedCompletion {
            return completed.result
        }
        if Task.isCancelled { return false }

        let session: ReaderExtensionSignInSession
        do {
            try context.authenticationAdmission.validate()
            session = try ReaderExtensionManager.shared.makeBrowserVerificationSession(
                for: context.sourceID,
                challengedURL: context.challengedURL
            )
            guard session.approvedDomains == context.approvedDomains,
                  session.mutationScope.authenticationNamespace
                    == context.authenticationAdmission.namespace,
                  ReaderExtensionAuthenticationGenerationRegistry.isCurrent(
                    context.authenticationAdmission.generation,
                    sourceID: context.sourceID,
                    namespace: context.authenticationAdmission.namespace
                  ) else {
                return false
            }
        } catch {
            return false
        }

        let token = UUID()
        activeKey = key
        activeToken = token
        activeContext = context
        ReaderLogger.shared.log(
            "ReaderCloudflare: started source=\(context.sourceID.rawValue.prefix(12)) host=\(host)",
            type: "ReaderExtensionNetwork"
        )
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                activeContinuation = continuation
                present(
                    session: session,
                    userAgent: context.userAgent,
                    token: token
                )
            }
        }, onCancel: {
            Task { @MainActor in
                ReaderExtensionCloudflareVerificationCoordinator.shared.complete(
                    token: token,
                    result: false
                )
            }
        })
    }

    private func present(
        session: ReaderExtensionSignInSession,
        userAgent: String,
        token: UUID
    ) {
        guard let scene = readerExtensionVerificationScene() else {
            complete(token: token, result: false)
            return
        }
        let root = ReaderExtensionCloudflareVerificationView(
            session: session,
            userAgent: userAgent,
            onDismiss: { [weak self] in
                self?.complete(token: token, result: false)
            },
            onVerificationSolved: { [weak self] in
                self?.complete(token: token, result: true)
            }
        )
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = UIColor.systemBackground
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = host
        window.makeKeyAndVisible()
        activeWindow = window
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 45_000_000_000)
            guard !Task.isCancelled else { return }
            self?.complete(token: token, result: false)
        }
    }

    private func complete(token: UUID, result: Bool) {
        guard activeToken == token else { return }
        var finalResult = result
        if result, let context = activeContext {
            do {
                try context.authenticationAdmission.validate()
                finalResult = ReaderExtensionBrowserChallengeSessionPolicy.hasUsableClearance(
                    in: context.authenticationStore.cookies(),
                    for: context.challengedURL,
                    approvedDomains: context.approvedDomains
                )
            } catch {
                finalResult = false
            }
        }
        let key = activeKey
        let continuation = activeContinuation
        timeoutTask?.cancel()
        timeoutTask = nil
        activeWindow?.isHidden = true
        activeWindow = nil
        activeContinuation = nil
        activeContext = nil
        activeToken = nil
        activeKey = nil
        if let key {
            completionSerial &+= 1
            completedFlows[key] = CompletedFlow(
                serial: completionSerial,
                result: finalResult
            )
            if completedFlows.count > 128,
               let oldest = completedFlows.min(by: { $0.value.serial < $1.value.serial })?.key {
                completedFlows.removeValue(forKey: oldest)
            }
            ReaderLogger.shared.log(
                "ReaderCloudflare: finished source=\(key.sourceID.rawValue.prefix(12)) host=\(key.host) solved=\(finalResult)",
                type: "ReaderExtensionNetwork"
            )
        }
        continuation?.resume(returning: finalResult)
    }
}

@MainActor
private func readerExtensionVerificationScene() -> UIWindowScene? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    return scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.windowScene
        ?? scenes.first(where: { $0.activationState == .foregroundActive })
        ?? scenes.first
}

struct ReaderExtensionSignInView: View {
    let session: ReaderExtensionSignInSession
    var title: String?
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08))
                }
                ReaderExtensionSignInWebView(
                    session: session,
                    reportError: { errorMessage = $0 }
                )
            }
            .navigationTitle(title ?? "Sign In to \(session.sourceName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

struct ReaderExtensionSignInWebView: UIViewRepresentable {
    let session: ReaderExtensionSignInSession
    let reportError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, reportError: reportError)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(context.coordinator.schemeHandler, forURLScheme: ReaderExtensionSignInURLProxy.secureScheme)
        configuration.userContentController.add(
            context.coordinator,
            name: Coordinator.cookieMessageName
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.attach(webView)
        do {
            webView.load(URLRequest(url: try ReaderExtensionSignInURLProxy.proxyURL(for: session.startURL)))
        } catch {
            reportError(error.localizedDescription)
        }
        return webView
    }

    func updateUIView(_: WKWebView, context _: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.cookieMessageName)
        coordinator.detach()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        static let cookieMessageName = "readerExtensionAuthCookie"
        let schemeHandler: ReaderExtensionSignInSchemeHandler
        private let session: ReaderExtensionSignInSession
        private let reportError: (String) -> Void
        private weak var webView: WKWebView?
        private var cookieMessageCount = 0
        private var cookieMessageBytes = 0
        private var cookieBridgeDisabled = false

        init(
            session: ReaderExtensionSignInSession,
            reportError: @escaping (String) -> Void
        ) {
            self.session = session
            self.reportError = reportError
            schemeHandler = ReaderExtensionSignInSchemeHandler(session: session)
            super.init()
            schemeHandler.onError = { [weak self] message in
                DispatchQueue.main.async { self?.reportError(message) }
            }
        }

        func attach(_ webView: WKWebView) { self.webView = webView }
        func detach() {
            schemeHandler.cancelAll()
            webView = nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if ReaderExtensionSignInURLProxy.isProxyURL(url) || url.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            // A missed dynamic top-level rewrite is translated here. Direct
            // subframe and resource loads remain cancelled rather than being
            // promoted into a main-frame navigation.
            if navigationAction.targetFrame?.isMainFrame != false,
               let proxied = try? ReaderExtensionSignInURLProxy.proxyURL(for: url) {
                webView.load(URLRequest(url: proxied))
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith _: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures _: WKWindowFeatures
        ) -> WKWebView? {
            guard let url = navigationAction.request.url else { return nil }
            let proxied = ReaderExtensionSignInURLProxy.isProxyURL(url)
                ? url
                : try? ReaderExtensionSignInURLProxy.proxyURL(for: url)
            if let proxied { webView.load(URLRequest(url: proxied)) }
            return nil
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.cookieMessageName else { return }
            cookieMessageCount += 1
            let candidateBytes = ((message.body as? [String: Any])?["cookie"] as? String)?.utf8.count ?? 0
            guard !cookieBridgeDisabled,
                  cookieMessageCount <= 128,
                  candidateBytes <= ReaderExtensionSignInCookieBridge.maximumCookieStringBytes,
                  candidateBytes <= 256 * 1_024 - cookieMessageBytes else {
                cookieBridgeDisabled = true
                controller.removeScriptMessageHandler(forName: Self.cookieMessageName)
                schemeHandler.cancelAll()
                webView?.stopLoading()
                reportError("The sign-in page exceeded its cookie-write limit.")
                return
            }
            cookieMessageBytes += candidateBytes
            guard
                  let body = message.body as? [String: Any],
                  let proxyURL = message.frameInfo.request.url,
                  ReaderExtensionSignInURLProxy.isProxyURL(proxyURL),
                  let cookie = body["cookie"] as? String else { return }
            do {
                try ReaderExtensionSignInCookieBridge.persist(
                    cookieString: cookie,
                    proxyURL: proxyURL,
                    session: session
                )
                replaceVisibleCookies(ReaderExtensionSignInCookieBridge.visibleCookies(
                    for: try ReaderExtensionSignInURLProxy.originalURL(
                        from: proxyURL,
                        approvedDomains: session.approvedDomains
                    ),
                    session: session
                ), in: message.frameInfo)
            } catch {
                reportError(error.localizedDescription)
            }
        }

        private func replaceVisibleCookies(_ cookies: [String: String], in frame: WKFrameInfo) {
            Task { @MainActor [weak self] in
                _ = try? await self?.webView?.callAsyncJavaScript(
                    "window.__eclipseReplaceReaderCookies && window.__eclipseReplaceReaderCookies(cookies);",
                    arguments: ["cookies": cookies],
                    in: frame,
                    contentWorld: .page
                )
            }
        }
    }
}

enum ReaderExtensionSignInCookieBridge {
    static let maximumCookieStringBytes = 4 * 1_024

    static func visibleCookies(
        for url: URL,
        session: ReaderExtensionSignInSession
    ) -> [String: String] {
        session.authenticationStore.cookies().filter {
            !$0.isHTTPOnly && ReaderExtensionSecurityPolicy.cookie(
                $0,
                mayBeSentTo: url,
                approvedDomains: session.approvedDomains
            )
        }.reduce(into: [:]) { $0[$1.name] = $1.value }
    }

    @MainActor
    static func persist(
        cookieString: String,
        proxyURL: URL,
        session: ReaderExtensionSignInSession
    ) throws {
        try ReaderExtensionManager.shared.validateSignInSession(session)
        let originalURL = try ReaderExtensionSignInURLProxy.originalURL(
            from: proxyURL,
            approvedDomains: session.approvedDomains
        )
        try session.authenticationStore.updateCookies { existing in
            try cookiesByMergingScriptWrite(
                cookieString,
                originalURL: originalURL,
                approvedDomains: session.approvedDomains,
                existing: existing
            )
        }
    }

    static func cookiesByMergingScriptWrite(
        _ cookieString: String,
        originalURL: URL,
        approvedDomains: Set<String>,
        existing: [HTTPCookie]
    ) throws -> [HTTPCookie] {
        guard cookieString.utf8.count <= maximumCookieStringBytes,
              !cookieString.contains("\r"), !cookieString.contains("\n") else {
            throw ReaderExtensionError.contentTooLarge
        }
        try ReaderExtensionSecurityPolicy.validatePublicURLSyntax(originalURL)
        try ReaderExtensionSecurityPolicy.validateApprovedDomain(
            originalURL,
            approvedDomains: approvedDomains
        )
        let incoming = HTTPCookie.cookies(
            withResponseHeaderFields: ["Set-Cookie": cookieString],
            for: originalURL
        ).filter { cookie in
            !cookie.isHTTPOnly
                && ReaderExtensionSecurityPolicy.cookie(
                    cookie,
                    mayBeSentTo: originalURL,
                    approvedDomains: approvedDomains,
                    now: .distantPast
                )
                && ReaderExtensionKeychainStore.validatedCookieIdentity(cookie) != nil
        }
        guard !incoming.isEmpty else { throw ReaderExtensionError.insecureURL }
        let identities = Set(incoming.compactMap(
            ReaderExtensionKeychainStore.validatedCookieIdentity
        ))
        return existing.filter {
            guard let identity = ReaderExtensionKeychainStore.validatedCookieIdentity($0) else {
                return false
            }
            return !identities.contains(identity)
        } + incoming
    }
}

enum ReaderExtensionSignInRequestTranslator {
    static func networkRequest(
        from request: URLRequest,
        sourceID: ReaderExtensionSourceID,
        approvedDomains: Set<String>,
        baseDomain: String?,
        isExplicitInitialTopLevelNavigation: Bool = false
    ) throws -> ReaderExtensionNetworkRequest {
        guard let proxyURL = request.url else { throw ReaderExtensionError.insecureURL }
        let originalURL = try ReaderExtensionSignInURLProxy.originalURL(
            from: proxyURL,
            approvedDomains: approvedDomains
        )
        guard let method = ReaderExtensionNetworkRequest.Method(
            rawValue: (request.httpMethod ?? "GET").uppercased()
        ) else { throw ReaderExtensionError.insecureURL }
        let translatedHeaders = translatedBrowserHeaders(
            request.allHTTPHeaderFields ?? [:],
            approvedDomains: approvedDomains
        )
        let targetHost = ReaderExtensionSecurityPolicy.canonicalHost(of: originalURL)
        let initialHost = ReaderExtensionSecurityPolicy.canonicalHost(baseDomain)
        // Origin/Referer can legitimately be absent, but that absence is not
        // proof of same-origin initiation. Only the one exact top-level load
        // created by Eclipse may use the session host as its initiator. Every
        // other request fails closed instead of gaining ambient cookies.
        let explicitInitialHost = isExplicitInitialTopLevelNavigation
            && initialHost == targetHost ? targetHost : nil
        let initiatorHost = translatedHeaders.initiatorHost ?? explicitInitialHost
        let admitsSameOriginCookies = initiatorHost != nil && initiatorHost == targetHost
        return ReaderExtensionNetworkRequest(
            method: method,
            url: originalURL,
            headers: translatedHeaders.headers,
            body: try boundedBody(from: request),
            sourceID: sourceID,
            approvedDomains: approvedDomains,
            baseDomain: initiatorHost,
            allowsCookies: admitsSameOriginCookies,
            cookieAccessPolicy: .sameOriginHostOnly,
            maximumResponseBytes: ReaderExtensionSecurityPolicy.maximumResponseBytes
        )
    }

    private static func translatedBrowserHeaders(
        _ input: [String: String],
        approvedDomains: Set<String>
    ) -> (headers: [String: String], initiatorHost: String?) {
        var output = input
        var initiatorHost: String?
        for (name, value) in input {
            switch name.lowercased() {
            case "accept-encoding":
                // The pinned HTTP/1.1 transport intentionally does not expose
                // a general decompressor to untrusted sign-in pages.
                output.removeValue(forKey: name)
            case "origin":
                output.removeValue(forKey: name)
                guard value.lowercased() != "null",
                      let proxyURL = URL(string: value),
                      let original = try? ReaderExtensionSignInURLProxy.originalURL(
                        from: proxyURL,
                        approvedDomains: approvedDomains
                      ),
                      let host = ReaderExtensionSecurityPolicy.canonicalHost(of: original) else { continue }
                initiatorHost = host
                var components = URLComponents()
                components.scheme = "https"
                components.host = host
                components.port = original.port
                output[name] = components.string ?? "https://\(host)"
            case "referer":
                output.removeValue(forKey: name)
                guard let proxyURL = URL(string: value),
                      let original = try? ReaderExtensionSignInURLProxy.originalURL(
                        from: proxyURL,
                        approvedDomains: approvedDomains
                      ),
                      let host = ReaderExtensionSecurityPolicy.canonicalHost(of: original) else { continue }
                if initiatorHost == nil { initiatorHost = host }
                output[name] = original.absoluteString
            default:
                break
            }
        }
        output["Accept-Encoding"] = "identity"
        return (output, initiatorHost)
    }

    private static func boundedBody(from request: URLRequest) throws -> Data? {
        if let body = request.httpBody {
            guard body.count <= ReaderExtensionSecurityPolicy.maximumRequestBodyBytes else {
                throw ReaderExtensionError.contentTooLarge
            }
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? ReaderExtensionError.insecureURL }
            if count == 0 { break }
            guard result.count <= ReaderExtensionSecurityPolicy.maximumRequestBodyBytes - count else {
                throw ReaderExtensionError.contentTooLarge
            }
            result.append(buffer, count: count)
        }
        return result
    }
}

enum ReaderExtensionSignInResponseHeaderPolicy {
    static func sanitizedHeaders(
        _ headers: [String: String],
        bodyCount: Int,
        approvedDomains: Set<String>
    ) -> [String: String] {
        let removed: Set<String> = [
            "content-encoding", "content-length", "content-security-policy",
            "content-security-policy-report-only", "location", "set-cookie",
            "transfer-encoding", "x-frame-options", "refresh", "link",
            "report-to", "nel"
        ]
        var output = headers.filter { !removed.contains($0.key.lowercased()) }
        for (name, value) in headers where name.caseInsensitiveCompare("Content-Type") == .orderedSame {
            let mime = value.split(separator: ";", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            if mime == "text/html" || mime == "application/xhtml+xml"
                || mime == "text/css" || mime == "image/svg+xml" {
                let deliveredMIME = mime == "application/xhtml+xml" ? "text/html" : mime
                output[name] = "\(deliveredMIME); charset=utf-8"
            }
        }
        for (name, value) in headers where name.caseInsensitiveCompare("Access-Control-Allow-Origin") == .orderedSame {
            output.removeValue(forKey: name)
            if value == "*" {
                output[name] = value
                continue
            }
            guard let originURL = URL(string: value),
                  originURL.scheme?.lowercased() == "https",
                  originURL.user == nil,
                  originURL.password == nil,
                  originURL.query == nil,
                  originURL.fragment == nil,
                  originURL.path.isEmpty || originURL.path == "/",
                  (try? ReaderExtensionSecurityPolicy.validateApprovedDomain(
                    originURL,
                    approvedDomains: approvedDomains
                  )) != nil,
                  let proxied = try? ReaderExtensionSignInURLProxy.proxyURL(for: originURL),
                  let host = proxied.host else { continue }
            var components = URLComponents()
            components.scheme = ReaderExtensionSignInURLProxy.secureScheme
            components.host = host
            components.port = originURL.port
            output[name] = components.string
        }
        output["Content-Length"] = String(bodyCount)
        output["Content-Security-Policy"] = ReaderExtensionSignInURLProxy.contentSecurityPolicy
        output["Referrer-Policy"] = "no-referrer"
        output["Permissions-Policy"] = "camera=(), microphone=(), geolocation=(), payment=(), usb=()"
        output["X-Content-Type-Options"] = "nosniff"
        return output
    }
}

enum ReaderExtensionSignInResourceLimitError: LocalizedError, Equatable {
    case stopped
    case totalRequests
    case queuedRequests
    case requestBytes
    case responseBytes

    var errorDescription: String? {
        switch self {
        case .stopped: return "The isolated sign-in session has ended."
        case .totalRequests: return "The sign-in page exceeded its request limit."
        case .queuedRequests: return "The sign-in page opened too many simultaneous requests."
        case .requestBytes: return "The sign-in page exceeded its request-data limit."
        case .responseBytes: return "The sign-in page exceeded its response-data limit."
        }
    }
}

final class ReaderExtensionSignInResourceBudget: @unchecked Sendable {
    let maximumTotalRequests: Int
    let maximumRequestBytes: Int
    let maximumResponseBytes: Int

    private let lock = NSLock()
    private var totalRequests = 0
    private var requestBytes = 0
    private var responseBytes = 0
    private(set) var isStopped = false

    init(
        maximumTotalRequests: Int = 512,
        maximumRequestBytes: Int = 8 * 1_024 * 1_024,
        maximumResponseBytes: Int = 64 * 1_024 * 1_024
    ) {
        self.maximumTotalRequests = max(1, maximumTotalRequests)
        self.maximumRequestBytes = max(0, maximumRequestBytes)
        self.maximumResponseBytes = max(0, maximumResponseBytes)
    }

    func reserveRequest() throws {
        try lock.withReaderExtensionSignInLock {
            guard !isStopped else { throw ReaderExtensionSignInResourceLimitError.stopped }
            guard totalRequests < maximumTotalRequests else {
                isStopped = true
                throw ReaderExtensionSignInResourceLimitError.totalRequests
            }
            totalRequests += 1
        }
    }

    func recordRequestBytes(_ count: Int) throws {
        try lock.withReaderExtensionSignInLock {
            guard !isStopped else { throw ReaderExtensionSignInResourceLimitError.stopped }
            guard count >= 0, count <= maximumRequestBytes - requestBytes else {
                isStopped = true
                throw ReaderExtensionSignInResourceLimitError.requestBytes
            }
            requestBytes += count
        }
    }

    func recordResponseBytes(_ count: Int) throws {
        try lock.withReaderExtensionSignInLock {
            guard !isStopped else { throw ReaderExtensionSignInResourceLimitError.stopped }
            guard count >= 0, count <= maximumResponseBytes - responseBytes else {
                isStopped = true
                throw ReaderExtensionSignInResourceLimitError.responseBytes
            }
            responseBytes += count
        }
    }

    func stop() {
        lock.withReaderExtensionSignInLock { isStopped = true }
    }

}

private actor ReaderExtensionSignInConcurrencyGate {
    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var didRelease = false
        private let releaseAction: @Sendable () -> Void

        init(releaseAction: @escaping @Sendable () -> Void) {
            self.releaseAction = releaseAction
        }

        func release() {
            let shouldRelease = lock.withReaderExtensionSignInLock { () -> Bool in
                guard !didRelease else { return false }
                didRelease = true
                return true
            }
            if shouldRelease { releaseAction() }
        }

        deinit { release() }
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Lease, Error>
    }

    private let maximumConcurrentRequests: Int
    private var activeRequests = 0
    private var waiters: [Waiter] = []
    private var isStopped = false

    init(maximumConcurrentRequests: Int = 6) {
        self.maximumConcurrentRequests = max(1, maximumConcurrentRequests)
    }

    func acquire() async throws -> Lease {
        try Task.checkCancellation()
        guard !isStopped else { throw ReaderExtensionSignInResourceLimitError.stopped }
        if activeRequests < maximumConcurrentRequests {
            activeRequests += 1
            return makeLease()
        }
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        }, onCancel: {
            Task { await self.cancelWaiter(id) }
        })
    }

    func stop() {
        isStopped = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.continuation.resume(throwing: ReaderExtensionSignInResourceLimitError.stopped) }
    }

    private func makeLease() -> Lease {
        Lease { [weak self] in
            guard let self else { return }
            Task { await self.releasePermit() }
        }
    }

    private func releasePermit() {
        if !waiters.isEmpty, !isStopped {
            let next = waiters.removeFirst()
            next.continuation.resume(returning: makeLease())
        } else {
            activeRequests = max(0, activeRequests - 1)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

private extension NSLock {
    func withReaderExtensionSignInLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}

final class ReaderExtensionSignInSchemeHandler: NSObject, WKURLSchemeHandler, @unchecked Sendable {
    var onError: ((String) -> Void)?

    private let session: ReaderExtensionSignInSession
    private let initialProxyURL: URL?
    private let resourceBudget: ReaderExtensionSignInResourceBudget
    private let concurrencyGate = ReaderExtensionSignInConcurrencyGate()
    private let lock = NSLock()
    private static let maximumRetainedTasks = 32
    private final class ActiveRequest {
        let isExplicitInitialTopLevelNavigation: Bool
        var task: Task<Void, Never>?
        var wasStopped = false

        init(isExplicitInitialTopLevelNavigation: Bool) {
            self.isExplicitInitialTopLevelNavigation = isExplicitInitialTopLevelNavigation
        }
    }
    private var tasks: [ObjectIdentifier: ActiveRequest] = [:]
    private var didClaimInitialTopLevelNavigation = false

    init(
        session: ReaderExtensionSignInSession,
        resourceBudget: ReaderExtensionSignInResourceBudget = ReaderExtensionSignInResourceBudget()
    ) {
        self.session = session
        initialProxyURL = try? ReaderExtensionSignInURLProxy.proxyURL(for: session.startURL)
        self.resourceBudget = resourceBudget
    }

    func webView(_: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
        do {
            try resourceBudget.reserveRequest()
        } catch {
            urlSchemeTask.didFailWithError(error)
            stopSession(after: error)
            return
        }
        lock.lock()
        let isExplicitInitialTopLevelNavigation = !didClaimInitialTopLevelNavigation
            && Self.matchesInitialTopLevelRequest(urlSchemeTask.request, expectedURL: initialProxyURL)
        if isExplicitInitialTopLevelNavigation {
            didClaimInitialTopLevelNavigation = true
        }
        let activeRequest = ActiveRequest(
            isExplicitInitialTopLevelNavigation: isExplicitInitialTopLevelNavigation
        )
        guard tasks.count < Self.maximumRetainedTasks else {
            lock.unlock()
            let error = ReaderExtensionSignInResourceLimitError.queuedRequests
            urlSchemeTask.didFailWithError(error)
            stopSession(after: error)
            return
        }
        tasks[identifier] = activeRequest
        lock.unlock()
        let task = Task { [weak self, weak urlSchemeTask] in
            guard let self, let urlSchemeTask else { return }
            do {
                let permit = try await concurrencyGate.acquire()
                defer { permit.release() }
                let request = try await makeNetworkRequest(
                    from: urlSchemeTask.request,
                    isExplicitInitialTopLevelNavigation: activeRequest.isExplicitInitialTopLevelNavigation
                )
                try resourceBudget.recordRequestBytes(request.body?.count ?? 0)
                let response = try await session.network.request(request)
                try resourceBudget.recordResponseBytes(response.body.count)
                try await MainActor.run {
                    try ReaderExtensionManager.shared.validateSignInSession(self.session)
                }
                let contentType = response.headers.first {
                    $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
                }?.value ?? "application/octet-stream"
                let disposition = response.headers.first {
                    $0.key.caseInsensitiveCompare("Content-Disposition") == .orderedSame
                }?.value.lowercased() ?? ""
                guard !disposition.contains("attachment") else {
                    throw ReaderExtensionError.unsupportedArchive
                }
                let visibleCookies = ReaderExtensionCookieAdmissionPolicy.allowsCookies(
                    for: response.finalURL,
                    request: request
                ) ? ReaderExtensionSignInCookieBridge.visibleCookies(
                    for: response.finalURL,
                    session: session
                ) : [:]
                let body = try ReaderExtensionSignInContentRewriter.rewrittenBody(
                    response.body,
                    contentType: contentType,
                    finalURL: response.finalURL,
                    visibleCookies: visibleCookies
                )
                // Count both received and post-rewrite bytes so a sequence of
                // expansion-heavy documents cannot hide behind the wire-size
                // budget.
                try resourceBudget.recordResponseBytes(body.count)
                let responseURL = try ReaderExtensionSignInURLProxy.proxyURL(for: response.finalURL)
                let headers = ReaderExtensionSignInResponseHeaderPolicy.sanitizedHeaders(
                    response.headers,
                    bodyCount: body.count,
                    approvedDomains: session.approvedDomains
                )
                guard let http = HTTPURLResponse(
                    url: responseURL,
                    statusCode: response.statusCode,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                ) else { throw ReaderExtensionError.insecureURL }
                guard finishIfActive(identifier, action: {
                    urlSchemeTask.didReceive(http)
                    urlSchemeTask.didReceive(body)
                    urlSchemeTask.didFinish()
                }) else { return }
            } catch is CancellationError {
                _ = finishIfActive(identifier) {}
            } catch {
                guard finishIfActive(identifier, action: {
                    urlSchemeTask.didFailWithError(error)
                }) else { return }
                onError?(error.localizedDescription)
                if isSessionStoppingSafetyLimit(error) {
                    stopSession(after: error)
                }
            }
        }
        lock.lock()
        activeRequest.task = task
        if activeRequest.wasStopped { task.cancel() }
        lock.unlock()
    }

    func webView(_: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let identifier = ObjectIdentifier(urlSchemeTask as AnyObject)
        lock.lock()
        let activeRequest = tasks.removeValue(forKey: identifier)
        activeRequest?.wasStopped = true
        let task = activeRequest?.task
        lock.unlock()
        task?.cancel()
    }

    private func isSessionStoppingSafetyLimit(_ error: Error) -> Bool {
        if error is ReaderExtensionSignInResourceLimitError {
            return true
        }
        guard let readerError = error as? ReaderExtensionError else {
            return false
        }
        if case .contentTooLarge = readerError {
            return true
        }
        return false
    }

    func cancelAll() {
        resourceBudget.stop()
        Task { await concurrencyGate.stop() }
        lock.lock()
        let active = Array(tasks.values)
        tasks.removeAll()
        active.forEach { $0.wasStopped = true }
        lock.unlock()
        active.forEach { $0.task?.cancel() }
    }

    private func stopSession(after error: Error) {
        resourceBudget.stop()
        Task { await concurrencyGate.stop() }
        lock.lock()
        let active = Array(tasks.values)
        tasks.removeAll()
        active.forEach { $0.wasStopped = true }
        lock.unlock()
        active.forEach { $0.task?.cancel() }
        onError?(error.localizedDescription)
    }

    func makeNetworkRequest(
        from request: URLRequest,
        isExplicitInitialTopLevelNavigation: Bool = false
    ) async throws -> ReaderExtensionNetworkRequest {
        try await MainActor.run {
            try ReaderExtensionManager.shared.validateSignInSession(session)
        }
        return try ReaderExtensionSignInRequestTranslator.networkRequest(
            from: request,
            sourceID: session.sourceID,
            approvedDomains: session.approvedDomains,
            baseDomain: session.baseDomain,
            isExplicitInitialTopLevelNavigation: isExplicitInitialTopLevelNavigation
        )
    }

    private static func matchesInitialTopLevelRequest(
        _ request: URLRequest,
        expectedURL: URL?
    ) -> Bool {
        guard let expectedURL,
              request.url?.absoluteString == expectedURL.absoluteString,
              (request.httpMethod ?? "GET").uppercased() == "GET",
              request.httpBody == nil,
              request.httpBodyStream == nil else {
            return false
        }
        return true
    }

    @discardableResult
    private func finishIfActive(
        _ identifier: ObjectIdentifier,
        action: () -> Void
    ) -> Bool {
        lock.lock()
        let wasActive = tasks.removeValue(forKey: identifier) != nil
        lock.unlock()
        guard wasActive else { return false }
        action()
        return true
    }
}

enum ReaderExtensionExternalBrowserBoundary {
    static let disclosure = "Opens in your default browser. Browser cookies stay there and are not imported into Eclipse; use Sign In above when the source needs an Eclipse authentication session."

    static func validatedURL(_ url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.user == nil,
              url.password == nil,
              ReaderExtensionSecurityPolicy.canonicalHost(of: url) != nil else {
            return nil
        }
        return url
    }
}

private extension ReaderExtensionMediaType {
    var displayName: String { self == .manga ? "Manga" : "Web Novel" }
}

private extension ReaderExtensionImplementation {
    var displayName: String {
        switch self {
        case .javascript: return "JavaScript"
        case .madara: return "Madara"
        case .mangaReader: return "MangaReader"
        case .mangaBox: return "MangaBox"
        case .mmrcms: return "MMRCMS"
        case .nepNep: return "NepNep"
        case .unsupportedNative: return "Requires an Eclipse update"
        }
    }
}

private extension ReaderExtensionMaturity {
    var displayName: String {
        switch self {
        case .safe: return "Safe"
        case .mature: return "Mature"
        case .unknown: return "Unknown"
        }
    }
}

private extension ReaderExtensionPreferenceValue {
    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value): return String(value)
        case .secretReference: return nil
        case .bool, .stringList: return nil
        }
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}
#endif
