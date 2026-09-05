//
//  EpisodeCell.swift
//  Sora
//
//  Created by Francesco on 07/08/25.
//

import SwiftUI
import Kingfisher

struct EpisodeCell: View {
    let episode: TMDBEpisode
    let showId: Int
    let showTitle: String
    let showPosterURL: String?
    let progress: Double
    let isSelected: Bool
    let onTap: () -> Void
    let onMarkWatched: () -> Void
    let onResetProgress: () -> Void
    var onDownload: (() -> Void)? = nil
    var playbackContext: EpisodePlaybackContext? = nil
    var isAnimeContent: Bool = false
    var isFiller: Bool = false

    @State private var isWatched: Bool = false
    @State private var isDownloaded: Bool = false

    @State private var downloadStateRefreshTask: Task<Void, Never>?
    @State private var progressValue: Double = 0
    @AppStorage(MediaDetailPlatformDefaults.horizontalEpisodeListKey) private var horizontalEpisodeList = MediaDetailPlatformDefaults.prefersHorizontalEpisodes

    private var horizontalCellWidth: CGFloat { 240 * iPadScaleSmall }
    private var horizontalImageHeight: CGFloat { 135 * iPadScaleSmall }
    private var horizontalTitleHeight: CGFloat { 18 }
    private var horizontalOverviewHeight: CGFloat { 42 }
    private var horizontalDetailsHeight: CGFloat { 86 }
    private var horizontalCellHeight: CGFloat { horizontalImageHeight + 8 + horizontalDetailsHeight }

    private struct EpisodePlayButtonModifier: ViewModifier {
        @ViewBuilder
        func body(content: Content) -> some View {
#if os(tvOS)
            content.buttonStyle(TVMediaCardButtonStyle())
#else
            content.buttonStyle(PlainButtonStyle())
#endif
        }
    }

    var body: some View {
        if horizontalEpisodeList {
            horizontalLayout
        } else if isIPad {
            iPadGridLayout
        } else {
            verticalLayout
        }
    }

    @MainActor private var iPadGridLayout: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    KFImage(URL(string: episode.fullStillURL ?? ""))

                        .setProcessor(DownsamplingImageProcessor(size: homeImageDecodeSize(width: 420, height: 236)))
                        .placeholder {
                            Rectangle()
                                .fill(Color.white.opacity(0.08))
                                .overlay(
                                    Image(systemName: "tv")
                                        .font(.title2)
                                        .foregroundColor(.white.opacity(0.65))
                                )
                        }
                        .resizable()
                        .aspectRatio(16/9, contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    if isWatched {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .heavy))
                            .foregroundColor(.white)
                            .frame(width: 25, height: 25)
                            .background(Circle().fill(Color.blue))
                            .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 1))
                            .padding(9)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if isDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 25, height: 25)
                            .background(Circle().fill(Color.green))
                            .overlay(Circle().stroke(Color.white.opacity(0.8), lineWidth: 1))
                            .padding(9)
                    }
                }
                .overlay(alignment: .bottom) {
                    if progressValue > 0 && progressValue < 0.85 {
                        ProgressView(value: progressValue)
                            .progressViewStyle(LinearProgressViewStyle(tint: .accentColor))
                            .frame(height: 4)
                            .padding(.horizontal, 8)
                            .padding(.bottom, 7)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            isSelected ? Color.accentColor : Color.white.opacity(0.10),
                            lineWidth: isSelected ? 2 : 1
                        )
                )
                .shadow(color: .black.opacity(0.26), radius: 8, x: 0, y: 4)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Text("Episode \(episode.episodeNumber)")
                            .font(.caption.weight(.medium))
                            .foregroundColor(.white.opacity(0.62))

                        if isFiller {
                            fillerBadge
                        }

                        Spacer(minLength: 8)

                        if episode.voteAverage > 0 {
                            Label(
                                String(format: "%.1f", episode.voteAverage),
                                systemImage: "star.fill"
                            )
                            .labelStyle(.titleAndIcon)
                            .foregroundColor(.white.opacity(0.72))
                        }

                        if let runtime = episode.runtime, runtime > 0 {
                            Text(episode.runtimeFormatted)
                                .foregroundColor(.white.opacity(0.72))
                        }
                    }
                    .font(.caption2)

                    if !episode.name.isEmpty {
                        Text(episode.name)
                            .font(.headline)
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }

                    if let overview = episode.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.58))
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .modifier(EpisodePlayButtonModifier())
#if !os(tvOS)
        .contextMenu {
            episodeContextMenu
        }
#endif
        .onAppear {
            progressValue = progress
            loadEpisodeProgress()
            refreshDownloadState()
        }
        .onReceive(ProgressManager.shared.$episodeProgressList) { entries in
            handleEpisodeProgressListChange(entries)
        }
#if !os(tvOS)
        .onReceive(DownloadManager.shared.$downloads) { _ in
            scheduleDownloadStateRefresh()
        }
#endif
        .preferredColorScheme(.dark)
    }

    @MainActor private var horizontalLayout: some View {
        Group {
            VStack(alignment: .leading, spacing: isTvOS ? 10 : 0) {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    KFImage(URL(string: episode.fullStillURL ?? ""))

                        .setProcessor(DownsamplingImageProcessor(size: homeImageDecodeSize(width: horizontalCellWidth, height: horizontalImageHeight)))
                        .placeholder {
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                                .overlay(
                                    Image(systemName: "tv")
                                        .font(.title2)
                                        .foregroundColor(.white.opacity(0.7))
                                )
                        }
                        .resizable()
                        .aspectRatio(16/9, contentMode: .fill)
                        .frame(width: horizontalCellWidth, height: horizontalImageHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    if progressValue > 0 && progressValue < 0.85 {
                        VStack {
                            Spacer()
                            ProgressView(value: progressValue)
                                .progressViewStyle(LinearProgressViewStyle(tint: .accentColor))
                                .frame(height: 3)
                                .padding(.horizontal, 4)
                                .padding(.bottom, 4)
                        }
                        .frame(width: horizontalCellWidth, height: horizontalImageHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    if isDownloaded || isWatched {
                        HStack {
                            if isDownloaded {
                                VStack {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .foregroundColor(.green)
                                        .shadow(radius: 2)
                                    Spacer()
                                }
                            }
                            Spacer()
                            if isWatched {
                                VStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.blue)
                                        .shadow(radius: 2)
                                    Spacer()
                                }
                            }
                        }
                        .padding(6)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Episode \(episode.episodeNumber)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if isFiller {
                            fillerBadge
                        }

                        Spacer()

                        HStack {
                            HStack(spacing: 2) {
                                if episode.voteAverage > 0 {
                                    Image(systemName: "star.fill")
                                        .font(.caption2)
                                        .foregroundColor(.yellow)
                                    Text(String(format: "%.1f", episode.voteAverage))
                                        .font(.caption2)
                                        .foregroundColor(.white)

                                    Text(" - ")
                                        .font(.caption2)
                                        .foregroundColor(.white)
                                }

                                if let runtime = episode.runtime, runtime > 0 {
                                    Text(episode.runtimeFormatted)
                                        .font(.caption2)
                                        .foregroundColor(.white)
                                }
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .applyLiquidGlassBackground(
                            cornerRadius: 16,
                            fallbackFill: Color.gray.opacity(0.2),
                            fallbackMaterial: .thinMaterial,
                            glassTint: Color.gray.opacity(0.15)
                        )
                        .clipShape(Capsule())
                    }

                    if !episode.name.isEmpty {
                        Text(episode.name)
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .frame(height: horizontalTitleHeight, alignment: .top)
                    } else {
                        Color.clear
                            .frame(height: horizontalTitleHeight)
                    }

                    if let overview = episode.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                            .frame(height: horizontalOverviewHeight, alignment: .top)
                            .clipped()
                    } else {
                        Color.clear
                            .frame(height: horizontalOverviewHeight)
                    }
                }
                .frame(width: horizontalCellWidth, height: horizontalDetailsHeight, alignment: .topLeading)
            }
            .frame(width: horizontalCellWidth, height: horizontalCellHeight, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .modifier(EpisodePlayButtonModifier())
#if os(tvOS)
        .contextMenu {
            episodeContextMenu
        }
#endif
            }
        }
#if !os(tvOS)
        .contextMenu {
            episodeContextMenu
        }
#endif
        .onAppear {
            progressValue = progress
            loadEpisodeProgress()
            refreshDownloadState()
        }
        .onReceive(ProgressManager.shared.$episodeProgressList) { entries in
            handleEpisodeProgressListChange(entries)
        }
#if !os(tvOS)
        .onReceive(DownloadManager.shared.$downloads) { _ in
            scheduleDownloadStateRefresh()
        }
#endif
        .preferredColorScheme(.dark)
    }

    @MainActor private var verticalLayout: some View {
        Group {
            VStack(alignment: .leading, spacing: isTvOS ? 10 : 0) {
        Button(action: onTap) {
            HStack(spacing: isTvOS ? 20 : 12) {
                ZStack {
                    KFImage(URL(string: episode.fullStillURL ?? ""))

                        .setProcessor(DownsamplingImageProcessor(size: homeImageDecodeSize(width: isTvOS ? 300 : 120 * iPadScaleSmall, height: isTvOS ? 170 : 68 * iPadScaleSmall)))
                        .placeholder {
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                                .overlay(
                                    Image(systemName: "tv")
                                        .font(.title2)
                                        .foregroundColor(.white.opacity(0.7))
                                )
                        }
                        .resizable()
                        .aspectRatio(16/9, contentMode: .fill)
                        .frame(width: isTvOS ? 300 : 120 * iPadScaleSmall, height: isTvOS ? 170 : 68 * iPadScaleSmall)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    if progressValue > 0 && progressValue < 0.85 {
                        VStack {
                            Spacer()
                            ProgressView(value: progressValue)
                                .progressViewStyle(LinearProgressViewStyle(tint: .accentColor))
                                .frame(height: 3)
                                .padding(.horizontal, 4)
                                .padding(.bottom, 4)
                        }
                        .frame(width: isTvOS ? 300 : 120 * iPadScaleSmall, height: isTvOS ? 170 : 68 * iPadScaleSmall)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    if isDownloaded || isWatched {
                        HStack {
                            if isDownloaded {
                                VStack {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .foregroundColor(.green)
                                        .shadow(radius: 2)
                                    Spacer()
                                }
                            }
                            Spacer()
                            if isWatched {
                                VStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.blue)
                                        .shadow(radius: 2)
                                    Spacer()
                                }
                            }
                        }
                        .padding(6)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Episode \(episode.episodeNumber)")
                            .font(isTvOS ? .system(size: 24) : .caption)
                            .foregroundColor(.secondary)
                            .fontWeight(.medium)

                        if isFiller {
                            fillerBadge
                        }

                        Spacer()

                        HStack {
                            HStack(spacing: 2) {
                                if episode.voteAverage > 0 {
                                    Image(systemName: "star.fill")
                                        .font(isTvOS ? .system(size: 24) : .caption2)
                                        .foregroundColor(.yellow)
                                    Text(String(format: "%.1f", episode.voteAverage))
                                        .font(isTvOS ? .system(size: 24) : .caption2)
                                        .foregroundColor(.white)

                                    Text(" - ")
                                        .font(isTvOS ? .system(size: 24) : .caption2)
                                        .foregroundColor(.white)
                                }

                                if let runtime = episode.runtime, runtime > 0 {
                                    Text(episode.runtimeFormatted)
                                        .font(isTvOS ? .system(size: 24) : .caption2)
                                }
                            }
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .applyLiquidGlassBackground(
                            cornerRadius: 16,
                            fallbackFill: Color.gray.opacity(0.2),
                            fallbackMaterial: .thinMaterial,
                            glassTint: Color.gray.opacity(0.15)
                        )
                        .clipShape(Capsule())
                    }

                    if !episode.name.isEmpty {
                        Text(episode.name)
                            .font(isTvOS ? .system(size: 29) : .subheadline)
                            .fontWeight(isTvOS ? .semibold : .medium)
                            .lineLimit(1)
                            .foregroundColor(.white)
                    }

                    if let overview = episode.overview, !overview.isEmpty {
                        Text(overview)
                            .font(isTvOS ? .system(size: 24) : .caption)
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(isTvOS ? 20 : 12)
            .applyLiquidGlassBackground(cornerRadius: 16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
            )
        }
        .modifier(EpisodePlayButtonModifier())
#if os(tvOS)
        .contextMenu {
            episodeContextMenu
        }
#endif
            }
        }
#if !os(tvOS)
        .contextMenu {
            episodeContextMenu
        }
#endif
        .onAppear {
            progressValue = progress
            loadEpisodeProgress()
            refreshDownloadState()
        }
        .onReceive(ProgressManager.shared.$episodeProgressList) { entries in
            handleEpisodeProgressListChange(entries)
        }
#if !os(tvOS)
        .onReceive(DownloadManager.shared.$downloads) { _ in
            scheduleDownloadStateRefresh()
        }
#endif
        .preferredColorScheme(.dark)
    }

    private var fillerBadge: some View {
        Text("Filler")
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundColor(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.16), in: Capsule())
            .accessibilityLabel("Filler episode")
    }

    private var episodeContextMenu: some View {
        Group {
            Button(action: onTap) {
                Label("Play", systemImage: "play.fill")
            }

#if !os(tvOS)
            if let onDownload = onDownload {
                let completedDownload = DownloadManager.shared.completedEpisodeDownloadItem(
                    tmdbId: showId,
                    seasonNumber: episode.seasonNumber,
                    episodeNumber: episode.episodeNumber,
                    playbackContext: playbackContext
                )
                let activeDownload = DownloadManager.shared.activeEpisodeDownloadItem(
                    tmdbId: showId,
                    seasonNumber: episode.seasonNumber,
                    episodeNumber: episode.episodeNumber,
                    playbackContext: playbackContext
                )

                if let completedDownload {
                    Button(role: .destructive, action: {
                        DownloadManager.shared.removeDownload(
                            id: completedDownload.id,
                            deleteFile: true
                        )
                    }) {
                        Label("Remove Download", systemImage: "trash")
                    }
                } else if activeDownload == nil {
                    Button(action: onDownload) {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                }
            }
#endif

            if episode.episodeNumber > 1 {
                Button(action: {
                    ProgressManager.shared.markPreviousEpisodesAsWatched(
                        showId: showId,
                        seasonNumber: episode.seasonNumber,
                        episodeNumber: episode.episodeNumber,
                        playbackContext: playbackContext,
                        isAnime: isAnimeContent
                    )
                    refreshProgressState()
                }) {
                    Label("Mark Previous as Watched", systemImage: "chevron.left.slash.chevron.right")
                }

                Button(action: {
                    ProgressManager.shared.markPreviousEpisodesAsUnwatched(
                        showId: showId,
                        seasonNumber: episode.seasonNumber,
                        episodeNumber: episode.episodeNumber
                    )
                    refreshProgressState()
                }) {
                    Label("Mark Previous as Not Watched", systemImage: "arrow.uturn.backward")
                }
            }

            if isWatched {
                Button(action: {
                    ProgressManager.shared.markEpisodeAsUnwatched(
                        showId: showId,
                        seasonNumber: episode.seasonNumber,
                        episodeNumber: episode.episodeNumber
                    )
                    onResetProgress()
                    isWatched = false
                    refreshProgressState()
                }) {
                    Label("Mark as Not Watched", systemImage: "eye.slash")
                }
            } else {
                Button(action: {
                    onMarkWatched()
                    isWatched = true
                    progressValue = 1
                }) {
                    Label("Mark as Watched", systemImage: "checkmark.circle")
                }
            }

            if progressValue > 0 {
                Button(action: {
                    ProgressManager.shared.resetEpisodeProgress(
                        showId: showId,
                        seasonNumber: episode.seasonNumber,
                        episodeNumber: episode.episodeNumber
                    )
                    onResetProgress()
                    isWatched = false
                    progressValue = 0
                }) {
                    Label("Reset Progress", systemImage: "arrow.counterclockwise")
                }
            }
        }
    }

    private func loadEpisodeProgress() {
        refreshProgressState()
        let newProgress = ProgressManager.shared.getEpisodeProgress(
            showId: showId,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber
        )
        if abs(progressValue - newProgress) > 0.001 {
            progressValue = newProgress
        }
    }

    private func handleEpisodeProgressListChange(_ entries: [EpisodeProgressEntry]) {
        let hasRelevantEntry = entries.contains {
            $0.showId == showId &&
            $0.seasonNumber == episode.seasonNumber &&
            $0.episodeNumber == episode.episodeNumber
        }
        guard hasRelevantEntry || isWatched || progressValue > 0 else { return }
        loadEpisodeProgress()
    }

    private func refreshProgressState() {
        let newValue = ProgressManager.shared.isEpisodeWatched(
            showId: showId,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber
        )
        if isWatched != newValue {
            isWatched = newValue
        }
    }

    private func refreshDownloadState() {

#if !os(tvOS)
        let present = DownloadManager.shared.completedEpisodeDownloadItem(
            tmdbId: showId,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber,
            playbackContext: playbackContext
        ) != nil
#else

        let present = false
#endif
        if isDownloaded != present {
            isDownloaded = present
        }
    }

    private func scheduleDownloadStateRefresh() {
        downloadStateRefreshTask?.cancel()
        downloadStateRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            refreshDownloadState()
        }
    }
}
