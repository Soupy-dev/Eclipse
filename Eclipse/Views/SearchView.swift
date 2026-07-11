import SwiftUI

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
            VStack(spacing: 12) {
                HStack {
                    Spacer()
                    randomButton
                }

                HStack(spacing: 8) {
#if !os(tvOS)
                    SearchBarEclipse(text: $searchText) {
                        performSearch(force: true)
                    }
#endif
                    
                    if !searchResults.isEmpty {
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
                            Image(systemName: searchFilter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(.primary)
                        }
                        .transition(.scale.combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: searchResults.isEmpty)

                browseButton
            }
            .padding()
            
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
                            .font(.caption)
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
                                                .font(.system(size: 16))

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
                                            .font(.system(size: 14))
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
                ZStack(alignment: .topTrailing) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: columnsCount), spacing: 16) {
                        ForEach(filteredResults, id: \.stableIdentity) { result in
                            SearchResultCard(result: result)
#if os(tvOS)
                                .focused($tvFocusedResultID, equals: result.stableIdentity)
#endif
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top)

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
                        .accessibilityLabel("Updating search results")
                    } else if errorMessage != nil {
                        Label("Could not refresh results", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(24)
                    }
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
            loadSearchHistory()
        }
        .onDisappear {
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
        .buttonStyle(.card)
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
            .foregroundColor(.accentColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isLoadingRandom)
        .accessibilityLabel("Open a random movie or TV show")
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
    
    // MARK: - Search History Management
    
    private func loadSearchHistory() {
        if let decodedHistory = try? JSONDecoder().decode([String].self, from: searchHistoryData) {
            searchHistory = decodedHistory
        }
    }
    
    private func saveSearchHistory() {
        if let encodedHistory = try? JSONEncoder().encode(searchHistory) {
            searchHistoryData = encodedHistory
        }
    }
    
    private func addToSearchHistory(_ query: String) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }
        
        searchHistory.removeAll { $0.lowercased() == trimmedQuery.lowercased() }
        searchHistory.insert(trimmedQuery, at: 0)
        
        if searchHistory.count > 10 {
            searchHistory = Array(searchHistory.prefix(10))
        }
        
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
                let eligibleResults = contentFilter.filterSearchResults(trendingResults)

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
        lastSubmittedSearchQuery = query
        isLoading = true
        errorMessage = nil

        Task {
            do {
                let results = try await tmdbService.searchMulti(query: query)

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

    var id: String { tmdbValue }

    var tmdbValue: String {
        switch self {
        case .movie:
            return "movie"
        case .tv:
            return "tv"
        }
    }

    var genres: [BrowseGenre] {
        switch self {
        case .movie:
            return BrowseGenre.movieGenres
        case .tv:
            return BrowseGenre.tvGenres
        }
    }
}

private struct BrowseGenre: Identifiable, Hashable {
    let id: Int
    let name: String

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
}

private struct BrowseMediaView: View {
    @AppStorage("mediaColumnsPortrait") private var mediaColumnsPortrait: Int = 3
    @AppStorage("mediaColumnsLandscape") private var mediaColumnsLandscape: Int = 5
#if os(tvOS)
    @AppStorage("tvCardDensity") private var tvCardDensity = "standard"
#endif
    @AppStorage("tmdbLanguage") private var selectedLanguage = "en-US"

    @State private var mediaType: BrowseMediaType = .movie
    @State private var selectedGenreIds: Set<Int> = []
    @State private var selectedYears: Set<Int> = []
    @State private var selectedCountryCode = ""
    @State private var results: [TMDBSearchResult] = []
    @State private var currentPage = 1
    @State private var hasMorePages = true
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var requestSerial = 0

    @StateObject private var tmdbService = TMDBService.shared
    @StateObject private var contentFilter = TMDBContentFilter.shared
    @Environment(\.verticalSizeClass) private var verticalSizeClass

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
        Array(repeating: GridItem(.flexible(), spacing: 16), count: columnsCount)
    }

    private var availableYears: [Int] {
        let currentYear = Calendar.current.component(.year, from: Date())
        return Array(stride(from: currentYear, through: 1950, by: -1))
    }

    private var selectedGenreName: String {
        let selectedNames = mediaType.genres
            .filter { selectedGenreIds.contains($0.id) }
            .map(\.name)
        return selectionSummary(values: selectedNames, emptyTitle: "Any Genre")
    }

    private var selectedYearName: String {
        let years = selectedYears
            .sorted(by: >)
            .map(String.init)
        return selectionSummary(values: years, emptyTitle: "Any Year")
    }

    private var selectedCountryName: String {
        BrowseCountry.all.first { $0.code == selectedCountryCode }?.name ?? "Any Country"
    }

    private var hasActiveFilters: Bool {
        !selectedGenreIds.isEmpty || !selectedYears.isEmpty || !selectedCountryCode.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                filterPanel

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
        .eclipseBackground()
        .onAppear {
            if results.isEmpty && !isLoading {
                reloadResults()
            }
        }
        .onChangeComp(of: mediaType) { _, _ in
            handleMediaTypeChange()
        }
        .onChangeComp(of: selectedGenreIds) { _, _ in
            reloadResults()
        }
        .onChangeComp(of: selectedYears) { _, _ in
            reloadResults()
        }
        .onChangeComp(of: selectedCountryCode) { _, _ in
            reloadResults()
        }
        .onChangeComp(of: selectedLanguage) { _, _ in
            reloadResults()
        }
        .onChangeComp(of: contentFilter.filterHorror) { _, _ in
            reloadResults()
        }
    }

    private var filterPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Type", selection: $mediaType) {
                ForEach(BrowseMediaType.allCases) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 132), spacing: 10, alignment: .leading)],
                alignment: .leading,
                spacing: 10
            ) {
                genreMenu
                yearMenu
                countryMenu

                if hasActiveFilters {
                    resetFiltersButton
                }
            }
        }
    }

    private var genreMenu: some View {
        Menu {
            Button(action: { selectedGenreIds.removeAll() }) {
                menuRow("Any Genre", isSelected: selectedGenreIds.isEmpty)
            }

            ForEach(mediaType.genres) { genre in
                Button(action: { toggleGenre(genre.id) }) {
                    menuRow(genre.name, isSelected: selectedGenreIds.contains(genre.id))
                }
            }
        } label: {
            filterChip(title: "Genre", value: selectedGenreName, systemImage: "theatermasks.fill")
        }
    }

    private var yearMenu: some View {
        Menu {
            Button(action: { selectedYears.removeAll() }) {
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

    private var countryMenu: some View {
        Menu {
            Button(action: { selectedCountryCode = "" }) {
                menuRow("Any Country", isSelected: selectedCountryCode.isEmpty)
            }

            ForEach(BrowseCountry.all) { country in
                Button(action: { selectedCountryCode = country.code }) {
                    menuRow(country.name, isSelected: selectedCountryCode == country.code)
                }
            }
        } label: {
            filterChip(title: "Country", value: selectedCountryName, systemImage: "globe")
        }
    }

    private var resetFiltersButton: some View {
        Button(action: resetFilters) {
            Label("Reset", systemImage: "arrow.counterclockwise")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(PlainButtonStyle())
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
        LazyVGrid(columns: gridColumns, spacing: 16) {
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
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Text(value)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func menuRow(_ title: String, isSelected: Bool) -> some View {
        HStack {
            Text(title)
            if isSelected {
                Image(systemName: "checkmark")
            }
        }
    }

    private func handleMediaTypeChange() {
        let validGenreIds = Set(mediaType.genres.map(\.id))
        let filteredGenreIds = selectedGenreIds.intersection(validGenreIds)
        if filteredGenreIds != selectedGenreIds {
            selectedGenreIds = filteredGenreIds
        } else {
            reloadResults()
        }
    }

    private func resetFilters() {
        selectedGenreIds.removeAll()
        selectedYears.removeAll()
        selectedCountryCode = ""
    }

    private func reloadResults() {
        currentPage = 1
        hasMorePages = true
        results = []
        errorMessage = nil
        loadPage(1, replacing: true)
    }

    private func loadNextPage() {
        guard !isLoading, hasMorePages else { return }
        loadPage(currentPage + 1, replacing: false)
    }

    private func loadPage(_ page: Int, replacing: Bool) {
        requestSerial += 1
        let serial = requestSerial
        let mediaType = self.mediaType.tmdbValue
        let genreIds = selectedGenreIds.sorted()
        let years = selectedYears.sorted(by: >)
        let country = selectedCountryCode.isEmpty ? nil : selectedCountryCode

        isLoading = true
        errorMessage = nil

        Task {
            do {
                let pageResult = try await fetchDiscoverPage(
                    mediaType: mediaType,
                    genreIds: genreIds,
                    years: years,
                    originCountry: country,
                    page: page
                )
                let filtered = contentFilter.filterSearchResults(pageResult.results)

                await MainActor.run {
                    guard serial == requestSerial else { return }

                    if replacing {
                        results = filtered
                    } else {
                        let existingIds = Set(results.map(\.stableIdentity))
                        results.append(contentsOf: filtered.filter { !existingIds.contains($0.stableIdentity) })
                    }

                    currentPage = page
                    hasMorePages = pageResult.hasMore
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    guard serial == requestSerial else { return }
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
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

    private func toggleGenre(_ genreId: Int) {
        if selectedGenreIds.contains(genreId) {
            selectedGenreIds.remove(genreId)
        } else {
            selectedGenreIds.insert(genreId)
        }
    }

    private func toggleYear(_ year: Int) {
        if selectedYears.contains(year) {
            selectedYears.remove(year)
        } else {
            selectedYears.insert(year)
        }
    }

    private struct BrowsePageResult {
        let results: [TMDBSearchResult]
        let hasMore: Bool
    }

    private func fetchDiscoverPage(
        mediaType: String,
        genreIds: [Int],
        years: [Int],
        originCountry: String?,
        page: Int
    ) async throws -> BrowsePageResult {
        guard !years.isEmpty else {
            let fetched = try await tmdbService.discoverMedia(
                mediaType: mediaType,
                genreIds: genreIds,
                originCountry: originCountry,
                page: page
            )
            return BrowsePageResult(results: fetched, hasMore: fetched.count >= 20)
        }

        return try await withThrowingTaskGroup(of: BrowsePageResult.self) { group in
            for year in years {
                group.addTask {
                    let fetched = try await tmdbService.discoverMedia(
                        mediaType: mediaType,
                        genreIds: genreIds,
                        year: year,
                        originCountry: originCountry,
                        page: page
                    )
                    return BrowsePageResult(results: fetched, hasMore: fetched.count >= 20)
                }
            }

            var combined: [TMDBSearchResult] = []
            var hasMore = false

            for try await result in group {
                combined.append(contentsOf: result.results)
                hasMore = hasMore || result.hasMore
            }

            return BrowsePageResult(
                results: sortedDeduplicatedResults(combined),
                hasMore: hasMore
            )
        }
    }

    private func sortedDeduplicatedResults(_ fetched: [TMDBSearchResult]) -> [TMDBSearchResult] {
        var seen = Set<String>()
        let uniqueResults = fetched.filter { result in
            seen.insert(result.stableIdentity).inserted
        }

        return uniqueResults.sorted { lhs, rhs in
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
