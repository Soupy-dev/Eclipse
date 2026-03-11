//
//  KanzenHomeView.swift
//  Kanzen
//
//  Created by Luna on 2025.
//

import SwiftUI
import Kingfisher

#if !os(tvOS)
struct KanzenHomeView: View {
    @StateObject private var homeViewModel = MangaHomeViewModel()
    @StateObject private var catalogManager = MangaCatalogManager.shared

    private var enabledCatalogs: [MangaCatalog] {
        catalogManager.getEnabledCatalogs()
    }

    var body: some View {
        NavigationView {
            Group {
                if homeViewModel.isLoading && homeViewModel.catalogResults.isEmpty {
                    ProgressView("Loading manga…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = homeViewModel.errorMessage, homeViewModel.catalogResults.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text(error)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Retry") {
                            homeViewModel.resetContent()
                            homeViewModel.loadContent(catalogManager: catalogManager)
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            let visibleCatalogs = enabledCatalogs.filter { catalog in
                                if let items = homeViewModel.catalogResults[catalog.id], !items.isEmpty {
                                    return true
                                }
                                return false
                            }
                            
                            ForEach(Array(visibleCatalogs.enumerated()), id: \.element.id) { index, catalog in
                                if let items = homeViewModel.catalogResults[catalog.id], !items.isEmpty {
                                    MangaCatalogSection(
                                        title: catalog.name,
                                        items: Array(items.prefix(15))
                                    )
                                    
                                    if index < visibleCatalogs.count - 1 {
                                        SectionDivider()
                                    }
                                }
                            }
                        }
                        .padding(.bottom, 30)
                    }
                    .refreshable {
                        homeViewModel.resetContent()
                        homeViewModel.loadContent(catalogManager: catalogManager)
                    }
                }
            }
            .background(GlobalGradientBackground().ignoresSafeArea())
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.large)
        }
        .task {
            homeViewModel.loadContent(catalogManager: catalogManager)
        }
    }
}

// MARK: - Catalog Section (Horizontal Row)

struct MangaCatalogSection: View {
    let title: String
    let items: [AniListManga]

    private let cellWidth: CGFloat = isIPad ? 140 * iPadScaleSmall : 140
    private var gap: Double { isIPad ? 28.0 : 14.0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: gap) {
                    ForEach(items) { manga in
                        NavigationLink(destination: MangaDetailView(manga: manga)) {
                            contentCell(
                                title: manga.displayTitle,
                                urlString: manga.coverURL ?? "",
                                width: cellWidth
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .modifier(KanzenScrollClipModifier())
        }
        .padding(.top, 20)
    }
}

struct KanzenScrollClipModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.scrollClipDisabled()
        } else {
            content
        }
    }
}
#endif
