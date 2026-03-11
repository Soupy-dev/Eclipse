//
//  CatalogsSettingsView.swift
//  Luna
//
//  Created by Soupy-dev
//

import SwiftUI

struct CatalogsSettingsView: View {
    @ObservedObject private var catalogManager = CatalogManager.shared
    @StateObject private var accentColorManager = AccentColorManager.shared
    @State private var editMode = EditMode.active
    
    var body: some View {
        List {
            Section {
                ForEach(catalogManager.catalogs.indices, id: \.self) { index in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(catalogManager.catalogs[index].name)
                                .font(.subheadline)
                                .fontWeight(.medium)
                            
                            Text("Source: \(catalogManager.catalogs[index].source.rawValue)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        Toggle("", isOn: Binding(
                            get: { catalogManager.catalogs[index].isEnabled },
                            set: { _ in catalogManager.toggleCatalog(id: catalogManager.catalogs[index].id) }
                        ))
                        .tint(accentColorManager.currentAccentColor)
                    }
                }
                .onMove(perform: catalogManager.moveCatalog)
            } header: {
                Text("Content Catalogs")
            } footer: {
                Text("Enable/disable content catalogs and drag to reorder them. The order here determines the order on your home screen.")
            }
            
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("TMDB")
                            .fontWeight(.semibold)
                        Spacer()
                        Text("Movies & TV Shows")
                            .foregroundColor(.secondary)
                    }
                    
                    HStack {
                        Text("AniList")
                            .fontWeight(.semibold)
                        Spacer()
                        Text("Anime")
                            .foregroundColor(.secondary)
                    }
                }
                .font(.caption)
            } header: {
                Text("Sources")
            }
        }
        .navigationTitle("Catalogs")
        .lunaSettingsStyle()
        .environment(\.editMode, $editMode)
    }
}
