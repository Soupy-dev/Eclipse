// Full-page grid shown when tapping a widget card (network, genre, company, etc.)

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
    
    private var columns: [GridItem] {
        if isIPad {
            return [
                GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 24, alignment: .top)
            ]
        }
        return [
            GridItem(.adaptive(minimum: 110, maximum: 180), spacing: 16)
        ]
    }
    
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                if let hero = heroItem {
                    heroHeader(hero)
                }
                
                LazyVGrid(columns: columns, spacing: isIPad ? 30 : 20) {
                    ForEach(items, id: \.stableIdentity) { item in
                        NavigationLink(destination: MediaDetailView(searchResult: item)
                            .heroDestination(id: "discover-\(item.stableIdentity)", namespace: heroNamespace)
                        ) {
                            discoverCard(item)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .onAppear {
                            if item.stableIdentity == items.last?.stableIdentity {
                                loadNextPage()
                            }
                        }
                    }
                }
                .padding(.horizontal, isIPad ? 28 : 16)
                .padding(.top, heroItem != nil ? (isIPad ? 28 : 16) : 8)
                
                if isLoadingMore {
                    EclipseLoadingIndicator()
                        .padding(.vertical, 20)
                }
                
                Spacer(minLength: 80)
            }
        }
        .eclipseBackground()
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
        Group {
            if isIPad {
                ZStack(alignment: .bottomLeading) {
                    KFImage(URL(string: hero.fullBackdropURL ?? hero.fullPosterURL ?? ""))
                        .placeholder {
                            Rectangle()
                                .fill(Color.gray.opacity(0.2))
                                .aspectRatio(16/9, contentMode: .fit)
                        }
                        .resizable()
                        .aspectRatio(16/9, contentMode: .fit)

                    LinearGradient(
                        colors: [.clear, Color.black.opacity(0.12), EclipseTheme.shared.backgroundBase.opacity(0.86)],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    heroHeaderText(hero)
                        .padding(.horizontal, 22)
                        .padding(.bottom, 18)
                }
                .frame(maxWidth: 1080)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.30), radius: 20, x: 0, y: 12)
                .padding(.horizontal, 28)
                .padding(.top, 16)
                .frame(maxWidth: .infinity)
            } else {
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
                        colors: [.clear, EclipseTheme.shared.backgroundBase],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 100)

                    heroHeaderText(hero)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
            }
        }
    }

    private func heroHeaderText(_ hero: TMDBSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(hero.displayTitle)
                .font(isIPad ? .title2 : .headline)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .lineLimit(1)

            HStack(spacing: 8) {
                if !hero.displayDate.isEmpty {
                    Text(hero.displayDate)
                        .font(isIPad ? .subheadline : .caption)
                        .foregroundColor(.white.opacity(0.72))
                }
                if let genres = hero.genreIds, let firstGenre = genres.first,
                   let genreName = WidgetGenre.curated.first(where: { $0.id == firstGenre })?.name {
                    Text(genreName)
                        .font(isIPad ? .subheadline : .caption)
                        .foregroundColor(.white.opacity(0.72))
                }
            }
        }
    }

    @ViewBuilder
    private func iPadDiscoverCard(_ item: TMDBSearchResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            KFImage(URL(string: item.fullBackdropURL ?? item.fullPosterURL ?? ""))
                .placeholder {
                    FallbackImageView(
                        isMovie: item.isMovie,
                        size: CGSize(width: 320, height: 180)
                    )
                }
                .resizable()
                .aspectRatio(16/9, contentMode: .fill)
                .frame(maxWidth: .infinity)
                .aspectRatio(16/9, contentMode: .fit)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.28), radius: 9, x: 0, y: 5)
                .heroSource(id: "discover-\(item.stableIdentity)", namespace: heroNamespace)

            Text(item.displayTitle)
                .font(.headline)
                .fontWeight(.semibold)
                .foregroundColor(.white)
                .lineLimit(1)

            HStack(spacing: 8) {
                if !item.displayDate.isEmpty {
                    Text(String(item.displayDate.prefix(4)))
                }

                if let vote = item.voteAverage, vote > 0 {
                    Label(String(format: "%.1f", vote), systemImage: "star.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundColor(.white.opacity(0.72))
                }
            }
            .font(.caption)
            .foregroundColor(.white.opacity(0.58))
        }
    }

    @ViewBuilder
    private func phoneDiscoverCard(_ item: TMDBSearchResult) -> some View {
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
                .heroSource(id: "discover-\(item.stableIdentity)", namespace: heroNamespace)

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

    @ViewBuilder
    private func discoverCard(_ item: TMDBSearchResult) -> some View {
        if isIPad {
            iPadDiscoverCard(item)
        } else {
            phoneDiscoverCard(item)
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
                    let existingIds = Set(items.map { $0.stableIdentity })
                    let unique = newItems.filter { !existingIds.contains($0.stableIdentity) }
                    items.append(contentsOf: unique)
                }
                isLoadingMore = false
            }
        }
    }
}
