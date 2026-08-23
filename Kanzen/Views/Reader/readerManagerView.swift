import SwiftUI
import UIKit
import UniformTypeIdentifiers

#if !os(tvOS)
typealias KanzenReaderChildViewController = UIViewController & KanzenReaderChildControlling

protocol KanzenReaderChildControlling: AnyObject {
    var readerDelegate: KanzenReaderChildDelegate? { get set }
    func setPages(_ pages: [KanzenReaderPage], startPage: Int)
    func applyReaderSettings(reloadCurrentPages: Bool)
    func moveToPage(_ page: Int, animated: Bool)
    func moveLeft()
    func moveRight()
}

protocol KanzenReaderChildDelegate: AnyObject {
    func readerChildDidRequestOverlayToggle()
    func readerChildDidChangePage(_ page: Int, totalPages: Int)
    func readerChildDidReachEnd()
    func readerChildDidRequestNextChapter() -> Bool
}

private func kanzenReaderCanvasColor(for style: UIUserInterfaceStyle) -> UIColor {
    let storedValue = ProfileSettingsStore.active.string(forKey: "Reader.backgroundColor")
    switch storedValue {
    case "white":
        return .white
    case "system":
        return .systemBackground
    case "auto":
        return style == .dark ? .black : .white
    default:
        if ExperimentalFeatureState.isEnabledAtLaunch {
            return UIColor(red: 0.055, green: 0.050, blue: 0.090, alpha: 1)
        }
        return .black
    }
}

enum KanzenTapZonePreset: String, CaseIterable, Identifiable {
    case automatic = "auto"
    case leftRight = "left-right"
    case lShaped = "l-shaped"
    case kindle = "kindle"
    case edge = "edge"
    case disabled = "disabled"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .leftRight: return "Left / Right"
        case .lShaped: return "L-Shaped"
        case .kindle: return "Kindle"
        case .edge: return "Edge"
        case .disabled: return "Disabled"
        }
    }
}

struct KanzenTapZone {
    enum ReaderKind {
        case paged
        case webtoon
        case text
    }

    enum RegionType {
        case left
        case right
    }

    struct Region {
        let bounds: CGRect
        let type: RegionType
    }

    let regions: [Region]

    static func configured(for kind: ReaderKind) -> KanzenTapZone? {
        let raw = ProfileSettingsStore.active.string(forKey: "Reader.tapZones") ?? KanzenTapZonePreset.disabled.rawValue
        let preset = KanzenTapZonePreset(rawValue: raw) ?? .disabled
        switch preset {
        case .automatic:
            return kind == .paged ? .leftRight : .lShaped
        case .leftRight:
            return .leftRight
        case .lShaped:
            return .lShaped
        case .kindle:
            return .kindle
        case .edge:
            return .edge
        case .disabled:
            return nil
        }
    }

    static func action(at point: CGPoint, in bounds: CGRect, kind: ReaderKind) -> RegionType? {
        guard bounds.width > 0, bounds.height > 0,
              let zone = configured(for: kind) else {
            return nil
        }
        let relativePoint = CGPoint(x: point.x / bounds.width, y: point.y / bounds.height)
        return zone.regions.first { $0.bounds.contains(relativePoint) }?.type
    }

    static let leftRight = KanzenTapZone(regions: [
        Region(bounds: CGRect(x: 0, y: 0, width: 1.0 / 3.0, height: 1), type: .left),
        Region(bounds: CGRect(x: 2.0 / 3.0, y: 0, width: 1.0 / 3.0, height: 1), type: .right)
    ])

    static let lShaped = KanzenTapZone(regions: [
        Region(bounds: CGRect(x: 0, y: 1.0 / 3.0, width: 1.0 / 3.0, height: 1.0 / 3.0), type: .left),
        Region(bounds: CGRect(x: 0, y: 0, width: 1, height: 1.0 / 3.0), type: .left),
        Region(bounds: CGRect(x: 2.0 / 3.0, y: 1.0 / 3.0, width: 1.0 / 3.0, height: 2.0 / 3.0), type: .right),
        Region(bounds: CGRect(x: 0, y: 2.0 / 3.0, width: 2.0 / 3.0, height: 1.0 / 3.0), type: .right)
    ])

    static let kindle = KanzenTapZone(regions: [
        Region(bounds: CGRect(x: 0, y: 1.0 / 3.0, width: 1.0 / 3.0, height: 2.0 / 3.0), type: .left),
        Region(bounds: CGRect(x: 1.0 / 3.0, y: 1.0 / 3.0, width: 2.0 / 3.0, height: 2.0 / 3.0), type: .right)
    ])

    static let edge = KanzenTapZone(regions: [
        Region(bounds: CGRect(x: 0, y: 0, width: 1.0 / 3.0, height: 1), type: .right),
        Region(bounds: CGRect(x: 1.0 / 3.0, y: 2.0 / 3.0, width: 1.0 / 3.0, height: 1.0 / 3.0), type: .left),
        Region(bounds: CGRect(x: 2.0 / 3.0, y: 0, width: 1.0 / 3.0, height: 1), type: .right)
    ])
}

enum KanzenReaderUpscaleModelStore {
    private static let storedFileName = "reader-upscale.mlmodel"

    static func storedModelURL(forProfile profileID: UUID) -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReaderUpscaling", isDirectory: true)
        guard profileID != ProfileManager.defaultProfileID else {
            return directory.appendingPathComponent(storedFileName)
        }
        return directory.appendingPathComponent("\(profileID.uuidString.lowercased())-\(storedFileName)")
    }

    static var storedModelURL: URL {
        storedModelURL(forProfile: ProfileManager.shared.activeProfileID)
    }

    static func discardModel(forProfile profileID: UUID) {
        guard profileID != ProfileManager.defaultProfileID else { return }
        try? FileManager.default.removeItem(at: storedModelURL(forProfile: profileID))
    }

    static var storedModelName: String {
        guard FileManager.default.fileExists(atPath: storedModelURL.path) else {
            return "None"
        }
        return ProfileSettingsStore.active.string(forKey: "Reader.upscaleModelName") ?? "None"
    }

    static func importModel(from sourceURL: URL) throws {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let directory = storedModelURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: storedModelURL.path) {
            try FileManager.default.removeItem(at: storedModelURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: storedModelURL)
        ProfileSettingsStore.active.set(sourceURL.lastPathComponent, forKey: "Reader.upscaleModelName")
    }

    static func clearModel() {
        try? FileManager.default.removeItem(at: storedModelURL)
        ProfileSettingsStore.active.removeObject(forKey: "Reader.upscaleModelName")
    }
}

struct readerManagerView: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss

    let chapters: [Chapter]?
    let selectedChapter: Chapter?
    let kanzen: KanzenEngine
    let mangaId: Int
    let mangaTitle: String
    let mangaCoverURL: String
    let mangaRoute: MangaContentRoute?
    let mangaFormat: String?
    let totalChapters: Int?
    let latestChapterNumbers: [String]?
    let trackerAniListId: Int?
    let trackerMALId: Int?

    init(
        chapters: [Chapter]?,
        selectedChapter: Chapter?,
        kanzen: KanzenEngine,
        mangaId: Int = 0,
        mangaTitle: String = "",
        mangaCoverURL: String = "",
        mangaRoute: MangaContentRoute? = nil,
        mangaFormat: String? = nil,
        totalChapters: Int? = nil,
        latestChapterNumbers: [String]? = nil,
        trackerAniListId: Int? = nil,
        trackerMALId: Int? = nil
    ) {
        self.chapters = chapters
        self.selectedChapter = selectedChapter
        self.kanzen = kanzen
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

    func makeUIViewController(context: Context) -> KanzenReaderViewController {
        let session = KanzenReaderSession(
            kanzen: kanzen,
            chapters: chapters,
            selectedChapter: selectedChapter,
            mangaId: mangaId,
            mangaTitle: mangaTitle,
            mangaCoverURL: mangaCoverURL,
            mangaRoute: mangaRoute,
            mangaFormat: mangaFormat,
            totalChapters: totalChapters,
            latestChapterNumbers: latestChapterNumbers,
            trackerAniListId: trackerAniListId,
            trackerMALId: trackerMALId
        )
        let controller = KanzenReaderViewController(session: session)
        controller.onClose = { dismiss() }
        return controller
    }

    func updateUIViewController(_ uiViewController: KanzenReaderViewController, context: Context) {
        uiViewController.onClose = { dismiss() }
    }
}

final class KanzenReaderViewController: UIViewController, KanzenReaderChildDelegate {
    let session: KanzenReaderSession
    var onClose: (() -> Void)?

    private let experimentalBackgroundLayer = CAGradientLayer()
    private let overlayView = KanzenReaderOverlayView()
    private let loadingView = UIActivityIndicatorView(style: .large)
    private let errorContainer = UIStackView()
    private let errorLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let notNowButton = UIButton(type: .system)
    private var activeReader: KanzenReaderChildViewController?
    private var loadTask: Task<Void, Never>?
    private var pendingDomainApproval: ReaderExtensionDomainConsentRequest?
    private var pendingVerification: (sourceID: ReaderExtensionSourceID, host: String)?
    private var barsVisible = true
    private var didRequestClose = false
    private weak var readerWindowScene: UIWindowScene?

    private var orientationLockEnabled: Bool {
        get { ProfileSettingsStore.active.bool(forKey: "readerOrientationLockEnabled") }
        set { ProfileSettingsStore.active.set(newValue, forKey: "readerOrientationLockEnabled") }
    }

    private var orientationLockMaskRaw: String {
        get { ProfileSettingsStore.active.string(forKey: "readerOrientationLockMask") ?? "all" }
        set { ProfileSettingsStore.active.set(newValue, forKey: "readerOrientationLockMask") }
    }

    init(session: KanzenReaderSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
        modalPresentationCapturesStatusBarAppearance = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var prefersStatusBarHidden: Bool { !barsVisible }
    override var prefersHomeIndicatorAutoHidden: Bool { !barsVisible }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = readerBackgroundColor()
        configureExperimentalBackgroundIfNeeded()
        configureLoadingView()
        configureErrorView()
        configureOverlay()
        applyReaderOrientationPreference()
        ReaderLogger.shared.log("Reader controller opened title=\(mangaLogTitle) chapter=\(session.selectedChapter.chapterNumber) mode=\(session.mode.rawValue)", type: "Reader")
        loadCurrentChapter()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        experimentalBackgroundLayer.frame = view.bounds
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        readerWindowScene = view.window?.windowScene ?? readerWindowScene
        applyPersistedOrientationLockIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        session.saveCurrentProgress(force: true)
        releaseActiveOrientationLock()
        readerWindowScene = nil
    }

    deinit {
        loadTask?.cancel()
    }

    private func configureLoadingView() {
        loadingView.color = .white
        loadingView.hidesWhenStopped = true
        loadingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(loadingView)
        NSLayoutConstraint.activate([
            loadingView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            loadingView.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func configureExperimentalBackgroundIfNeeded() {
        guard ExperimentalFeatureState.isEnabledAtLaunch else { return }
        experimentalBackgroundLayer.colors = [
            UIColor(red: 0.04, green: 0.07, blue: 0.12, alpha: 1).cgColor,
            UIColor(red: 0.24, green: 0.18, blue: 0.42, alpha: 1).cgColor,
            UIColor(red: 0.13, green: 0.12, blue: 0.22, alpha: 1).cgColor,
            UIColor(red: 0.05, green: 0.05, blue: 0.09, alpha: 1).cgColor
        ]
        experimentalBackgroundLayer.locations = [0.0, 0.38, 0.72, 1.0]
        experimentalBackgroundLayer.startPoint = CGPoint(x: 0.0, y: 0.0)
        experimentalBackgroundLayer.endPoint = CGPoint(x: 1.0, y: 1.0)
        experimentalBackgroundLayer.frame = view.bounds
        view.layer.insertSublayer(experimentalBackgroundLayer, at: 0)
    }

    private func configureErrorView() {
        errorContainer.axis = .vertical
        errorContainer.alignment = .center
        errorContainer.spacing = 12
        errorContainer.isHidden = true
        errorContainer.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView(image: UIImage(systemName: "exclamationmark.triangle"))
        icon.tintColor = UIColor.white.withAlphaComponent(0.72)
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.heightAnchor.constraint(equalToConstant: 34).isActive = true
        icon.widthAnchor.constraint(equalToConstant: 34).isActive = true

        errorLabel.textColor = UIColor.white.withAlphaComponent(0.78)
        errorLabel.font = .preferredFont(forTextStyle: .subheadline)
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center

        retryButton.setTitle("Retry", for: .normal)
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)
        notNowButton.setTitle("Not Now", for: .normal)
        notNowButton.addTarget(self, action: #selector(notNowTapped), for: .touchUpInside)
        notNowButton.isHidden = true

        errorContainer.addArrangedSubview(icon)
        errorContainer.addArrangedSubview(errorLabel)
        errorContainer.addArrangedSubview(retryButton)
        errorContainer.addArrangedSubview(notNowButton)
        view.addSubview(errorContainer)
        NSLayoutConstraint.activate([
            errorContainer.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            errorContainer.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            errorContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            errorContainer.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    private func configureOverlay() {
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        overlayView.onClose = { [weak self] in self?.closeReader() }
        overlayView.onSettings = { [weak self] in self?.presentSettings() }
        overlayView.onChapterList = { [weak self] in self?.presentChapterList() }
        overlayView.onPreviousChapter = { [weak self] in self?.goToPreviousChapter() }
        overlayView.onNextChapter = { [weak self] in self?.goToNextChapter() }
        overlayView.onOrientationLock = { [weak self] in self?.toggleOrientationLock() }
        view.addSubview(overlayView)
        NSLayoutConstraint.activate([
            overlayView.topAnchor.constraint(equalTo: view.topAnchor),
            overlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlayView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        updateOverlay(page: 0, totalPages: 1)
    }

    private func loadCurrentChapter() {
        loadTask?.cancel()
        pendingDomainApproval = nil
        pendingVerification = nil
        retryButton.setTitle("Retry", for: .normal)
        notNowButton.isHidden = true
        loadingView.startAnimating()
        errorContainer.isHidden = true
        activeReader?.view.isHidden = true
        ReaderLogger.shared.log("Reader chapter load start chapter=\(session.selectedChapter.chapterNumber) mode=\(session.mode.rawValue)", type: "Reader")

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let pages = try await self.session.loadSelectedChapter()
                try Task.checkCancellation()
                await MainActor.run {
                    self.loadingView.stopAnimating()
                    self.installReader(for: pages)
                }
            } catch is CancellationError {
                await MainActor.run { self.loadingView.stopAnimating() }
            } catch {
                await MainActor.run {
                    self.loadingView.stopAnimating()
                    if case ReaderExtensionError.domainConsentRequired(let host) = error,
                       let sourceID = self.session.mangaRoute?.readerExtensionSourceID {
                        self.showDomainConsentPrompt(host: host, sourceID: sourceID)
                    } else if case ReaderExtensionError.browserVerificationRequired(let host) = error,
                              let sourceID = self.session.mangaRoute?.readerExtensionSourceID {
                        self.showBrowserVerificationPrompt(host: host, sourceID: sourceID)
                    } else {
                        self.showError(error.localizedDescription)
                    }
                }
                ReaderLogger.shared.log(
                    "Reader load failed error=\(ReaderExtensionDiagnostics.errorCode(error))",
                    type: "ReaderError"
                )
            }
        }
    }

    private func installReader(for pages: [KanzenReaderPage]) {
        let nextReader: KanzenReaderChildViewController
        if pages.allSatisfy(\.isText) {
            nextReader = KanzenTextReaderViewController()
        } else if session.mode == .webtoon {
            nextReader = KanzenWebtoonReaderViewController()
        } else {
            nextReader = KanzenPagedReaderViewController(mode: session.mode, pageOffsetKey: KanzenReaderSettingsView.pageOffsetStorageKey(scopeKey: session.readerSettingsScopeKey))
        }

        let needsNewReader: Bool
        if let activeReader {
            needsNewReader = ObjectIdentifier(type(of: activeReader)) != ObjectIdentifier(type(of: nextReader))
        } else {
            needsNewReader = true
        }

        if needsNewReader {
            activeReader?.willMove(toParent: nil)
            activeReader?.view.removeFromSuperview()
            activeReader?.removeFromParent()

            nextReader.readerDelegate = self
            addChild(nextReader)
            nextReader.view.translatesAutoresizingMaskIntoConstraints = false
            view.insertSubview(nextReader.view, belowSubview: overlayView)
            NSLayoutConstraint.activate([
                nextReader.view.topAnchor.constraint(equalTo: view.topAnchor),
                nextReader.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                nextReader.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                nextReader.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            nextReader.didMove(toParent: self)
            activeReader = nextReader
        } else {
            activeReader?.readerDelegate = self
            activeReader?.view.isHidden = false
        }

        view.backgroundColor = readerBackgroundColor()
        activeReader?.setPages(pages, startPage: session.currentPage)
        activeReader?.applyReaderSettings(reloadCurrentPages: false)
        updateOverlay(page: session.currentPage, totalPages: pages.count)
        let rendererName = activeReader.map { String(describing: type(of: $0)) } ?? "unknown"
        ReaderLogger.shared.log("Reader installed renderer=\(rendererName) chapter=\(session.selectedChapter.chapterNumber) pages=\(pages.count) startPage=\(session.currentPage)", type: "Reader")
    }

    private func showError(_ message: String) {
        activeReader?.view.isHidden = true
        pendingDomainApproval = nil
        pendingVerification = nil
        retryButton.setTitle("Retry", for: .normal)
        notNowButton.isHidden = true
        errorLabel.text = message
        errorContainer.isHidden = false
    }

    private func showDomainConsentPrompt(host: String, sourceID: ReaderExtensionSourceID) {
        activeReader?.view.isHidden = true
        let sourceName = ReaderExtensionManager.shared.source(for: sourceID)?.name ?? "This reader source"
        let request = ReaderExtensionManager.shared.domainConsentRequest(
            domain: host,
            for: sourceID
        )
        guard ReaderExtensionDomainConsentCoordinator.shared.claim(request) else {
            showError("This domain request is already being reviewed.")
            return
        }
        pendingDomainApproval = request
        errorLabel.text = "\(sourceName) wants to contact \(host). Approval applies only to this source, profile, and device. It may send requests and matching authentication cookies to that domain."
        retryButton.setTitle("Allow & Retry", for: .normal)
        notNowButton.isHidden = false
        errorContainer.isHidden = false
    }

    /// The site wants a browser check. Reuse the source-scoped sign-in
    /// browser: it runs the page in WebKit and writes any resulting cookies
    /// into the same source jar the pinned transport reads from, so a solved
    /// challenge simply makes the next request succeed.
    private func showBrowserVerificationPrompt(host: String, sourceID: ReaderExtensionSourceID) {
        activeReader?.view.isHidden = true
        pendingDomainApproval = nil
        pendingVerification = (sourceID, host)
        let sourceName = ReaderExtensionManager.shared.source(for: sourceID)?.name ?? "This reader source"
        errorLabel.text = "\(host) is asking for a browser verification check before \(sourceName) can load. Open it to complete the check, then retry."
        retryButton.setTitle("Open Verification", for: .normal)
        notNowButton.isHidden = false
        errorContainer.isHidden = false
    }

    private func presentBrowserVerification(
        sourceID: ReaderExtensionSourceID,
        host: String
    ) {
        do {
            guard let challengedURL = ReaderExtensionSecurityPolicy.canonicalHTTPSURL(
                forHost: host
            ) else {
                throw ReaderExtensionError.insecureURL
            }
            let session = try ReaderExtensionManager.shared.makeBrowserVerificationSession(
                for: sourceID,
                challengedURL: challengedURL
            )
            let controller = UIHostingController(
                rootView: ReaderExtensionCloudflareVerificationView(
                    session: session,
                    userAgent: ReaderExtensionSecurityPolicy.defaultReaderUserAgent
                )
            )
            controller.modalPresentationStyle = .formSheet
            present(controller, animated: true)
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func retryTapped() {
        if let pendingVerification {
            self.pendingVerification = nil
            retryButton.setTitle("Retry", for: .normal)
            notNowButton.isHidden = true
            presentBrowserVerification(
                sourceID: pendingVerification.sourceID,
                host: pendingVerification.host
            )
            return
        }
        if let pendingDomainApproval {
            do {
                try ReaderExtensionManager.shared.approve(pendingDomainApproval)
            } catch {
                showError(error.localizedDescription)
                return
            }
        }
        loadCurrentChapter()
    }

    @objc private func notNowTapped() {
        if let pendingDomainApproval {
            ReaderExtensionDomainConsentCoordinator.shared.defer(pendingDomainApproval)
        }
        let declinedVerification = pendingVerification != nil
        pendingDomainApproval = nil
        pendingVerification = nil
        retryButton.setTitle("Retry", for: .normal)
        notNowButton.isHidden = true
        errorLabel.text = declinedVerification
            ? "Verification was not completed. Retry once the site check has been passed."
            : "Domain access was not allowed. Retry when you are ready to review the request again."
    }

    private func updateOverlay(page: Int, totalPages: Int) {
        overlayView.update(
            title: session.mangaTitle,
            chapter: session.selectedChapter.chapterNumber,
            page: page,
            totalPages: totalPages,
            canPrevious: session.canMovePreviousChapter,
            canNext: session.canMoveNextChapter,
            orientationLocked: orientationLockEnabled
        )
    }

    func readerChildDidRequestOverlayToggle() {
        setBarsVisible(!barsVisible, animated: true)
    }

    func readerChildDidChangePage(_ page: Int, totalPages: Int) {
        session.setCurrentPage(page, totalPages: totalPages)
        updateOverlay(page: page, totalPages: totalPages)
    }

    func readerChildDidReachEnd() {
        session.markCurrentChapterRead()
    }

    func readerChildDidRequestNextChapter() -> Bool {
        guard session.canMoveNextChapter else { return false }
        goToNextChapter()
        return true
    }

    private func setBarsVisible(_ visible: Bool, animated: Bool) {
        barsVisible = visible
        setNeedsStatusBarAppearanceUpdate()
        let changes = {
            self.overlayView.alpha = visible ? 1 : 0
        }
        if animated {
            UIView.animate(withDuration: 0.18, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes)
        } else {
            changes()
        }
    }

    private func closeReader() {
        guard !didRequestClose else { return }
        didRequestClose = true
        onClose?()
    }

    private func goToPreviousChapter() {
        guard session.movePreviousChapter() else { return }
        loadCurrentChapter()
    }

    private func goToNextChapter() {
        guard session.moveNextChapter(markCurrentRead: true) else { return }
        loadCurrentChapter()
    }

    private func presentChapterList() {
        let view = KanzenReaderChapterListView(
            chapters: session.chapters,
            selectedChapter: session.selectedChapter,
            mangaId: session.mangaId
        ) { [weak self] chapter in
            self?.dismiss(animated: true)
            self?.session.selectChapter(chapter)
            self?.loadCurrentChapter()
        }
        present(
            UIHostingController(
                rootView: NavigationView { view }
                    .navigationViewStyle(StackNavigationViewStyle())

                    .profileScopedAppStorage()
            ),
            animated: true
        )
    }

    private func presentSettings() {
        ReaderLogger.shared.log("Reader settings opened chapter=\(session.selectedChapter.chapterNumber) mode=\(session.mode.rawValue)", type: "ReaderSettings")
        let view = KanzenReaderSettingsView(
            scopeKey: session.readerSettingsScopeKey,
            onModeChanged: { [weak self] mode in
                guard let self else { return }
                self.session.mode = mode
                ProfileSettingsStore.active.set(mode.rawValue, forKey: self.session.readerModeStorageKey)
                if self.session.readerModeStorageKey == "kanzenReaderMode" {
                    ProfileSettingsStore.active.set(mode.readingMode.rawValue, forKey: "readingMode")
                }
                ReaderLogger.shared.log("Reader mode changed mode=\(mode.rawValue)", type: "ReaderSettings")
                self.loadCurrentChapter()
            },
            onSettingsChanged: { [weak self] requiresReload, key in
                self?.applyReaderSettings(reloadPages: requiresReload, changedKey: key)
            }
        )
        present(
            UIHostingController(
                rootView: NavigationView { view }
                    .navigationViewStyle(StackNavigationViewStyle())

                    .profileScopedAppStorage()
            ),
            animated: true
        )
    }

    private func applyReaderSettings(reloadPages: Bool, changedKey: String) {
        view.backgroundColor = readerBackgroundColor()
        ReaderLogger.shared.log("Reader setting changed key=\(changedKey) reload=\(reloadPages)", type: "ReaderSettings")

        if changedKey == "Reader.orientation" {
            applyReaderOrientationPreference()
        }

        if reloadPages {
            activeReader?.setPages(session.pages, startPage: session.currentPage)
        }
        activeReader?.applyReaderSettings(reloadCurrentPages: false)
        updateOverlay(page: session.currentPage, totalPages: max(session.pages.count, 1))
    }

    private func toggleOrientationLock() {
        if orientationLockEnabled {
            orientationLockEnabled = false
            orientationLockMaskRaw = "all"
            applyReaderOrientationPreference()
        } else {
            let mask = currentExactOrientationMask()
            orientationLockEnabled = true
            orientationLockMaskRaw = rawValue(for: mask)
            applyOrientationMask(mask)
        }
        updateOverlay(page: session.currentPage, totalPages: max(session.pages.count, 1))
    }

    private func applyPersistedOrientationLockIfNeeded() {
        if orientationLockEnabled {
            applyOrientationMask(mask(for: orientationLockMaskRaw))
        } else {
            applyReaderOrientationPreference()
        }
    }

    private func applyReaderOrientationPreference() {
        guard !orientationLockEnabled else { return }
        switch ProfileSettingsStore.active.string(forKey: "Reader.orientation") ?? "device" {
        case "portrait":
            applyOrientationMask(.portrait)
        case "landscape":
            applyOrientationMask(.landscape)
        case "all":
            applyOrientationMask(.all)
        default:
            applyOrientationMask(.all)
        }
    }

    private func releaseActiveOrientationLock() {
        guard let scene = activeWindowScene else { return }
        AppDelegate.setOrientationLock(.all, for: scene)
        if #available(iOS 16.0, *) {
            viewIfLoaded?.window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        } else {
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    private func currentExactOrientationMask() -> UIInterfaceOrientationMask {
        guard let orientation = activeWindowScene?.interfaceOrientation else { return .portrait }
        switch orientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return orientation.isLandscape ? .landscape : .portrait
        }
    }

    private func applyOrientationMask(_ mask: UIInterfaceOrientationMask) {

        guard let scene = activeWindowScene else { return }
        AppDelegate.setOrientationLock(mask, for: scene)
        if #available(iOS 16.0, *) {
            viewIfLoaded?.window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                ReaderLogger.shared.log(
                    "Reader orientation request failed mask=\(mask.rawValue): \(error.localizedDescription)",
                    type: "ReaderSettings"
                )
            }
        } else {
            UIViewController.attemptRotationToDeviceOrientation()
        }
    }

    private var activeWindowScene: UIWindowScene? {
        viewIfLoaded?.window?.windowScene ?? readerWindowScene
    }

    private func rawValue(for mask: UIInterfaceOrientationMask) -> String {
        switch mask {
        case .portrait: return "portrait"
        case .portraitUpsideDown: return "portraitUpsideDown"
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        case .landscape: return "landscape"
        default: return "all"
        }
    }

    private func mask(for rawValue: String) -> UIInterfaceOrientationMask {
        switch rawValue {
        case "portrait": return .portrait
        case "portraitUpsideDown": return .portraitUpsideDown
        case "landscapeLeft": return .landscapeLeft
        case "landscapeRight": return .landscapeRight
        case "landscape": return .landscape
        default: return .all
        }
    }

    private func readerBackgroundColor() -> UIColor {
        kanzenReaderCanvasColor(for: traitCollection.userInterfaceStyle)
    }

    private var mangaLogTitle: String {
        session.mangaTitle.isEmpty ? "<untitled>" : session.mangaTitle
    }
}

private final class KanzenReaderOverlayView: UIView {
    var onClose: (() -> Void)?
    var onSettings: (() -> Void)?
    var onChapterList: (() -> Void)?
    var onPreviousChapter: (() -> Void)?
    var onNextChapter: (() -> Void)?
    var onOrientationLock: (() -> Void)?

    private let topPanel = UIStackView()
    private let bottomPanel = UIStackView()
    private let titleLabel = UILabel()
    private let chapterLabel = UILabel()
    private let pageLabel = UILabel()
    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let lockButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true
        configureTopPanel()
        configureBottomPanel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hitView = super.hitTest(point, with: event)
        return hitView === self ? nil : hitView
    }

    func update(
        title: String,
        chapter: String,
        page: Int,
        totalPages: Int,
        canPrevious: Bool,
        canNext: Bool,
        orientationLocked: Bool
    ) {
        titleLabel.text = title.isEmpty ? "Reader" : title
        chapterLabel.text = chapter
        pageLabel.text = "\(min(max(page + 1, 1), max(totalPages, 1))) of \(max(totalPages, 1))"
        previousButton.isEnabled = canPrevious
        nextButton.isEnabled = canNext
        previousButton.tintColor = canPrevious ? .white : UIColor.white.withAlphaComponent(0.3)
        nextButton.tintColor = canNext ? .white : UIColor.white.withAlphaComponent(0.3)
        lockButton.setImage(UIImage(systemName: orientationLocked ? "lock.fill" : "lock.open"), for: .normal)
    }

    private func configureTopPanel() {
        topPanel.axis = .horizontal
        topPanel.alignment = .center
        topPanel.spacing = 12
        applyPanelChrome(to: topPanel)
        topPanel.isLayoutMarginsRelativeArrangement = true
        topPanel.layoutMargins = ExperimentalFeatureState.isEnabledAtLaunch
            ? UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 14)
            : UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        topPanel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.textColor = .white
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.lineBreakMode = .byTruncatingTail

        chapterLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        chapterLabel.font = .preferredFont(forTextStyle: .subheadline)
        chapterLabel.adjustsFontForContentSizeCategory = true
        chapterLabel.lineBreakMode = .byTruncatingTail

        let labels = UIStackView(arrangedSubviews: [titleLabel, chapterLabel])
        labels.axis = .vertical
        labels.spacing = 2

        let close = iconButton("xmark", action: #selector(closeTapped))
        topPanel.addArrangedSubview(labels)
        topPanel.addArrangedSubview(close)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(topPanel)
        let preferredWidth = topPanel.widthAnchor.constraint(equalTo: widthAnchor, constant: -72)
        preferredWidth.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            topPanel.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 10),
            topPanel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            topPanel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            topPanel.centerXAnchor.constraint(equalTo: centerXAnchor),
            preferredWidth,
            topPanel.widthAnchor.constraint(lessThanOrEqualToConstant: 720)
        ])
    }

    private func configureBottomPanel() {
        bottomPanel.axis = .horizontal
        bottomPanel.alignment = .center
        bottomPanel.spacing = 16
        applyPanelChrome(to: bottomPanel)
        bottomPanel.isLayoutMarginsRelativeArrangement = true
        bottomPanel.layoutMargins = ExperimentalFeatureState.isEnabledAtLaunch
            ? UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
            : UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        bottomPanel.translatesAutoresizingMaskIntoConstraints = false

        lockButton.tintColor = .white
        lockButton.addTarget(self, action: #selector(lockTapped), for: .touchUpInside)
        constrainIcon(lockButton)

        let settings = iconButton("gearshape.fill", action: #selector(settingsTapped))
        let list = iconButton("list.bullet", action: #selector(listTapped))
        let spacer = UIView()

        previousButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        previousButton.addTarget(self, action: #selector(previousTapped), for: .touchUpInside)
        constrainIcon(previousButton, width: 28)

        pageLabel.textColor = .white
        pageLabel.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .medium)
        pageLabel.textAlignment = .center
        pageLabel.adjustsFontSizeToFitWidth = true
        pageLabel.minimumScaleFactor = 0.78
        pageLabel.widthAnchor.constraint(equalToConstant: 82).isActive = true

        nextButton.setImage(UIImage(systemName: "chevron.right"), for: .normal)
        nextButton.addTarget(self, action: #selector(nextTapped), for: .touchUpInside)
        constrainIcon(nextButton, width: 28)

        let pager = UIStackView(arrangedSubviews: [previousButton, pageLabel, nextButton])
        pager.axis = .horizontal
        pager.alignment = .center
        pager.spacing = 8
        pager.backgroundColor = ExperimentalFeatureState.isEnabledAtLaunch
            ? UIColor.white.withAlphaComponent(0.16)
            : UIColor.white.withAlphaComponent(0.12)
        pager.layer.cornerRadius = 18
        if ExperimentalFeatureState.isEnabledAtLaunch {
            pager.layer.borderWidth = 1
            pager.layer.borderColor = UIColor.white.withAlphaComponent(0.10).cgColor
        }
        pager.isLayoutMarginsRelativeArrangement = true
        pager.layoutMargins = UIEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)

        [lockButton, settings, list, spacer, pager].forEach { bottomPanel.addArrangedSubview($0) }
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        addSubview(bottomPanel)
        let preferredWidth = bottomPanel.widthAnchor.constraint(equalTo: widthAnchor, constant: -72)
        preferredWidth.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            bottomPanel.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -10),
            bottomPanel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            bottomPanel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            bottomPanel.centerXAnchor.constraint(equalTo: centerXAnchor),
            topPanel.widthAnchor.constraint(equalTo: bottomPanel.widthAnchor),
            preferredWidth,
            bottomPanel.widthAnchor.constraint(lessThanOrEqualToConstant: 720)
        ])
    }

    private func iconButton(_ systemName: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: systemName), for: .normal)
        button.tintColor = .white
        button.addTarget(self, action: action, for: .touchUpInside)
        constrainIcon(button)
        return button
    }

    private func constrainIcon(_ button: UIButton, width: CGFloat = 36) {
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        button.heightAnchor.constraint(equalToConstant: 36).isActive = true
    }

    private func applyPanelChrome(to panel: UIStackView) {
        panel.backgroundColor = ExperimentalFeatureState.isEnabledAtLaunch
            ? UIColor(red: 0.10, green: 0.09, blue: 0.16, alpha: 0.86)
            : UIColor.black.withAlphaComponent(0.78)
        panel.layer.cornerRadius = ExperimentalFeatureState.isEnabledAtLaunch ? 24 : 22
        panel.layer.cornerCurve = .continuous
        panel.layer.borderWidth = ExperimentalFeatureState.isEnabledAtLaunch ? 1 : 0
        panel.layer.borderColor = ExperimentalFeatureState.isEnabledAtLaunch
            ? UIColor(red: 0.52, green: 0.43, blue: 0.92, alpha: 0.50).cgColor
            : UIColor.clear.cgColor
        panel.layer.shadowColor = UIColor.black.cgColor
        panel.layer.shadowOpacity = ExperimentalFeatureState.isEnabledAtLaunch ? 0.32 : 0
        panel.layer.shadowRadius = ExperimentalFeatureState.isEnabledAtLaunch ? 18 : 0
        panel.layer.shadowOffset = CGSize(width: 0, height: 10)
    }

    @objc private func closeTapped() { onClose?() }
    @objc private func settingsTapped() { onSettings?() }
    @objc private func listTapped() { onChapterList?() }
    @objc private func previousTapped() { onPreviousChapter?() }
    @objc private func nextTapped() { onNextChapter?() }
    @objc private func lockTapped() { onOrientationLock?() }
}

private struct KanzenReaderChapterListView: View {
    let chapters: [Chapter]
    let selectedChapter: Chapter
    let mangaId: Int
    let onSelect: (Chapter) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reversed = false

    private var displayedChapters: [Chapter] {
        reversed ? chapters.reversed() : chapters
    }

    var body: some View {
        List {
            Section {
                ForEach(displayedChapters) { chapter in
                    Button {
                        dismiss()
                        onSelect(chapter)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(chapter.chapterNumber)
                                    .foregroundColor(.primary)
                                    .fontWeight(ChapterIdentityNormalizer.key(for: chapter.chapterNumber) == ChapterIdentityNormalizer.key(for: selectedChapter.chapterNumber) ? .bold : .regular)
                                if let group = chapter.chapterData?.first?.scanlationGroup, !group.isEmpty {
                                    Text(group)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            if mangaId != 0, MangaReadingProgressManager.shared.isChapterRead(mangaId: mangaId, chapterNumber: chapter.chapterNumber) {
                                Text("Read")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("\(chapters.count) Chapters")
                    Spacer()
                    Button {
                        reversed.toggle()
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
            }
        }
        .navigationTitle("Chapters")
        .navigationBarTitleDisplayMode(.inline)
        .kanzenReaderModalStyle()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
    }
}

private struct KanzenReaderSettingsView: View {
    let scopeKey: String?
    let onModeChanged: (KanzenReaderMode) -> Void
    let onSettingsChanged: (_ requiresReload: Bool, _ key: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var modeRaw: String
    @State private var pageOffset: Bool
    @State private var showingUpscaleImporter = false
    @State private var upscaleModelName: String
    @AppStorage("Reader.downsampleImages") private var downsampleImages = true
    @AppStorage("Reader.cropBorders") private var cropBorders = false
    @AppStorage("Reader.disableQuickActions") private var disableQuickActions = false
    @AppStorage("Reader.disableDoubleTap") private var disableDoubleTap = false
    @AppStorage("Reader.liveText") private var liveText = false
    @AppStorage("Reader.hideBarsOnSwipe") private var hideBarsOnSwipe = false
    @AppStorage("Reader.backgroundColor") private var backgroundColor = "black"
    @AppStorage("Reader.orientation") private var orientation = "device"
    @AppStorage("Reader.tapZones") private var tapZones = KanzenTapZonePreset.disabled.rawValue
    @AppStorage("Reader.invertTapZones") private var invertTapZones = false
    @AppStorage("Reader.animatePageTransitions") private var animatePageTransitions = true
    @AppStorage("Reader.upscaleImages") private var upscaleImages = false
    @AppStorage("Reader.upscaleMaxHeight") private var upscaleMaxHeight = 2000
    @AppStorage("Reader.pagesToPreload") private var pagesToPreload = 3
    @AppStorage("Reader.pagedPageLayout") private var pagedLayout = "single"
    @AppStorage("Reader.splitWideImages") private var splitWideImages = false
    @AppStorage("Reader.reverseSplitOrder") private var reverseSplitOrder = false
    @AppStorage("Reader.verticalInfiniteScroll") private var infiniteScroll = true
    @AppStorage("Reader.pillarbox") private var pillarbox = false
    @AppStorage("Reader.pillarboxAmount") private var pillarboxAmount = 15.0
    @AppStorage("Reader.pillarboxOrientation") private var pillarboxOrientation = "both"
    @AppStorage("readerFontSize") private var textFontSize = 16.0
    @AppStorage("readerFontFamily") private var textFontFamily = "-apple-system"
    @AppStorage("readerFontWeight") private var textFontWeight = "normal"
    @AppStorage("readerColorPreset") private var textColorPreset = 0
    @AppStorage("readerTextAlignment") private var textAlignment = "left"
    @AppStorage("readerLineSpacing") private var textLineSpacing = 1.6
    @AppStorage("readerMargin") private var textHorizontalPadding = 4.0

    private var sanitizedPillarboxAmount: Double {
        Self.sanitizedSetting(pillarboxAmount, default: 15, range: 5...95)
    }

    private var sanitizedTextFontSize: Double {
        Self.sanitizedSetting(textFontSize, default: 16, range: 12...32)
    }

    private var sanitizedTextLineSpacing: Double {
        Self.sanitizedSetting(textLineSpacing, default: 1.6, range: 1...3)
    }

    private var sanitizedTextHorizontalPadding: Double {
        Self.sanitizedSetting(textHorizontalPadding, default: 4, range: 0...30)
    }

    private func sanitizedBinding(
        _ value: Binding<Double>,
        default defaultValue: Double,
        range: ClosedRange<Double>
    ) -> Binding<Double> {
        Binding(
            get: { Self.sanitizedSetting(value.wrappedValue, default: defaultValue, range: range) },
            set: { value.wrappedValue = Self.sanitizedSetting($0, default: defaultValue, range: range) }
        )
    }

    private static func sanitizedSetting(
        _ value: Double,
        default defaultValue: Double,
        range: ClosedRange<Double>
    ) -> Double {
        guard value.isFinite else { return defaultValue }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    init(
        scopeKey: String?,
        onModeChanged: @escaping (KanzenReaderMode) -> Void,
        onSettingsChanged: @escaping (_ requiresReload: Bool, _ key: String) -> Void
    ) {
        self.scopeKey = scopeKey
        self.onModeChanged = onModeChanged
        self.onSettingsChanged = onSettingsChanged
        let mode = KanzenReaderMode.currentDefault(scopeKey: scopeKey)
        _modeRaw = State(initialValue: mode.rawValue)
        _pageOffset = State(initialValue: ProfileSettingsStore.active.object(forKey: Self.pageOffsetStorageKey(scopeKey: scopeKey)) as? Bool ?? false)
        _upscaleModelName = State(initialValue: KanzenReaderUpscaleModelStore.storedModelName)
    }

    static func pageOffsetStorageKey(scopeKey: String?) -> String {
        if let scopeKey, !scopeKey.isEmpty {
            return "Reader.pagedPageOffset.\(scopeKey)"
        }
        return "Reader.pagedPageOffset"
    }

    private var modeStorageKey: String {
        KanzenReaderMode.storageKey(scopeKey: scopeKey)
    }

    private var pageOffsetStorageKey: String {
        Self.pageOffsetStorageKey(scopeKey: scopeKey)
    }

    private var liveTextAvailable: Bool {
        if #available(iOS 16.0, *) {
            return true
        }
        return false
    }

    var body: some View {
        Form {
            Section("General") {
                Picker("Reading Mode", selection: Binding(
                    get: { KanzenReaderMode(rawValue: modeRaw) ?? .webtoon },
                    set: {
                        modeRaw = $0.rawValue
                        ProfileSettingsStore.active.set($0.rawValue, forKey: modeStorageKey)
                        onModeChanged($0)
                    }
                )) {
                    ForEach(KanzenReaderMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Toggle("Downsample Images", isOn: $downsampleImages)
                Toggle("Crop Borders", isOn: $cropBorders)
                Toggle("Quick Actions", isOn: Binding(
                    get: { !disableQuickActions },
                    set: { disableQuickActions = !$0 }
                ))
                Toggle("Disable Double Tap Zoom", isOn: $disableDoubleTap)
                Toggle("Live Text", isOn: $liveText)
                    .disabled(!liveTextAvailable)
                Toggle("Hide Bars On Swipe", isOn: $hideBarsOnSwipe)
                Picker("Background", selection: $backgroundColor) {
                    Text("Black").tag("black")
                    Text("White").tag("white")
                    Text("System").tag("system")
                    Text("Auto").tag("auto")
                }
                .pickerStyle(.menu)
                Picker("Orientation", selection: $orientation) {
                    Text("Device").tag("device")
                    Text("Portrait").tag("portrait")
                    Text("Landscape").tag("landscape")
                    Text("All").tag("all")
                }
                .pickerStyle(.menu)
            }
            .eclipseExperimentalSettingsRows()

            Section("Tap Zones") {
                Picker("Preset", selection: $tapZones) {
                    ForEach(KanzenTapZonePreset.allCases) { preset in
                        Text(preset.title).tag(preset.rawValue)
                    }
                }
                .pickerStyle(.menu)
                Toggle("Invert Zones", isOn: $invertTapZones)
                Toggle("Animate Page Turns", isOn: $animatePageTransitions)
            }
            .eclipseExperimentalSettingsRows()

            Section("Upscaling") {
                Toggle("Upscale Images", isOn: $upscaleImages)
                    .disabled(downsampleImages || upscaleModelName == "None")
                Stepper("Max Height: \(upscaleMaxHeight) px", value: $upscaleMaxHeight, in: 800...6000, step: 100)
                    .disabled(!upscaleImages || downsampleImages)
                Button {
                    showingUpscaleImporter = true
                } label: {
                    HStack {
                        Text("Import Core ML Model")
                        Spacer()
                        Text(upscaleModelName)
                            .foregroundColor(.secondary)
                    }
                }
                if upscaleModelName != "None" {
                    Button(role: .destructive) {
                        KanzenReaderUpscaleModelStore.clearModel()
                        upscaleModelName = KanzenReaderUpscaleModelStore.storedModelName
                        upscaleImages = false
                        onSettingsChanged(true, "Reader.upscaleModel")
                    } label: {
                        Text("Remove Imported Model")
                    }
                }
            }
            .eclipseExperimentalSettingsRows()

            Section("Paged") {
                Stepper("Pages To Preload: \(pagesToPreload)", value: $pagesToPreload, in: 1...10)
                Picker("Page Layout", selection: $pagedLayout) {
                    Text("Single").tag("single")
                    Text("Double").tag("double")
                    Text("Auto").tag("auto")
                }
                .pickerStyle(.menu)
                Toggle("Page Offset", isOn: $pageOffset)
                Toggle("Split Wide Images", isOn: $splitWideImages)
                Toggle("Reverse Split Order", isOn: $reverseSplitOrder)
                    .disabled(!splitWideImages)
            }
            .eclipseExperimentalSettingsRows()

            Section("Webtoon") {
                Toggle("Infinite Vertical Scroll", isOn: $infiniteScroll)
                Toggle("Pillarbox", isOn: $pillarbox)
                Stepper(
                    "Pillarbox Amount: \(Int(sanitizedPillarboxAmount))%",
                    value: sanitizedBinding($pillarboxAmount, default: 15, range: 5...95),
                    in: 5...95,
                    step: 5
                )
                    .disabled(!pillarbox)
                Picker("Pillarbox In", selection: $pillarboxOrientation) {
                    Text("Both").tag("both")
                    Text("Portrait").tag("portrait")
                    Text("Landscape").tag("landscape")
                }
                .pickerStyle(.menu)
                .disabled(!pillarbox)
            }
            .eclipseExperimentalSettingsRows()

            Section("Text") {
                Picker("Font", selection: $textFontFamily) {
                    Text("System").tag("-apple-system")
                    Text("Serif").tag("Georgia")
                    Text("Mono").tag("Menlo")
                    Text("Rounded").tag("ui-rounded")
                }
                .pickerStyle(.menu)
                Picker("Weight", selection: $textFontWeight) {
                    Text("Regular").tag("normal")
                    Text("Medium").tag("500")
                    Text("Bold").tag("700")
                }
                .pickerStyle(.menu)
                Picker("Theme", selection: $textColorPreset) {
                    Text("Light").tag(0)
                    Text("Sepia").tag(1)
                    Text("Gray").tag(2)
                    Text("Dark").tag(3)
                    Text("Black").tag(4)
                }
                .pickerStyle(.menu)
                Picker("Alignment", selection: $textAlignment) {
                    Text("Left").tag("left")
                    Text("Center").tag("center")
                    Text("Right").tag("right")
                    Text("Justify").tag("justify")
                }
                .pickerStyle(.menu)
                Stepper(
                    "Font Size: \(Int(sanitizedTextFontSize))",
                    value: sanitizedBinding($textFontSize, default: 16, range: 12...32),
                    in: 12...32,
                    step: 1
                )
                Stepper(
                    "Line Spacing: \(String(format: "%.1f", sanitizedTextLineSpacing))",
                    value: sanitizedBinding($textLineSpacing, default: 1.6, range: 1...3),
                    in: 1...3,
                    step: 0.1
                )
                Stepper(
                    "Margin: \(Int(sanitizedTextHorizontalPadding))",
                    value: sanitizedBinding($textHorizontalPadding, default: 4, range: 0...30),
                    in: 0...30,
                    step: 1
                )
            }
            .eclipseExperimentalSettingsRows()
        }
        .navigationTitle("Reader Settings")
        .navigationBarTitleDisplayMode(.inline)
        .kanzenReaderModalStyle()
        .fileImporter(isPresented: $showingUpscaleImporter, allowedContentTypes: [.data]) { result in
            guard case .success(let url) = result else { return }
            do {
                try KanzenReaderUpscaleModelStore.importModel(from: url)
                upscaleModelName = KanzenReaderUpscaleModelStore.storedModelName
                onSettingsChanged(true, "Reader.upscaleModel")
            } catch {
                upscaleModelName = KanzenReaderUpscaleModelStore.storedModelName
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .onChange(of: downsampleImages) { _ in
            if downsampleImages, upscaleImages {
                upscaleImages = false
            }
            onSettingsChanged(true, "Reader.downsampleImages")
        }
        .onChange(of: cropBorders) { _ in onSettingsChanged(true, "Reader.cropBorders") }
        .onChange(of: disableQuickActions) { _ in onSettingsChanged(false, "Reader.disableQuickActions") }
        .onChange(of: disableDoubleTap) { _ in onSettingsChanged(false, "Reader.disableDoubleTap") }
        .onChange(of: liveText) { _ in onSettingsChanged(false, "Reader.liveText") }
        .onChange(of: hideBarsOnSwipe) { _ in onSettingsChanged(false, "Reader.hideBarsOnSwipe") }
        .onChange(of: backgroundColor) { _ in onSettingsChanged(false, "Reader.backgroundColor") }
        .onChange(of: orientation) { _ in onSettingsChanged(false, "Reader.orientation") }
        .onChange(of: tapZones) { _ in onSettingsChanged(false, "Reader.tapZones") }
        .onChange(of: invertTapZones) { _ in onSettingsChanged(false, "Reader.invertTapZones") }
        .onChange(of: animatePageTransitions) { _ in onSettingsChanged(false, "Reader.animatePageTransitions") }
        .onChange(of: upscaleImages) { _ in onSettingsChanged(true, "Reader.upscaleImages") }
        .onChange(of: upscaleMaxHeight) { _ in onSettingsChanged(true, "Reader.upscaleMaxHeight") }
        .onChange(of: pagesToPreload) { _ in onSettingsChanged(false, "Reader.pagesToPreload") }
        .onChange(of: pagedLayout) { _ in onSettingsChanged(true, "Reader.pagedPageLayout") }
        .onChange(of: pageOffset) { newValue in
            ProfileSettingsStore.active.set(newValue, forKey: pageOffsetStorageKey)
            onSettingsChanged(true, pageOffsetStorageKey)
        }
        .onChange(of: splitWideImages) { _ in onSettingsChanged(true, "Reader.splitWideImages") }
        .onChange(of: reverseSplitOrder) { _ in onSettingsChanged(true, "Reader.reverseSplitOrder") }
        .onChange(of: infiniteScroll) { _ in onSettingsChanged(false, "Reader.verticalInfiniteScroll") }
        .onChange(of: pillarbox) { _ in onSettingsChanged(true, "Reader.pillarbox") }
        .onChange(of: pillarboxAmount) { _ in onSettingsChanged(true, "Reader.pillarboxAmount") }
        .onChange(of: pillarboxOrientation) { _ in onSettingsChanged(true, "Reader.pillarboxOrientation") }
        .onChange(of: textFontFamily) { _ in onSettingsChanged(true, "readerFontFamily") }
        .onChange(of: textFontWeight) { _ in onSettingsChanged(true, "readerFontWeight") }
        .onChange(of: textColorPreset) { _ in onSettingsChanged(true, "readerColorPreset") }
        .onChange(of: textAlignment) { _ in onSettingsChanged(true, "readerTextAlignment") }
        .onChange(of: textFontSize) { _ in onSettingsChanged(true, "readerFontSize") }
        .onChange(of: textLineSpacing) { _ in onSettingsChanged(true, "readerLineSpacing") }
        .onChange(of: textHorizontalPadding) { _ in onSettingsChanged(true, "readerMargin") }
        .onAppear {
            pillarboxAmount = sanitizedPillarboxAmount
            textFontSize = sanitizedTextFontSize
            textLineSpacing = sanitizedTextLineSpacing
            textHorizontalPadding = sanitizedTextHorizontalPadding
        }
    }
}

private extension View {
    @ViewBuilder
    func kanzenReaderModalStyle() -> some View {
        if ExperimentalFeatureState.isEnabledAtLaunch {
            self.eclipseSettingsStyle()
        } else {
            self
        }
    }
}
#endif
