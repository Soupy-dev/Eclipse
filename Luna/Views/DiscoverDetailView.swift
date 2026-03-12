//
//  DiscoverDetailView.swift
//  Luna
//
//  Full-page grid shown when tapping a widget card (network, genre, company, etc.)
//

import SwiftUI
import Kingfisher

struct DiscoverDetailView: View {
    let title: String
    let initialItems: [TMDBSearchResult]
    var heroItem: TMDBSearchResult? = nil
    var loadMore: ((Int) async -> [TMDBSearchResult])? = nil
    
    @State private var items: [TMDBSearchResult] = []
    @State private var currentPage = 1
    @State private var isLoadingMore = false
    @State private var hasMorePages = true
    @Environment(\.heroNamespace) private var heroNamespace
    
    private let columns = [
        GridItem(.adaptive(minimum: 110, maximum: 180), spacing: 16)
    ]
    
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                if let hero = heroItem {
                    heroHeader(hero)
                }
                
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(items) { item in
                        NavigationLink(destination: MediaDetailView(searchResult: item)
                            .heroDestination(id: "discover-\(item.id)", namespace: heroNamespace)
                        ) {
                            discoverCard(item)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .onAppear {
                            if item.id == items.last?.id {
                                loadNextPage()
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, heroItem != nil ? 16 : 8)
                
                if isLoadingMore {
                    ProgressView()
                        .padding(.vertical, 20)
                }
                
                Spacer(minLength: 80)
            }
        }
        .background(LunaTheme.shared.backgroundBase.ignoresSafeArea())
        .navigationTitle(title)
#if os(iOS)
        .navigationBarTitleDisplayMode(.large)
#endif
        .onAppear {
            if items.isEmpty {
                items = initialItems
            }
        }
    }
    
    @ViewBuilder
    private func heroHeader(_ hero: TMDBSearchResult) -> some View {
        ZStack(alignment: .bottomLeading) {
            KFImage(URL(string: hero.fullBackdropURL ?? hero.fullPosterURL ?? ""))
                .placeholder {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                }
                .resizable()
                .aspectRatio(16/9, contentMode: .fill)
                .frame(height: 220)
                .clipped()
            
            LinearGradient(
                colors: [.clear, LunaTheme.shared.backgroundBase],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 100)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(hero.displayTitle)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .lineLimit(1)
                
                HStack(spacing: 8) {
                    if !hero.displayDate.isEmpty {
                        Text(hero.displayDate)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                    }
                    if let genres = hero.genreIds, let firstGenre = genres.first,
                       let genreName = WidgetGenre.curated.first(where: { $0.id == firstGenre })?.name {
                        Text(genreName)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }
    
    @ViewBuilder
    private func discoverCard(_ item: TMDBSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            KFImage(URL(string: item.fullPosterURL ?? ""))
                .placeholder {
                    FallbackImageView(
                        isMovie: item.isMovie,
                        size: CGSize(width: 120, height: 180)
                    )
                }
                .resizable()
                .aspectRatio(2/3, contentMode: .fill)
                .frame(minWidth: 0, maxWidth: .infinity)
                .aspectRatio(2/3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)
                .heroSource(id: "discover-\(item.id)", namespace: heroNamespace)
            
            Text(item.displayTitle)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .lineLimit(1)
            
            HStack(spacing: 4) {
                if !item.displayDate.isEmpty {
                    let date = item.displayDate
                    Text(String(date.prefix(4)))
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.6))
                }
                
                if let vote = item.voteAverage, vote > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.yellow)
                        Text(String(format: "%.1f", vote))
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
            }
        }
    }
    
    private func loadNextPage() {
        guard let loadMore = loadMore, !isLoadingMore, hasMorePages else { return }
        isLoadingMore = true
        currentPage += 1
        Task {
            let newItems = await loadMore(currentPage)
            await MainActor.run {
                if newItems.isEmpty {
                    hasMorePages = false
                } else {
                    let existingIds = Set(items.map { $0.id })
                    let unique = newItems.filter { !existingIds.contains($0.id) }
                    items.append(contentsOf: unique)
                }
                isLoadingMore = false
            }
        }
    }
}
