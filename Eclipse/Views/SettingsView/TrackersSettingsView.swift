import SwiftUI
import Foundation
import Kingfisher

struct TrackersSettingsView: View {
    private struct TraktListSortOption: Identifiable {
        let id: String
        let name: String
    }

    @StateObject private var trackerManager = TrackerManager.shared
    @StateObject private var catalogManager = CatalogManager.shared
    @State private var showImportConfirmation = false
    @State private var showMALImportConfirmation = false
    @State private var showTraktImportConfirmation = false
    @State private var showSyncTools = false
    @State private var traktListInput = ""
    @State private var traktListName = ""
    @State private var traktListMediaType = "shows"
    @State private var traktListSortBy = "rank"
    @State private var traktListSortHow = "asc"
    @State private var traktListError: String?

    private let traktListSortOptions: [TraktListSortOption] = [
        TraktListSortOption(id: "rank", name: "List Rank"),
        TraktListSortOption(id: "added", name: "Recently Added"),
        TraktListSortOption(id: "title", name: "Title"),
        TraktListSortOption(id: "released", name: "Release Date"),
        TraktListSortOption(id: "popularity", name: "Popularity"),
        TraktListSortOption(id: "votes", name: "Votes")
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Trackers")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal)

                VStack(spacing: 12) {
                    // Sync Toggle
                    Toggle("Enable Sync", isOn: Binding(
                        get: { trackerManager.trackerState.syncEnabled },
                        set: { trackerManager.setSyncEnabled($0) }
                    ))
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(12)

                    Toggle("Auto Sync Ratings", isOn: Binding(
                        get: { trackerManager.trackerState.autoSyncRatings },
                        set: { trackerManager.setAutoSyncRatings($0) }
                    ))
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(12)

                    Button(action: { showSyncTools = true }) {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .foregroundColor(.blue)
                                .frame(width: 32, height: 32)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Sync Tools")
                                    .font(.headline)
                                    .foregroundColor(.white)

                                Text("Preview imports, pushes, and AniList/MAL ports")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color.gray.opacity(0.1))
                        .cornerRadius(12)
                    }
                    .buttonStyle(.plain)

                    // AniList Section
                    trackerRow(
                        service: .anilist,
                        isConnected: trackerManager.trackerState.getAccount(for: .anilist) != nil,
                        username: trackerManager.trackerState.getAccount(for: .anilist)?.username,
                        onConnect: { trackerManager.startAniListAuth() },
                        onDisconnect: { trackerManager.disconnectTracker(.anilist) }
                    )

                    // AniList Import Section
                    if trackerManager.trackerState.getAccount(for: .anilist) != nil {
                        aniListImportSection
                    }

                    // MyAnimeList Section
                    trackerRow(
                        service: .myAnimeList,
                        isConnected: trackerManager.trackerState.getAccount(for: .myAnimeList) != nil,
                        username: trackerManager.trackerState.getAccount(for: .myAnimeList)?.username,
                        onConnect: { trackerManager.startMALAuth() },
                        onDisconnect: { trackerManager.disconnectTracker(.myAnimeList) }
                    )

                    if trackerManager.trackerState.getAccount(for: .myAnimeList) != nil {
                        malImportSection
                    }

                    // Trakt Section
                    trackerRow(
                        service: .trakt,
                        isConnected: trackerManager.trackerState.getAccount(for: .trakt) != nil,
                        username: trackerManager.trackerState.getAccount(for: .trakt)?.username,
                        onConnect: { trackerManager.startTraktAuth() },
                        onDisconnect: { trackerManager.disconnectTracker(.trakt) }
                    )

#if os(tvOS)
                    if trackerManager.isAuthenticating,
                       let userCode = trackerManager.traktDeviceUserCode,
                       let verificationURL = trackerManager.traktDeviceVerificationURL {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Connect Trakt")
                                .font(.headline)
                                .foregroundColor(.white)
                            Text("Open \(verificationURL.absoluteString) on any browser and enter:")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(userCode)
                                .font(.system(size: 34, weight: .bold, design: .monospaced))
                            Text("Eclipse will finish connecting automatically. You can close the web sheet and use the code on a phone or computer instead.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.blue.opacity(0.15))
                        .cornerRadius(12)
                    }
#endif

                    if trackerManager.trackerState.getAccount(for: .trakt) != nil {
                        Toggle("Live Trakt Scrobbling", isOn: Binding(
                            get: { trackerManager.trackerState.liveTraktScrobbling },
                            set: { trackerManager.setLiveTraktScrobbling($0) }
                        ))
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(12)

                        traktFeatureSettingsSection

                        if trackerManager.trackerState.traktPublicCatalogsEnabled {
                            traktPublicCatalogsSection
                        }

                        traktImportSection
                    }
                }
                .padding(.horizontal)

                if let error = trackerManager.authError {
                    VStack {
                        HStack {
                            Image(systemName: "exclamationmark.circle")
                                .foregroundColor(.orange)
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                    .padding(.horizontal)
                }

                Spacer()
            }
            .padding(.vertical)
            .frame(maxWidth: isIPad ? 700 : .infinity)
            .frame(maxWidth: .infinity)
        }
        .background(SettingsGradientBackground().ignoresSafeArea())
        .navigationTitle("Trackers")
        #if !os(tvOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("Import AniList Library", isPresented: $showImportConfirmation) {
            Button("Import", role: .none) {
                trackerManager.importAniListToLibrary()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(aniListImportConfirmationMessage)
        }
        .alert("Import MAL Library", isPresented: $showMALImportConfirmation) {
            Button("Import", role: .none) {
                trackerManager.importMALToLibrary()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(malImportConfirmationMessage)
        }
        .alert("Import Trakt Library", isPresented: $showTraktImportConfirmation) {
            Button("Import", role: .none) {
                trackerManager.importTraktToLibrary()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will import your Trakt watchlist and watched progress as Eclipse collections without deleting or downgrading anything.")
        }
        .sheet(isPresented: $showSyncTools) {
            TrackerSyncToolsSheet(trackerManager: trackerManager)
        }
    }

    // MARK: - AniList Import Section

    @ViewBuilder
    private var aniListImportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import AniList Library")
                        .font(.headline)
                        .foregroundColor(.white)

                    Text("Import your Watching, Planning, and Completed lists as collections")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if trackerManager.isImportingAniList {
                    EclipseLoadingIndicator(tint: .white)
                } else {
                    Button(action: { showImportConfirmation = true }) {
                        Text("Import")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.blue)
                            .cornerRadius(6)
                    }
                }
            }

            if let progress = trackerManager.aniListImportProgress {
                Text(progress)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if let error = trackerManager.aniListImportError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }

    @ViewBuilder
    private var malImportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import MAL Library")
                        .font(.headline)
                        .foregroundColor(.white)

                    Text(malImportDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if trackerManager.isImportingMAL {
                    EclipseLoadingIndicator(tint: .white)
                } else {
                    Button(action: { showMALImportConfirmation = true }) {
                        Text("Import")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.blue)
                            .cornerRadius(6)
                    }
                }
            }

            if let progress = trackerManager.malImportProgress {
                Text(progress)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if let error = trackerManager.malImportError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }

    @ViewBuilder
    private var traktImportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import Trakt Library")
                        .font(.headline)
                        .foregroundColor(.white)

                    Text("Import your watchlist and watched progress as collections")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if trackerManager.isImportingTrakt {
                    EclipseLoadingIndicator(tint: .white)
                } else {
                    Button(action: { showTraktImportConfirmation = true }) {
                        Text("Import")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.blue)
                            .cornerRadius(6)
                    }
                }
            }

            if let progress = trackerManager.traktImportProgress {
                Text(progress)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if let error = trackerManager.traktImportError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }

    @ViewBuilder
    private var traktFeatureSettingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trakt Features")
                .font(.headline)
                .foregroundColor(.white)

            traktToggleRow(
                title: "Public List Catalogs",
                subtitle: "Add Trakt public lists to the Home catalog system.",
                isOn: Binding(
                    get: { trackerManager.trackerState.traktPublicCatalogsEnabled },
                    set: { trackerManager.setTraktPublicCatalogsEnabled($0) }
                )
            )

            traktToggleRow(
                title: "Detail Reviews",
                subtitle: "Show non-spoiler Trakt comments and reviews on media detail pages.",
                isOn: Binding(
                    get: { trackerManager.trackerState.traktCommentsEnabled },
                    set: { trackerManager.setTraktCommentsEnabled($0) }
                )
            )

            traktToggleRow(
                title: "Anime Episode Mapping",
                subtitle: "When seasons don't line up, match anime episodes to Trakt using absolute numbering so scrobbles still land.",
                isOn: Binding(
                    get: { trackerManager.trackerState.traktAnimeEpisodeMapping },
                    set: { trackerManager.setTraktAnimeEpisodeMapping($0) }
                )
            )

            traktToggleRow(
                title: "Sync Trakt Watchlist",
                subtitle: "Mirror the \u{201C}Trakt Watchlist\u{201D} collection with your Trakt watchlist. Adds you make sync both ways; pulled items are only ever added, never deleted.",
                isOn: Binding(
                    get: { trackerManager.trackerState.traktWatchlistSync },
                    set: { trackerManager.setTraktWatchlistSync($0) }
                )
            )
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }

    @ViewBuilder
    private var traktPublicCatalogsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Trakt Public Catalogs")
                        .font(.headline)
                        .foregroundColor(.white)

                    Text("Added lists appear in Catalogs for ordering and per-row toggles.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }

            if !catalogManager.traktPublicListCatalogs.isEmpty {
                VStack(spacing: 8) {
                    ForEach(catalogManager.traktPublicListCatalogs) { catalog in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(catalog.name)
                                    .font(.subheadline)
                                    .foregroundColor(.white)
                                    .lineLimit(1)

                                if let listIdentifier = catalog.traktListDisplayIdentifier {
                                    let mediaType = Catalog.normalizedTraktListMediaType(catalog.traktListMediaType) == "movies" ? "Movies" : "Shows"
                                    Text("List \(listIdentifier) - \(mediaType)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Spacer()

                            Button(role: .destructive) {
                                catalogManager.removeTraktPublicListCatalog(id: catalog.id)
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundColor(.red)
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(10)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(10)
                    }
                }
            }

            VStack(spacing: 10) {
                TextField("Trakt list URL or ID", text: $traktListInput)
#if os(tvOS)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(8)
#else
                    .textFieldStyle(.roundedBorder)
#endif

                TextField("Catalog name (optional)", text: $traktListName)
#if os(tvOS)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(8)
#else
                    .textFieldStyle(.roundedBorder)
#endif

                HStack {
                    Picker(LocalizedStringKey("Trakt List Type"), selection: $traktListMediaType) {
                        Text("Shows").tag("shows")
                        Text("Movies").tag("movies")
                    }
                    .pickerStyle(.menu)

                    Spacer()

                    Picker("Sort", selection: $traktListSortBy) {
                        ForEach(traktListSortOptions) { option in
                            Text(option.name).tag(option.id)
                        }
                    }
                    .pickerStyle(.menu)
                }

                HStack {
                    Picker("Direction", selection: $traktListSortHow) {
                        Text("Ascending").tag("asc")
                        Text("Descending").tag("desc")
                    }
                    .pickerStyle(.segmented)

                    Button(action: addTraktPublicCatalog) {
                        Label("Add", systemImage: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.blue)
                            .cornerRadius(8)
                    }
                }

                if let traktListError {
                    Text(traktListError)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }

    @ViewBuilder
    private func traktToggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.white)

                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
        }
    }

    private func addTraktPublicCatalog() {
        guard let parsedList = parseTraktList(from: traktListInput) else {
            traktListError = "Enter a Trakt public list URL, username/list slug URL, or numeric list ID."
            return
        }

        catalogManager.addTraktPublicListCatalog(
            name: traktListName,
            listId: parsedList.id,
            listUser: parsedList.user,
            listSlug: parsedList.slug,
            mediaType: traktListMediaType,
            sortBy: traktListSortBy,
            sortHow: traktListSortHow
        )
        traktListInput = ""
        traktListName = ""
        traktListError = nil
    }

    private func parseTraktList(from input: String) -> ParsedTraktList? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let components = URLComponents(string: trimmed),
           let parsed = parseTraktUserSlugPath(components.path) {
            return parsed
        }

        if let parsed = parseTraktUserSlugPath(trimmed) {
            return parsed
        }

        let numericId = trimmed
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
            .last
        return numericId.map { ParsedTraktList(id: $0, user: nil, slug: nil) }
    }

    private func parseTraktUserSlugPath(_ path: String) -> ParsedTraktList? {
        let parts = path
            .split(separator: "/")
            .map(String.init)

        guard let usersIndex = parts.firstIndex(where: { $0.lowercased() == "users" }),
              usersIndex + 3 < parts.count,
              parts[usersIndex + 2].lowercased() == "lists" else {
            return nil
        }

        let user = parts[usersIndex + 1]
        let slug = parts[usersIndex + 3]
        guard !user.isEmpty, !slug.isEmpty else { return nil }
        return ParsedTraktList(id: nil, user: user, slug: slug)
    }

    private struct ParsedTraktList {
        let id: Int?
        let user: String?
        let slug: String?
    }

    @ViewBuilder
    private func trackerRow(
        service: TrackerService,
        isConnected: Bool,
        username: String?,
        onConnect: @escaping () -> Void,
        onDisconnect: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if let logoURL = service.logoURL {
                    KFImage(logoURL)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 40, height: 40)
                        .cornerRadius(8)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(service.displayName)
                        .font(.headline)
                        .foregroundColor(.white)

                    if let username = username {
                        Text(username)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if isConnected {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)

                        Button(action: onDisconnect) {
                            Text("Disconnect")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                } else {
                    Button(action: onConnect) {
                        Text("Connect")
                            .font(.caption)
                            .foregroundColor(.blue)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.blue.opacity(0.2))
                            .cornerRadius(6)
                    }
                }
            }
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }

    private var aniListImportConfirmationMessage: String {
#if os(tvOS)
        "This will import your AniList anime lists as Eclipse collections and fill local watched progress without deleting or downgrading anything."
#else
        "This will import your AniList lists as Eclipse collections and fill local watch/read progress without deleting or downgrading anything."
#endif
    }

    private var malImportConfirmationMessage: String {
#if os(tvOS)
        "This will import your MAL anime lists as Eclipse collections and fill local watched progress without deleting or downgrading anything."
#else
        "This will import your MAL lists as Eclipse collections and fill local watch/read progress without deleting or downgrading anything."
#endif
    }

    private var malImportDescription: String {
#if os(tvOS)
        "Import MAL anime lists as Eclipse collections and watched progress"
#else
        "Import MAL lists as Eclipse collections and reader progress"
#endif
    }
}

private struct TrackerSyncToolsSheet: View {
    @ObservedObject var trackerManager: TrackerManager
    @Environment(\.dismiss) private var dismiss
    @State private var confirmationAction: TrackerSyncToolAction?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let status = trackerManager.syncToolStatus {
                        syncStatusCard(status)
                    }

                    ForEach(TrackerSyncToolAction.allCases) { action in
                        syncToolCard(action)
                    }
                }
                .padding()
            }
            .background(SettingsGradientBackground().ignoresSafeArea())
            .navigationTitle("Sync Tools")
            #if !os(tvOS)
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(trackerManager.syncToolIsLocked)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .disabled(trackerManager.syncToolIsLocked)
                }
            }
            .alert("Run Sync Tool?", isPresented: Binding(
                get: { confirmationAction != nil },
                set: { if !$0 { confirmationAction = nil } }
            )) {
                Button("Run", role: .none) {
                    if let action = confirmationAction {
                        trackerManager.runSyncTool(action)
                    }
                    confirmationAction = nil
                }
                Button("Cancel", role: .cancel) {
                    confirmationAction = nil
                }
            } message: {
                Text("This writes progress to the selected destination but never deletes entries or downgrades progress.")
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    @ViewBuilder
    private func syncStatusCard(_ status: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if trackerManager.isRunningSyncTool {
                    EclipseLoadingIndicator(tint: .white)
                }

                Text(status)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                if trackerManager.isRunningSyncTool {
                    Button(role: .destructive) {
                        trackerManager.cancelSyncTool()
                    } label: {
                        Label("Cancel", systemImage: "xmark.circle")
                    }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
            }

            if trackerManager.syncToolProgressTotal > 0 {
                ProgressView(
                    value: Double(trackerManager.syncToolProgressCompleted),
                    total: Double(max(trackerManager.syncToolProgressTotal, 1))
                )
                .tint(.blue)

                HStack {
                    Text("\(trackerManager.syncToolProgressCompleted) / \(trackerManager.syncToolProgressTotal)")
                    Spacer()
                    if trackerManager.syncToolIsLocked {
                        Text("Stay here while this large sync runs")
                    }
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }

            if let detail = trackerManager.syncToolProgressDetail {
                Text(detail)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.12))
        .cornerRadius(12)
    }

    @ViewBuilder
    private func syncToolCard(_ action: TrackerSyncToolAction) -> some View {
        let preview = trackerManager.syncToolPreview?.action == action ? trackerManager.syncToolPreview : nil

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: action.isProviderPort ? "arrow.left.arrow.right.circle.fill" : "tray.and.arrow.down.fill")
                    .foregroundColor(action.isProviderPort ? .orange : .blue)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 4) {
                    Text(action.title)
                        .font(.headline)
                        .foregroundColor(.white)

                    Text(action.subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }

            if let preview {
                VStack(alignment: .leading, spacing: 6) {
                    previewMetric("Add", preview.itemsToAdd)
                    previewMetric("Advance", preview.itemsToAdvance)
                    previewMetric("Skipped", preview.skipped)
                    previewMetric("Unmapped", preview.unmapped)
                    previewMetric("API calls", preview.estimatedAPICalls)

                    if preview.estimatedAPICalls >= 90 {
                        Label("Large sync: Eclipse will show progress, honor rate limits, and keep this sheet open until it finishes or you cancel.", systemImage: "hourglass")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }

                    ForEach(preview.notes, id: \.self) { note in
                        Text(note)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(10)
                .background(Color.black.opacity(0.18))
                .cornerRadius(8)
            }

            HStack {
                Button("Preview") {
                    trackerManager.previewSyncTool(action)
                }
                .disabled(trackerManager.isRunningSyncTool)

                Spacer()

                Button(action.isProviderPort ? "Confirm & Run" : "Run") {
                    if action.isProviderPort {
                        confirmationAction = action
                    } else {
                        trackerManager.runSyncTool(action)
                    }
                }
                .disabled(trackerManager.isRunningSyncTool || preview == nil)
            }
            .font(.caption.weight(.medium))
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
    }

    @ViewBuilder
    private func previewMetric(_ title: String, _ value: Int) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.secondary)
            Spacer()
            Text("\(value)")
                .foregroundColor(.white)
        }
        .font(.caption2)
    }
}
