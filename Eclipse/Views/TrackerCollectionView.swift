import SwiftUI

struct TrackerCollectionSections: View {
    let target: TrackerCollectionTarget
    var seriesTargets: [TrackerCollectionTarget] = []
    var onSelect: ((TrackerLibraryEntry) -> Void)? = nil
    @ObservedObject private var manager = TrackerManager.shared
    @ObservedObject private var profiles = ProfileManager.shared

    var body: some View {
        if TrackerLibrarySettings.isEnabled && !profiles.isKidsModeActive {
            ForEach(TrackerService.allCases, id: \.self) { service in
                if target.supports(service), let session = manager.captureLibrarySession(service: service) {
                    if seriesTargets.count > 1 && service != .trakt {
                        TrackerSeriesCollectionSection(targets: seriesTargets, session: session)
                            .id(session)
                    } else {
                        TrackerCollectionSection(target: target, session: session, onSelect: onSelect)
                            .id(target)
                            .id(session)
                    }
                }
            }
        }
    }
}

private struct TrackerCollectionSection: View {
    let target: TrackerCollectionTarget
    let session: TrackerLibrarySession
    let onSelect: ((TrackerLibraryEntry) -> Void)?
    @Environment(\.scenePhase) private var scenePhase
    @State private var candidate: TrackerLibraryEntry?
    @State private var existing: TrackerLibraryEntry?
    @State private var membershipLoaded = false
    @State private var included = false
    @State private var loading = false
    @State private var searching = false
    @State private var searchText = ""
    @State private var candidates: [TrackerLibraryEntry] = []
    @State private var lists: [TrackerLibraryList] = []
    @State private var selectedSection: TrackerLibrarySection = .watchlist
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var generation = UUID()
    @State private var work: Task<Void, Never>?
    private let manager = TrackerManager.shared

    var body: some View {
        Section(header: Text(session.service.displayName)) {
            if let candidate {
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.title).font(.headline)
                    Text([candidate.format, candidate.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundColor(.secondary)
                }
                if session.service == .trakt {
                    Picker("List", selection: $selectedSection) {
                        Text("Watchlist").tag(TrackerLibrarySection.watchlist)
                        Text("Owned Collection").tag(TrackerLibrarySection.collection)
                        ForEach(lists) { list in
                            Text(list.name).tag(TrackerLibrarySection.customList(id: list.id, name: list.name))
                        }
                    }
                    .disabled(loading)
                    .onChange(of: selectedSection) { _ in loadMembership() }
                    if selectedSection == .collection {
                        Text(candidate.kind == .show ? "Tracks episodes you own." : "Tracks movies you own.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    if membershipLoaded {
                        Button {
                            changeTraktMembership()
                        } label: {
                            Label(traktActionTitle,
                                  systemImage: included ? "checkmark.circle.fill" : "plus.circle")
                        }
                        .disabled(loading)
                        .accessibilityIdentifier("trackerCollection.\(session.service.rawValue).add")
                    }
                } else if membershipLoaded {
                    if let existing {
                        Label("In your list · \(existing.status.title(for: existing.kind))", systemImage: "checkmark.circle.fill")
                        Text("\(existing.progress) \(existing.kind.unit) · \(Int(existing.score)) / 100")
                            .font(.caption).foregroundColor(.secondary)
                    } else {
                        Button("Add to Planning", action: addToPlanning)
                            .disabled(loading)
                            .accessibilityIdentifier("trackerCollection.\(session.service.rawValue).add")
                    }
                }
                if session.service != .trakt && !target.hasExactIdentity(for: session.service) {
                    Button("Choose a Different Title") {
                        searching = true
                        searchText = target.title
                        search()
                    }.disabled(loading)
                }
            } else if !searching && !loading && !target.hasExactIdentity(for: session.service) {
                Button("Choose Matching Title") {
                    searching = true
                    searchText = target.title
                    search()
                }
                .accessibilityIdentifier("trackerCollection.\(session.service.rawValue).choose")
            }
            if searching {
                HStack {
                    TextField("Search title", text: $searchText).onSubmit(search)
                    Button("Search", action: search).disabled(loading)
                }
                Text(target.kind == .manga ? "Choose the matching manga or novel." : "Choose the exact anime title or season.")
                    .font(.caption).foregroundColor(.secondary)
                ForEach(candidates) { result in
                    Button {
                        select(result)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(result.title)
                            Text([result.format, result.year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }.disabled(loading)
                }
            }
            if loading { ProgressView("\(candidate == nil ? "Finding title" : "Updating list")…") }
            if let message { Text(message).font(.callout).foregroundColor(.secondary) }
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundColor(.secondary)
            }
            Button("Refresh", action: refresh).disabled(loading)
        }
        .task { resolveInitial() }
        .onChange(of: scenePhase) { phase in
            if phase == .active && !loading { refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .trackerLibraryInvalidated)) { notification in
            if notification.object as? TrackerLibrarySession == session && !loading {
                if candidate != nil { loadMembership() } else { resolveInitial() }
            }
        }
        .onDisappear {
            generation = UUID()
            work?.cancel()
        }
    }

    private var traktActionTitle: String {
        if selectedSection == .collection, candidate?.kind == .show {
            return included ? "Remove All Episodes from Collection" : "Collect All Episodes"
        }
        return included ? "Remove from \(destinationName)" : "Add to \(destinationName)"
    }

    private var destinationName: String {
        selectedSection == .collection ? "Owned Collection" : selectedSection.title
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        work?.cancel()
        let token = UUID()
        generation = token
        loading = true
        errorMessage = nil
        message = nil
        work = Task { @MainActor in
            do {
                try await TrackerRequestContext.$priority.withValue(.interactive) {
                    try await operation()
                }
            } catch is CancellationError {
                if !Task.isCancelled, generation == token, manager.librarySessionIsCurrent(session) {
                    errorMessage = "The list changed. Refresh to update it."
                }
            } catch {
                guard generation == token, manager.librarySessionIsCurrent(session) else { return }
                errorMessage = error.localizedDescription
            }
            guard generation == token else { return }
            loading = false
        }
    }

    private func requireCurrent(_ token: UUID) throws {
        try Task.checkCancellation()
        guard token == generation, manager.librarySessionIsCurrent(session) else { throw CancellationError() }
    }

    private func resolveInitial() {
        guard target.hasExactIdentity(for: session.service) else { return }
        run {
            let token = generation
            let found = try await manager.collectionCandidates(target: target, session: session)
            try requireCurrent(token)
            guard found.count == 1, let result = found.first else { throw TrackerLibraryError.noMatch }
            candidate = result
            if session.service == .trakt {
                lists = try await manager.fetchLibraryLists(session: session)
                try requireCurrent(token)
            }
            try await refreshMembership(token: token)
        }
    }

    private func search() {
        run {
            let token = generation
            let found = try await manager.collectionCandidates(target: target, session: session, search: searchText)
            try requireCurrent(token)
            candidates = found
            if found.isEmpty { message = "No matching titles found. Try another title." }
        }
    }

    private func select(_ entry: TrackerLibraryEntry) {
        guard !loading, manager.librarySessionIsCurrent(session) else { return }
        candidate = entry
        existing = nil
        membershipLoaded = false
        searching = false
        candidates = []
        onSelect?(entry)
        loadMembership()
    }

    private func loadMembership(forceRefresh: Bool = false) {
        membershipLoaded = false
        run { try await refreshMembership(token: generation, forceRefresh: forceRefresh) }
    }

    private func refresh() {
        do {
            _ = try manager.refreshLibrarySession(session)
            if candidate != nil { loadMembership(forceRefresh: true) } else { resolveInitial() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func refreshMembership(token: UUID, forceRefresh: Bool = false) async throws {
        guard let candidate else { return }
        if session.service == .trakt {
            let value = try await manager.fetchTraktCollectionMembership(entry: candidate, section: selectedSection,
                session: session, forceRefresh: forceRefresh)
            try requireCurrent(token)
            included = value
        } else {
            let entry = try await manager.collectionEntry(candidate, session: session)
            try requireCurrent(token)
            existing = entry
        }
        membershipLoaded = true
    }

    private func addToPlanning() {
        guard let candidate, membershipLoaded, existing == nil, !loading else { return }
        membershipLoaded = false
        run {
            let token = generation
            let saved = try await manager.addCollectionEntryToPlanning(candidate, session: session)
            try requireCurrent(token)
            existing = saved
            onSelect?(saved)
            membershipLoaded = true
            message = "Saved to \(session.service.displayName)."
        }
    }

    private func changeTraktMembership() {
        guard let candidate, membershipLoaded, !loading else { return }
        let desired = !included
        let action: TraktLibraryAction
        switch selectedSection {
        case .watchlist: action = .watchlist(desired)
        case .collection: action = .collection(desired)
        case .customList(let id, _): action = .customList(id: id, included: desired)
        default: return
        }
        membershipLoaded = false
        run {
            let token = generation
            try await manager.performTraktLibraryAction(action, entry: candidate, session: session)
            try requireCurrent(token)
            included = desired
            membershipLoaded = true
            message = desired ? "Added to \(destinationName)." : "Removed from \(destinationName)."
        }
    }
}


private struct TrackerSeriesCollectionSection: View {
    let targets: [TrackerCollectionTarget]
    let session: TrackerLibrarySession
    @Environment(\.scenePhase) private var scenePhase
    @State private var rows: [TrackerSeriesCollectionRow] = []
    @State private var loading = false
    @State private var adding = false
    @State private var attemptedAdd = false
    @State private var attemptHasIncompleteSeasons = false
    @State private var confirmedActionIDs = Set<String>()
    @State private var completed = 0
    @State private var total = 0
    @State private var errorMessage: String?
    @State private var generation = UUID()
    @State private var work: Task<Void, Never>?
    private let manager = TrackerManager.shared

    var body: some View {
        Section(header: Text(session.service.displayName)) {
            Text("All \(targets.count) seasons")
                .font(.headline)
                .accessibilityIdentifier("trackerCollection.\(session.service.rawValue).seasonCount")
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.target.title)
                        .accessibilityIdentifier("trackerCollection.\(session.service.rawValue).season.\(row.index)")
                    if let error = row.errorMessage {
                        Text(error).font(.caption).foregroundColor(.secondary)
                    } else if row.membershipLoaded, let entry = row.existing {
                        Label("In your list · \(entry.status.title(for: entry.kind))", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundColor(.secondary)
                    } else if row.membershipLoaded {
                        Text("Not in your list").font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            if loading {
                ProgressView("\(adding ? "Saving" : "Checking") season \(completed) of \(max(total, 1))…")
            } else if !rows.isEmpty {
                if attemptedAdd && rows.allSatisfy(\.confirmedByAction) {
                    Label("All seasons processed", systemImage: "checkmark.circle.fill")
                } else {
                    Button(attemptedAdd ? "Retry Incomplete Seasons" : "Add All Seasons to Planning", action: addAll)
                        .accessibilityIdentifier("trackerCollection.\(session.service.rawValue).addAllSeasons")
                    Text("Existing entries keep their status, progress, and rating.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            if let errorMessage { Text(errorMessage).font(.callout).foregroundColor(.secondary) }
            Button("Refresh", action: refresh).disabled(loading)
        }
        .task { load() }
        .onChange(of: targets) { _ in load() }
        .onChange(of: scenePhase) { phase in
            if phase == .active && !loading { refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .trackerLibraryInvalidated)) { notification in
            if notification.object as? TrackerLibrarySession == session && !loading { load() }
        }
        .onDisappear {
            generation = UUID()
            work?.cancel()
        }
    }

    private func requireCurrent(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token, manager.librarySessionIsCurrent(session) else { throw CancellationError() }
    }

    private func resolve(_ target: TrackerCollectionTarget) async throws -> TrackerLibraryEntry {
        guard target.hasExactIdentity(for: session.service) else { throw TrackerLibraryError.noMatch }
        let candidates = try await manager.collectionCandidates(target: target, session: session)
        guard candidates.count == 1, let candidate = candidates.first else { throw TrackerLibraryError.noMatch }
        return candidate
    }

    private func run(adding: Bool, operation: @escaping @MainActor (UUID) async throws -> Void) {
        work?.cancel()
        let token = UUID()
        generation = token
        loading = true
        self.adding = adding
        completed = 0
        total = targets.count
        errorMessage = nil
        work = Task { @MainActor in
            do {
                try await TrackerRequestContext.$priority.withValue(.interactive) {
                    try await operation(token)
                }
            } catch {
                guard !Task.isCancelled, generation == token, manager.librarySessionIsCurrent(session) else { return }
                errorMessage = error is CancellationError ? "The list changed. Refresh to update it." : error.localizedDescription
            }
            guard generation == token else { return }
            loading = false
        }
    }

    private func refresh() {
        do {
            _ = try manager.refreshLibrarySession(session)
            load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func load() {
        let preserveAttempt = attemptedAdd && attemptHasIncompleteSeasons
        if !preserveAttempt { confirmedActionIDs = [] }
        let confirmedIDs = confirmedActionIDs
        attemptedAdd = preserveAttempt
        if !preserveAttempt { attemptHasIncompleteSeasons = false }
        run(adding: false) { token in
            let result = try await TrackerSeriesCollection.load(targets: targets, confirmedEntryIDs: confirmedIDs,
                isAuthorized: { generation == token && manager.librarySessionIsCurrent(session) },
                resolve: resolve,
                read: { try await manager.collectionEntry($0, session: session) },
                onUpdate: { values, count, maximum in
                    rows = values
                    completed = count
                    total = maximum
                })
            try requireCurrent(token)
            rows = result
        }
    }

    private func addAll() {
        guard !loading else { return }
        let retryIncompleteOnly = attemptedAdd
        let initialRows = rows
        let confirmedIDs = confirmedActionIDs
        attemptedAdd = true
        attemptHasIncompleteSeasons = true
        run(adding: true) { token in
            let result = try await TrackerSeriesCollection.addAll(rows: initialRows,
                retryIncompleteOnly: retryIncompleteOnly, confirmedEntryIDs: confirmedIDs,
                isAuthorized: { generation == token && manager.librarySessionIsCurrent(session) },
                resolve: resolve,
                add: { try await manager.addCollectionEntryToPlanning($0, session: session) },
                onUpdate: { values, count, maximum in
                    rows = values
                    confirmedActionIDs.formUnion(values.filter(\.confirmedByAction).compactMap { $0.candidate?.id })
                    completed = count
                    total = maximum
                })
            try requireCurrent(token)
            rows = result
            let incomplete = result.filter { !$0.confirmedByAction }.count
            attemptHasIncompleteSeasons = incomplete > 0
            if incomplete > 0 {
                errorMessage = "\(result.count - incomplete) of \(result.count) tracker entries confirmed. \(incomplete) could not be added."
            }
        }
    }
}

#if os(macOS)
struct MacReaderCollectionSheet: View {
    let item: MangaLibraryItem
    @ObservedObject private var library = MangaLibraryManager.shared
    @ObservedObject private var profiles = ProfileManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var authority = ProgressManager.shared.profileMutationAuthority()
    @State private var newCollectionName = ""

    var body: some View {
        VStack {
            Text("Add to Collection").font(.title2).padding(.top)
            List {
                Section(header: Text("Local")) {
                    ForEach(library.collections) { collection in
                        Button {
                            guard authority.map(ProgressManager.shared.profileMutationAuthorityIsCurrent) == true else { return }
                            if library.isItemInCollection(collection.id, item: item) { library.removeItem(from: collection.id, item: item) }
                            else { library.addItem(to: collection.id, item: item) }
                        } label: {
                            Label(collection.name, systemImage: library.isItemInCollection(collection.id, item: item) ? "checkmark.circle.fill" : "circle")
                        }
                    }
                    HStack {
                        TextField("New collection name", text: $newCollectionName)
                        Button("Create") {
                            guard authority.map(ProgressManager.shared.profileMutationAuthorityIsCurrent) == true else { return }
                            library.createCollection(name: newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines))
                            newCollectionName = ""
                        }.disabled(newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                TrackerCollectionSections(target: TrackerCollectionTarget(title: item.title, kind: .manga,
                    aniListID: item.trackerAniListId ?? MangaReadingProgressManager.shared.progress(for: item.id)?.trackerAniListId ?? (item.id > 0 ? item.id : nil),
                    malID: item.trackerMALId ?? MangaReadingProgressManager.shared.progress(for: item.id)?.trackerMALId)) { match in
                        guard authority.map(ProgressManager.shared.profileMutationAuthorityIsCurrent) == true else { return }
                        var known = library.collections.flatMap(\.items).first { $0.id == item.id } ?? item
                        let progress = MangaReadingProgressManager.shared.progress(for: item.id)
                        known.trackerAniListId = known.trackerAniListId ?? progress?.trackerAniListId
                        known.trackerMALId = known.trackerMALId ?? progress?.trackerMALId
                        let linked = known.applyingTrackerSelection(aniListID: match.aniListID, malID: match.malID)
                        library.updateSavedItem(linked)
                        MangaReadingProgressManager.shared.updateTrackerMatch(mangaId: item.id,
                            aniListId: linked.trackerAniListId, malId: linked.trackerMALId,
                            confidence: linked.trackerMatchConfidence, replacingExisting: true)
                    }
            }
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).padding(.bottom)
        }
        .frame(width: 560, height: 580)
        .disabled(profiles.isKidsModeActive)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.activeProfileDidChange)) { _ in dismiss() }
    }
}
#endif
