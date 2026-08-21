#if os(iOS) && !targetEnvironment(macCatalyst)
import SwiftUI
import CryptoKit
import UIKit
import ImageIO

enum SkyStreamUntestedWarningAcknowledgement {
    private static let keyPrefix = "skyStreamUntestedWarningSeen.v2."

    static func archiveSHA256(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func normalizedArchiveSHA256(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.utf8.count == 64,
              normalized.unicodeScalars.allSatisfy({ scalar in
                  ("0"..."9").contains(Character(scalar))
                      || ("a"..."f").contains(Character(scalar))
              }) else {
            return nil
        }
        return normalized
    }

    static func warningKey(forArchiveSHA256 value: String?) -> String? {
        normalizedArchiveSHA256(value).map { keyPrefix + $0 }
    }

    static func wasSeen(
        forArchiveSHA256 value: String?,
        defaults: UserDefaults = ProfileSettingsStore.services
    ) -> Bool {
        guard let key = warningKey(forArchiveSHA256: value) else { return false }
        return defaults.bool(forKey: key)
    }

    static func markSeen(
        forArchiveSHA256 value: String?,
        defaults: UserDefaults = ProfileSettingsStore.services
    ) {
        guard let key = warningKey(forArchiveSHA256: value) else { return }
        defaults.set(true, forKey: key)
    }
}

private actor SkyStreamIconFetchCoordinator {
    static let shared = SkyStreamIconFetchCoordinator()

    private struct InFlight {
        let id: UUID
        let task: Task<Data?, Never>
        var waiterIDs: Set<UUID>
    }

    private struct SlotWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let maximumConcurrentFetches = 4
    private let maximumQueuedFetches = 32
    private var activeFetches = 0
    private var slotWaiters: [SlotWaiter] = []
    private var inFlightByURL: [String: InFlight] = [:]

    private let httpClient = SkyStreamHTTPClient()
    private let cache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.countLimit = 128
        cache.totalCostLimit = 8 * 1_024 * 1_024
        return cache
    }()

    func data(for rawURL: String) async -> Data? {
        let key = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 8 * 1_024 else { return nil }
        if let cached = cache.object(forKey: key as NSString) {
            return cached as Data
        }

        let waiterID = UUID()
        let inFlightID: UUID
        let task: Task<Data?, Never>
        if var existing = inFlightByURL[key] {
            existing.waiterIDs.insert(waiterID)
            inFlightByURL[key] = existing
            inFlightID = existing.id
            task = existing.task
        } else {
            let id = UUID()
            let created = Task<Data?, Never> { [weak self] in
                guard let self else { return nil }
                return await self.executeFetch(key)
            }
            inFlightByURL[key] = InFlight(id: id, task: created, waiterIDs: [waiterID])
            inFlightID = id
            task = created
        }

        return await withTaskCancellationHandler {
            let result = await task.value
            return finishWaiter(
                waiterID,
                inFlightID: inFlightID,
                key: key,
                result: result
            )
        } onCancel: {
            Task {
                await self.cancelWaiter(waiterID, inFlightID: inFlightID, key: key)
            }
        }
    }

    private func finishWaiter(
        _ waiterID: UUID,
        inFlightID: UUID,
        key: String,
        result: Data?
    ) -> Data? {
        guard let current = inFlightByURL[key], current.id == inFlightID else {
            return result
        }
        var updated = current
        updated.waiterIDs.remove(waiterID)
        if let result {
            cache.setObject(result as NSData, forKey: key as NSString, cost: result.count)
        }

        inFlightByURL.removeValue(forKey: key)
        return result
    }

    private func cancelWaiter(_ waiterID: UUID, inFlightID: UUID, key: String) {
        guard var current = inFlightByURL[key], current.id == inFlightID else { return }
        current.waiterIDs.remove(waiterID)
        if current.waiterIDs.isEmpty {
            inFlightByURL.removeValue(forKey: key)
            current.task.cancel()
        } else {
            inFlightByURL[key] = current
        }
    }

    private func executeFetch(_ rawURL: String) async -> Data? {
        do {
            try await acquireSlot()
        } catch {
            return nil
        }
        defer { releaseSlot() }
        guard !Task.isCancelled else { return nil }

        do {
            let validated = try await SkyStreamRemoteURLPolicy.shared.validate(
                rawURL,
                purpose: .icon
            )
            guard validated.url.scheme?.lowercased() == "https" else { return nil }
            let response = try await httpClient.fetch(
                SkyStreamHTTPRequest(url: validated, allowsCookies: false),
                packageID: "ui_icons",
                limits: SkyStreamHTTPRequestLimits(
                    maximumResponseBytes: 512 * 1_024,
                    maximumRequestBodyBytes: 0,
                    maximumRedirects: 3,
                    timeout: 10
                )
            )
            guard (200...299).contains(response.statusCode),
                  response.data.count <= 512 * 1_024,
                  let mime = response.response.mimeType?.lowercased(),
                  Self.allowedImageMIMETypes.contains(mime) else {
                return nil
            }
            return response.data
        } catch {
            return nil
        }
    }

    private func acquireSlot() async throws {
        try Task.checkCancellation()
        if activeFetches < maximumConcurrentFetches {
            activeFetches += 1
            return
        }
        guard slotWaiters.count < maximumQueuedFetches else {
            throw SkyStreamSecurityError.tooManyConcurrentRequests
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    slotWaiters.append(SlotWaiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelSlotWaiter(waiterID) }
        }
    }

    private func cancelSlotWaiter(_ id: UUID) {
        guard let index = slotWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = slotWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func releaseSlot() {
        if !slotWaiters.isEmpty {
            let next = slotWaiters.removeFirst()

            next.continuation.resume()
        } else {
            activeFetches = max(0, activeFetches - 1)
        }
    }

    private static let allowedImageMIMETypes: Set<String> = [
        "image/png", "image/jpeg", "image/jpg", "image/gif", "image/webp",
        "image/heic", "image/heif", "image/tiff"
    ]
}

private struct SkyStreamDecodedIcon: @unchecked Sendable {
    let image: UIImage
    let memoryCost: Int
}

private struct SkyStreamIconView: View {
    let rawURL: String?
    let size: CGFloat
    let fallbackSystemName: String

    @State private var loadedImage: UIImage?
    @State private var isLoading = false

    private static let decodedCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 128
        cache.totalCostLimit = 16 * 1_024 * 1_024
        return cache
    }()

    private static let validatedURLCache: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 256
        return cache
    }()

    private var validatedURLString: String? {
        guard let rawURL else { return nil }
        let cacheKey = rawURL as NSString
        if let memoized = Self.validatedURLCache.object(forKey: cacheKey) {
            return memoized.length == 0 ? nil : memoized as String
        }
        guard let validated = try? SkyStreamRemoteURLPolicy.shared.validateSyntactic(
                rawURL,
                purpose: .icon
              ),
              validated.url.scheme?.lowercased() == "https" else {
            Self.validatedURLCache.setObject("" as NSString, forKey: cacheKey)
            return nil
        }
        let resolved = validated.url.absoluteString
        Self.validatedURLCache.setObject(resolved as NSString, forKey: cacheKey)
        return resolved
    }

    var body: some View {
        Group {
            if let loadedImage {
                Image(uiImage: loadedImage)
                    .resizable()
                    .scaledToFill()
            } else if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: max(7, size * 0.2), style: .continuous))
        .accessibilityHidden(true)
        .task(id: validatedURLString) {
            loadedImage = nil
            guard let key = validatedURLString else {
                isLoading = false
                return
            }
            if let cached = Self.decodedCache.object(forKey: key as NSString) {
                loadedImage = cached
                isLoading = false
                return
            }

            isLoading = true
            guard let data = await SkyStreamIconFetchCoordinator.shared.data(for: key),
                  !Task.isCancelled else {
                isLoading = false
                return
            }
            let decoded = await Task.detached(priority: .utility) {
                Self.decodeThumbnail(data)
            }.value
            guard !Task.isCancelled, let decoded else {
                isLoading = false
                return
            }
            Self.decodedCache.setObject(
                decoded.image,
                forKey: key as NSString,
                cost: decoded.memoryCost
            )
            loadedImage = decoded.image
            isLoading = false
        }
    }

    private var fallback: some View {
        Image(systemName: fallbackSystemName)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(.tint)
    }

    nonisolated private static func decodeThumbnail(_ data: Data) -> SkyStreamDecodedIcon? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              (1...16).contains(CGImageSourceGetCount(source)),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0,
              width <= 4_096, height <= 4_096,
              Int64(width) * Int64(height) <= 16_000_000 else {
            return nil
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 256
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }
        let memoryCost = min(cgImage.bytesPerRow * cgImage.height, 4 * 1_024 * 1_024)
        return SkyStreamDecodedIcon(image: UIImage(cgImage: cgImage), memoryCost: memoryCost)
    }
}

struct SkyStreamManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = SkyStreamPluginManager.shared
    @State private var inputURL = ""
    @State private var isResolving = false
    @State private var errorMessage: String?
    @State private var pendingInstall: PendingInstall?
    @State private var pendingReplacement: PendingInstall?
    @State private var showUntestedWarning = false
    @State private var showReplacementWarning = false
    @State private var isRetryingLoad = false
    @State private var showResetConfirmation = false

    private struct PendingInstall: Identifiable {
        enum Source {
            case direct(data: Data, url: URL)
            case repository(packageName: String, repository: SkyStreamSavedRepository)
        }

        let id = UUID()
        let packageName: String?
        let displayName: String
        let archiveSHA256: String?
        let source: Source
    }

    var body: some View {
        NavigationView {
            List {
                if let notice = manager.lastNoticeMessage {
                    Section {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(notice)
                                .font(.subheadline)
                            Spacer(minLength: 4)
                            Button("Dismiss") { manager.dismissNotice() }
                                .font(.caption)
                        }
                    }
                }

                if manager.stateLoadDidFail || !manager.unreadablePackageIDs.isEmpty {
                    stateLoadFailureSection
                }

                Section {
                    TextField("HTTPS repository or .sky URL", text: $inputURL)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .onSubmit(resolveInput)

                    Button(action: resolveInput) {
                        HStack {
                            Label("Add", systemImage: "plus.circle")
                            Spacer()
                            if isResolving {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isResolving || inputURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text("Add SkyStream Plugin")
                } footer: {
                    Text("Enter a user-supplied HTTPS repo.json, plugin-list JSON, or .sky package URL. Eclipse does not include or recommend a repository.")
                }

                if !manager.installedPlugins.isEmpty {
                    Section("Installed Plugins") {
                        ForEach(manager.installedPlugins) { plugin in
                            NavigationLink {
                                SkyStreamPluginSettingsView(packageName: plugin.id)
                            } label: {
                                installedPluginLabel(plugin)
                            }
                        }
                    }
                }

                if !manager.repositories.isEmpty {
                    Section("Saved Repositories") {
                        ForEach(manager.repositories) { repository in
                            NavigationLink {
                                SkyStreamRepositoryDetailView(repositoryID: repository.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(repository.name)
                                    Text("\(repository.plugins.count) plugins")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

            }
            .navigationTitle("SkyStream Plugins")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay {
                if !manager.isLoaded && !manager.stateLoadDidFail {
                    ProgressView("Loading SkyStream…")
                }
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
        .alert("Reset SkyStream Data?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) { performReset() }
        } message: {
            Text("This removes every saved SkyStream repository and installed package from this device. You can add them again afterwards.")
        }
        .alert("Untested Plugin", isPresented: $showUntestedWarning) {
            Button("Cancel", role: .cancel) { pendingInstall = nil }
            Button("Install") {
                guard let pendingInstall else { return }
                performInstall(pendingInstall, policy: .normal)
            }
        } message: {
            Text("This package runs third-party JavaScript and has not completed Eclipse compatibility testing. Eclipse will still isolate its storage, filter network access, verify package integrity, and reject non-VOD output.")
        }
        .alert("Confirm Code Replacement", isPresented: $showReplacementWarning) {
            Button("Cancel", role: .cancel) { pendingReplacement = nil }
            Button("Replace", role: .destructive) {
                guard let pendingReplacement else { return }
                performInstall(pendingReplacement, policy: .userConfirmedReplacement)
            }
        } message: {
            Text("This changes the package's pinned source, installs an older version, or replaces code without a version change. Existing code stays installed unless the replacement fully validates.")
        }
        .alert("SkyStream Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var stateLoadFailureHeadline: String {
        if manager.stateLoadDidFail {
            return "SkyStream could not read its saved data, so no repositories or packages are available."
        }
        if manager.unreadablePackageIDs.count == 1 {
            return "1 installed SkyStream package could not be read and was skipped."
        }
        return "\(manager.unreadablePackageIDs.count) installed SkyStream packages could not be read and were skipped."
    }

    private var stateLoadFailureSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(.red)
                    Text(stateLoadFailureHeadline)
                        .font(.subheadline)
                }
                if manager.stateLoadDidFail, let detail = manager.lastErrorMessage {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                retryLoad()
            } label: {
                HStack {
                    Label("Try Again", systemImage: "arrow.clockwise")
                    Spacer()
                    if isRetryingLoad {
                        ProgressView()
                    }
                }
            }
            .disabled(isRetryingLoad)

            Button(role: .destructive) {
                showResetConfirmation = true
            } label: {
                Label("Reset SkyStream Plugin Data", systemImage: "trash")
            }
            .disabled(isRetryingLoad)
        } footer: {
            Text("Resetting clears the saved repositories and installed packages on this device so SkyStream can start over.")
        }
    }

    private func retryLoad() {
        guard !isRetryingLoad else { return }
        isRetryingLoad = true
        Task {
            await manager.retryLoadingPersistedState()
            isRetryingLoad = false
        }
    }

    private func performReset() {
        guard !isRetryingLoad else { return }
        isRetryingLoad = true
        Task {
            do {
                try await manager.resetPluginData()
            } catch {
                errorMessage = error.localizedDescription
            }
            isRetryingLoad = false
        }
    }

    @ViewBuilder
    private func installedPluginLabel(_ plugin: SkyStreamInstalledPluginState) -> some View {
        HStack(spacing: 12) {
            SkyStreamIconView(
                rawURL: plugin.manifest.iconURL,
                size: 36,
                fallbackSystemName: "shippingbox.fill"
            )
            VStack(alignment: .leading, spacing: 3) {
                Text(plugin.manifest.name)
                HStack(spacing: 6) {
                    Text("v\(plugin.manifest.version)")
                    if plugin.compatibility.status != .untested {
                        Text("•")
                        Text(plugin.compatibility.status.rawValue)
                    }
                }
                .font(.caption)
                .foregroundStyle(plugin.compatibility.status == .incompatible ? .red : .secondary)
            }
        }
    }

    private func resolveInput() {
        let value = inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !isResolving else { return }
        isResolving = true
        Task {
            do {
                let result = try await manager.addUserInput(value)
                switch result {
                case .repository:
                    inputURL = ""
                case .archive(let data, let sourceURL):
                    let pending = PendingInstall(
                        packageName: nil,
                        displayName: sourceURL.host ?? "Direct SkyStream Package",
                        archiveSHA256: SkyStreamUntestedWarningAcknowledgement.archiveSHA256(for: data),
                        source: .direct(data: data, url: sourceURL)
                    )
                    pendingInstall = pending
                    if warningWasSeen(for: pending) {
                        performInstall(pending, policy: .normal)
                    } else {
                        showUntestedWarning = true
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isResolving = false
        }
    }

    private func requestRepositoryInstall(
        packageName: String,
        displayName: String,
        repository: SkyStreamSavedRepository
    ) {
        let pending = PendingInstall(
            packageName: packageName,
            displayName: displayName,
            archiveSHA256: repository.plugins
                .first(where: { $0.manifest.packageName == packageName })?
                .expectedArchiveSHA256,
            source: .repository(packageName: packageName, repository: repository)
        )
        pendingInstall = pending
        if warningWasSeen(for: pending) {
            performInstall(pending, policy: .normal)
        } else {
            showUntestedWarning = true
        }
    }

    private func performInstall(
        _ pending: PendingInstall,
        policy: SkyStreamReplacementPolicy
    ) {
        pendingInstall = nil
        Task {
            do {
                let installed: SkyStreamInstalledPluginState
                switch pending.source {
                case .direct(let data, let url):
                    installed = try await manager.installDirectArchive(
                        data,
                        sourceURL: url,
                        replacementPolicy: policy
                    )
                case .repository(let packageName, let repository):
                    installed = try await manager.install(
                        packageName: packageName,
                        from: repository,
                        replacementPolicy: policy
                    )
                }

                SkyStreamUntestedWarningAcknowledgement.markSeen(
                    forArchiveSHA256: installed.archiveSHA256
                )
                inputURL = ""
            } catch let error as SkyStreamPluginManagerError {
                switch error {
                case .provenanceTakeoverRequiresConfirmation,
                     .downgradeRequiresConfirmation,
                     .sameVersionCodeReplacementRequiresConfirmation where policy == .normal:
                    pendingReplacement = pending
                    showReplacementWarning = true
                default:
                    errorMessage = error.localizedDescription
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func warningWasSeen(for pending: PendingInstall) -> Bool {
        SkyStreamUntestedWarningAcknowledgement.wasSeen(
            forArchiveSHA256: pending.archiveSHA256
        )
    }
}

private struct SkyStreamRepositoryDetailView: View {
    let repositoryID: String
    @StateObject private var manager = SkyStreamPluginManager.shared
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var normalizedSearchIndex: [String: String] = [:]
    @State private var installRequest: InstallRequest?
    @State private var replacementRequest: InstallRequest?
    @State private var showUntestedWarning = false
    @State private var showReplacementWarning = false
    @State private var errorMessage: String?
    @State private var showRemoveConfirmation = false

    private struct InstallRequest: Identifiable {
        let id = UUID()
        let packageName: String
        let displayName: String
        let archiveSHA256: String?
        let repository: SkyStreamSavedRepository
    }

    private var repository: SkyStreamSavedRepository? {
        manager.repositories.first { $0.id == repositoryID }
    }

    private var repositoryIndexIdentity: String {
        guard let repository else { return "missing" }
        return "\(repository.id)|\(repository.lastRefreshedAt.timeIntervalSince1970)|\(repository.plugins.count)"
    }

    private var filteredPlugins: [SkyStreamPluginListEntry] {
        guard let repository else { return [] }
        let query = Self.normalizedSearchText(debouncedSearchText)
        guard !query.isEmpty else { return repository.plugins }
        guard !normalizedSearchIndex.isEmpty else { return repository.plugins }
        return repository.plugins.filter { entry in
            normalizedSearchIndex[entry.manifest.packageName]?.contains(query) == true
        }
    }

    var body: some View {
        List {
            if let repository {
                Section {
                    ForEach(filteredPlugins) { entry in
                        catalogRow(entry, repository: repository)
                    }
                } header: {
                    Text("Plugins")
                }

                Section {
                    Button {
                        Task {
                            do {
                                let refreshed = try await SkyStreamRepositoryManager.shared.refresh(repository)
                                try await manager.saveRepository(refreshed)
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    } label: {
                        Label("Refresh Repository", systemImage: "arrow.clockwise")
                    }

                    Button("Remove Repository", role: .destructive) {
                        showRemoveConfirmation = true
                    }
                } footer: {
                    Text("Removing a repository keeps installed plugins and their settings, but freezes their update provenance.")
                }
            } else {
                Text("Repository unavailable")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(repository?.name ?? "Repository")
        .searchable(text: $searchText, prompt: "Search plugins")
        .task(id: repositoryIndexIdentity) {
            guard let plugins = repository?.plugins else {
                normalizedSearchIndex = [:]
                return
            }
            let index = await Task.detached(priority: .utility) {
                var result: [String: String] = [:]
                result.reserveCapacity(plugins.count)
                for entry in plugins where result[entry.manifest.packageName] == nil {
                    let blob = [
                        entry.manifest.name,
                        entry.manifest.packageName,
                        entry.manifest.authors.joined(separator: " "),
                        entry.manifest.languages.joined(separator: " "),
                        entry.manifest.categories.joined(separator: " ")
                    ].joined(separator: " \u{1f} ")
                    result[entry.manifest.packageName] = Self.normalizedSearchText(blob)
                }
                return result
            }.value
            guard !Task.isCancelled else { return }
            normalizedSearchIndex = index
        }
        .task(id: searchText) {
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                try? await Task.sleep(nanoseconds: 180_000_000)
            }
            guard !Task.isCancelled else { return }
            debouncedSearchText = trimmed
        }
        .alert("Untested Plugin", isPresented: $showUntestedWarning) {
            Button("Cancel", role: .cancel) { installRequest = nil }
            Button("Install") {
                guard let installRequest else { return }
                install(installRequest, policy: .normal)
            }
        } message: {
            Text("This third-party package has not completed Eclipse compatibility testing. Install only if you trust its source.")
        }
        .alert("Confirm Code Replacement", isPresented: $showReplacementWarning) {
            Button("Cancel", role: .cancel) { replacementRequest = nil }
            Button("Replace", role: .destructive) {
                guard let replacementRequest else { return }
                install(replacementRequest, policy: .userConfirmedReplacement)
            }
        } message: {
            Text("This package is pinned to a different source, is older, or changed code without a version bump. Existing code remains installed unless the replacement fully validates.")
        }
        .alert("Remove Repository?", isPresented: $showRemoveConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                Task {
                    do {
                        try await manager.removeRepository(sourceURL: repositoryID)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        } message: {
            Text("Installed plugins remain available. Their pinned repository will be marked unavailable for updates.")
        }
        .alert("SkyStream Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    nonisolated private static func normalizedSearchText(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    @ViewBuilder
    private func catalogRow(
        _ entry: SkyStreamPluginListEntry,
        repository: SkyStreamSavedRepository
    ) -> some View {
        let compatibility = catalogCompatibility(for: entry.manifest)
        HStack(alignment: .top, spacing: 12) {
            SkyStreamIconView(
                rawURL: entry.manifest.iconURL,
                size: 32,
                fallbackSystemName: "shippingbox"
            )
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.manifest.name)
                    .font(.headline)
                Text(entry.manifest.description ?? entry.manifest.packageName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text([
                    "v\(entry.manifest.version)",
                    entry.manifest.authors.joined(separator: ", "),
                    entry.manifest.languages.joined(separator: ", "),
                    entry.manifest.categories.joined(separator: ", ")
                ].filter { !$0.isEmpty }.joined(separator: " • "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if compatibility.status != .untested {
                    Label(
                        compatibility.status.rawValue,
                        systemImage: compatibilitySystemImage(for: compatibility.status)
                    )
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(compatibilityColor(for: compatibility.status))
                    if let explanation = compatibility.reasons.first?.message {
                        Text(explanation)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            Spacer()
            Button(installButtonTitle(for: entry)) {
                let request = InstallRequest(
                    packageName: entry.manifest.packageName,
                    displayName: entry.manifest.name,
                    archiveSHA256: entry.expectedArchiveSHA256,
                    repository: repository
                )
                installRequest = request
                if SkyStreamUntestedWarningAcknowledgement.wasSeen(
                    forArchiveSHA256: request.archiveSHA256
                ) {
                    install(request, policy: .normal)
                } else {

                    showUntestedWarning = true
                }
            }
            .buttonStyle(.bordered)
            .disabled(isAlreadyCurrent(entry, repository: repository))
        }
    }

    private func catalogCompatibility(
        for manifest: SkyStreamPluginManifest
    ) -> SkyStreamCompatibilityResult {
        if let version = manifest.manifestVersion,
           !SkyStreamPackageValidationLimits.default.supportedManifestVersions.contains(version) {
            return SkyStreamCompatibilityResult(
                status: .incompatible,
                reasons: [
                    SkyStreamCompatibilityReason(
                        code: .unsupportedManifestVersion,
                        message: "SkyStream manifest version \(version) is unsupported."
                    )
                ]
            )
        }
        if manifest.categories.contains(where: { $0.lowercased().contains("live") }) {
            return SkyStreamCompatibilityResult(
                status: .limited,
                reasons: [
                    SkyStreamCompatibilityReason(
                        code: .liveOnly,
                        message: "Live output is filtered; only verified VOD streams can be used."
                    )
                ]
            )
        }
        return .untested
    }

    private func compatibilitySystemImage(for status: SkyStreamCompatibilityStatus) -> String {
        switch status {
        case .compatible: return "checkmark.circle.fill"
        case .untested: return "questionmark.circle"
        case .limited: return "exclamationmark.triangle.fill"
        case .incompatible: return "xmark.octagon.fill"
        }
    }

    private func compatibilityColor(for status: SkyStreamCompatibilityStatus) -> Color {
        switch status {
        case .compatible: return .green
        case .untested: return .secondary
        case .limited: return .orange
        case .incompatible: return .red
        }
    }

    private func installButtonTitle(for entry: SkyStreamPluginListEntry) -> String {
        guard let installed = manager.plugin(packageName: entry.manifest.packageName) else {
            return "Install"
        }
        if entry.manifest.version > installed.manifest.version { return "Update" }
        if entry.manifest.version < installed.manifest.version { return "Replace" }
        return isCatalogCodeCurrent(entry, installed: installed)
            && installed.provenance.repositoryURL == repositoryID
            ? "Installed"
            : "Replace"
    }

    private func isAlreadyCurrent(
        _ entry: SkyStreamPluginListEntry,
        repository: SkyStreamSavedRepository
    ) -> Bool {
        guard let installed = manager.plugin(packageName: entry.manifest.packageName) else { return false }
        return installed.provenance.repositoryURL == repository.sourceURL
            && installed.manifest.version >= entry.manifest.version
            && isCatalogCodeCurrent(entry, installed: installed)
    }

    private func isCatalogCodeCurrent(
        _ entry: SkyStreamPluginListEntry,
        installed: SkyStreamInstalledPluginState
    ) -> Bool {

        guard let expected = SkyStreamUntestedWarningAcknowledgement.normalizedArchiveSHA256(
            entry.expectedArchiveSHA256
        ) else {

            return true
        }
        return installed.archiveSHA256.caseInsensitiveCompare(expected) == .orderedSame
    }

    private func install(_ request: InstallRequest, policy: SkyStreamReplacementPolicy) {
        installRequest = nil
        Task {
            do {
                let installed = try await manager.install(
                    packageName: request.packageName,
                    from: request.repository,
                    replacementPolicy: policy
                )
                SkyStreamUntestedWarningAcknowledgement.markSeen(
                    forArchiveSHA256: installed.archiveSHA256
                )
            } catch let error as SkyStreamPluginManagerError {
                switch error {
                case .provenanceTakeoverRequiresConfirmation,
                     .downgradeRequiresConfirmation,
                     .sameVersionCodeReplacementRequiresConfirmation where policy == .normal:
                    replacementRequest = request
                    showReplacementWarning = true
                default:
                    errorMessage = error.localizedDescription
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct SkyStreamPluginSettingsView: View {
    let packageName: String
    @Environment(\.dismiss) private var dismiss
    @StateObject private var manager = SkyStreamPluginManager.shared
    @StateObject private var profileManager = ProfileManager.shared
    @State private var showResetConfirmation = false
    @State private var showUninstallConfirmation = false
    @State private var errorMessage: String?

    private var plugin: SkyStreamInstalledPluginState? {
        manager.plugin(packageName: packageName)
    }

    private var canAdminister: Bool {
        profileManager.activeProfile?.isKidsProfile != true
    }

    var body: some View {
        Form {
            if let plugin {
                Section("Plugin") {
                    valueRow("Name", plugin.manifest.name)
                    valueRow("Package", plugin.id)
                    valueRow("Version", String(plugin.manifest.version))
                    if plugin.compatibility.status != .untested {
                        valueRow("Compatibility", plugin.compatibility.status.rawValue)
                        if let reason = plugin.compatibility.reasons.first?.message {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !plugin.manifest.authors.isEmpty {
                        valueRow("Authors", plugin.manifest.authors.joined(separator: ", "))
                    }
                }

                if let domains = plugin.manifest.domains, !domains.isEmpty {
                    Section("Mirror Domain") {
                        Picker("Domain", selection: Binding(
                            get: { plugin.selectedDomainURL ?? domains.first?.url ?? plugin.manifest.baseURL },
                            set: { value in
                                guard canAdminister else { return }
                                Task {
                                    do { try await manager.setSelectedDomain(packageName: packageName, domainURL: value) }
                                    catch { errorMessage = error.localizedDescription }
                                }
                            }
                        )) {
                            ForEach(domains, id: \.url) { domain in
                                Text(domain.name).tag(domain.url)
                            }
                        }
                    }
                    .disabled(!canAdminister)
                }

                Section("Source") {
                    valueRow("Installed From", plugin.provenance.kind.rawValue)
                    Text(SkyStreamRemoteURLPolicy.redactedDescription(of: plugin.provenance.repositoryURL ?? plugin.provenance.sourceURL))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if plugin.provenance.frozenAt != nil {
                        Label("Update provenance is frozen", systemImage: "snowflake")
                            .foregroundStyle(.orange)
                    }
                    Button("Check for Update") {
                        guard canAdminister else { return }
                        Task {
                            do { try await manager.updateIfAvailable(packageName: packageName) }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
                    .disabled(
                        !canAdminister
                            || (plugin.provenance.kind != .repository
                                && plugin.provenance.kind != .directArchive)
                            || plugin.provenance.frozenAt != nil
                    )
                }

                if canAdminister {
                    Section {
                        Button("Reset Plugin Preferences") { showResetConfirmation = true }
                        Button("Uninstall Plugin", role: .destructive) { showUninstallConfirmation = true }
                    } footer: {
                        Text("Uninstalling removes the whole package and all of its provider rows.")
                    }
                } else {
                    Section {
                        Text("This is a kids profile, so it can see this plugin but not change or remove it. Switch to a grown-up profile to make those changes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(plugin?.manifest.name ?? "SkyStream Plugin")
        .alert("Reset Preferences?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                guard canAdminister else { return }
                Task {
                    do { try await manager.resetPreferences(packageName: packageName) }
                    catch { errorMessage = error.localizedDescription }
                }
            }
        }
        .alert("Uninstall Plugin?", isPresented: $showUninstallConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Uninstall", role: .destructive) {
                guard canAdminister else { return }
                Task {
                    do {
                        try await manager.uninstall(packageName: packageName)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        } message: {
            Text("This removes the plugin, every sub-provider row, stored preferences, and its local payload.")
        }
        .alert("SkyStream Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private func valueRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct SkyStreamProviderRow: View {
    let provider: SkyStreamProviderDescriptor
    @ObservedObject var manager: SkyStreamPluginManager
    @ObservedObject var healthStore: SourceHealthStore
    var canAdminister = true
    @State private var errorMessage: String?
    @State private var showingSettings = false

    private var currentProvider: SkyStreamProviderDescriptor {
        manager.provider(sourceID: provider.id) ?? provider
    }

    private var healthState: SourceHealthDisplayState {
        guard currentProvider.isEnabled else { return .unchecked }
        return healthStore.displayStates[provider.id] ?? .unchecked
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                toggleProvider()
            } label: {
                HStack(spacing: 12) {
                    SkyStreamIconView(
                        rawURL: currentProvider.iconURL,
                        size: 40,
                        fallbackSystemName: "shippingbox.fill"
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(currentProvider.displayName)
                            .font(.headline)
                        Text(providerSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        healthLabel
                    }
                    Spacer()
                    if currentProvider.isEnabled {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if canAdminister {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Settings for \(currentProvider.displayName)")
            }
        }
        .sheet(isPresented: $showingSettings) {
            NavigationView {
                SkyStreamPluginSettingsView(packageName: currentProvider.packageName)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showingSettings = false }
                        }
                    }
            }
            .navigationViewStyle(StackNavigationViewStyle())
        }
        .alert("SkyStream Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var providerSubtitle: String {
        currentProvider.compatibility.status == .untested
            ? "SkyStream"
            : "SkyStream • \(currentProvider.compatibility.status.rawValue)"
    }

    private func toggleProvider() {
        Task {
            do {
                try await manager.setProviderEnabled(
                    sourceID: currentProvider.id,
                    enabled: !currentProvider.isEnabled
                )
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var healthLabel: some View {
        switch healthState {
        case .healthy:
            Label("Reachable", systemImage: "checkmark.circle")
                .font(.caption2)
                .foregroundStyle(.green)
        case .warning(let reason), .playbackIssue(let reason):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
                .lineLimit(1)
        case .stale:
            Label("Health check pending", systemImage: "clock")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .unchecked:
            EmptyView()
        }
    }
}
#endif
