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
    
    @State private var isWatched: Bool = false
    @State private var progressValue: Double = 0
    @AppStorage("horizontalEpisodeList") private var horizontalEpisodeList: Bool = false
    
    var body: some View {
        if horizontalEpisodeList {
            horizontalLayout
        } else {
            verticalLayout
        }
    }
    
    @MainActor private var horizontalLayout: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    KFImage(URL(string: episode.fullStillURL ?? ""))
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
                        .frame(width: 240 * iPadScaleSmall, height: 135 * iPadScaleSmall)
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
                        .frame(width: 240 * iPadScaleSmall, height: 135 * iPadScaleSmall)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    if isWatched {
                        HStack {
                            Spacer()
                            VStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                                    .shadow(radius: 2)
                                Spacer()
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
                    }
                    
                    if let overview = episode.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(width: 240 * iPadScaleSmall, alignment: .leading)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .contextMenu {
            episodeContextMenu
        }
        .onAppear {
            progressValue = progress
            loadEpisodeProgress()
        }
        .onReceive(ProgressManager.shared.$episodeProgressList) { _ in
            refreshProgressState()
            progressValue = ProgressManager.shared.getEpisodeProgress(
                showId: showId,
                seasonNumber: episode.seasonNumber,
                episodeNumber: episode.episodeNumber
            )
        }
        .preferredColorScheme(.dark)
    }
    
    @MainActor private var verticalLayout: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                ZStack {
                    KFImage(URL(string: episode.fullStillURL ?? ""))
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
                        .frame(width: 120 * iPadScaleSmall, height: 68 * iPadScaleSmall)
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
                        .frame(width: 120 * iPadScaleSmall, height: 68 * iPadScaleSmall)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    if isWatched {
                        HStack {
                            Spacer()
                            VStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.blue)
                                    .shadow(radius: 2)
                                Spacer()
                            }
                        }
                        .padding(6)
                    }
                }
                
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Episode \(episode.episodeNumber)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fontWeight(.medium)
                        
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
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .foregroundColor(.white)
                    }
                    
                    if let overview = episode.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
            .applyLiquidGlassBackground(cornerRadius: 16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .contextMenu {
            episodeContextMenu
        }
        .onAppear {
            progressValue = progress
            loadEpisodeProgress()
        }
        .onReceive(ProgressManager.shared.$episodeProgressList) { _ in
            refreshProgressState()
            progressValue = ProgressManager.shared.getEpisodeProgress(
                showId: showId,
                seasonNumber: episode.seasonNumber,
                episodeNumber: episode.episodeNumber
            )
        }
        .preferredColorScheme(.dark)
    }
    
    private var episodeContextMenu: some View {
        Group {
            Button(action: onTap) {
                Label("Play", systemImage: "play.fill")
            }
            
            if let onDownload = onDownload {
                let isDownloaded = DownloadManager.shared.isDownloaded(
                    tmdbId: showId, isMovie: false,
                    seasonNumber: episode.seasonNumber,
                    episodeNumber: episode.episodeNumber
                )
                let isDownloading = DownloadManager.shared.isDownloading(
                    tmdbId: showId, isMovie: false,
                    seasonNumber: episode.seasonNumber,
                    episodeNumber: episode.episodeNumber
                )
                
                if isDownloaded {
                    Button(role: .destructive, action: {
                        let id = "dl_ep_\(showId)_s\(episode.seasonNumber)_e\(episode.episodeNumber)"
                        DownloadManager.shared.removeDownload(id: id, deleteFile: true)
                    }) {
                        Label("Remove Download", systemImage: "trash")
                    }
                } else if !isDownloading {
                    Button(action: onDownload) {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                }
            }
            
            if episode.episodeNumber > 1 {
                Button(action: {
                    ProgressManager.shared.markPreviousEpisodesAsWatched(
                        showId: showId,
                        seasonNumber: episode.seasonNumber,
                        episodeNumber: episode.episodeNumber,
                        playbackContext: playbackContext
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
                    ProgressManager.shared.markEpisodeAsWatched(
                        showId: showId,
                        seasonNumber: episode.seasonNumber,
                        episodeNumber: episode.episodeNumber,
                        playbackContext: playbackContext
                    )
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
        progressValue = ProgressManager.shared.getEpisodeProgress(
            showId: showId,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber
        )
    }

    private func refreshProgressState() {
        isWatched = ProgressManager.shared.isEpisodeWatched(
            showId: showId,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber
        )
    }
}
