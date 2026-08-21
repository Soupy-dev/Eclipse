//
//  CollectionDetailView.swift
//  Sora
//
//  Created by Francesco on 08/09/25.
//

import SwiftUI
import Kingfisher
import UniformTypeIdentifiers

struct CollectionDetailView: View {
    @ObservedObject var collection: LibraryCollection

    @ObservedObject private var contentFilter = TMDBContentFilter.shared
    @Environment(\.heroNamespace) private var heroNamespace
    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false
    @State private var draggingId: String?

    @State private var kidsBlockedItemIds: Set<String> = []

    @State private var kidsFilterResolved = false
    @State private var kidsFilterTask: Task<Void, Never>?

    private var visibleItems: [LibraryItem] {
        guard ProfileManager.shared.isKidsModeActive else { return collection.items }
        guard kidsFilterResolved else { return [] }
        return collection.items.filter { !kidsBlockedItemIds.contains($0.searchResult.stableIdentity) }
    }

    private func refreshKidsItemFilter() {
        kidsFilterTask?.cancel()
        guard ProfileManager.shared.isKidsModeActive else {
            kidsBlockedItemIds = []
            kidsFilterResolved = true
            return
        }
        kidsFilterResolved = false
        let results = collection.items.map(\.searchResult)

        let initiatingProfileID = ProfileManager.shared.activeProfileID
        kidsFilterTask = Task { @MainActor in
            await TMDBContentFilter.shared.prepareMaturityRatings(for: results)
            guard !Task.isCancelled,
                  ProfileManager.shared.activeProfileID == initiatingProfileID else { return }
            let allowed = Set(TMDBContentFilter.shared.filterSearchResults(results).map(\.stableIdentity))
            kidsBlockedItemIds = Set(results.map(\.stableIdentity)).subtracting(allowed)
            kidsFilterResolved = true
        }
    }

    private enum TVItemFocus: Hashable {
        case open(String)
        case remove(String)
        case emptyState
    }

    @FocusState private var tvItemFocus: TVItemFocus?

#if os(tvOS)
    @State private var tvItemPendingRemoval: LibraryItem?

    private var tvRemovalConfirmationPresented: Binding<Bool> {
        Binding(
            get: { tvItemPendingRemoval != nil },
            set: { if !$0 { tvItemPendingRemoval = nil } }
        )
    }
#endif

    private var collectionGridColumns: [GridItem] {
        if isTvOS {
            return [GridItem(.adaptive(minimum: 220), spacing: 48)]
        }
        if isIPad {
            return [GridItem(.adaptive(minimum: 176), spacing: 24)]
        }
        return [GridItem(.adaptive(minimum: 120), spacing: 8)]
    }

    private struct CollectionItemButtonModifier: ViewModifier {
        let itemID: String
        let focus: FocusState<TVItemFocus?>.Binding
        let onRemove: () -> Void

        @ViewBuilder
        func body(content: Content) -> some View {
#if os(tvOS)
            content
                .buttonStyle(.card)
                .focused(focus, equals: .open(itemID))
#else
            content
                .buttonStyle(PlainButtonStyle())
                .contextMenu {
                    Button(role: .destructive, action: onRemove) {
                        Label("Remove", systemImage: "trash")
                    }
                }
#endif
        }
    }

    var body: some View {
        ScrollView {
            if visibleItems.isEmpty {
                VStack {
                    Image(systemName: collection.name == "Bookmarks" ? "bookmark" : "folder")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)
                    Text("No items in this collection")
                        .font(.title2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top)
                    Text(collection.name == "Bookmarks" ? "Bookmark items from detail views" : "Add media from detail views")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
#if os(tvOS)
                    Button {
                        dismiss()
                    } label: {
                        Label("Back to Library", systemImage: "chevron.backward")
                    }
                    .buttonStyle(.bordered)
                    .padding(.top, 16)
                    .focused($tvItemFocus, equals: .emptyState)
#endif
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 100)
            } else {
                LazyVGrid(
                    columns: collectionGridColumns,
                    spacing: isTvOS ? 48 : (isIPad ? 24 : 16)
                ) {
                    ForEach(visibleItems, id: \.searchResult.stableIdentity) { item in
                        let heroID = "collection-\(collection.id)-\(item.searchResult.stableIdentity)"
                        VStack(spacing: 10) {
#if !os(tvOS)
                        if isEditing {
                            posterTile(item, heroID: heroID)
                                .overlay(reorderGripOverlay, alignment: .topTrailing)
                                .opacity(draggingId == item.searchResult.stableIdentity ? 0.4 : 1)
                                .onDrag {
                                    draggingId = item.searchResult.stableIdentity
                                    return NSItemProvider(object: item.searchResult.stableIdentity as NSString)
                                }
                                .onDrop(of: [.text], delegate: LibraryReorderDropDelegate(
                                    targetId: item.searchResult.stableIdentity,
                                    orderedIds: { collection.items.map { $0.searchResult.stableIdentity } },
                                    draggingId: { draggingId },
                                    clearDragging: { draggingId = nil },
                                    move: { from, to in
                                        LibraryManager.shared.moveItem(in: collection.id, from: IndexSet(integer: from), to: to)
                                    }
                                ))
                        } else {
                            NavigationLink(destination: MediaDetailView(searchResult: item.searchResult)
                                .heroDestination(id: heroID, namespace: heroNamespace)
                            ) {
                                posterTile(item, heroID: heroID)
                            }
                            .modifier(
                                CollectionItemButtonModifier(
                                    itemID: item.searchResult.stableIdentity,
                                    focus: $tvItemFocus,
                                    onRemove: {
                                        LibraryManager.shared.removeItem(from: collection.id, item: item)
                                    }
                                )
                            )
                        }
#else
                        NavigationLink(destination: MediaDetailView(searchResult: item.searchResult)
                            .heroDestination(id: heroID, namespace: heroNamespace)
                        ) {
                            posterTile(item, heroID: heroID)
                        }
                        .modifier(
                            CollectionItemButtonModifier(
                                itemID: item.searchResult.stableIdentity,
                                focus: $tvItemFocus,
                                onRemove: {
                                    LibraryManager.shared.removeItem(from: collection.id, item: item)
                                }
                            )
                        )
                        Button(role: .destructive) {
                            tvItemPendingRemoval = item
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .focused($tvItemFocus, equals: .remove(item.searchResult.stableIdentity))
#endif
                        }
                    }
                }
#if os(tvOS)
                .padding(.horizontal, 60)
                .padding(.vertical, 32)
#else
                .padding()
#endif
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(collection.name)
        .background(SettingsGradientBackground().ignoresSafeArea())
        .onAppear { refreshKidsItemFilter() }
        .onDisappear { kidsFilterTask?.cancel() }
        .onChangeComp(of: contentFilter.isKidsProfileActive) { _, _ in refreshKidsItemFilter() }
        .onChangeComp(of: contentFilter.maturityRatingRevision) { _, _ in refreshKidsItemFilter() }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDataDidChange)) { _ in
            refreshKidsItemFilter()
        }

        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in
            dismiss()
        }
#if os(tvOS)
        .alert(
            "Remove Item",
            isPresented: tvRemovalConfirmationPresented,
            presenting: tvItemPendingRemoval
        ) { item in
            Button("Remove", role: .destructive) {
                removeItemAndRestoreFocus(item)
            }
            Button("Cancel", role: .cancel) { }
        } message: { item in
            Text("\"\(item.searchResult.displayTitle)\" will be removed from \(collection.name).")
        }
#else
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if collection.items.count > 1 {
                    Button {
                        withAnimation { isEditing.toggle() }
                        if !isEditing { draggingId = nil }
                    } label: {
                        Image(systemName: isEditing ? "checkmark" : "arrow.up.arrow.down")
                    }
                }
            }
        }
#endif
    }

    private func posterTile(_ item: LibraryItem, heroID: String) -> some View {
        VStack {
            if let url = item.searchResult.fullPosterURL {
                KFImage(URL(string: url))
                    .placeholder {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.3))
                    }
                    .resizable()
                    .aspectRatio(2/3, contentMode: .fill)
                    .frame(
                        width: isTvOS ? 220 : 120 * iPadScale,
                        height: isTvOS ? 330 : 180 * iPadScale
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.1), radius: 3, x: 0, y: 1)
                    .heroSource(id: heroID, namespace: heroNamespace)
            }

            Text(item.searchResult.displayTitle)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(1)
                .foregroundColor(.white)
        }
    }

    private var reorderGripOverlay: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.white)
            .padding(5)
            .background(Circle().fill(Color.black.opacity(0.55)))
            .padding(6)
    }

#if os(tvOS)
    private func removeItemAndRestoreFocus(_ item: LibraryItem) {

        let items = visibleItems
        guard let removedIndex = items.firstIndex(where: {
            $0.searchResult.stableIdentity == item.searchResult.stableIdentity
        }) else { return }

        let survivingItems = items.filter {
            $0.searchResult.stableIdentity != item.searchResult.stableIdentity
        }
        let nearestItemID = survivingItems.isEmpty
            ? nil
            : survivingItems[min(removedIndex, survivingItems.count - 1)].searchResult.stableIdentity

        LibraryManager.shared.removeItem(from: collection.id, item: item)

        DispatchQueue.main.async {
            if let nearestItemID {
                tvItemFocus = .open(nearestItemID)
            } else {
                tvItemFocus = .emptyState
            }
        }
    }
#endif
}
