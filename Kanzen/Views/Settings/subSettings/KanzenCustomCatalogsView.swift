//
//  KanzenCustomCatalogsView.swift
//  Kanzen
//
//  Created by Eclipse on 2026.
//

import SwiftUI
import Combine

#if !os(tvOS)
struct KanzenCatalogRowModel: Identifiable, Equatable {
    let id: UUID
    let title: String
    let summary: String
    let styleName: String
    let isPreset: Bool
    let isEnabled: Bool
}

struct KanzenCatalogSourceSection: Identifiable, Equatable {
    let id: ReaderExtensionSourceID
    let name: String
    let rows: [KanzenCatalogRowModel]
}

struct KanzenCatalogListSnapshot {
    var sections: [KanzenCatalogSourceSection] = []
    var presetIDsBySource: [ReaderExtensionSourceID: Set<String>] = [:]
}

private struct KanzenCatalogBufferIdentity: Equatable {
    let address: UInt
    let count: Int

    init<Element>(_ array: [Element]) {
        count = array.count
        address = array.withUnsafeBufferPointer { buffer -> UInt in
            guard let base = buffer.baseAddress else { return 0 }
            return UInt(bitPattern: UnsafeRawPointer(base))
        }
    }
}

final class KanzenCatalogListDerivation: ObservableObject {
    private struct DerivedStrings {
        let title: String
        let query: String
        let displayStyle: KanzenCatalogDisplayStyle
        let filters: [ReaderExtensionFilter]
        let displayTitle: String
        let summary: String
    }

    private var cachedCatalogs: [KanzenCustomCatalog] = []
    private var cachedSources: [ReaderExtensionInstalledSource] = []
    private var cachedSnapshot: KanzenCatalogListSnapshot?
    private var derivedStrings: [UUID: DerivedStrings] = [:]

    func snapshot(
        catalogs: [KanzenCustomCatalog],
        installedSources: [ReaderExtensionInstalledSource]
    ) -> KanzenCatalogListSnapshot {
        if let reusable = cachedSnapshot,
           KanzenCatalogBufferIdentity(cachedCatalogs) == KanzenCatalogBufferIdentity(catalogs),
           KanzenCatalogBufferIdentity(cachedSources) == KanzenCatalogBufferIdentity(installedSources) {
            return reusable
        }

        var names: [ReaderExtensionSourceID: String] = [:]
        names.reserveCapacity(installedSources.count)
        for source in installedSources where names[source.id] == nil {
            names[source.id] = source.name
        }

        var rowsBySource: [ReaderExtensionSourceID: [KanzenCatalogRowModel]] = [:]
        var presetIDsBySource: [ReaderExtensionSourceID: Set<String>] = [:]
        var orderedSourceIDs: [ReaderExtensionSourceID] = []
        var nextDerivedStrings: [UUID: DerivedStrings] = [:]
        nextDerivedStrings.reserveCapacity(catalogs.count)

        for catalog in catalogs {
            let derived = strings(for: catalog)
            nextDerivedStrings[catalog.id] = derived
            let row = KanzenCatalogRowModel(
                id: catalog.id,
                title: derived.displayTitle,
                summary: derived.summary,
                styleName: catalog.displayStyle.displayName,
                isPreset: catalog.isPreset,
                isEnabled: catalog.isEnabled
            )
            if rowsBySource[catalog.sourceID] == nil {
                orderedSourceIDs.append(catalog.sourceID)
                rowsBySource[catalog.sourceID] = [row]
            } else {
                rowsBySource[catalog.sourceID]?.append(row)
            }
            if let presetID = catalog.presetID, catalog.isEnabled {
                presetIDsBySource[catalog.sourceID, default: []].insert(presetID)
            }
        }

        let sections = orderedSourceIDs
            .map { sourceID in
                KanzenCatalogSourceSection(
                    id: sourceID,
                    name: names[sourceID] ?? "Removed source",
                    rows: rowsBySource[sourceID] ?? []
                )
            }
            .sorted { left, right in
                let comparison = left.name.localizedCaseInsensitiveCompare(right.name)
                guard comparison == .orderedSame else { return comparison == .orderedAscending }
                return left.id.rawValue < right.id.rawValue
            }

        let snapshot = KanzenCatalogListSnapshot(
            sections: sections,
            presetIDsBySource: presetIDsBySource
        )
        cachedCatalogs = catalogs
        cachedSources = installedSources
        derivedStrings = nextDerivedStrings
        cachedSnapshot = snapshot
        return snapshot
    }

    private func strings(for catalog: KanzenCustomCatalog) -> DerivedStrings {
        if let cached = derivedStrings[catalog.id],
           KanzenCatalogBufferIdentity(cached.filters) == KanzenCatalogBufferIdentity(catalog.filters),
           cached.displayStyle == catalog.displayStyle,
           cached.title == catalog.title,
           cached.query == catalog.query {
            return cached
        }
        return DerivedStrings(
            title: catalog.title,
            query: catalog.query,
            displayStyle: catalog.displayStyle,
            filters: catalog.filters,
            displayTitle: catalog.displayTitle,
            summary: catalog.summary
        )
    }
}

struct KanzenCustomCatalogsView: View {
    @StateObject private var catalogManager = KanzenCustomCatalogManager.shared
    @StateObject private var readerExtensionManager = ReaderExtensionManager.shared
    @StateObject private var contentFilter = ReaderContentFilter.shared
    @StateObject private var suggestions = KanzenCatalogSuggestionStore()
    @StateObject private var derivation = KanzenCatalogListDerivation()
    @State private var renamingCatalog: KanzenCustomCatalog?
    @Environment(\.editMode) private var editMode
    @State private var isBuildingCatalog = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if contentFilter.isKidsProfileActive {
                restrictedView
            } else {
                catalogList
            }
        }
        .navigationTitle("Custom Catalogs")
        .navigationBarTitleDisplayMode(.inline)
        .eclipseSettingsStyle()
        .preferredColorScheme(.dark)
        .onChange(of: contentFilter.isKidsProfileActive) { isKids in
            guard isKids else { return }
            isBuildingCatalog = false
            renamingCatalog = nil
            errorMessage = nil
            suggestions.reset()
        }
        .alert("Custom Catalogs", isPresented: Binding(
            get: { errorMessage != nil && !contentFilter.isKidsProfileActive },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(item: $renamingCatalog) { catalog in
            KanzenCustomCatalogEditorView(
                sourceName: sourceName(for: catalog.sourceID),
                draft: catalog,
                isRenamingExistingCatalog: true
            )
        }
    }

    private func sourceName(for sourceID: ReaderExtensionSourceID) -> String {
        readerExtensionManager.installedSources.first { $0.id == sourceID }?.name ?? "Removed source"
    }

    private var restrictedView: some View {
        List {
            Section {
                Text("Custom catalogs cannot be viewed or changed from a kids profile. Switch to a grown-up profile to continue.")
                    .foregroundColor(.secondary)
            }
            .eclipseExperimentalSettingsRows()
            .background(EclipseScrollTracker())
        }
    }

    private var catalogList: some View {
        let snapshot = derivation.snapshot(
            catalogs: catalogManager.catalogs,
            installedSources: readerExtensionManager.installedSources
        )
        let sources = readerExtensionManager.enabledSources

        return List {
            if snapshot.sections.isEmpty {
                emptySection
            } else {
                ForEach(snapshot.sections) { section in
                    catalogSection(section)
                }
            }

            suggestedSection(sources: sources, presetIDsBySource: snapshot.presetIDsBySource)

            Section {
                Text("Disabled catalogs stay saved but do not load on Discover. Each source may hold up to \(KanzenCustomCatalogManager.maximumCatalogsPerSource) catalogs.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .eclipseExperimentalSettingsRows()
            .background(EclipseScrollTracker())
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    beginCatalogCreation(hasUsableSources: !sources.isEmpty)
                } label: {
                    Image(systemName: "plus")
                }
                .disabled(sources.isEmpty)
                .accessibilityLabel("New Catalog")

                EditButton()
                    .disabled(snapshot.sections.isEmpty && editMode?.wrappedValue.isEditing != true)
            }
        }
        .sheet(isPresented: $isBuildingCatalog) {
            KanzenCatalogBuilderView(
                sources: sources,
                onSaved: { _ in isBuildingCatalog = false },
                onCancel: { isBuildingCatalog = false }
            )
        }
    }

    private var emptySection: some View {
        Section(footer: Text("Tap + to build a catalog from a source's own filters, or switch on a suggestion below. A filtered search saved from the Reader search screen lands here too.")) {
            VStack(spacing: 10) {
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)
                Text("No Custom Catalogs")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
        .eclipseExperimentalSettingsRows()
        .background(EclipseScrollTracker())
    }

    private func catalogSection(_ section: KanzenCatalogSourceSection) -> some View {
        Section(header: Text(section.name)) {
            ForEach(section.rows) { row in
                KanzenCatalogRow(
                    row: row,
                    onOpen: { beginRename(id: row.id) },
                    onToggle: { catalogManager.setEnabled($0, id: row.id) }
                )
                .equatable()
            }
            .onDelete { offsets in
                for index in offsets where section.rows.indices.contains(index) {
                    catalogManager.remove(id: section.rows[index].id)
                }
            }
            .onMove { offsets, destination in
                catalogManager.move(from: offsets, to: destination, within: section.id)
            }
        }
        .eclipseExperimentalSettingsRows()
        .background(EclipseScrollTracker())
    }

    @ViewBuilder
    private func suggestedSection(
        sources: [ReaderExtensionInstalledSource],
        presetIDsBySource: [ReaderExtensionSourceID: Set<String>]
    ) -> some View {
        if !sources.isEmpty {
            Section(
                header: Text("Suggested"),
                footer: Text("Nothing here is on until you switch it on. Opening a source asks it for its filter list once, then offers every genre and sort row Eclipse can build from it.")
            ) {
                ForEach(sources) { source in
                    suggestionGroup(source, presetIDs: presetIDsBySource[source.id] ?? [])
                }
            }
            .eclipseExperimentalSettingsRows()
            .background(EclipseScrollTracker())
        }
    }

    private func suggestionGroup(
        _ source: ReaderExtensionInstalledSource,
        presetIDs: Set<String>
    ) -> some View {
        DisclosureGroup(isExpanded: expansionBinding(source.id)) {
            suggestionContent(source, presetIDs: presetIDs)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(suggestionSummary(source, enabledCount: presetIDs.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func suggestionContent(
        _ source: ReaderExtensionInstalledSource,
        presetIDs: Set<String>
    ) -> some View {
        switch suggestions.state(for: source.id) {
        case .idle:
            Text("Open this source to load its suggestions.")
                .font(.caption)
                .foregroundColor(.secondary)

        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Reading this source's filters...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
                Button("Try Again") {
                    suggestions.retry(sourceID: source.id)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 2)

        case .loaded(let resolutions):
            if resolutions.isEmpty {
                Text("This source's filters do not match any built-in catalog.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(resolutions, id: \.preset.id) { resolution in
                    suggestionRow(
                        resolution,
                        sourceID: source.id,
                        isOn: presetIDs.contains(resolution.preset.id)
                    )
                }
            }
        }
    }

    private func suggestionRow(
        _ resolution: KanzenCatalogPresetResolution,
        sourceID: ReaderExtensionSourceID,
        isOn: Bool
    ) -> some View {
        KanzenCatalogSuggestionRow(
            title: resolution.title,
            detail: suggestionDetail(resolution),
            isOn: isOn,
            onToggle: { setSuggestion($0, resolution: resolution, sourceID: sourceID) }
        )
    }

    private func suggestionDetail(_ resolution: KanzenCatalogPresetResolution) -> String {
        let style = resolution.displayStyle.displayName
        guard !resolution.describesItselfExactly else { return style }
        return "\(style) \u{00b7} matches \u{201C}\(resolution.matchedLabel)\u{201D}"
    }

    private func suggestionSummary(
        _ source: ReaderExtensionInstalledSource,
        enabledCount enabled: Int
    ) -> String {
        guard case .loaded(let resolutions) = suggestions.state(for: source.id) else {
            return enabled == 0 ? "No suggestions switched on" : "\(enabled) switched on"
        }
        guard enabled > 0 else { return "\(resolutions.count) available" }
        return "\(enabled) on \u{00b7} \(resolutions.count) available"
    }

    private func expansionBinding(_ sourceID: ReaderExtensionSourceID) -> Binding<Bool> {
        Binding(
            get: { suggestions.isExpanded(sourceID) },
            set: { suggestions.setExpanded($0, for: sourceID) }
        )
    }

    private func setSuggestion(
        _ isOn: Bool,
        resolution: KanzenCatalogPresetResolution,
        sourceID: ReaderExtensionSourceID
    ) {
        guard !contentFilter.isKidsProfileActive else { return }
        guard isOn else {
            guard let existing = catalogManager.catalog(forPresetID: resolution.preset.id, sourceID: sourceID) else {
                return
            }
            // Removing is only safe while the row is still exactly what the
            // preset produced. Once it carries a name or a style the user
            // chose, switching the suggestion off must not silently destroy
            // that work - disable it and leave it in the source's own list.
            // A title this resolver would produce today counts as pristine even
            // if it is not the one stored, so changing how a preset is named
            // can never turn removals into undeletable ghost rows.
            let pristine = resolution.catalog(for: sourceID)
            let pristineTitles: Set<String> = [pristine.title, resolution.preset.title]
            if pristineTitles.contains(existing.title) && existing.displayStyle == pristine.displayStyle {
                catalogManager.remove(id: existing.id)
            } else {
                catalogManager.setEnabled(false, id: existing.id)
            }
            return
        }
        if let existing = catalogManager.catalog(forPresetID: resolution.preset.id, sourceID: sourceID) {
            catalogManager.setEnabled(true, id: existing.id)
            return
        }
        do {
            try catalogManager.save(resolution.catalog(for: sourceID))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func beginRename(id: UUID) {
        guard let catalog = catalogManager.catalogs.first(where: { $0.id == id }) else { return }
        renamingCatalog = catalog
    }

    private func beginCatalogCreation(hasUsableSources: Bool) {
        guard !contentFilter.isKidsProfileActive, hasUsableSources else { return }
        isBuildingCatalog = true
    }
}

private struct KanzenCatalogRow: View, Equatable {
    let row: KanzenCatalogRowModel
    let onOpen: () -> Void
    let onToggle: (Bool) -> Void

    static func == (lhs: KanzenCatalogRow, rhs: KanzenCatalogRow) -> Bool {
        lhs.row == rhs.row
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(row.isEnabled ? .primary : .secondary)
                    Text(row.summary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        KanzenCatalogBadge(text: row.styleName)
                        if row.isPreset {
                            KanzenCatalogBadge(text: "Suggested")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityHint("Opens naming and row style for this catalog.")

            Toggle("", isOn: Binding(
                get: { row.isEnabled },
                set: { onToggle($0) }
            ))
            .labelsHidden()
            .accessibilityLabel("Show \(row.title) on Discover")
        }
    }
}

private struct KanzenCatalogSuggestionRow: View {
    let title: String
    let detail: String
    let isOn: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Toggle("", isOn: Binding(
                get: { isOn },
                set: { onToggle($0) }
            ))
            .labelsHidden()
            .accessibilityLabel("Show \(title) on Discover")
        }
    }
}

private struct KanzenCatalogBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.16))
            .clipShape(Capsule())
    }
}

@MainActor
final class KanzenCatalogSuggestionStore: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded([KanzenCatalogPresetResolution])
        case failed(String)
    }

    @Published private(set) var states: [ReaderExtensionSourceID: LoadState] = [:]
    @Published private(set) var expandedSourceIDs: Set<ReaderExtensionSourceID> = []

    private var loadTokens: [ReaderExtensionSourceID: UUID] = [:]
    private var loadTasks: [ReaderExtensionSourceID: Task<Void, Never>] = [:]

    func state(for sourceID: ReaderExtensionSourceID) -> LoadState {
        states[sourceID] ?? .idle
    }

    func isExpanded(_ sourceID: ReaderExtensionSourceID) -> Bool {
        expandedSourceIDs.contains(sourceID)
    }

    func setExpanded(_ isExpanded: Bool, for sourceID: ReaderExtensionSourceID) {
        guard isExpanded else {
            expandedSourceIDs.remove(sourceID)
            stopLoading(sourceID: sourceID)
            return
        }
        expandedSourceIDs.insert(sourceID)
        resolveIfNeeded(sourceID: sourceID)
    }

    func retry(sourceID: ReaderExtensionSourceID) {
        guard isExpanded(sourceID) else { return }
        stopLoading(sourceID: sourceID)
        states[sourceID] = nil
        resolveIfNeeded(sourceID: sourceID)
    }

    func reset() {
        for task in loadTasks.values {
            task.cancel()
        }
        loadTasks.removeAll()
        loadTokens.removeAll()
        expandedSourceIDs.removeAll()
        states.removeAll()
    }

    private func stopLoading(sourceID: ReaderExtensionSourceID) {
        loadTasks[sourceID]?.cancel()
        loadTasks[sourceID] = nil
        loadTokens[sourceID] = nil
        if case .loading = state(for: sourceID) {
            states[sourceID] = nil
        }
    }

    private func resolveIfNeeded(sourceID: ReaderExtensionSourceID) {
        guard !ProfileManager.shared.isKidsModeActive else { return }
        guard case .idle = state(for: sourceID) else { return }

        let token = UUID()
        loadTokens[sourceID] = token
        states[sourceID] = .loading

        loadTasks[sourceID] = Task { @MainActor in
            let started = Date()
            let label = String(sourceID.rawValue.prefix(12))
            do {
                let provider = try ReaderExtensionManager.shared.provider(for: sourceID)
                let builtInRows = KanzenCatalogBuiltInRows(source: provider.source)
                let filters = try await provider.filters()
                try Task.checkCancellation()
                let resolved = await Self.resolutions(against: filters, builtInRows: builtInRows)
                try Task.checkCancellation()
                guard loadTokens[sourceID] == token else { return }
                states[sourceID] = .loaded(resolved)
                finish(sourceID: sourceID, token: token)
                let elapsed = Int(Date().timeIntervalSince(started) * 1000)
                ReaderLogger.shared.log(
                    "Catalog suggestions resolved source=\(label) count=\(resolved.count) elapsedMs=\(elapsed)",
                    type: "ReaderSearch"
                )
            } catch is CancellationError {
                finish(sourceID: sourceID, token: token)
            } catch {
                guard loadTokens[sourceID] == token else { return }
                states[sourceID] = .failed(error.localizedDescription)
                finish(sourceID: sourceID, token: token)
                ReaderLogger.shared.log(
                    "Catalog suggestions failed source=\(label) error=\(ReaderExtensionDiagnostics.errorCode(error))",
                    type: "ReaderSearch"
                )
            }
        }
    }

    private func finish(sourceID: ReaderExtensionSourceID, token: UUID) {
        guard loadTokens[sourceID] == token else { return }
        loadTokens[sourceID] = nil
        loadTasks[sourceID] = nil
    }

    private static func resolutions(
        against filters: [ReaderExtensionFilter],
        builtInRows: KanzenCatalogBuiltInRows
    ) async -> [KanzenCatalogPresetResolution] {
        await Task.detached(priority: .userInitiated) {
            KanzenCatalogPresetResolver.resolutions(against: filters, builtInRows: builtInRows)
        }.value
    }
}

enum KanzenCustomCatalogEditorSave {
    static func perform(_ draft: KanzenCustomCatalog) -> Result<KanzenCustomCatalog, Error> {
        var catalog = draft
        let trimmed = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        catalog.title = trimmed.isEmpty
            ? KanzenCustomCatalog.suggestedTitle(query: draft.query, filters: draft.filters)
            : trimmed
        do {
            return .success(try KanzenCustomCatalogManager.shared.save(catalog))
        } catch {
            return .failure(error)
        }
    }
}

struct KanzenCustomCatalogEditorFields: View {
    let sourceName: String
    let draft: KanzenCustomCatalog
    @Binding var title: String
    @Binding var displayStyle: KanzenCatalogDisplayStyle
    let errorMessage: String?

    var body: some View {
        let digest = KanzenCustomCatalog.digest(query: draft.query, filters: draft.filters)
        let components = digest.components

        return Group {
            Section(header: Text("Name")) {
                TextField(KanzenCustomCatalog.suggestedTitle(from: digest), text: $title)
                    .autocorrectionDisabled()
            }
            .eclipseExperimentalSettingsRows()
            .background(EclipseScrollTracker())

            Section(
                header: Text("Row Style"),
                footer: Text("Genre cards ignore the saved filters and show this source's own genre list instead.")
            ) {
                ForEach(KanzenCatalogDisplayStyle.allCases, id: \.self) { style in
                    styleRow(style)
                }
            }
            .eclipseExperimentalSettingsRows()
            .background(EclipseScrollTracker())

            Section(header: Text("Catalog"), footer: Text("This row appears on Discover under \(sourceName) and reloads with the home feed.")) {
                LabeledCatalogRow(title: "Source", detail: sourceName)
                catalogDetail(components: components)
            }
            .eclipseExperimentalSettingsRows()
            .background(EclipseScrollTracker())

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundColor(.orange)
                }
                .eclipseExperimentalSettingsRows()
                .background(EclipseScrollTracker())
            }
        }
    }

    @ViewBuilder
    private func catalogDetail(components: [String]) -> some View {
        if displayStyle.isQueryBacked {
            ForEach(Array(components.enumerated()), id: \.offset) { _, component in
                Text(component)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            if components.isEmpty {
                Text("Everything this source returns")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        } else {
            Text("Genre cards from this source's own genre list")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private func styleRow(_ style: KanzenCatalogDisplayStyle) -> some View {
        Button {
            displayStyle = style
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(style.displayName)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                    Text(style.summary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 12)
                Image(systemName: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.accentColor)
                    .opacity(style == displayStyle ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityAddTraits(style == displayStyle ? .isSelected : [])
    }
}

struct KanzenCustomCatalogEditorView: View {
    let sourceName: String
    let draft: KanzenCustomCatalog
    var isRenamingExistingCatalog: Bool = false
    var onSaved: ((KanzenCustomCatalog) -> Void)?

    @Environment(\.presentationMode) private var presentationMode
    @State private var title: String = ""
    @State private var displayStyle: KanzenCatalogDisplayStyle = .poster
    @State private var hasAdoptedDraft = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            Form {
                KanzenCustomCatalogEditorFields(
                    sourceName: sourceName,
                    draft: draft,
                    title: $title,
                    displayStyle: $displayStyle,
                    errorMessage: errorMessage
                )
            }
            .navigationTitle(isRenamingExistingCatalog ? "Edit Catalog" : "Save as Catalog")
            .navigationBarTitleDisplayMode(.inline)
            .eclipseSettingsStyle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .onAppear {
            guard !hasAdoptedDraft else { return }
            hasAdoptedDraft = true
            title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            displayStyle = draft.displayStyle
        }
    }

    private func save() {
        var catalog = draft
        catalog.title = title
        catalog.displayStyle = displayStyle
        switch KanzenCustomCatalogEditorSave.perform(catalog) {
        case .success(let saved):
            errorMessage = nil
            onSaved?(saved)
            dismiss()
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func dismiss() {
        presentationMode.wrappedValue.dismiss()
    }
}

struct LabeledCatalogRow: View {
    let title: String
    let detail: String

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline)
            Spacer(minLength: 12)
            Text(detail)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
#endif
