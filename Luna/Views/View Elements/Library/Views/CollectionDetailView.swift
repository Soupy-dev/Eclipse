//
//  CollectionDetailView.swift
//  Sora
//
//  Created by Francesco on 08/09/25.
//

import SwiftUI
import Kingfisher

struct CollectionDetailView: View {
    @ObservedObject var collection: LibraryCollection
    @Environment(\.heroNamespace) private var heroNamespace
    @State private var scrollOffset: CGFloat = 0
    
    var body: some View {
        ScrollView {
            LunaScrollTracker()

            if collection.items.isEmpty {
                VStack {
                    Image(systemName: collection.name == "Bookmarks" ? "bookmark" : "folder")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)
                    Text("No items in this collection")
                        .font(.title2)
                        .padding(.top)
                    Text(collection.name == "Bookmarks" ? "Bookmark items from detail views" : "Add media from detail views")
                        .foregroundColor(.secondary)
                }
                .frame(maxHeight: .infinity)
                .padding(.top, 100)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: isIPad ? 160 : 120))], spacing: 16) {
                    ForEach(Array(collection.items.enumerated()), id: \.offset) { index, item in
                        let heroID = "collection-\(collection.id)-\(index)-\(item.searchResult.stableIdentity)"
                        NavigationLink(destination: MediaDetailView(searchResult: item.searchResult)
                            .heroDestination(id: heroID, namespace: heroNamespace)
                        ) {
                            VStack {
                                if let url = item.searchResult.fullPosterURL {
                                    KFImage(URL(string: url))
                                        .placeholder {
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(Color.secondary.opacity(0.3))
                                        }
                                        .resizable()
                                        .aspectRatio(2/3, contentMode: .fill)
                                        .frame(width: 120 * iPadScale, height: 180 * iPadScale)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .shadow(color: .black.opacity(0.1), radius: 3, x: 0, y: 1)
                                        .heroSource(id: heroID, namespace: heroNamespace)
                                }
                                
                                Text(item.searchResult.displayTitle)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                    .foregroundColor(.white)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .contextMenu {
                            Button(role: .destructive) {
                                LibraryManager.shared.removeItem(from: collection.id, item: item)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .coordinateSpace(name: "lunaGradientScroll")
        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { scrollOffset = $0 }
        .navigationTitle(collection.name)
        .background(SettingsGradientBackground(scrollOffset: scrollOffset).ignoresSafeArea())
    }
}
