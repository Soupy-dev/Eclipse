#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class MacReaderSession: ObservableObject {
    @Published private(set) var reader: KanzenReaderSession?
    @Published private(set) var pages: [KanzenReaderPage] = []
    @Published private(set) var isLoading = false
    @Published var error: String?
    @Published var errorKind: ReaderExtensionError?
    @Published private(set) var persistenceError: String?
    @Published var signInPresentation: MacReaderSignInPresentation?
    @Published var page = 0
    @Published var revision = UUID()
    @Published var pageCommand: MacReaderPageCommand?
    @Published var zoomCommand: MacReaderZoomCommand?
    @Published var magnification = 1.0
    @Published var textRecognitionCommand: MacReaderTextRecognitionCommand?
    @Published var retryPageCommand: MacReaderRetryPageCommand?
    var wheelNavigation = MacReaderWheelNavigationPolicy()
    @Published private(set) var novelReadingProgress = 0.0
    @Published private(set) var novelPositionCommand: MacReaderNovelPositionCommand?
    @Published var showsControls = true
    @Published var autoScroll = false
    @Published var autoScrollSpeed = 1.0
    @Published var settingsPresented = false
    private var task: Task<Void, Never>?
    private(set) var offlineLease: DownloadStorageLease?
    private var generation = UUID()
    private var profileObserver: NSObjectProtocol?
    private let settingsStoreOverride: UserDefaults?
    private(set) var owner = ProfileManager.shared.activeProfileID
    var isReading: Bool { reader != nil }
    var contentGeneration: UUID { generation }
    var settingsStore: UserDefaults { settingsStoreOverride ?? ProfileSettingsStore.shared.store(for: owner) }
    var effectiveReadingMode: KanzenReaderMode {
        let stores = settingsStoreOverride != nil || settingsStore === UserDefaults.standard ? [settingsStore] : [settingsStore, UserDefaults.standard]
        return KanzenReaderMode.resolveDefault(scopedKey: KanzenReaderMode.storageKey(scopeKey: reader?.readerSettingsScopeKey), stores: stores).mode
    }

    init(settingsStore: UserDefaults? = nil) {
        settingsStoreOverride = settingsStore
        profileObserver = NotificationCenter.default.addObserver(forName: .activeProfileDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    deinit {
        task?.cancel()
        if let profileObserver { NotificationCenter.default.removeObserver(profileObserver) }
    }

    func open(item: MangaLibraryItem, chapters: [Chapter], selected: Chapter, engine: KanzenEngine, pageLoader: ((Chapter, KanzenReaderMode) async throws -> [PageData])? = nil) {
        guard canStartWork else { return }
        close()
        guard ReaderContentFilter.shared.allows(libraryItem: item) else {
            error = "This title is unavailable in this profile."
            return
        }
        owner = ProfileManager.shared.activeProfileID
        reader = KanzenReaderSession(kanzen: engine, chapters: chapters, selectedChapter: selected, mangaId: item.id, mangaTitle: item.title, mangaCoverURL: item.coverURL ?? "", mangaRoute: item.route, mangaFormat: item.format, totalChapters: item.totalChapters, latestChapterNumbers: item.latestChapterNumbers, trackerAniListId: item.trackerAniListId, trackerMALId: item.trackerMALId, pageLoader: pageLoader)
        load()
    }

    func close() {
        generation = UUID()
        task?.cancel()
        task = nil
        _ = flushForMacTermination()
        reader?.invalidateChapterLoad()
        if let reader {
            ReaderExtensionManager.shared.releasePageResources(reader.pages.compactMap { $0.pageData.readerExtensionResource })
        }
        reader = nil
        offlineLease?.close()
        offlineLease = nil
        pages = []
        pageCommand = nil
        zoomCommand = nil
        magnification = 1
        textRecognitionCommand = nil
        retryPageCommand = nil
        wheelNavigation = MacReaderWheelNavigationPolicy()
        novelReadingProgress = 0
        novelPositionCommand = nil
        showsControls = true
        isLoading = false
        error = nil
        errorKind = nil
        signInPresentation = nil
        autoScroll = false
        settingsPresented = false
        ReaderExtensionCloudflareVerificationCoordinator.shared.cancel()
        owner = ProfileManager.shared.activeProfileID
    }

    func load() {
        guard canStartWork, let reader else { return }
        generation = UUID()
        let current = generation
        task?.cancel()
        isLoading = true
        error = nil
        errorKind = nil
        pages = []
        pageCommand = nil
        novelReadingProgress = 0
        novelPositionCommand = nil
        offlineLease?.close()
        offlineLease = nil
        task = Task { [weak self, weak reader] in
            guard let self, let reader else { return }
            do {
                if let route = reader.mangaRoute { self.offlineLease = try ReaderDownloadManager.shared.acquireOfflineChapter(route: route, chapterNumber: reader.selectedChapter.chapterNumber) }
                let result = try await reader.loadSelectedChapter()
                try Task.checkCancellation()
                guard self.generation == current, self.reader === reader else { return }
                self.pages = result
                self.page = reader.currentPage
                self.revision = UUID()
                self.isLoading = false
            } catch {
                guard !Task.isCancelled, self.generation == current else { return }
                self.isLoading = false
                self.error = error.localizedDescription
                self.errorKind = error as? ReaderExtensionError
            }
        }
    }

    func signInToSource() {
        guard canStartWork, !ProfileManager.shared.isKidsModeActive, let source = reader?.mangaRoute?.readerExtensionSourceID else { return }
        do { signInPresentation = MacReaderSignInPresentation(session: try ReaderExtensionManager.shared.makeSignInSession(for: source)) }
        catch { self.error = error.localizedDescription }
    }

    func select(_ chapter: Chapter) {
        guard canStartWork else { return }
        reader?.selectChapter(chapter)
        load()
    }

    func nextChapter() {
        guard canStartWork else { return }
        guard reader?.moveNextChapter() == true else { return }
        load()
    }

    func previousChapter() {
        guard canStartWork else { return }
        guard reader?.movePreviousChapter() == true else { return }
        load()
    }

    func requestPageStep(_ delta: Int) {
        guard canStartWork else { return }
        pageCommand = MacReaderPageCommand(delta: delta)
    }

    func requestZoom(_ action: MacReaderZoomCommand.Action) {
        guard canStartWork, !pages.isEmpty, !pages.allSatisfy(\.isText) else { return }
        zoomCommand = MacReaderZoomCommand(action: action)
    }

    func requestTextRecognition() {
        guard canStartWork, !pages.isEmpty, !pages.allSatisfy(\.isText), settingsStore.bool(forKey: "Reader.liveText") else { return }
        textRecognitionCommand = MacReaderTextRecognitionCommand(page: page, contentGeneration: contentGeneration)
    }

    func requestPageRetry() {
        guard canStartWork, !isLoading, pages.indices.contains(page), !pages[page].isText else { return }
        retryPageCommand = MacReaderRetryPageCommand(page: page, contentGeneration: contentGeneration)
    }

    func movePage(_ delta: Int) {
        let candidate = page + delta
        if candidate >= pages.count { nextChapter(); return }
        if candidate < 0 { previousChapter(); return }
        page = candidate
        revision = UUID()
    }

    func requestNovelPosition(_ fraction: Double) {
        guard canStartWork, !isLoading, !pages.isEmpty, pages.allSatisfy(\.isText) else { return }
        autoScroll = false
        novelPositionCommand = MacReaderNovelPositionCommand(fraction: MacReaderNovelPosition.finiteFraction(fraction), contentGeneration: contentGeneration)
    }

    func positionChanged(page: Int, completion: Double?) {
        guard let reader, !pages.isEmpty else { return }
        let next = min(max(page, 0), pages.count - 1)
        if self.page != next { self.page = next }
        if let completion, pages.allSatisfy(\.isText) {
            let progress = MacReaderNovelPosition.finiteFraction(completion)
            if novelReadingProgress != progress { novelReadingProgress = progress }
        }
        reader.setCurrentPage(self.page, totalPages: pages.count, completion: completion)
        reader.saveCurrentProgress()
    }

    func applySettings() {
        guard let reader else { return }
        reader.mode = effectiveReadingMode
        if reader.mode == .ltr || reader.mode == .rtl { autoScroll = false }
        revision = UUID()
        objectWillChange.send()
    }

    private var canStartWork: Bool {
        !MacLaunchProfileAccess.requiresUnlock && !MacLaunchProfileAccess.isTerminating
            && ProfileManager.shared.rosterStoreIsReadable
    }

    @discardableResult
    func flushForMacTermination() -> Bool {
        reader?.saveCurrentProgress(force: true)
        let progressSaved = MangaReadingProgressManager.shared.flushForMacTermination()
        let settingsSaved = settingsStore.synchronize()
        let success = progressSaved && settingsSaved
        persistenceError = success ? nil : "Reader progress could not be saved. Free disk space and retry before quitting."
        return success
    }
}

struct MacReaderNovelPositionCommand: Identifiable {
    let id = UUID()
    let fraction: Double
    let contentGeneration: UUID
}

struct MacReaderPageCommand: Identifiable {
    let id = UUID()
    let delta: Int
}

struct MacReaderZoomCommand: Identifiable {
    enum Action { case increase, decrease, reset }
    let id = UUID()
    let action: Action
}

struct MacReaderTextRecognitionCommand: Identifiable {
    let id = UUID()
    let page: Int
    let contentGeneration: UUID
}

struct MacReaderRetryPageCommand: Identifiable {
    let id = UUID()
    let page: Int
    let contentGeneration: UUID
}

struct MacReaderSignInPresentation: Identifiable {
    let id = UUID()
    let session: ReaderExtensionSignInSession
}

struct MacReaderSettingsSnapshot: Equatable {
    let mode: KanzenReaderMode
    let background: String
    let cropBorders: Bool
    let downsample: Bool
    let upscale: Bool
    let upscaleHeight: Int
    let modelURL: URL
    let modelRevision: String
    let preload: Int
    let layout: String
    let offset: Bool
    let split: Bool
    let reverseSplit: Bool
    let pillarbox: Double
    let pillarboxOrientation: String
    let infiniteScroll: Bool
    let font: String
    let fontSize: Double
    let fontWeight: String
    let lineSpacing: Double
    let margin: Double
    let alignment: String
    let colorPreset: Int
    let liveText: Bool
    let quickActions: Bool
    let doubleClickZoom: Bool
    let hideControlsOnScroll: Bool
    let animatePageTurns: Bool

    @MainActor
    init(session: MacReaderSession) {
        let store = session.settingsStore
        mode = session.reader?.mode ?? .webtoon
        background = store.string(forKey: "Reader.backgroundColor") ?? "black"
        cropBorders = store.bool(forKey: "Reader.cropBorders")
        downsample = store.object(forKey: "Reader.downsampleImages") as? Bool ?? true
        upscale = Self.imageUpscalingEnabled(store: store)
        upscaleHeight = min(max(store.object(forKey: "Reader.upscaleMaxHeight") as? Int ?? 2000, 800), 6000)
        modelURL = KanzenReaderUpscaleModelStore.storedModelURL(forProfile: session.owner)
        let modelMetadata = try? modelURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        modelRevision = "\(modelMetadata?.contentModificationDate?.timeIntervalSince1970 ?? 0):\(modelMetadata?.fileSize ?? 0)"
        preload = min(max(store.object(forKey: "Reader.pagesToPreload") as? Int ?? 3, 1), 10)
        layout = store.string(forKey: "Reader.pagedPageLayout") ?? "single"
        offset = MacReaderSettingsPolicy.pageOffset(store: store, scopeKey: session.reader?.readerSettingsScopeKey)
        split = store.bool(forKey: "Reader.splitWideImages")
        reverseSplit = store.bool(forKey: "Reader.reverseSplitOrder")
        pillarbox = store.bool(forKey: "Reader.pillarbox") ? Self.number(store, "Reader.pillarboxAmount", fallback: 15, bounds: 5...95) : 0
        pillarboxOrientation = store.string(forKey: "Reader.pillarboxOrientation") ?? "both"
        infiniteScroll = store.object(forKey: "Reader.verticalInfiniteScroll") as? Bool ?? true
        font = store.string(forKey: "readerFontFamily") ?? "-apple-system"
        fontSize = Self.number(store, "readerFontSize", fallback: 16, bounds: 12...32)
        fontWeight = store.string(forKey: "readerFontWeight") ?? "normal"
        lineSpacing = Self.number(store, "readerLineSpacing", fallback: 1.6, bounds: 1...3)
        margin = Self.number(store, "readerMargin", fallback: 4, bounds: 0...30)
        alignment = store.string(forKey: "readerTextAlignment") ?? "left"
        colorPreset = min(max(store.integer(forKey: "readerColorPreset"), 0), 4)
        liveText = store.bool(forKey: "Reader.liveText")
        quickActions = !store.bool(forKey: "Reader.disableQuickActions")
        doubleClickZoom = !store.bool(forKey: "Reader.disableDoubleTap")
        hideControlsOnScroll = store.bool(forKey: "Reader.hideBarsOnSwipe")
        animatePageTurns = store.object(forKey: "Reader.animatePageTransitions") as? Bool ?? true
    }

    static func imageUpscalingEnabled(
        store: UserDefaults,
        compatibility: IntelMacCompatibilityPolicy = PlatformCapabilities.current.intelMacCompatibility
    ) -> Bool {
        compatibility.supportsReaderImageUpscaling
            && !(store.object(forKey: "Reader.downsampleImages") as? Bool ?? true)
            && store.bool(forKey: "Reader.upscaleImages")
    }

    private static func number(_ store: UserDefaults, _ key: String, fallback: Double, bounds: ClosedRange<Double>) -> Double {
        let number = store.object(forKey: key) as? Double ?? fallback
        return number.isFinite ? min(max(number, bounds.lowerBound), bounds.upperBound) : fallback
    }
}
#endif
