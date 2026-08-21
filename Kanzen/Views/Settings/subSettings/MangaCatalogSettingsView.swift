//
//  MangaCatalogSettingsView.swift
//  Kanzen
//
//  Created by Eclipse on 2025.
//

import SwiftUI

#if !os(tvOS)
struct MangaCatalogSettingsView: View {
    @StateObject private var readerExtensionManager = ReaderExtensionManager.shared
    @StateObject private var contentFilter = ReaderContentFilter.shared
    @StateObject private var customCatalogManager = KanzenCustomCatalogManager.shared
    @State private var errorMessage: String?

    private var sources: [ReaderExtensionInstalledSource] {
        readerExtensionManager.installedSources.sorted {
            if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        Group {
            if contentFilter.isKidsProfileActive {
                restrictedView
            } else {
                sourceList
            }
        }
        .navigationTitle("Home Sources")
        .navigationBarTitleDisplayMode(.inline)
        .eclipseSettingsStyle()
        .preferredColorScheme(.dark)
        .toolbar {
            if !contentFilter.isKidsProfileActive {
                EditButton()
                    .disabled(sources.isEmpty)
            }
        }
        .onChange(of: contentFilter.isKidsProfileActive) { isKids in
            if isKids { errorMessage = nil }
        }
        .alert("Reader Extensions", isPresented: Binding(
            get: { errorMessage != nil && !contentFilter.isKidsProfileActive },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var restrictedView: some View {
        List {
            Section {
                Text("Reader sources and discovery settings cannot be viewed from a kids profile. Switch to a grown-up profile to continue.")
                    .foregroundColor(.secondary)
            }
        }
    }

    private var sourceList: some View {
        List {
            Section(
                header: Text("Custom Catalogs"),
                footer: Text("Save a filtered search from any Reader source and it becomes an extra row on Discover.")
            ) {
                NavigationLink(destination: KanzenCustomCatalogsView()) {
                    HStack(spacing: 12) {
                        Image(systemName: "rectangle.stack.badge.plus")
                            .foregroundColor(.accentColor)
                            .frame(width: 28, height: 28)
                        Text("Custom Catalogs")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                        Text("\(customCatalogManager.catalogs.count)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .eclipseExperimentalSettingsRows()
            .background(EclipseScrollTracker())

            Section(
                header: Text("Reader Extension Home Sources"),
                footer: Text("Enabled Reader Extensions appear on Discover. Mature sources remain hidden there unless Show Mature Sources is enabled. Legacy Kanzen JavaScript modules remain available for compatibility but do not provide home feeds.")
            ) {
                if sources.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "books.vertical")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No Reader Extensions Installed")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        NavigationLink(destination: ReaderExtensionsSettingsView()) {
                            Text("Manage Reader Sources")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                } else {
                    ForEach(sources) { source in
                        HStack(spacing: 12) {
                            Image(systemName: source.mediaType == .manga ? "books.vertical" : "text.book.closed")
                                .foregroundColor(source.enabled ? .accentColor : .secondary)
                                .frame(width: 28, height: 28)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .foregroundColor(source.enabled ? .primary : .secondary)
                                Text("\(source.effectiveLanguage.uppercased()) · \(source.mediaType == .manga ? "Manga" : "Web Novel")")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if source.maturity == .mature && !readerExtensionManager.showMatureSources {
                                    Text("Hidden by mature-source setting")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }
                            }

                            Spacer()

                            Toggle("", isOn: Binding(
                                get: { source.enabled },
                                set: {
                                    guard !ProfileManager.shared.isKidsModeActive else { return }
                                    do { try readerExtensionManager.setEnabled($0, for: source.id) }
                                    catch { errorMessage = error.localizedDescription }
                                }
                            ))
                            .labelsHidden()
                        }
                    }
                    .onMove { offsets, destination in
                        guard !ProfileManager.shared.isKidsModeActive else { return }
                        do {
                            try readerExtensionManager.moveInstalledSources(from: offsets, to: destination)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }
            .eclipseExperimentalSettingsRows()
            .background(EclipseScrollTracker())
        }
    }
}
#endif
