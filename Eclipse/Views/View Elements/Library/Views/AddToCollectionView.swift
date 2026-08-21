//
//  AddToCollectionView.swift
//  Sora
//
//  Created by Francesco on 08/09/25.
//

import SwiftUI

struct AddToCollectionView: View {
    let searchResult: TMDBSearchResult
    @Environment(\.dismiss) var dismiss

    @StateObject private var accentColorManager = AccentColorManager.shared
    @ObservedObject private var libraryManager = LibraryManager.shared
    @State private var showingCreateSheet = false
    @State private var selectedCollectionIDs: Set<UUID> = []
#if os(tvOS)
    private enum TVFocus: Hashable {
        case collection(UUID)
        case create
        case done
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
                                if selectedCollectionIDs.contains(collection.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(accentColorManager.currentAccentColor)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
#if os(tvOS)
                        .buttonStyle(.card)
                        .focused($tvFocus, equals: .collection(collection.id))
#else
                        .buttonStyle(.plain)
#endif
                        .accessibilityLabel(collection.name)
                        .accessibilityValue(
                            selectedCollectionIDs.contains(collection.id)
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

#if os(tvOS)

                Button("Done") {
                    dismiss()
                }
                .padding(.bottom)
                .buttonStyle(.bordered)
                .focused($tvFocus, equals: .done)
                .accessibilityIdentifier("tv.addToCollection.done")
#endif
            }
            .navigationTitle("Add to Collection")
#if !os(tvOS)
            .navigationBarItems(
                leading: Button("Cancel") { dismiss() },
                trailing: Button("Done") { dismiss() }
            )
#endif
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .sheet(isPresented: $showingCreateSheet) {
            CreateCollectionView()
        }
        .onAppear {
            syncSelectedCollections()
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
        let isSelected = selectedCollectionIDs.contains(collection.id)
        if isSelected {
            selectedCollectionIDs.remove(collection.id)
            libraryManager.removeItem(from: collection.id, item: item)
        } else {
            selectedCollectionIDs.insert(collection.id)
            libraryManager.addItem(to: collection.id, item: item)
        }
    }

    private func syncSelectedCollections() {
        selectedCollectionIDs = Set(
            libraryManager.collections
                .filter { libraryManager.isItemInCollection($0.id, item: item) }
                .map(\.id)
        )
    }
}
