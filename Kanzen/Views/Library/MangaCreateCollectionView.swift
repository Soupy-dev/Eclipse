//
//  MangaCreateCollectionView.swift
//  Kanzen
//
//  Created by Eclipse on 2026.
//

import SwiftUI

#if !os(tvOS)
struct MangaCreateCollectionView: View {
    @EnvironmentObject var libraryManager: MangaLibraryManager
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var collectionDescription: String = ""

    var body: some View {
        NavigationView {
            Form {
                Section("Collection Name") {
                    TextField("Name", text: $name)
                }

                Section("Description (Optional)") {
                    TextField("Description", text: $collectionDescription)
                }
            }
            .navigationTitle("New Collection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Create") {
                        let desc = collectionDescription.isEmpty ? nil : collectionDescription
                        libraryManager.createCollection(name: name, description: desc)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}
#endif
