//
//  MangaAddToCollectionView.swift
//  Kanzen
//
//  Created by Eclipse on 2026.
//

import SwiftUI

#if !os(tvOS)
struct MangaAddToCollectionView: View {
    let item: MangaLibraryItem
    @EnvironmentObject var libraryManager: MangaLibraryManager
    @Environment(\.dismiss) private var dismiss
    @State private var authority = ProgressManager.shared.profileMutationAuthority()
    @State private var showCreateCollection = false
    @ObservedObject private var profiles = ProfileManager.shared

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Local")) {
                    ForEach(libraryManager.collections) { collection in
                        Button {
                            guard authority.map(ProgressManager.shared.profileMutationAuthorityIsCurrent) == true else { return }
                            if libraryManager.isItemInCollection(collection.id, item: item) {
                                libraryManager.removeItem(from: collection.id, item: item)
                            } else {
                                libraryManager.addItem(to: collection.id, item: item)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(collection.name)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    Text("\(collection.items.count) items")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if libraryManager.isItemInCollection(collection.id, item: item) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.accentColor)
                                } else {
                                    Image(systemName: "circle")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }

                    Button {
                        guard authority.map(ProgressManager.shared.profileMutationAuthorityIsCurrent) == true else { return }
                        showCreateCollection = true
                    } label: {
                        Label("Create New Collection", systemImage: "plus.circle")
                    }
                }
                TrackerCollectionSections(target: trackerTarget) { match in
                    guard authority.map(ProgressManager.shared.profileMutationAuthorityIsCurrent) == true else { return }
                    var known = libraryManager.collections.flatMap(\.items).first { $0.id == item.id } ?? item
                    let progress = MangaReadingProgressManager.shared.progress(for: item.id)
                    known.trackerAniListId = known.trackerAniListId ?? progress?.trackerAniListId
                    known.trackerMALId = known.trackerMALId ?? progress?.trackerMALId
                    let linked = known.applyingTrackerSelection(aniListID: match.aniListID, malID: match.malID)
                    libraryManager.updateSavedItem(linked)
                    MangaReadingProgressManager.shared.updateTrackerMatch(mangaId: item.id,
                        aniListId: linked.trackerAniListId, malId: linked.trackerMALId,
                        confidence: linked.trackerMatchConfidence, replacingExisting: true)
                }
            }
            .navigationTitle("Add to Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showCreateCollection) {
                MangaCreateCollectionView()
                    .environmentObject(libraryManager)
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .disabled(profiles.isKidsModeActive)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.activeProfileDidChange)) { _ in dismiss() }
    }
    private var trackerTarget: TrackerCollectionTarget {
        let progress = MangaReadingProgressManager.shared.progress(for: item.id)
        return TrackerCollectionTarget(title: item.title, kind: .manga,
            aniListID: item.trackerAniListId ?? progress?.trackerAniListId ?? (item.id > 0 ? item.id : nil),
            malID: item.trackerMALId ?? progress?.trackerMALId)
    }
}
#endif
