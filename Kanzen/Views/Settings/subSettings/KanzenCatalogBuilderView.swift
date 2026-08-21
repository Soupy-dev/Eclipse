//
//  KanzenCatalogBuilderView.swift
//  Kanzen
//
//  Created by Eclipse on 2026.
//

import SwiftUI

#if !os(tvOS)
struct KanzenCatalogBuilderView: View {
    let sources: [ReaderExtensionInstalledSource]
    let onSaved: (KanzenCustomCatalog) -> Void
    let onCancel: () -> Void

    @StateObject private var catalogManager = KanzenCustomCatalogManager.shared

    var body: some View {
        NavigationView {
            List {
                Section(
                    header: Text("Reader Source"),
                    footer: Text("Pick the source this catalog reads from. Its own filters come next, then a name and a row style.")
                ) {
                    if sources.isEmpty {
                        Text("No reader source is enabled. Enable one under Reader Sources first.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(sources) { source in
                            sourceLink(source)
                        }
                    }
                }
                .eclipseExperimentalSettingsRows()
                .background(EclipseScrollTracker())
            }
            .navigationTitle("New Catalog")
            .navigationBarTitleDisplayMode(.inline)
            .eclipseSettingsStyle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
    }

    private func sourceLink(_ source: ReaderExtensionInstalledSource) -> some View {
        let hasRoom = catalogManager.canAddCatalog(for: source.id)
        return NavigationLink(
            destination: KanzenCatalogFilterStepView(source: source, onSaved: onSaved)
        ) {
            VStack(alignment: .leading, spacing: 3) {
                Text(source.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(hasRoom ? .primary : .secondary)
                Text("\(source.effectiveLanguage.uppercased()) \u{00b7} \(source.mediaType == .manga ? "Manga" : "Web Novel")")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if !hasRoom {
                    Text("Catalog limit reached. Delete one from this source first.")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
        }
        .disabled(!hasRoom)
    }
}

private struct KanzenCatalogFilterStepView: View {
    let source: ReaderExtensionInstalledSource
    let onSaved: (KanzenCustomCatalog) -> Void

    @StateObject private var filterEditor = ReaderExtensionFilterEditorModel()
    @State private var query = ""

    var body: some View {
        List {
            Section(
                header: Text("Title Contains"),
                footer: Text("Optional. Leave this empty to catalog whatever the filters return.")
            ) {
                TextField("Any title", text: $query)
                    .autocorrectionDisabled()
            }
            .eclipseExperimentalSettingsRows()
            .background(EclipseScrollTracker())

            Section(
                header: Text("Filters"),
                footer: Text("These are \(source.name)'s own filters. Whatever is selected here is what the Discover row loads.")
            ) {
                filterContent
            }
            .eclipseExperimentalSettingsRows()
            .background(EclipseScrollTracker())

            Section {
                NavigationLink(destination: namingStep) {
                    Text("Name and Save")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
                .disabled(filterEditor.isLoading)
            }
            .eclipseExperimentalSettingsRows()
            .background(EclipseScrollTracker())
        }
        .navigationTitle(source.name)
        .navigationBarTitleDisplayMode(.inline)
        .eclipseSettingsStyle()
        .preferredColorScheme(.dark)
        .task {
            filterEditor.load(sourceID: source.id, label: String(source.id.rawValue.prefix(12)))
        }
        .onDisappear {
            filterEditor.cancel()
        }
    }

    @ViewBuilder
    private var filterContent: some View {
        if let message = filterEditor.errorMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundColor(.orange)
        }

        if filterEditor.isLoading {
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading filters...")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
        } else if filterEditor.filters.isEmpty {
            Text("This source does not expose filters. The catalog will hold everything it returns.")
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            ReaderExtensionFilterEditorList(filters: $filterEditor.filters)
                .padding(.vertical, 6)
        }
    }

    private var namingStep: some View {
        KanzenCatalogNamingStepView(
            sourceName: source.name,
            sourceID: source.id,
            query: $query,
            filterEditor: filterEditor,
            onSaved: onSaved
        )
    }
}

private struct KanzenCatalogNamingStepView: View {
    let sourceName: String
    let sourceID: ReaderExtensionSourceID
    @Binding var query: String
    @ObservedObject var filterEditor: ReaderExtensionFilterEditorModel
    let onSaved: (KanzenCustomCatalog) -> Void

    @State private var title = ""
    @State private var displayStyle: KanzenCatalogDisplayStyle = .poster
    @State private var errorMessage: String?
    @State private var hasSaved = false

    private var draft: KanzenCustomCatalog {
        KanzenCustomCatalog(
            title: title,
            sourceID: sourceID,
            query: query,
            filters: filterEditor.filters,
            displayStyle: displayStyle
        )
    }

    var body: some View {
        Form {
            KanzenCustomCatalogEditorFields(
                sourceName: sourceName,
                draft: draft,
                title: $title,
                displayStyle: $displayStyle,
                errorMessage: errorMessage
            )
        }
        .navigationTitle("Save as Catalog")
        .navigationBarTitleDisplayMode(.inline)
        .eclipseSettingsStyle()
        .preferredColorScheme(.dark)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(hasSaved)
            }
        }
    }

    private func save() {
        guard !hasSaved else { return }
        switch KanzenCustomCatalogEditorSave.perform(draft) {
        case .success(let saved):
            errorMessage = nil
            hasSaved = true
            onSaved(saved)
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }
}
#endif
