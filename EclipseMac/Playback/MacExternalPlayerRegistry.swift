#if os(macOS)
import AppKit
import Foundation

struct MacExternalPlayerApplication: Identifiable {
    let id: String
    let name: String
    let applicationURL: URL
}

enum MacExternalPlaybackPolicy {
    static func allows(url: URL, hasHeaders: Bool, hasProxyOwnership: Bool,
                       sourceKind: PlaybackSourceKind?, autoMode: Bool, watchTogether: Bool) -> Bool {
        guard !hasHeaders, !hasProxyOwnership, sourceKind != .skyStream, sourceKind != .nuvio, !autoMode, !watchTogether else { return false }
        if url.isFileURL { return true }
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        return host != "localhost" && host != "::1" && host != "[::1]" && !host.hasPrefix("127.")
    }
}

@MainActor
final class MacExternalPlayerRegistry {
    static let shared = MacExternalPlayerRegistry()
    static let selectedBundleIdentifierKey = "macExternalPlayerBundleIdentifier"

    private struct PlaybackLease {
        let processIdentifier: pid_t
        let securityScopedURL: URL?
        let downloadLease: DownloadStorageLease?
    }

    private var playbackLeases: [PlaybackLease] = []
    private var terminationObserver: NSObjectProtocol?

    private init() {
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
                guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                Task { @MainActor in self?.release(processIdentifier: application.processIdentifier) }
            }
    }

    var installedApplications: [MacExternalPlayerApplication] {
        [("com.colliderli.iina", "IINA"), ("org.videolan.vlc", "VLC"),
         ("com.firecore.infuse", "Infuse"), ("com.firecore.infuse-pro", "Infuse Pro"),
         ("com.kanmuguoji.vidhub", "VidHub")].compactMap { identifier, name in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier).map {
                MacExternalPlayerApplication(id: identifier, name: name, applicationURL: $0)
            }
        }
    }

    func handoffIfSelected(_ request: PlaybackRequest) async -> Bool {
        guard request.externalAudioTracks.isEmpty,
              let selected = UserDefaults.standard.string(forKey: Self.selectedBundleIdentifierKey), !selected.isEmpty,
              MacExternalPlaybackPolicy.allows(url: request.url, hasHeaders: !request.headers.isEmpty,
                  hasProxyOwnership: request.launchContext?.ephemeralProxyOwnership != nil,
                  sourceKind: request.launchContext?.sourceKind,
                  autoMode: request.launchContext?.autoMode == true,
                  watchTogether: WatchTogetherCoordinator.shared.playbackHandoffIdentity.sessionID != nil),
              let application = installedApplications.first(where: { $0.id == selected }) else { return false }
        let scoped = request.url.isFileURL && request.url.startAccessingSecurityScopedResource()
        let downloadLease: DownloadStorageLease?
        if request.url.isFileURL, let item = DownloadManager.shared.completedDownloads.first(where: {
            DownloadManager.shared.localFileURL(for: $0)?.standardizedFileURL == request.url.standardizedFileURL
        }) {
            guard let lease = try? DownloadManager.shared.acquirePlaybackLease(for: item) else {
                if scoped { request.url.stopAccessingSecurityScopedResource() }
                return false
            }
            downloadLease = lease
        } else { downloadLease = nil }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        let opened: NSRunningApplication? = await withCheckedContinuation { continuation in
            NSWorkspace.shared.open([request.url], withApplicationAt: application.applicationURL,
                configuration: configuration) { running, _ in continuation.resume(returning: running) }
        }
        guard let opened else {
            if scoped { request.url.stopAccessingSecurityScopedResource() }
            downloadLease?.close()
            return false
        }
        playbackLeases.append(.init(processIdentifier: opened.processIdentifier,
            securityScopedURL: scoped ? request.url : nil, downloadLease: downloadLease))
        if opened.isTerminated { release(processIdentifier: opened.processIdentifier) }
        return true
    }

    func releaseAllForTermination() {
        let releases = playbackLeases
        playbackLeases.removeAll()
        releases.forEach {
            $0.securityScopedURL?.stopAccessingSecurityScopedResource()
            $0.downloadLease?.close()
        }
    }

    private func release(processIdentifier: pid_t) {
        let releases = playbackLeases.filter { $0.processIdentifier == processIdentifier }
        playbackLeases.removeAll { $0.processIdentifier == processIdentifier }
        releases.forEach {
            $0.securityScopedURL?.stopAccessingSecurityScopedResource()
            $0.downloadLease?.close()
        }
    }
}
#endif
