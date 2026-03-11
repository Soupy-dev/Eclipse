//
//  MangaCatalogSettingsView.swift
//  Kanzen
//
//  Created by Luna on 2025.
//

import SwiftUI

#if !os(tvOS)
struct MangaCatalogSettingsView: View {
    @StateObject private var catalogManager = MangaCatalogManager.shared

    var body: some View {
        List {
            Section(header: Text("Reorder and toggle catalogs"), footer: Text("Enabled catalogs appear on the Home tab. Drag to reorder.")) {
                ForEach(catalogManager.catalogs) { catalog in
                    HStack {
                        Image(systemName: catalog.isEnabled ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(catalog.isEnabled ? .accentColor : .secondary)
                            .onTapGesture {
                                catalogManager.toggleCatalog(id: catalog.id)
                            }

                        Text(catalog.name)
                            .foregroundColor(catalog.isEnabled ? .primary : .secondary)

                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .onMove { from, to in
                    catalogManager.moveCatalog(from: from, to: to)
                }
            }
        }
        .navigationTitle("Home Catalogs")
        .navigationBarTitleDisplayMode(.inline)
        .lunaSettingsStyle()
        .toolbar {
            EditButton()
        }
    }
}
#endif
