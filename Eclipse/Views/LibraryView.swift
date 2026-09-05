//
//  LibraryView.swift
//  Sora
//
//  Created by Francesco on 07/08/25.
//

import SwiftUI
import Kingfisher

#if !os(tvOS)
import UniformTypeIdentifiers

struct LibraryReorderDropDelegate: DropDelegate {
    let targetId: String
    let orderedIds: () -> [String]
    let draggingId: () -> String?
    let clearDragging: () -> Void
    let move: (_ from: Int, _ to: Int) -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        guard let dragId = draggingId(), dragId != targetId else { return }
        let ids = orderedIds()
        guard let fromIndex = ids.firstIndex(of: dragId),
              let toIndex = ids.firstIndex(of: targetId) else { return }
        let destination = toIndex > fromIndex ? toIndex + 1 : toIndex
        withAnimation(.default) {
            move(fromIndex, destination)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        clearDragging()
        return true
    }
}
#endif

struct LibraryView: View {
    @State private var showingCreateSheet = false

    @State private var kidsBlockedLibraryIds: Set<LibraryIdentity> = []

    @State private var kidsFilterResolved = false

    @State private var kidsFilterTask: Task<Void, Never>?

    private struct LibraryIdentity: Hashable {
        let isMovie: Bool
        let id: Int

        init(_ result: TMDBSearchResult) {
            self.isMovie = result.isMovie
            self.id = result.id
        }
    }

    private func visibleToProfile(_ items: [LibraryItem]) -> [LibraryItem] {
        guard ProfileManager.shared.isKidsModeActive else { return items }
        guard kidsFilterResolved else { return [] }
        return items.filter { !kidsBlockedLibraryIds.contains(LibraryIdentity($0.searchResult)) }
    }

    private func refreshKidsLibraryFilter() {
        kidsFilterTask?.cancel()
        guard ProfileManager.shared.isKidsModeActive else {
            kidsBlockedLibraryIds = []
            kidsFilterResolved = true
            return
        }
        kidsFilterResolved = false
        let results = libraryManager.collections.flatMap { $0.items.map(\.searchResult) }

        let initiatingProfileID = ProfileManager.shared.activeProfileID
        kidsFilterTask = Task { @MainActor in
            await TMDBContentFilter.shared.prepareMaturityRatings(for: results)
            guard !Task.isCancelled,
                  ProfileManager.shared.activeProfileID == initiatingProfileID else { return }
            let allowed = Set(TMDBContentFilter.shared.filterSearchResults(results).map(LibraryIdentity.init))
            kidsBlockedLibraryIds = Set(results.map(LibraryIdentity.init)).subtracting(allowed)
            kidsFilterResolved = true
        }
    }
    @State private var isEditing = false
    @State private var draggingId: String?
    @AppStorage(LibraryDisplaySettings.showBookmarksSectionKey)
    private var showsBookmarksSection = LibraryDisplaySettings.defaultShowBookmarksSection
    @AppStorage(LibraryDisplaySettings.collectionLayoutKey)
    private var collectionLayoutRaw = LibraryCollectionLayout.defaultValue.rawValue

#if os(tvOS)
    private enum TVCollectionFocus: Hashable {
        case open(UUID)
        case rename(UUID)
        case delete(UUID)
        case create
    }

    @FocusState private var tvCollectionFocus: TVCollectionFocus?

    @State private var tvCollectionPendingDeletion: LibraryCollection?
    @State private var tvCollectionPendingRename: LibraryCollection?
    @State private var tvRenameText = ""

    private var tvDeleteConfirmationPresented: Binding<Bool> {
        Binding(
            get: { tvCollectionPendingDeletion != nil },
            set: { if !$0 { tvCollectionPendingDeletion = nil } }
        )
    }
#endif

    @StateObject private var accentColorManager = AccentColorManager.shared
    @ObservedObject private var libraryManager = LibraryManager.shared

    @ObservedObject private var contentFilter = TMDBContentFilter.shared
    @Environment(\.heroNamespace) private var heroNamespace

    var body: some View {
        gatedBody
            .onAppear { refreshKidsLibraryFilter() }
            .onDisappear { kidsFilterTask?.cancel() }
            .onChangeComp(of: libraryManager.collections.count) { _, _ in refreshKidsLibraryFilter() }
            .onChangeComp(of: contentFilter.isKidsProfileActive) { _, _ in refreshKidsLibraryFilter() }
            .onChangeComp(of: contentFilter.maturityRatingRevision) { _, _ in refreshKidsLibraryFilter() }

            .onReceive(NotificationCenter.default.publisher(for: .libraryDataDidChange)) { _ in
                refreshKidsLibraryFilter()
            }

            .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in
                refreshKidsLibraryFilter()
            }
    }

    @ViewBuilder
    private var gatedBody: some View {
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
                if showsBookmarksSection {
                    bookmarksSection
                }
                collectionsSection
            }
            .padding(.top)
        }
        .background(SettingsGradientBackground().ignoresSafeArea())
        .navigationTitle("Library")

#if !os(tvOS)
        .navigationBarItems(trailing: HStack(spacing: 18) {
            if hasReorderableContent {
                Button(action: {
                    withAnimation { isEditing.toggle() }
                    if !isEditing { draggingId = nil }
                }) {
                    Image(systemName: isEditing ? "checkmark" : "arrow.up.arrow.down")
                        .foregroundColor(accentColorManager.currentAccentColor)
                }
            }
            Button(action: {
                showingCreateSheet = true
            }) {
                Image(systemName: "plus")
                    .foregroundColor(accentColorManager.currentAccentColor)
            }
        })
#endif
        .sheet(isPresented: $showingCreateSheet) {
            CreateCollectionView()
        }
    }

    private var hasReorderableContent: Bool {
        let bookmarks = showsBookmarksSection
            ? libraryManager.collections.first(where: { $0.name == "Bookmarks" })?.items.count ?? 0
            : 0
        let collections = libraryManager.collections.filter { $0.name != "Bookmarks" }.count
        return bookmarks > 1 || collections > 1
    }

    private var collectionLayout: LibraryCollectionLayout {
        LibraryCollectionLayout(rawValue: collectionLayoutRaw) ?? .defaultValue
    }

    private var reorderGripOverlay: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.white)
            .padding(5)
            .background(Circle().fill(Color.black.opacity(0.55)))
            .padding(6)
    }

    private var bookmarksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
#if os(tvOS)
            tvSectionHeader(
                title: "Bookmarks",
                count: libraryManager.collections
                    .first(where: { $0.name == "Bookmarks" })
                    .map { visibleToProfile($0.items).count }
            )
            .padding(.horizontal)
#else
            EclipseSectionHeader(
                title: "Bookmarks",
                count: libraryManager.collections
                    .first(where: { $0.name == "Bookmarks" })
                    .map { visibleToProfile($0.items).count }
            )
            .padding(.horizontal)
#endif

            if let bookmarksCollection = libraryManager.collections.first(where: { $0.name == "Bookmarks" }),
               !visibleToProfile(bookmarksCollection.items).isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: isTvOS ? 40 : 12) {

                        ForEach(visibleToProfile(bookmarksCollection.items), id: \.searchResult.stableIdentity) { item in
                            let heroID = "library-bookmark-\(item.searchResult.stableIdentity)"
#if !os(tvOS)
                            if isEditing {
                                BookmarkItemCard(item: item, heroID: heroID)
                                    .overlay(reorderGripOverlay, alignment: .topTrailing)
                                    .opacity(draggingId == item.searchResult.stableIdentity ? 0.4 : 1)
                                    .onDrag {
                                        draggingId = item.searchResult.stableIdentity
                                        return NSItemProvider(object: item.searchResult.stableIdentity as NSString)
                                    }
                                    .onDrop(of: [.text], delegate: LibraryReorderDropDelegate(
                                        targetId: item.searchResult.stableIdentity,
                                        orderedIds: { bookmarksCollection.items.map { $0.searchResult.stableIdentity } },
                                        draggingId: { draggingId },
                                        clearDragging: { draggingId = nil },
                                        move: { from, to in
                                            LibraryManager.shared.moveItem(in: bookmarksCollection.id, from: IndexSet(integer: from), to: to)
                                        }
                                    ))
                            } else {
                                NavigationLink(destination: MediaDetailView(searchResult: item.searchResult)
                                    .heroDestination(id: heroID, namespace: heroNamespace)
                                ) {
                                    BookmarkItemCard(item: item, heroID: heroID)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
#else
                            NavigationLink(destination: MediaDetailView(searchResult: item.searchResult)
                                .heroDestination(id: heroID, namespace: heroNamespace)
                            ) {
                                BookmarkItemCard(item: item, heroID: heroID)
                            }
                            .buttonStyle(TVMediaCardButtonStyle())
#endif
                        }
                    }
                    .padding(.horizontal)
                }
            } else {
#if os(tvOS)
                tvEmptyState(
                    icon: "bookmark",
                    title: "No bookmarks yet",
                    message: "Bookmark items to see them here."
                )
#else
                EclipseEmptyState(
                    icon: "bookmark",
                    title: "No bookmarks yet",
                    message: "Bookmark items to see them here."
                )
#endif
            }
        }
    }

    private var collectionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
#if os(tvOS)
            tvSectionHeader(
                title: "Collections",
                count: libraryManager.collections.filter { $0.name != "Bookmarks" }.count
            )
            .padding(.horizontal)
#else
            EclipseSectionHeader(
                title: "Collections",
                count: libraryManager.collections.filter { $0.name != "Bookmarks" }.count
            )
            .padding(.horizontal)
#endif

#if os(tvOS)

            Button {
                showingCreateSheet = true
            } label: {
                Label("New Collection", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .focused($tvCollectionFocus, equals: .create)
            .accessibilityIdentifier("tv.library.newCollection")
            .padding(.horizontal)
#endif

            let nonBookmarkCollections = libraryManager.collections.filter { $0.name != "Bookmarks" }

            if !nonBookmarkCollections.isEmpty {
                if collectionLayout == .horizontal {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: isTvOS ? 40 : 16) {
                            ForEach(nonBookmarkCollections) { collection in
                                collectionCard(for: collection, among: nonBookmarkCollections)
                            }
                        }
                        .padding(.horizontal)
                    }
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: isTvOS ? 320 : 160 * iPadScale), spacing: isTvOS ? 40 : 16)],
                        alignment: .leading,
                        spacing: isTvOS ? 40 : 16
                    ) {
                        ForEach(nonBookmarkCollections) { collection in
                            collectionCard(for: collection, among: nonBookmarkCollections)
                        }
                    }
                    .padding(.horizontal)
                }
            } else {
#if os(tvOS)
                tvEmptyState(
                    icon: "folder.badge.plus",
                    title: "No collections yet",
                    message: "Create collections to organize your media."
                )
#else
                EclipseEmptyState(
                    icon: "folder.badge.plus",
                    title: "No collections yet",
                    message: "Create collections to organize your media."
                )
#endif
            }
        }
#if os(tvOS)
        .alert(
            "Delete Collection",
            isPresented: tvDeleteConfirmationPresented,
            presenting: tvCollectionPendingDeletion
        ) { collection in
            Button("Delete", role: .destructive) {
                deleteCollectionAndRestoreFocus(
                    collection,
                    from: libraryManager.collections.filter { $0.name != "Bookmarks" }
                )
            }
            Button("Cancel", role: .cancel) { }
        } message: { collection in
            Text("\"\(collection.name)\" and its saved items will be removed from your library.")
        }
        .sheet(item: $tvCollectionPendingRename) { collection in
            NavigationView {
                Form {
                    Section {
                        TextField("Collection Name", text: $tvRenameText)
                            .textFieldStyle(.plain)
                            .padding(12)
                            .background(Color.white.opacity(0.08))
                            .cornerRadius(8)
                            .accessibilityIdentifier("tv.library.renameCollection.name")
                    }

                    Section {
                        Button("Save") {
                            LibraryManager.shared.renameCollection(collection, name: tvRenameText)
                            tvCollectionPendingRename = nil
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(tvRenameText.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("tv.library.renameCollection.save")

                        Button("Cancel") { tvCollectionPendingRename = nil }
                            .buttonStyle(.bordered)
                            .accessibilityIdentifier("tv.library.renameCollection.cancel")
                    }
                }
                .navigationTitle("Rename Collection")
            }
            .navigationViewStyle(StackNavigationViewStyle())
        }
#endif
    }

    @ViewBuilder
    private func collectionCard(
        for collection: LibraryCollection,
        among collections: [LibraryCollection]
    ) -> some View {
#if os(tvOS)
        VStack(spacing: 10) {
            NavigationLink(destination: CollectionDetailView(collection: collection)) {
                CollectionCard(collection: collection, visibleItems: visibleToProfile)
            }
            .buttonStyle(TVMediaCardButtonStyle())
            .focused($tvCollectionFocus, equals: .open(collection.id))

            HStack(spacing: 12) {
                Button {
                    tvRenameText = collection.name
                    tvCollectionPendingRename = collection
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .focused($tvCollectionFocus, equals: .rename(collection.id))

                Button(role: .destructive) {
                    tvCollectionPendingDeletion = collection
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .focused($tvCollectionFocus, equals: .delete(collection.id))
            }
        }
#else
        if isEditing {
            CollectionCard(collection: collection, visibleItems: visibleToProfile)
                .overlay(reorderGripOverlay, alignment: .topTrailing)
                .opacity(draggingId == collection.id.uuidString ? 0.4 : 1)
                .onDrag {
                    draggingId = collection.id.uuidString
                    return NSItemProvider(object: collection.id.uuidString as NSString)
                }
                .onDrop(of: [.text], delegate: LibraryReorderDropDelegate(
                    targetId: collection.id.uuidString,
                    orderedIds: { libraryManager.collections.filter { $0.name != "Bookmarks" }.map { $0.id.uuidString } },
                    draggingId: { draggingId },
                    clearDragging: { draggingId = nil },
                    move: { from, to in
                        libraryManager.moveCollections(from: IndexSet(integer: from), to: to)
                    }
                ))
        } else {
            NavigationLink(destination: CollectionDetailView(collection: collection)) {
                CollectionCard(collection: collection, visibleItems: visibleToProfile)
            }
            .buttonStyle(PlainButtonStyle())
        }
#endif
    }

#if os(tvOS)
    private func tvSectionHeader(title: String, count: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title)
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)

            if let count {
                Text("\(count)")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }

            Spacer(minLength: 0)
        }
    }

    private func tvEmptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 64, weight: .regular))
                .foregroundColor(.white.opacity(0.5))

            Text(title)
                .font(.system(size: 31, weight: .semibold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)

            Text(message)
                .font(.system(size: 27))
                .foregroundColor(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 60)
        .padding(.vertical, 40)
    }

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

    private var posterWidth: CGFloat { isTvOS ? 240 : 120 * iPadScale }
    private var posterHeight: CGFloat { isTvOS ? 360 : 180 * iPadScale }

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
                .frame(width: posterWidth, height: posterHeight)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
                .heroSource(id: heroID, namespace: heroNamespace)

            Text(item.searchResult.displayTitle)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
                .foregroundColor(.white)
        }
        .frame(width: posterWidth, alignment: .leading)
    }
}

struct CollectionCard: View {
    @ObservedObject var collection: LibraryCollection

    let visibleItems: ([LibraryItem]) -> [LibraryItem]
    @State private var showingRenameAlert = false
    @State private var renameText = ""

    private var previewItems: [LibraryItem] {
        visibleItems(collection.items)
    }

    private var cardSide: CGFloat { isTvOS ? 320 : 160 * iPadScale }
    private var previewTileSide: CGFloat { isTvOS ? 158 : 78 * iPadScale }

    var body: some View {
        VStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.08))
                .frame(width: cardSide, height: cardSide)
                .overlay(
                    collectionPreview
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))

            VStack(spacing: 4) {
                Text(collection.name)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                Text("\(previewItems.count) items")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(width: cardSide)
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
        let recentItems = Array(previewItems.sorted(by: { $0.dateAdded < $1.dateAdded }).suffix(4))

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
                .frame(width: cardSide, height: cardSide)
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
                        .frame(width: previewTileSide, height: previewTileSide)
                        .clipped()
                        .id(item.id)
                }

                ForEach(recentItems.count..<4, id: \.self) { _ in
                    Rectangle()
                        .fill(Color.gray.opacity(0.1))
                        .frame(width: previewTileSide, height: previewTileSide)
                }
            }
        }
    }
}

#Preview {
    LibraryView()
}
