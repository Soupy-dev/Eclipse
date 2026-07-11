import SwiftUI

struct AddToCollectionView: View {
    let searchResult: TMDBSearchResult
    @Environment(\.dismiss) var dismiss
    
    @StateObject private var accentColorManager = AccentColorManager.shared
    @ObservedObject private var libraryManager = LibraryManager.shared
    @State private var showingCreateSheet = false
#if os(tvOS)
    private enum TVFocus: Hashable {
        case collection(UUID)
        case create
    }

    @FocusState private var tvFocus: TVFocus?
#endif
    
    var item: LibraryItem { LibraryItem(searchResult: searchResult) }
    
    var body: some View {
        NavigationView {
            VStack {
                List {
                    ForEach(libraryManager.collections) { collection in
                        Button {
                            toggleMembership(in: collection)
                        } label: {
                            HStack {
                                Image(systemName: collection.name == "Bookmarks" ? "bookmark.fill" : "folder")
                                    .foregroundColor(collection.name == "Bookmarks" ? .yellow : .primary)
                                VStack(alignment: .leading) {
                                    Text(collection.name)
                                        .fontWeight(collection.name == "Bookmarks" ? .semibold : .regular)
                                    if let desc = collection.description {
                                        Text(desc)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                if libraryManager.isItemInCollection(collection.id, item: item) {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(accentColorManager.currentAccentColor)
                                }
                            }
                        }
#if os(tvOS)
                        .buttonStyle(.card)
                        .focused($tvFocus, equals: .collection(collection.id))
#else
                        .buttonStyle(.plain)
#endif
                        .accessibilityLabel(collection.name)
                        .accessibilityValue(
                            libraryManager.isItemInCollection(collection.id, item: item)
                                ? "Included"
                                : "Not included"
                        )
                        .accessibilityHint("Toggles this title in the collection.")
                    }
                }
                
                Button("Create New Collection") {
                    showingCreateSheet = true
                }
                .padding()
#if os(tvOS)
                .buttonStyle(.borderedProminent)
                .focused($tvFocus, equals: .create)
#endif
            }
            .navigationTitle("Add to Collection")
            .navigationBarItems(
                leading: Button("Cancel") { dismiss() },
                trailing: Button("Done") { dismiss() }
            )
        }
        .sheet(isPresented: $showingCreateSheet) {
            CreateCollectionView()
        }
#if os(tvOS)
        .onAppear {
            tvFocus = libraryManager.collections.first.map { .collection($0.id) } ?? .create
        }
        .onChange(of: showingCreateSheet) { _, isPresented in
            if !isPresented {
                tvFocus = .create
            }
        }
#endif
    }

    private func toggleMembership(in collection: LibraryCollection) {
        if libraryManager.isItemInCollection(collection.id, item: item) {
            libraryManager.removeItem(from: collection.id, item: item)
        } else {
            libraryManager.addItem(to: collection.id, item: item)
        }
    }
}
