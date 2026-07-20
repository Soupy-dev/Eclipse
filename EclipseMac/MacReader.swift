import AppKit
import Combine
import Foundation
import PDFKit
import SwiftUI
import WebKit

enum MacReaderDocument {
    case images(title: String, urls: [URL])
    case remotePages(title: String, pages: [MacReaderPagePayload])
    case pdf(title: String, url: URL)
    case html(title: String, url: URL)

    var title: String {
        switch self {
        case .images(let title, _), .remotePages(let title, _), .pdf(let title, _), .html(let title, _): title
        }
    }
}

struct MacReaderTrackingContext: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let title: String
    let chapterNumber: Double
    let totalChapters: Int?

    init?(title: String, chapterNumber: Double, totalChapters: Int?) {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty,
              normalizedTitle.count <= 512,
              chapterNumber.isFinite,
              chapterNumber >= 0 else { return nil }

        schemaVersion = Self.currentSchemaVersion
        self.title = normalizedTitle
        self.chapterNumber = chapterNumber
        self.totalChapters = totalChapters.flatMap { (1...1_000_000).contains($0) ? $0 : nil }
    }

    var isUsable: Bool {
        schemaVersion == Self.currentSchemaVersion &&
            !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            title.count <= 512 &&
            chapterNumber.isFinite &&
            chapterNumber >= 0 &&
            totalChapters.map { (1...1_000_000).contains($0) } != false
    }
}

@MainActor
final class MacReaderController: ObservableObject {
    static let shared = MacReaderController()

    @Published private(set) var document: MacReaderDocument?
    @Published private(set) var documentIdentity = UUID()
    @Published private(set) var trackingContext: MacReaderTrackingContext?
    @Published var pendingWindowPresentation = false
    @AppStorage("macReaderDirection") var direction = MacReaderDirection.vertical
    @AppStorage("macReaderBackground") var background = MacReaderBackground.black
    @AppStorage("macReaderPageGap") var pageGap = 12.0

    private var didSubmitTrackingProgress = false

    private init() {}

    func openImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "Open in Kanzen"
        panel.prompt = "Read"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder, .image, .pdf, .html]
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        open(urls: panel.urls)
    }

    func open(urls: [URL]) {
        let nextDocument: MacReaderDocument
        if urls.count == 1, let url = urls.first {
            if url.hasDirectoryPath {
                let images = imageURLs(in: url)
                nextDocument = .images(title: url.lastPathComponent, urls: images)
            } else if url.pathExtension.lowercased() == "pdf" {
                nextDocument = .pdf(title: url.deletingPathExtension().lastPathComponent, url: url)
            } else if ["html", "htm"].contains(url.pathExtension.lowercased()) {
                nextDocument = .html(title: url.deletingPathExtension().lastPathComponent, url: url)
            } else {
                nextDocument = .images(title: url.deletingPathExtension().lastPathComponent, urls: [url])
            }
        } else {
            let images = urls.filter(Self.isImage).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            nextDocument = .images(title: "Imported Chapter", urls: images)
        }
        present(nextDocument)
    }

    func open(
        title: String,
        pages: [MacReaderPagePayload],
        trackingContext: MacReaderTrackingContext? = nil
    ) {
        present(
            .remotePages(title: title, pages: pages),
            shouldPresent: !pages.isEmpty,
            trackingContext: trackingContext
        )
    }

    func reportPageReached(index: Int, totalPages: Int, documentIdentity: UUID) {
        guard documentIdentity == self.documentIdentity,
              totalPages > 0,
              (0..<totalPages).contains(index),
              !didSubmitTrackingProgress,
              let trackingContext,
              trackingContext.isUsable else { return }

        let reachedPage = index + 1
        let reachedLastPage = reachedPage == totalPages
        let reachedCompletionThreshold = Double(reachedPage) / Double(totalPages) >= 0.85
        guard reachedLastPage || reachedCompletionThreshold else { return }

        didSubmitTrackingProgress = true
        Task {
            await MacTrackerStore.shared.syncMangaProgress(
                title: trackingContext.title,
                chapterNumber: trackingContext.chapterNumber,
                totalChapters: trackingContext.totalChapters
            )
        }
    }

    private func present(
        _ nextDocument: MacReaderDocument,
        shouldPresent: Bool = true,
        trackingContext: MacReaderTrackingContext? = nil
    ) {
        documentIdentity = UUID()
        self.trackingContext = trackingContext?.isUsable == true ? trackingContext : nil
        didSubmitTrackingProgress = false
        document = nextDocument
        pendingWindowPresentation = shouldPresent
    }

    private func imageURLs(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .nameKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return urls.filter(Self.isImage).sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    private static func isImage(_ url: URL) -> Bool {
        ["jpg", "jpeg", "png", "webp", "gif", "heic", "avif", "tiff", "bmp"].contains(url.pathExtension.lowercased())
    }
}

enum MacReaderDirection: String, CaseIterable, Identifiable {
    case vertical = "Webtoon"
    case leftToRight = "Left to Right"
    case rightToLeft = "Right to Left"
    var id: String { rawValue }
}

enum MacReaderBackground: String, CaseIterable, Identifiable {
    case black = "Black"
    case gray = "Gray"
    case sepia = "Sepia"
    var id: String { rawValue }
    var color: Color {
        switch self {
        case .black: .black
        case .gray: Color(white: 0.12)
        case .sepia: Color(red: 0.16, green: 0.13, blue: 0.1)
        }
    }
}

struct MacReaderView: View {
    @EnvironmentObject private var reader: MacReaderController
    @State private var controlsVisible = true

    var body: some View {
        ZStack {
            reader.background.color.ignoresSafeArea()
            if let document = reader.document {
                content(document, documentIdentity: reader.documentIdentity)
            } else {
                ContentUnavailableView("No Book Open", systemImage: "books.vertical", description: Text("Choose Open Book from Kanzen or drag a folder, image, PDF, or HTML file here."))
            }
        }
        .frame(minWidth: 620, minHeight: 480)
        .toolbar {
            ToolbarItemGroup {
                Picker("Reading Mode", selection: $reader.direction) {
                    ForEach(MacReaderDirection.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 150)
                Button { reader.openImportPanel() } label: { Label("Open", systemImage: "folder") }
            }
        }
        .navigationTitle(reader.document?.title ?? "Reader")
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            loadDroppedFiles(providers)
            return true
        }
    }

    @ViewBuilder
    private func content(_ document: MacReaderDocument, documentIdentity: UUID) -> some View {
        switch document {
        case .images(_, let urls):
            if urls.isEmpty {
                ContentUnavailableView("No Images", systemImage: "photo.badge.exclamationmark", description: Text("The selected folder contains no supported images."))
            } else if reader.direction == .vertical {
                MacWebtoonReader(urls: urls, gap: reader.pageGap)
            } else {
                MacPagedReader(urls: urls, rightToLeft: reader.direction == .rightToLeft, documentIdentity: documentIdentity)
                    .id(documentIdentity)
            }
        case .remotePages(_, let pages):
            if pages.isEmpty {
                ContentUnavailableView("No Pages", systemImage: "photo.badge.exclamationmark", description: Text("The source returned no readable pages."))
            } else if reader.direction == .vertical {
                MacRemoteWebtoonReader(pages: pages, gap: reader.pageGap, documentIdentity: documentIdentity)
            } else {
                MacRemotePagedReader(pages: pages, rightToLeft: reader.direction == .rightToLeft, documentIdentity: documentIdentity)
                    .id(documentIdentity)
            }
        case .pdf(_, let url):
            MacPDFReader(url: url)
        case .html(_, let url):
            MacNovelReader(url: url)
        }
    }

    private func loadDroppedFiles(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { value, _ in
                let url: URL?
                if let data = value as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else { url = value as? URL }
                guard let url else { return }
                Task { @MainActor in reader.open(urls: [url]) }
            }
        }
    }
}

private struct MacRemoteWebtoonReader: View {
    @EnvironmentObject private var reader: MacReaderController
    let pages: [MacReaderPagePayload]
    let gap: Double
    let documentIdentity: UUID
    var body: some View {
        ScrollView {
            LazyVStack(spacing: gap) {
                ForEach(pages.indices, id: \.self) { index in
                    MacRemotePageView(
                        page: pages[index],
                        pageIdentity: .init(documentIdentity: documentIdentity, index: index)
                    )
                        .accessibilityLabel("Page \(index + 1) of \(pages.count)")
                        .onScrollVisibilityChange(threshold: 0.01) { isVisible in
                            guard isVisible else { return }
                            reader.reportPageReached(
                                index: index,
                                totalPages: pages.count,
                                documentIdentity: documentIdentity
                            )
                        }
                }
            }
            .frame(maxWidth: 1100).padding(20).frame(maxWidth: .infinity)
        }
    }
}

private struct MacRemotePagedReader: View {
    @EnvironmentObject private var reader: MacReaderController
    let pages: [MacReaderPagePayload]
    let rightToLeft: Bool
    let documentIdentity: UUID
    @State private var index = 0
    var body: some View {
        ZStack {
            if let page = pages[safe: clampedIndex] {
                MacRemotePageView(
                    page: page,
                    pageIdentity: .init(documentIdentity: documentIdentity, index: clampedIndex)
                )
                .padding(24)
            } else {
                ContentUnavailableView("No Pages", systemImage: "photo.badge.exclamationmark")
            }
            HStack {
                Button { move(rightToLeft ? 1 : -1) } label: { Image(systemName: "chevron.left.circle.fill") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Spacer()
                Text(pages.isEmpty ? "0 / 0" : "\(clampedIndex + 1) / \(pages.count)")
                    .padding(.horizontal, 12).padding(.vertical, 7).background(.ultraThinMaterial, in: Capsule())
                Spacer()
                Button { move(rightToLeft ? -1 : 1) } label: { Image(systemName: "chevron.right.circle.fill") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .buttonStyle(.plain).font(.system(size: 28)).padding(20)
        }
        .onAppear { reportCurrentPage() }
        .onChange(of: index) { _, _ in reportCurrentPage() }
        .onChange(of: documentIdentity) { _, _ in index = 0 }
        .onChange(of: pages.count) { _, _ in clampIndex() }
    }
    private var clampedIndex: Int {
        guard !pages.isEmpty else { return 0 }
        return min(pages.count - 1, max(0, index))
    }
    private func clampIndex() { index = clampedIndex }
    private func reportCurrentPage() {
        guard !pages.isEmpty else { return }
        reader.reportPageReached(
            index: clampedIndex,
            totalPages: pages.count,
            documentIdentity: documentIdentity
        )
    }
    private func move(_ amount: Int) {
        guard !pages.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            index = min(pages.count - 1, max(0, clampedIndex + amount))
        }
    }
}

private struct MacReaderPageIdentity: Hashable {
    let documentIdentity: UUID
    let index: Int
}

private struct MacRemotePageView: View {
    let page: MacReaderPagePayload
    let pageIdentity: MacReaderPageIdentity
    @AppStorage("readerFontSize") private var fontSize = 16.0
    @AppStorage("readerFontFamily") private var fontFamily = "-apple-system"
    @AppStorage("readerFontWeight") private var fontWeight = "normal"
    @AppStorage("readerTextAlignment") private var textAlignment = "left"
    @AppStorage("readerLineSpacing") private var lineSpacing = 1.6
    @AppStorage("readerMargin") private var margin = 4.0
    @State private var image: NSImage?
    @State private var isLoading = true
    @State private var failed = false
    @State private var activePageIdentity: MacReaderPageIdentity?

    var body: some View {
        Group {
            switch page {
            case .text(let text):
                ScrollView {
                    Text(text)
                        .textSelection(.enabled)
                        .font(resolvedFont)
                        .fontWeight(resolvedWeight)
                        .multilineTextAlignment(resolvedAlignment)
                        .lineSpacing(CGFloat(max(0, fontSize * (lineSpacing - 1))))
                        .padding(.horizontal, CGFloat(margin + 28))
                        .padding(.vertical, 36)
                        .frame(maxWidth: 820, alignment: resolvedFrameAlignment)
                }
            case .remote, .data, .file:
                if activePageIdentity != pageIdentity { ProgressView().frame(height: 300) }
                else if let image { Image(nsImage: image).resizable().scaledToFit() }
                else if failed { ContentUnavailableView("Page Failed", systemImage: "photo.badge.exclamationmark") .frame(height: 300) }
                else { ProgressView().frame(height: 300) }
            }
        }
        .task(id: pageIdentity) {
            activePageIdentity = pageIdentity
            image = nil
            failed = false
            isLoading = true
            await load(expectedIdentity: pageIdentity)
        }
    }

    private func load(expectedIdentity: MacReaderPageIdentity) async {
        do {
            let data: Data
            switch page {
            case .remote(let url, let headers):
                var request = URLRequest(url: url, timeoutInterval: 30)
                headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
                let (value, _) = try await MacBoundedContent.httpData(
                    for: request,
                    maximumBytes: MacAidokuContentLimits.pageBytes
                )
                data = value
            case .data(let value):
                guard value.count <= MacAidokuContentLimits.pageBytes else { throw URLError(.dataLengthExceedsMaximum) }
                data = value
            case .file(let url):
                data = try MacBoundedContent.fileData(at: url, maximumBytes: MacAidokuContentLimits.pageBytes)
            case .text:
                guard activePageIdentity == expectedIdentity else { return }
                isLoading = false
                return
            }
            guard !Task.isCancelled, activePageIdentity == expectedIdentity else { return }
            image = NSImage(data: data)
            failed = image == nil
        } catch {
            guard !Task.isCancelled, activePageIdentity == expectedIdentity else { return }
            image = nil
            failed = true
        }
        isLoading = false
    }

    private var resolvedFont: Font {
        switch fontFamily {
        case "Georgia": .custom("Georgia", size: CGFloat(fontSize))
        case "Menlo": .custom("Menlo", size: CGFloat(fontSize))
        case "ui-rounded": .system(size: CGFloat(fontSize), design: .rounded)
        default: .system(size: CGFloat(fontSize))
        }
    }

    private var resolvedWeight: Font.Weight {
        switch fontWeight {
        case "700": .bold
        case "500": .medium
        default: .regular
        }
    }

    private var resolvedAlignment: TextAlignment {
        switch textAlignment {
        case "center": .center
        default: .leading
        }
    }

    private var resolvedFrameAlignment: Alignment {
        textAlignment == "center" ? .top : .topLeading
    }
}

private struct MacWebtoonReader: View {
    let urls: [URL]
    let gap: Double

    var body: some View {
        ScrollView {
            LazyVStack(spacing: gap) {
                ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                    MacReaderImage(url: url)
                        .accessibilityLabel("Page \(index + 1) of \(urls.count)")
                }
            }
            .frame(maxWidth: 1100)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
        }
    }

}

private struct MacPagedReader: View {
    let urls: [URL]
    let rightToLeft: Bool
    let documentIdentity: UUID
    @State private var index = 0

    var body: some View {
        ZStack {
            if let url = urls[safe: clampedIndex] {
                MacReaderImage(url: url)
                    .padding(24)
                    .id(url)
                    .transition(.opacity)
            } else {
                ContentUnavailableView("No Images", systemImage: "photo.badge.exclamationmark")
            }
            HStack {
                Button { move(by: rightToLeft ? 1 : -1) } label: { Image(systemName: "chevron.left.circle.fill") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Spacer()
                Text(urls.isEmpty ? "0 / 0" : "\(clampedIndex + 1) / \(urls.count)")
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                Spacer()
                Button { move(by: rightToLeft ? -1 : 1) } label: { Image(systemName: "chevron.right.circle.fill") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .buttonStyle(.plain)
            .font(.system(size: 28))
            .padding(20)
        }
        .onChange(of: documentIdentity) { _, _ in index = 0 }
        .onChange(of: urls.count) { _, _ in index = clampedIndex }
    }

    private var clampedIndex: Int {
        guard !urls.isEmpty else { return 0 }
        return min(urls.count - 1, max(0, index))
    }

    private func move(by delta: Int) {
        guard !urls.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            index = min(urls.count - 1, max(0, clampedIndex + delta))
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private struct MacReaderImage: View {
    let url: URL
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else if failed {
                ContentUnavailableView("Page Failed", systemImage: "photo.badge.exclamationmark", description: Text(url.lastPathComponent))
                    .frame(height: 300)
            } else {
                ProgressView().frame(height: 300)
            }
        }
        .task(id: url) {
            image = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: url) }.value
            failed = image == nil
        }
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Open With Default App") { NSWorkspace.shared.open(url) }
        }
    }
}

private struct MacPDFReader: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.document = PDFDocument(url: url)
        return view
    }
    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url { nsView.document = PDFDocument(url: url) }
    }
}

private struct MacNovelReader: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var loadedURL: URL?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.loadedURL = url.standardizedFileURL
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return view
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {
        let nextURL = url.standardizedFileURL
        guard context.coordinator.loadedURL != nextURL else { return }
        context.coordinator.loadedURL = nextURL
        nsView.stopLoading()
        nsView.loadFileURL(nextURL, allowingReadAccessTo: nextURL.deletingLastPathComponent())
    }
}

struct MacReaderBrowseView: View {
    @EnvironmentObject private var reader: MacReaderController
    @EnvironmentObject private var aidoku: MacAidokuStore
    var body: some View {
        VStack(spacing: 18) {
            if aidoku.installedSources.isEmpty {
                ContentUnavailableView("No Reader Sources", systemImage: "safari", description: Text("Add an Aidoku source list and install a source in Settings, or open a local book."))
            } else {
                List(aidoku.installedSources) { source in
                    HStack {
                        Image(systemName: source.isEnabled ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(source.isEnabled ? .green : .secondary)
                        VStack(alignment: .leading) {
                            Text(source.name).font(.headline)
                            Text(source.languages.map { $0.uppercased() }.joined(separator: ", "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 5)
                }
            }
            HStack {
                Button("Open Local Book…") { reader.openImportPanel() }
                Spacer()
                Text("Use Search to browse all enabled sources.").foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.bottom, 14)
        }
    }
}
