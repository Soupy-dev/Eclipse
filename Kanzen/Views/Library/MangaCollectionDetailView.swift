import SwiftUI
import Kingfisher

#if !os(tvOS)
struct MangaCollectionDetailView: View {
    @ObservedObject var collection: MangaLibraryCollection
    @ObservedObject var libraryManager: MangaLibraryManager
    @State private var isRefreshingSources = false
    @State private var refreshStatus: String?

    private let columns = [GridItem(.adaptive(minimum: 120), spacing: 12)]

    var body: some View {
        Group {
            if collection.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "books.vertical")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No manga in this collection")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let refreshStatus {
                            Text(refreshStatus)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.horizontal)
                        }

                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(collection.items) { item in
                                NavigationLink(destination: mangaDestination(for: item)) {
                                    mangaCard(item)
                                }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        libraryManager.removeItem(from: collection.id, item: item)
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
        }
        .navigationTitle(collection.name)
        .navigationBarTitleDisplayMode(.inline)
        .background(GlobalGradientBackground().ignoresSafeArea())
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    refreshCollectionSources()
                } label: {
                    if isRefreshingSources {
                        EclipseLoadingIndicator()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshingSources || collection.items.isEmpty)
                .accessibilityLabel("Refresh Sources")
            }
        }
    }

    @ViewBuilder
    private func mangaCard(_ item: MangaLibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            KFImage(URL(string: item.coverURL ?? ""))
                .placeholder { Rectangle().fill(Color.gray.opacity(0.2)) }
                .resizable()
                .scaledToFill()
                .frame(width: 120, height: 180)
                .clipped()
                .cornerRadius(8)
                .overlay(alignment: .topLeading) {
                    unreadBadge(for: item)
                }
                .overlay(alignment: .topTrailing) {
                    downloadedBadge(for: item)
                }

            Text(item.title)
                .font(.caption)
                .lineLimit(2)
                .foregroundColor(.primary)
        }
        .frame(width: 120)
    }

    @ViewBuilder
    private func mangaDestination(for item: MangaLibraryItem) -> some View {
        MangaLibraryDestinationView(item: item)
    }

    @ViewBuilder
    private func unreadBadge(for item: MangaLibraryItem) -> some View {
        let unread = item.unreadCount(readChapters: MangaReadingProgressManager.shared.readChapters(for: item.aniListId))
        if unread > 0 {
            Text("\(unread)")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.red)
                .clipShape(Capsule())
                .padding(4)
        }
    }

    @ViewBuilder
    private func downloadedBadge(for item: MangaLibraryItem) -> some View {
        if ReaderDownloadManager.shared.isDownloaded(route: item.route) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption)
                .foregroundColor(.white)
                .padding(5)
                .background(Color.black.opacity(0.65))
                .clipShape(Circle())
                .padding(4)
        }
    }

    private func refreshCollectionSources() {
        guard !isRefreshingSources else { return }
        isRefreshingSources = true
        refreshStatus = "Refreshing saved sources..."
        Task { @MainActor in
            let summary = await libraryManager.refreshSource(for: collection)
            refreshStatus = summary.statusText
            isRefreshingSources = false
        }
    }
}
#endif
