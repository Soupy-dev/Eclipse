//
//  KanzenHistoryView.swift
//  Kanzen
//
//  Created by Luna on 2026.
//

import SwiftUI
import Kingfisher

#if !os(tvOS)
struct KanzenHistoryView: View {
    @ObservedObject private var progressManager = MangaReadingProgressManager.shared

    private var historyItems: [(id: Int, progress: MangaProgress)] {
        progressManager.recentlyReadMangaIds()
    }

    var body: some View {
        NavigationView {
            Group {
                if historyItems.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("No reading history")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Manga you read will appear here.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(historyItems, id: \.id) { item in
                            NavigationLink(destination: mangaDestination(for: item)) {
                                HStack(spacing: 12) {
                                    KFImage(URL(string: item.progress.coverURL ?? ""))
                                        .placeholder { Rectangle().fill(Color.gray.opacity(0.2)) }
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 50, height: 75)
                                        .clipped()
                                        .cornerRadius(12)

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.progress.title ?? "Unknown Manga")
                                            .font(.headline)
                                            .lineLimit(2)

                                        if let lastCh = item.progress.lastReadChapter {
                                            Text("Ch. \(lastCh)")
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                        }

                                        if let date = item.progress.lastReadDate {
                                            Text(date, style: .relative)
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .lunaHideScrollBackground()
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.large)
            .background(GlobalGradientBackground().ignoresSafeArea())
        }
    }

    @ViewBuilder
    private func mangaDestination(for item: (id: Int, progress: MangaProgress)) -> some View {
        if let moduleUUIDStr = item.progress.moduleUUID,
           let moduleUUID = UUID(uuidString: moduleUUIDStr),
           let contentParams = item.progress.contentParams {
            HistoryModuleLoaderView(
                moduleUUID: moduleUUID,
                title: item.progress.title ?? "Unknown",
                imageURL: item.progress.coverURL ?? "",
                contentParams: contentParams,
                isNovel: item.progress.isNovel ?? false
            )
        } else {
            let manga = AniListManga(
                id: item.id,
                title: AniListManga.AniListMangaTitle(
                    romaji: item.progress.title,
                    english: nil,
                    native: nil
                ),
                chapters: item.progress.totalChapters,
                volumes: nil,
                status: nil,
                coverImage: item.progress.coverURL.map {
                    AniListManga.AniListMangaCover(large: $0, medium: nil)
                },
                format: item.progress.format,
                description: nil,
                genres: nil,
                averageScore: nil,
                countryOfOrigin: nil,
                startDate: nil
            )
            MangaDetailView(manga: manga)
        }
    }
}

// MARK: - Module Loader for History

private struct HistoryModuleLoaderView: View {
    let moduleUUID: UUID
    let title: String
    let imageURL: String
    let contentParams: String
    let isNovel: Bool

    @ObservedObject private var kanzen = KanzenEngine()
    @State private var moduleLoaded = false
    @State private var loadFailed = false

    var body: some View {
        if moduleLoaded, let module = ModuleManager.shared.getModule(moduleUUID) {
            contentView(parentModule: module, title: title, imageURL: imageURL, params: contentParams)
                .environmentObject(kanzen)
        } else if loadFailed {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
                Text("Module not available")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Text("The source module may have been removed.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        } else {
            ProgressView("Loading module…")
                .task {
                    guard let module = ModuleManager.shared.getModule(moduleUUID) else {
                        loadFailed = true
                        return
                    }
                    do {
                        let content = try ModuleManager.shared.getModuleScript(module: module)
                        try kanzen.loadScript(content, isNovel: isNovel)
                        moduleLoaded = true
                    } catch {
                        Logger.shared.log("Error loading module for history: \(error.localizedDescription)", type: "Error")
                        loadFailed = true
                    }
                }
        }
    }
}
#endif
