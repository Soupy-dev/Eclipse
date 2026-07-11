import SwiftUI
import Kingfisher

struct LibraryView: View {
    @State private var showingCreateSheet = false

#if os(tvOS)
    private enum TVCollectionFocus: Hashable {
        case open(UUID)
        case delete(UUID)
        case create
    }

    @FocusState private var tvCollectionFocus: TVCollectionFocus?
#endif
    
    @StateObject private var accentColorManager = AccentColorManager.shared
    @ObservedObject private var libraryManager = LibraryManager.shared
    @Environment(\.heroNamespace) private var heroNamespace
    
    var body: some View {
#if os(tvOS)
        libraryContent
#else
        if #available(iOS 16.0, *) {
            NavigationStack {
                libraryContent
            }
        } else {
            NavigationView {
                libraryContent
            }
            .navigationViewStyle(StackNavigationViewStyle())
        }
#endif
    }
    
    private var libraryContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                bookmarksSection
                collectionsSection
            }
            .padding(.top)
        }
        .background(SettingsGradientBackground().ignoresSafeArea())
        .navigationTitle("Library")
        .navigationBarItems(trailing: Button(action: {
            showingCreateSheet = true
        }) {
            Image(systemName: "plus")
                .foregroundColor(accentColorManager.currentAccentColor)
        }
#if os(tvOS)
        .focused($tvCollectionFocus, equals: .create)
#endif
        )
        .sheet(isPresented: $showingCreateSheet) {
            CreateCollectionView()
        }
    }
    
    private var bookmarksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            EclipseSectionHeader(
                title: "Bookmarks",
                count: libraryManager.collections.first(where: { $0.name == "Bookmarks" })?.items.count
            )
            .padding(.horizontal)

            if let bookmarksCollection = libraryManager.collections.first(where: { $0.name == "Bookmarks" }),
               !bookmarksCollection.items.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        // Show oldest bookmarks first so order is predictable
                        ForEach(bookmarksCollection.items.sorted(by: { $0.dateAdded < $1.dateAdded }), id: \.searchResult.stableIdentity) { item in
                            let heroID = "library-bookmark-\(item.searchResult.stableIdentity)"
                            NavigationLink(destination: MediaDetailView(searchResult: item.searchResult)
                                .heroDestination(id: heroID, namespace: heroNamespace)
                            ) {
                                BookmarkItemCard(item: item, heroID: heroID)
                            }
#if os(tvOS)
                            .buttonStyle(.card)
#else
                            .buttonStyle(PlainButtonStyle())
#endif
                        }
                    }
                    .padding(.horizontal)
                }
            } else {
                EclipseEmptyState(
                    icon: "bookmark",
                    title: "No bookmarks yet",
                    message: "Bookmark items to see them here."
                )
            }
        }
    }

    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            EclipseSectionHeader(
                title: "Collections",
                count: libraryManager.collections.filter { $0.name != "Bookmarks" }.count
            )
            .padding(.horizontal)

            let nonBookmarkCollections = libraryManager.collections.filter { $0.name != "Bookmarks" }
            
            if !nonBookmarkCollections.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(nonBookmarkCollections) { collection in
#if os(tvOS)
                            VStack(spacing: 10) {
                                NavigationLink(destination: CollectionDetailView(collection: collection)) {
                                    CollectionCard(collection: collection)
                                }
                                .buttonStyle(.card)
                                .focused($tvCollectionFocus, equals: .open(collection.id))

                                Button(role: .destructive) {
                                    deleteCollectionAndRestoreFocus(
                                        collection,
                                        from: nonBookmarkCollections
                                    )
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .focused($tvCollectionFocus, equals: .delete(collection.id))
                            }
#else
                            NavigationLink(destination: CollectionDetailView(collection: collection)) {
                                CollectionCard(collection: collection)
                            }
                            .buttonStyle(PlainButtonStyle())
#endif
                        }
                    }
                    .padding(.horizontal)
                }
            } else {
                EclipseEmptyState(
                    icon: "folder.badge.plus",
                    title: "No collections yet",
                    message: "Create collections to organize your media."
                )
            }
        }
    }

#if os(tvOS)
    private func deleteCollectionAndRestoreFocus(
        _ collection: LibraryCollection,
        from collections: [LibraryCollection]
    ) {
        guard let removedIndex = collections.firstIndex(where: { $0.id == collection.id }) else { return }
        let survivingCollections = collections.filter { $0.id != collection.id }
        let nextFocus: TVCollectionFocus
        if survivingCollections.isEmpty {
            nextFocus = .create
        } else {
            let nearestCollectionID = survivingCollections[min(removedIndex, survivingCollections.count - 1)].id
            nextFocus = .open(nearestCollectionID)
        }

        LibraryManager.shared.deleteCollection(collection)

        DispatchQueue.main.async {
            tvCollectionFocus = nextFocus
        }
    }
#endif
}

struct BookmarkItemCard: View {
    let item: LibraryItem
    let heroID: String
    @Environment(\.heroNamespace) private var heroNamespace
    
    var body: some View {
        VStack(spacing: 8) {
            KFImage(URL(string: item.searchResult.fullPosterURL ?? ""))
                .placeholder {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay(
                            Image(systemName: item.searchResult.isMovie ? "tv" : "tv.and.mediabox")
                                .font(.title2)
                                .foregroundColor(.white.opacity(0.7))
                        )
                }
                .resizable()
                .aspectRatio(2/3, contentMode: .fill)
                .frame(width: 120 * iPadScale, height: 180 * iPadScale)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
                .heroSource(id: heroID, namespace: heroNamespace)
            
            Text(item.searchResult.displayTitle)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
                .foregroundColor(.white)
        }
        .frame(width: 120 * iPadScale, alignment: .leading)
    }
}

struct CollectionCard: View {
    @ObservedObject var collection: LibraryCollection
    @State private var showingRenameAlert = false
    @State private var renameText = ""
    
    var body: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.08))
                .frame(width: 160 * iPadScale, height: 160 * iPadScale)
                .overlay(
                    collectionPreview
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))
            
            VStack(spacing: 4) {
                Text(collection.name)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                
                Text("\(collection.items.count) items")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(width: 160 * iPadScale)
        }
#if !os(tvOS)
        .contextMenu {
            if collection.name != "Bookmarks" {
                Button {
                    renameText = collection.name
                    showingRenameAlert = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }

                Button(role: .destructive) {
                    LibraryManager.shared.deleteCollection(collection)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .alert("Rename Collection", isPresented: $showingRenameAlert) {
            TextField("Collection Name", text: $renameText)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                LibraryManager.shared.renameCollection(collection, name: renameText)
            }
        } message: {
            Text("Enter a new name for this collection.")
        }
#endif
    }
    
    @ViewBuilder
    @MainActor
    private var collectionPreview: some View {
        let recentItems = Array(collection.items.sorted(by: { $0.dateAdded < $1.dateAdded }).suffix(4))
        
        if recentItems.isEmpty {
            VStack {
                Image(systemName: "folder")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
                Text("Empty")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } else if recentItems.count == 1 {
            let single = recentItems[0]
            KFImage(URL(string: single.searchResult.fullPosterURL ?? ""))
                .placeholder {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay(
                            Image(systemName: single.searchResult.isMovie ? "tv" : "tv.and.mediabox")
                                .font(.title2)
                                .foregroundColor(.white.opacity(0.7))
                        )
                }
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 160 * iPadScale, height: 160 * iPadScale)
                .id(single.id)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 2), spacing: 2) {
                ForEach(recentItems) { item in
                    KFImage(URL(string: item.searchResult.fullPosterURL ?? ""))
                        .placeholder {
                            Rectangle()
                                .fill(Color.gray.opacity(0.3))
                                .overlay(
                                    Image(systemName: item.searchResult.isMovie ? "tv" : "tv.and.mediabox")
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.7))
                                )
                        }
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 78 * iPadScale, height: 78 * iPadScale)
                        .clipped()
                        .id(item.id)
                }
                
                ForEach(recentItems.count..<4, id: \.self) { _ in
                    Rectangle()
                        .fill(Color.gray.opacity(0.1))
                        .frame(width: 78 * iPadScale, height: 78 * iPadScale)
                }
            }
        }
    }
}

#Preview {
    LibraryView()
}
