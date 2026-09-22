//
//  AddToCollectionView.swift
//  Sora
//
//  Created by Francesco on 08/09/25.
//

import SwiftUI

struct AddToCollectionView: View {
    let searchResult: TMDBSearchResult
    var trackerTargets: [TrackerCollectionTarget] = []
    @ObservedObject private var profiles = ProfileManager.shared
    @Environment(\.dismiss) var dismiss

    @StateObject private var accentColorManager = AccentColorManager.shared
    @ObservedObject private var libraryManager = LibraryManager.shared
    @State private var showingCreateSheet = false
    @State private var authority = ProgressManager.shared.profileMutationAuthority()
    private var selectedCollectionIDs: Set<UUID> {
        Set(libraryManager.collections.filter { libraryManager.isItemInCollection($0.id, item: item) }.map(\.id))
    }
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
                    Section(header: Text("Local")) {
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
                            .buttonStyle(TVGlassRowButtonStyle())
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
                    TrackerCollectionSections(target: trackerTargets.first ?? TrackerCollectionTarget(media: searchResult),
                        seriesTargets: trackerTargets)
                }

                Button("Create New Collection") {
                    guard authority.map(ProgressManager.shared.profileMutationAuthorityIsCurrent) == true else { return }
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
#endif
        }
        .providerNavigationStyle()
        .disabled(profiles.isKidsModeActive)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.activeProfileDidChange)) { _ in dismiss() }
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
        guard authority.map(ProgressManager.shared.profileMutationAuthorityIsCurrent) == true else { return }
        let isSelected = selectedCollectionIDs.contains(collection.id)
        if isSelected {
            libraryManager.removeItem(from: collection.id, item: item)
        } else {
            libraryManager.addItem(to: collection.id, item: item)
        }
    }

}
