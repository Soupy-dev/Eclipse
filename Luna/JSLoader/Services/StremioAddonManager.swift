//
//  StremioAddonManager.swift
//  Luna
//
//  Created by Soupy on 2026.
//

import CryptoKit
import Foundation

@MainActor
class StremioAddonManager: ObservableObject {
    static let shared = StremioAddonManager()

    @Published var addons: [StremioAddon] = []
    @Published var isDownloading = false

    var activeAddons: [StremioAddon] {
        addons.filter { $0.isActive }
    }

    private init() {
        loadAddons()
    }

    // MARK: - Load

    func loadAddons() {
        addons = StremioAddonStore.shared.getAddons()
    }

    // MARK: - Add Addon

    func addAddon(from url: String) async throws {
        isDownloading = true
        defer { isDownloading = false }

        let manifest = try await StremioClient.shared.fetchManifest(from: url)

        guard manifest.supportsStreams else {
            throw StremioAddonError.noStreamSupport
        }

        // Check for duplicate by manifest id
        if addons.contains(where: { $0.manifest.id == manifest.id }) {
            throw StremioAddonError.alreadyExists
        }

        let id = generateAddonUUID(manifest: manifest)
        let manifestData = try JSONEncoder().encode(manifest)
        let manifestJSON = String(data: manifestData, encoding: .utf8) ?? ""

        // Normalize the URL
        var configuredURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if configuredURL.hasSuffix("/manifest.json") {
            configuredURL = String(configuredURL.dropLast("/manifest.json".count))
        }
        if configuredURL.hasSuffix("/") {
            configuredURL = String(configuredURL.dropLast())
        }

        StremioAddonStore.shared.storeAddon(
            id: id,
            configuredURL: configuredURL,
            manifestJSON: manifestJSON,
            isActive: true
        )
        AutoModeSourceSelection.appendSourceIfNeeded("stremio:\(id.uuidString)")

        loadAddons()
        Logger.shared.log("Stremio: Added addon '\(manifest.name)' (\(manifest.id))", type: "Stremio")
    }

    // MARK: - Remove Addon

    func removeAddon(_ addon: StremioAddon) {
        StremioAddonStore.shared.remove(addon)
        loadAddons()
    }

    // MARK: - Toggle Active

    func setAddonState(_ addon: StremioAddon, isActive: Bool) {
        let manifestData = (try? JSONEncoder().encode(addon.manifest)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        StremioAddonStore.shared.storeAddon(
            id: addon.id,
            configuredURL: addon.configuredURL,
            manifestJSON: manifestData,
            isActive: isActive
        )
        loadAddons()
    }

    // MARK: - Reconfigure

    func reconfigureAddon(_ addon: StremioAddon, newURL: String) async throws {
        let manifest = try await StremioClient.shared.fetchManifest(from: newURL)

        guard manifest.supportsStreams else {
            throw StremioAddonError.noStreamSupport
        }

        var configuredURL = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if configuredURL.hasSuffix("/manifest.json") {
            configuredURL = String(configuredURL.dropLast("/manifest.json".count))
        }
        if configuredURL.hasSuffix("/") {
            configuredURL = String(configuredURL.dropLast())
        }

        let manifestData = try JSONEncoder().encode(manifest)
        let manifestJSON = String(data: manifestData, encoding: .utf8) ?? ""

        StremioAddonStore.shared.storeAddon(
            id: addon.id,
            configuredURL: configuredURL,
            manifestJSON: manifestJSON,
            isActive: addon.isActive
        )

        loadAddons()
        Logger.shared.log("Stremio: Reconfigured addon '\(manifest.name)' (\(manifest.id))", type: "Stremio")
    }

    // MARK: - Reorder

    func moveAddons(fromOffsets: IndexSet, toOffset: Int) {
        var mutable = addons
        mutable.move(fromOffsets: fromOffsets, toOffset: toOffset)

        let entities = StremioAddonStore.shared.getEntities()
        for (index, addon) in mutable.enumerated() {
            if let entity = entities.first(where: { $0.id == addon.id }) {
                entity.sortIndex = Int64(index)
            }
        }

        StremioAddonStore.shared.save()
        loadAddons()
    }

    // MARK: - Refresh Manifests

    func refreshAddons() async {
        for addon in addons {
            do {
                let manifest = try await StremioClient.shared.fetchManifest(from: addon.configuredURL)
                let manifestData = try JSONEncoder().encode(manifest)
                let manifestJSON = String(data: manifestData, encoding: .utf8) ?? ""

                StremioAddonStore.shared.storeAddon(
                    id: addon.id,
                    configuredURL: addon.configuredURL,
                    manifestJSON: manifestJSON,
                    isActive: addon.isActive
                )

                Logger.shared.log("Stremio: Refreshed addon '\(manifest.name)'", type: "Stremio")
            } catch {
                Logger.shared.log("Stremio: Failed to refresh '\(addon.manifest.name)': \(error.localizedDescription)", type: "Stremio")
            }
        }

        loadAddons()
    }

    // MARK: - Fetch Streams from All Active Addons

    struct AddonStreamResult: Identifiable {
        let id = UUID()
        let addon: StremioAddon
        let streams: [StremioStream]
    }

    /// Fetches streams from all active addons for a given piece of content.
    /// Returns results as they come in via the callback, similar to progressive JS search.
    func fetchStreamsFromAddons(
        tmdbId: Int,
        imdbId: String?,
        type: String,
        season: Int?,
        episode: Int?,
        onResult: @escaping (StremioAddon, [StremioStream]) -> Void,
        onComplete: @escaping () -> Void
    ) async {
        let active = activeAddons
        Logger.shared.log("Stremio: fetchStreamsFromAddons — \(active.count) active addon(s), tmdbId=\(tmdbId) imdbId=\(imdbId ?? "nil") type=\(type) s=\(season?.description ?? "nil") e=\(episode?.description ?? "nil")", type: "Stremio")
        guard !active.isEmpty else {
            Logger.shared.log("Stremio: No active addons, skipping", type: "Stremio")
            onComplete()
            return
        }

        let client = StremioClient.shared
        let maxConcurrent = 2

        await withTaskGroup(of: (StremioAddon, [StremioStream])?.self) { group in
            var nextIndex = 0

            // Seed the group with the first batch
            while nextIndex < active.count && nextIndex < maxConcurrent {
                let addon = active[nextIndex]
                group.addTask {
                    await Self.fetchStreamsForAddon(addon, client: client, tmdbId: tmdbId, imdbId: imdbId, type: type, season: season, episode: episode)
                }
                nextIndex += 1
            }

            // As each completes, report it and start the next one
            for await result in group {
                if let (addon, streams) = result {
                    await MainActor.run {
                        onResult(addon, streams)
                    }
                }

                if nextIndex < active.count {
                    let addon = active[nextIndex]
                    group.addTask {
                        await Self.fetchStreamsForAddon(addon, client: client, tmdbId: tmdbId, imdbId: imdbId, type: type, season: season, episode: episode)
                    }
                    nextIndex += 1
                }
            }
        }

        onComplete()
    }

    // MARK: - Helpers

    private static func fetchStreamsForAddon(
        _ addon: StremioAddon,
        client: StremioClient,
        tmdbId: Int,
        imdbId: String?,
        type: String,
        season: Int?,
        episode: Int?
    ) async -> (StremioAddon, [StremioStream])? {
        Logger.shared.log("Stremio: Starting fetch for addon '\(addon.manifest.name)' baseURL=\(addon.configuredURL)", type: "Stremio")

        guard let contentId = client.buildContentId(
            tmdbId: tmdbId,
            imdbId: imdbId,
            type: type,
            season: season,
            episode: episode,
            addon: addon
        ) else {
            Logger.shared.log("Stremio: No valid content ID for \(addon.manifest.name) — skipping", type: "Stremio")
            return (addon, [])
        }

        Logger.shared.log("Stremio: \(addon.manifest.name) requesting streams with contentId='\(contentId)'", type: "Stremio")

        do {
            let streams = try await client.fetchStreams(
                baseURL: addon.configuredURL,
                type: type,
                id: contentId
            )
            Logger.shared.log("Stremio: \(addon.manifest.name) returned \(streams.count) stream(s) for '\(contentId)'", type: "Stremio")
            return (addon, streams)
        } catch {
            Logger.shared.log("Stremio: \(addon.manifest.name) FAILED with id '\(contentId)': \(error.localizedDescription)", type: "Stremio")
            return (addon, [])
        }
    }

    private func generateAddonUUID(manifest: StremioManifest) -> UUID {
        let input = manifest.id
        let hash = SHA256.hash(data: Data(input.utf8))
        let hashBytes = Array(hash)
        return UUID(uuid: (
            hashBytes[0], hashBytes[1], hashBytes[2], hashBytes[3],
            hashBytes[4], hashBytes[5], hashBytes[6], hashBytes[7],
            hashBytes[8], hashBytes[9], hashBytes[10], hashBytes[11],
            hashBytes[12], hashBytes[13], hashBytes[14], hashBytes[15]
        ))
    }

    enum StremioAddonError: LocalizedError {
        case noStreamSupport
        case alreadyExists

        var errorDescription: String? {
            switch self {
            case .noStreamSupport: return "This addon does not support streams"
            case .alreadyExists: return "This addon is already installed"
            }
        }
    }
}
