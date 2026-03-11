//
//  LibraryView.swift
//  Kanzen
//
//  Created by Dawud Osman on 22/05/2025.
//
import SwiftUI
import CoreData
import Kingfisher

#if !os(tvOS)
struct KanzenLibraryView: View {
    @ObservedObject private var libraryManager = MangaLibraryManager.shared
    @EnvironmentObject var moduleManager: ModuleManager
    @State private var showCreateCollection = false

    private var bookmarksCollection: MangaLibraryCollection? {
        libraryManager.collections.first { $0.name == "Bookmarks" }
    }

    private var userCollections: [MangaLibraryCollection] {
        libraryManager.collections.filter { $0.name != "Bookmarks" }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // MARK: - Bookmarks
                    if let bookmarks = bookmarksCollection, !bookmarks.items.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Bookmarks")
                                .font(.title2)
                                .fontWeight(.bold)
                                .padding(.horizontal, 16)

                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 12) {
                                    ForEach(bookmarks.items.sorted(by: { $0.dateAdded < $1.dateAdded })) { item in
                                        NavigationLink(destination: mangaDestination(for: item)) {
                                            bookmarkCard(item)
                                        }
                                        .contextMenu {
                                            Button(role: .destructive) {
                                                libraryManager.removeItem(from: bookmarks.id, item: item)
                                            } label: {
                                                Label("Remove", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    }

                    // MARK: - Collections
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Collections")
                                .font(.title2)
                                .fontWeight(.bold)
                            Spacer()
                            Button {
                                showCreateCollection = true
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title3)
                            }
                        }
                        .padding(.horizontal, 16)

                        if userCollections.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .font(.title)
                                    .foregroundColor(.secondary)
                                Text("No collections yet")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(spacing: 14) {
                                    ForEach(userCollections) { collection in
                                        NavigationLink(destination: MangaCollectionDetailView(collection: collection, libraryManager: libraryManager)) {
                                            collectionCard(collection)
                                        }
                                        .contextMenu {
                                            Button(role: .destructive) {
                                                libraryManager.deleteCollection(collection)
                                            } label: {
                                                Label("Delete Collection", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    }

                    // MARK: - All Bookmarks Grid (if any)
                    if let bookmarks = bookmarksCollection, !bookmarks.items.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("All Bookmarks")
                                .font(.title2)
                                .fontWeight(.bold)
                                .padding(.horizontal, 16)

                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                                ForEach(bookmarks.items.sorted(by: { $0.dateAdded > $1.dateAdded })) { item in
                                    NavigationLink(destination: mangaDestination(for: item)) {
                                        mangaGridCard(item)
                                    }
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            libraryManager.removeItem(from: bookmarks.id, item: item)
                                        } label: {
                                            Label("Remove", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }

                    if (bookmarksCollection?.items.isEmpty ?? true) && userCollections.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "books.vertical")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                            Text("Your library is empty")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            Text("Bookmark manga from the Home or Search tabs to see them here.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                    }
                }
                .padding(.vertical, 8)
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .background(GlobalGradientBackground().ignoresSafeArea())
            .sheet(isPresented: $showCreateCollection) {
                MangaCreateCollectionView()
                    .environmentObject(libraryManager)
            }
        }
    }

    // MARK: - Card Views

    @ViewBuilder
    private func bookmarkCard(_ item: MangaLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            KFImage(URL(string: item.coverURL ?? ""))
                .placeholder { Rectangle().fill(Color.gray.opacity(0.2)) }
                .resizable()
                .scaledToFill()
                .frame(width: 120, height: 180)
                .clipped()
                .cornerRadius(16)
                .overlay(alignment: .topTrailing) {
                    unreadBadge(for: item)
                }

            Text(item.title)
                .font(.caption)
                .lineLimit(2)
                .foregroundColor(.primary)
        }
        .frame(width: 120)
    }

    @ViewBuilder
    private func mangaGridCard(_ item: MangaLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            KFImage(URL(string: item.coverURL ?? ""))
                .placeholder { Rectangle().fill(Color.gray.opacity(0.2)) }
                .resizable()
                .scaledToFill()
                .frame(height: 180)
                .clipped()
                .cornerRadius(16)

            Text(item.title)
                .font(.caption)
                .lineLimit(2)
                .foregroundColor(.primary)
        }
    }

    @ViewBuilder
    private func collectionCard(_ collection: MangaLibraryCollection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // 2x2 preview grid
            let previews = Array(collection.items.prefix(4))
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(LunaTheme.shared.cardBackground)
                    .frame(width: 140, height: 140)

                if previews.isEmpty {
                    Image(systemName: "folder")
                        .font(.title)
                        .foregroundColor(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.fixed(62)), GridItem(.fixed(62))], spacing: 4) {
                        ForEach(previews) { item in
                            KFImage(URL(string: item.coverURL ?? ""))
                                .placeholder { Rectangle().fill(Color.gray.opacity(0.2)) }
                                .resizable()
                                .scaledToFill()
                                .frame(width: 62, height: 62)
                                .clipped()
                                .cornerRadius(4)
                        }
                    }
                    .padding(4)
                }
            }
            .frame(width: 140, height: 140)

            Text(collection.name)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
                .foregroundColor(.primary)

            Text("\(collection.items.count) items")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(width: 140)
    }

    @ViewBuilder
    private func unreadBadge(for item: MangaLibraryItem) -> some View {
        let readCount = MangaReadingProgressManager.shared.readChapters(for: item.aniListId).count
        let total = item.totalChapters ?? 0
        let unread = max(0, total - readCount)
        if unread > 0 {
            Text("\(unread)")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.accentColor)
                .clipShape(Capsule())
                .padding(4)
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func mangaDestination(for item: MangaLibraryItem) -> some View {
        let manga = AniListManga(
            id: item.aniListId,
            title: AniListManga.AniListMangaTitle(romaji: item.title, english: nil, native: nil),
            chapters: item.totalChapters,
            volumes: nil,
            status: nil,
            coverImage: item.coverURL.map { AniListManga.AniListMangaCover(large: $0, medium: nil) },
            format: item.format,
            description: nil,
            genres: nil,
            averageScore: nil,
            countryOfOrigin: nil,
            startDate: nil
        )
        MangaDetailView(manga: manga)
    }
}
#endif
