//
//  DownloadsView.swift
//  Luna
//
//  Created on 27/02/26.
//

import SwiftUI
import AVKit
import Kingfisher

struct DownloadsView: View {
    @StateObject private var downloadManager = DownloadManager.shared
    @State private var showingDeleteAllConfirmation = false
    @State private var showingDeleteCompletedConfirmation = false
    @State private var showingDeleteSeriesConfirmation = false
    @State private var seriesToDelete: (tmdbId: Int, title: String)? = nil
    @State private var selectedTab: DownloadsTab = .downloads
    @State private var scrollOffset: CGFloat = 0
    
    private enum DownloadsTab: String, CaseIterable {
        case downloads = "Downloads"
        case library = "Library"
    }
    
    private var activeDownloads: [DownloadItem] {
        downloadManager.downloads.filter { $0.status == .downloading || $0.status == .queued || $0.status == .paused }
    }
    
    private var completedDownloads: [DownloadItem] {
        downloadManager.downloads.filter { $0.status == .completed }
    }
    
    private var failedDownloads: [DownloadItem] {
        downloadManager.downloads.filter { $0.status == .failed }
    }
    
    var body: some View {
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
        .background(SettingsGradientBackground(scrollOffset: scrollOffset).ignoresSafeArea())
#if os(iOS)
        .navigationBarTitleDisplayMode(.large)
#endif
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if !downloadManager.downloads.isEmpty {
                    managementMenu
                }
            }
        }
        .confirmationDialog("Delete All Downloads", isPresented: $showingDeleteAllConfirmation, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) {
                downloadManager.deleteAll()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will cancel all active downloads and remove all downloaded files. This action cannot be undone.")
        }
        .confirmationDialog("Delete Completed", isPresented: $showingDeleteCompletedConfirmation, titleVisibility: .visible) {
            Button("Delete Completed", role: .destructive) {
                downloadManager.deleteAllCompleted()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will remove all completed download files. This action cannot be undone.")
        }
        .confirmationDialog(
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
    
    // MARK: - Empty State
    
    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 64))
                .foregroundColor(.secondary.opacity(0.5))
            
            Text("No Downloads")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
            
            Text("Download movies and episodes to watch offline.\nUse the download button on any media page.")
                .font(.subheadline)
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    // MARK: - Downloads List
    
    @ViewBuilder
    private var downloadsList: some View {
        if activeDownloads.isEmpty && failedDownloads.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary.opacity(0.5))
                
                Text("No Active Downloads")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                
                Text("Completed downloads can be found\nin the Library tab.")
                    .font(.subheadline)
                    .foregroundColor(.secondary.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
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
            .background(LunaScrollTracker())
        }
            .listStyle(.plain)
            .lunaHideScrollBackground()
            .coordinateSpace(name: "lunaGradientScroll")
            .onPreferenceChange(ScrollOffsetPreferenceKey.self) { scrollOffset = $0 }
        }
    }
    
    // MARK: - Section Header
    
    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text("\(count)")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.gray.opacity(0.3))
                .cornerRadius(12)
            
            Spacer()
        }
        .padding(.horizontal)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }
    
    // MARK: - Active Download Row
    
    private func activeDownloadRow(_ item: DownloadItem) -> some View {
        HStack(spacing: 12) {
            posterImage(url: item.posterURL)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .foregroundColor(.white)
                
                if item.status == .downloading {
                    ProgressView(value: item.progress)
                        .tint(.blue)
                    
                    HStack {
                        Text("\(Int(item.progress * 100))%")
                            .font(.caption2)
                            .foregroundColor(.blue)
                        
                        Spacer()
                        
                        Text(item.formattedSize)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                } else if item.status == .queued {
                    Text(item.error ?? "Queued")
                        .font(.caption)
                        .foregroundColor(.orange)
                } else if item.status == .paused {
                    ProgressView(value: item.progress)
                        .tint(.gray)
                    
                    Text("Paused • \(Int(item.progress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            downloadActionButtons(item)
        }
        .padding(10)
        .applyLiquidGlassBackground(cornerRadius: 16)
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
            // Pause / Resume / Queued button
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
            .disabled(item.status == .queued)
            
            // Cancel / Delete button
            Button(action: {
                downloadManager.cancelDownload(id: item.id)
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.red.opacity(0.8))
                    .frame(width: 32, height: 32)
            }
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
    
    // MARK: - Failed Download Row
    
    private func failedDownloadRow(_ item: DownloadItem) -> some View {
        HStack(spacing: 12) {
            posterImage(url: item.posterURL)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .foregroundColor(.white)
                
                Text(item.error ?? "Unknown error")
                    .font(.caption)
                    .foregroundColor(.red)
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
        .padding(10)
        .applyLiquidGlassBackground(cornerRadius: 16)
        .contextMenu {
            Button(action: { downloadManager.resumeDownload(id: item.id) }) {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive, action: { downloadManager.removeDownload(id: item.id, deleteFile: true) }) {
                Label("Remove", systemImage: "trash")
            }
        }
    }
    
    // MARK: - Completed Download Row
    
    private func completedDownloadRow(_ item: DownloadItem) -> some View {
        Button(action: {
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
                        let formatter = ByteCountFormatter()
                        Text(formatter.string(fromByteCount: item.totalBytes))
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
    
    // MARK: - Poster Image
    
    private func posterImage(url: String?) -> some View {
        KFImage(URL(string: url ?? ""))
            .placeholder {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.3))
                    .overlay(
                        Image(systemName: "film")
                            .font(.title3)
                            .foregroundColor(.gray)
                    )
            }
            .resizable()
            .aspectRatio(2/3, contentMode: .fill)
            .frame(width: 55 * iPadScaleSmall, height: 82 * iPadScaleSmall)
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    
    // MARK: - Library View (Grouped by Show/Season)
    
    /// Groups completed downloads by show (tmdbId) then by season
    private struct ShowGroup: Identifiable {
        let id: Int  // tmdbId
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
        
        // Sort shows by title, seasons by number, episodes by episode number
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
                VStack(spacing: 16) {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary.opacity(0.5))
                    
                    Text("No Downloaded Content")
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                    
                    Text("Completed downloads will appear here\ngrouped by show and season.")
                        .font(.subheadline)
                        .foregroundColor(.secondary.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(groupedDownloads) { show in
                        if show.isMovie {
                            // Movies show directly
                            if let item = show.seasons.first?.episodes.first {
                                completedDownloadRow(item)
                                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                                    .listRowBackground(Color.clear)
                                    .contextMenu {
                                        Button(action: { playDownloadedItem(item) }) {
                                            Label("Play", systemImage: "play.fill")
                                        }
                                        Button(role: .destructive) {
                                            seriesToDelete = (tmdbId: show.id, title: show.title)
                                            showingDeleteSeriesConfirmation = true
                                        } label: {
                                            Label("Delete Download", systemImage: "trash")
                                        }
                                    }
                            }
                        } else {
                            // TV Shows: navigate to full detail page
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
                    
                    let formatter = ByteCountFormatter()
                    Text(formatter.string(fromByteCount: item.totalBytes))
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
    
    // MARK: - Management Menu
    
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
    
    // MARK: - Storage Footer
    
    private var storageFooter: some View {
        let storageUsed = downloadManager.calculateStorageUsed()
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        
        return VStack(spacing: 4) {
            Text("Storage Used: \(formatter.string(fromByteCount: storageUsed))")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text("\(completedDownloads.count) downloaded • \(activeDownloads.count) active")
                .font(.caption2)
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - Playback
    
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
    
    private func shareDownloadedItem(_ item: DownloadItem) {
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
    
    private func playDownloadedItem(_ item: DownloadItem) {
        guard let fileURL = downloadManager.localFileURL(for: item) else {
            Logger.shared.log("Downloaded file not found for: \(item.id)", type: "Download")
            return
        }
        
        let inAppRaw = UserDefaults.standard.string(forKey: "inAppPlayer") ?? "VLC"
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
            pvc.episodePlaybackContext = item.episodePlaybackContext
            pvc.originalTMDBSeasonNumber = item.episodePlaybackContext?.resolvedTMDBSeasonNumber
            pvc.originalTMDBEpisodeNumber = item.episodePlaybackContext?.resolvedTMDBEpisodeNumber
            pvc.modalPresentationStyle = .fullScreen
            if !item.isMovie {
                pvc.onRequestNextEpisode = { seasonNumber, episodeNumber in
                    guard let nextItem = nextDownloadedEpisode(
                        for: item.tmdbId,
                        requestedSeasonNumber: seasonNumber,
                        requestedEpisodeNumber: episodeNumber,
                        currentItemId: item.id
                    ) else {
                        Logger.shared.log("NextEpisode: No downloaded next episode found for tmdbId=\(item.tmdbId) after \(item.id)", type: "Player")
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        playDownloadedItem(nextItem)
                    }
                }
            }
            
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController,
               let topmostVC = rootVC.topmostViewController() as UIViewController? {
                topmostVC.present(pvc, animated: true, completion: nil)
            }
        } else {
            // Normal player (AVPlayer)
            let playerVC = NormalPlayer()
            let item2 = AVPlayerItem(url: fileURL)
            playerVC.player = AVPlayer(playerItem: item2)
            playerVC.mediaInfo = item.mediaInfo
            playerVC.episodePlaybackContext = item.episodePlaybackContext
            playerVC.modalPresentationStyle = .fullScreen
            
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController,
               let topmostVC = rootVC.topmostViewController() as UIViewController? {
                topmostVC.present(playerVC, animated: true) {
                    playerVC.playAtDefaultSpeed()
                }
            }
        }
    }

    private func nextDownloadedEpisode(
        for tmdbId: Int,
        requestedSeasonNumber: Int,
        requestedEpisodeNumber: Int,
        currentItemId: String
    ) -> DownloadItem? {
        let episodes = downloadManager.completedDownloads
            .filter {
                !$0.isMovie &&
                $0.tmdbId == tmdbId &&
                $0.seasonNumber != nil &&
                $0.episodeNumber != nil
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

        guard let currentIndex = episodes.firstIndex(where: { $0.id == currentItemId }) else { return nil }
        let nextIndex = episodes.index(after: currentIndex)
        guard nextIndex < episodes.endIndex else { return nil }
        return episodes[nextIndex]
    }
}
