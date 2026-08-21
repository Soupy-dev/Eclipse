import SwiftUI
import AVKit
import Kingfisher

struct DownloadsView: View {
    @StateObject private var downloadManager = DownloadManager.shared
    @StateObject private var progressManager = ProgressManager.shared

    @ObservedObject private var contentFilter = TMDBContentFilter.shared
    @State private var showingDeleteAllConfirmation = false
    @State private var showingDeleteCompletedConfirmation = false
    @State private var showingDeleteSeriesConfirmation = false
    @State private var seriesToDelete: (tmdbId: Int, title: String)? = nil
    @State private var selectedTab: DownloadsTab = .downloads
#if os(iOS)
    @Environment(\.eclipseWindowSceneSessionIdentifier) private var presentationSceneIdentifier
#endif

    private enum DownloadsTab: String, CaseIterable {
        case downloads = "Downloads"
        case library = "Library"
    }

    @State private var kidsBlockedDownloads: Set<DownloadIdentity> = []

    @State private var kidsFilterResolved = false

    @State private var kidsFilterTask: Task<Void, Never>?

    private var downloadIdentities: Set<DownloadIdentity> {
        Set(downloadManager.downloads.map { DownloadIdentity(isMovie: $0.isMovie, id: $0.tmdbId) })
    }

    private func visibleToProfile(_ items: [DownloadItem]) -> [DownloadItem] {
        guard ProfileManager.shared.isKidsModeActive else { return items }
        guard kidsFilterResolved else { return [] }
        return items.filter {
            !kidsBlockedDownloads.contains(DownloadIdentity(isMovie: $0.isMovie, id: $0.tmdbId))
        }
    }

    private func refreshKidsDownloadFilter() {
        kidsFilterTask?.cancel()
        guard ProfileManager.shared.isKidsModeActive else {
            kidsBlockedDownloads = []
            kidsFilterResolved = true
            return
        }
        kidsFilterResolved = false

        var representatives: [DownloadIdentity: DownloadItem] = [:]
        for item in downloadManager.downloads {
            let identity = DownloadIdentity(isMovie: item.isMovie, id: item.tmdbId)
            if let existing = representatives[identity], existing.kidsPolicyDetails != nil { continue }
            if representatives[identity] == nil || item.kidsPolicyDetails != nil {
                representatives[identity] = item
            }
        }

        let initiatingProfileID = ProfileManager.shared.activeProfileID
        kidsFilterTask = Task { @MainActor in
            await TMDBMaturityRatingStore.shared.resolve(representatives.keys.map { (isMovie: $0.isMovie, id: $0.id) })

            var blocked: Set<DownloadIdentity> = []
            for (identity, item) in representatives {
                guard !Task.isCancelled else { return }
                let allowed = await TMDBContentFilter.shared.kidsPolicyAllowsPlayback(
                    isMovie: identity.isMovie,
                    id: identity.id,
                    title: item.playerTitleBase,
                    persistedDetails: item.kidsPolicyDetails
                )
                if !allowed { blocked.insert(identity) }
            }
            guard !Task.isCancelled,
                  ProfileManager.shared.activeProfileID == initiatingProfileID else { return }
            kidsBlockedDownloads = blocked
            kidsFilterResolved = true
        }
    }

    private struct DownloadIdentity: Hashable {
        let isMovie: Bool
        let id: Int
    }

    private var activeDownloads: [DownloadItem] {
        visibleToProfile(downloadManager.downloads.filter { $0.status == .downloading || $0.status == .queued || $0.status == .paused })
    }

    private var completedDownloads: [DownloadItem] {
        visibleToProfile(downloadManager.downloads.filter { $0.status == .completed })
    }

    private var failedDownloads: [DownloadItem] {
        visibleToProfile(downloadManager.downloads.filter { $0.status == .failed })
    }

    var body: some View {
        Group {
            if #available(iOS 16.0, *) {
                NavigationStack {
                    downloadsContent
                }
            } else {
                NavigationView {
                    downloadsContent
                }
                .navigationViewStyle(StackNavigationViewStyle())
            }
        }
        .onAppear { refreshKidsDownloadFilter() }
        .onDisappear { kidsFilterTask?.cancel() }
        .onChangeComp(of: downloadIdentities) { _, _ in refreshKidsDownloadFilter() }
        .onChangeComp(of: contentFilter.isKidsProfileActive) { _, _ in refreshKidsDownloadFilter() }
        .onChangeComp(of: contentFilter.maturityRatingRevision) { _, _ in refreshKidsDownloadFilter() }

        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in
            refreshKidsDownloadFilter()
        }
    }

    private var downloadsContent: some View {
        Group {
            if downloadManager.downloads.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    Picker("View", selection: $selectedTab) {
                        ForEach(DownloadsTab.allCases, id: \.self) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 8)

                    switch selectedTab {
                    case .downloads:
                        downloadsList
                    case .library:
                        libraryView
                    }
                }
            }
        }
        .navigationTitle("Downloads")
        .background(SettingsGradientBackground().ignoresSafeArea())
#if os(iOS)
        .navigationBarTitleDisplayMode(.large)
#endif
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !downloadManager.downloads.isEmpty, !ProfileManager.shared.isKidsModeActive {
                    managementMenu
                }
            }
        }
        .adaptiveConfirmationDialog("Delete All Downloads", isPresented: $showingDeleteAllConfirmation, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) {
                downloadManager.deleteAll()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will cancel all active downloads and remove all downloaded files. This action cannot be undone.")
        }
        .adaptiveConfirmationDialog("Delete Completed", isPresented: $showingDeleteCompletedConfirmation, titleVisibility: .visible) {
            Button("Delete Completed", role: .destructive) {
                downloadManager.deleteAllCompleted()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will remove all completed download files. This action cannot be undone.")
        }
        .adaptiveConfirmationDialog(
            "Delete \(seriesToDelete?.title ?? "Series")",
            isPresented: $showingDeleteSeriesConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All Downloads", role: .destructive) {
                if let tmdbId = seriesToDelete?.tmdbId {
                    downloadManager.deleteAllForShow(tmdbId: tmdbId)
                }
                seriesToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                seriesToDelete = nil
            }
        } message: {
            Text("This will remove all downloaded episodes for \(seriesToDelete?.title ?? "this series"). This action cannot be undone.")
        }
    }

    private var emptyState: some View {
        EclipseEmptyState(
            icon: "arrow.down.circle",
            title: "No Downloads",
            message: "Download movies and episodes to watch offline. Use the download button on any media page."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var downloadsList: some View {
        if activeDownloads.isEmpty && failedDownloads.isEmpty {
            EclipseEmptyState(
                icon: "checkmark.circle",
                title: "No Active Downloads",
                message: "Completed downloads can be found in the Library tab."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
            if !activeDownloads.isEmpty {
                Section {
                    ForEach(activeDownloads) { item in
                        activeDownloadRow(item)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowBackground(Color.clear)
#if os(iOS)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    downloadManager.cancelDownload(id: item.id)
                                } label: {
                                    Label("Cancel", systemImage: "xmark.circle")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                if item.status == .downloading {
                                    Button {
                                        downloadManager.pauseDownload(id: item.id)
                                    } label: {
                                        Label("Pause", systemImage: "pause.circle")
                                    }
                                    .tint(.orange)
                                } else if item.status == .paused {
                                    Button {
                                        downloadManager.resumeDownload(id: item.id)
                                    } label: {
                                        Label("Resume", systemImage: "play.circle")
                                    }
                                    .tint(.green)
                                }
                            }
#endif
                    }
                } header: {
                    sectionHeader("Active", count: activeDownloads.count)
                }
            }

            if !failedDownloads.isEmpty {
                Section {
                    ForEach(failedDownloads) { item in
                        failedDownloadRow(item)
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowBackground(Color.clear)
#if os(iOS)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    downloadManager.removeDownload(id: item.id, deleteFile: true)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    downloadManager.resumeDownload(id: item.id)
                                } label: {
                                    Label("Retry", systemImage: "arrow.clockwise")
                                }
                                .tint(.orange)
                            }
#endif
                    }
                } header: {
                    sectionHeader("Failed", count: failedDownloads.count)
                }
            }

            Section {
                storageFooter
                    .listRowBackground(Color.clear)
            }
        }
            .listStyle(.plain)
            .eclipseHideScrollBackground()
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        EclipseSectionHeader(title: title, count: count)
            .padding(.horizontal)
            .padding(.top, 16)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private func statusBadge(for status: DownloadStatus) -> some View {
        switch status {
        case .downloading:
            EclipseStatusBadge(text: "Downloading", systemImage: "arrow.down", tint: .blue)
        case .queued:
            EclipseStatusBadge(text: "Queued", systemImage: "clock", tint: .orange)
        case .paused:
            EclipseStatusBadge(text: "Paused", systemImage: "pause.fill", tint: .gray)
        case .failed:
            EclipseStatusBadge(text: "Failed", systemImage: "exclamationmark.triangle.fill", tint: .red)
        case .completed:
            EclipseStatusBadge(text: "Completed", systemImage: "checkmark", tint: .green)
        }
    }

    private func activeDownloadRow(_ item: DownloadItem) -> some View {
        HStack(spacing: 12) {
            posterImage(url: item.posterURL)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.displayTitle)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .foregroundColor(.white)

                statusBadge(for: item.status)

                if item.status == .downloading || item.status == .paused {
                    ProgressView(value: item.progress)
                        .tint(item.status == .paused ? Color.gray : Color.blue)

                    HStack {
                        Text("\(Int(item.progress * 100))%")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.7))

                        Spacer()

                        Text(item.formattedSize)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else if item.status == .queued, let detail = item.error, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            downloadActionButtons(item)
        }
        .padding(12)
        .glassCard(cornerRadius: 16)
        .contextMenu {
            if item.status == .downloading {
                Button(action: { downloadManager.pauseDownload(id: item.id) }) {
                    Label("Pause", systemImage: "pause.circle")
                }
            }
            if item.status == .paused {
                Button(action: { downloadManager.resumeDownload(id: item.id) }) {
                    Label("Resume", systemImage: "play.circle")
                }
            }
            Button(role: .destructive, action: { downloadManager.cancelDownload(id: item.id) }) {
                Label("Cancel", systemImage: "xmark.circle")
            }
        }
    }

    private func downloadActionButtons(_ item: DownloadItem) -> some View {
        HStack(spacing: 4) {

            Button(action: {
                switch item.status {
                case .downloading:
                    downloadManager.pauseDownload(id: item.id)
                case .paused:
                    downloadManager.resumeDownload(id: item.id)
                default:
                    break
                }
            }) {
                Image(systemName: actionIcon(for: item.status))
                    .font(.title3)
                    .foregroundColor(actionColor(for: item.status))
                    .frame(width: 32, height: 32)
            }

            .buttonStyle(.borderless)
            .disabled(item.status == .queued)

            Button(action: {
                downloadManager.cancelDownload(id: item.id)
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.red.opacity(0.8))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.borderless)
        }
    }

    private func actionIcon(for status: DownloadStatus) -> String {
        switch status {
        case .downloading: return "pause.circle.fill"
        case .paused: return "play.circle.fill"
        case .queued: return "xmark.circle"
        default: return "circle"
        }
    }

    private func actionColor(for status: DownloadStatus) -> Color {
        switch status {
        case .downloading: return .blue
        case .paused: return .green
        case .queued: return .orange
        default: return .secondary
        }
    }

    private func failedDownloadRow(_ item: DownloadItem) -> some View {
        HStack(spacing: 12) {
            posterImage(url: item.posterURL)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.displayTitle)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .foregroundColor(.white)

                statusBadge(for: .failed)

                Text(item.error ?? "Unknown error")
                    .font(.caption)
                    .foregroundColor(.red.opacity(0.85))
                    .lineLimit(2)
            }

            Spacer()

            Button(action: {
                downloadManager.resumeDownload(id: item.id)
            }) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.title2)
                    .foregroundColor(.orange)
                    .frame(width: 36, height: 36)
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 16)
        .contextMenu {
            Button(action: { downloadManager.resumeDownload(id: item.id) }) {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive, action: { downloadManager.removeDownload(id: item.id, deleteFile: true) }) {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private func completedDownloadRow(_ item: DownloadItem) -> some View {
        let isWatched = item.isMovie && movieIsWatched(item)

        return Button(action: {
            playDownloadedItem(item)
        }) {
            HStack(spacing: 12) {
                posterImage(url: item.posterURL)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displayTitle)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                        .foregroundColor(.white)

                    if !item.isMovie, let ep = item.episodeNumber, let sn = item.seasonNumber {
                        Text("S\(sn)E\(ep)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text(DownloadByteCountFormatter.string(fromByteCount: item.totalBytes))
                            .font(.caption2)
                            .foregroundColor(.secondary)

                        if let date = item.dateCompleted {
                            Text("•")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text(Self.completedDateString(from: date))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }

                        if isWatched {
                            Text("•")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("Watched")
                                .font(.caption2)
                                .foregroundColor(.blue)
                        }
                    }
                }

                Spacer()

                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .padding(10)
        .applyLiquidGlassBackground(cornerRadius: 16)
        .contextMenu {
            Button(action: { playDownloadedItem(item) }) {
                Label("Play", systemImage: "play.fill")
            }
            if item.isMovie {
                if isWatched {
                    Button(action: { markMovieAsUnwatched(item) }) {
                        Label("Mark as Not Watched", systemImage: "eye.slash")
                    }
                } else {
                    Button(action: { markMovieAsWatched(item) }) {
                        Label("Mark as Watched", systemImage: "checkmark.circle")
                    }
                }
            }
#if os(iOS)
            if downloadManager.localFileURL(for: item) != nil {
                Button(action: { shareDownloadedItem(item) }) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
#endif
            Button(role: .destructive, action: { downloadManager.removeDownload(id: item.id, deleteFile: true) }) {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private func posterImage(url: String?) -> some View {
        KFImage(URL(string: url ?? ""))
            .placeholder {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        Image(systemName: "film")
                            .font(.title3)
                            .foregroundColor(.white.opacity(0.4))
                    )
            }
            .resizable()
            .aspectRatio(2/3, contentMode: .fill)
            .frame(width: 60 * iPadScaleSmall, height: 90 * iPadScaleSmall)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
    }

    private struct ShowGroup: Identifiable {
        let id: Int
        let title: String
        let posterURL: String?
        let isMovie: Bool
        var seasons: [SeasonGroup]
    }

    private struct SeasonGroup: Identifiable {
        var id: Int { seasonNumber }
        let seasonNumber: Int
        var episodes: [DownloadItem]
    }

    private var groupedDownloads: [ShowGroup] {
        var showMap: [Int: ShowGroup] = [:]

        for item in completedDownloads {
            if showMap[item.tmdbId] == nil {
                showMap[item.tmdbId] = ShowGroup(
                    id: item.tmdbId,
                    title: item.title,
                    posterURL: item.posterURL,
                    isMovie: item.isMovie,
                    seasons: []
                )
            }

            let seasonNum = item.seasonNumber ?? 0
            if let index = showMap[item.tmdbId]?.seasons.firstIndex(where: { $0.seasonNumber == seasonNum }) {
                showMap[item.tmdbId]?.seasons[index].episodes.append(item)
            } else {
                showMap[item.tmdbId]?.seasons.append(SeasonGroup(seasonNumber: seasonNum, episodes: [item]))
            }
        }

        return showMap.values
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            .map { group in
                var g = group
                g.seasons = g.seasons
                    .sorted { $0.seasonNumber < $1.seasonNumber }
                    .map { season in
                        var s = season
                        s.episodes.sort { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) }
                        return s
                    }
                return g
            }
    }

    private var libraryView: some View {
        Group {
            if completedDownloads.isEmpty {
                EclipseEmptyState(
                    icon: "rectangle.stack",
                    title: "No Downloaded Content",
                    message: "Completed downloads will appear here grouped by show and season."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groupedDownloads) { show in
                        if show.isMovie {

                            if let item = show.seasons.first?.episodes.first {
                                completedDownloadRow(item)
                                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                    .listRowBackground(Color.clear)
                            }
                        } else {

                            NavigationLink(destination: DownloadedShowDetailView(
                                showTitle: show.title,
                                tmdbId: show.id,
                                posterURL: show.posterURL,
                                seasons: show.seasons.map { season in
                                    DownloadedShowDetailView.DownloadedSeasonGroup(
                                        seasonNumber: season.seasonNumber,
                                        episodes: season.episodes
                                    )
                                }
                            )) {
                                HStack(spacing: 12) {
                                    posterImage(url: show.posterURL)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(show.title)
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.white)
                                            .lineLimit(2)

                                        let totalEps = show.seasons.reduce(0) { $0 + $1.episodes.count }
                                        Text("\(totalEps) episode\(totalEps == 1 ? "" : "s")")
                                            .font(.caption)
                                            .foregroundColor(.secondary)

                                        let watchedCount = show.seasons.flatMap(\.episodes).filter {
                                            ProgressManager.shared.isEpisodeWatched(
                                                showId: $0.tmdbId,
                                                seasonNumber: $0.seasonNumber ?? 1,
                                                episodeNumber: $0.episodeNumber ?? 1
                                            )
                                        }.count
                                        if watchedCount > 0 {
                                            HStack(spacing: 3) {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .font(.caption2)
                                                    .foregroundColor(.blue)
                                                Text("\(watchedCount)/\(totalEps) watched")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                    }

                                    Spacer()

                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                Button(role: .destructive) {
                                    seriesToDelete = (tmdbId: show.id, title: show.title)
                                    showingDeleteSeriesConfirmation = true
                                } label: {
                                    Label("Delete All Downloads", systemImage: "trash")
                                }
                            }
                        }
                    }

                    Section {
                        storageFooter
                            .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func libraryEpisodeRow(_ item: DownloadItem) -> some View {
        Button(action: { playDownloadedItem(item) }) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    if let ep = item.episodeNumber {
                        Text("Episode \(ep)")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                    }

                    if let name = item.episodeName, !name.isEmpty {
                        Text(name)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }

                    Text(DownloadByteCountFormatter.string(fromByteCount: item.totalBytes))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundColor(.white)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .contextMenu {
            Button(action: { playDownloadedItem(item) }) {
                Label("Play", systemImage: "play.fill")
            }
            Button(role: .destructive, action: { downloadManager.removeDownload(id: item.id, deleteFile: true) }) {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var managementMenu: some View {
        Menu {
            if activeDownloads.contains(where: { $0.status == .downloading || $0.status == .queued }) {
                Button(action: { downloadManager.pauseAll() }) {
                    Label("Pause All", systemImage: "pause.circle")
                }
            }

            if activeDownloads.contains(where: { $0.status == .paused }) {
                Button(action: { downloadManager.resumeAll() }) {
                    Label("Resume All", systemImage: "play.circle")
                }
            }

            if !failedDownloads.isEmpty {
                Button(action: { downloadManager.retryAllFailed() }) {
                    Label("Retry Failed", systemImage: "arrow.clockwise")
                }
            }

            if !activeDownloads.isEmpty {
                Button(role: .destructive, action: { downloadManager.cancelAllActive() }) {
                    Label("Cancel All Active", systemImage: "xmark.circle")
                }
            }

            Divider()

            if !completedDownloads.isEmpty {
                Button(role: .destructive, action: { showingDeleteCompletedConfirmation = true }) {
                    Label("Delete Completed", systemImage: "trash")
                }
            }

            Button(role: .destructive, action: { showingDeleteAllConfirmation = true }) {
                Label("Delete All", systemImage: "trash.fill")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private var storageFooter: some View {
        let storageUsed = downloadManager.calculateStorageUsed()

        return VStack(spacing: 4) {
            Text("Storage Used: \(DownloadByteCountFormatter.string(fromByteCount: storageUsed))")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("\(completedDownloads.count) downloaded • \(activeDownloads.count) active")
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
    }

    private static func completedDateString(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "Just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func movieIsWatched(_ item: DownloadItem) -> Bool {
        progressManager.isMovieWatched(movieId: item.tmdbId)
    }

    private func markMovieAsWatched(_ item: DownloadItem) {
        progressManager.markMovieAsWatched(
            movieId: item.tmdbId,
            title: item.playerTitleBase,
            posterURL: item.posterURL
        )
    }

    private func markMovieAsUnwatched(_ item: DownloadItem) {
        progressManager.markMovieAsUnwatched(
            movieId: item.tmdbId,
            title: item.playerTitleBase,
            posterURL: item.posterURL
        )
    }

    private func shareDownloadedItem(_ item: DownloadItem) {
#if os(iOS)
        guard let fileURL = downloadManager.localFileURL(for: item) else { return }
        let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        if let topmostVC = downloadPresentationController() {
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = topmostVC.view
                popover.sourceRect = CGRect(
                    x: topmostVC.view.bounds.midX,
                    y: topmostVC.view.bounds.midY,
                    width: 1,
                    height: 1
                )
                popover.permittedArrowDirections = []
            }
            topmostVC.present(activityVC, animated: true)
        }
#endif
    }

    private func playDownloadedItem(
        _ item: DownloadItem,
        from presenter: UIViewController? = nil,
        canonicalPlaybackContext: EpisodePlaybackContext? = nil
    ) {
        guard let fileURL = downloadManager.localFileURL(for: item) else {
            Logger.shared.log("Downloaded file not found for: \(item.id)", type: "Download")
            return
        }

        guard let originatingPresenter = downloadPresentationController(explicit: presenter) else {
            Logger.shared.log("Downloaded playback has no presenter", type: "Player")
            return
        }
        let subtitles = downloadManager.localSubtitleURL(for: item).map { [$0.absoluteString] } ?? []
        let effectiveContext = canonicalPlaybackContext ?? item.episodePlaybackContext
        let isAnimeEpisode = !item.isMovie
            && (item.isAnime || effectiveContext?.hasAnimeMediaId == true)
        let effectiveMediaInfo: MediaInfo = {
            guard !item.isMovie, let effectiveContext else { return item.mediaInfo }
            return .episode(
                showId: item.tmdbId,
                seasonNumber: effectiveContext.localSeasonNumber,
                episodeNumber: effectiveContext.localEpisodeNumber,
                showTitle: item.playerTitleBase,
                showPosterURL: item.posterURL,
                isAnime: isAnimeEpisode
            )
        }()
        let nextEpisodeRequest: ((_ seasonNumber: Int, _ episodeNumber: Int) -> Void)? = item.isMovie || isAnimeEpisode ? nil : { [weak originatingPresenter] seasonNumber, episodeNumber in
            guard let originatingPresenter else { return }
            guard let nextItem = nextDownloadedEpisode(
                for: item.tmdbId,
                requestedSeasonNumber: seasonNumber,
                requestedEpisodeNumber: episodeNumber,
                currentItemId: item.id,
                allowNextAvailableFallback: false
            ) else {
                Logger.shared.log("NextEpisode: No downloaded next episode found for tmdbId=\(item.tmdbId) after \(item.id)", type: "Player")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.playDownloadedItem(nextItem, from: originatingPresenter)
            }
        }
        let resolvedNextEpisodeRequest: ((ResolvedNextEpisodeTarget) -> Void)? = isAnimeEpisode ? { [weak originatingPresenter] target in
            guard let originatingPresenter,
                  let nextItem = downloadManager.completedEpisodeDownloadItem(
                    tmdbId: target.showID,
                    seasonNumber: target.episode.seasonNumber,
                    episodeNumber: target.episode.episodeNumber,
                    playbackContext: target.playbackContext
                  ) else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.playDownloadedItem(
                    nextItem,
                    from: originatingPresenter,
                    canonicalPlaybackContext: target.playbackContext
                )
            }
        } : nil
        let localNextEpisode: DownloadItem? = item.isMovie || isAnimeEpisode ? nil : nextDownloadedEpisode(
            for: item.tmdbId,
            requestedSeasonNumber: item.seasonNumber ?? 0,
            requestedEpisodeNumber: (item.episodeNumber ?? 0) + 1,
            currentItemId: item.id
        )
        let request = PlaybackRequest(
            url: fileURL,
            subtitles: subtitles,
            mediaInfo: effectiveMediaInfo,

            kidsPolicyDetails: item.kidsPolicyDetails,
            episodePlaybackContext: effectiveContext,
            title: item.playerTitleBase,
            subtitle: item.displayTitle,
            artworkURL: item.posterURL.flatMap(URL.init(string:)),
            isAnime: isAnimeEpisode,
            originalTMDBSeasonNumber: effectiveContext?.resolvedTMDBSeasonNumber,
            originalTMDBEpisodeNumber: effectiveContext?.resolvedTMDBEpisodeNumber,
            onRequestNextEpisode: nextEpisodeRequest,
            onRequestResolvedNextEpisode: resolvedNextEpisodeRequest,
            localNextEpisodeFallback: PlaybackEpisodeCoordinate(
                seasonNumber: localNextEpisode?.seasonNumber,
                episodeNumber: localNextEpisode?.episodeNumber
            )
        )
        PlaybackCoordinator.shared.present(request, from: originatingPresenter)
    }

    @MainActor
    private func downloadPresentationController(explicit: UIViewController? = nil) -> UIViewController? {
        if let explicit { return explicit }
#if os(iOS)
        return UIApplication.shared.eclipseTopmostViewController(
            forSceneSessionIdentifier: presentationSceneIdentifier
        )
#else
        return UIApplication.shared.eclipseTopmostViewController()
#endif
    }

    private func nextDownloadedEpisode(
        for tmdbId: Int,
        requestedSeasonNumber: Int,
        requestedEpisodeNumber: Int,
        currentItemId: String,
        allowNextAvailableFallback: Bool = true
    ) -> DownloadItem? {
        let episodes = downloadManager.completedDownloads
            .filter {
                !$0.isMovie &&
                $0.tmdbId == tmdbId &&
                $0.seasonNumber != nil &&
                $0.episodeNumber != nil &&
                downloadManager.localFileURL(for: $0) != nil
            }
            .sorted {
                if $0.seasonNumber == $1.seasonNumber {
                    return ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0)
                }
                return ($0.seasonNumber ?? 0) < ($1.seasonNumber ?? 0)
            }

        if let requested = episodes.first(where: {
            $0.seasonNumber == requestedSeasonNumber && $0.episodeNumber == requestedEpisodeNumber
        }) {
            return requested
        }

        guard allowNextAvailableFallback else { return nil }

        guard let currentIndex = episodes.firstIndex(where: { $0.id == currentItemId }) else { return nil }
        let nextIndex = episodes.index(after: currentIndex)
        guard nextIndex < episodes.endIndex else { return nil }
        return episodes[nextIndex]
    }
}
