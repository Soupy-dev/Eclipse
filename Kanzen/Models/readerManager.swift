import SwiftUI
import Kingfisher
#if !os(tvOS)
import AidokuRunner
#endif



class readerManager: ObservableObject {
    @Published  var chapters: [Chapter]?
    @Published var selectedChapter: Chapter?
    @Published var index: Int
    @Published var currChapter: [PageData]
    @Published var prevChapter: [PageData]
    @Published var nextChapter: [PageData]
    @Published var isLoadingCurrentChapter = false
    @Published var currentErrorMessage: String?
    @AppStorage("readingMode") var readingModeRaw: Int = ReadingMode.WEBTOON.rawValue
    var pagePrefetchers: [ImagePrefetcher] = []
    var backgroundPagePrefetchers: [ImagePrefetcher] = []
    private var lastAdjacentPrefetchSignature: String?
    private var lastBackgroundPrefetchSignature: String?
    var readingMode: ReadingMode {
        let mode = ReadingMode(rawValue: readingModeRaw) ?? .WEBTOON
        return mode == .VERTICAL ? .WEBTOON : mode
    }
    var changeIndex: Bool = false

     var kanzen : KanzenEngine
    var mangaId: Int = 0
    var mangaTitle: String = ""
    var mangaCoverURL: String = ""
    var mangaRoute: MangaContentRoute?
    var mangaFormat: String?
    var totalChapters: Int?
    var latestChapterNumbers: [String]?
    var trackerAniListId: Int?
    var trackerMALId: Int?
    // Cached controllers - only recreated when data changes
 var currControllers: [UIViewController]?
  var prevControllers: [UIViewController]?
var nextControllers: [UIViewController]?
    
    // task
    private var currTask: Task<Void, Never>?
    private var pendingPagePersistTask: Task<Void, Never>?
    private var pendingPagePersist: Int?
    private var pendingPagePersistChapterNumber: String?
    
    // Task storage for loadPages operations
    private var loadPagesTasks: [ChapterPosition: Task<Void, Never>] = [:]
    

    
    var currRange: ClosedRange<CGFloat> {
        if currChapter.count > 0 {
           return 0...CGFloat(currChapter.count - 1)
        } else {
           return  0...CGFloat(0)
        }
    }
    
    init(index: Int = 0, currChapter: [PageData] = [], prevChapter: [PageData] = [], nextChapter: [PageData] = [], shiftChapterLeft: @escaping () -> Void = {}, shiftChapterRight: @escaping () -> Void = {}, fetchPrev: @escaping () -> Void = {}, fetchNext: @escaping () -> Void = {}, kanzen: KanzenEngine,chapters: [Chapter]?, selectedChapter: Chapter?, mangaId: Int = 0, mangaTitle: String = "", mangaCoverURL: String = "", mangaRoute: MangaContentRoute? = nil, mangaFormat: String? = nil, totalChapters: Int? = nil, latestChapterNumbers: [String]? = nil, trackerAniListId: Int? = nil, trackerMALId: Int? = nil) {
        self.index = index
        self.currChapter = currChapter
        self.prevChapter = prevChapter
        self.nextChapter = nextChapter
        self.kanzen = kanzen
        self.chapters = chapters
        self.selectedChapter = selectedChapter
        self.mangaId = mangaId
        self.mangaTitle = mangaTitle
        self.mangaCoverURL = mangaCoverURL
        self.mangaRoute = mangaRoute
        self.mangaFormat = mangaFormat
        self.totalChapters = totalChapters
        self.latestChapterNumbers = latestChapterNumbers
        self.trackerAniListId = trackerAniListId
        self.trackerMALId = trackerMALId
    }
    func initChapters(){
        // resetState
        resetState()

    }
    func resetState()
    {
        flushPendingPagePosition()
        cancelAllLoadPagesTasks()
        index = 0
        isLoadingCurrentChapter = true
        currentErrorMessage = nil
        prevChapter = []
        currChapter = []
        nextChapter = []
        currControllers = nil
        prevControllers = nil
        nextControllers = nil
        if let selectedChapter = selectedChapter, let chapters = chapters
        {
            var didStartCurrentLoad = false
            if let currSources = selectedChapter.chapterData, currSources.count > 0,
                let currParams = currSources[0].params
            {
                didStartCurrentLoad = true
                loadPages(chapter: selectedChapter, params: currParams, position: .curr)
            }
            if readingMode != .WEBTOON,
               let idx = resolvedChapterIndex(for: selectedChapter, in: chapters) {
                // fetch adjacent pages only for paged readers; webtoon loads adjacent chapters at boundaries.
                if idx > 0
                {
                    let prevChapter = chapters[idx - 1]
                    if let prevSources = prevChapter.chapterData, prevSources.count > 0,
                        let prevParams = prevSources[0].params
                    {
                        loadPages(chapter: prevChapter, params: prevParams, position: .prev)
                    }
                }
                if idx < chapters.count - 1
                {
                    let nextChapters = chapters[idx + 1]
                    if let nextSources = nextChapters.chapterData, nextSources.count > 0,
                        let nextParams = nextSources[0].params
                    {
                        loadPages(chapter: nextChapters, params: nextParams, position: .next)
                    }
                }
            }

            if !didStartCurrentLoad {
                isLoadingCurrentChapter = false
                currentErrorMessage = "No page source found for this chapter."
            }

                    
        }
        else {
            isLoadingCurrentChapter = false
            currentErrorMessage = "No chapter selected."
        }
    }
    // Cancel all loadPages tasks
    private func cancelAllLoadPagesTasks() {
        for (_, task) in loadPagesTasks {
            task.cancel()
        }
        loadPagesTasks.removeAll()
        ReaderPageImageOptions.stop(&pagePrefetchers)
        ReaderPageImageOptions.stop(&backgroundPagePrefetchers)
        lastAdjacentPrefetchSignature = nil
        lastBackgroundPrefetchSignature = nil
    }
    
    // Cancel specific loadPages task
    private func cancelLoadPagesTask(for position: ChapterPosition) {
        
        loadPagesTasks[position]?.cancel()
        loadPagesTasks.removeValue(forKey: position)
    }
    
    // Setter Functions
    func setIndex(_ index: Int) {
        if self.index != index {
            self.index = index
        }
        persistCurrentPagePosition(page: index)
    }

    func setTransientIndex(_ index: Int) {
        schedulePagePositionPersist(page: index)
    }

    func flushPendingPagePosition() {
        guard let page = pendingPagePersist,
              let chapterNumber = pendingPagePersistChapterNumber else { return }
        pendingPagePersistTask?.cancel()
        pendingPagePersistTask = nil
        pendingPagePersist = nil
        pendingPagePersistChapterNumber = nil
        if self.index != page {
            self.index = page
        }
        persistCurrentPagePosition(page: page, chapterNumber: chapterNumber)
    }

    func setCurrChapter(_ currChapter: [PageData]) {
        isLoadingCurrentChapter = false
        currentErrorMessage = nil
        self.currChapter = currChapter
        if readingMode == .WEBTOON {
            currControllers = nil
        } else {
            generateCurrControllers()
        }
        // Restore saved page position
        if mangaId != 0, let chapter = selectedChapter {
            let saved = MangaReadingProgressManager.shared.pagePosition(
                mangaId: mangaId,
                chapterNumber: chapter.chapterNumber
            )
            if saved > 0, saved < currChapter.count {
                self.index = saved
                self.changeIndex = true
                ReaderLogger.shared.log(
                    "Restoring reader page=\(saved + 1)/\(currChapter.count) chapter=\(chapter.chapterNumber)",
                    type: "ReaderProgress"
                )
            }
            persistCurrentPagePosition(page: self.index)
        }
        if readingMode == .WEBTOON {
            ReaderPageImageOptions.stop(&pagePrefetchers)
            ReaderPageImageOptions.stop(&backgroundPagePrefetchers)
            lastAdjacentPrefetchSignature = nil
            lastBackgroundPrefetchSignature = nil
        } else {
            preloadAdjacentPages()
            preloadRemainingCurrentChapterPages()
        }
    }
    
    func setPrevChapter(_ prevChapter: [PageData]) {
        self.prevChapter = prevChapter
        if readingMode == .WEBTOON {
            prevControllers = nil
        } else {
            generatePrevControllers()
        }
    }
    
    func setNextChapter(_ nextChapter: [PageData]) {
        self.nextChapter = nextChapter
        if readingMode == .WEBTOON {
            nextControllers = nil
        } else {
            generateNextControllers()
        }
    }
    func generateCurrControllers()
    {
        currControllers = currChapter.map { page in
            if !page.isTransition, (page.urlString != nil || page.imageData != nil) {
                return UIHostingController(rootView: AnyView(ZoomablePageView(page: page)))
            }
            return UIHostingController(rootView: AnyView(page.body))
        }
        if let selectedChapter = selectedChapter{
            let transistionView: any View = chapterView(page: PageData(content: "CHAPTER_END"), index: selectedChapter.chapterNumber)
            currControllers = currControllers! + [UIHostingController(rootView: AnyView( transistionView))]
        }
       
    }
    func generatePrevControllers()
    {
        prevControllers = prevChapter.map { page in
            if !page.isTransition, (page.urlString != nil || page.imageData != nil) {
                return UIHostingController(rootView: AnyView(ZoomablePageView(page: page)))
            }
            return UIHostingController(rootView: AnyView(page.body))
        }
        if let selectedChapter = selectedChapter,
           let chapters = chapters,
           let selectedIndex = resolvedChapterIndex(for: selectedChapter, in: chapters),
           selectedIndex > 0 {
            let transistionView: any View = chapterView(page: PageData(content: "CHAPTER_END"), index: chapters[selectedIndex - 1].chapterNumber)
            prevControllers = prevControllers! + [UIHostingController(rootView: AnyView( transistionView))]
            
        }
    }
    func generateNextControllers()
    {
        nextControllers = nextChapter.map { page in
            if !page.isTransition, (page.urlString != nil || page.imageData != nil) {
                return UIHostingController(rootView: AnyView(ZoomablePageView(page: page)))
            }
            return UIHostingController(rootView: AnyView(page.body))
        }
        if let selectedChapter = selectedChapter,
           let chapters = chapters,
           let selectedIndex = resolvedChapterIndex(for: selectedChapter, in: chapters),
           selectedIndex < chapters.count - 1 {
            let transistionView: any View = chapterView(page: PageData(content: "CHAPTER_END"), index: chapters[selectedIndex + 1].chapterNumber)
            nextControllers = nextControllers! + [UIHostingController(rootView: AnyView( transistionView))]
            
        }
    }
    func shiftLeft() {
        flushPendingPagePosition()
        // Cancel next chapter loading since it's no longer needed
        cancelLoadPagesTask(for: .next)
        guard let selectedChapter,
              let chapters,
              let selectedIndex = resolvedChapterIndex(for: selectedChapter, in: chapters) else {
            ReaderLogger.shared.log("Ignored previous chapter shift because the selected chapter is stale", type: "ReaderDebug")
            return
        }
        if selectedIndex == 0 {
            ReaderLogger.shared.log("No previous chapter available", type: "ReaderDebug")
            return
        }
        guard !prevChapter.isEmpty else {
            ReaderLogger.shared.log("Previous chapter is not loaded yet", type: "ReaderDebug")
            fetchPrev()
            return
        }
        
        // Mark the chapter we're leaving as read
        if mangaId != 0 {
            markChapterRead(selectedChapter)
        }
        
        //shift Controllers
        nextControllers = currControllers
        currControllers = prevControllers
        prevControllers = nil
        
        // Shift chapters (this will trigger didSet and invalidate controllers)
        nextChapter = currChapter
        currChapter = prevChapter
        prevChapter = []
        
        // Now shift the controllers to maintain references
        // What was "current" becomes "next"
        // What was "previous" becomes "current"
        // "Previous" becomes empty
        shiftChapterLeft()
        index = currChapter.count - 1
        ReaderLogger.shared.log("Shifted left; controllers moved", type: "ReaderProgress")
    }
    
    func shiftRight() {
        flushPendingPagePosition()
        // Cancel prev chapter loading since it's no longer needed
        cancelLoadPagesTask(for: .prev)
        guard let selectedChapter,
              let chapters,
              let selectedIndex = resolvedChapterIndex(for: selectedChapter, in: chapters) else {
            ReaderLogger.shared.log("Ignored next chapter shift because the selected chapter is stale", type: "ReaderDebug")
            return
        }
        if selectedIndex == chapters.count - 1 {
            ReaderLogger.shared.log("No next chapter available", type: "ReaderDebug")
            return
        }
        guard !nextChapter.isEmpty else {
            ReaderLogger.shared.log("Next chapter is not loaded yet", type: "ReaderDebug")
            fetchNext()
            return
        }
        
        // Mark the chapter we're leaving as read
        if mangaId != 0 {
            markChapterRead(selectedChapter)
        }
        
        prevControllers = currControllers
        currControllers = nextControllers
        nextControllers = nil
        // Shift chapters (this will trigger didSet and invalidate controllers)
        prevChapter = currChapter
        currChapter = nextChapter
        nextChapter = []
        
        
        // What was "current" becomes "previous"
        // What was "next" becomes "current"
        // "Next" becomes empty

        index = 0
        shiftChapterRight()

        ReaderLogger.shared.log("Shifted right; controllers moved", type: "ReaderProgress")
    }

    private func persistCurrentPagePosition(page: Int, chapterNumber explicitChapterNumber: String? = nil) {
        guard mangaId != 0, let chapter = selectedChapter else { return }
        let chapterNumber = explicitChapterNumber ?? chapter.chapterNumber
        MangaReadingProgressManager.shared.savePagePosition(
            mangaId: mangaId,
            chapterNumber: chapterNumber,
            page: page,
            pageCount: currChapter.count,
            mangaTitle: mangaTitle,
            coverURL: mangaCoverURL,
            format: mangaFormat,
            totalChapters: totalChapters,
            latestChapterNumbers: latestChapterNumbers,
            route: mangaRoute,
            trackerAniListId: trackerAniListId,
            trackerMALId: trackerMALId,
            readThreshold: readerReadThreshold
        )
    }

    private func schedulePagePositionPersist(page: Int) {
        guard let chapter = selectedChapter else { return }
        pendingPagePersist = page
        pendingPagePersistChapterNumber = chapter.chapterNumber
        pendingPagePersistTask?.cancel()
        pendingPagePersistTask = nil
    }

    private var readerReadThreshold: Double {
        let raw = UserDefaults.standard.object(forKey: "readerReadThresholdPercent") as? Double ?? 80
        return max(50, min(raw, 100)) / 100
    }

    private func markChapterRead(_ chapter: Chapter) {
        MangaReadingProgressManager.shared.markChapterRead(
            mangaId: mangaId,
            chapterNumber: chapter.chapterNumber,
            mangaTitle: mangaTitle,
            coverURL: mangaCoverURL,
            format: mangaFormat,
            totalChapters: totalChapters,
            latestChapterNumbers: latestChapterNumbers,
            route: mangaRoute,
            trackerAniListId: trackerAniListId,
            trackerMALId: trackerMALId
        )
    }
    
    func getIndex() -> Int {
        return index
    }
    
    func findControllers(currView: UIViewController) -> Bool {
        if let currControllers = currControllers, currControllers.contains(currView) {
            return true
        }
        if let prevControllers = prevControllers, prevControllers.contains(currView) {
            return true
        }
        if let nextControllers = nextControllers, nextControllers.contains(currView) {
            return true
        }
        return false
    }
    func fetchTask(bool: Bool, completion: @escaping (() -> Void ) = {})
    {
        currTask?.cancel()
        if bool {
            // Also cancel the actual loading task for next
            cancelLoadPagesTask(for: .next)
            currTask = Task
            {
                 fetchNext(completion: completion)
            }

            
        }
        else
        {            // Also cancel the actual loading task for prev
            cancelLoadPagesTask(for: .prev)
            currTask = Task
            {
                fetchPrev(completion: completion)
            }


        }
    }
  
    
    func loadPages(chapter: Chapter? = nil, params: Any, position: ChapterPosition, completion: @escaping () -> Void = {}){
        // Cancel any existing task for this position
        cancelLoadPagesTask(for: position)
        
        // Create new task and store it
        loadPagesTasks[position] = Task { @MainActor in
            do {
                // Check for cancellation before starting
                try Task.checkCancellation()
                
                ReaderLogger.shared.log("Loading chapter position=\(position)", type: "Reader")
                let loadStartedAt = Date()

                let pages: [PageData]
                let loadSource: String
                if let route = self.mangaRoute,
                   let chapter,
                   let localPages = ReaderDownloadManager.shared.pages(for: route, chapterNumber: chapter.chapterNumber) {
                    pages = localPages
                    loadSource = "download"
                    ReaderLogger.shared.log("Loaded downloaded chapter position=\(position) pages=\(localPages.count)", type: "ReaderDownload")
                } else if let payload = params as? ReaderDownloadedChapterPayload {
                    if let localPages = ReaderDownloadManager.shared.pages(for: payload.route, chapterNumber: payload.chapterNumber) {
                        pages = localPages
                        loadSource = "downloadPayload"
                        ReaderLogger.shared.log("Loaded downloaded chapter payload position=\(position) pages=\(localPages.count)", type: "ReaderDownload")
                    } else {
                        throw NSError(domain: "ReaderDownload", code: 404, userInfo: [NSLocalizedDescriptionKey: "Downloaded chapter files are missing."])
                    }
                } else if let payload = params as? AidokuChapterPayload {
                    loadSource = "aidoku"
                    let keepNativePages = self.readingMode == .WEBTOON
                    pages = try await AidokuSourceManager.shared.pageList(
                        sourceId: payload.sourceId,
                        manga: payload.manga,
                        chapter: payload.chapter,
                        nativePages: keepNativePages
                    )
                } else {
                    loadSource = "legacy"
                    let result = await withCheckedContinuation { continuation in
                        self.kanzen.extractImages(params: params) { result in
                            continuation.resume(returning: result)
                        }
                    } ?? []
                    pages = result.map { PageData(content: $0) }
                }
                
                // Check for cancellation after network call
                try Task.checkCancellation()
                let loadElapsedMs = Int(Date().timeIntervalSince(loadStartedAt) * 1000)
                let urlCount = pages.filter { $0.urlString != nil }.count
                let dataCount = pages.filter { $0.imageData != nil }.count
                let textCount = pages.filter { $0.textContent != nil }.count
                if position == .curr || loadElapsedMs >= 500 {
                    ReaderLogger.shared.log(
                        "Chapter pages loaded position=\(position) source=\(loadSource) elapsedMs=\(loadElapsedMs) pages=\(pages.count) url=\(urlCount) data=\(dataCount) text=\(textCount)",
                        type: "ReaderPerf"
                    )
                }
                
       
                
                if !pages.isEmpty {
                    // Check for cancellation before updating UI
                    try Task.checkCancellation()
                    
                    // Update UI on main thread (already on MainActor)
                    switch position
                    {
                    case .prev:
                        self.setPrevChapter(pages)
                        
                    case .next:
                        self.setNextChapter(pages)
                        
                        
                    case .curr:
                        self.setCurrChapter(pages)


                    }
                    ReaderLogger.shared.log("Loaded chapter position=\(position) pages=\(pages.count)", type: "Reader")
                    completion()
                } else if position == .curr {
                    self.isLoadingCurrentChapter = false
                    self.currentErrorMessage = "No pages found for this chapter."
                    completion()
                } else {
                    completion()
                }
                
                // Remove completed task from storage
                self.loadPagesTasks.removeValue(forKey: position)
                
            } catch {
                if error is CancellationError {
                    ReaderLogger.shared.log("Loading chapter position=\(position) cancelled", type: "ReaderDebug")
                } else {
                    ReaderLogger.shared.log("Error loading chapter position=\(position): \(error.localizedDescription)", type: "Error")
                    if position == .curr {
                        self.isLoadingCurrentChapter = false
                        self.currentErrorMessage = error.localizedDescription
                    }
                }
                // Remove failed/cancelled task from storage
                self.loadPagesTasks.removeValue(forKey: position)
            }
        }
    }
    // shiftCurrChapter
    func shiftChapterLeft()
    {
        if let currChapter = selectedChapter, let chapters = chapters
        {
            if let idx = resolvedChapterIndex(for: currChapter, in: chapters),
               idx > 0
            {
                selectedChapter = chapters[idx - 1]
                ReaderLogger.shared.log("Shifted to previous chapter", type: "ReaderProgress")
            }
        }
    }
    func shiftChapterRight()
    {
        if let currChapter = selectedChapter, let chapters = chapters
        {
            if let idx = resolvedChapterIndex(for: currChapter, in: chapters),
               idx < chapters.count - 1
            {
                selectedChapter = chapters[idx + 1]
                ReaderLogger.shared.log("Shifted to next chapter", type: "ReaderProgress")
            }
        }
    }

    func goToPreviousChapter() {
        flushPendingPagePosition()
        guard let chapter = selectedChapter,
              let chapters,
              let chapterIndex = resolvedChapterIndex(for: chapter, in: chapters),
              chapterIndex > 0 else { return }
        if mangaId != 0 {
            markChapterRead(chapter)
        }
        selectedChapter = chapters[chapterIndex - 1]
        resetState()
    }

    func goToNextChapter() {
        flushPendingPagePosition()
        guard let chapter = selectedChapter,
              let chapters,
              let chapterIndex = resolvedChapterIndex(for: chapter, in: chapters),
              chapterIndex < chapters.count - 1 else { return }
        if mangaId != 0 {
            markChapterRead(chapter)
        }
        selectedChapter = chapters[chapterIndex + 1]
        resetState()
    }

    func fetchPrev(completion: @escaping () -> Void = {})
    {
        ReaderLogger.shared.log("Prefetch previous chapter requested", type: "ReaderDebug")
        if let selectedChapter = selectedChapter, let chapters = chapters {
            if let idx = resolvedChapterIndex(for: selectedChapter, in: chapters),
               idx > 0 {
                let prevChapter = chapters[idx - 1]
                if let prevSources = prevChapter.chapterData, prevSources.count > 0,
                    let prevParams = prevSources[0].params
                {
                    loadPages(chapter: prevChapter, params: prevParams, position: .prev,completion: completion)
                    
                }
                
            }
        }
    }
    func fetchNext(completion: @escaping () -> Void = {})
    {        if let selectedChapter = selectedChapter, let chapters = chapters {
        if let idx = resolvedChapterIndex(for: selectedChapter, in: chapters),
           idx < chapters.count - 1 {
            let nextChapters = chapters[idx + 1]
            if let nextSources = nextChapters.chapterData, nextSources.count > 0,
                let nextParams = nextSources[0].params
            {
                loadPages(chapter: nextChapters, params: nextParams, position: .next,completion: completion)
            }
            
        }
    }
        
    }
    
    func preloadAdjacentPages()
    {
        guard !currChapter.isEmpty else { return }

        let anchor = max(0, (index / 4) * 4)
        let lowerBound = max(anchor - 2, 0)
        let upperBound = min(anchor + 12, currChapter.count - 1)
        var pagesToPrefetch: [PageData] = []

        for pageIndex in lowerBound...upperBound where pageIndex != index {
            pagesToPrefetch.append(currChapter[pageIndex])
        }

        if index >= currChapter.count - 3 {
            for page in nextChapter.prefix(4) {
                pagesToPrefetch.append(page)
            }
        }

        if index <= 2 {
            for page in prevChapter.suffix(4) {
                pagesToPrefetch.append(page)
            }
        }

        let signature = pagesToPrefetch.map(\.cacheKey).joined(separator: "|")
        guard signature != lastAdjacentPrefetchSignature else { return }
        lastAdjacentPrefetchSignature = signature

        ReaderPageImageOptions.stop(&pagePrefetchers)
        pagePrefetchers = ReaderPageImageOptions.makePrefetchers(for: pagesToPrefetch)
        ReaderPageImageOptions.start(pagePrefetchers)
        
    }

    func preloadRemainingCurrentChapterPages() {
        let signature = currChapter.map(\.cacheKey).joined(separator: "|")
        guard signature != lastBackgroundPrefetchSignature else { return }
        lastBackgroundPrefetchSignature = signature

        ReaderPageImageOptions.stop(&backgroundPagePrefetchers)
        backgroundPagePrefetchers = ReaderPageImageOptions.makePrefetchers(for: currChapter)
        ReaderPageImageOptions.start(backgroundPagePrefetchers)
        ReaderLogger.shared.log("Background prefetching \(backgroundPagePrefetchers.count) reader page groups", type: "ReaderProgress")
    }
    func getNextChapterIdx() -> String{
        if let selectedChapter,
           let currChapters = chapters,
           let idx = resolvedChapterIndex(for: selectedChapter, in: currChapters),
           idx + 1 < currChapters.count {
            return currChapters[idx+1].chapterNumber
            
        }
        return "0"
        
    }
    func getPrevChapterIdx() -> String
    {
        if let selectedChapter,
           let currChapters = chapters,
           let idx = resolvedChapterIndex(for: selectedChapter, in: currChapters),
           idx > 0 {
            return currChapters[idx - 1].chapterNumber
            
        }
        return "0"
    }

    /// Provider refreshes, chapter de-duplication, and restored state can leave `Chapter.idx`
    /// referring to an older array. Prefer the fast indexed lookup only when its identity still
    /// matches, then recover by stable chapter identity instead of subscripting stale state.
    private func resolvedChapterIndex(for chapter: Chapter, in chapters: [Chapter]) -> Int? {
        let chapterKey = ChapterIdentityNormalizer.key(for: chapter.chapterNumber)
        if chapters.indices.contains(chapter.idx),
           ChapterIdentityNormalizer.key(for: chapters[chapter.idx].chapterNumber) == chapterKey {
            return chapter.idx
        }
        return chapters.firstIndex {
            ChapterIdentityNormalizer.key(for: $0.chapterNumber) == chapterKey
        }
    }
}

#if !os(tvOS)
enum KanzenReaderMode: String, CaseIterable, Identifiable {
    case ltr
    case rtl
    case vertical
    case webtoon

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ltr: return "Left to Right"
        case .rtl: return "Right to Left"
        case .vertical: return "Vertical"
        case .webtoon: return "Continuous Scroll"
        }
    }

    var readingMode: ReadingMode {
        switch self {
        case .ltr: return .LTR
        case .rtl: return .RTL
        case .vertical: return .VERTICAL
        case .webtoon: return .WEBTOON
        }
    }

    static func storageKey(scopeKey: String?) -> String {
        if let scopeKey, !scopeKey.isEmpty {
            return "kanzenReaderMode.\(scopeKey)"
        }
        return "kanzenReaderMode"
    }

    static func currentDefault(scopeKey: String? = nil) -> KanzenReaderMode {
        let scopedKey = storageKey(scopeKey: scopeKey)
        if scopedKey != "kanzenReaderMode",
           let scoped = UserDefaults.standard.object(forKey: scopedKey) as? String,
           let mode = KanzenReaderMode(rawValue: scoped) {
            return mode
        }

        let migrated = UserDefaults.standard.object(forKey: "kanzenReaderMode") as? String
        if let migrated, let mode = KanzenReaderMode(rawValue: migrated) {
            return mode
        }

        let legacy = UserDefaults.standard.integer(forKey: "readingMode")
        let mode = ReadingMode(rawValue: legacy) ?? .WEBTOON
        let resolved: KanzenReaderMode
        switch mode {
        case .LTR: resolved = .ltr
        case .RTL: resolved = .rtl
        case .VERTICAL: resolved = .vertical
        case .WEBTOON: resolved = .webtoon
        }
        UserDefaults.standard.set(resolved.rawValue, forKey: "kanzenReaderMode")
        return resolved
    }
}

struct KanzenReaderPage: Identifiable {
    let id: String
    let pageData: PageData
    let index: Int

    var text: String? { pageData.textContent }
    var isText: Bool { text != nil }
    var isImageLike: Bool { pageData.imageData != nil || pageData.urlString != nil || pageData.aidokuPage != nil }

    init(pageData: PageData, index: Int, chapterNumber: String) {
        self.pageData = pageData
        self.index = index
        self.id = "\(chapterNumber)-\(index)-\(pageData.cacheKey)"
    }
}

@MainActor
final class KanzenReaderSession {
    let kanzen: KanzenEngine
    private(set) var chapters: [Chapter]
    private(set) var selectedChapter: Chapter
    let mangaId: Int
    let mangaTitle: String
    let mangaCoverURL: String
    let mangaRoute: MangaContentRoute?
    let mangaFormat: String?
    let totalChapters: Int?
    let latestChapterNumbers: [String]?
    let trackerAniListId: Int?
    let trackerMALId: Int?

    private let loader: KanzenReaderPageLoader
    private var lastSavedChapterNumber: String?
    private var lastSavedPage = -1
    private var thresholdMarkedChapterNumber: String?

    var pages: [KanzenReaderPage] = []
    var currentPage: Int = 0
    var mode: KanzenReaderMode = .webtoon

    var readerSettingsScopeKey: String? {
        if let stableKey = mangaRoute?.stableKey, !stableKey.isEmpty {
            return stableKey
        }
        return mangaId == 0 ? nil : "\(mangaId)"
    }

    var readerModeStorageKey: String {
        KanzenReaderMode.storageKey(scopeKey: readerSettingsScopeKey)
    }

    init(
        kanzen: KanzenEngine,
        chapters: [Chapter]?,
        selectedChapter: Chapter?,
        mangaId: Int,
        mangaTitle: String,
        mangaCoverURL: String,
        mangaRoute: MangaContentRoute?,
        mangaFormat: String?,
        totalChapters: Int?,
        latestChapterNumbers: [String]?,
        trackerAniListId: Int?,
        trackerMALId: Int?
    ) {
        self.kanzen = kanzen
        let normalized = ChapterIdentityNormalizer.deduplicatedChapters(chapters ?? [], reindex: true)
        self.chapters = normalized
        if let selectedChapter,
           let match = normalized.first(where: {
               ChapterIdentityNormalizer.key(for: $0.chapterNumber) == ChapterIdentityNormalizer.key(for: selectedChapter.chapterNumber)
           }) {
            self.selectedChapter = match
        } else {
            self.selectedChapter = normalized.first ?? Chapter(chapterNumber: "", idx: 0, chapterData: nil)
        }
        self.mangaId = mangaId
        self.mangaTitle = mangaTitle
        self.mangaCoverURL = mangaCoverURL
        self.mangaRoute = mangaRoute
        self.mangaFormat = mangaFormat
        self.totalChapters = totalChapters
        self.latestChapterNumbers = latestChapterNumbers.map(ChapterIdentityNormalizer.deduplicatedNumbers)
        self.trackerAniListId = trackerAniListId
        self.trackerMALId = trackerMALId
        self.loader = KanzenReaderPageLoader(kanzen: kanzen, route: mangaRoute)
        self.mode = KanzenReaderMode.currentDefault(scopeKey: readerSettingsScopeKey)
    }

    var canMovePreviousChapter: Bool {
        chapterIndex > 0
    }

    var canMoveNextChapter: Bool {
        chapterIndex < chapters.count - 1
    }

    var chapterIndex: Int {
        chapters.firstIndex(where: {
            ChapterIdentityNormalizer.key(for: $0.chapterNumber) == ChapterIdentityNormalizer.key(for: selectedChapter.chapterNumber)
        }) ?? min(max(selectedChapter.idx, 0), max(chapters.count - 1, 0))
    }

    var readThreshold: Double {
        let raw = UserDefaults.standard.object(forKey: "readerReadThresholdPercent") as? Double ?? 80
        return max(50, min(raw, 100)) / 100
    }

    func loadSelectedChapter() async throws -> [KanzenReaderPage] {
        let pageData = try await loader.loadPages(for: selectedChapter, mode: mode)
        guard !pageData.isEmpty else {
            throw NSError(domain: "KanzenReader", code: 1, userInfo: [NSLocalizedDescriptionKey: "No pages found for this chapter."])
        }
        let mapped = pageData.enumerated().map { index, page in
            KanzenReaderPage(pageData: page, index: index, chapterNumber: selectedChapter.chapterNumber)
        }
        pages = mapped
        currentPage = restoredPage(in: mapped)
        lastSavedChapterNumber = nil
        lastSavedPage = -1
        thresholdMarkedChapterNumber = nil
        ReaderLogger.shared.log(
            "Reader loaded chapter=\(selectedChapter.chapterNumber) pages=\(mapped.count) mode=\(mode.rawValue)",
            type: "Reader"
        )
        return mapped
    }

    func selectChapter(_ chapter: Chapter) {
        saveCurrentProgress(force: true)
        if let match = chapters.first(where: {
            ChapterIdentityNormalizer.key(for: $0.chapterNumber) == ChapterIdentityNormalizer.key(for: chapter.chapterNumber)
        }) {
            selectedChapter = match
        } else {
            selectedChapter = chapter
        }
        pages = []
        currentPage = 0
    }

    func movePreviousChapter() -> Bool {
        guard canMovePreviousChapter else { return false }
        selectChapter(chapters[chapterIndex - 1])
        return true
    }

    func moveNextChapter(markCurrentRead: Bool = true) -> Bool {
        guard canMoveNextChapter else { return false }
        if markCurrentRead {
            markCurrentChapterRead()
        }
        selectChapter(chapters[chapterIndex + 1])
        return true
    }

    func setCurrentPage(_ page: Int, totalPages: Int) {
        let safeTotal = max(totalPages, 1)
        currentPage = min(max(page, 0), safeTotal - 1)
        markReadIfThresholdReached(page: currentPage, totalPages: safeTotal)
    }

    func saveCurrentProgress(force: Bool = false) {
        guard mangaId != 0, !selectedChapter.chapterNumber.isEmpty else { return }
        let pageCount = max(pages.count, 1)
        let page = min(max(currentPage, 0), pageCount - 1)
        guard force || lastSavedChapterNumber != selectedChapter.chapterNumber || lastSavedPage != page else { return }
        lastSavedChapterNumber = selectedChapter.chapterNumber
        lastSavedPage = page
        MangaReadingProgressManager.shared.savePagePosition(
            mangaId: mangaId,
            chapterNumber: selectedChapter.chapterNumber,
            page: page,
            pageCount: pageCount,
            mangaTitle: mangaTitle,
            coverURL: mangaCoverURL,
            format: mangaFormat,
            totalChapters: totalChapters,
            latestChapterNumbers: latestChapterNumbers,
            route: mangaRoute,
            trackerAniListId: trackerAniListId,
            trackerMALId: trackerMALId,
            readThreshold: readThreshold
        )
    }

    func markCurrentChapterRead() {
        guard mangaId != 0, !selectedChapter.chapterNumber.isEmpty else { return }
        thresholdMarkedChapterNumber = selectedChapter.chapterNumber
        MangaReadingProgressManager.shared.markChapterRead(
            mangaId: mangaId,
            chapterNumber: selectedChapter.chapterNumber,
            mangaTitle: mangaTitle,
            coverURL: mangaCoverURL,
            format: mangaFormat,
            totalChapters: totalChapters,
            latestChapterNumbers: latestChapterNumbers,
            route: mangaRoute,
            trackerAniListId: trackerAniListId,
            trackerMALId: trackerMALId
        )
    }

    private func markReadIfThresholdReached(page: Int, totalPages: Int) {
        guard totalPages > 0 else { return }
        guard thresholdMarkedChapterNumber != selectedChapter.chapterNumber else { return }
        let completion = Double(min(page + 1, totalPages)) / Double(totalPages)
        if completion >= readThreshold || page >= totalPages - 1 {
            markCurrentChapterRead()
        }
    }

    private func restoredPage(in pages: [KanzenReaderPage]) -> Int {
        guard mangaId != 0, !pages.isEmpty else { return 0 }
        let saved = MangaReadingProgressManager.shared.pagePosition(
            mangaId: mangaId,
            chapterNumber: selectedChapter.chapterNumber
        )
        guard saved > 0 else { return 0 }
        return min(max(saved, 0), pages.count - 1)
    }
}

struct KanzenReaderPageLoader {
    let kanzen: KanzenEngine
    let route: MangaContentRoute?

    func loadPages(for chapter: Chapter, mode: KanzenReaderMode) async throws -> [PageData] {
        if let route,
           let localPages = ReaderDownloadManager.shared.pages(for: route, chapterNumber: chapter.chapterNumber) {
            ReaderLogger.shared.log("Reader using downloaded pages chapter=\(chapter.chapterNumber)", type: "ReaderDownload")
            return localPages
        }

        guard let params = chapter.chapterData?.first?.params else {
            throw NSError(domain: "KanzenReader", code: 2, userInfo: [NSLocalizedDescriptionKey: "No page source found for this chapter."])
        }

        if let payload = params as? ReaderDownloadedChapterPayload {
            if let pages = ReaderDownloadManager.shared.pages(for: payload.route, chapterNumber: payload.chapterNumber) {
                return pages
            }
            throw NSError(domain: "ReaderDownload", code: 404, userInfo: [NSLocalizedDescriptionKey: "Downloaded chapter files are missing."])
        }

        if let payload = params as? AidokuChapterPayload {
            return try await AidokuSourceManager.shared.pageList(
                sourceId: payload.sourceId,
                manga: payload.manga,
                chapter: payload.chapter,
                nativePages: mode == .webtoon
            )
        }

        if isLegacyNovelRoute {
            let text = await withCheckedContinuation { continuation in
                kanzen.extractText(params: params) { result in
                    continuation.resume(returning: result)
                }
            }
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text != "undefined" else {
                throw NSError(domain: "KanzenReader", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to extract text content."])
            }
            return [PageData(content: .text(text))]
        }

        let images = await withCheckedContinuation { continuation in
            kanzen.extractImages(params: params) { result in
                continuation.resume(returning: result)
            }
        } ?? []
        return images.map { PageData(content: $0) }
    }

    private var isLegacyNovelRoute: Bool {
        if case .legacyModule(_, _, let isNovel) = route {
            return isNovel
        }
        return false
    }
}
#endif
