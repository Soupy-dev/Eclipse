//
//  StorageView.swift
//  Eclipse
//
//  Created by Francesco on 04/11/25.
//

import SwiftUI

private struct StorageBreakdownItem: Identifiable, Sendable {
    var id: String { title }
    let title: String
    let sizeBytes: Int64
}

private struct StorageScanRequest: Sendable {
    let documentsDirectory: URL
    let cachesDirectory: URL
    let downloadsDirectory: URL
    let mpvPreloadDirectory: URL
    let nuvioPluginBytes: Int64
}

private struct StorageScanResult: Sendable {
    let cacheSizeBytes: Int64
    let breakdown: [StorageBreakdownItem]
}

private enum StorageScanner {
    private struct Metrics {
        var total: Int64 = 0
        var subtitles: Int64 = 0
        var downloads: Int64 = 0
        var mpvPreload: Int64 = 0
        var imageCache: Int64 = 0
        var serviceCache: Int64 = 0
        var readerCache: Int64 = 0
    }

    private static let subtitleExtensions: Set<String> = ["srt", "vtt", "ass", "ssa"]
    private static let imageTokens = ["kingfisher", "imagecache", "image-cache"]
    private static let serviceTokens = ["service", "source", "stremio"]
    private static let readerTokens = ["kanzen", "aidoku", "reader", "manga"]

    static func scan(_ request: StorageScanRequest) -> StorageScanResult? {
        guard let documentMetrics = metrics(
            at: request.documentsDirectory,
            downloadsDirectory: request.downloadsDirectory,
            mpvPreloadDirectory: request.mpvPreloadDirectory,
            classifyNamedCaches: false
        ), let cacheMetrics = metrics(
            at: request.cachesDirectory,
            downloadsDirectory: request.downloadsDirectory,
            mpvPreloadDirectory: request.mpvPreloadDirectory,
            classifyNamedCaches: true
        ) else {
            return nil
        }

        var downloadsSize = documentMetrics.downloads + cacheMetrics.downloads
        var subtitleSize = documentMetrics.subtitles + cacheMetrics.subtitles
        var mpvPreloadSize = documentMetrics.mpvPreload + cacheMetrics.mpvPreload

        if !isDescendant(request.downloadsDirectory, of: request.documentsDirectory),
           !isDescendant(request.downloadsDirectory, of: request.cachesDirectory) {
            guard let downloadMetrics = metrics(
                at: request.downloadsDirectory,
                downloadsDirectory: request.downloadsDirectory,
                mpvPreloadDirectory: request.mpvPreloadDirectory,
                classifyNamedCaches: false
            ) else { return nil }
            downloadsSize += downloadMetrics.total
            subtitleSize += downloadMetrics.subtitles
            mpvPreloadSize += downloadMetrics.mpvPreload
        }

        if !isDescendant(request.mpvPreloadDirectory, of: request.documentsDirectory),
           !isDescendant(request.mpvPreloadDirectory, of: request.cachesDirectory),
           !isDescendant(request.mpvPreloadDirectory, of: request.downloadsDirectory) {
            guard let preloadMetrics = metrics(
                at: request.mpvPreloadDirectory,
                downloadsDirectory: request.downloadsDirectory,
                mpvPreloadDirectory: request.mpvPreloadDirectory,
                classifyNamedCaches: false
            ) else { return nil }
            mpvPreloadSize += preloadMetrics.total
            subtitleSize += preloadMetrics.subtitles
        }

        let imageCacheSize = cacheMetrics.imageCache > 0
            ? cacheMetrics.imageCache
            : max(0, cacheMetrics.total - cacheMetrics.mpvPreload)
        let documentSize = max(0, documentMetrics.total - documentMetrics.downloads)

        return StorageScanResult(
            cacheSizeBytes: cacheMetrics.total,
            breakdown: [
                StorageBreakdownItem(title: "Document Directory", sizeBytes: documentSize),
                StorageBreakdownItem(title: "Image Cache", sizeBytes: imageCacheSize),
                StorageBreakdownItem(title: "MPV Warmup Cache", sizeBytes: mpvPreloadSize),
                StorageBreakdownItem(title: "Downloads / Video Storage", sizeBytes: downloadsSize),
                StorageBreakdownItem(title: "Subtitle Cache", sizeBytes: subtitleSize),
                StorageBreakdownItem(title: "Service / Addon Cache", sizeBytes: cacheMetrics.serviceCache),
                StorageBreakdownItem(title: "Plugin Provider Code", sizeBytes: request.nuvioPluginBytes),
                StorageBreakdownItem(title: "Reader Cache", sizeBytes: cacheMetrics.readerCache)
            ]
        )
    }

    private static func metrics(
        at root: URL,
        downloadsDirectory: URL,
        mpvPreloadDirectory: URL,
        classifyNamedCaches: Bool
    ) -> Metrics? {
        if Task.isCancelled { return nil }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return Metrics()
        }

        let rootPath = root.standardizedFileURL.path
        var result = Metrics()
        for case let fileURL as URL in enumerator {
            if Task.isCancelled { return nil }
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize else {
                continue
            }

            let size = Int64(fileSize)
            result.total += size
            if subtitleExtensions.contains(fileURL.pathExtension.lowercased()) {
                result.subtitles += size
            }
            if isDescendant(fileURL, of: downloadsDirectory) {
                result.downloads += size
            }
            if isDescendant(fileURL, of: mpvPreloadDirectory) {
                result.mpvPreload += size
            }

            guard classifyNamedCaches else { continue }
            let path = fileURL.standardizedFileURL.path
            let relative = path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
            let topLevelName = relative
                .split(separator: "/", omittingEmptySubsequences: true)
                .first
                .map(String.init)?
                .lowercased() ?? ""
            if imageTokens.contains(where: topLevelName.contains) {
                result.imageCache += size
            }
            if serviceTokens.contains(where: topLevelName.contains) {
                result.serviceCache += size
            }
            if readerTokens.contains(where: topLevelName.contains) {
                result.readerCache += size
            }
        }
        return result
    }

    private static func isDescendant(_ url: URL, of directory: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        return path == directoryPath || path.hasPrefix(directoryPath + "/")
    }
}

struct StorageView: View {
    @State private var cacheSizeBytes: Int64 = 0
    @State private var storageBreakdown: [StorageBreakdownItem] = []
    @State private var isLoading: Bool = true
    @State private var isClearing: Bool = false
    @State private var showConfirmClear: Bool = false
    @State private var errorMessage: String?
    @State private var scanTask: Task<StorageScanResult?, Never>?
    @State private var scanGeneration = UUID()

    @AppStorage("autoClearCacheEnabled", store: .standard) private var autoClearCacheEnabled = false
    @AppStorage("autoClearCacheThresholdMB", store: .standard) private var autoClearCacheThresholdMB: Double = 500

    @StateObject private var accentColorManager = AccentColorManager.shared

    private var accent: Color { accentColorManager.currentAccentColor }

    private var sanitizedAutoClearCacheThresholdMB: Double {
        CacheManager.sanitizedAutoClearThresholdMB(autoClearCacheThresholdMB)
    }

    private let cacheThresholdOptions: [Double] = [100, 250, 500, 1000, 2000, 5000]

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                GlassSection(header: "App Cache") {
                    VStack(spacing: 0) {
                        GlassDetailRow(icon: "externaldrive.fill", iconColor: .gray, title: "Cache Size") {
                            if isLoading {
                                EclipseLoadingIndicator()
                                    .tint(.white.opacity(0.6))
                            } else {
                                Text(formattedCacheSize)
                                    .font(.subheadline)
                                    .foregroundColor(.white.opacity(0.5))
                            }
                        }

                        GlassDivider()

                        Button {
                            showConfirmClear = true
                        } label: {
                            GlassDetailRow(icon: "trash.fill", iconColor: .red, title: isClearing ? "Clearing Cache..." : "Clear Cache") {
                                if isClearing {
                                    EclipseLoadingIndicator()
                                        .tint(.white.opacity(0.6))
                                } else {
                                    EmptyView()
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isClearing || (isLoading && cacheSizeBytes == 0))
                    }
                }
                GlassSectionFooter("Cache includes images and other temporary files that can be removed.")

                if ExperimentalFeatureState.isEnabledAtLaunch || ExperimentalFeatureState.isMPVAdvancedPlaybackAvailable {
                    GlassSection(header: "Storage Breakdown") {
                        VStack(spacing: 0) {
                            ForEach(storageBreakdown) { item in
                                GlassDetailRow(icon: "doc.fill", iconColor: .blue, title: item.title) {
                                    if isLoading {
                                        EclipseLoadingIndicator()
                                            .tint(.white.opacity(0.6))
                                    } else {
                                        Text(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))
                                            .font(.subheadline)
                                            .foregroundColor(.white.opacity(0.5))
                                    }
                                }
                                GlassDivider()
                            }

                            Button(role: .destructive) {
                                ExperimentalMPVPreloadManager.shared.clearCache()
                                refreshCacheSize()
                            } label: {
                                GlassDetailRow(icon: "trash", iconColor: .red, title: "Clear MPV Warmup Cache") {
                                    EmptyView()
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(!ExperimentalFeatureState.isMPVAdvancedPlaybackAvailable || isLoading || isClearing)
                        }
                    }
                    GlassSectionFooter(ExperimentalFeatureState.isMPVAdvancedPlaybackAvailable ? "MPV warmup files are temporary cache data and are excluded from downloads, backup, and iCloud." : "MPV warmup cache actions require MPV as the default in-app player with the MoltenVK renderer.")
                }

                GlassSection(header: "Auto-Clear Cache") {
                    VStack(spacing: 0) {
                        GlassDetailRow(icon: "clock.arrow.circlepath", iconColor: .orange, title: "Enable Auto-Clear") {
                            Toggle("", isOn: $autoClearCacheEnabled)
                                .labelsHidden()
                                .tint(accent)
                        }

                        if autoClearCacheEnabled {
                            GlassDivider()

                            GlassDetailRow(icon: "gauge.with.dots.needle.bottom.50percent", iconColor: .yellow, title: "Threshold", subtitle: "Cache will be cleared when size exceeds \(formatThreshold(sanitizedAutoClearCacheThresholdMB)).") {
                                Menu {
                                    ForEach(cacheThresholdOptions, id: \.self) { value in
                                        Button {
                                            autoClearCacheThresholdMB = value
                                        } label: {
                                            if sanitizedAutoClearCacheThresholdMB == value {
                                                Label(formatThreshold(value), systemImage: "checkmark")
                                            } else {
                                                Text(formatThreshold(value))
                                            }
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Text(formatThreshold(sanitizedAutoClearCacheThresholdMB))
                                            .font(.subheadline)
                                            .foregroundColor(.white.opacity(0.6))
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundColor(.white.opacity(0.4))
                                    }
                                }
                            }
                        }
                    }
                }
                GlassSectionFooter("Automatically clear cache when it exceeds the specified size.")

                if let errorMessage {
                    GlassSection(header: "Error") {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                    }
                }
            }
            .padding(.top, 16)
            .padding(.bottom, 32)
            .background(EclipseScrollTracker())
        }
        .navigationTitle("Storage")
        .background(SettingsGradientBackground().ignoresSafeArea())
        .eclipseDarkToolbar()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: refreshCacheSize) {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(isLoading || isClearing)
                .help("Recalculate cache size")
            }
        }
        .onAppear {
            refreshCacheSize()
        }
        .onDisappear {
            scanTask?.cancel()
            scanTask = nil
        }
        .onChange(of: autoClearCacheEnabled) { enabled in
            if enabled {
                autoClearCacheThresholdMB = sanitizedAutoClearCacheThresholdMB
                Logger.shared.log("Auto-clear cache enabled with threshold: \(formatThreshold(sanitizedAutoClearCacheThresholdMB))", type: "Storage")
            }
        }
        .alert("Clear Cache?", isPresented: $showConfirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { clearCache() }
        } message: {
            Text("This will remove cached files. You may need to re-download some content later.")
        }
    }

    private var formattedCacheSize: String {
        ByteCountFormatter.string(fromByteCount: cacheSizeBytes, countStyle: .file)
    }

    private func formatThreshold(_ mb: Double) -> String {
        let sanitized = CacheManager.sanitizedAutoClearThresholdMB(mb)
        if sanitized >= 1000 {
            return String(format: "%.1f GB", sanitized / 1000)
        }
        return String(format: "%.0f MB", sanitized)
    }

    private func refreshCacheSize() {
        scanTask?.cancel()
        errorMessage = nil
        isLoading = true
        let generation = UUID()
        scanGeneration = generation

        let documents = documentsDirectory()
        let caches = cachesDirectory()
        let downloads = DownloadManager.shared.downloadsDirectory
        let preload = ExperimentalMPVPreloadManager.shared.cacheDirectory
        let task = Task.detached(priority: .utility) {
            let request = StorageScanRequest(
                documentsDirectory: documents,
                cachesDirectory: caches,
                downloadsDirectory: downloads,
                mpvPreloadDirectory: preload,
                nuvioPluginBytes: Self.nuvioPluginStorageBytes()
            )
            return StorageScanner.scan(request)
        }
        scanTask = task

        Task { @MainActor in
            guard let result = await task.value,
                  !task.isCancelled,
                  scanGeneration == generation else { return }
            scanTask = nil
            cacheSizeBytes = result.cacheSizeBytes
            storageBreakdown = result.breakdown
            isLoading = false

            if autoClearCacheEnabled {
                let thresholdMB = sanitizedAutoClearCacheThresholdMB
                let thresholdBytes = CacheManager.autoClearThresholdBytes(for: thresholdMB)
                if result.cacheSizeBytes > thresholdBytes {
                    Logger.shared.log("Cache size (\(ByteCountFormatter.string(fromByteCount: result.cacheSizeBytes, countStyle: .file))) exceeds threshold (\(formatThreshold(thresholdMB))). Auto-clearing...", type: "Storage")
                    autoClearCache()
                }
            }
        }
    }

    private func clearCache() {
        errorMessage = nil
        isClearing = true
        performCacheClear(logCompletion: false)
    }

    private func autoClearCache() {
        isClearing = true
        performCacheClear(logCompletion: true)
    }

    private func performCacheClear(logCompletion: Bool) {
        scanTask?.cancel()
        scanTask = nil
        let directory = cachesDirectory()

        Task { @MainActor in
            let clearError = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    let fileManager = FileManager.default
                    let items = try fileManager.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: nil,
                        options: []
                    )
                    for url in items {
                        try? fileManager.removeItem(at: url)
                    }
                    URLCache.shared.removeAllCachedResponses()
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value

            if let clearError {
                errorMessage = clearError
                isClearing = false
                isLoading = false
                return
            }

            cacheSizeBytes = 0
            isClearing = false
            if logCompletion {
                Logger.shared.log("Auto-clear completed.", type: "Storage")
            }
            refreshCacheSize()
        }
    }

    private func cachesDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    private func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static func nuvioPluginStorageBytes() -> Int64 {
#if os(iOS) && !targetEnvironment(macCatalyst)
        guard PlatformCapabilities.current.supportsNuvioPlugins else { return 0 }
        return NuvioPluginStore.shared.codeSizeBytes()
#else
        return 0
#endif
    }

}

#Preview {
    StorageView()
}
