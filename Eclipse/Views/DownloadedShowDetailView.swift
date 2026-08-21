import SwiftUI
import Kingfisher
import AVKit

struct DownloadedShowDetailView: View {
    let showTitle: String
    let tmdbId: Int
    let posterURL: String?
    let seasons: [DownloadedSeasonGroup]

    @StateObject private var downloadManager = DownloadManager.shared

    @ObservedObject private var contentFilter = TMDBContentFilter.shared
    @State private var showingDeleteConfirmation = false
    @State private var itemToDelete: DownloadItem?

    @State private var kidsAccessResolved = false
    @State private var kidsBlocked = false
    @State private var kidsFilterTask: Task<Void, Never>?
#if os(iOS)
    @Environment(\.eclipseWindowSceneSessionIdentifier) private var presentationSceneIdentifier
#endif

    struct DownloadedSeasonGroup: Identifiable {
        var id: Int { seasonNumber }
        let seasonNumber: Int
        var episodes: [DownloadItem]
    }

    var body: some View {
        Group {
            if contentFilter.isKidsProfileActive && (kidsBlocked || !kidsAccessResolved) {
                kidsGateStatus(isResolving: !kidsAccessResolved)
            } else {
                ScrollView {
                    VStack(spacing: 0) {

                        headerView

                        VStack(spacing: 16) {
                            ForEach(seasons) { season in
                                seasonSection(season)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 32)
                    }
                }
            }
        }
        .navigationTitle(showTitle)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .background(SettingsGradientBackground(allowsAnimatedBackground: false).ignoresSafeArea())
        .onAppear { refreshKidsAccess() }
        .onDisappear {
            kidsFilterTask?.cancel()
            kidsFilterTask = nil
        }
        .onChangeComp(of: contentFilter.isKidsProfileActive) { _, _ in refreshKidsAccess() }
        .onChangeComp(of: contentFilter.maturityRatingRevision) { _, _ in refreshKidsAccess() }

        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in
            refreshKidsAccess()
        }
        .adaptiveConfirmationDialog(
            "Delete Episode",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            if let item = itemToDelete {
                Button("Delete", role: .destructive) {
                    downloadManager.removeDownload(id: item.id, deleteFile: true)
                }
            }
            Button("Cancel", role: .cancel) {
                itemToDelete = nil
            }
        } message: {
            Text("This downloaded episode will be permanently removed.")
        }
    }

    @ViewBuilder
    private func kidsGateStatus(isResolving: Bool) -> some View {
        VStack(spacing: 16) {
            if isResolving {
                EclipseLoadingIndicator()
                    .scaleEffect(1.5)
                Text("Checking this title...")
                    .font(.callout)
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: "lock.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                Text("Not available on this profile")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func refreshKidsAccess() {
        kidsFilterTask?.cancel()
        guard ProfileManager.shared.isKidsModeActive else {
            kidsBlocked = false
            kidsAccessResolved = true
            return
        }
        kidsAccessResolved = false

        let persistedDetails = seasons.flatMap(\.episodes).compactMap(\.kidsPolicyDetails).first

        let initiatingProfileID = ProfileManager.shared.activeProfileID
        kidsFilterTask = Task { @MainActor in
            let allowed = await TMDBContentFilter.shared.kidsPolicyAllowsPlayback(
                isMovie: false,
                id: tmdbId,
                title: showTitle,
                persistedDetails: persistedDetails
            )
            guard !Task.isCancelled,
                  ProfileManager.shared.activeProfileID == initiatingProfileID else { return }
            kidsBlocked = !allowed
            kidsAccessResolved = true
        }
    }

    private var headerView: some View {
        HStack(spacing: 16) {
            KFImage(URL(string: posterURL ?? ""))
                .placeholder {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.3))
                        .overlay(
                            Image(systemName: "film")
                                .font(.largeTitle)
                                .foregroundColor(.gray)
                        )
                }
                .resizable()
                .aspectRatio(2/3, contentMode: .fill)
                .frame(width: 120 * iPadScaleSmall, height: 180 * iPadScaleSmall)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 8)

            VStack(alignment: .leading, spacing: 8) {
                Text(showTitle)
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .lineLimit(3)

                let totalEps = seasons.reduce(0) { $0 + $1.episodes.count }
                let totalSeasons = seasons.count

                Text("\(totalSeasons) season\(totalSeasons == 1 ? "" : "s") • \(totalEps) episode\(totalEps == 1 ? "" : "s")")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                let totalSize = seasons.flatMap(\.episodes).reduce(Int64(0)) { $0 + $1.totalBytes }
                Text(DownloadByteCountFormatter.string(fromByteCount: totalSize))
                    .font(.caption)
                    .foregroundColor(.secondary)

                let watchedCount = seasons.flatMap(\.episodes).filter { episodeIsWatched($0) }.count
                if watchedCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundColor(.blue)
                        Text("\(watchedCount)/\(totalEps) watched")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(16)
    }

    private func seasonSection(_ season: DownloadedSeasonGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if seasons.count > 1 {
                Text("Season \(season.seasonNumber)")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.leading, 4)
            }

            ForEach(season.episodes) { item in
                episodeCard(item)
            }
        }
    }

    private func episodeCard(_ item: DownloadItem) -> some View {
        let isWatched = episodeIsWatched(item)
        let progress = episodeProgress(item)

        return ZStack(alignment: .trailing) {
            Button(action: { playDownloadedItem(item) }) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {

                        ZStack {
                            Circle()
                                .fill(isWatched ? Color.blue : Color.gray.opacity(0.3))
                                .frame(width: 36, height: 36)

                            if isWatched {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                            } else {
                                Text("\(item.episodeNumber ?? 0)")
                                    .font(.system(size: 14, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                            }
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Episode \(item.episodeNumber ?? 0)")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.white)

                            if let name = item.episodeName, !name.isEmpty {
                                Text(name)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            episodeMetadata(item, isWatched: isWatched, progress: progress)
                        }

                        Spacer()

                        HStack(spacing: 12) {
                            Image(systemName: "play.circle.fill")
                                .font(.title3)
                                .foregroundColor(.white)

                            Color.clear
                                .frame(width: 32, height: 36)
                        }
                    }

                    if progress > 0 && !isWatched {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.15))
                                    .frame(height: 3)

                                Capsule()
                                    .fill(Color.blue)
                                    .frame(width: geo.size.width * CGFloat(progress), height: 3)
                            }
                        }
                        .frame(height: 3)
                        .padding(.top, 8)
                    }
                }
                .padding(12)
                .applyLiquidGlassBackground(cornerRadius: 12)
            }
            .buttonStyle(PlainButtonStyle())

            Button(action: {
                itemToDelete = item
                showingDeleteConfirmation = true
            }) {
                Image(systemName: "trash")
                    .font(.subheadline)
                    .foregroundColor(.red.opacity(0.8))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.trailing, 4)
        }
        .contextMenu {
            Button(action: { playDownloadedItem(item) }) {
                Label("Play", systemImage: "play.fill")
            }

            if isWatched {
                Button(action: { markAsUnwatched(item) }) {
                    Label("Mark as Unwatched", systemImage: "eye.slash")
                }
            } else {
                Button(action: { markAsWatched(item) }) {
                    Label("Mark as Watched", systemImage: "eye")
                }
            }

#if os(iOS)
            if downloadManager.localFileURL(for: item) != nil {
                Button(action: { shareItem(item) }) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
#endif

            Button(role: .destructive, action: {
                itemToDelete = item
                showingDeleteConfirmation = true
            }) {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func episodeMetadata(_ item: DownloadItem, isWatched: Bool, progress: Double) -> some View {
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, *) {
            ViewThatFits(in: .horizontal) {
                inlineEpisodeMetadata(item, isWatched: isWatched, progress: progress)
                stackedEpisodeMetadata(item, isWatched: isWatched, progress: progress)
            }
        } else {

            stackedEpisodeMetadata(item, isWatched: isWatched, progress: progress)
        }
    }

    @ViewBuilder
    private func inlineEpisodeMetadata(_ item: DownloadItem, isWatched: Bool, progress: Double) -> some View {
        HStack(spacing: 6) {
            Text(DownloadByteCountFormatter.string(fromByteCount: item.totalBytes))
                .fixedSize(horizontal: true, vertical: false)

            if isWatched {
                Text("• Watched")
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundColor(.blue)
            } else if progress > 0 {
                Text("• \(Int(progress * 100))%")
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .font(.caption2)
        .foregroundColor(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder
    private func stackedEpisodeMetadata(_ item: DownloadItem, isWatched: Bool, progress: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(DownloadByteCountFormatter.string(fromByteCount: item.totalBytes))

            if isWatched {
                Text("Watched")
                    .foregroundColor(.blue)
            } else if progress > 0 {
                Text("\(Int(progress * 100))%")
            }
        }
        .font(.caption2)
        .foregroundColor(.secondary)
        .lineLimit(1)
    }

    private func episodeIsWatched(_ item: DownloadItem) -> Bool {
        let item = currentDownloadItem(item)
        return ProgressManager.shared.isEpisodeWatched(
            showId: item.tmdbId,
            seasonNumber: item.seasonNumber ?? 1,
            episodeNumber: item.episodeNumber ?? 1
        )
    }

    private func episodeProgress(_ item: DownloadItem) -> Double {
        let item = currentDownloadItem(item)
        return ProgressManager.shared.getEpisodeProgress(
            showId: item.tmdbId,
            seasonNumber: item.seasonNumber ?? 1,
            episodeNumber: item.episodeNumber ?? 1
        )
    }

    private func markAsWatched(_ item: DownloadItem) {
        let item = currentDownloadItem(item)
        ProgressManager.shared.markEpisodeAsWatched(
            showId: item.tmdbId,
            seasonNumber: item.seasonNumber ?? 1,
            episodeNumber: item.episodeNumber ?? 1,
            playbackContext: item.episodePlaybackContext,
            isAnime: item.isAnime
        )
    }

    private func markAsUnwatched(_ item: DownloadItem) {
        let item = currentDownloadItem(item)
        ProgressManager.shared.markEpisodeAsUnwatched(
            showId: item.tmdbId,
            seasonNumber: item.seasonNumber ?? 1,
            episodeNumber: item.episodeNumber ?? 1
        )
    }

    private func currentDownloadItem(_ item: DownloadItem) -> DownloadItem {
        downloadManager.downloads.first(where: { $0.id == item.id }) ?? item
    }

    private func playDownloadedItem(
        _ originalItem: DownloadItem,
        from presenter: UIViewController? = nil,
        canonicalPlaybackContext: EpisodePlaybackContext? = nil
    ) {
        let item = currentDownloadItem(originalItem)
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

    private func shareItem(_ item: DownloadItem) {
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
}
