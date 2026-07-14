import SwiftUI
import Kingfisher

struct CollectionDetailView: View {
    @ObservedObject var collection: LibraryCollection
    @Environment(\.heroNamespace) private var heroNamespace
    @Environment(\.dismiss) private var dismiss

    private enum TVItemFocus: Hashable {
        case open(String)
        case remove(String)
        case emptyState
    }

    @FocusState private var tvItemFocus: TVItemFocus?

    private var collectionGridColumns: [GridItem] {
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
            if collection.items.isEmpty {
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
                    spacing: isIPad ? 24 : 16
                ) {
                    ForEach(collection.items, id: \.searchResult.stableIdentity) { item in
                        let heroID = "collection-\(collection.id)-\(item.searchResult.stableIdentity)"
                        VStack(spacing: 10) {
                        NavigationLink(destination: MediaDetailView(searchResult: item.searchResult)
                            .heroDestination(id: heroID, namespace: heroNamespace)
                        ) {
                            VStack {
                                if let url = item.searchResult.fullPosterURL {
                                    KFImage(URL(string: url))
                                        .placeholder {
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(Color.secondary.opacity(0.3))
                                        }
                                        .resizable()
                                        .aspectRatio(2/3, contentMode: .fill)
                                        .frame(width: 120 * iPadScale, height: 180 * iPadScale)
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
                        .modifier(
                            CollectionItemButtonModifier(
                                itemID: item.searchResult.stableIdentity,
                                focus: $tvItemFocus,
                                onRemove: {
                                    LibraryManager.shared.removeItem(from: collection.id, item: item)
                                }
                            )
                        )
#if os(tvOS)
                        Button(role: .destructive) {
                            removeItemAndRestoreFocus(item)
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
                .padding()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(collection.name)
        .background(SettingsGradientBackground().ignoresSafeArea())
    }

#if os(tvOS)
    private func removeItemAndRestoreFocus(_ item: LibraryItem) {
        let items = collection.items
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
