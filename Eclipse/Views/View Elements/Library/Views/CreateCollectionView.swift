//
//  CreateCollectionView.swift
//  Sora
//
//  Created by Francesco on 08/09/25.
//

import SwiftUI

struct CreateCollectionView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var libraryManager = LibraryManager.shared

    @State private var name = ""
    @State private var description = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("Collection Name", text: $name)
#if os(tvOS)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(8)
                        .accessibilityIdentifier("tv.createCollection.name")
#endif
                    TextField("Description (optional)", text: $description)
#if os(tvOS)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(8)
                        .accessibilityIdentifier("tv.createCollection.description")
#endif

                    if let errorMessage {
                        Text(errorMessage)
                            .font(isTvOS ? .body : .footnote)
                            .foregroundColor(.red)
                    }
                }

#if os(tvOS)

                Section {
                    Button("Create") { createCollection() }
                        .buttonStyle(.borderedProminent)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("tv.createCollection.create")

                    Button("Cancel") { dismiss() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("tv.createCollection.cancel")
                }
#endif
            }
            .navigationTitle("New Collection")
#if !os(tvOS)
            .navigationBarItems(
                leading: Button("Cancel") { dismiss() },
                trailing: Button("Create") { createCollection() }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            )
#endif
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func createCollection() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        let trimmedDescription = description.trimmingCharacters(in: .whitespaces)
        guard libraryManager.createCollection(
            name: trimmedName,
            description: trimmedDescription.isEmpty ? nil : trimmedDescription
        ) else {
            errorMessage = "\(LibraryManager.bookmarksCollectionName) is reserved for the pinned bookmarks collection. Pick another name."
            return
        }
        dismiss()
    }
}
