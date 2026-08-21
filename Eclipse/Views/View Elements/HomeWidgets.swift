import SwiftUI
import Kingfisher

private struct WidgetCardButtonStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
#if os(tvOS)
        content.buttonStyle(.card)
#else
        content.buttonStyle(PlainButtonStyle())
#endif
    }
}

struct NetworkSectionWidget: View {
    let widgetData: [String: [TMDBSearchResult]]
    let tmdbService: TMDBService
    var metrics: ExperimentalMediaDesignMetrics = .current

    private let networks = WidgetNetwork.active

    var body: some View {
        let availableNetworks = networks.filter { network in
            let items = widgetData["network_\(network.id)"] ?? []
            return !items.isEmpty
        }

        if !availableNetworks.isEmpty {
            VStack(alignment: .leading, spacing: ExperimentalFeatureState.isEnabledAtLaunch ? 18 : 16) {
                Text(HomeWidgetTitle.forCatalog("networks"))
                    .font(isTvOS ? .headline : (ExperimentalFeatureState.isEnabledAtLaunch ? .system(size: isIPad ? 34 : 29, weight: .heavy) : .title2))
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, isTvOS ? 60 : (isIPad ? 24 : 16))

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: isTvOS ? 50 : (ExperimentalFeatureState.isEnabledAtLaunch ? 22 : 16)) {
                        ForEach(availableNetworks) { network in
                            let items = widgetData["network_\(network.id)"] ?? []
                            NavigationLink(destination: DiscoverDetailView(
                                title: network.name,
                                initialItems: items,
                                loadMore: { page in

                                    await TMDBContentFilter.shared.filterSearchResultsResolvingRatings(
                                        (try? await tmdbService.discoverByNetwork(networkId: network.id, page: page)) ?? []
                                    )
                                }
                            )) {
                                networkCard(network: network, items: items)
                            }
                            .modifier(WidgetCardButtonStyle())
                        }
                    }
                    .padding(.horizontal, isTvOS ? 60 : (isIPad ? 24 : 16))
                }
                .modifier(ScrollClipModifier())
            }
            .padding(.top, isTvOS ? 40 : (ExperimentalFeatureState.isEnabledAtLaunch ? metrics.sectionSpacing : 24))
        }
    }

    @ViewBuilder
    private func networkCard(network: WidgetNetwork, items: [TMDBSearchResult]) -> some View {
        let isExperimental = ExperimentalFeatureState.isEnabledAtLaunch
        let s: CGFloat = isExperimental ? metrics.mediaCardScale : 1
        let posterWidth: CGFloat = (isTvOS ? 220 : (isExperimental ? (isIPad ? 124 : 96) : (isIPad ? 100 : 80))) * s
        let posterHeight: CGFloat = (isTvOS ? 326 : (isExperimental ? (isIPad ? 178 : 142) : (isIPad ? 150 : 120))) * s
        let availableWidth = max(UIScreen.main.bounds.width - 44, 280)
        let maxCardWidth: CGFloat = (isTvOS ? 720 : (isIPad ? 430 : 318)) * s
        let cardWidth: CGFloat = isExperimental ? min(maxCardWidth, availableWidth) : (isIPad ? 340 : 260)
        let cardHeight: CGFloat = (isTvOS ? 386 : (isExperimental ? (isIPad ? 214 : 168) : (isIPad ? 190 : 160))) * s
        let radius = isExperimental ? metrics.cardRadius : 16

        ZStack(alignment: .leading) {
            HStack(spacing: isTvOS ? -46 : -20) {
                Spacer()
                ForEach(Array(items.prefix(3).enumerated()), id: \.element.id) { index, item in
                    KFImage(URL(string: item.fullPosterURL ?? ""))
                        .setProcessor(DownsamplingImageProcessor(size: homeImageDecodeSize(width: posterWidth, height: posterHeight)))
                        .placeholder { Color.gray.opacity(0.3) }
                        .resizable()
                        .aspectRatio(2/3, contentMode: .fill)
                        .frame(width: posterWidth, height: posterHeight)
                        .clipShape(RoundedRectangle(cornerRadius: isTvOS ? 20 : (isExperimental ? 13 : 10), style: .continuous))
                        .rotationEffect(.degrees(Double(index - 1) * 5))
                        .offset(y: index == 1 ? -5 : 5)
                        .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 5)
                }
            }
            .padding(.trailing, isTvOS ? 46 : (isExperimental ? 20 : 12))
            .padding(.vertical, isTvOS ? 28 : 12)

            VStack(alignment: .leading, spacing: isTvOS ? 14 : 6) {
                Text(network.name)
                    .font(isTvOS ? .title2 : (isExperimental ? .system(size: isIPad ? 34 : 28, weight: .heavy) : .title2))
                    .fontWeight(.heavy)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
            }
            .padding(.leading, isTvOS ? 56 : (isExperimental ? 24 : 16))
        }
        .frame(width: cardWidth, height: cardHeight)
        .background(
            LinearGradient(
                colors: isExperimental
                    ? [Color.black.opacity(0.58), Color(red: 0.12, green: 0.10, blue: 0.15).opacity(metrics.glassOpacity)]
                    : [Color.white.opacity(0.12), Color.white.opacity(0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.white.opacity(isExperimental ? 0.12 : 0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(isExperimental ? 0.28 : 0), radius: 18, x: 0, y: 10)
    }
}

struct GenreSectionWidget: View {
    let widgetData: [String: [TMDBSearchResult]]
    let tmdbService: TMDBService
    var metrics: ExperimentalMediaDesignMetrics = .current

    private let genres = WidgetGenre.active

    var body: some View {
        let availableGenres = genres.filter { !(widgetData["genre_\($0.id)"] ?? []).isEmpty }

        if !availableGenres.isEmpty {
            VStack(alignment: .leading, spacing: ExperimentalFeatureState.isEnabledAtLaunch ? 18 : 16) {
                Text(HomeWidgetTitle.forCatalog("genres"))
                    .font(isTvOS ? .headline : (ExperimentalFeatureState.isEnabledAtLaunch ? .system(size: isIPad ? 34 : 29, weight: .heavy) : .title2))
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, isTvOS ? 60 : (isIPad ? 24 : 16))

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: isTvOS ? 50 : (ExperimentalFeatureState.isEnabledAtLaunch ? 22 : 16)) {
                        ForEach(availableGenres) { genre in
                            let items = widgetData["genre_\(genre.id)"] ?? []
                            NavigationLink(destination: DiscoverDetailView(
                                title: genre.name,
                                initialItems: items,
                                loadMore: { page in

                                    await TMDBContentFilter.shared.filterSearchResultsResolvingRatings(
                                        (try? await tmdbService.discoverByGenre(genreId: genre.id, page: page)) ?? []
                                    )
                                }
                            )) {
                                genreCard(genre: genre, items: items)
                            }
                            .modifier(WidgetCardButtonStyle())
                        }
                    }
                    .padding(.horizontal, isTvOS ? 60 : (isIPad ? 24 : 16))
                }
                .modifier(ScrollClipModifier())
            }
            .padding(.top, isTvOS ? 40 : (ExperimentalFeatureState.isEnabledAtLaunch ? metrics.sectionSpacing : 24))
        }
    }

    @ViewBuilder
    private func genreCard(genre: WidgetGenre, items: [TMDBSearchResult]) -> some View {
        let isExperimental = ExperimentalFeatureState.isEnabledAtLaunch
        let s: CGFloat = isExperimental ? metrics.mediaCardScale : 1
        let posterWidth: CGFloat = (isTvOS ? 220 : (isExperimental ? (isIPad ? 124 : 96) : (isIPad ? 100 : 80))) * s
        let posterHeight: CGFloat = (isTvOS ? 326 : (isExperimental ? (isIPad ? 178 : 142) : (isIPad ? 150 : 120))) * s
        let availableWidth = max(UIScreen.main.bounds.width - 44, 280)
        let maxCardWidth: CGFloat = (isTvOS ? 720 : (isIPad ? 430 : 318)) * s
        let cardWidth: CGFloat = isExperimental ? min(maxCardWidth, availableWidth) : (isIPad ? 340 : 260)
        let cardHeight: CGFloat = (isTvOS ? 386 : (isExperimental ? (isIPad ? 214 : 168) : (isIPad ? 190 : 160))) * s
        let radius = isExperimental ? metrics.cardRadius : 16

        ZStack(alignment: .leading) {
            HStack(spacing: isTvOS ? -46 : -20) {
                Spacer()
                ForEach(Array(items.prefix(3).enumerated()), id: \.element.id) { index, item in
                    KFImage(URL(string: item.fullPosterURL ?? item.fullBackdropURL ?? ""))
                        .setProcessor(DownsamplingImageProcessor(size: homeImageDecodeSize(width: posterWidth, height: posterHeight)))
                        .placeholder { Color.gray.opacity(0.3) }
                        .resizable()
                        .aspectRatio(2/3, contentMode: .fill)
                        .frame(width: posterWidth, height: posterHeight)
                        .clipShape(RoundedRectangle(cornerRadius: isTvOS ? 20 : (isExperimental ? 13 : 10), style: .continuous))
                        .rotationEffect(.degrees(Double(index - 1) * 5))
                        .offset(y: index == 1 ? -5 : 5)
                        .shadow(color: .black.opacity(0.22), radius: 8, x: 0, y: 5)
                }
            }
            .padding(.trailing, isTvOS ? 46 : (isExperimental ? 20 : 12))
            .padding(.vertical, isTvOS ? 28 : 12)

            Text(genre.name)
                .font(isTvOS ? .title2 : (isExperimental ? .system(size: isIPad ? 32 : 27, weight: .heavy) : .title2))
                .fontWeight(.heavy)
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
                .frame(width: cardWidth * 0.5, alignment: .leading)
                .padding(.leading, isTvOS ? 56 : (isExperimental ? 24 : 16))
        }
        .frame(width: cardWidth, height: cardHeight)
        .background(
            LinearGradient(
                colors: isExperimental
                    ? [Color.black.opacity(0.58), Color(red: 0.12, green: 0.10, blue: 0.15).opacity(metrics.glassOpacity)]
                    : [Color.white.opacity(0.12), Color.white.opacity(0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.white.opacity(isExperimental ? 0.12 : 0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(isExperimental ? 0.28 : 0), radius: 18, x: 0, y: 10)
    }
}

struct CompanySectionWidget: View {
    let widgetData: [String: [TMDBSearchResult]]
    let tmdbService: TMDBService
    var metrics: ExperimentalMediaDesignMetrics = .current

    private let companies = WidgetCompany.active
    var body: some View {
        let availableCompanies = companies.filter { !(widgetData["company_\($0.id)"] ?? []).isEmpty }

        if !availableCompanies.isEmpty {
            VStack(alignment: .leading, spacing: ExperimentalFeatureState.isEnabledAtLaunch ? 18 : 16) {
                Text(HomeWidgetTitle.forCatalog("companies"))
                    .font(isTvOS ? .headline : (ExperimentalFeatureState.isEnabledAtLaunch ? .system(size: isIPad ? 34 : 29, weight: .heavy) : .title2))
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, isTvOS ? 60 : (isIPad ? 24 : 16))

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: isTvOS ? 50 : (ExperimentalFeatureState.isEnabledAtLaunch ? 22 : 16)) {
                        ForEach(availableCompanies) { company in
                            let items = widgetData["company_\(company.id)"] ?? []
                            NavigationLink(destination: DiscoverDetailView(
                                title: company.name,
                                initialItems: items,
                                loadMore: { page in

                                    await TMDBContentFilter.shared.filterSearchResultsResolvingRatings(
                                        (try? await tmdbService.discoverByCompany(companyId: company.id, page: page)) ?? []
                                    )
                                }
                            )) {
                                companyCard(company: company, items: items)
                            }
                            .modifier(WidgetCardButtonStyle())
                        }
                    }
                    .padding(.horizontal, isTvOS ? 60 : (isIPad ? 24 : 16))
                }
                .modifier(ScrollClipModifier())
            }
            .padding(.top, isTvOS ? 40 : (ExperimentalFeatureState.isEnabledAtLaunch ? metrics.sectionSpacing : 24))
        }
    }

    @ViewBuilder
    private func companyCard(company: WidgetCompany, items: [TMDBSearchResult]) -> some View {
        let isExperimental = ExperimentalFeatureState.isEnabledAtLaunch
        let s: CGFloat = isExperimental ? metrics.mediaCardScale : 1
        let cardWidth: CGFloat = (isTvOS ? 600 : (isExperimental ? (isIPad ? 340 : 264) : (isIPad ? 300 : 232))) * s
        let cardHeight: CGFloat = (isTvOS ? 282 : (isExperimental ? (isIPad ? 150 : 124) : 104)) * s
        let radius = isExperimental ? metrics.cardRadius : 14

        ZStack {
            if let backdropURL = items.first?.fullBackdropURL {
                KFImage(URL(string: backdropURL))
                    .setProcessor(DownsamplingImageProcessor(size: homeImageDecodeSize(width: cardWidth, height: cardHeight)))
                    .placeholder { Color.gray.opacity(0.15) }
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: cardWidth, height: cardHeight)
                    .clipped()
                    .overlay(Color.black.opacity(isExperimental ? 0.42 : 0.55))
            } else {
                Color.black.opacity(isExperimental ? 0.52 : 0.2)
            }

            Text(company.name)
                .font(isTvOS ? .title2 : (isExperimental ? .system(size: isIPad ? 28 : 22, weight: .heavy) : (isIPad ? .title3 : .headline)))
                .fontWeight(.heavy)
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
                .padding(.horizontal, isTvOS ? 32 : 14)
                .shadow(color: .black.opacity(0.6), radius: 4, x: 0, y: 2)
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.white.opacity(isExperimental ? 0.12 : 0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(isExperimental ? 0.24 : 0), radius: 16, x: 0, y: 8)
    }
}

struct RankedListWidget: View {
    let catalogId: String
    let title: String
    let items: [TMDBSearchResult]
    let tmdbService: TMDBService
    var metrics: ExperimentalMediaDesignMetrics = .current

    var body: some View {
        if !items.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: isTvOS ? 50 : (ExperimentalFeatureState.isEnabledAtLaunch ? 22 : 16)) {
                    NavigationLink(destination: DiscoverDetailView(
                        title: title,
                        initialItems: items
                    )) {
                        rankedCard(title: title, items: items)
                    }
                    .modifier(WidgetCardButtonStyle())
                }
                .padding(.horizontal, isTvOS ? 60 : (isIPad ? 24 : 16))
            }
            .modifier(ScrollClipModifier())
            .padding(.top, isTvOS ? 40 : (ExperimentalFeatureState.isEnabledAtLaunch ? metrics.sectionSpacing : 24))
        }
    }

    @ViewBuilder
    private func rankedCard(title: String, items: [TMDBSearchResult]) -> some View {
        let isExperimental = ExperimentalFeatureState.isEnabledAtLaunch
        let s: CGFloat = isExperimental ? metrics.mediaCardScale : 1
        let posterWidth: CGFloat = (isTvOS ? 235 : (isExperimental ? (isIPad ? 132 : 102) : (isIPad ? 112 : 86))) * s
        let posterHeight: CGFloat = (isTvOS ? 376 : (isExperimental ? 164 : 140)) * s
        let cardWidth: CGFloat = isTvOS
            ? 720 * s
            : (isExperimental
               ? min(CGFloat(isIPad ? 420 : 318) * s, max(UIScreen.main.bounds.width - 44, 280))
               : (isIPad ? 360 : 280))
        let radius = isExperimental ? metrics.cardRadius : 16

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: isTvOS ? 10 : 4) {
                ForEach(Array(items.prefix(3).enumerated()), id: \.element.id) { _, item in
                    KFImage(URL(string: item.fullPosterURL ?? ""))
                        .setProcessor(DownsamplingImageProcessor(size: homeImageDecodeSize(width: posterWidth, height: posterHeight)))
                        .placeholder { Color.gray.opacity(0.3) }
                        .resizable()
                        .aspectRatio(2/3, contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: posterHeight)
                        .clipped()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: isTvOS ? 22 : (isExperimental ? 16 : 10), style: .continuous))
            .padding(.horizontal, isTvOS ? 24 : (isExperimental ? 14 : 12))
            .padding(.top, isTvOS ? 24 : (isExperimental ? 14 : 12))

            HStack(spacing: isTvOS ? 14 : 6) {
#if os(tvOS)
                Image(systemName: "laurel.leading")
                    .font(.caption)
                    .foregroundColor(.yellow.opacity(0.7))
#endif

                Text(title)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .lineLimit(1)

                Image(systemName: "laurel.trailing")
                    .font(.caption)
                    .foregroundColor(.yellow.opacity(0.7))
            }
            .padding(.top, isTvOS ? 24 : 12)
            .padding(.horizontal, isTvOS ? 24 : (isExperimental ? 14 : 12))

            VStack(alignment: .leading, spacing: isTvOS ? 14 : 6) {
                ForEach(Array(items.prefix(3).enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: isTvOS ? 18 : 8) {
                        Text("\(index + 1)")
                            .font(.subheadline)
                            .fontWeight(.heavy)
                            .foregroundColor(.yellow.opacity(0.8))
                            .frame(width: isTvOS ? 46 : 20)

                        Text(item.displayTitle)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.9))
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, isTvOS ? 32 : (isExperimental ? 14 : 12))
            .padding(.top, isTvOS ? 20 : 10)
            .padding(.bottom, isTvOS ? 30 : 14)
        }
        .frame(width: cardWidth, alignment: .leading)
        .background(
            LinearGradient(
                colors: isExperimental
                    ? [Color.black.opacity(0.56), Color(red: 0.13, green: 0.10, blue: 0.16).opacity(metrics.glassOpacity)]
                    : [Color.white.opacity(0.1), Color.white.opacity(0.04)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.white.opacity(isExperimental ? 0.12 : 0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(isExperimental ? 0.28 : 0), radius: 18, x: 0, y: 10)
    }
}

struct FeaturedSpotlightWidget: View {
    let widgetData: [String: [TMDBSearchResult]]
    let genreName: String
    let tmdbService: TMDBService
    var metrics: ExperimentalMediaDesignMetrics = .current

    private var spotlightTitle: String {
        let trimmedGenre = genreName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedGenre.isEmpty ? "Popular" : "Popular \u{00B7} \(trimmedGenre)"
    }

    var body: some View {
        let items = widgetData["featured"] ?? []

        if let spotlight = items.first {
            if ExperimentalFeatureState.isEnabledAtLaunch {
                experimentalSpotlightBody(spotlight: spotlight, items: items)
            } else {
                legacySpotlightBody(spotlight: spotlight, items: items)
            }
        }
    }

    @ViewBuilder
    private func experimentalSpotlightBody(spotlight: TMDBSearchResult, items: [TMDBSearchResult]) -> some View {
        let radius = metrics.cardRadius + 10
        let trailingItems = Array(items.dropFirst().prefix(8))

        VStack(spacing: 0) {
            NavigationLink(destination: spotlightDestination(items: items)) {
                experimentalSpotlightBanner(spotlight: spotlight)
            }
            .modifier(WidgetCardButtonStyle())

            if !trailingItems.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: isTvOS ? 50 : (isIPad ? 22 : 16)) {
                        ForEach(trailingItems) { item in
                            NavigationLink(destination: MediaDetailView(searchResult: item)) {
                                spotlightSmallCard(item: item, forceLandscape: true)
                            }
                            .modifier(WidgetCardButtonStyle())
                        }
                    }
                    .padding(.horizontal, isTvOS ? 60 : (isIPad ? 24 : 16))
                    .padding(.vertical, isTvOS ? 46 : (isIPad ? 26 : 20))
                }
                .modifier(ScrollClipModifier())
                .background(

                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.05),
                            Color.black.opacity(0.22)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
        .background(Color.black.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.34), radius: 24, x: 0, y: 14)
        .padding(.horizontal, isTvOS ? 60 : (isIPad ? 24 : 16))
        .padding(.top, isTvOS ? 40 : metrics.sectionSpacing)
    }

    @ViewBuilder
    private func legacySpotlightBody(spotlight: TMDBSearchResult, items: [TMDBSearchResult]) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            NavigationLink(destination: spotlightDestination(items: items)) {
                spotlightBanner(spotlight: spotlight)
            }
            .modifier(WidgetCardButtonStyle())

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(Array(items.dropFirst().prefix(8))) { item in
                        NavigationLink(destination: MediaDetailView(searchResult: item)) {
                            spotlightSmallCard(item: item, forceLandscape: false)
                        }
                        .modifier(WidgetCardButtonStyle())
                    }
                }
                .padding(.horizontal, isIPad ? 24 : 16)
            }
            .modifier(ScrollClipModifier())
        }
        .padding(.top, 24)
    }

    private func spotlightDestination(items: [TMDBSearchResult]) -> DiscoverDetailView {
        DiscoverDetailView(
            title: spotlightTitle,
            initialItems: items,
            heroItem: items.first,
            loadMore: loadFeaturedPage
        )
    }

    private func loadFeaturedPage(_ page: Int) async -> [TMDBSearchResult] {
        guard let genre = WidgetGenre.active.first(where: { $0.name == genreName }) else { return [] }

        return await TMDBContentFilter.shared.filterSearchResultsResolvingRatings(
            (try? await tmdbService.discoverByGenre(genreId: genre.id, mediaType: "tv", page: page)) ?? []
        )
    }

    @ViewBuilder
    private func experimentalSpotlightBanner(spotlight: TMDBSearchResult) -> some View {
        let bannerHeight: CGFloat = (isTvOS ? 580 : (isIPad ? 350 : 252)) * metrics.mediaCardScale

        ZStack(alignment: .center) {
            KFImage(URL(string: spotlight.fullBackdropURL ?? spotlight.fullPosterURL ?? ""))
                .setProcessor(DownsamplingImageProcessor(size: homeImageDecodeSize(width: UIScreen.main.bounds.width, height: bannerHeight)))
                .placeholder {
                    Rectangle().fill(Color.gray.opacity(0.2))
                }
                .resizable()
                .aspectRatio(16/9, contentMode: .fill)
                .frame(height: bannerHeight)
                .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.16), .black.opacity(0.58)],
                startPoint: .top,
                endPoint: .bottom
            )

            LinearGradient(
                colors: [.clear, .black.opacity(0.34), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: bannerHeight * 0.7)
            .allowsHitTesting(false)

            VStack(alignment: .center, spacing: isTvOS ? 18 : 8) {
                HStack(spacing: isTvOS ? 14 : 6) {
                    Image(systemName: "laurel.leading")
                        .font(isIPad ? .title : .title2)
                        .foregroundColor(.white.opacity(0.86))

                    Text(spotlightTitle)
                        .font(isTvOS ? .title : .system(size: isIPad ? 34 : 28, weight: .heavy))
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Image(systemName: "laurel.trailing")
                        .font(isIPad ? .title : .title2)
                        .foregroundColor(.white.opacity(0.86))
                }

                Text(spotlight.displayTitle)
                    .font(isTvOS ? .headline : .system(size: isIPad ? 20 : 17, weight: .medium))
                    .foregroundColor(.white.opacity(0.74))
                    .lineLimit(1)
            }
            .padding(isTvOS ? 50 : 22)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity)
        .frame(height: bannerHeight)
    }

    @ViewBuilder
    private func spotlightBanner(spotlight: TMDBSearchResult) -> some View {
        let bannerHeight: CGFloat = isIPad ? 280 : 200
        let radius: CGFloat = 16

        ZStack(alignment: .bottomLeading) {
            KFImage(URL(string: spotlight.fullBackdropURL ?? spotlight.fullPosterURL ?? ""))
                .setProcessor(DownsamplingImageProcessor(size: homeImageDecodeSize(width: UIScreen.main.bounds.width, height: bannerHeight)))
                .placeholder {
                    Rectangle().fill(Color.gray.opacity(0.2))
                }
                .resizable()
                .aspectRatio(16/9, contentMode: .fill)
                .frame(height: bannerHeight)
                .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.7), .black.opacity(0.9)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "laurel.leading")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.86))

                    Text(spotlightTitle)
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Image(systemName: "laurel.trailing")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.86))
                }

                Text(spotlight.displayTitle)
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))
                    .lineLimit(1)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .frame(height: bannerHeight)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .clear, radius: 0, x: 0, y: 0)
        .padding(.horizontal, isIPad ? 24 : 16)
    }

    @ViewBuilder
    private func spotlightSmallCard(item: TMDBSearchResult, forceLandscape: Bool) -> some View {
        let isLandscape = ExperimentalFeatureState.isEnabledAtLaunch || forceLandscape
        let s: CGFloat = ExperimentalFeatureState.isEnabledAtLaunch ? metrics.mediaCardScale : 1
        let posterWidth = CGFloat(isTvOS ? (isLandscape ? 400 : 280) : (isLandscape ? 176 : 120)) * iPadScale * s
        let posterHeight = CGFloat(isTvOS ? (isLandscape ? 225 : 380) : (isLandscape ? 99 : 180)) * iPadScale * s
        let posterShadowRadius: CGFloat = isIPad ? 3 : 6
        let radius = isLandscape ? max(metrics.cardRadius - 2, 14) : 12

        VStack(alignment: .leading, spacing: isTvOS ? 14 : 6) {
            KFImage(URL(string: isLandscape ? (item.fullBackdropURL ?? item.fullPosterURL ?? "") : (item.fullPosterURL ?? "")))
                .setProcessor(DownsamplingImageProcessor(size: homeImageDecodeSize(width: posterWidth, height: posterHeight)))
                .placeholder {
                    FallbackImageView(
                        isMovie: item.isMovie,
                        size: CGSize(width: posterWidth, height: posterHeight)
                    )
                }
                .resizable()
                .aspectRatio(isLandscape ? 16/9 : 2/3, contentMode: .fill)
                .frame(width: posterWidth, height: posterHeight)
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: isLandscape ? 12 : posterShadowRadius, x: 0, y: isLandscape ? 7 : 3)

            Text(item.displayTitle)
                .font(isTvOS ? .headline : .system(size: isLandscape ? 18 : 12, weight: .medium))
                .fontWeight(.medium)
                .foregroundColor(.white)
                .lineLimit(1)
                .frame(width: posterWidth, alignment: .leading)

            HStack(spacing: isTvOS ? 10 : 4) {
                if !item.displayDate.isEmpty {
                    let date = item.displayDate
                    Text(isLandscape ? String(date.prefix(4)) : String(date.prefix(10)))
                        .font(isTvOS ? .subheadline : .system(size: isLandscape ? 15 : 11, weight: .regular))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .frame(width: posterWidth, alignment: .leading)
        }
    }
}

enum HomeWidgetTitle {
    static func forCatalog(_ id: String) -> String {
        CatalogManager.shared.catalogs.first { $0.id == id }?.name ?? fallback(id)
    }

    private static func fallback(_ id: String) -> String {
        switch id {
        case "networks": return "Network"
        case "genres": return "Category"
        case "companies": return "Company"
        default: return ""
        }
    }
}
