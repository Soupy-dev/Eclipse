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
    @State private var showCreateCollection = false

    var body: some View {
        NavigationView {
            List {
                ForEach(libraryManager.collections) { collection in
                    Button {
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
                    showCreateCollection = true
                } label: {
                    Label("Create New Collection", systemImage: "plus.circle")
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
    }
}
#endif
