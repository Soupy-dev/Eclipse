#if !os(tvOS)
import Kingfisher
import SwiftUI

struct ReaderDownloadsSettingsView: View {
    @StateObject private var downloadManager = ReaderDownloadManager.shared
    @State private var selectedTab: ReaderDownloadsTab = .queue
    @State private var showingDeleteAll = false
    @State private var showingDeleteFailed = false
    @AppStorage("readerDownloadsBackgroundEnabled") private var backgroundDownloadsEnabled = true
    @AppStorage("readerDownloadsWifiOnly") private var wifiOnly = false
    @AppStorage("readerDownloadsParallelLimit") private var parallelLimit = 2

    private enum ReaderDownloadsTab: String, CaseIterable {
        case queue = "Queue"
        case library = "Library"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                KanzenRootHeader("Downloads")

                Picker("Downloads", selection: $selectedTab) {
                    ForEach(ReaderDownloadsTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)

                settingsSection

                switch selectedTab {
                case .queue:
                    queueSection
                case .library:
                    downloadedLibrarySection
                }

                storageSection
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
        }
        .background(GlobalGradientBackground().ignoresSafeArea())
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .adaptiveConfirmationDialog("Delete All Reader Downloads", isPresented: $showingDeleteAll, titleVisibility: .visible) {
            Button("Delete All", role: .destructive) {
                downloadManager.deleteAll()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes downloaded Reader files and cancels active Reader downloads.")
        }
        .adaptiveConfirmationDialog("Clear Failed Reader Downloads", isPresented: $showingDeleteFailed, titleVisibility: .visible) {
            Button("Clear Failed", role: .destructive) {
                downloadManager.deleteFailed()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            EmptyView()
        }
    }

    private var settingsSection: some View {
        GlassSection(header: "Download Settings") {
            VStack(spacing: 0) {
                GlassSettingsRow(icon: "bolt.fill", iconColor: .green, title: "Background Downloads") {
                    Toggle("", isOn: $backgroundDownloadsEnabled)
                        .labelsHidden()
                }

                GlassDivider()

                GlassSettingsRow(icon: "wifi", iconColor: .blue, title: "Wi-Fi Only") {
                    Toggle("", isOn: $wifiOnly)
                        .labelsHidden()
                }

                GlassDivider()

                GlassSettingsRow(icon: "rectangle.stack.fill", iconColor: .purple, title: "Parallel Downloads") {
                    Menu {
                        ForEach(1...4, id: \.self) { limit in
                            Button {
                                parallelLimit = limit
                                downloadManager.applyQueueSettingsChanged()
                            } label: {
                                HStack {
                                    Text("\(limit)")
                                    if parallelLimit == limit {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text("\(max(1, min(parallelLimit, 4)))")
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.bold))
                                .foregroundColor(.secondary)
                        }
                        .foregroundColor(.white)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var queueSection: some View {
        let active = downloadManager.activeDownloads
        let failed = downloadManager.failedDownloads
        if active.isEmpty && failed.isEmpty {
            emptyState(
                icon: "checkmark.circle",
                title: "No Active Downloads",
                message: "Reader downloads that are queued, paused, or failed will show here."
            )
        } else {
            GlassSection(header: "Active") {
                VStack(spacing: 0) {
                    ForEach(Array(active.enumerated()), id: \.element.id) { index, item in
                        queueRow(item)
                        if index < active.count - 1 { GlassDivider() }
                    }
                }
            }

            if !failed.isEmpty {
                GlassSection(header: "Failed") {
                    VStack(spacing: 0) {
                        ForEach(Array(failed.enumerated()), id: \.element.id) { index, item in
                            queueRow(item)
                            if index < failed.count - 1 { GlassDivider() }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var downloadedLibrarySection: some View {
        let titles = downloadManager.downloadedTitles
        if titles.isEmpty {
            emptyState(
                icon: "arrow.down.circle",
                title: "No Reader Downloads",
                message: "Downloaded manga, manhwa, and light novels will appear here."
            )
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: isIPad ? 160 : 118), spacing: 16)], spacing: 18) {
                ForEach(titles) { title in
                    NavigationLink(destination: ReaderDownloadedTitleDetailView(title: title)) {
                        downloadedTitleCard(title)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            downloadManager.deleteTitle(route: title.route)
                        } label: {
                            Label("Delete Downloads", systemImage: "trash")
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var storageSection: some View {
        GlassSection(header: "Storage") {
            VStack(spacing: 0) {
                GlassSettingsRow(icon: "internaldrive.fill", iconColor: .teal, title: "Used") {
                    Text(formattedBytes(downloadManager.totalDownloadedBytes))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                GlassDivider()

                Button {
                    showingDeleteFailed = true
                } label: {
                    GlassSettingsRow(icon: "exclamationmark.triangle.fill", iconColor: .orange, title: "Clear Failed")
                }
                .buttonStyle(.plain)

                GlassDivider()

                Button(role: .destructive) {
                    showingDeleteAll = true
                } label: {
                    GlassSettingsRow(icon: "trash.fill", iconColor: .red, title: "Delete All Reader Downloads")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func queueRow(_ item: ReaderDownloadItem) -> some View {
        HStack(spacing: 12) {
            poster(url: item.coverURL, width: 48, height: 72)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.mangaTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text(item.displayChapterTitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)

                if item.status == .downloading || item.status == .paused || item.status == .queued {
                    ProgressView(value: item.progress)
                        .tint(item.status == .paused ? .gray : .accentColor)
                    Text(statusText(item))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else if item.status == .failed {
                    Text(item.error ?? "Failed")
                        .font(.caption2)
                        .foregroundColor(.orange)
                        .lineLimit(2)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                if item.status == .downloading {
                    Button { downloadManager.pauseDownload(id: item.id) } label: {
                        Image(systemName: "pause.circle.fill")
                    }
                } else if item.status == .paused {
                    Button { downloadManager.resumeDownload(id: item.id) } label: {
                        Image(systemName: "play.circle.fill")
                    }
                } else if item.status == .failed {
                    Button { downloadManager.retryDownload(id: item.id) } label: {
                        Image(systemName: "arrow.clockwise.circle.fill")
                    }
                }

                Button(role: .destructive) { downloadManager.cancelDownload(id: item.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                }
            }
            .font(.title3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contextMenu {
            if item.status == .downloading {
                Button { downloadManager.pauseDownload(id: item.id) } label: {
                    Label("Pause", systemImage: "pause.circle")
                }
            }
            if item.status == .paused {
                Button { downloadManager.resumeDownload(id: item.id) } label: {
                    Label("Resume", systemImage: "play.circle")
                }
            }
            if item.status == .failed {
                Button { downloadManager.retryDownload(id: item.id) } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }
            Button(role: .destructive) { downloadManager.cancelDownload(id: item.id) } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }

    private func downloadedTitleCard(_ title: ReaderDownloadedTitle) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            poster(url: title.coverURL, width: nil, height: isIPad ? 220 : 176)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title3)
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Color.black.opacity(0.65))
                        .clipShape(Circle())
                        .padding(6)
                }

            Text(title.title)
                .font(.caption.weight(.semibold))
                .foregroundColor(.primary)
                .lineLimit(2)

            Text("\(title.completedCount) chapters - \(title.formattedSize)")
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    private func poster(url: String?, width: CGFloat?, height: CGFloat) -> some View {
        KFImage(URL(string: url ?? ""))
            .placeholder {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay(Image(systemName: "book.closed").foregroundColor(.secondary))
            }
            .resizable()
            .scaledToFill()
            .frame(width: width, height: height)
            .clipped()
            .cornerRadius(10)
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.7))
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private func statusText(_ item: ReaderDownloadItem) -> String {
        switch item.status {
        case .queued:
            return "Queued"
        case .downloading:
            return "\(Int(item.progress * 100))% • \(item.completedPages)/\(max(item.totalPages, 1)) pages"
        case .paused:
            return "Paused • \(Int(item.progress * 100))%"
        case .failed:
            return item.error ?? "Failed"
        case .completed:
            return "Complete"
        case .none:
            return ""
        }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct ReaderDownloadedTitleDetailView: View {
    let title: ReaderDownloadedTitle
    @ObservedObject private var downloadManager = ReaderDownloadManager.shared
    @StateObject private var kanzen = KanzenEngine()
    @State private var selectedChapter: Chapter?
    @State private var showingDelete = false

    private var chapters: [Chapter] {
        downloadManager.chapters(for: title.route).enumerated().map { index, item in
            Chapter(
                chapterNumber: item.chapterNumber,
                idx: index,
                chapterData: [
                    ChapterData(
                        params: ReaderDownloadedChapterPayload(route: title.route, chapterNumber: item.chapterNumber),
                        title: item.chapterTitle ?? "",
                        scanlationGroup: item.sourceName ?? ""
                    )
                ]
            )
        }
    }

    private var isNovel: Bool {
        title.format?.uppercased().contains("NOVEL") == true
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    KFImage(URL(string: title.coverURL ?? ""))
                        .placeholder { Rectangle().fill(Color.gray.opacity(0.2)) }
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 108)
                        .clipped()
                        .cornerRadius(10)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(title.title)
                            .font(.headline)
                            .lineLimit(2)
                        Text(title.sourceName ?? "Downloaded Reader Title")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("\(title.completedCount) chapters - \(title.formattedSize)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }

            Section("Downloaded Chapters") {
                ForEach(chapters) { chapter in
                    Button {
                        selectedChapter = chapter
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(chapter.chapterNumber)
                                    .font(.subheadline.weight(.semibold))
                                if let title = chapter.chapterData?.first?.title, !title.isEmpty {
                                    Text(title)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundColor(.green)
                        }
                    }
                }
            }
        }
        .navigationTitle(title.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(role: .destructive) {
                    showingDelete = true
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .adaptiveConfirmationDialog("Delete Downloads", isPresented: $showingDelete, titleVisibility: .visible) {
            Button("Delete Downloads", role: .destructive) {
                downloadManager.deleteTitle(route: title.route)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            EmptyView()
        }
        .fullScreenCover(item: $selectedChapter) { chapter in
            readerManagerView(
                chapters: chapters,
                selectedChapter: chapter,
                kanzen: kanzen,
                mangaId: title.mangaId,
                mangaTitle: title.title,
                mangaCoverURL: title.coverURL ?? "",
                mangaRoute: title.route,
                mangaFormat: title.format,
                totalChapters: chapters.count,
                latestChapterNumbers: chapters.map(\.chapterNumber)
            )
        }
    }
}
#endif
