//
//  CatalogsSettingsView.swift
//  Eclipse
//
//  Created by Soupy-dev
//

import SwiftUI

struct CatalogsSettingsView: View {
    @ObservedObject private var catalogManager = CatalogManager.shared
    @ObservedObject private var trackerManager = TrackerManager.shared
    @StateObject private var accentColorManager = AccentColorManager.shared
    @State private var editMode = EditMode.active

    var body: some View {
        catalogsContent
            .navigationTitle("Catalogs")
            .accessibilityIdentifier("tv.settings.catalogs.screen")
            .eclipseSettingsStyle()
#if !os(tvOS)
            .environment(\.editMode, $editMode)
#endif
            .onAppear {
                StremioAddonManager.shared.loadAddons()
            }
    }

    @ViewBuilder
    private var catalogsContent: some View {
#if os(tvOS)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                Text("Content Catalogs")
                    .font(.title2.weight(.semibold))

                ForEach(Array(catalogManager.visibleCatalogs.enumerated()), id: \.element.id) { index, catalog in
                    HStack(spacing: 22) {
                        catalogIdentity(catalog)

                        Spacer(minLength: 20)

                        Toggle("Enabled", isOn: Binding(
                            get: { catalogManager.isCatalogEffectivelyEnabled(catalog) },
                            set: { _ in catalogManager.toggleCatalog(id: catalog.id) }
                        ))
                        .labelsHidden()
                        .tint(accentColorManager.currentAccentColor)
                        .accessibilityLabel("Enable \(catalog.name)")

                        Button {
                            moveCatalog(at: index, by: -1)
                        } label: {
                            Label("Move Up", systemImage: "chevron.up")
                        }
                        .disabled(index == 0)
                        .accessibilityIdentifier("tv.catalog.\(catalog.id).moveUp")

                        Button {
                            moveCatalog(at: index, by: 1)
                        } label: {
                            Label("Move Down", systemImage: "chevron.down")
                        }
                        .disabled(index == catalogManager.visibleCatalogs.count - 1)
                        .accessibilityIdentifier("tv.catalog.\(catalog.id).moveDown")
                    }
                    .padding(.horizontal, 30)
                    .padding(.vertical, 22)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.white.opacity(0.075))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                    )
                    .focusSection()
                }

                Text("Enable or disable content catalogs and use the arrow buttons to reorder them. The order here determines the order on your home screen.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
            }
            .padding(.horizontal, 70)
            .padding(.vertical, 34)
        }
#else
        List {
            Section {
                ForEach(catalogManager.visibleCatalogs) { catalog in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(catalog.name)
                                .font(.subheadline)
                                .fontWeight(.medium)

                            HStack(spacing: 6) {
                                Text(sourceText(for: catalog))
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                if catalogManager.isCatalogLockedByPerformanceMode(catalog) {
                                    Image(systemName: "lock.fill")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }

                                if catalog.displayStyle != .standard {
                                    Text("\u{00B7} \(displayStyleText(for: catalog.displayStyle))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { catalogManager.isCatalogEffectivelyEnabled(catalog) },
                            set: { _ in catalogManager.toggleCatalog(id: catalog.id) }
                        ))
                        .tint(accentColorManager.currentAccentColor)

                    }
                }
                .onMove(perform: catalogManager.moveVisibleCatalog)
            } header: {
                Text("Content Catalogs")
            } footer: {
                Text("Enable/disable content catalogs and drag to reorder them. The order here determines the order on your home screen. Stremio catalog addons may reduce performance or have visual inconsistencies. Trakt catalogs appear after Trakt is connected.")
            }
            .eclipseExperimentalSettingsRows()
            .background(EclipseScrollTracker())
        }
#endif
    }

    private func catalogIdentity(_ catalog: Catalog) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(catalog.name)
                .font(.headline)

            HStack(spacing: 6) {
                Text(sourceText(for: catalog))
                    .font(.caption)
                    .foregroundColor(.secondary)

                if catalogManager.isCatalogLockedByPerformanceMode(catalog) {
                    Image(systemName: "lock.fill")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                if catalog.displayStyle != .standard {
                    Text("\u{00B7} \(displayStyleText(for: catalog.displayStyle))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func moveCatalog(at index: Int, by offset: Int) {
        let destination = index + offset
        let catalogs = catalogManager.visibleCatalogs
        guard catalogs.indices.contains(index), catalogs.indices.contains(destination) else { return }
        catalogManager.moveVisibleCatalog(
            from: IndexSet(integer: index),
            to: offset < 0 ? destination : destination + 1
        )
    }

    private func sourceText(for catalog: Catalog) -> String {
        if catalogManager.isCatalogLockedByPerformanceMode(catalog) {
            return "Source: Performance Mode - AniList locked"
        }
        if catalog.source == .stremio,
           let addonName = catalog.stremioAddonName,
           !addonName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Source: Stremio · \(addonName)"
        }
        if catalog.source == .trakt,
           let listIdentifier = catalog.traktListDisplayIdentifier {
            let mediaType = Catalog.normalizedTraktListMediaType(catalog.traktListMediaType) == "movies" ? "Movies" : "Shows"
            return "Source: Trakt - List \(listIdentifier) - \(mediaType)"
        }
        if catalog.id == Catalog.traktContinueWatchingCatalogId {
            return "Source: Trakt - Continue Watching"
        }
        return "Source: \(catalog.source.rawValue)"
    }

    private func displayStyleText(for style: Catalog.CatalogDisplayStyle) -> String {
        switch style {
        case .continueWatching:
            return "Playback"
        default:
            return style.rawValue.capitalized
        }
    }
}
