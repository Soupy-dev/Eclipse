//
//  DownloadedShowDetailView.swift
//  Luna
//
//  Full detail page for a downloaded show in the Library tab.
//

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
        #if os(iOS)
        .background(Color(.systemBackground))
        #else
        .background(Color.black)
        #endif
        .confirmationDialog(
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
        
        return Button(action: { playDownloadedItem(item) }) {
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
                    
                    // Action buttons
                    HStack(spacing: 12) {
                        Image(systemName: "play.circle.fill")
                            .font(.title3)
                            .foregroundColor(.white)
                        
                        Button(action: {
                            itemToDelete = item
                            showingDeleteConfirmation = true
                        }) {
                            Image(systemName: "trash")
                                .font(.subheadline)
                                .foregroundColor(.red.opacity(0.8))
                        }
                        .buttonStyle(PlainButtonStyle())
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
            episodeNumber: item.episodeNumber ?? 1
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
    
    private func playDownloadedItem(_ item: DownloadItem) {
        guard let fileURL = downloadManager.localFileURL(for: item) else {
            Logger.shared.log("Downloaded file not found for: \(item.id)", type: "Download")
            return
        }
        
        let inAppRaw = UserDefaults.standard.string(forKey: "inAppPlayer") ?? "Normal"
        let subtitleArray: [String]? = downloadManager.localSubtitleURL(for: item).map { [$0.absoluteString] }
        
        if inAppRaw == "mpv" || inAppRaw == "VLC" {
            let preset = PlayerPreset.presets.first
            let pvc = PlayerViewController(
                url: fileURL,
                preset: preset ?? PlayerPreset(id: .sdrRec709, title: "Default", summary: "", stream: nil, commands: []),
                headers: [:],
                subtitles: subtitleArray,
                mediaInfo: item.mediaInfo
            )
            pvc.isAnimeHint = item.isAnime
            pvc.modalPresentationStyle = .fullScreen
            
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController,
               let topmostVC = rootVC.topmostViewController() as UIViewController? {
                topmostVC.present(pvc, animated: true, completion: nil)
            }
        } else {
            let playerVC = NormalPlayer()
            let item2 = AVPlayerItem(url: fileURL)
            playerVC.player = AVPlayer(playerItem: item2)
            playerVC.mediaInfo = item.mediaInfo
            playerVC.modalPresentationStyle = .fullScreen
            
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController,
               let topmostVC = rootVC.topmostViewController() as UIViewController? {
                topmostVC.present(playerVC, animated: true) {
                    playerVC.player?.play()
                }
            }
        }
    }
    
    // MARK: - Share
    
    private func shareItem(_ item: DownloadItem) {
#if os(iOS)
        guard let fileURL = downloadManager.localFileURL(for: item) else { return }
        let activityVC = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController,
           let topmostVC = rootVC.topmostViewController() as UIViewController? {
            activityVC.popoverPresentationController?.sourceView = topmostVC.view
            topmostVC.present(activityVC, animated: true)
        }
#endif
    }
}
