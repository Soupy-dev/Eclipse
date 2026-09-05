//
//  SearchView.swift
//  Sora
//
//  Created by Francesco on 07/08/25.
//

import SwiftUI

enum SearchGridLayoutPolicy {
    static func columnCount(_ storedCount: Int) -> Int {
        min(max(storedCount, 1), 10)
    }
}

struct SearchView: View {
    @AppStorage("mediaColumnsPortrait") private var mediaColumnsPortrait: Int = 3
    @AppStorage("mediaColumnsLandscape") private var mediaColumnsLandscape: Int = 5
#if os(tvOS)
    @AppStorage("tvCardDensity") private var tvCardDensity = "standard"
#endif
    @AppStorage("tmdbLanguage") private var selectedLanguage = "en-US"
    @AppStorage("searchHistory") private var searchHistoryData: Data = Data()

    @State private var searchText = ""
    @State private var searchResults: [TMDBSearchResult] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchFilter: SearchFilter = .all
    @State private var searchHistory: [String] = []
    @State private var showingBrowse = false
    @State private var randomResult: TMDBSearchResult?
    @State private var isLoadingRandom = false
    @State private var randomErrorMessage: String?
    @State private var pendingSearchTask: Task<Void, Never>?
    @State private var lastSubmittedSearchQuery = ""
    @State private var searchRequestSerial = 0
#if os(tvOS)
    @FocusState private var tvFocusedResultID: String?
    @State private var tvSearchIsVisible = false
    @State private var tvSearchPresentationGeneration = UUID()
#endif

    @StateObject private var tmdbService = TMDBService.shared
    @StateObject private var contentFilter = TMDBContentFilter.shared
    @Environment(\.verticalSizeClass) var verticalSizeClass

    enum SearchFilter: String, CaseIterable {
        case all = "All"
        case movies = "Movies"
        case tvShows = "TV Shows"
    }

    var filteredResults: [TMDBSearchResult] {
        switch searchFilter {
        case .all:
            return searchResults
        case .movies:
            return searchResults.filter { $0.isMovie }
        case .tvShows:
            return searchResults.filter { $0.isTVShow }
        }
    }

    private var columnsCount: Int {
#if os(tvOS)
        switch tvCardDensity {
        case "spacious": return 4
        case "compact": return 6
        default: return 5
        }
#else
        if UIDevice.current.userInterfaceIdiom == .pad {
            let screenWidth = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.screen })
                .first?.bounds.width ?? 1024

            let isLandscape = screenWidth > (UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.screen })
                .first?.bounds.height ?? 768)
            return isLandscape ? mediaColumnsLandscape : mediaColumnsPortrait
        } else {
            return verticalSizeClass == .compact ? mediaColumnsLandscape : mediaColumnsPortrait
        }
#endif
    }

    private var searchGridColumns: [GridItem] {
#if os(tvOS)
        Array(repeating: GridItem(.flexible(), spacing: 16), count: SearchGridLayoutPolicy.columnCount(columnsCount))
#else
        if isIPad {
            return [GridItem(.adaptive(minimum: 154, maximum: 190), spacing: 24)]
        }
        return Array(repeating: GridItem(.flexible(), spacing: 16), count: SearchGridLayoutPolicy.columnCount(columnsCount))
#endif
    }

    var body: some View {
#if os(tvOS)
        searchContent
#else
        if #available(iOS 16.0, *) {
            NavigationStack {
                searchContent
            }
        } else {
            NavigationView {
                searchContent
            }
            .navigationViewStyle(StackNavigationViewStyle())
        }
#endif
    }

    private var searchContent: some View {
        ScrollView {
#if os(tvOS)
            if !searchResults.isEmpty {
                HStack {
                    Spacer()
                    searchFilterMenu
                }
                .padding()
            }
#else
            VStack(spacing: 12) {
                HStack {
                    Spacer()
                    randomButton
                }

                HStack(spacing: 8) {
                    SearchBarEclipse(text: $searchText) {
                        performSearch(force: true)
                    }

                    if !searchResults.isEmpty {
                        searchFilterMenu
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: searchResults.isEmpty)

                browseButton
            }
            .padding()
#endif

            if isLoading && searchResults.isEmpty {
                VStack {
                    EclipseLoadingIndicator()
                        .scaleEffect(1.2)

                    Text("Searching...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = errorMessage, searchResults.isEmpty {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .imageScale(.large)
                        .font(.system(size: 60))
                        .foregroundColor(.orange)

                    Text("Error")
                        .font(.title2)
                        .foregroundColor(.primary)
                        .padding(.top)

                    Text(errorMessage)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Button("Try Again") {
                        performSearch(force: true)
                    }
                    .padding(.top)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if searchText.isEmpty {
                if searchHistory.isEmpty {
                    VStack {
                        Image(systemName: "magnifyingglass.circle")
                            .imageScale(.large)
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)

                        Text("Search Movies & TV Shows")
                            .font(.title2)
                            .foregroundColor(.secondary)
                            .padding()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("Recent Searches")
                                .font(.headline)
                                .foregroundColor(.primary)

                            Spacer()

                            Button("Clear") {
                                clearSearchHistory()
                            }
                            .font(isTvOS ? .system(size: 26) : .caption)
                        }
                        .padding(.horizontal)
                        .padding(.top)

                        VStack(spacing: 0) {
                            ForEach(Array(searchHistory.enumerated()), id: \.offset) { index, historyItem in
                                HStack(spacing: 12) {
                                    Button(action: {
                                        searchText = historyItem
                                        performSearch(force: true)
                                    }) {
                                        HStack {
                                            Image(systemName: "clock")
                                                .foregroundColor(.secondary)
                                                .font(.system(size: isTvOS ? 24 : 16))

                                            Text(historyItem)
                                                .foregroundColor(.primary)
                                                .font(.body)
                                                .multilineTextAlignment(.leading)

                                            Spacer()
                                        }
                                        .contentShape(Rectangle())
                                    }
#if os(tvOS)
                                    .buttonStyle(.bordered)
#else
                                    .buttonStyle(PlainButtonStyle())
#endif

                                    Button(action: {
                                        removeFromSearchHistory(at: index)
                                    }) {
                                        Image(systemName: "xmark")
                                            .foregroundColor(.secondary)
                                            .font(.system(size: isTvOS ? 24 : 14))
                                    }
#if os(tvOS)
                                    .buttonStyle(.bordered)
#else
                                    .buttonStyle(PlainButtonStyle())
#endif
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 8)

                                if index < searchHistory.count - 1 {
                                    Divider()
                                        .padding(.leading, 40)
                                }
                            }
                        }
                        .clipped()

                        Spacer()
                    }
                }
            } else if filteredResults.isEmpty && !searchResults.isEmpty {
                VStack {
                    Image(systemName: "tv.and.hifispeaker.fill")
                        .imageScale(.large)
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)

                    Text("No \(searchFilter.rawValue.lowercased()) found")
                        .font(.title2)
                        .foregroundColor(.secondary)
                        .padding()

                    Text("Try adjusting your filter or search for something else")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if searchResults.isEmpty {
                VStack {
                    Image(systemName: "questionmark.circle")
                        .imageScale(.large)
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)

                    Text("No results found")
                        .font(.title2)
                        .foregroundColor(.secondary)
                        .padding()

                    Text("Try searching for a different movie or TV show")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LazyVGrid(
                    columns: searchGridColumns,
                    spacing: isIPad ? 24 : 16
                ) {
                    ForEach(filteredResults, id: \.stableIdentity) { result in
                        SearchResultCard(result: result)
#if os(tvOS)
                            .focused($tvFocusedResultID, equals: result.stableIdentity)
                            .accessibilityIdentifier("tv.search.result.\(result.stableIdentity)")
#endif
                    }
                }
                .padding(.horizontal)
                .padding(.top)
            }

#if os(tvOS)
            VStack(spacing: 24) {
                HStack {
                    Spacer()
                    randomButton
                }

                browseButton
            }
            .padding()
#endif
        }
        .overlay(alignment: .bottom) {
            if !searchText.isEmpty && !filteredResults.isEmpty {
                if isLoading {
                    HStack(spacing: 10) {
                        EclipseLoadingIndicator()
                        Text("Updating results")
                            .font(.caption)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(24)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Updating search results")
                } else if errorMessage != nil {
                    Label("Could not refresh results", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(24)
                        .allowsHitTesting(false)
                }
            }
        }
        .navigationTitle("Search")
#if os(tvOS)
        .searchable(text: $searchText, prompt: "Movies & TV Shows")
        .onSubmit(of: .search) {
            performSearch(force: true)
        }
#endif
        .onChangeComp(of: searchText) { _, newValue in
            scheduleSearch(for: newValue)
        }
        .eclipseBackground()
        .background {
            browseNavigationLink
            randomNavigationLink
        }
        .alert("Couldn't Find a Random Title", isPresented: Binding(
            get: { randomErrorMessage != nil },
            set: { if !$0 { randomErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(randomErrorMessage ?? "Please try again.")
        }
        .onChangeComp(of: selectedLanguage) { _, _ in
            if !searchText.isEmpty && !searchResults.isEmpty {
                performSearch(force: true)
            }
        }
        .onChangeComp(of: contentFilter.filterHorror) { _, _ in
            if !searchText.isEmpty && !searchResults.isEmpty {
                performSearch(force: true)
            }
        }
        .onAppear {
#if os(tvOS)
            tvSearchIsVisible = true
            tvSearchPresentationGeneration = UUID()
#endif
            loadSearchHistory()
        }

        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in
            reloadSearchResultsForProfileChange()
        }
        .onDisappear {
#if os(tvOS)
            tvSearchIsVisible = false
            tvSearchPresentationGeneration = UUID()
#endif
            pendingSearchTask?.cancel()
        }
    }

    private var browseButton: some View {
        Group {
#if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .pad {
                Button(action: { showingBrowse = true }) {
                    browseButtonContent
                }
            } else {
                NavigationLink(destination: BrowseMediaView()) {
                    browseButtonContent
                }
            }
#else
            NavigationLink(destination: BrowseMediaView()) {
                browseButtonContent
            }
#endif
        }
#if os(tvOS)
        .buttonStyle(TVMediaCardButtonStyle())
#else
        .buttonStyle(PlainButtonStyle())
#endif
    }

    private var randomButton: some View {
        Button(action: openRandomTitle) {
            HStack(spacing: 6) {
                if isLoadingRandom {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "dice.fill")
                }

                Text("Random")
            }
            .font(.subheadline.weight(.semibold))
#if !os(tvOS)

            .foregroundColor(.accentColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.12))
            .clipShape(Capsule())
#endif
        }
#if os(tvOS)

        .buttonStyle(.borderedProminent)
#else
        .buttonStyle(PlainButtonStyle())
#endif
        .disabled(isLoadingRandom)
        .accessibilityLabel("Open a random movie or TV show")
    }

    private var searchFilterMenu: some View {
        Menu {
            ForEach(SearchFilter.allCases, id: \.self) { filter in
                Button(action: {
                    searchFilter = filter
                }) {
                    HStack {
                        Text(filter.rawValue)
                        if searchFilter == filter {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
#if os(tvOS)
            HStack(spacing: 10) {
                Image(systemName: searchFilter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                Text(searchFilter == .all ? "Filter" : searchFilter.rawValue)
            }
            .font(.system(size: 28, weight: .semibold))
            .foregroundColor(.primary)
#else
            Image(systemName: searchFilter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(.primary)
#endif
        }
    }

    private var browseNavigationLink: some View {
        NavigationLink(
            destination: BrowseMediaView(),
            isActive: $showingBrowse
        ) {
            EmptyView()
        }
        .hidden()
    }

    private var randomNavigationLink: some View {
        NavigationLink(
            destination: randomDestination,
            isActive: Binding(
                get: { randomResult != nil },
                set: { isActive in
                    if !isActive {
                        randomResult = nil
                    }
                }
            )
        ) {
            EmptyView()
        }
        .hidden()
    }

    @ViewBuilder
    private var randomDestination: some View {
        if let randomResult {
            MediaDetailView(searchResult: randomResult)
        } else {
            EmptyView()
        }
    }

    private var browseButtonContent: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Browse")
                    .font(.headline)
                    .foregroundColor(.primary)

                Text("Movies & TV Shows")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func loadSearchHistory() {
        guard let decodedHistory = BackupSearchHistory.decodedQueries(from: searchHistoryData) else {
            searchHistory = []
            return
        }
        searchHistory = decodedHistory
        saveSearchHistory()
    }

    private func saveSearchHistory() {
        searchHistory = BackupSearchHistory.sanitizedQueries(searchHistory)
        if let encodedHistory = try? JSONEncoder().encode(searchHistory),
           encodedHistory.count <= BackupSearchHistory.maximumEncodedBytes {
            searchHistoryData = encodedHistory
        }
    }

    private func addToSearchHistory(_ query: String) {
        guard let trimmedQuery = BackupSearchHistory.sanitizedQueries([query]).first else { return }

        searchHistory.removeAll { $0.lowercased() == trimmedQuery.lowercased() }
        searchHistory.insert(trimmedQuery, at: 0)

        saveSearchHistory()
    }

    private func removeFromSearchHistory(at index: Int) {
        guard index < searchHistory.count else { return }
        searchHistory.remove(at: index)
        saveSearchHistory()
    }

    private func clearSearchHistory() {
        searchHistory.removeAll()
        saveSearchHistory()
    }

    private func openRandomTitle() {
        guard !isLoadingRandom else { return }

        isLoadingRandom = true
        randomErrorMessage = nil

        Task {
            do {
                let trendingResults = try await tmdbService.getTrending(mediaType: "all", timeWindow: "week")
                let eligibleResults = await contentFilter.filterSearchResultsResolvingRatings(trendingResults)

                await MainActor.run {
                    if let randomResult = eligibleResults.randomElement() {
                        self.randomResult = randomResult
                    } else {
                        self.randomErrorMessage = "No eligible movies or TV shows were available."
                    }
                    self.isLoadingRandom = false
                }
            } catch {
                await MainActor.run {
                    self.randomErrorMessage = error.localizedDescription
                    self.isLoadingRandom = false
                }
            }
        }
    }

    private func reloadSearchResultsForProfileChange() {
        pendingSearchTask?.cancel()
        pendingSearchTask = nil

        searchRequestSerial += 1
        searchResults = []
#if os(tvOS)
        tvFocusedResultID = nil
#endif
        errorMessage = nil
        isLoading = false
        lastSubmittedSearchQuery = ""
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        performSearch(force: true)
    }

    private func scheduleSearch(for value: String) {
        pendingSearchTask?.cancel()

        let query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
#if os(tvOS)
            tvFocusedResultID = nil
#endif
            errorMessage = nil
            isLoading = false
            searchFilter = .all
            lastSubmittedSearchQuery = ""
            return
        }

        pendingSearchTask = Task { [query] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query else {
                    return
                }
                performSearch()
            }
        }
    }

    private func performSearch(force: Bool = false) {
        pendingSearchTask?.cancel()

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }

        if !force && query.caseInsensitiveCompare(lastSubmittedSearchQuery) == .orderedSame {
            return
        }

        searchRequestSerial += 1
        let serial = searchRequestSerial
#if os(tvOS)
        let presentationGeneration = tvSearchPresentationGeneration
#endif
        lastSubmittedSearchQuery = query
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let results = try await tmdbService.searchMulti(query: query)
                await contentFilter.prepareMaturityRatings(for: results)

                await MainActor.run {
                    guard serial == searchRequestSerial,
                          searchText.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(query) == .orderedSame else {
                        return
                    }
                    let filteredResults = contentFilter.filterSearchResults(results)
#if os(tvOS)
                    let restoredFocus = restoredTVResultFocus(
                        previousID: tvFocusedResultID,
                        previousResults: self.filteredResults,
                        nextResults: filteredResultsForCurrentFilter(filteredResults)
                    )
#endif
                    self.searchResults = filteredResults
                    self.isLoading = false
#if os(tvOS)
                    if let restoredFocus {
                        DispatchQueue.main.async {
                            guard tvSearchIsVisible,
                                  tvSearchPresentationGeneration == presentationGeneration else { return }
                            tvFocusedResultID = restoredFocus
                        }
                    }
#endif
                    if !filteredResults.isEmpty {
                        self.addToSearchHistory(query)
                    }
                }
            } catch {
                await MainActor.run {
                    guard serial == searchRequestSerial,
                          searchText.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(query) == .orderedSame else {
                        return
                    }
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

#if os(tvOS)
    private func filteredResultsForCurrentFilter(_ results: [TMDBSearchResult]) -> [TMDBSearchResult] {
        switch searchFilter {
        case .all: return results
        case .movies: return results.filter(\.isMovie)
        case .tvShows: return results.filter(\.isTVShow)
        }
    }

    private func restoredTVResultFocus(
        previousID: String?,
        previousResults: [TMDBSearchResult],
        nextResults: [TMDBSearchResult]
    ) -> String? {
        guard let previousID else { return nil }
        if nextResults.contains(where: { $0.stableIdentity == previousID }) {
            return previousID
        }
        guard !nextResults.isEmpty else { return nil }
        let previousIndex = previousResults.firstIndex(where: { $0.stableIdentity == previousID }) ?? 0
        return nextResults[min(previousIndex, nextResults.count - 1)].stableIdentity
    }
#endif
}

private enum BrowseMediaType: String, CaseIterable, Identifiable {
    case movie = "Movies"
    case tv = "TV Shows"
    case anime = "Anime"

    var id: String { rawValue }

    var tmdbValue: String {
        switch self {
        case .movie:
            return "movie"
        case .tv, .anime:
            return "tv"
        }
    }

    var isAnime: Bool {
        self == .anime
    }

    var genres: [BrowseGenre] {
        switch self {
        case .movie:
            return BrowseGenre.movieGenres
        case .tv:
            return BrowseGenre.tvGenres
        case .anime:
            return BrowseGenre.animeGenres
        }
    }

    var countries: [BrowseCountry] {
        isAnime ? BrowseCountry.animeCountries : BrowseCountry.all
    }
}

private enum BrowseSort: String, CaseIterable, Identifiable {
    case popularity = "popularity.desc"
    case newest = "newest"
    case oldest = "oldest"
    case rank = "vote_average.desc"
    case title = "title.asc"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .popularity:
            return "Most Popular"
        case .newest:
            return "Newest"
        case .oldest:
            return "Oldest"
        case .rank:
            return "Rank"
        case .title:
            return "Title A-Z"
        }
    }

    func tmdbValue(for mediaType: BrowseMediaType) -> String {
        switch self {
        case .popularity:
            return "popularity.desc"
        case .newest:
            return mediaType.tmdbValue == "tv" ? "first_air_date.desc" : "primary_release_date.desc"
        case .oldest:
            return mediaType.tmdbValue == "tv" ? "first_air_date.asc" : "primary_release_date.asc"
        case .rank:
            return "vote_average.desc"
        case .title:
            return mediaType.tmdbValue == "tv" ? "name.asc" : "original_title.asc"
        }
    }

}

enum BrowseDiscoverRatingPolicy {
    static func minimumVoteCount(isRankSort: Bool, minimumRating _: Double) -> Int? {
        isRankSort ? 100 : nil
    }
}

enum BrowseAgeRating: String, Codable, CaseIterable, Identifiable {
    case all
    case general
    case teen
    case mature
    case adult

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "Any Age Rating"
        case .general:
            return "All Ages"
        case .teen:
            return "Up to 14+"
        case .mature:
            return "Up to 17+"
        case .adult:
            return "18+ Only"
        }
    }

    func includes(_ rating: MaturityRating?, hasExplicitContent: Bool = false) -> Bool {
        guard self != .all else { return true }
        if hasExplicitContent {
            guard rating == nil || rating == .unknown || rating == .adult else { return false }
            return self == .adult
        }
        guard let rating, rating != .unknown else { return false }

        switch self {
        case .all:
            return true
        case .general:
            return rating == .general
        case .teen:
            return rating <= .teen
        case .mature:
            return rating <= .mature
        case .adult:
            return rating == .adult
        }
    }
}

private enum BrowseAnimeClassifier {
    private static let originCountries: Set<String> = ["JP", "CN", "KR", "TW"]
    private static let originalLanguages: Set<String> = ["ja", "zh", "ko"]

    private enum Classification: Equatable {
        case anime
        case nonAnime

        case unknownAnimation
    }

    static func isAnime(_ result: TMDBSearchResult) -> Bool {
        classification(for: result) == .anime
    }

    static func shouldIncludeInTV(_ result: TMDBSearchResult) -> Bool {
        classification(for: result) == .nonAnime
    }

    private static func classification(for result: TMDBSearchResult) -> Classification {
        guard result.mediaType == "tv" else { return .nonAnime }

        if result.isAnimeHint == true {
            return .anime
        }

        guard result.genreIds?.contains(16) == true else { return .nonAnime }

        if let origins = result.originCountry, !origins.isEmpty {
            return origins.contains(where: originCountries.contains) ? .anime : .nonAnime
        }

        if let language = result.originalLanguage?.lowercased(), !language.isEmpty {
            return originalLanguages.contains(language) ? .anime : .nonAnime
        }

        return .unknownAnimation
    }
}

struct BrowseFilterConfiguration: Codable, Equatable {
    var selectedGenreKeys: [String]
    var excludedGenreKeys: [String]
    var selectedYears: [Int]
    var excludedYears: [Int]
    var selectedCountryCodes: [String]
    var sortRawValue: String
    var minimumRating: Double
    var ageRatingRawValue: String

    func sanitized(
        validGenreKeys: Set<String>,
        validCountryCodes: Set<String>,
        validYearRange: ClosedRange<Int>
    ) -> BrowseFilterConfiguration {
        let selectedGenres = Set(selectedGenreKeys).intersection(validGenreKeys)
        let excludedGenres = Set(excludedGenreKeys)
            .intersection(validGenreKeys)
            .subtracting(selectedGenres)
        let selectedYearSet = Set(selectedYears.filter(validYearRange.contains))
        let excludedYearSet = Set(excludedYears.filter(validYearRange.contains))
            .subtracting(selectedYearSet)
        let countries = Set(selectedCountryCodes.map { $0.uppercased() })
            .intersection(validCountryCodes)
        let boundedMinimumRating = minimumRating.isFinite
            ? min(max(minimumRating, 0), 10)
            : 0

        return BrowseFilterConfiguration(
            selectedGenreKeys: selectedGenres.sorted(),
            excludedGenreKeys: excludedGenres.sorted(),
            selectedYears: selectedYearSet.sorted(),
            excludedYears: excludedYearSet.sorted(),
            selectedCountryCodes: countries.sorted(),
            sortRawValue: BrowseSort(rawValue: sortRawValue)?.rawValue ?? BrowseSort.popularity.rawValue,
            minimumRating: boundedMinimumRating,
            ageRatingRawValue: BrowseAgeRating(rawValue: ageRatingRawValue)?.rawValue ?? BrowseAgeRating.all.rawValue
        )
    }
}

struct BrowseFilterPreferences: Codable, Equatable {
    static let storageKey = "browseFilterPreferences"

    let mediaTypeRawValue: String
    let configurationsByMediaType: [String: BrowseFilterConfiguration]

    private enum CodingKeys: String, CodingKey {
        case mediaTypeRawValue
        case configurationsByMediaType
        case selectedGenreKeys
        case excludedGenreKeys
        case selectedYears
        case excludedYears
        case selectedCountryCode
        case sortRawValue
        case minimumRating
        case animeAgeRatingRawValue
    }

    init(
        mediaTypeRawValue: String,
        configurationsByMediaType: [String: BrowseFilterConfiguration]
    ) {
        self.mediaTypeRawValue = mediaTypeRawValue
        self.configurationsByMediaType = configurationsByMediaType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mediaTypeRawValue = try container.decodeIfPresent(String.self, forKey: .mediaTypeRawValue)
            ?? BrowseMediaType.movie.rawValue

        if let configurations = try container.decodeIfPresent(
            [String: BrowseFilterConfiguration].self,
            forKey: .configurationsByMediaType
        ) {
            configurationsByMediaType = configurations
            return
        }

        let legacyCountry = try container.decodeIfPresent(String.self, forKey: .selectedCountryCode) ?? ""
        let legacyAgeRating = try container.decodeIfPresent(String.self, forKey: .animeAgeRatingRawValue)
        let excludesAdultAnime = legacyAgeRating == "excludeAdults"
        var migrated: [String: BrowseFilterConfiguration] = [
            mediaTypeRawValue: BrowseFilterConfiguration(
                selectedGenreKeys: try container.decodeIfPresent([String].self, forKey: .selectedGenreKeys) ?? [],
                excludedGenreKeys: try container.decodeIfPresent([String].self, forKey: .excludedGenreKeys) ?? [],
                selectedYears: try container.decodeIfPresent([Int].self, forKey: .selectedYears) ?? [],
                excludedYears: try container.decodeIfPresent([Int].self, forKey: .excludedYears) ?? [],
                selectedCountryCodes: legacyCountry.isEmpty ? [] : [legacyCountry],
                sortRawValue: try container.decodeIfPresent(String.self, forKey: .sortRawValue)
                    ?? BrowseSort.popularity.rawValue,
                minimumRating: try container.decodeIfPresent(Double.self, forKey: .minimumRating) ?? 0,
                ageRatingRawValue: mediaTypeRawValue == BrowseMediaType.anime.rawValue && excludesAdultAnime
                    ? BrowseAgeRating.mature.rawValue
                    : BrowseAgeRating.all.rawValue
            )
        ]
        if excludesAdultAnime, mediaTypeRawValue != BrowseMediaType.anime.rawValue {
            migrated[BrowseMediaType.anime.rawValue] = BrowseFilterConfiguration(
                selectedGenreKeys: [],
                excludedGenreKeys: [],
                selectedYears: [],
                excludedYears: [],
                selectedCountryCodes: ["JP"],
                sortRawValue: BrowseSort.popularity.rawValue,
                minimumRating: 0,
                ageRatingRawValue: BrowseAgeRating.mature.rawValue
            )
        }
        configurationsByMediaType = migrated
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mediaTypeRawValue, forKey: .mediaTypeRawValue)
        try container.encode(configurationsByMediaType, forKey: .configurationsByMediaType)
    }

    static func load(profile id: UUID) -> BrowseFilterPreferences? {
        guard let data = ProfileSettingsStore.shared.store(for: id).data(forKey: storageKey) else {
            return nil
        }
        return try? JSONDecoder().decode(BrowseFilterPreferences.self, from: data)
    }
}

private struct BrowseGenre: Identifiable, Hashable {
    let id: String
    let name: String
    let tmdbGenreID: Int?
    let keyword: String?

    init(id: Int, name: String) {
        self.id = "tmdb-\(id)"
        self.name = name
        self.tmdbGenreID = id
        self.keyword = nil
    }

    init(keyword: String, name: String) {
        self.id = "keyword-\(keyword)"
        self.name = name
        self.tmdbGenreID = nil
        self.keyword = keyword
    }

    static let movieGenres: [BrowseGenre] = [
        BrowseGenre(id: 28, name: "Action"),
        BrowseGenre(id: 12, name: "Adventure"),
        BrowseGenre(id: 16, name: "Animation"),
        BrowseGenre(id: 35, name: "Comedy"),
        BrowseGenre(id: 80, name: "Crime"),
        BrowseGenre(id: 99, name: "Documentary"),
        BrowseGenre(id: 18, name: "Drama"),
        BrowseGenre(id: 10751, name: "Family"),
        BrowseGenre(id: 14, name: "Fantasy"),
        BrowseGenre(id: 36, name: "History"),
        BrowseGenre(id: 27, name: "Horror"),
        BrowseGenre(id: 10402, name: "Music"),
        BrowseGenre(id: 9648, name: "Mystery"),
        BrowseGenre(id: 10749, name: "Romance"),
        BrowseGenre(id: 878, name: "Sci-Fi"),
        BrowseGenre(id: 10770, name: "TV Movie"),
        BrowseGenre(id: 53, name: "Thriller"),
        BrowseGenre(id: 10752, name: "War"),
        BrowseGenre(id: 37, name: "Western")
    ]

    static let tvGenres: [BrowseGenre] = [
        BrowseGenre(id: 10759, name: "Action & Adventure"),
        BrowseGenre(id: 16, name: "Animation"),
        BrowseGenre(id: 35, name: "Comedy"),
        BrowseGenre(id: 80, name: "Crime"),
        BrowseGenre(id: 99, name: "Documentary"),
        BrowseGenre(id: 18, name: "Drama"),
        BrowseGenre(id: 10751, name: "Family"),
        BrowseGenre(id: 10762, name: "Kids"),
        BrowseGenre(id: 9648, name: "Mystery"),
        BrowseGenre(id: 10763, name: "News"),
        BrowseGenre(id: 10764, name: "Reality"),
        BrowseGenre(id: 10765, name: "Sci-Fi & Fantasy"),
        BrowseGenre(id: 10766, name: "Soap"),
        BrowseGenre(id: 10767, name: "Talk"),
        BrowseGenre(id: 10768, name: "War & Politics"),
        BrowseGenre(id: 37, name: "Western")
    ]

    static let animeGenres: [BrowseGenre] = [
        BrowseGenre(id: 10759, name: "Action & Adventure"),
        BrowseGenre(id: 35, name: "Comedy"),
        BrowseGenre(id: 18, name: "Drama"),
        BrowseGenre(id: 10751, name: "Family"),
        BrowseGenre(id: 10762, name: "Kids"),
        BrowseGenre(id: 9648, name: "Mystery"),
        BrowseGenre(id: 10765, name: "Sci-Fi & Fantasy"),
        BrowseGenre(keyword: "isekai", name: "Isekai"),
        BrowseGenre(keyword: "reincarnation", name: "Reincarnation"),
        BrowseGenre(keyword: "slice of life", name: "Slice of Life"),
        BrowseGenre(keyword: "romance", name: "Romance"),
        BrowseGenre(keyword: "fantasy", name: "Fantasy"),
        BrowseGenre(keyword: "supernatural", name: "Supernatural"),
        BrowseGenre(keyword: "psychological", name: "Psychological"),
        BrowseGenre(keyword: "mecha", name: "Mecha"),
        BrowseGenre(keyword: "sports", name: "Sports"),
        BrowseGenre(keyword: "school", name: "School"),
        BrowseGenre(keyword: "historical", name: "Historical"),
        BrowseGenre(keyword: "harem", name: "Harem"),
        BrowseGenre(keyword: "magical girl", name: "Magical Girl"),
        BrowseGenre(keyword: "music", name: "Music"),
        BrowseGenre(keyword: "horror", name: "Horror"),
        BrowseGenre(keyword: "samurai", name: "Samurai"),
        BrowseGenre(keyword: "super power", name: "Super Power"),
        BrowseGenre(keyword: "time travel", name: "Time Travel"),
        BrowseGenre(keyword: "video game", name: "Video Game")
    ]
}

private struct BrowseCountry: Identifiable, Hashable {
    let code: String
    let name: String

    var id: String { code }

    static let all: [BrowseCountry] = [
        BrowseCountry(code: "US", name: "United States"),
        BrowseCountry(code: "JP", name: "Japan"),
        BrowseCountry(code: "KR", name: "South Korea"),
        BrowseCountry(code: "GB", name: "United Kingdom"),
        BrowseCountry(code: "CA", name: "Canada"),
        BrowseCountry(code: "FR", name: "France"),
        BrowseCountry(code: "DE", name: "Germany"),
        BrowseCountry(code: "CN", name: "China"),
        BrowseCountry(code: "IN", name: "India"),
        BrowseCountry(code: "ES", name: "Spain"),
        BrowseCountry(code: "MX", name: "Mexico"),
        BrowseCountry(code: "BR", name: "Brazil"),
        BrowseCountry(code: "AU", name: "Australia"),
        BrowseCountry(code: "TH", name: "Thailand")
    ]

    static let animeCountries: [BrowseCountry] = [
        BrowseCountry(code: "JP", name: "Japan"),
        BrowseCountry(code: "CN", name: "China"),
        BrowseCountry(code: "KR", name: "South Korea"),
        BrowseCountry(code: "TW", name: "Taiwan")
    ]
}

private struct BrowseMediaView: View {
    @AppStorage("mediaColumnsPortrait") private var mediaColumnsPortrait: Int = 3
    @AppStorage("mediaColumnsLandscape") private var mediaColumnsLandscape: Int = 5
#if os(tvOS)
    @AppStorage("tvCardDensity") private var tvCardDensity = "standard"
#endif
    @AppStorage("tmdbLanguage") private var selectedLanguage = "en-US"

    @State private var mediaType: BrowseMediaType
    @State private var filterConfigurations: [BrowseMediaType: BrowseFilterConfiguration]
    @State private var showingFilters = false
    @State private var results: [TMDBSearchResult] = []
    @State private var currentPage = 1
    @State private var hasMorePages = true
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var requestSerial = 0
    @State private var loadTask: Task<Void, Never>?

    @State private var filterOwner: UUID

    @State private var profileAppliedMediaType: BrowseMediaType?

    @StateObject private var tmdbService = TMDBService.shared
    @StateObject private var contentFilter = TMDBContentFilter.shared
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private struct RestoredBrowseFilters {
        let mediaType: BrowseMediaType
        let configurations: [BrowseMediaType: BrowseFilterConfiguration]
    }

    private static func defaultConfiguration(for mediaType: BrowseMediaType) -> BrowseFilterConfiguration {
        BrowseFilterConfiguration(
            selectedGenreKeys: [],
            excludedGenreKeys: [],
            selectedYears: [],
            excludedYears: [],
            selectedCountryCodes: mediaType.isAnime ? ["JP"] : [],
            sortRawValue: BrowseSort.popularity.rawValue,
            minimumRating: 0,
            ageRatingRawValue: BrowseAgeRating.all.rawValue
        )
    }

    private static func sanitizedConfiguration(
        _ configuration: BrowseFilterConfiguration,
        for mediaType: BrowseMediaType
    ) -> BrowseFilterConfiguration {
        let currentYear = Calendar.current.component(.year, from: Date())
        return configuration.sanitized(
            validGenreKeys: Set(mediaType.genres.map(\.id)),
            validCountryCodes: Set(mediaType.countries.map(\.code)),
            validYearRange: 1950...currentYear
        )
    }

    private static func restoredFilters(for profile: UUID) -> RestoredBrowseFilters {
        let preferences = BrowseFilterPreferences.load(profile: profile)
        let restoredMediaType = preferences
            .flatMap { BrowseMediaType(rawValue: $0.mediaTypeRawValue) }
            ?? .movie

        var configurations: [BrowseMediaType: BrowseFilterConfiguration] = [:]
        for mediaType in BrowseMediaType.allCases {
            let stored = preferences?.configurationsByMediaType[mediaType.rawValue]
                ?? defaultConfiguration(for: mediaType)
            configurations[mediaType] = sanitizedConfiguration(stored, for: mediaType)
        }

        return RestoredBrowseFilters(
            mediaType: restoredMediaType,
            configurations: configurations
        )
    }

    init() {
        let owner = ProfileManager.shared.activeProfileID
        let restored = Self.restoredFilters(for: owner)

        _filterOwner = State(initialValue: owner)
        _mediaType = State(initialValue: restored.mediaType)
        _filterConfigurations = State(initialValue: restored.configurations)
    }

    private var currentFilters: BrowseFilterConfiguration {
        filterConfigurations[mediaType] ?? Self.defaultConfiguration(for: mediaType)
    }

    private var selectedGenreKeys: Set<String> { Set(currentFilters.selectedGenreKeys) }
    private var excludedGenreKeys: Set<String> { Set(currentFilters.excludedGenreKeys) }
    private var selectedYears: Set<Int> { Set(currentFilters.selectedYears) }
    private var excludedYears: Set<Int> { Set(currentFilters.excludedYears) }
    private var selectedCountryCodes: Set<String> { Set(currentFilters.selectedCountryCodes) }
    private var sort: BrowseSort { BrowseSort(rawValue: currentFilters.sortRawValue) ?? .popularity }
    private var minimumRating: Double { currentFilters.minimumRating }
    private var ageRating: BrowseAgeRating {
        BrowseAgeRating(rawValue: currentFilters.ageRatingRawValue) ?? .all
    }

    private var columnsCount: Int {
#if os(tvOS)
        switch tvCardDensity {
        case "spacious": return 4
        case "compact": return 6
        default: return 5
        }
#else
        if UIDevice.current.userInterfaceIdiom == .pad {
            let screen = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.screen })
                .first
            let width = screen?.bounds.width ?? 1024
            let height = screen?.bounds.height ?? 768
            return width > height ? mediaColumnsLandscape : mediaColumnsPortrait
        } else {
            return verticalSizeClass == .compact ? mediaColumnsLandscape : mediaColumnsPortrait
        }
#endif
    }

    private var gridColumns: [GridItem] {
#if os(tvOS)
        Array(repeating: GridItem(.flexible(), spacing: 16), count: SearchGridLayoutPolicy.columnCount(columnsCount))
#else
        if isIPad {
            return [GridItem(.adaptive(minimum: 154, maximum: 190), spacing: 24)]
        }
        return Array(repeating: GridItem(.flexible(), spacing: 16), count: SearchGridLayoutPolicy.columnCount(columnsCount))
#endif
    }

    private var availableYears: [Int] {
        let currentYear = Calendar.current.component(.year, from: Date())
        return Array(stride(from: currentYear, through: 1950, by: -1))
    }

    private var selectedGenreName: String {
        let selectedNames = mediaType.genres
            .filter { selectedGenreKeys.contains($0.id) }
            .map(\.name)
        return selectionSummary(values: selectedNames, emptyTitle: mediaType.isAnime ? "Any Anime Genre" : "Any Genre")
    }

    private var excludedGenreName: String {
        let excludedNames = mediaType.genres
            .filter { excludedGenreKeys.contains($0.id) }
            .map(\.name)
        return selectionSummary(values: excludedNames, emptyTitle: "None")
    }

    private var selectedYearName: String {
        let years = selectedYears
            .sorted(by: >)
            .map(String.init)
        return selectionSummary(values: years, emptyTitle: "Any Year")
    }

    private var excludedYearName: String {
        let years = excludedYears
            .sorted(by: >)
            .map(String.init)
        return selectionSummary(values: years, emptyTitle: "None")
    }

    private var selectedCountryName: String {
        let countryNames = mediaType.countries
            .filter { selectedCountryCodes.contains($0.code) }
            .map(\.name)
        return selectionSummary(values: countryNames, emptyTitle: "Any Country")
    }

    private var hasActiveFilters: Bool {
        !selectedGenreKeys.isEmpty
            || !excludedGenreKeys.isEmpty
            || !selectedYears.isEmpty
            || !excludedYears.isEmpty
            || !selectedCountryCodes.isEmpty
            || sort != .popularity
            || minimumRating > 0
            || ageRating != .all
    }

    private var activeFilterCount: Int {
        var count = 0
        if !selectedGenreKeys.isEmpty { count += 1 }
        if !excludedGenreKeys.isEmpty { count += 1 }
        if !selectedYears.isEmpty { count += 1 }
        if !excludedYears.isEmpty { count += 1 }
        if !selectedCountryCodes.isEmpty { count += 1 }
        if sort != .popularity { count += 1 }
        if minimumRating > 0 { count += 1 }
        if ageRating != .all { count += 1 }
        return count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
#if os(tvOS)
                filterPanel
#else
                VStack(alignment: .leading, spacing: 12) {
                    mediaTypeSelector
                    filterButton
                }
#endif

                if isLoading && results.isEmpty {
                    loadingState
                } else if let errorMessage {
                    errorState(errorMessage)
                } else if results.isEmpty {
                    emptyState
                } else {
                    resultsGrid
                }
            }
            .padding()
        }
        .navigationTitle("Browse")
#if os(iOS)
        .navigationBarTitleDisplayMode(.large)
#endif
#if !os(tvOS)
        .sheet(isPresented: $showingFilters) {
            filterSheet
        }
#endif
        .eclipseBackground()
        .onAppear {
            if results.isEmpty && !isLoading {
                reloadResults()
            }
        }
        .onDisappear {
            cancelBrowseLoad()
        }
        .onChangeComp(of: mediaType) { _, newMediaType in
            if profileAppliedMediaType == newMediaType {
                profileAppliedMediaType = nil
                return
            }
            persistFilters(filterConfigurations)
            reloadResults()
        }
        .onChangeComp(of: selectedLanguage) { _, _ in
            reloadResults()
        }
        .onChangeComp(of: contentFilter.filterHorror) { _, _ in
            reloadResults()
        }

        .onReceive(NotificationCenter.default.publisher(for: .activeProfileDidChange)) { _ in
            applyProfileChange()
        }
    }

    private var mediaTypeSelector: some View {
        Picker("Type", selection: $mediaType) {
            ForEach(BrowseMediaType.allCases) { type in
                Text(type.rawValue).tag(type)
            }
        }
        .pickerStyle(.segmented)
    }

    private var filterChipsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: isTvOS ? 420 : 132), spacing: isTvOS ? 20 : 10, alignment: .leading)],
            alignment: .leading,
            spacing: isTvOS ? 20 : 10
        ) {
            genreMenu
            excludedGenreMenu
            yearMenu
            excludedYearMenu
            countryMenu
            sortMenu
            ratingMenu
            ageRatingMenu

            if hasActiveFilters {
                resetFiltersButton
            }
        }
    }

    private var filterPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            mediaTypeSelector
            filterChipsGrid
        }
    }

    private var filterButton: some View {
        Button {
            showingFilters = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 16, weight: .semibold))

                Text("Filters")
                    .font(.subheadline.weight(.semibold))

                if activeFilterCount > 0 {
                    Text("\(activeFilterCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.secondary)
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PlainButtonStyle())
    }

    private var filterSheet: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    filterChipsGrid
                }
                .padding()
            }
            .navigationTitle("Filters")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showingFilters = false }
                }
            }
            .eclipseBackground()
        }
#if os(iOS)
        .navigationViewStyle(StackNavigationViewStyle())
#endif
    }

    private var genreMenu: some View {
        Menu {
            Button(action: { updateCurrentFilters { $0.selectedGenreKeys = [] } }) {
                menuRow("Any Genre", isSelected: selectedGenreKeys.isEmpty)
            }

            ForEach(mediaType.genres) { genre in
                Button(action: { toggleGenre(genre) }) {
                    menuRow(genre.name, isSelected: selectedGenreKeys.contains(genre.id))
                }
            }
        } label: {
            filterChip(
                title: mediaType.isAnime ? "Anime Genres" : "Genres",
                value: selectedGenreName,
                systemImage: "theatermasks.fill"
            )
        }
    }

    private var excludedGenreMenu: some View {
        Menu {
            Button(action: { updateCurrentFilters { $0.excludedGenreKeys = [] } }) {
                menuRow("Exclude None", isSelected: excludedGenreKeys.isEmpty)
            }

            ForEach(mediaType.genres) { genre in
                Button(action: { toggleGenre(genre, excluded: true) }) {
                    menuRow(genre.name, isSelected: excludedGenreKeys.contains(genre.id))
                }
            }
        } label: {
            filterChip(title: "Exclude Genres", value: excludedGenreName, systemImage: "theatermasks")
        }
    }

    private var yearMenu: some View {
        Menu {
            Button(action: { updateCurrentFilters { $0.selectedYears = [] } }) {
                menuRow("Any Year", isSelected: selectedYears.isEmpty)
            }

            ForEach(availableYears, id: \.self) { year in
                Button(action: { toggleYear(year) }) {
                    menuRow("\(year)", isSelected: selectedYears.contains(year))
                }
            }
        } label: {
            filterChip(title: "Year", value: selectedYearName, systemImage: "calendar")
        }
    }

    private var excludedYearMenu: some View {
        Menu {
            Button(action: { updateCurrentFilters { $0.excludedYears = [] } }) {
                menuRow("Exclude None", isSelected: excludedYears.isEmpty)
            }

            ForEach(availableYears, id: \.self) { year in
                Button(action: { toggleYear(year, excluded: true) }) {
                    menuRow("\(year)", isSelected: excludedYears.contains(year))
                }
            }
        } label: {
            filterChip(title: "Exclude Years", value: excludedYearName, systemImage: "calendar.badge.minus")
        }
    }

    private var countryMenu: some View {
        Menu {
            Button(action: { updateCurrentFilters { $0.selectedCountryCodes = [] } }) {
                menuRow("Any Country", isSelected: selectedCountryCodes.isEmpty)
            }

            ForEach(mediaType.countries) { country in
                Button(action: { toggleCountry(country) }) {
                    menuRow(country.name, isSelected: selectedCountryCodes.contains(country.code))
                }
            }
        } label: {
            filterChip(title: "Countries", value: selectedCountryName, systemImage: "globe")
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(BrowseSort.allCases) { option in
                Button(action: { updateCurrentFilters { $0.sortRawValue = option.rawValue } }) {
                    menuRow(option.title, isSelected: sort == option)
                }
            }
        } label: {
            filterChip(title: "Order", value: sort.title, systemImage: "arrow.up.arrow.down")
        }
    }

    private var minimumRatingLabel: String {
        minimumRating > 0 ? "\(Int(minimumRating))+ Stars" : "Any Rating"
    }

    private var ratingMenu: some View {
        Menu {
            Button(action: { updateCurrentFilters { $0.minimumRating = 0 } }) {
                menuRow("Any Rating", isSelected: minimumRating == 0)
            }

            ForEach([5, 6, 7, 8, 9], id: \.self) { star in
                Button(action: { updateCurrentFilters { $0.minimumRating = Double(star) } }) {
                    menuRow("\(star)+ Stars", isSelected: Int(minimumRating) == star)
                }
            }
        } label: {
            filterChip(title: "Rating", value: minimumRatingLabel, systemImage: "star.fill")
        }
    }

    private var ageRatingMenu: some View {
        Menu {
            ForEach(BrowseAgeRating.allCases) { option in
                Button(action: { updateCurrentFilters { $0.ageRatingRawValue = option.rawValue } }) {
                    menuRow(option.title, isSelected: ageRating == option)
                }
            }
        } label: {
            filterChip(
                title: "Age Rating",
                value: ageRating.title,
                systemImage: "18.circle"
            )
        }
    }

    private var resetFiltersButton: some View {
        Button(action: resetFilters) {
            Label("Reset", systemImage: "arrow.counterclockwise")
                .font(.subheadline.weight(.semibold))
#if !os(tvOS)
                .foregroundColor(.primary)
#endif
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
#if !os(tvOS)

                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
#endif
        }
#if os(tvOS)
        .buttonStyle(.bordered)
#else
        .buttonStyle(PlainButtonStyle())
#endif
    }

    private var loadingState: some View {
        VStack(spacing: 10) {
            EclipseLoadingIndicator()
                .scaleEffect(1.2)

            Text("Loading...")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .imageScale(.large)
                .font(.system(size: 52))
                .foregroundColor(.orange)

            Text("Unable to Load")
                .font(.title3.weight(.semibold))

            Text(message)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Try Again") {
                reloadResults()
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
        .padding(.horizontal)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.grid.2x2")
                .imageScale(.large)
                .font(.system(size: 52))
                .foregroundColor(.secondary)

            Text("No Results")
                .font(.title3.weight(.semibold))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private var resultsGrid: some View {
        LazyVGrid(columns: gridColumns, spacing: isIPad ? 24 : 16) {
            ForEach(results, id: \.stableIdentity) { result in
                SearchResultCard(result: result)
                    .onAppear {
                        if result.stableIdentity == results.last?.stableIdentity {
                            loadNextPage()
                        }
                    }
            }
        }
        .padding(.top, 4)
        .overlay(alignment: .bottom) {
            if isLoading {
                EclipseLoadingIndicator()
                    .padding(.vertical, 18)
            }
        }
    }

    private func filterChip(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: isTvOS ? 14 : 8) {
            Image(systemName: systemImage)
                .font(.system(size: isTvOS ? 26 : 13, weight: .semibold))

            VStack(alignment: .leading, spacing: isTvOS ? 4 : 1) {
                Text(title)
                    .font(isTvOS ? .system(size: 26) : .caption2)
                    .foregroundColor(.secondary)

                Text(value)
                    .font(isTvOS ? .system(size: 30, weight: .semibold) : .subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Image(systemName: "chevron.down")
                .font(.system(size: isTvOS ? 18 : 10, weight: .bold))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, isTvOS ? 24 : 12)
        .frame(maxWidth: .infinity, minHeight: isTvOS ? 96 : 48, alignment: .leading)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: isTvOS ? 18 : 10, style: .continuous))
    }

    private func menuRow(_ title: String, isSelected: Bool) -> some View {
        HStack {
            Text(title)
            if isSelected {
                Image(systemName: "checkmark")
            }
        }
    }

    private func updateCurrentFilters(_ update: (inout BrowseFilterConfiguration) -> Void) {
        var updated = currentFilters
        update(&updated)
        updated = Self.sanitizedConfiguration(updated, for: mediaType)

        var nextConfigurations = filterConfigurations
        nextConfigurations[mediaType] = updated
        filterConfigurations = nextConfigurations
        persistFilters(nextConfigurations)
        reloadResults()
    }

    private func resetFilters() {
        var nextConfigurations = filterConfigurations
        nextConfigurations[mediaType] = Self.defaultConfiguration(for: mediaType)
        filterConfigurations = nextConfigurations
        persistFilters(nextConfigurations)
        reloadResults()
    }

    private func applyProfileChange() {
        let owner = ProfileManager.shared.activeProfileID
        guard owner != filterOwner else {
            reloadResults()
            return
        }
        filterOwner = owner
        let restored = Self.restoredFilters(for: owner)
        filterConfigurations = restored.configurations
        if mediaType != restored.mediaType {
            profileAppliedMediaType = restored.mediaType
            mediaType = restored.mediaType
        }
        reloadResults()
    }

    private func persistFilters(_ configurations: [BrowseMediaType: BrowseFilterConfiguration]) {
        let configurationsByMediaType = Dictionary(uniqueKeysWithValues: configurations.map {
            ($0.key.rawValue, $0.value)
        })
        let preferences = BrowseFilterPreferences(
            mediaTypeRawValue: mediaType.rawValue,
            configurationsByMediaType: configurationsByMediaType
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(preferences) else { return }
        let owner = filterOwner
        ProfileSettingsStore.shared
            .store(for: owner)
            .set(data, forKey: BrowseFilterPreferences.storageKey)
    }

    private func reloadResults() {
        currentPage = 1
        hasMorePages = true
        results = []
        errorMessage = nil
        loadPage(1, replacing: true)
    }

    private func cancelBrowseLoad() {
        requestSerial += 1
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }

    private func loadNextPage() {
        guard !isLoading, hasMorePages else { return }
        loadPage(currentPage + 1, replacing: false)
    }

    private func loadPage(_ page: Int, replacing: Bool) {
        requestSerial += 1
        let serial = requestSerial
        loadTask?.cancel()
        let browseMediaType = self.mediaType
        let mediaType = browseMediaType.tmdbValue
        let isAnime = browseMediaType.isAnime
        let selectedGenres = browseMediaType.genres.filter { selectedGenreKeys.contains($0.id) }
        let excludedGenres = browseMediaType.genres.filter { excludedGenreKeys.contains($0.id) }
        let years = selectedYears.sorted(by: >)
        let excludedYears = self.excludedYears
        let countries = selectedCountryCodes.sorted()
        let sort = self.sort
        let minimumRating = self.minimumRating
        let ageRating = self.ageRating

        isLoading = true
        errorMessage = nil

        let task = Task {
            do {
                let pageResult = try await fetchDiscoverPage(
                    mediaType: mediaType,
                    isAnime: isAnime,
                    genres: selectedGenres,
                    excludedGenres: excludedGenres,
                    years: years,
                    excludedYears: excludedYears,
                    originCountries: countries,
                    sort: sort,
                    minimumRating: minimumRating,
                    page: page
                )
                try Task.checkCancellation()
                let browseTypeFiltered = await filterResultsForBrowseType(
                    pageResult.results,
                    mediaType: browseMediaType,
                    ageRating: ageRating
                )
                try Task.checkCancellation()
                let contentFiltered = await contentFilter.filterSearchResultsResolvingRatings(
                    filterExcludedResults(
                        browseTypeFiltered,
                        excludedGenreIds: excludedGenres.compactMap(\.tmdbGenreID),
                        excludedYears: excludedYears
                    )
                )
                try Task.checkCancellation()
                let filtered = regionGuardedResults(
                    contentFiltered,
                    countries: Set(countries)
                )

                await MainActor.run {
                    guard serial == requestSerial else { return }
                    loadTask = nil

                    let combinedResults = replacing ? filtered : results + filtered
                    results = sortedDeduplicatedResults(combinedResults, by: sort)

                    currentPage = page
                    hasMorePages = pageResult.hasMore
                    isLoading = false

                    if hasMorePages && results.count < 12 && page < 8 {
                        loadNextPage()
                    }
                }
            } catch {
                await MainActor.run {
                    guard serial == requestSerial else { return }
                    loadTask = nil
                    isLoading = false
                    guard !(error is CancellationError),
                          (error as? URLError)?.code != .cancelled else { return }
                    errorMessage = error.localizedDescription
                }
            }
        }
        loadTask = task
    }

    private func selectionSummary(values: [String], emptyTitle: String) -> String {
        guard let firstValue = values.first else {
            return emptyTitle
        }

        if values.count == 1 {
            return firstValue
        }

        if values.count == 2 {
            return "\(firstValue), \(values[1])"
        }

        return "\(firstValue) +\(values.count - 1)"
    }

    private func toggleGenre(_ genre: BrowseGenre) {
        toggleGenre(genre, excluded: false)
    }

    private func toggleGenre(_ genre: BrowseGenre, excluded: Bool) {
        let genreKey = genre.id
        updateCurrentFilters { filters in
            var selected = Set(filters.selectedGenreKeys)
            var excludedGenres = Set(filters.excludedGenreKeys)

            if excluded {
                if excludedGenres.contains(genreKey) {
                    excludedGenres.remove(genreKey)
                } else {
                    excludedGenres.insert(genreKey)
                    selected.remove(genreKey)
                }
            } else if selected.contains(genreKey) {
                selected.remove(genreKey)
            } else {
                selected.insert(genreKey)
                excludedGenres.remove(genreKey)
            }

            filters.selectedGenreKeys = selected.sorted()
            filters.excludedGenreKeys = excludedGenres.sorted()
        }
    }

    private func toggleYear(_ year: Int) {
        toggleYear(year, excluded: false)
    }

    private func toggleYear(_ year: Int, excluded: Bool) {
        updateCurrentFilters { filters in
            var selected = Set(filters.selectedYears)
            var excludedYearSet = Set(filters.excludedYears)

            if excluded {
                if excludedYearSet.contains(year) {
                    excludedYearSet.remove(year)
                } else {
                    excludedYearSet.insert(year)
                    selected.remove(year)
                }
            } else if selected.contains(year) {
                selected.remove(year)
            } else {
                selected.insert(year)
                excludedYearSet.remove(year)
            }

            filters.selectedYears = selected.sorted()
            filters.excludedYears = excludedYearSet.sorted()
        }
    }

    private func toggleCountry(_ country: BrowseCountry) {
        updateCurrentFilters { filters in
            var countries = Set(filters.selectedCountryCodes)
            if countries.contains(country.code) {
                countries.remove(country.code)
            } else {
                countries.insert(country.code)
            }
            filters.selectedCountryCodes = countries.sorted()
        }
    }

    private struct BrowsePageResult {
        let results: [TMDBSearchResult]
        let hasMore: Bool
    }

    private func fetchDiscoverPage(
        mediaType: String,
        isAnime: Bool,
        genres: [BrowseGenre],
        excludedGenres: [BrowseGenre],
        years: [Int],
        excludedYears: Set<Int>,
        originCountries: [String],
        sort: BrowseSort,
        minimumRating: Double,
        page: Int
    ) async throws -> BrowsePageResult {
        let selectedKeywordNames = genres.compactMap(\.keyword)
        let excludedKeywordNames = excludedGenres.compactMap(\.keyword)
        let keywordNames = Array(Set(selectedKeywordNames + excludedKeywordNames)).sorted()
        let keywordIDsByName = await tmdbService.keywordIDs(for: keywordNames)
        let selectedKeywordIDs = selectedKeywordNames.compactMap { keywordIDsByName[$0] }
        let excludedKeywordIDs = excludedKeywordNames.compactMap { keywordIDsByName[$0] }
        let effectiveGenreIds = Array(Set(genres.compactMap(\.tmdbGenreID) + (isAnime ? [16] : []))).sorted()
        let excludedGenreIds = Array(Set(excludedGenres.compactMap(\.tmdbGenreID))).sorted()
        let effectiveCountries = Array(Set(originCountries)).sorted()
        let effectiveLanguage = isAnime ? animeLanguage(for: effectiveCountries) : nil
        let requestedYears = years.filter { !excludedYears.contains($0) }
        let tmdbSortValue = sort.tmdbValue(for: mediaType == "tv" ? .tv : .movie)

        let ratingFloor: Double? = minimumRating > 0 ? minimumRating : nil
        let voteCountFloor = BrowseDiscoverRatingPolicy.minimumVoteCount(
            isRankSort: sort == .rank,
            minimumRating: minimumRating
        )

        guard !requestedYears.isEmpty || years.isEmpty else {
            return BrowsePageResult(results: [], hasMore: false)
        }

        guard !requestedYears.isEmpty else {
            let fetched = try await tmdbService.discoverMedia(
                mediaType: mediaType,
                genreIds: effectiveGenreIds,
                excludedGenreIds: excludedGenreIds,
                keywordIds: selectedKeywordIDs,
                excludedKeywordIds: excludedKeywordIDs,
                originCountries: effectiveCountries,
                originalLanguage: effectiveLanguage,
                sortBy: tmdbSortValue,
                minimumVoteCount: voteCountFloor,
                voteAverageGte: ratingFloor,
                page: page
            )
            return BrowsePageResult(results: fetched.results, hasMore: fetched.hasMore)
        }

        return try await withThrowingTaskGroup(of: BrowsePageResult.self) { group in
            for year in requestedYears {
                group.addTask {
                    let fetched = try await tmdbService.discoverMedia(
                        mediaType: mediaType,
                        genreIds: effectiveGenreIds,
                        excludedGenreIds: excludedGenreIds,
                        keywordIds: selectedKeywordIDs,
                        excludedKeywordIds: excludedKeywordIDs,
                        year: year,
                        originCountries: effectiveCountries,
                        originalLanguage: effectiveLanguage,
                        sortBy: tmdbSortValue,
                        minimumVoteCount: voteCountFloor,
                        voteAverageGte: ratingFloor,
                        page: page
                    )
                    return BrowsePageResult(results: fetched.results, hasMore: fetched.hasMore)
                }
            }

            var combined: [TMDBSearchResult] = []
            var hasMore = false

            for try await result in group {
                combined.append(contentsOf: result.results)
                hasMore = hasMore || result.hasMore
            }

            return BrowsePageResult(
                results: sortedDeduplicatedResults(combined, by: sort),
                hasMore: hasMore
            )
        }
    }

    private func filterExcludedResults(
        _ fetched: [TMDBSearchResult],
        excludedGenreIds: [Int],
        excludedYears: Set<Int>
    ) -> [TMDBSearchResult] {
        fetched.filter { result in
            if let year = Int(result.displayDate.prefix(4)), excludedYears.contains(year) {
                return false
            }

            if let genreIds = result.genreIds,
               genreIds.contains(where: excludedGenreIds.contains) {
                return false
            }

            return true
        }
    }

    private func filterResultsForBrowseType(
        _ fetched: [TMDBSearchResult],
        mediaType: BrowseMediaType,
        ageRating: BrowseAgeRating
    ) async -> [TMDBSearchResult] {
        let typeFiltered = fetched.filter { result in
            switch mediaType {
            case .movie:
                return true
            case .tv:
                return BrowseAnimeClassifier.shouldIncludeInTV(result)
            case .anime:
                return BrowseAnimeClassifier.isAnime(result)
            }
        }

        guard ageRating != .all else {
            return typeFiltered
        }
        guard !Task.isCancelled else { return [] }

        await TMDBMaturityRatingStore.shared.resolve(
            typeFiltered.map { (isMovie: $0.isMovie, id: $0.id) }
        )
        guard !Task.isCancelled else { return [] }
        return typeFiltered.filter { result in
            let hasExplicitContent = result.adult == true
                || (mediaType.isAnime && TMDBContentFilter.hasExplicitAnimeMetadata(result))
            let rating = TMDBMaturityRatingStore.shared.rating(isMovie: result.isMovie, id: result.id)
            return ageRating.includes(rating, hasExplicitContent: hasExplicitContent)
        }
    }

    private func animeLanguage(for countries: [String]) -> String? {
        guard countries.count == 1 else { return nil }
        switch countries[0] {
        case "JP": return "ja"
        case "CN", "TW": return "zh"
        case "KR": return "ko"
        default: return nil
        }
    }

    private func expectedLanguages(for country: String) -> Set<String>? {
        switch country {
        case "US", "GB", "AU": return ["en"]
        case "CA": return ["en", "fr"]
        case "JP": return ["ja"]
        case "KR": return ["ko"]
        case "CN", "TW": return ["zh", "cn"]
        case "FR": return ["fr"]
        case "DE": return ["de"]
        case "ES": return ["es", "ca"]
        case "MX": return ["es"]
        case "BR": return ["pt"]
        case "TH": return ["th"]
        case "IN": return nil
        default: return nil
        }
    }

    private func regionGuardedResults(_ results: [TMDBSearchResult], countries: Set<String>) -> [TMDBSearchResult] {
        guard !countries.isEmpty else { return results }
        let languageSets = countries.compactMap(expectedLanguages)
        let acceptableLanguages = languageSets.reduce(into: Set<String>()) { result, languages in
            result.formUnion(languages)
        }
        let hasCountryWithoutLanguageFallback = languageSets.count != countries.count
        return results.filter { result in
            if let origins = result.originCountry, !origins.isEmpty {
                return !countries.isDisjoint(with: origins)
            }
            if !hasCountryWithoutLanguageFallback,
               let language = result.originalLanguage,
               !language.isEmpty {
                return acceptableLanguages.contains(language.lowercased())
            }
            return true
        }
    }

    private func sortedDeduplicatedResults(_ fetched: [TMDBSearchResult], by sort: BrowseSort) -> [TMDBSearchResult] {
        var seen = Set<String>()
        let uniqueResults = fetched.filter { result in
            seen.insert(result.stableIdentity).inserted
        }

        return uniqueResults.sorted { lhs, rhs in
            switch sort {
            case .newest, .oldest:
                if lhs.displayDate != rhs.displayDate {
                    if lhs.displayDate.isEmpty { return false }
                    if rhs.displayDate.isEmpty { return true }
                    return sort == .newest
                        ? lhs.displayDate > rhs.displayDate
                        : lhs.displayDate < rhs.displayDate
                }
            case .rank:
                if lhs.voteAverage != rhs.voteAverage {
                    return (lhs.voteAverage ?? 0) > (rhs.voteAverage ?? 0)
                }
            case .title:
                let comparison = lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle)
                if comparison != .orderedSame {
                    return comparison == .orderedAscending
                }
            case .popularity:
                break
            }

            if lhs.popularity != rhs.popularity {
                return lhs.popularity > rhs.popularity
            }
            return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        }
    }
}

struct SearchBarEclipse: View {
    @Binding var text: String
    var onSearchButtonClicked: () -> Void

    var body: some View {
        HStack {
            TextField(LocalizedStringKey("Search Placeholder"), text: $text)
                .submitLabel(.search)
                .onSubmit(onSearchButtonClicked)
                .padding(7)
                .padding(.horizontal, 25)
#if !os(tvOS)
                .background(Color(.systemGray6))
#endif
                .cornerRadius(12)
                .contentShape(Rectangle())
                .overlay(
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 8)

                        if !text.isEmpty {
                            Button(action: {
                                self.text = ""
                            }) {
                                Image(systemName: "multiply.circle.fill")
                                    .foregroundColor(.secondary)
                                    .padding(.trailing, 8)
                            }
                        }
                    }
                )
        }
    }
}
