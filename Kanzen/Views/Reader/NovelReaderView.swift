import SwiftUI

#if !os(tvOS)
import WebKit

enum ReaderExtensionOfflineNovelHTML {
    /// Reader Extension novel downloads are persisted as inert plain text.
    /// Encode that text once before placing it in the reader's HTML body so
    /// downloaded text can never be reparsed as source-provided markup.
    static func bodyContent(for downloadedText: String, route: MangaContentRoute) -> String {
        guard case .readerExtension = route else { return downloadedText }
        return downloadedText
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

struct NovelReaderView: View {
    let kanzen: KanzenEngine
    let chapters: [Chapter]
    let initialChapter: Chapter
    let mangaId: Int
    let mangaTitle: String
    let mangaCoverURL: String
    let mangaRoute: MangaContentRoute?
    let mangaFormat: String?
    let totalChapters: Int?
    let latestChapterNumbers: [String]?

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var progressManager = MangaReadingProgressManager.shared

    @State private var progressOwnerProfileID: UUID

    private var ownerSettings: UserDefaults {
        ProfileSettingsStore.shared.store(for: progressOwnerProfileID)
    }

    @State private var currentChapter: Chapter
    @State private var htmlContent: String = ""
    @State private var isLoading: Bool = true
    @State private var loadError: String?

    @State private var isHeaderVisible: Bool = true
    @State private var isSettingsExpanded: Bool = false
    @State private var readingProgress: Double = 0.0
    @State private var autoMarkedReadChapters: Set<String> = []
    @State private var windowSafeAreaInsets: UIEdgeInsets = .zero
    @State private var scrollRequest: NovelScrollRequest?

    @State private var readerReadThreshold: Double

    @State private var fontSize: CGFloat
    @State private var selectedFont: String
    @State private var fontWeight: String
    @State private var selectedColorPreset: Int
    @State private var textAlignment: String
    @State private var lineSpacing: CGFloat
    @State private var margin: CGFloat

    @State private var isAutoScrolling: Bool = false
    @State private var autoScrollSpeed: Double = 1.0

    private let fontOptions: [(String, String)] = [
        ("-apple-system", "System"),
        ("Georgia", "Georgia"),
        ("Times New Roman", "Times"),
        ("Helvetica", "Helvetica"),
        ("Charter", "Charter"),
        ("New York", "New York")
    ]

    private let weightOptions: [(String, String)] = [
        ("300", "Light"),
        ("normal", "Regular"),
        ("600", "Semibold"),
        ("bold", "Bold")
    ]

    private let alignmentOptions: [(String, String, String)] = [
        ("left", "Left", "text.alignleft"),
        ("center", "Center", "text.aligncenter"),
        ("right", "Right", "text.alignright"),
        ("justify", "Justify", "text.justify")
    ]

    private let colorPresets: [(name: String, background: String, text: String)] = [
        (name: "Pure", background: "#ffffff", text: "#000000"),
        (name: "Warm", background: "#f9f1e4", text: "#4f321c"),
        (name: "Slate", background: "#49494d", text: "#d7d7d8"),
        (name: "Off-Black", background: "#121212", text: "#EAEAEA"),
        (name: "Dark", background: "#000000", text: "#ffffff")
    ]

    private var currentBGColor: Color {
        Color(hex: colorPresets[selectedColorPreset].background)
    }

    private var currentTextColor: Color {
        Color(hex: colorPresets[selectedColorPreset].text)
    }

    private var usesIsolatedReaderExtensionDocument: Bool {
        guard let mangaRoute else { return false }
        if case .readerExtension = mangaRoute { return true }
        return false
    }

    init(kanzen: KanzenEngine, chapters: [Chapter], initialChapter: Chapter, mangaId: Int, mangaTitle: String, mangaCoverURL: String, mangaRoute: MangaContentRoute? = nil, mangaFormat: String? = nil, totalChapters: Int? = nil, latestChapterNumbers: [String]? = nil) {
        self.kanzen = kanzen
        self.chapters = chapters
        self.initialChapter = initialChapter
        self.mangaId = mangaId
        self.mangaTitle = mangaTitle
        self.mangaCoverURL = mangaCoverURL
        self.mangaRoute = mangaRoute
        self.mangaFormat = mangaFormat
        self.totalChapters = totalChapters
        self.latestChapterNumbers = latestChapterNumbers

        _currentChapter = State(initialValue: initialChapter)

        let owner = ProfileManager.shared.activeProfileID
        _progressOwnerProfileID = State(initialValue: owner)

        let defaults = ProfileSettingsStore.shared.store(for: owner)
        let storedThreshold = defaults.object(forKey: "readerReadThresholdPercent") as? Double ?? 80
        let readThreshold = storedThreshold.isFinite ? min(max(storedThreshold, 50), 100) : 80
        let fontSize = defaults.novelCGFloat(forKey: "readerFontSize", default: 16, range: 12...32)
        let lineSpacing = defaults.novelCGFloat(forKey: "readerLineSpacing", default: 1.6, range: 1...3)
        let margin = defaults.novelCGFloat(forKey: "readerMargin", default: 4, range: 0...30)
        defaults.set(readThreshold, forKey: "readerReadThresholdPercent")
        defaults.setNovelCGFloat(fontSize, forKey: "readerFontSize")
        defaults.setNovelCGFloat(lineSpacing, forKey: "readerLineSpacing")
        defaults.setNovelCGFloat(margin, forKey: "readerMargin")
        _readerReadThreshold = State(initialValue: readThreshold / 100)
        _fontSize = State(initialValue: fontSize)
        _selectedFont = State(initialValue: defaults.string(forKey: "readerFontFamily") ?? "-apple-system")
        _fontWeight = State(initialValue: defaults.string(forKey: "readerFontWeight") ?? "normal")
        _selectedColorPreset = State(initialValue: defaults.integer(forKey: "readerColorPreset"))
        _textAlignment = State(initialValue: defaults.string(forKey: "readerTextAlignment") ?? "left")
        _lineSpacing = State(initialValue: lineSpacing)
        _margin = State(initialValue: margin)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            currentBGColor.ignoresSafeArea()

            if isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: currentTextColor))
            } else if let error = loadError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundColor(.orange)
                    Text("Error loading chapter")
                        .font(.headline)
                        .foregroundColor(currentTextColor)
                    Text(error)
                        .font(.subheadline)
                        .foregroundColor(currentTextColor.opacity(0.7))
                }
            } else {
                ZStack {

                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.4)) {
                                isHeaderVisible.toggle()
                                if !isHeaderVisible { isSettingsExpanded = false }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    NovelHTMLView(
                        htmlContent: htmlContent,
                        fontSize: fontSize,
                        fontFamily: selectedFont,
                        fontWeight: fontWeight,
                        textAlignment: textAlignment,
                        lineSpacing: lineSpacing,
                        margin: margin,
                        isAutoScrolling: $isAutoScrolling,
                        autoScrollSpeed: autoScrollSpeed,
                        colorPreset: colorPresets[selectedColorPreset],
                        chapterKey: currentChapter.id.uuidString,
                        settingsStore: ownerSettings,
                        isolatesReaderExtensionHTML: usesIsolatedReaderExtensionDocument,
                        scrollRequest: scrollRequest,
                        onProgressChanged: { progress in
                            self.readingProgress = progress
                            if progress >= readerReadThreshold {
                                self.markCurrentChapterReadIfNeeded()
                            }
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal)
                    .simultaneousGesture(TapGesture().onEnded {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            isHeaderVisible.toggle()
                            if !isHeaderVisible { isSettingsExpanded = false }
                        }
                    })
                }
            }

            headerView
                .opacity(isHeaderVisible ? 1 : 0)
                .offset(y: isHeaderVisible ? 0 : -100)
                .allowsHitTesting(isHeaderVisible)
                .animation(.easeInOut(duration: 0.4), value: isHeaderVisible)
                .zIndex(1)

            if isHeaderVisible {
                footerView
                    .transition(.move(edge: .bottom))
                    .zIndex(2)
            }
        }
        .navigationBarHidden(true)
        .navigationBarBackButtonHidden(true)
        .ignoresSafeArea()
        .background {
            NovelReaderWindowMetricsReader { insets in
                if windowSafeAreaInsets != insets {
                    windowSafeAreaInsets = insets
                }
            }
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
        .onAppear {
            loadChapterContent()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation(.easeInOut(duration: 0.4)) {
                    isHeaderVisible = false
                }
            }
        }
    }

    private func loadChapterContent() {
        isLoading = true
        loadError = nil
        htmlContent = ""

        ReaderLogger.shared.log("NovelReader: chapter load requested", type: "ReaderDebug")
        ReaderLogger.shared.log("NovelReader: chapterData count=\(currentChapter.chapterData?.count ?? 0)", type: "ReaderDebug")

        if let mangaRoute,
           let downloadedText = ReaderDownloadManager.shared.text(for: mangaRoute, chapterNumber: currentChapter.chapterNumber) {
            ReaderLogger.shared.log("NovelReader: loaded downloaded text", type: "ReaderDownload")
            htmlContent = ReaderExtensionOfflineNovelHTML.bodyContent(
                for: downloadedText,
                route: mangaRoute
            )
            isLoading = false
            return
        }

        guard let data = currentChapter.chapterData?.first else {
            ReaderLogger.shared.log("NovelReader: chapterData is nil or empty", type: "Error")
            loadError = "No chapter data available"
            isLoading = false
            return
        }

        ReaderLogger.shared.log("NovelReader: chapterData.params type=\(type(of: data.params as Any))", type: "ReaderDebug")
        ReaderLogger.shared.log("NovelReader: chapter metadata available", type: "ReaderDebug")

        guard let params = data.params else {
            ReaderLogger.shared.log("NovelReader: params is nil", type: "Error")
            loadError = "No chapter data available"
            isLoading = false
            return
        }

        if params is ReaderDownloadedChapterPayload {
            ReaderLogger.shared.log("NovelReader: downloaded text files missing", type: "ReaderDownload")
            loadError = "Downloaded chapter files are missing."
            isLoading = false
            return
        }

        if let payload = params as? ReaderExtensionChapterPayload {
            let owner = progressOwnerProfileID
            Task { @MainActor in
                do {
                    let provider = try ReaderExtensionManager.shared.provider(for: payload.sourceID)
                    let sanitizedHTML = try await provider.chapterHTML(
                        chapterKey: payload.chapter.key,
                        chapterTitle: payload.chapter.title
                    )
                    guard ProfileManager.shared.isStillActive(owner) else { return }
                    htmlContent = sanitizedHTML
                    isLoading = false
                    ReaderLogger.shared.log(
                        "NovelReader: Reader Extension chapter loaded length=\(sanitizedHTML.count)",
                        type: "ReaderExtensions"
                    )
                } catch {
                    guard ProfileManager.shared.isStillActive(owner) else { return }
                    if case ReaderExtensionError.domainConsentRequired(let host) = error {
                        loadError = "This source needs permission to contact \(host). Review its missing domain approvals in Reader Sources."
                    } else {
                        loadError = error.localizedDescription
                    }
                    isLoading = false
                    ReaderLogger.shared.log(
                        "NovelReader: Reader Extension chapter failed: \(error.localizedDescription)",
                        type: "ReaderExtensions"
                    )
                }
            }
            return
        }

        ReaderLogger.shared.log("NovelReader: calling extractText", type: "ReaderDebug")
        kanzen.extractText(params: params) { result in
            DispatchQueue.main.async {
                if let content = result, !content.isEmpty, content != "undefined", content.count > 20 {
                    ReaderLogger.shared.log("NovelReader: extractText success, length=\(content.count)", type: "ReaderDebug")
                    self.htmlContent = content
                    self.isLoading = false
                } else {
                    ReaderLogger.shared.log("NovelReader: extractText failed or returned empty", type: "Error")
                    self.loadError = "Failed to extract text content"
                    self.isLoading = false
                }
            }
        }
    }

    private func goToNextChapter() {
        guard let idx = chapters.firstIndex(where: { $0.id == currentChapter.id }),
              idx + 1 < chapters.count else { return }
        markCurrentChapterRead()
        currentChapter = chapters[idx + 1]
        readingProgress = 0
        loadChapterContent()
    }

    private func goToPreviousChapter() {
        guard let idx = chapters.firstIndex(where: { $0.id == currentChapter.id }),
              idx > 0 else { return }
        currentChapter = chapters[idx - 1]
        readingProgress = 0
        loadChapterContent()
    }

    private func markCurrentChapterRead() {
        progressManager.markChapterRead(
            mangaId: mangaId,
            chapterNumber: currentChapter.chapterNumber,
            mangaTitle: mangaTitle,
            coverURL: mangaCoverURL,
            format: mangaFormat,
            totalChapters: totalChapters,
            latestChapterNumbers: latestChapterNumbers,
            route: mangaRoute,
            forProfile: progressOwnerProfileID
        )
    }

    private func markCurrentChapterReadIfNeeded() {
        guard !autoMarkedReadChapters.contains(currentChapter.chapterNumber) else { return }
        autoMarkedReadChapters.insert(currentChapter.chapterNumber)
        markCurrentChapterRead()
    }

    private var headerView: some View {
        VStack {
            HStack {
                Button {
                    if readingProgress >= readerReadThreshold { markCurrentChapterReadIfNeeded() }
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(currentTextColor)
                        .padding(12)
                        .background(currentBGColor.opacity(0.8))
                        .clipShape(Circle())
                        .frame(width: 44, height: 44)
                }
                .padding(.leading)

                Text(currentChapter.chapterNumber)
                    .font(.headline)
                    .foregroundColor(currentTextColor)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                Button { goToPreviousChapter() } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(currentTextColor)
                        .padding(12)
                        .background(currentBGColor.opacity(0.8))
                        .clipShape(Circle())
                        .frame(width: 44, height: 44)
                }
                .disabled(chapters.firstIndex(where: { $0.id == currentChapter.id }) == 0)

                Button { goToNextChapter() } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(currentTextColor)
                        .padding(12)
                        .background(currentBGColor.opacity(0.8))
                        .clipShape(Circle())
                        .frame(width: 44, height: 44)
                }
                .disabled({
                    guard let idx = chapters.firstIndex(where: { $0.id == currentChapter.id }) else { return true }
                    return idx + 1 >= chapters.count
                }())

                Button {
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                        isSettingsExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(currentTextColor)
                        .padding(12)
                        .background(currentBGColor.opacity(0.8))
                        .clipShape(Circle())
                        .frame(width: 44, height: 44)
                        .rotationEffect(.degrees(isSettingsExpanded ? 90 : 0))
                }
                .padding(.trailing)
            }
            .padding(.top, safeAreaTop)
            .padding(.bottom, 10)
            .background(.ultraThinMaterial)
            .overlay(alignment: .topTrailing) {
                if isSettingsExpanded {
                    settingsPanel
                        .padding(.top, safeAreaTop + 60)
                        .padding(.trailing, 8)
                        .transition(.opacity)
                }
            }

            Spacer()
        }
        .ignoresSafeArea()
    }

    private var footerView: some View {
        VStack {
            Spacer()

            VStack(spacing: 0) {

                HStack {
                    Spacer()
                    Button {
                        isAutoScrolling.toggle()
                    } label: {
                        Image(systemName: isAutoScrolling ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(isAutoScrolling ? .red : currentTextColor)
                            .padding(12)
                            .background(currentBGColor.opacity(0.8))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(currentTextColor.opacity(0.2))
                            .frame(height: 4)

                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(width: max(0, min(CGFloat(readingProgress) * geo.size.width, geo.size.width)), height: 4)

                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 16, height: 16)
                            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                            .offset(x: max(0, min(CGFloat(readingProgress) * geo.size.width, geo.size.width)) - 8)
                    }
                    .cornerRadius(2)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let pct = min(max(value.location.x / geo.size.width, 0), 1)
                                scrollToPosition(pct)
                            }
                    )
                }
                .frame(height: 24)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, safeAreaBottom + 16)
            }
            .background(.ultraThinMaterial)
            .opacity(isHeaderVisible ? 1 : 0)
            .offset(y: isHeaderVisible ? 0 : 100)
            .animation(.easeInOut(duration: 0.4), value: isHeaderVisible)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var settingsPanel: some View {
        VStack(spacing: 8) {

            Menu {
                VStack {
                    Text("Font Size: \(Int(fontSize))pt")
                    Slider(value: Binding(get: { fontSize }, set: { fontSize = $0; ProfileSettingsStore.active.setNovelCGFloat($0, forKey: "readerFontSize") }), in: 12...32, step: 1)
                }
                .padding()
            } label: { settingsIcon("textformat.size") }

            Menu {
                ForEach(fontOptions, id: \.0) { font in
                    Button {
                        selectedFont = font.0
                        ProfileSettingsStore.active.set(font.0, forKey: "readerFontFamily")
                    } label: {
                        HStack {
                            Text(font.1)
                            Spacer()
                            if selectedFont == font.0 { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: { settingsIcon("textformat.characters") }

            Menu {
                ForEach(weightOptions, id: \.0) { weight in
                    Button {
                        fontWeight = weight.0
                        ProfileSettingsStore.active.set(weight.0, forKey: "readerFontWeight")
                    } label: {
                        HStack {
                            Text(weight.1)
                            Spacer()
                            if fontWeight == weight.0 { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: { settingsIcon("bold") }

            Menu {
                ForEach(0..<colorPresets.count, id: \.self) { idx in
                    Button {
                        selectedColorPreset = idx
                        ProfileSettingsStore.active.set(idx, forKey: "readerColorPreset")
                    } label: {
                        HStack {
                            Text(colorPresets[idx].name)
                            Spacer()
                            if selectedColorPreset == idx { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: { settingsIcon("paintpalette") }

            Menu {
                VStack {
                    Text("Line Spacing: \(String(format: "%.1f", lineSpacing))")
                    Slider(value: Binding(get: { lineSpacing }, set: { lineSpacing = $0; ProfileSettingsStore.active.setNovelCGFloat($0, forKey: "readerLineSpacing") }), in: 1.0...3.0, step: 0.1)
                }
                .padding()
            } label: { settingsIcon("arrow.left.and.right.text.vertical") }

            Menu {
                VStack {
                    Text("Margin: \(Int(margin))px")
                    Slider(value: Binding(get: { margin }, set: { margin = $0; ProfileSettingsStore.active.setNovelCGFloat($0, forKey: "readerMargin") }), in: 0...30, step: 1)
                }
                .padding()
            } label: { settingsIcon("rectangle.inset.filled") }

            Menu {
                ForEach(alignmentOptions, id: \.0) { alignment in
                    Button {
                        textAlignment = alignment.0
                        ProfileSettingsStore.active.set(alignment.0, forKey: "readerTextAlignment")
                    } label: {
                        HStack {
                            Image(systemName: alignment.2)
                            Text(alignment.1)
                            Spacer()
                            if textAlignment == alignment.0 { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: { settingsIcon("text.alignleft") }
        }
        .frame(width: 60, alignment: .trailing)
    }

    private func settingsIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(currentTextColor)
            .padding(10)
            .background(currentBGColor.opacity(0.8))
            .clipShape(Circle())
    }

    private func scrollToPosition(_ percentage: CGFloat) {
        let clamped = min(max(percentage, 0), 1)
        readingProgress = Double(clamped)
        scrollRequest = NovelScrollRequest(percentage: clamped)
    }

    private var safeAreaTop: CGFloat {
        windowSafeAreaInsets.top
    }

    private var safeAreaBottom: CGFloat {
        windowSafeAreaInsets.bottom
    }
}

private struct NovelReaderWindowMetricsReader: UIViewRepresentable {
    let onChange: (UIEdgeInsets) -> Void

    func makeUIView(context: Context) -> NovelReaderWindowMetricsProbeView {
        NovelReaderWindowMetricsProbeView(onChange: onChange)
    }

    func updateUIView(_ uiView: NovelReaderWindowMetricsProbeView, context: Context) {
        uiView.onChange = onChange
        uiView.reportInsetsIfNeeded()
    }
}

private final class NovelReaderWindowMetricsProbeView: UIView {
    var onChange: (UIEdgeInsets) -> Void
    private var lastReportedInsets: UIEdgeInsets?

    init(onChange: @escaping (UIEdgeInsets) -> Void) {
        self.onChange = onChange
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportInsetsIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportInsetsIfNeeded()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        reportInsetsIfNeeded()
    }

    func reportInsetsIfNeeded() {
        let insets = window?.safeAreaInsets ?? .zero
        guard insets != lastReportedInsets else { return }
        lastReportedInsets = insets
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lastReportedInsets == insets else { return }
            self.onChange(insets)
        }
    }
}

private struct NovelScrollRequest: Equatable {
    let id = UUID()
    let percentage: CGFloat
}

private struct NovelHTMLView: UIViewRepresentable {
    let htmlContent: String
    let fontSize: CGFloat
    let fontFamily: String
    let fontWeight: String
    let textAlignment: String
    let lineSpacing: CGFloat
    let margin: CGFloat
    @Binding var isAutoScrolling: Bool
    let autoScrollSpeed: Double
    let colorPreset: (name: String, background: String, text: String)
    let chapterKey: String

    let settingsStore: UserDefaults
    let isolatesReaderExtensionHTML: Bool
    let scrollRequest: NovelScrollRequest?
    var onProgressChanged: ((Double) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stopProgressTracking()
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private static let readerBridgeWorld = WKContentWorld.world(name: "app.eclipse.reader-extension-progress")
        var parent: NovelHTMLView
        var scrollTimer: Timer?
        var progressTimer: Timer?
        weak var webView: WKWebView?

        var lastHTML: String = ""
        var lastFontSize: CGFloat = 0
        var lastFontFamily: String = ""
        var lastFontWeight: String = ""
        var lastAlignment: String = ""
        var lastLineSpacing: CGFloat = 0
        var lastMargin: CGFloat = 0
        var lastPreset: String = ""
        var lastScrollRequestID: UUID?

        init(_ parent: NovelHTMLView) {
            self.parent = parent
        }

        func evaluateReaderScript(
            _ script: String,
            in webView: WKWebView,
            completion: ((Any?, Error?) -> Void)? = nil
        ) {
            if parent.isolatesReaderExtensionHTML {
                webView.evaluateJavaScript(
                    script,
                    in: nil,
                    in: Self.readerBridgeWorld
                ) { result in
                    switch result {
                    case .success(let value): completion?(value, nil)
                    case .failure(let error): completion?(nil, error)
                    }
                }
            } else {
                webView.evaluateJavaScript(script, completionHandler: completion)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {

            let saved = parent.settingsStore.double(forKey: "novelScrollPos_\(parent.chapterKey)")
            if saved > 0.01 {
                let script = "window.scrollTo(0, document.documentElement.scrollHeight * \(saved));"
                evaluateReaderScript(script, in: webView)
            }
            startProgressTracking(webView: webView)
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if message.name == "novelScrollHandler", let wv = self.webView {
                updateProgress(wv)
            }
        }

        func startAutoScroll(_ webView: WKWebView) {
            stopAutoScroll()
            scrollTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
                let amount = self.parent.autoScrollSpeed * 0.5
                self.evaluateReaderScript("window.scrollBy(0, \(amount));", in: webView)
                self.evaluateReaderScript("(window.pageYOffset + window.innerHeight) >= document.body.scrollHeight", in: webView) { result, _ in
                    if let atBottom = result as? Bool, atBottom {
                        DispatchQueue.main.async { self.parent.isAutoScrolling = false }
                    }
                }
            }
        }

        func stopAutoScroll() {
            scrollTimer?.invalidate()
            scrollTimer = nil
        }

        func startProgressTracking(webView: WKWebView) {
            stopProgressTracking()
            self.webView = webView
            updateProgress(webView)

            progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self, weak webView] _ in
                guard let self, let wv = webView, wv.window != nil else {
                    self?.stopProgressTracking()
                    return
                }
                self.updateProgress(wv)
            }

            let js = """
            (function() {
                let last = 0;
                function tick() {
                    let now = Date.now();
                    if (now - last >= 16) {
                        window.webkit.messageHandlers.novelScrollHandler.postMessage('s');
                        last = now;
                    }
                    requestAnimationFrame(tick);
                }
                requestAnimationFrame(tick);
            })();
            """
            let script = parent.isolatesReaderExtensionHTML
                ? WKUserScript(
                    source: js,
                    injectionTime: .atDocumentEnd,
                    forMainFrameOnly: true,
                    in: Self.readerBridgeWorld
                )
                : WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
            webView.configuration.userContentController.addUserScript(script)
            if parent.isolatesReaderExtensionHTML {
                webView.configuration.userContentController.add(
                    self,
                    contentWorld: Self.readerBridgeWorld,
                    name: "novelScrollHandler"
                )
            } else {
                webView.configuration.userContentController.add(self, name: "novelScrollHandler")
            }
        }

        func stopProgressTracking() {
            progressTimer?.invalidate()
            progressTimer = nil
            if let wv = webView {
                wv.configuration.userContentController.removeAllUserScripts()
                if parent.isolatesReaderExtensionHTML {
                    wv.configuration.userContentController.removeScriptMessageHandler(
                        forName: "novelScrollHandler",
                        contentWorld: Self.readerBridgeWorld
                    )
                } else {
                    wv.configuration.userContentController.removeScriptMessageHandler(forName: "novelScrollHandler")
                }
            }
        }

        func updateProgress(_ webView: WKWebView) {
            guard webView.window != nil else { stopProgressTracking(); return }
            let js = """
            (function() {
                var sh = document.documentElement.scrollHeight;
                var st = window.pageYOffset || document.documentElement.scrollTop;
                var ch = document.documentElement.clientHeight;
                var raw = sh > 0 ? (st + ch) / sh : 0;
                var progress = raw > 0.95 ? 1.0 : raw;
                return { progress: progress, scrollPos: st / sh };
            })();
            """
            evaluateReaderScript(js, in: webView) { [weak self] result, _ in
                guard let self, let dict = result as? [String: Any],
                      let progress = dict["progress"] as? Double else { return }
                if let scrollPos = dict["scrollPos"] as? Double {
                    self.parent.settingsStore.set(scrollPos, forKey: "novelScrollPos_\(self.parent.chapterKey)")
                }
                self.parent.onProgressChanged?(progress)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard parent.isolatesReaderExtensionHTML else {
                decisionHandler(.allow)
                return
            }
            let url = navigationAction.request.url
            let isInitialDocument = navigationAction.navigationType == .other
                && (url == nil || url?.scheme?.lowercased() == "about")
            decisionHandler(isInitialDocument ? .allow : .cancel)
        }
    }

    func makeUIView(context: Context) -> WKWebView {
        let wv: WKWebView
        if isolatesReaderExtensionHTML {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            wv = WKWebView(frame: .zero, configuration: configuration)
        } else {
            wv = WKWebView()
        }
        wv.backgroundColor = .clear
        wv.isOpaque = false
        wv.scrollView.backgroundColor = .clear
        wv.scrollView.showsHorizontalScrollIndicator = false
        wv.scrollView.bounces = false
        wv.scrollView.alwaysBounceHorizontal = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.navigationDelegate = context.coordinator
        context.coordinator.webView = wv
        return wv
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let c = context.coordinator

        if let scrollRequest, scrollRequest.id != c.lastScrollRequestID {
            c.lastScrollRequestID = scrollRequest.id
            let percentage = min(max(scrollRequest.percentage, 0), 1)
            let script = """
            (function() {
                var h = document.documentElement.scrollHeight - document.documentElement.clientHeight;
                window.scrollTo({ top: h * \(percentage), behavior: 'auto' });
            })();
            """
            c.evaluateReaderScript(script, in: webView)
        }

        if isAutoScrolling {
            c.startAutoScroll(webView)
        } else {
            c.stopAutoScroll()
        }

        if webView.window != nil {
            c.startProgressTracking(webView: webView)
        } else {
            c.stopProgressTracking()
        }

        guard !htmlContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let changed = c.lastHTML != htmlContent || c.lastFontSize != fontSize ||
                      c.lastFontFamily != fontFamily || c.lastFontWeight != fontWeight ||
                      c.lastAlignment != textAlignment || c.lastLineSpacing != lineSpacing ||
                      c.lastMargin != margin || c.lastPreset != colorPreset.name

        guard changed else { return }

        let contentSecurityPolicy = isolatesReaderExtensionHTML
            ? "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src 'none'; style-src 'unsafe-inline'; font-src 'none'; media-src 'none'; frame-src 'none'; form-action 'none'; base-uri 'none'; connect-src 'none'\">"
            : ""
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
            \(contentSecurityPolicy)
            <style>
                html, body {
                    font-family: \(fontFamily), system-ui;
                    font-size: \(fontSize)px;
                    font-weight: \(fontWeight);
                    line-height: \(lineSpacing);
                    text-align: \(textAlignment);
                    padding: \(margin)px;
                    padding-top: calc(\(margin)px + 20px);
                    margin: 0;
                    color: \(colorPreset.text);
                    background-color: \(colorPreset.background);
                    transition: all 0.3s ease;
                    overflow-x: hidden;
                    width: 100%;
                    max-width: 100%;
                    word-wrap: break-word;
                    -webkit-user-select: text;
                    -webkit-touch-callout: none;
                    -webkit-tap-highlight-color: transparent;
                }
                body { box-sizing: border-box; }
                p, div, span, h1, h2, h3, h4, h5, h6 {
                    font-size: inherit; font-family: inherit; font-weight: inherit;
                    line-height: inherit; text-align: inherit; color: inherit;
                    max-width: 100%; word-wrap: break-word; overflow-wrap: break-word;
                }
                * { max-width: 100%; box-sizing: border-box; }
            </style>
        </head>
        <body>\(htmlContent)</body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)

        let savedPos = settingsStore.double(forKey: "novelScrollPos_\(chapterKey)")
        if savedPos > 0.01 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                let js = "window.scrollTo(0, document.documentElement.scrollHeight * \(savedPos));"
                c.evaluateReaderScript(js, in: webView)
            }
        }

        c.lastHTML = htmlContent
        c.lastFontSize = fontSize
        c.lastFontFamily = fontFamily
        c.lastFontWeight = fontWeight
        c.lastAlignment = textAlignment
        c.lastLineSpacing = lineSpacing
        c.lastMargin = margin
        c.lastPreset = colorPreset.name
    }
}

private extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        switch hex.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255
            g = Double((int >> 8) & 0xFF) / 255
            b = Double(int & 0xFF) / 255
        case 8:
            r = Double((int >> 24) & 0xFF) / 255
            g = Double((int >> 16) & 0xFF) / 255
            b = Double((int >> 8) & 0xFF) / 255
        default:
            r = 0; g = 0; b = 0
        }
        self.init(red: r, green: g, blue: b)
    }
}

private extension UserDefaults {
    func novelCGFloat(
        forKey key: String,
        default defaultValue: CGFloat,
        range: ClosedRange<CGFloat>
    ) -> CGFloat {
        guard let value = (object(forKey: key) as? NSNumber)?.doubleValue,
              value.isFinite else { return defaultValue }
        return min(max(CGFloat(value), range.lowerBound), range.upperBound)
    }

    func setNovelCGFloat(_ value: CGFloat, forKey key: String) {
        set(NSNumber(value: Double(value)), forKey: key)
    }
}

#endif
