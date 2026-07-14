// Full detail page for a downloaded show in the Library tab.

import SwiftUI
import Kingfisher
import AVKit

struct DownloadedShowDetailView: View {
    let showTitle: String
    let tmdbId: Int
    let posterURL: String?
    let seasons: [DownloadedSeasonGroup]
    
    @StateObject private var downloadManager = DownloadManager.shared
    @State private var showingDeleteConfirmation = false
    @State private var itemToDelete: DownloadItem?
#if os(iOS)
    @Environment(\.eclipseWindowSceneSessionIdentifier) private var presentationSceneIdentifier
#endif
    
    struct DownloadedSeasonGroup: Identifiable {
        var id: Int { seasonNumber }
        let seasonNumber: Int
        var episodes: [DownloadItem]
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Hero header with poster
                headerView
                
                // Episode sections
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
        .navigationTitle(showTitle)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .background(SettingsGradientBackground(allowsAnimatedBackground: false).ignoresSafeArea())
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
    
    // MARK: - Header
    
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
                let formatter = ByteCountFormatter()
                Text(formatter.string(fromByteCount: totalSize))
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                // Watched count
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
    
    // MARK: - Season Section
    
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
    
    // MARK: - Episode Card
    
    private func episodeCard(_ item: DownloadItem) -> some View {
        let isWatched = episodeIsWatched(item)
        let progress = episodeProgress(item)
        
        return ZStack(alignment: .trailing) {
            Button(action: { playDownloadedItem(item) }) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        // Episode number badge
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

                            HStack(spacing: 6) {
                                let formatter = ByteCountFormatter()
                                Text(formatter.string(fromByteCount: item.totalBytes))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)

                                if isWatched {
                                    Text("• Watched")
                                        .font(.caption2)
                                        .foregroundColor(.blue)
                                } else if progress > 0 {
                                    Text("• \(Int(progress * 100))%")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        Spacer()

                        // Reserve a separate trailing hit target for Delete. Keeping the two buttons
                        // as siblings avoids a nested Button dispatching both Delete and Play.
                        HStack(spacing: 12) {
                            Image(systemName: "play.circle.fill")
                                .font(.title3)
                                .foregroundColor(.white)

                            Color.clear
                                .frame(width: 32, height: 36)
                        }
                    }

                    // Progress bar (only if partially watched, not fully watched)
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
    
    // MARK: - Progress Helpers
    
    private func episodeIsWatched(_ item: DownloadItem) -> Bool {
        return ProgressManager.shared.isEpisodeWatched(
            showId: item.tmdbId,
            seasonNumber: item.seasonNumber ?? 1,
            episodeNumber: item.episodeNumber ?? 1
        )
    }
    
    private func episodeProgress(_ item: DownloadItem) -> Double {
        return ProgressManager.shared.getEpisodeProgress(
            showId: item.tmdbId,
            seasonNumber: item.seasonNumber ?? 1,
            episodeNumber: item.episodeNumber ?? 1
        )
    }
    
    private func markAsWatched(_ item: DownloadItem) {
        ProgressManager.shared.markEpisodeAsWatched(
            showId: item.tmdbId,
            seasonNumber: item.seasonNumber ?? 1,
            episodeNumber: item.episodeNumber ?? 1,
            playbackContext: item.episodePlaybackContext,
            isAnime: item.isAnime
        )
    }
    
    private func markAsUnwatched(_ item: DownloadItem) {
        ProgressManager.shared.markEpisodeAsUnwatched(
            showId: item.tmdbId,
            seasonNumber: item.seasonNumber ?? 1,
            episodeNumber: item.episodeNumber ?? 1
        )
    }
    
    // MARK: - Playback
    
    private func playDownloadedItem(_ item: DownloadItem, from presenter: UIViewController? = nil) {
        guard let fileURL = downloadManager.localFileURL(for: item) else {
            Logger.shared.log("Downloaded file not found for: \(item.id)", type: "Download")
            return
        }
        
        guard let originatingPresenter = downloadPresentationController(explicit: presenter) else {
            Logger.shared.log("Downloaded playback has no presenter", type: "Player")
            return
        }
        let subtitles = downloadManager.localSubtitleURL(for: item).map { [$0.absoluteString] } ?? []
        let nextEpisodeRequest: ((_ seasonNumber: Int, _ episodeNumber: Int) -> Void)? = item.isMovie ? nil : { [weak originatingPresenter] seasonNumber, episodeNumber in
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
        let localNextEpisode: DownloadItem? = item.isMovie ? nil : nextDownloadedEpisode(
            for: item.tmdbId,
            requestedSeasonNumber: item.seasonNumber ?? 0,
            requestedEpisodeNumber: (item.episodeNumber ?? 0) + 1,
            currentItemId: item.id
        )
        let request = PlaybackRequest(
            url: fileURL,
            subtitles: subtitles,
            mediaInfo: item.mediaInfo,
            episodePlaybackContext: item.episodePlaybackContext,
            title: item.playerTitleBase,
            subtitle: item.displayTitle,
            artworkURL: item.posterURL.flatMap(URL.init(string:)),
            isAnime: item.isAnime,
            originalTMDBSeasonNumber: item.episodePlaybackContext?.resolvedTMDBSeasonNumber,
            originalTMDBEpisodeNumber: item.episodePlaybackContext?.resolvedTMDBEpisodeNumber,
            onRequestNextEpisode: nextEpisodeRequest,
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
    
    // MARK: - Share
    
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
