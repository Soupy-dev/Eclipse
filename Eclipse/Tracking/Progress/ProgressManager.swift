//
//  ProgressManager.swift
//  Sora
//
//  Created by Francesco on 27/08/25.
//

import Foundation
import AVFoundation
import Combine
#if canImport(UIKit)
import UIKit
#endif

struct ShowMetadata: Codable {
    let showId: Int
    var title: String
    var posterURL: String?
}

struct ProgressData: Codable {
    var movieProgress: [MovieProgressEntry] = []
    var episodeProgress: [EpisodeProgressEntry] = []
    var showMetadata: [Int: ShowMetadata] = [:]
    var hiddenUpNextShowIds: Set<Int> = []

    private enum CodingKeys: String, CodingKey {
        case movieProgress
        case episodeProgress
        case showMetadata
        case hiddenUpNextShowIds
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        movieProgress = try container.decodeIfPresent([MovieProgressEntry].self, forKey: .movieProgress) ?? []
        episodeProgress = try container.decodeIfPresent([EpisodeProgressEntry].self, forKey: .episodeProgress) ?? []
        showMetadata = try container.decodeIfPresent([Int: ShowMetadata].self, forKey: .showMetadata) ?? [:]
        hiddenUpNextShowIds = try container.decodeIfPresent(Set<Int>.self, forKey: .hiddenUpNextShowIds) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(movieProgress, forKey: .movieProgress)
        try container.encode(episodeProgress, forKey: .episodeProgress)
        try container.encode(showMetadata, forKey: .showMetadata)
        try container.encode(hiddenUpNextShowIds.sorted(), forKey: .hiddenUpNextShowIds)
    }

    mutating func updateMovie(_ entry: MovieProgressEntry) {
        if let index = movieProgress.firstIndex(where: { $0.id == entry.id }) {
            movieProgress[index] = entry
        } else {
            movieProgress.append(entry)
        }
    }

    mutating func updateEpisode(_ entry: EpisodeProgressEntry) {
        if let index = episodeProgress.firstIndex(where: { $0.id == entry.id }) {
            episodeProgress[index] = entry
        } else {
            episodeProgress.append(entry)
        }
    }

    mutating func updateShowMetadata(showId: Int, title: String, posterURL: String?) {
        showMetadata[showId] = ShowMetadata(showId: showId, title: title, posterURL: posterURL)
    }

    func findMovie(id: Int) -> MovieProgressEntry? {
        movieProgress.first { $0.id == id }
    }

    func findEpisode(showId: Int, season: Int, episode: Int) -> EpisodeProgressEntry? {
        episodeProgress.first { $0.showId == showId && $0.seasonNumber == season && $0.episodeNumber == episode }
    }

    func getShowMetadata(showId: Int) -> ShowMetadata? {
        showMetadata[showId]
    }
}

struct MovieProgressEntry: Codable, Identifiable {
    let id: Int
    let title: String
    var posterURL: String? = nil
    var currentTime: Double = 0
    var totalDuration: Double = 0
    var isWatched: Bool = false
    var lastUpdated: Date = Date()
    var lastServiceId: UUID? = nil
    var lastHref: String? = nil

    var lastSourceId: String? = nil

    var lastContentReference: ProviderContentReference? = nil

    var progress: Double {
        guard totalDuration > 0 else { return 0 }
        return min(currentTime / totalDuration, 1.0)
    }
}

struct EpisodeProgressEntry: Codable, Identifiable {
    let id: String
    let showId: Int
    let seasonNumber: Int
    let episodeNumber: Int
    var currentTime: Double = 0
    var totalDuration: Double = 0
    var isWatched: Bool = false
    var lastUpdated: Date = Date()
    var lastServiceId: UUID? = nil
    var lastHref: String? = nil
    var lastSourceId: String? = nil
    var lastContentReference: ProviderContentReference? = nil
    var playbackContext: EpisodePlaybackContext? = nil
    var isAnime: Bool? = nil

    var progress: Double {
        guard totalDuration > 0 else { return 0 }
        return min(currentTime / totalDuration, 1.0)
    }

    init(showId: Int, seasonNumber: Int, episodeNumber: Int) {
        self.id = "ep_\(showId)_s\(seasonNumber)_e\(episodeNumber)"
        self.showId = showId
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
    }
}

/// One policy is used before progress reaches local JSON, backups, or a
/// provider-neutral cloud envelope. Invalid anime mapping metadata is removed
/// without discarding otherwise valid watch progress.
enum ProgressPersistencePolicy {
    static let maximumPersistedStoreBytes = 32 * 1_024 * 1_024
    static let maximumIdentifier = Int(Int32.max)
    static let maximumCoordinate = 1_000_000
    static let maximumBulkEpisodeMutationCount = 10_000
    static let maximumDuration: TimeInterval = 30 * 24 * 60 * 60

    static func bulkEpisodeMutationIsSafe(
        showID: Int,
        seasonNumber: Int,
        throughEpisode: Int
    ) -> Bool {
        validPositiveIdentifier(showID)
            && (0...maximumCoordinate).contains(seasonNumber)
            && (1...maximumBulkEpisodeMutationCount).contains(throughEpisode)
    }

    static func exactEpisodeMutationNumbers(
        showID: Int,
        seasonNumber: Int,
        episodeNumbers: [Int]
    ) -> [Int]? {
        guard validPositiveIdentifier(showID),
              (0...maximumCoordinate).contains(seasonNumber),
              !episodeNumbers.isEmpty,
              episodeNumbers.count <= maximumBulkEpisodeMutationCount,
              episodeNumbers.allSatisfy({ (1...maximumCoordinate).contains($0) }) else {
            return nil
        }
        let result = Array(Set(episodeNumbers)).sorted()
        return result.isEmpty ? nil : result
    }

    static func previousEpisodeMutationIsSafe(
        showID: Int,
        seasonNumber: Int,
        episodeNumber: Int
    ) -> Bool {
        validPositiveIdentifier(showID)
            && (0...maximumCoordinate).contains(seasonNumber)
            && (2...(maximumBulkEpisodeMutationCount + 1)).contains(episodeNumber)
    }

    static func sanitized(
        _ source: ProgressData,
        preservingDeviceLocalReferences: Bool
    ) -> ProgressData {
        let now = Date()
        var movieByID: [Int: MovieProgressEntry] = [:]
        for rawEntry in source.movieProgress {
            guard validPositiveIdentifier(rawEntry.id),
                  isPlausibleClock(rawEntry.lastUpdated, now: now),
                  let times = sanitizedTimes(
                    currentTime: rawEntry.currentTime,
                    totalDuration: rawEntry.totalDuration
                  ) else {
                continue
            }
            var entry = rawEntry
            entry.currentTime = times.currentTime
            entry.totalDuration = times.totalDuration
            if !preservingDeviceLocalReferences {
                entry.lastHref = nil
                entry.lastContentReference = nil
            }
            if let existing = movieByID[entry.id] {
                if entryIsPreferred(entry, over: existing) {
                    movieByID[entry.id] = entry
                }
            } else {
                movieByID[entry.id] = entry
            }
        }

        var episodeByID: [String: EpisodeProgressEntry] = [:]
        for rawEntry in source.episodeProgress {
            guard validPositiveIdentifier(rawEntry.showId),
                  validSeasonCoordinate(rawEntry.seasonNumber),
                  (1...maximumCoordinate).contains(rawEntry.episodeNumber),
                  isPlausibleClock(rawEntry.lastUpdated, now: now),
                  let times = sanitizedTimes(
                    currentTime: rawEntry.currentTime,
                    totalDuration: rawEntry.totalDuration
                  ) else {
                continue
            }
            let canonicalID = "ep_\(rawEntry.showId)_s\(rawEntry.seasonNumber)_e\(rawEntry.episodeNumber)"
            guard rawEntry.id == canonicalID else { continue }

            var entry = rawEntry
            entry.currentTime = times.currentTime
            entry.totalDuration = times.totalDuration
            if let context = entry.playbackContext,
               sanitizedPlaybackContext(
                context,
                expectedLocalEpisodeNumber: entry.episodeNumber
               ) == nil {
                entry.playbackContext = nil
            }
            if !preservingDeviceLocalReferences {
                entry.lastHref = nil
                entry.lastContentReference = nil
            }
            if let existing = episodeByID[entry.id] {
                if entryIsPreferred(entry, over: existing) {
                    episodeByID[entry.id] = entry
                }
            } else {
                episodeByID[entry.id] = entry
            }
        }

        var result = ProgressData()
        result.movieProgress = movieByID.values.sorted { $0.id < $1.id }
        result.episodeProgress = episodeByID.values.sorted { lhs, rhs in
            if lhs.showId != rhs.showId { return lhs.showId < rhs.showId }
            if lhs.seasonNumber != rhs.seasonNumber { return lhs.seasonNumber < rhs.seasonNumber }
            return lhs.episodeNumber < rhs.episodeNumber
        }
        result.showMetadata = Dictionary(
            source.showMetadata.compactMap { showID, metadata -> (Int, ShowMetadata)? in
                guard validPositiveIdentifier(showID), metadata.showId == showID else { return nil }
                return (showID, metadata)
            },
            uniquingKeysWith: { _, incoming in incoming }
        )
        result.hiddenUpNextShowIds = Set(
            source.hiddenUpNextShowIds.filter(validPositiveIdentifier)
        )
        return result
    }

    static func sanitizedTimes(
        currentTime: Double,
        totalDuration: Double
    ) -> (currentTime: Double, totalDuration: Double)? {
        guard currentTime.isFinite,
              totalDuration.isFinite,
              currentTime >= 0,
              totalDuration >= 0,
              currentTime <= maximumDuration,
              totalDuration <= maximumDuration else {
            return nil
        }
        guard totalDuration > 0 else {
            return currentTime == 0 ? (0, 0) : nil
        }
        return (currentTime, max(totalDuration, currentTime))
    }

    static func validPositiveIdentifier(_ value: Int) -> Bool {
        (1...maximumIdentifier).contains(value)
    }

    static func validSeasonCoordinate(_ value: Int) -> Bool {
        (0...maximumCoordinate).contains(value)
            || (value > Int.min && (1...maximumIdentifier).contains(-value))
    }

    static func sanitizedPlaybackContext(
        _ context: EpisodePlaybackContext,
        expectedLocalEpisodeNumber: Int? = nil
    ) -> EpisodePlaybackContext? {
        guard (-maximumCoordinate...maximumCoordinate).contains(context.localSeasonNumber),
              (1...maximumCoordinate).contains(context.localEpisodeNumber),
              expectedLocalEpisodeNumber.map({ $0 == context.localEpisodeNumber }) ?? true,
              validSignedProviderIdentifier(context.anilistMediaId),
              validOptionalPositiveIdentifier(context.canonicalAniListMediaId),
              validOptionalPositiveIdentifier(context.malMediaId),
              validOptionalPositiveIdentifier(context.kitsuMediaId),
              validOptionalCoordinate(context.tmdbSeasonNumber, allowsZero: true),
              validOptionalCoordinate(context.tmdbEpisodeNumber, allowsZero: false),
              validOptionalSignedCoordinate(context.tmdbEpisodeOffset),
              validOptionalCoordinate(context.animeAbsoluteEpisodeNumber, allowsZero: false),
              validOptionalCoordinate(context.animeSeasonEpisodeCount, allowsZero: false) else {
            return nil
        }
        if let offset = context.tmdbEpisodeOffset {
            let (resolved, overflow) = offset.addingReportingOverflow(context.localEpisodeNumber)
            guard !overflow, (1...maximumCoordinate).contains(resolved) else { return nil }
        }
        return context
    }

    static func progressDataIsSafe(_ source: ProgressData) -> Bool {
        canonicalData(source) == canonicalData(
            sanitized(source, preservingDeviceLocalReferences: true)
        )
    }

    private static func validSignedProviderIdentifier(_ value: Int?) -> Bool {
        guard let value else { return true }
        return value != 0
            && value != Int.min
            && (-maximumIdentifier...maximumIdentifier).contains(value)
    }

    private static func validOptionalPositiveIdentifier(_ value: Int?) -> Bool {
        value.map(validPositiveIdentifier) ?? true
    }

    private static func validOptionalCoordinate(_ value: Int?, allowsZero: Bool) -> Bool {
        guard let value else { return true }
        return allowsZero
            ? (0...maximumCoordinate).contains(value)
            : (1...maximumCoordinate).contains(value)
    }

    private static func validOptionalSignedCoordinate(_ value: Int?) -> Bool {
        guard let value else { return true }
        return (-maximumCoordinate...maximumCoordinate).contains(value)
    }

    private static func isPlausibleClock(_ value: Date, now: Date) -> Bool {
        let seconds = value.timeIntervalSince1970
        return seconds.isFinite
            && seconds >= 0
            && seconds <= now.timeIntervalSince1970
                + MediaStateEnvelopeValidator.maximumFutureClockSkew
    }

    private static func entryIsPreferred<Entry: Encodable>(
        _ candidate: Entry,
        over existing: Entry
    ) -> Bool {
        let candidateDate: Date
        let existingDate: Date
        if let candidate = candidate as? MovieProgressEntry,
           let existing = existing as? MovieProgressEntry {
            candidateDate = candidate.lastUpdated
            existingDate = existing.lastUpdated
        } else if let candidate = candidate as? EpisodeProgressEntry,
                  let existing = existing as? EpisodeProgressEntry {
            candidateDate = candidate.lastUpdated
            existingDate = existing.lastUpdated
        } else {
            return false
        }
        if candidateDate != existingDate { return candidateDate > existingDate }
        guard let candidateData = canonicalData(candidate),
              let existingData = canonicalData(existing) else { return false }
        return existingData.lexicographicallyPrecedes(candidateData)
    }

    private static func canonicalData<Value: Encodable>(_ value: Value) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(value)
    }
}

enum ContinueWatchingRemovalTarget {
    case localProgress
    case localUpNextShow
    case traktPlayback(Int)
    case traktUpNextShow
    case none

    var isRemovable: Bool {
        switch self {
        case .none:
            return false
        case .localProgress, .localUpNextShow, .traktPlayback, .traktUpNextShow:
            return true
        }
    }
}

struct ContinueWatchingItem: Identifiable {
    let id: String
    let tmdbId: Int
    let isMovie: Bool
    let title: String
    let posterURL: String?
    let progress: Double
    let lastUpdated: Date
    let seasonNumber: Int?
    let episodeNumber: Int?
    let currentTime: Double
    let totalDuration: Double
    let playbackContext: EpisodePlaybackContext?
    let isAnime: Bool
    let statusText: String?
    let isWatchNext: Bool
    let traktPlaybackId: Int?
    var removalTarget: ContinueWatchingRemovalTarget = .localProgress

    var remainingTime: String {
        guard totalDuration.isFinite, currentTime.isFinite else { return "0 min left" }
        let remaining = min(
            ProgressPersistencePolicy.maximumDuration,
            max(0, totalDuration - currentTime)
        )
        let minutes = Int(exactly: (remaining / 60).rounded(.down)) ?? 0
        if minutes < 60 {
            return "\(minutes) min left"
        } else {
            let hours = minutes / 60
            let mins = minutes % 60
            return mins > 0 ? "\(hours)h \(mins)m left" : "\(hours)h left"
        }
    }

    var displayStatus: String {
        statusText ?? remainingTime
    }
}

final class ProgressManager: ObservableObject {
    static let shared = ProgressManager()

    struct ProfileMutationAuthority: Equatable {
        let profileID: UUID
        let storeGeneration: UInt64
    }

    private let fileManager = FileManager.default
    private var progressData: ProgressData = ProgressData()

    private var progressFileURL: URL
    private var activeProfileID: UUID
    private let debounceInterval: TimeInterval = 2.0
    private let debounceMaximumLatency: TimeInterval = 20.0
    private var debounceTask: Task<Void, Never>?
    private var firstUnflushedChangeAt: Date?
    private let debounceLock = NSLock()
    private let accessQueue = DispatchQueue(label: "app.eclipse.soupy.progress-manager", attributes: .concurrent)
    private let accessQueueKey = DispatchSpecificKey<UInt8>()

    private var storeGeneration: UInt64 = 0

    private var storeWriteSequence: UInt64 = 0
    private var durationShrinkWarningKeys: Set<String> = []
    private static let continueWatchingMinimumProgress = 0.05
    private static let watchedProgressThreshold = 0.85

    private static let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    @Published private(set) var movieProgressList: [MovieProgressEntry] = []
    @Published private(set) var episodeProgressList: [EpisodeProgressEntry] = []

    private init() {
        let profileID = ProfileManager.shared.activeProfileID
        self.activeProfileID = profileID
        self.progressFileURL = Self.progressFileURL(for: profileID)
        accessQueue.setSpecific(key: accessQueueKey, value: 1)
        Self.migrateLegacyStoreIfNeeded()
        loadProgressData()
#if canImport(UIKit)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.flushPendingSave()
        }
#endif
    }

    private static let legacyFileName = "ProgressData.json"

    static func progressFileURL(for profileID: UUID) -> URL {
        documentsDirectory.appendingPathComponent(
            ProfileScopedStorage.documentFileName(
                base: "ProgressData",
                fileExtension: "json",
                profileID: profileID
            )
        )
    }

    private static func unreadableMarkerURL(for profileID: UUID) -> URL {
        documentsDirectory.appendingPathComponent(
            "ProgressData-\(ProfileScopedStorage.token(for: profileID)).unreadable.marker"
        )
    }

    private static func markStoreUnreadable(for profileID: UUID) {
        try? Data("unreadable\n".utf8).write(
            to: unreadableMarkerURL(for: profileID),
            options: .atomic
        )
    }

    private static func migrateLegacyStoreIfNeeded() {
        ProfileScopedStorage.migrateLegacyStoreIfNeeded(marker: "progress") {
            let fileManager = FileManager.default
            let legacyURL = documentsDirectory.appendingPathComponent(legacyFileName)
            let destinationURL = progressFileURL(for: ProfileManager.defaultProfileID)
            guard fileManager.fileExists(atPath: legacyURL.path),
                  !fileManager.fileExists(atPath: destinationURL.path) else { return }
            do {
                try fileManager.moveItem(at: legacyURL, to: destinationURL)
                Logger.shared.log(
                    "ProgressManager: migrated legacy store into the default profile namespace",
                    type: "Progress"
                )
            } catch {
                Logger.shared.log(
                    "ProgressManager: legacy store migration failed: \(error.localizedDescription)",
                    type: "Error"
                )

                throw error
            }
        }
    }

    func switchProfile(to profileID: UUID) {
        guard profileID != activeProfileID else { return }
        flushPendingSave()

        accessQueue.sync(flags: .barrier) {

            if self.activeStoreLoadFailed {

                self.inactiveProfileCache.removeValue(forKey: self.activeProfileID)
            } else {
                self.inactiveProfileCache[self.activeProfileID] = self.progressData
            }
            self.inactiveProfileCache.removeValue(forKey: profileID)
            self.storeGeneration &+= 1
            self.storeWriteSequence &+= 1
            self.activeProfileID = profileID
            self.progressFileURL = Self.progressFileURL(for: profileID)
            self.progressData = ProgressData()

            self.activeStoreLoadFailed = false
            self.durationShrinkWarningKeys = []
        }
        loadProgressData()

        publishProgressData(accessQueue.sync { self.progressData })
    }

    private var inactiveProfileCache: [UUID: ProgressData] = [:]

    private var activeStoreLoadFailed = false

    func profileMutationAuthority(
        requiredOwner: UUID? = nil
    ) -> ProfileMutationAuthority? {
        let capture = { () -> ProfileMutationAuthority? in
            guard requiredOwner == nil || requiredOwner == self.activeProfileID else {
                return nil
            }
            return ProfileMutationAuthority(
                profileID: self.activeProfileID,
                storeGeneration: self.storeGeneration
            )
        }
        if DispatchQueue.getSpecific(key: accessQueueKey) != nil {
            return capture()
        }
        return accessQueue.sync(execute: capture)
    }

    func profileMutationAuthorityIsCurrent(
        _ authority: ProfileMutationAuthority
    ) -> Bool {
        let validate = {
            Self.profileMutationAuthorityIsCurrent(
                authorityProfileID: authority.profileID,
                authorityGeneration: authority.storeGeneration,
                currentProfileID: self.activeProfileID,
                currentGeneration: self.storeGeneration
            )
        }
        if DispatchQueue.getSpecific(key: accessQueueKey) != nil {
            return validate()
        }
        return accessQueue.sync(execute: validate)
    }

    static func profileMutationAuthorityIsCurrent(
        authorityProfileID: UUID,
        authorityGeneration: UInt64,
        currentProfileID: UUID,
        currentGeneration: UInt64
    ) -> Bool {
        authorityProfileID == currentProfileID
            && authorityGeneration == currentGeneration
    }

    static func storeGenerationAfterAuthoritativeRestore(_ current: UInt64) -> UInt64 {
        current &+ 1
    }

    private func logRejectedMutation(
        _ operation: String,
        authority: ProfileMutationAuthority?
    ) {
        Logger.shared.log(
            "ProgressManager: abandoned \(operation); its profile authority is no longer current (owner=\(authority?.profileID.uuidString ?? "unavailable"))",
            type: "Progress"
        )
    }

    func progressData(forProfile profileID: UUID) -> ProgressData? {
        if profileID == activeProfileID {

            return accessQueue.sync {
                self.activeStoreLoadFailed
                    ? nil
                    : ProgressPersistencePolicy.sanitized(
                        self.progressData,
                        preservingDeviceLocalReferences: true
                    )
            }
        }
        guard !fileManager.fileExists(atPath: Self.unreadableMarkerURL(for: profileID).path) else {
            return nil
        }
        if let cached = accessQueue.sync(execute: { inactiveProfileCache[profileID] }) {
            return cached
        }
        let url = Self.progressFileURL(for: profileID)
        guard fileManager.fileExists(atPath: url.path) else {

            let empty = ProgressData()
            accessQueue.sync(flags: .barrier) {
                self.inactiveProfileCache[profileID] = empty
            }
            return empty
        }
        let decoded: ProgressData
        do {
            let data = try BoundedLocalStoreReader.read(
                from: url,
                maximumBytes: ProgressPersistencePolicy.maximumPersistedStoreBytes
            )
            decoded = try JSONDecoder().decode(ProgressData.self, from: data)
        } catch {
            Self.markStoreUnreadable(for: profileID)
            Logger.shared.log(
                "ProgressManager: store for profile \(profileID) exists but could not be read: \(error.localizedDescription)",
                type: "Error"
            )
            return nil
        }
        let sanitized = ProgressPersistencePolicy.sanitized(
            decoded,
            preservingDeviceLocalReferences: true
        )
        guard repairDecodedStoreIfNeeded(
            decoded: decoded,
            sanitized: sanitized,
            destination: url,
            profileID: profileID
        ) else { return nil }
        accessQueue.sync(flags: .barrier) {
            self.inactiveProfileCache[profileID] = sanitized
        }
        return sanitized
    }

    @discardableResult
    func applyRestoredProgressData(_ newData: ProgressData, forProfile profileID: UUID) -> Bool {
        let sanitizedData = ProgressPersistencePolicy.sanitized(
            newData,
            preservingDeviceLocalReferences: true
        )
        var restoreError: Error?
        var shouldPublish = false
        accessQueue.sync(flags: .barrier) {
            do {

                if profileID == self.activeProfileID {
                    self.storeWriteSequence &+= 1
                }
                let destination = Self.progressFileURL(for: profileID)
                let data = try JSONEncoder().encode(sanitizedData)
                guard data.count <= ProgressPersistencePolicy.maximumPersistedStoreBytes else {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                try Self.persistAuthoritativeRestoreData(data, to: destination) {
                    try self.preserveUnreadableStoreBeforeAuthoritativeWrite(
                        destination: destination,
                        profileID: profileID
                    )
                    self.preservePreviousStoreIfCatastrophicShrink(
                        newByteCount: data.count,
                        destination: destination,
                        profileID: profileID
                    )
                }
                try Self.clearUnreadableMarker(for: profileID)
                if profileID == self.activeProfileID {
                    // A restore is an authoritative replacement of the active
                    // store. Revoke work captured from the pre-restore
                    // generation even though the profile UUID did not change.
                    self.storeGeneration = Self.storeGenerationAfterAuthoritativeRestore(
                        self.storeGeneration
                    )
                    self.progressData = sanitizedData
                    self.activeStoreLoadFailed = false
                    shouldPublish = true
                } else {
                    self.inactiveProfileCache[profileID] = sanitizedData
                }
            } catch {
                restoreError = error
            }
        }
        if let restoreError {
            Logger.shared.log(
                "ProgressManager: refused a profile restore that could not be persisted: \(restoreError.localizedDescription)",
                type: "Error"
            )
            return false
        }
        if shouldPublish {
            publishProgressData(sanitizedData)
        }
        return true
    }

    func discardStore(forProfile profileID: UUID) {
        guard profileID != activeProfileID else { return }
        try? fileManager.removeItem(at: Self.progressFileURL(for: profileID))
        try? fileManager.removeItem(at: Self.unreadableMarkerURL(for: profileID))
        accessQueue.sync(flags: .barrier) {
            _ = self.inactiveProfileCache.removeValue(forKey: profileID)
        }
    }

    func getProgressData() -> ProgressData {
        return accessQueue.sync {
            return ProgressPersistencePolicy.sanitized(
                self.progressData,
                preservingDeviceLocalReferences: true
            )
        }
    }

    @discardableResult
    func replaceProgressDataForRestore(
        _ newData: ProgressData,
        expectedProfileID: UUID
    ) -> Bool {
        let sanitizedData = ProgressPersistencePolicy.sanitized(
            newData,
            preservingDeviceLocalReferences: true
        )
        guard let captured = captureStoreWriteRequest(authorizing: expectedProfileID) else {
            Logger.shared.log(
                "ProgressManager: discarded a restore before persistence because its profile owner changed",
                type: "Error"
            )
            return false
        }
        let request = StoreWriteRequest(
            profileID: captured.profileID,
            destination: captured.destination,
            generation: captured.generation,
            sequence: captured.sequence,
            snapshot: sanitizedData,

            storeLoadFailed: false
        )
        var restoreError: Error?
        var didRestore = false
        accessQueue.sync(flags: .barrier) {
            guard self.storeWriteRequestTargetsCurrentStore(request) else { return }
            do {
                let data = try JSONEncoder().encode(sanitizedData)
                guard data.count <= ProgressPersistencePolicy.maximumPersistedStoreBytes else {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                try Self.persistAuthoritativeRestoreData(data, to: request.destination) {
                    try self.preserveUnreadableStoreBeforeAuthoritativeWrite(
                        destination: request.destination,
                        profileID: request.profileID
                    )
                    self.preservePreviousStoreIfCatastrophicShrink(
                        newByteCount: data.count,
                        destination: request.destination,
                        profileID: request.profileID
                    )
                }
                try Self.clearUnreadableMarker(for: request.profileID)
                // Prevent delayed playback/tracker work from the state that
                // preceded this same-profile restore from becoming current.
                self.storeGeneration = Self.storeGenerationAfterAuthoritativeRestore(
                    self.storeGeneration
                )
                self.progressData = sanitizedData

                self.activeStoreLoadFailed = false
                didRestore = true
            } catch {
                restoreError = error
            }
        }
        if let restoreError {
            Logger.shared.log(
                "ProgressManager: refused a restore that could not be persisted: \(restoreError.localizedDescription)",
                type: "Error"
            )
            return false
        }
        guard didRestore else {
            Logger.shared.log(
                "ProgressManager: discarded a restore after its profile owner changed",
                type: "Error"
            )
            return false
        }
        publishProgressData(sanitizedData)
        Logger.shared.log("Progress data restored in bulk (\(sanitizedData.movieProgress.count) movies, \(sanitizedData.episodeProgress.count) episodes)", type: "Progress")
        return true
    }

    func bulkMarkEpisodesAsWatched(
        showId: Int,
        seasonNumber: Int,
        throughEpisode: Int,
        owner: UUID? = nil
    ) {
        guard ProgressPersistencePolicy.bulkEpisodeMutationIsSafe(
            showID: showId,
            seasonNumber: seasonNumber,
            throughEpisode: throughEpisode
        ) else { return }
        guard let authority = profileMutationAuthority(requiredOwner: owner) else {
            logRejectedMutation("a bulk watched import", authority: nil)
            return
        }
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            guard self.profileMutationAuthorityIsCurrent(authority) else {
                self.logRejectedMutation("a bulk watched import", authority: authority)
                return
            }
            for e in 1...throughEpisode {
                var entry = self.progressData.findEpisode(showId: showId, season: seasonNumber, episode: e)
                    ?? EpisodeProgressEntry(showId: showId, seasonNumber: seasonNumber, episodeNumber: e)
                guard !entry.isWatched else { continue }
                let safeDuration = entry.totalDuration > 0 ? entry.totalDuration : max(entry.currentTime, 1)
                entry.totalDuration = safeDuration
                entry.isWatched = true
                entry.currentTime = safeDuration
                entry.lastUpdated = Date()
                self.progressData.updateEpisode(entry)
            }
            self.publishCurrentData()
            Logger.shared.log("Bulk marked S\(seasonNumber)E1-E\(throughEpisode) as watched for show \(showId) (import)", type: "Progress")
        }
        saveProgressData()
    }

    private func publishCurrentData() {
        accessQueue.async { [weak self] in
            guard let self = self else { return }
            self.publishProgressData(self.progressData)
        }
    }

    private func publishProgressData(_ snapshot: ProgressData) {
        let movies = snapshot.movieProgress
        let episodes = snapshot.episodeProgress
        DispatchQueue.main.async {
            self.movieProgressList = movies
            self.episodeProgressList = episodes
            NotificationCenter.default.post(name: .progressDataDidChange, object: self)
        }
    }

    private func loadProgressData() {
        let markerURL = Self.unreadableMarkerURL(for: activeProfileID)
        let hasUnreadableMarker = fileManager.fileExists(atPath: markerURL.path)
        guard fileManager.fileExists(atPath: progressFileURL.path) else {
            if hasUnreadableMarker {
                try? Self.clearUnreadableMarker(for: activeProfileID)
                Logger.shared.log(
                    "ProgressManager: cleared a stale unreadable-store marker and started a fresh store",
                    type: "Error"
                )
                return
            }
            Logger.shared.log("Progress file not found, initializing new data", type: "Progress")
            return
        }
        guard !hasUnreadableMarker else {
            accessQueue.sync(flags: .barrier) {
                self.activeStoreLoadFailed = true
            }
            Logger.shared.log(
                "ProgressManager: preserved a previously unreadable store and suspended saves until an authoritative restore",
                type: "Error"
            )
            return
        }

        let data: Data
        do {
            data = try BoundedLocalStoreReader.read(
                from: progressFileURL,
                maximumBytes: ProgressPersistencePolicy.maximumPersistedStoreBytes
            )
        } catch {
            Self.markStoreUnreadable(for: activeProfileID)

            accessQueue.sync(flags: .barrier) {
                self.activeStoreLoadFailed = true
            }
            Logger.shared.log(
                "ProgressManager: store could not be read; leaving it in place and suspending saves: \(error.localizedDescription)",
                type: "Error"
            )
            return
        }
        Logger.shared.log("Progress file size: \(data.count) bytes", type: "Progress")

        do {
            let decoded = try JSONDecoder().decode(ProgressData.self, from: data)
            let sanitized = ProgressPersistencePolicy.sanitized(
                decoded,
                preservingDeviceLocalReferences: true
            )
            let repairSucceeded = repairDecodedStoreIfNeeded(
                decoded: decoded,
                sanitized: sanitized,
                destination: progressFileURL,
                profileID: activeProfileID
            )
            Logger.shared.log("Loaded \(sanitized.episodeProgress.count) episodes from JSON", type: "Progress")
            for ep in sanitized.episodeProgress.prefix(5) {
                Logger.shared.log("  - showId=\(ep.showId) S\(ep.seasonNumber)E\(ep.episodeNumber)", type: "Progress")
            }
            accessQueue.sync(flags: .barrier) {
                self.progressData = sanitized
                self.activeStoreLoadFailed = !repairSucceeded
            }
            publishProgressData(sanitized)
            if repairSucceeded {
                try? Self.clearUnreadableMarker(for: activeProfileID)
            }
            Logger.shared.log("Progress data loaded successfully (\(sanitized.movieProgress.count) movies, \(sanitized.episodeProgress.count) episodes)", type: "Progress")
        } catch {
            Logger.shared.log("Failed to decode progress data: \(error.localizedDescription)", type: "Error")
            accessQueue.sync(flags: .barrier) {

                self.activeStoreLoadFailed = true
            }

            do {

                let quarantineURL = Self.documentsDirectory.appendingPathComponent(
                    "\(sidecarPrefix)unreadable-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.lowercased()).json"
                )
                try fileManager.moveItem(at: progressFileURL, to: quarantineURL)
                try? Self.clearUnreadableMarker(for: activeProfileID)
                accessQueue.sync(flags: .barrier) {
                    self.progressData = ProgressData()
                    self.activeStoreLoadFailed = false
                }
                Logger.shared.log(
                    "ProgressManager: moved undecodable store aside as \(quarantineURL.lastPathComponent) and started a fresh store",
                    type: "Error"
                )
            } catch {
                if !hasUnreadableMarker {
                    try? Data("unreadable\n".utf8).write(to: markerURL, options: .atomic)
                }
                Logger.shared.log(
                    "ProgressManager: could not persist the unreadable-store quarantine: \(error.localizedDescription)",
                    type: "Error"
                )
            }
        }
    }

    private static func clearUnreadableMarker(for profileID: UUID) throws {
        let url = unreadableMarkerURL(for: profileID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Runs all source-preservation work before the atomic replacement. Tests
    /// inject a failed preservation step here to prove that old bytes cannot be
    /// overwritten while an account-isolation journal is still pending.
    static func persistAuthoritativeRestoreData(
        _ data: Data,
        to destination: URL,
        write: (Data, URL) throws -> Void = { data, destination in
            try data.write(to: destination, options: .atomic)
        },
        beforeReplacing: () throws -> Void
    ) throws {
        try beforeReplacing()
        try write(data, destination)
    }

    private func repairDecodedStoreIfNeeded(
        decoded: ProgressData,
        sanitized: ProgressData,
        destination: URL,
        profileID: UUID
    ) -> Bool {
        guard !ProgressPersistencePolicy.progressDataIsSafe(decoded) else { return true }
        let rescueURL = Self.documentsDirectory.appendingPathComponent(
            "\(Self.sidecarPrefix(for: profileID))repaired-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.lowercased()).json"
        )
        do {
            try fileManager.copyItem(at: destination, to: rescueURL)
            let safeData = try JSONEncoder().encode(sanitized)
            guard safeData.count <= ProgressPersistencePolicy.maximumPersistedStoreBytes else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try safeData.write(to: destination, options: .atomic)
            Logger.shared.log(
                "ProgressManager: preserved unsafe source bytes as \(rescueURL.lastPathComponent) and installed the usable sanitized progress",
                type: "Error"
            )
            pruneRescueFiles(for: profileID)
            return true
        } catch {
            Logger.shared.log(
                "ProgressManager: could not durably preserve and repair unsafe progress; saves remain suspended: \(error.localizedDescription)",
                type: "Error"
            )
            return false
        }
    }

    private func preserveUnreadableStoreBeforeAuthoritativeWrite(
        destination: URL,
        profileID: UUID
    ) throws {
        let isKnownUnreadable = profileID == activeProfileID
            ? activeStoreLoadFailed
            : fileManager.fileExists(atPath: Self.unreadableMarkerURL(for: profileID).path)
        guard isKnownUnreadable,
              fileManager.fileExists(atPath: destination.path) else { return }
        let rescueURL = Self.documentsDirectory.appendingPathComponent(
            "\(Self.sidecarPrefix(for: profileID))unreadable-before-restore-\(UUID().uuidString.lowercased()).json"
        )
        do {
            // The source is already known to be unreadable or unbounded. Move
            // it aside within Documents instead of reading/copying it: a FIFO
            // cannot block, a sparse/oversized file is not duplicated, and a
            // failed replacement still leaves the exact raw source quarantined.
            try fileManager.moveItem(at: destination, to: rescueURL)
        } catch {
            Self.markStoreUnreadable(for: profileID)
            throw error
        }
        Logger.shared.log(
            "ProgressManager: quarantined unreadable source as \(rescueURL.lastPathComponent) before authoritative restore",
            type: "Error"
        )
    }

    private struct StoreWriteRequest {
        let profileID: UUID
        let destination: URL
        let generation: UInt64
        let sequence: UInt64
        let snapshot: ProgressData
        let storeLoadFailed: Bool
    }

    private func captureStoreWriteRequest(
        authorizing expectedProfileID: UUID?
    ) -> StoreWriteRequest? {
        let capture: () -> StoreWriteRequest? = {
            guard let nextSequence = Self.authorizedNextStoreWriteSequence(
                currentProfileID: self.activeProfileID,
                expectedProfileID: expectedProfileID,
                currentSequence: self.storeWriteSequence
            ) else {
                return nil
            }
            self.storeWriteSequence = nextSequence
            return StoreWriteRequest(
                profileID: self.activeProfileID,
                destination: self.progressFileURL,
                generation: self.storeGeneration,
                sequence: self.storeWriteSequence,
                snapshot: ProgressPersistencePolicy.sanitized(
                    self.progressData,
                    preservingDeviceLocalReferences: true
                ),
                storeLoadFailed: self.activeStoreLoadFailed
            )
        }
        if DispatchQueue.getSpecific(key: accessQueueKey) != nil {
            return capture()
        }

        return accessQueue.sync(flags: .barrier) {
            capture()
        }
    }

    static func authorizedNextStoreWriteSequence(
        currentProfileID: UUID,
        expectedProfileID: UUID?,
        currentSequence: UInt64
    ) -> UInt64? {
        guard expectedProfileID == nil || expectedProfileID == currentProfileID else {
            return nil
        }
        return currentSequence &+ 1
    }

    private func storeWriteRequestTargetsCurrentStore(_ request: StoreWriteRequest) -> Bool {
        Self.storeWriteIdentityIsCurrent(
            requestProfileID: request.profileID,
            requestGeneration: request.generation,
            requestDestination: request.destination,
            requestSequence: request.sequence,
            currentProfileID: activeProfileID,
            currentGeneration: storeGeneration,
            currentDestination: progressFileURL,
            currentSequence: storeWriteSequence
        )
    }

    static func storeWriteIdentityIsCurrent(
        requestProfileID: UUID,
        requestGeneration: UInt64,
        requestDestination: URL,
        requestSequence: UInt64,
        currentProfileID: UUID,
        currentGeneration: UInt64,
        currentDestination: URL,
        currentSequence: UInt64
    ) -> Bool {
        requestGeneration == currentGeneration
            && requestProfileID == currentProfileID
            && requestDestination == currentDestination
            && requestSequence == currentSequence
    }

    private func storeWriteRequestIsCurrent(_ request: StoreWriteRequest) -> Bool {
        storeWriteRequestTargetsCurrentStore(request)
            && !request.storeLoadFailed
            && !activeStoreLoadFailed
    }

    private func saveProgressData() {
        guard let request = captureStoreWriteRequest(authorizing: nil) else { return }
        enqueueStoreWrite(request)
    }

    private func enqueueStoreWrite(_ request: StoreWriteRequest) {
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self, self.storeWriteRequestIsCurrent(request) else { return }
            self.writeProgressData(request)
        }
    }

    private func writeProgressData(_ request: StoreWriteRequest) {

        guard !request.storeLoadFailed else {
            Logger.shared.log(
                "ProgressManager: refused to save over a store that failed to load",
                type: "Error"
            )
            return
        }
        do {
            let data = try JSONEncoder().encode(request.snapshot)
            guard data.count <= ProgressPersistencePolicy.maximumPersistedStoreBytes else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            preservePreviousStoreIfCatastrophicShrink(
                newByteCount: data.count,
                destination: request.destination,
                profileID: request.profileID
            )
            try data.write(to: request.destination, options: .atomic)
            Logger.shared.log("Progress data saved successfully", type: "Progress")
        } catch {
            Logger.shared.log("Failed to save progress data: \(error.localizedDescription)", type: "Error")
        }
    }

    private func preservePreviousStoreIfCatastrophicShrink(
        newByteCount: Int,
        destination: URL,
        profileID: UUID
    ) {
        guard let attributes = try? fileManager.attributesOfItem(atPath: destination.path),
              let existingSize = (attributes[.size] as? NSNumber)?.intValue,
              existingSize > 4_096,
              newByteCount < existingSize / 4 else {
            return
        }
        let rescueURL = Self.documentsDirectory.appendingPathComponent(
            "\(Self.sidecarPrefix(for: profileID))rescued-\(Int(Date().timeIntervalSince1970)).json"
        )
        try? fileManager.copyItem(at: destination, to: rescueURL)
        Logger.shared.log(
            "ProgressManager: write shrinks store from \(existingSize) to \(newByteCount) bytes; preserved previous data as \(rescueURL.lastPathComponent)",
            type: "Error"
        )
        pruneRescueFiles(for: profileID)
    }

    private var sidecarPrefix: String {
        Self.sidecarPrefix(for: activeProfileID)
    }

    private static func sidecarPrefix(for profileID: UUID) -> String {
        "ProgressData-\(ProfileScopedStorage.token(for: profileID))."
    }

    private func pruneRescueFiles(for profileID: UUID) {
        let prefixes = [
            "\(Self.sidecarPrefix(for: profileID))rescued-",
            "\(Self.sidecarPrefix(for: profileID))unreadable-",
            "\(Self.sidecarPrefix(for: profileID))repaired-",

            "ProgressData.rescued-",
            "ProgressData.unreadable-",
            "ProgressData.repaired-"
        ]
        guard let contents = try? fileManager.contentsOfDirectory(
            at: Self.documentsDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        for prefix in prefixes {
            let matches = contents
                .filter { $0.lastPathComponent.hasPrefix(prefix) }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for stale in matches.dropFirst(3) {
                try? fileManager.removeItem(at: stale)
            }
        }
    }

    private func debouncedSave() {
        guard let request = captureStoreWriteRequest(authorizing: nil) else { return }
        let now = Date()
        debounceLock.lock()
        let firstChange = firstUnflushedChangeAt ?? now
        firstUnflushedChangeAt = firstChange
        if now.timeIntervalSince(firstChange) >= debounceMaximumLatency {
            debounceTask?.cancel()
            debounceTask = nil
            firstUnflushedChangeAt = nil
            debounceLock.unlock()
            enqueueStoreWrite(request)
            return
        }
        let delayNanoseconds = UInt64(debounceInterval * 1_000_000_000)
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.debounceLock.lock()
            self.firstUnflushedChangeAt = nil
            self.debounceLock.unlock()
            self.enqueueStoreWrite(request)
        }
        debounceLock.unlock()
    }

    func flushPendingSave() {
        debounceLock.lock()
        let pendingTask = debounceTask
        debounceTask = nil
        firstUnflushedChangeAt = nil
        debounceLock.unlock()
        pendingTask?.cancel()

        guard let request = captureStoreWriteRequest(authorizing: nil) else { return }
        let writeIfCurrent = {
            guard self.storeWriteRequestIsCurrent(request) else { return }
            self.writeProgressData(request)
        }
        if DispatchQueue.getSpecific(key: accessQueueKey) != nil {
            writeIfCurrent()
        } else {
            accessQueue.sync(flags: .barrier, execute: writeIfCurrent)
        }
    }

    private func stableProgressTimes(
        currentTime: Double,
        totalDuration: Double,
        previousDuration: Double,
        label: String
    ) -> (currentTime: Double, totalDuration: Double)? {
        guard currentTime.isFinite, totalDuration.isFinite, currentTime >= 0, totalDuration > 0 else {
            Logger.shared.log("Invalid progress values for \(label): currentTime=\(currentTime), totalDuration=\(totalDuration)", type: "Warning")
            return nil
        }

        var resolvedDuration = totalDuration
        if previousDuration.isFinite, previousDuration > 0 {
            let shrinkTolerance = max(2.0, previousDuration * 0.005)
            if totalDuration + shrinkTolerance < previousDuration {
                let warningKey = "\(label)|\(previousDuration.rounded())|\(totalDuration.rounded())"
                if durationShrinkWarningKeys.insert(warningKey).inserted {
                    Logger.shared.log("Ignoring shorter reported duration for \(label): previous=\(previousDuration), reported=\(totalDuration)", type: "Warning")
                }
            }
            resolvedDuration = max(resolvedDuration, previousDuration)
        }

        resolvedDuration = max(resolvedDuration, currentTime)
        let resolvedTime = min(max(0, currentTime), resolvedDuration)
        return (resolvedTime, resolvedDuration)
    }

    func updateMovieProgress(
        movieId: Int,
        title: String,
        currentTime: Double,
        totalDuration: Double,
        posterURL: String? = nil,
        owner: UUID? = nil
    ) {
        guard currentTime.isFinite, totalDuration.isFinite, currentTime >= 0, totalDuration > 0 else {
            Logger.shared.log("Invalid progress values for movie \(title): currentTime=\(currentTime), totalDuration=\(totalDuration)", type: "Warning")
            return
        }
        guard let authority = profileMutationAuthority(requiredOwner: owner) else {
            logRejectedMutation("a movie progress update", authority: nil)
            return
        }

        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            guard self.profileMutationAuthorityIsCurrent(authority) else {
                self.logRejectedMutation("a movie progress update", authority: authority)
                return
            }
            var entry = self.progressData.findMovie(id: movieId) ?? MovieProgressEntry(id: movieId, title: title)
            let previousWatchedState = entry.isWatched
            guard let times = self.stableProgressTimes(
                currentTime: currentTime,
                totalDuration: totalDuration,
                previousDuration: entry.totalDuration,
                label: "movie \(title)"
            ) else { return }
            entry.currentTime = times.currentTime
            entry.totalDuration = times.totalDuration
            entry.lastUpdated = Date()

            if let posterURL = posterURL {
                entry.posterURL = posterURL
            }

            if entry.progress >= 0.85 {
                entry.isWatched = true
            }

            self.progressData.updateMovie(entry)
            self.publishCurrentData()

            DispatchQueue.main.async {
                TrackerManager.shared.syncTraktMoviePlaybackProgress(
                    movieId: movieId,
                    progress: entry.progress,
                    force: !previousWatchedState && entry.isWatched,
                    requiredOwner: authority.profileID,
                    progressAuthority: authority
                )
            }
            self.debouncedSave()
        }
    }

    func getMovieProgress(movieId: Int, title: String) -> Double {
        var result: Double = 0.0
        accessQueue.sync {
            result = self.progressData.findMovie(id: movieId)?.progress ?? 0.0
        }
        return result
    }

    func getMovieCurrentTime(movieId: Int, title: String) -> Double {
        var result: Double = 0.0
        accessQueue.sync {
            result = self.progressData.findMovie(id: movieId)?.currentTime ?? 0.0
        }
        return result
    }

    func isMovieWatched(movieId: Int) -> Bool {
        var result: Bool = false
        accessQueue.sync {
            if let entry = self.progressData.findMovie(id: movieId) {
                result = Self.isCompletedMovie(entry)
            }
        }
        return result
    }

    func markMovieAsWatched(
        movieId: Int,
        title: String,
        posterURL: String? = nil,
        owner: UUID? = nil
    ) {
        guard let authority = profileMutationAuthority(requiredOwner: owner) else {
            logRejectedMutation("a manual movie watched update", authority: nil)
            return
        }
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            guard self.profileMutationAuthorityIsCurrent(authority) else {
                self.logRejectedMutation("a manual movie watched update", authority: authority)
                return
            }
            var entry = self.progressData.findMovie(id: movieId) ?? MovieProgressEntry(id: movieId, title: title)
            let safeDuration = entry.totalDuration > 0 ? entry.totalDuration : max(entry.currentTime, 1)
            entry.posterURL = posterURL ?? entry.posterURL
            entry.totalDuration = safeDuration
            entry.currentTime = safeDuration
            entry.isWatched = true
            entry.lastUpdated = Date()
            self.progressData.updateMovie(entry)
            self.publishCurrentData()
            self.saveProgressData()
            Logger.shared.log("Marked movie as watched: \(entry.title)", type: "Progress")

            DispatchQueue.main.async {
                TrackerManager.shared.syncTraktMoviePlaybackProgress(
                    movieId: movieId,
                    progress: 1.0,
                    force: true,
                    requiredOwner: authority.profileID,
                    progressAuthority: authority
                )
            }
        }
    }

    func markMovieAsUnwatched(
        movieId: Int,
        title: String,
        posterURL: String? = nil,
        owner: UUID? = nil
    ) {
        guard let authority = profileMutationAuthority(requiredOwner: owner) else {
            logRejectedMutation("a manual movie unwatched update", authority: nil)
            return
        }
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            guard self.profileMutationAuthorityIsCurrent(authority) else {
                self.logRejectedMutation("a manual movie unwatched update", authority: authority)
                return
            }
            var entry = self.progressData.findMovie(id: movieId) ?? MovieProgressEntry(id: movieId, title: title)
            entry.posterURL = posterURL ?? entry.posterURL
            entry.currentTime = 0
            entry.isWatched = false
            entry.lastUpdated = Date()
            self.progressData.updateMovie(entry)
            self.publishCurrentData()
            self.saveProgressData()
            Logger.shared.log("Marked movie as unwatched: \(entry.title)", type: "Progress")
        }
    }

    func recordMovieServiceInfo(movieId: Int, serviceId: UUID?, href: String?) {
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            let sourceID = serviceId.map { "service:\($0.uuidString)" }
            let reference = sourceID.flatMap { sourceID in
                href.map { ProviderContentReference.service(sourceID: sourceID, href: $0) }
            }
            if var entry = self.progressData.findMovie(id: movieId) {
                entry.lastServiceId = serviceId
                entry.lastHref = href
                entry.lastSourceId = sourceID
                entry.lastContentReference = reference
                entry.lastUpdated = Date()
                self.progressData.updateMovie(entry)
                self.publishCurrentData()
            } else {
                var newEntry = MovieProgressEntry(id: movieId, title: "")
                newEntry.lastServiceId = serviceId
                newEntry.lastHref = href
                newEntry.lastSourceId = sourceID
                newEntry.lastContentReference = reference
                newEntry.lastUpdated = Date()
                self.progressData.updateMovie(newEntry)
                self.publishCurrentData()
            }
        }
        saveProgressData()
    }

    func recordEpisodeServiceInfo(showId: Int, seasonNumber: Int, episodeNumber: Int, serviceId: UUID?, href: String?) {
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            let sourceID = serviceId.map { "service:\($0.uuidString)" }
            let reference = sourceID.flatMap { sourceID in
                href.map { ProviderContentReference.service(sourceID: sourceID, href: $0) }
            }
            if var entry = self.progressData.findEpisode(showId: showId, season: seasonNumber, episode: episodeNumber) {
                entry.lastServiceId = serviceId
                entry.lastHref = href
                entry.lastSourceId = sourceID
                entry.lastContentReference = reference
                entry.lastUpdated = Date()
                self.progressData.updateEpisode(entry)
                self.publishCurrentData()
            } else {
                var newEntry = EpisodeProgressEntry(showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber)
                newEntry.lastServiceId = serviceId
                newEntry.lastHref = href
                newEntry.lastSourceId = sourceID
                newEntry.lastContentReference = reference
                newEntry.lastUpdated = Date()
                self.progressData.updateEpisode(newEntry)
                self.publishCurrentData()
            }
        }
        saveProgressData()
    }

    func recordMovieSourceInfo(
        movieId: Int,
        sourceId: String,
        reference: ProviderContentReference
    ) {
        guard Self.isValidProviderReference(sourceId: sourceId, reference: reference) else { return }
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            var entry = self.progressData.findMovie(id: movieId)
                ?? MovieProgressEntry(id: movieId, title: "")
            entry.lastSourceId = sourceId
            entry.lastContentReference = reference
            entry.lastServiceId = nil
            entry.lastHref = nil
            entry.lastUpdated = Date()
            self.progressData.updateMovie(entry)
            self.publishCurrentData()
        }
        saveProgressData()
    }

    func recordEpisodeSourceInfo(
        showId: Int,
        seasonNumber: Int,
        episodeNumber: Int,
        sourceId: String,
        reference: ProviderContentReference
    ) {
        guard Self.isValidProviderReference(sourceId: sourceId, reference: reference) else { return }
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            var entry = self.progressData.findEpisode(
                showId: showId,
                season: seasonNumber,
                episode: episodeNumber
            ) ?? EpisodeProgressEntry(
                showId: showId,
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber
            )
            entry.lastSourceId = sourceId
            entry.lastContentReference = reference
            entry.lastServiceId = nil
            entry.lastHref = nil
            entry.lastUpdated = Date()
            self.progressData.updateEpisode(entry)
            self.publishCurrentData()
        }
        saveProgressData()
    }

    private static func isValidProviderReference(
        sourceId: String,
        reference: ProviderContentReference
    ) -> Bool {
        let trimmed = sourceId.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed == sourceId
            && trimmed.utf8.count <= 320
            && reference.sourceID == sourceId
    }

    func updateEpisodeProgress(
        showId: Int,
        seasonNumber: Int,
        episodeNumber: Int,
        currentTime: Double,
        totalDuration: Double,
        showTitle: String? = nil,
        showPosterURL: String? = nil,
        playbackContext: EpisodePlaybackContext? = nil,
        isAnime: Bool = false,
        owner: UUID? = nil
    ) {
        guard currentTime.isFinite, totalDuration.isFinite, currentTime >= 0, totalDuration > 0 else {
            Logger.shared.log("Invalid progress values for episode S\(seasonNumber)E\(episodeNumber): currentTime=\(currentTime), totalDuration=\(totalDuration)", type: "Warning")
            return
        }
        guard let authority = profileMutationAuthority(requiredOwner: owner) else {
            logRejectedMutation("an episode progress update", authority: nil)
            return
        }

        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            guard self.profileMutationAuthorityIsCurrent(authority) else {
                self.logRejectedMutation("an episode progress update", authority: authority)
                return
            }
            var entry = self.progressData.findEpisode(showId: showId, season: seasonNumber, episode: episodeNumber)
                ?? EpisodeProgressEntry(showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber)

            let previousWatchedState = entry.isWatched
            guard let times = self.stableProgressTimes(
                currentTime: currentTime,
                totalDuration: totalDuration,
                previousDuration: entry.totalDuration,
                label: "episode S\(seasonNumber)E\(episodeNumber)"
            ) else { return }
            entry.currentTime = times.currentTime
            entry.totalDuration = times.totalDuration
            entry.lastUpdated = Date()
            entry.playbackContext = playbackContext ?? entry.playbackContext
            entry.isAnime = entry.isAnime == true || isAnime || playbackContext?.hasAnimeMediaId == true

            if entry.progress >= 0.85 {
                entry.isWatched = true
            }

            self.unhideUpNextShowIfNeeded(showId: showId)
            self.progressData.updateEpisode(entry)

            if let showTitle = showTitle {
                self.progressData.updateShowMetadata(showId: showId, title: showTitle, posterURL: showPosterURL)
            }

            self.publishCurrentData()

            if !entry.isWatched {
                DispatchQueue.main.async {
                    TrackerManager.shared.syncTraktEpisodePlaybackProgress(
                        showId: showId,
                        seasonNumber: seasonNumber,
                        episodeNumber: episodeNumber,
                        progress: entry.progress,
                        playbackContext: playbackContext?.forEpisodeNumber(episodeNumber),
                        requiredOwner: authority.profileID,
                        progressAuthority: authority
                    )
                }
            }

            if !previousWatchedState && entry.isWatched {
                DispatchQueue.main.async {
                    TrackerManager.shared.syncWatchProgress(
                        showId: showId,
                        seasonNumber: seasonNumber,
                        episodeNumber: episodeNumber,
                        progress: entry.progress,
                        isAnime: entry.isAnime == true,
                        playbackContext: playbackContext?.forEpisodeNumber(episodeNumber),
                        requiredOwner: authority.profileID,
                        progressAuthority: authority
                    )
                }
            }
            self.debouncedSave()
        }
    }

    func getEpisodeProgress(showId: Int, seasonNumber: Int, episodeNumber: Int) -> Double {
        var result: Double = 0.0
        accessQueue.sync {
            result = self.progressData.findEpisode(showId: showId, season: seasonNumber, episode: episodeNumber)?.progress ?? 0.0
        }
        return result
    }

    func getEpisodeCurrentTime(showId: Int, seasonNumber: Int, episodeNumber: Int) -> Double {
        var result: Double = 0.0
        accessQueue.sync {
            result = self.progressData.findEpisode(showId: showId, season: seasonNumber, episode: episodeNumber)?.currentTime ?? 0.0
        }
        return result
    }

    func getLatestEpisodeProgress(showId: Int) -> EpisodeProgressEntry? {
        var result: EpisodeProgressEntry?
        accessQueue.sync {
            result = self.progressData.episodeProgress
                .filter {
                    $0.showId == showId &&
                    ($0.currentTime > 0 || $0.totalDuration > 0 || $0.isWatched || $0.lastHref != nil)
                }
                .max { $0.lastUpdated < $1.lastUpdated }
        }
        return result
    }

    func findEpisode(showId: Int, season: Int, episode: Int) -> EpisodeProgressEntry? {
        var result: EpisodeProgressEntry?
        accessQueue.sync {
            result = self.progressData.findEpisode(showId: showId, season: season, episode: episode)
        }
        return result
    }

    @MainActor
    func reconcileAnimeStructuralCoordinates(
        showId: Int,
        regularSeasonByAniListID: [Int: Int],
        specialSeasonByAniListID: [Int: Int],
        canonicalEpisodeContexts: [EpisodePlaybackContext] = [],
        canonicalProviderIDByStoredID: [Int: Int] = [:]
    ) {
        guard !regularSeasonByAniListID.isEmpty || !specialSeasonByAniListID.isEmpty else { return }
        let changedSnapshot: ProgressData? = accessQueue.sync(flags: .barrier) { [weak self] in
            guard let self else { return nil }

            func hasCompatibleIdentity(
                _ lhs: EpisodeProgressEntry,
                _ rhs: EpisodeProgressEntry
            ) -> Bool {
                if let lhsContext = lhs.playbackContext,
                   let rhsContext = rhs.playbackContext {
                    return AnimeEpisodeIdentityPolicy.isSameEpisode(
                        lhsContext,
                        rhsContext,
                        providerAliases: canonicalProviderIDByStoredID,
                        allowLegacyLocalCoordinates: true
                    )
                }
                return lhs.playbackContext == nil && rhs.playbackContext == nil
            }

            var plans: [(original: EpisodeProgressEntry, migrated: EpisodeProgressEntry?)] = []
            plans.reserveCapacity(self.progressData.episodeProgress.count)

            for stored in self.progressData.episodeProgress {
                guard stored.showId == showId else {
                    plans.append((stored, nil))
                    continue
                }
                let context = stored.playbackContext
                let storedProviderID = context?.anilistMediaId
                    ?? AnimeSyntheticSeasonKey.providerID(from: stored.seasonNumber)
                guard let storedProviderID, storedProviderID != 0 else {
                    plans.append((stored, nil))
                    continue
                }
                let canonicalProviderID = canonicalProviderIDByStoredID[storedProviderID]
                    ?? storedProviderID

                let identityContext = context ?? EpisodePlaybackContext(
                    localSeasonNumber: stored.seasonNumber,
                    localEpisodeNumber: stored.episodeNumber,
                    anilistMediaId: storedProviderID,
                    tmdbSeasonNumber: nil,
                    tmdbEpisodeNumber: nil,
                    tmdbEpisodeOffset: nil,
                    animeAbsoluteEpisodeNumber: nil,
                    animeSeasonEpisodeCount: nil,
                    isSpecial: AnimeSyntheticSeasonKey.isSynthetic(stored.seasonNumber),
                    titleOnlySearch: false
                )
                let canonicalContext = canonicalEpisodeContexts.first {
                    AnimeEpisodeIdentityPolicy.isSameEpisode(
                        identityContext,
                        $0,
                        providerAliases: canonicalProviderIDByStoredID
                    )
                }

                let targetSeason: Int
                let isSpecial: Bool
                if let canonicalContext {
                    targetSeason = canonicalContext.localSeasonNumber
                    isSpecial = canonicalContext.isSpecial
                } else if let regularSeason = regularSeasonByAniListID[canonicalProviderID]
                    ?? regularSeasonByAniListID[storedProviderID] {
                    targetSeason = regularSeason
                    isSpecial = false
                } else if let specialSeason = specialSeasonByAniListID[canonicalProviderID]
                    ?? specialSeasonByAniListID[storedProviderID] {
                    targetSeason = specialSeason
                    isSpecial = true
                } else {
                    plans.append((stored, nil))
                    continue
                }

                let targetEpisode = canonicalContext?.localEpisodeNumber
                    ?? context?.localEpisodeNumber
                    ?? stored.episodeNumber
                let resolvedContext = canonicalContext ?? EpisodePlaybackContext(
                    localSeasonNumber: targetSeason,
                    localEpisodeNumber: targetEpisode,
                    anilistMediaId: canonicalProviderID,
                    kitsuMediaId: context?.kitsuMediaId,
                    tmdbSeasonNumber: nil,
                    tmdbEpisodeNumber: nil,
                    tmdbEpisodeOffset: nil,
                    animeAbsoluteEpisodeNumber: nil,
                    animeSeasonEpisodeCount: nil,
                    isSpecial: isSpecial,
                    titleOnlySearch: isSpecial && (context?.titleOnlySearch ?? false)
                )
                let roleAlreadyMatches = context == resolvedContext
                guard targetEpisode > 0,
                      stored.seasonNumber != targetSeason || stored.episodeNumber != targetEpisode
                        || !roleAlreadyMatches else {
                    plans.append((stored, nil))
                    continue
                }

                var migrated = EpisodeProgressEntry(
                    showId: showId,
                    seasonNumber: targetSeason,
                    episodeNumber: targetEpisode
                )
                migrated.currentTime = stored.currentTime
                migrated.totalDuration = stored.totalDuration
                migrated.isWatched = stored.isWatched
                migrated.lastUpdated = stored.lastUpdated
                migrated.lastServiceId = stored.lastServiceId
                migrated.lastHref = stored.lastHref
                migrated.lastSourceId = stored.lastSourceId
                migrated.lastContentReference = stored.lastContentReference
                migrated.isAnime = true
                migrated.playbackContext = resolvedContext
                plans.append((stored, migrated))
            }

            var useMigrated = plans.map { $0.migrated != nil }
            while true {
                var indicesByID: [String: [Int]] = [:]
                for index in plans.indices {
                    let entry = useMigrated[index]
                        ? (plans[index].migrated ?? plans[index].original)
                        : plans[index].original
                    indicesByID[entry.id, default: []].append(index)
                }
                var revertedAny = false
                for indices in indicesByID.values where indices.count > 1 {
                    let entries = indices.map { index in
                        useMigrated[index]
                            ? (plans[index].migrated ?? plans[index].original)
                            : plans[index].original
                    }
                    let isCompatible = entries.indices.allSatisfy { lhsIndex in
                        entries.indices.allSatisfy { rhsIndex in
                            lhsIndex == rhsIndex
                                || hasCompatibleIdentity(entries[lhsIndex], entries[rhsIndex])
                        }
                    }
                    guard !isCompatible else { continue }
                    for index in indices where useMigrated[index] {
                        useMigrated[index] = false
                        revertedAny = true
                    }
                }
                if !revertedAny { break }
            }

            var changed = useMigrated.contains(true)
            var rebuilt: [EpisodeProgressEntry] = []
            var firstIndexByID: [String: Int] = [:]
            rebuilt.reserveCapacity(plans.count)
            for index in plans.indices {
                let candidate = useMigrated[index]
                    ? (plans[index].migrated ?? plans[index].original)
                    : plans[index].original
                guard let existingIndex = firstIndexByID[candidate.id] else {
                    firstIndexByID[candidate.id] = rebuilt.count
                    rebuilt.append(candidate)
                    continue
                }
                guard hasCompatibleIdentity(rebuilt[existingIndex], candidate) else {

                    rebuilt.append(candidate)
                    continue
                }
                var existing = rebuilt[existingIndex]
                let newer = candidate.lastUpdated >= existing.lastUpdated ? candidate : existing
                let older = candidate.lastUpdated >= existing.lastUpdated ? existing : candidate
                existing = newer
                existing.currentTime = max(newer.currentTime, older.currentTime)
                existing.totalDuration = max(newer.totalDuration, older.totalDuration, existing.currentTime)
                existing.isWatched = newer.isWatched || older.isWatched
                existing.lastUpdated = max(newer.lastUpdated, older.lastUpdated)
                if existing.lastServiceId == nil { existing.lastServiceId = older.lastServiceId }
                if existing.lastHref == nil { existing.lastHref = older.lastHref }
                if existing.lastSourceId == nil { existing.lastSourceId = older.lastSourceId }
                if existing.lastContentReference == nil {
                    existing.lastContentReference = older.lastContentReference
                }
                if existing.playbackContext == nil { existing.playbackContext = older.playbackContext }
                existing.isAnime = newer.isAnime == true || older.isAnime == true
                rebuilt[existingIndex] = existing
                changed = true
            }

            guard changed else { return nil }
            self.progressData.episodeProgress = rebuilt
            return self.progressData
        }
        guard let changedSnapshot else { return }

        movieProgressList = changedSnapshot.movieProgress
        episodeProgressList = changedSnapshot.episodeProgress
        NotificationCenter.default.post(name: .progressDataDidChange, object: self)
        saveProgressData()
    }

    func isEpisodeWatched(showId: Int, seasonNumber: Int, episodeNumber: Int) -> Bool {
        var result: Bool = false
        accessQueue.sync {
            if let entry = self.progressData.findEpisode(showId: showId, season: seasonNumber, episode: episodeNumber) {
                result = Self.isCompletedEpisode(entry)
            }
        }
        return result
    }

    func hasStartedOrCompletedEpisode(showId: Int, seasonNumber: Int, episodeNumber: Int) -> Bool {
        var result: Bool = false
        accessQueue.sync {
            if let entry = self.progressData.findEpisode(showId: showId, season: seasonNumber, episode: episodeNumber) {
                result = entry.isWatched || entry.progress > Self.continueWatchingMinimumProgress
            }
        }
        return result
    }

    func markEpisodeAsWatched(
        showId: Int,
        seasonNumber: Int,
        episodeNumber: Int,
        playbackContext: EpisodePlaybackContext? = nil,
        isAnime: Bool = false,
        owner: UUID? = nil
    ) {
        guard let authority = profileMutationAuthority(requiredOwner: owner) else {
            logRejectedMutation("a manual episode watched update", authority: nil)
            return
        }
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            guard self.profileMutationAuthorityIsCurrent(authority) else {
                self.logRejectedMutation("a manual episode watched update", authority: authority)
                return
            }
            var entry = self.progressData.findEpisode(showId: showId, season: seasonNumber, episode: episodeNumber)
                ?? EpisodeProgressEntry(showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber)
            let safeDuration = entry.totalDuration > 0 ? entry.totalDuration : max(entry.currentTime, 1)
            entry.totalDuration = safeDuration
            entry.isWatched = true
            entry.currentTime = safeDuration
            entry.lastUpdated = Date()
            entry.playbackContext = playbackContext ?? entry.playbackContext
            entry.isAnime = entry.isAnime == true || isAnime || playbackContext?.hasAnimeMediaId == true
            self.unhideUpNextShowIfNeeded(showId: showId)
            self.progressData.updateEpisode(entry)
            self.publishCurrentData()
            Logger.shared.log("Marked episode as watched: S\(seasonNumber)E\(episodeNumber)", type: "Progress")

            DispatchQueue.main.async {
                TrackerManager.shared.syncWatchProgress(
                    showId: showId,
                    seasonNumber: seasonNumber,
                    episodeNumber: episodeNumber,
                    progress: 1.0,
                    isAnime: entry.isAnime == true,
                    playbackContext: playbackContext?.forEpisodeNumber(episodeNumber),
                    requiredOwner: authority.profileID,
                    progressAuthority: authority
                )
            }
        }
        saveProgressData()
    }

    func bulkMarkEpisodeNumbersAsWatched(
        showId: Int,
        seasonNumber: Int,
        episodeNumbers: [Int],
        owner: UUID? = nil
    ) {
        guard let episodeNumbers = ProgressPersistencePolicy.exactEpisodeMutationNumbers(
            showID: showId,
            seasonNumber: seasonNumber,
            episodeNumbers: episodeNumbers
        ) else { return }
        guard let authority = profileMutationAuthority(requiredOwner: owner) else {
            logRejectedMutation("an exact-episode watched import", authority: nil)
            return
        }
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            guard self.profileMutationAuthorityIsCurrent(authority) else {
                self.logRejectedMutation("an exact-episode watched import", authority: authority)
                return
            }
            for episodeNumber in episodeNumbers {
                var entry = self.progressData.findEpisode(showId: showId, season: seasonNumber, episode: episodeNumber)
                    ?? EpisodeProgressEntry(showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber)
                guard !entry.isWatched else { continue }
                let safeDuration = entry.totalDuration > 0 ? entry.totalDuration : max(entry.currentTime, 1)
                entry.totalDuration = safeDuration
                entry.isWatched = true
                entry.currentTime = safeDuration
                entry.lastUpdated = Date()
                self.progressData.updateEpisode(entry)
            }
            self.publishCurrentData()
            Logger.shared.log("Bulk marked \(episodeNumbers.count) exact episode(s) as watched for show \(showId) S\(seasonNumber) (import)", type: "Progress")
        }
        saveProgressData()
    }

    func markMovieAsWatchedForImport(
        movieId: Int,
        title: String,
        posterURL: String? = nil,
        owner: UUID? = nil
    ) {
        guard let authority = profileMutationAuthority(requiredOwner: owner) else {
            logRejectedMutation("a movie watched import", authority: nil)
            return
        }
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            guard self.profileMutationAuthorityIsCurrent(authority) else {
                self.logRejectedMutation("a movie watched import", authority: authority)
                return
            }
            var entry = self.progressData.findMovie(id: movieId) ?? MovieProgressEntry(id: movieId, title: title)
            let safeDuration = entry.totalDuration > 0 ? entry.totalDuration : max(entry.currentTime, 1)
            entry.posterURL = posterURL ?? entry.posterURL
            entry.totalDuration = safeDuration
            entry.currentTime = safeDuration
            entry.isWatched = true
            entry.lastUpdated = Date()
            self.progressData.updateMovie(entry)
            self.publishCurrentData()
            Logger.shared.log("Marked movie \(movieId) as watched locally (import)", type: "Progress")
        }
        saveProgressData()
    }

    func resetEpisodeProgress(
        showId: Int,
        seasonNumber: Int,
        episodeNumber: Int,
        owner: UUID? = nil
    ) {
        guard let authority = profileMutationAuthority(requiredOwner: owner) else {
            logRejectedMutation("an episode reset", authority: nil)
            return
        }
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            guard self.profileMutationAuthorityIsCurrent(authority) else {
                self.logRejectedMutation("an episode reset", authority: authority)
                return
            }
            var entry = self.progressData.findEpisode(showId: showId, season: seasonNumber, episode: episodeNumber)
                ?? EpisodeProgressEntry(showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber)
            entry.currentTime = 0
            entry.isWatched = false
            entry.lastUpdated = Date()
            self.progressData.updateEpisode(entry)
            self.publishCurrentData()
            Logger.shared.log("Reset episode progress: S\(seasonNumber)E\(episodeNumber)", type: "Progress")
        }
        saveProgressData()
    }

    func markPreviousEpisodesAsWatched(
        showId: Int,
        seasonNumber: Int,
        episodeNumber: Int,
        playbackContext: EpisodePlaybackContext? = nil,
        isAnime: Bool = false,
        owner: UUID? = nil
    ) {
        guard ProgressPersistencePolicy.previousEpisodeMutationIsSafe(
            showID: showId,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber
        ) else { return }
        guard let authority = profileMutationAuthority(requiredOwner: owner) else {
            logRejectedMutation("a previous-episodes watched update", authority: nil)
            return
        }

        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            guard self.profileMutationAuthorityIsCurrent(authority) else {
                self.logRejectedMutation("a previous-episodes watched update", authority: authority)
                return
            }
            for e in 1..<episodeNumber {
                var entry = self.progressData.findEpisode(showId: showId, season: seasonNumber, episode: e)
                    ?? EpisodeProgressEntry(showId: showId, seasonNumber: seasonNumber, episodeNumber: e)
                let safeDuration = entry.totalDuration > 0 ? entry.totalDuration : max(entry.currentTime, 1)
                entry.totalDuration = safeDuration
                entry.isWatched = true
                entry.currentTime = safeDuration
                entry.lastUpdated = Date()
                entry.playbackContext = playbackContext?.forEpisodeNumber(e)
                entry.isAnime = isAnime || playbackContext?.hasAnimeMediaId == true
                self.progressData.updateEpisode(entry)
            }
            self.publishCurrentData()
            Logger.shared.log("Marked previous episodes as watched for S\(seasonNumber) up to E\(episodeNumber - 1)", type: "Progress")

            DispatchQueue.main.async {
                let highestEpisode = episodeNumber - 1
                TrackerManager.shared.syncWatchProgress(
                    showId: showId,
                    seasonNumber: seasonNumber,
                    episodeNumber: highestEpisode,
                    progress: 1.0,
                    isAnime: isAnime || playbackContext?.hasAnimeMediaId == true,
                    playbackContext: playbackContext?.forEpisodeNumber(highestEpisode),
                    requiredOwner: authority.profileID,
                    progressAuthority: authority
                )
            }
        }
        saveProgressData()
    }

    func markEpisodeAsUnwatched(
        showId: Int,
        seasonNumber: Int,
        episodeNumber: Int,
        owner: UUID? = nil
    ) {
        guard let authority = profileMutationAuthority(requiredOwner: owner) else {
            logRejectedMutation("a manual episode unwatched update", authority: nil)
            return
        }
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            guard self.profileMutationAuthorityIsCurrent(authority) else {
                self.logRejectedMutation("a manual episode unwatched update", authority: authority)
                return
            }
            var entry = self.progressData.findEpisode(showId: showId, season: seasonNumber, episode: episodeNumber)
                ?? EpisodeProgressEntry(showId: showId, seasonNumber: seasonNumber, episodeNumber: episodeNumber)
            entry.currentTime = 0
            entry.isWatched = false
            entry.lastUpdated = Date()
            self.progressData.updateEpisode(entry)
            self.publishCurrentData()
            Logger.shared.log("Marked episode as unwatched: S\(seasonNumber)E\(episodeNumber)", type: "Progress")
        }
        saveProgressData()
    }

    func markPreviousEpisodesAsUnwatched(
        showId: Int,
        seasonNumber: Int,
        episodeNumber: Int,
        owner: UUID? = nil
    ) {
        guard ProgressPersistencePolicy.previousEpisodeMutationIsSafe(
            showID: showId,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber
        ) else { return }
        guard let authority = profileMutationAuthority(requiredOwner: owner) else {
            logRejectedMutation("a previous-episodes unwatched update", authority: nil)
            return
        }

        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            guard self.profileMutationAuthorityIsCurrent(authority) else {
                self.logRejectedMutation("a previous-episodes unwatched update", authority: authority)
                return
            }
            for e in 1..<episodeNumber {
                var entry = self.progressData.findEpisode(showId: showId, season: seasonNumber, episode: e)
                    ?? EpisodeProgressEntry(showId: showId, seasonNumber: seasonNumber, episodeNumber: e)
                entry.currentTime = 0
                entry.isWatched = false
                entry.lastUpdated = Date()
                self.progressData.updateEpisode(entry)
            }
            self.publishCurrentData()
            Logger.shared.log("Marked previous episodes as unwatched for S\(seasonNumber) up to E\(episodeNumber - 1)", type: "Progress")
        }
        saveProgressData()
    }

    func getContinueWatchingItems(limit: Int = 10) -> [ContinueWatchingItem] {
        var items: [ContinueWatchingItem] = []

        accessQueue.sync {

            let movies = self.progressData.movieProgress
                .filter { !$0.isWatched && $0.progress > Self.continueWatchingMinimumProgress && $0.progress < Self.watchedProgressThreshold }
                .map { movie in
                    ContinueWatchingItem(
                        id: "movie_\(movie.id)",
                        tmdbId: movie.id,
                        isMovie: true,
                        title: movie.title,
                        posterURL: movie.posterURL,
                        progress: movie.progress,
                        lastUpdated: movie.lastUpdated,
                        seasonNumber: nil,
                        episodeNumber: nil,
                        currentTime: movie.currentTime,
                        totalDuration: movie.totalDuration,
                        playbackContext: nil,
                        isAnime: false,
                        statusText: nil,
                        isWatchNext: false,
                        traktPlaybackId: nil
                    )
                }

            var showMap: [Int: EpisodeProgressEntry] = [:]
            for episode in self.progressData.episodeProgress where Self.isActiveContinueWatchingEpisode(episode) {
                if let existing = showMap[episode.showId] {
                    if episode.lastUpdated > existing.lastUpdated {
                        showMap[episode.showId] = episode
                    }
                } else {
                    showMap[episode.showId] = episode
                }
            }

            let episodes = showMap.values.map { episode in

                let showMeta = self.progressData.getShowMetadata(showId: episode.showId)
                return ContinueWatchingItem(
                    id: "episode_\(episode.showId)",
                    tmdbId: episode.showId,
                    isMovie: false,
                    title: showMeta?.title ?? "",
                    posterURL: showMeta?.posterURL,
                    progress: episode.progress,
                    lastUpdated: episode.lastUpdated,
                    seasonNumber: episode.seasonNumber,
                    episodeNumber: episode.episodeNumber,
                    currentTime: episode.currentTime,
                    totalDuration: episode.totalDuration,
                    playbackContext: episode.playbackContext,
                    isAnime: episode.isAnime == true || episode.playbackContext?.hasAnimeMediaId == true,
                    statusText: nil,
                    isWatchNext: false,
                    traktPlaybackId: nil
                )
            }

            items = (movies + episodes)
                .sorted { $0.lastUpdated > $1.lastUpdated }
                .prefix(limit)
                .map { $0 }
        }

        return items
    }

    func getWatchNextCandidates(limit: Int = 10) -> [WatchNextCandidate] {
        var candidates: [WatchNextCandidate] = []

        accessQueue.sync {
            let hiddenShowIds = self.progressData.hiddenUpNextShowIds
            candidates = Dictionary(grouping: self.progressData.episodeProgress, by: \.showId)
                .compactMap { showId, episodes in
                    guard !hiddenShowIds.contains(showId) else {
                        return nil
                    }

                    let regularEpisodes = episodes.filter(Self.isRegularEpisode)
                    guard !regularEpisodes.contains(where: Self.isActiveContinueWatchingEpisode) else {
                        return nil
                    }

                    let completedEpisodes = regularEpisodes.filter(Self.isCompletedEpisode)
                    guard let frontier = completedEpisodes.max(by: Self.isEpisodeBefore) else {
                        return nil
                    }

                    let showMeta = self.progressData.getShowMetadata(showId: showId)
                    let lastUpdated = completedEpisodes.map(\.lastUpdated).max() ?? frontier.lastUpdated
                    return WatchNextCandidate(
                        tmdbId: frontier.showId,
                        title: showMeta?.title ?? "",
                        posterURL: showMeta?.posterURL,
                        seasonNumber: frontier.seasonNumber,
                        episodeNumber: frontier.episodeNumber,
                        lastUpdated: lastUpdated,
                        playbackContext: frontier.playbackContext,
                        isAnime: frontier.isAnime == true || frontier.playbackContext?.hasAnimeMediaId == true
                    )
                }
                .sorted { $0.lastUpdated > $1.lastUpdated }
                .prefix(limit)
                .map { $0 }
        }

        return candidates
    }

    private static func isRegularEpisode(_ episode: EpisodeProgressEntry) -> Bool {
        episode.playbackContext?.isSpecial != true
            && episode.seasonNumber > 0
            && !AnimeSyntheticSeasonKey.isSynthetic(episode.seasonNumber)
            && episode.episodeNumber > 0
    }

    private static func isCompletedEpisode(_ episode: EpisodeProgressEntry) -> Bool {
        episode.isWatched || episode.progress >= watchedProgressThreshold
    }

    private static func isCompletedMovie(_ movie: MovieProgressEntry) -> Bool {
        movie.isWatched || movie.progress >= watchedProgressThreshold
    }

    private static func isActiveContinueWatchingEpisode(_ episode: EpisodeProgressEntry) -> Bool {
        !episode.isWatched &&
        episode.progress > continueWatchingMinimumProgress &&
        episode.progress < watchedProgressThreshold
    }

    private static func isEpisodeBefore(_ lhs: EpisodeProgressEntry, _ rhs: EpisodeProgressEntry) -> Bool {
        if lhs.seasonNumber == rhs.seasonNumber {
            return lhs.episodeNumber < rhs.episodeNumber
        }
        return lhs.seasonNumber < rhs.seasonNumber
    }

    func markContinueWatchingItemAsWatched(
        _ item: ContinueWatchingItem,
        owner: UUID? = nil
    ) {
        guard let authority = profileMutationAuthority(requiredOwner: owner) else {
            logRejectedMutation("a Continue Watching completion", authority: nil)
            return
        }
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self else { return }
            guard self.profileMutationAuthorityIsCurrent(authority) else {
                self.logRejectedMutation("a Continue Watching completion", authority: authority)
                return
            }

            if item.isMovie {
                var entry = self.progressData.findMovie(id: item.tmdbId)
                    ?? MovieProgressEntry(id: item.tmdbId, title: item.title)
                let safeDuration = entry.totalDuration > 0 ? entry.totalDuration : max(entry.currentTime, 1)
                entry.totalDuration = safeDuration
                entry.currentTime = safeDuration
                entry.isWatched = true
                entry.lastUpdated = Date()
                self.progressData.updateMovie(entry)
                Logger.shared.log("Marked continue-watching movie as watched: \(entry.title)", type: "Progress")
                DispatchQueue.main.async {
                    TrackerManager.shared.syncTraktMoviePlaybackProgress(
                        movieId: item.tmdbId,
                        progress: 1.0,
                        force: true,
                        requiredOwner: authority.profileID,
                        progressAuthority: authority
                    )
                }
            } else {
                guard let seasonNumber = item.seasonNumber,
                      let episodeNumber = item.episodeNumber else { return }
                var entry = self.progressData.findEpisode(showId: item.tmdbId, season: seasonNumber, episode: episodeNumber)
                    ?? EpisodeProgressEntry(showId: item.tmdbId, seasonNumber: seasonNumber, episodeNumber: episodeNumber)
                let safeDuration = entry.totalDuration > 0 ? entry.totalDuration : max(entry.currentTime, 1)
                entry.totalDuration = safeDuration
                entry.currentTime = safeDuration
                entry.isWatched = true
                entry.lastUpdated = Date()
                self.unhideUpNextShowIfNeeded(showId: item.tmdbId)
                self.progressData.updateEpisode(entry)
                self.progressData.updateShowMetadata(showId: item.tmdbId, title: item.title, posterURL: item.posterURL)
                Logger.shared.log("Marked continue-watching episode as watched: showId=\(item.tmdbId) S\(seasonNumber)E\(episodeNumber)", type: "Progress")

                DispatchQueue.main.async {
                    TrackerManager.shared.syncWatchProgress(
                        showId: item.tmdbId,
                        seasonNumber: seasonNumber,
                        episodeNumber: episodeNumber,
                        progress: 1.0,
                        isAnime: item.isAnime,
                        playbackContext: item.playbackContext?.forEpisodeNumber(episodeNumber),
                        requiredOwner: authority.profileID,
                        progressAuthority: authority
                    )
                }
            }

            self.publishCurrentData()
            self.saveProgressData()
        }
    }

    func removeUpNextShow(_ item: ContinueWatchingItem) {
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }
            self.progressData.hiddenUpNextShowIds.insert(item.tmdbId)
            Logger.shared.log("Removed show from Up Next: showId=\(item.tmdbId)", type: "Progress")
            self.publishCurrentData()
            self.saveProgressData()
        }
    }

    private func unhideUpNextShowIfNeeded(showId: Int) {
        if progressData.hiddenUpNextShowIds.remove(showId) != nil {
            Logger.shared.log("Restored show to Up Next after new progress: showId=\(showId)", type: "Progress")
        }
    }

    func removeContinueWatchingItem(_ item: ContinueWatchingItem) {
        accessQueue.async(flags: .barrier) { [weak self] in
            guard let self = self else { return }

            if item.isMovie {
                self.progressData.movieProgress.removeAll { $0.id == item.tmdbId }
                Logger.shared.log("Removed continue-watching movie entry id=\(item.tmdbId)", type: "Progress")
            } else {
                guard let seasonNumber = item.seasonNumber,
                      let episodeNumber = item.episodeNumber else { return }
                self.progressData.episodeProgress.removeAll {
                    $0.showId == item.tmdbId &&
                    $0.seasonNumber == seasonNumber &&
                    $0.episodeNumber == episodeNumber
                }

                let hasEpisodesForShow = self.progressData.episodeProgress.contains { $0.showId == item.tmdbId }
                if !hasEpisodesForShow {
                    self.progressData.showMetadata[item.tmdbId] = nil
                }

                Logger.shared.log("Removed continue-watching episode entry showId=\(item.tmdbId) S\(seasonNumber)E\(episodeNumber)", type: "Progress")
            }

            self.publishCurrentData()
            self.saveProgressData()
        }
    }

    func syncTraktProgressOnPlaybackClose(
        for mediaInfo: MediaInfo,
        playbackContext: EpisodePlaybackContext? = nil,
        played: Bool = true,
        owner: UUID? = nil,
        progressAuthority: ProfileMutationAuthority? = nil
    ) {
        guard played else {
            Logger.shared.log("Skipping Trakt playback-close sync because playback never started", type: "Tracker")
            return
        }
        let resolvedAuthority = progressAuthority
            ?? profileMutationAuthority(requiredOwner: owner)
        guard let authority = resolvedAuthority,
              owner == nil || owner == authority.profileID,
              profileMutationAuthorityIsCurrent(authority),
              ProfileManager.shared.isStillActive(authority.profileID) else {
            Logger.shared.log("Abandoned Trakt playback-close sync: the session's profile authority is no longer active", type: "Tracker")
            return
        }
        switch mediaInfo {
        case .movie(let id, _, _, _):
            let progress: Double? = accessQueue.sync {
                guard self.profileMutationAuthorityIsCurrent(authority) else { return nil }
                return self.progressData.findMovie(id: id)?.progress ?? 0
            }
            guard let progress else { return }
            TrackerManager.shared.syncTraktMoviePlaybackProgress(
                movieId: id,
                progress: progress,
                force: true,
                requiredOwner: authority.profileID,
                progressAuthority: authority
            )
        case .episode(let showId, let seasonNumber, let episodeNumber, _, _, _):
            let progress: Double? = accessQueue.sync {
                guard self.profileMutationAuthorityIsCurrent(authority) else { return nil }
                return self.progressData.findEpisode(showId: showId, season: seasonNumber, episode: episodeNumber)?.progress ?? 0
            }
            guard let progress else { return }
            TrackerManager.shared.syncTraktEpisodePlaybackProgress(
                showId: showId,
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber,
                progress: progress,
                playbackContext: playbackContext?.forEpisodeNumber(episodeNumber),
                force: true,
                requiredOwner: authority.profileID,
                progressAuthority: authority
            )
        }
    }

    func addPeriodicTimeObserver(
        to player: AVPlayer,
        for mediaInfo: MediaInfo,
        playbackContext: EpisodePlaybackContext? = nil,
        owner: UUID? = nil
    ) -> Any? {
        let interval = CMTime(seconds: 1.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        let sessionOwner = owner ?? ProfileManager.shared.activeProfileID
        guard let sessionAuthority = profileMutationAuthority(requiredOwner: sessionOwner) else {
            Logger.shared.log(
                "Abandoned periodic progress observer creation: its profile authority is no longer active",
                type: "Progress"
            )
            return nil
        }

        var didReportAbandonedSession = false

        return player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard ProfileManager.shared.isStillActive(sessionOwner),
                  self?.profileMutationAuthorityIsCurrent(sessionAuthority) == true else {
                if !didReportAbandonedSession {
                    didReportAbandonedSession = true
                    Logger.shared.log("Abandoned periodic progress writes: the playing session's profile is no longer active", type: "Progress")
                }
                return
            }
            guard let self = self,
                  let currentItem = player.currentItem,
                  currentItem.duration.seconds.isFinite,
                  currentItem.duration.seconds >= 5 else {
                return
            }

            let currentTime = time.seconds
            let duration = currentItem.duration.seconds

            guard currentTime >= 0 && currentTime <= duration else { return }

            switch mediaInfo {
            case .movie(let id, let title, let posterURL, _):
                self.updateMovieProgress(
                    movieId: id,
                    title: title,
                    currentTime: currentTime,
                    totalDuration: duration,
                    posterURL: posterURL,
                    owner: sessionOwner
                )
                if player.timeControlStatus == .playing {
                    TrackerManager.shared.scrobbleTraktPlayback(
                        .start,
                        for: mediaInfo,
                        progress: currentTime / duration,
                        requiredOwner: sessionOwner,
                        progressAuthority: sessionAuthority
                    )
                }

            case .episode(let showId, let seasonNumber, let episodeNumber, let showTitle, let showPosterURL, let isAnime):
                let resolvedPlaybackContext = playbackContext?.forEpisodeNumber(episodeNumber)
                self.updateEpisodeProgress(
                    showId: showId,
                    seasonNumber: seasonNumber,
                    episodeNumber: episodeNumber,
                    currentTime: currentTime,
                    totalDuration: duration,
                    showTitle: showTitle,
                    showPosterURL: showPosterURL,
                    playbackContext: resolvedPlaybackContext,
                    isAnime: isAnime || playbackContext?.hasAnimeMediaId == true,
                    owner: sessionOwner
                )
                if player.timeControlStatus == .playing {
                    TrackerManager.shared.scrobbleTraktPlayback(
                        .start,
                        for: mediaInfo,
                        progress: currentTime / duration,
                        playbackContext: resolvedPlaybackContext,
                        requiredOwner: sessionOwner,
                        progressAuthority: sessionAuthority
                    )
                }
            }
        }
    }

}

struct WatchNextCandidate {
    let tmdbId: Int
    let title: String
    let posterURL: String?
    let seasonNumber: Int
    let episodeNumber: Int
    let lastUpdated: Date
    let playbackContext: EpisodePlaybackContext?
    let isAnime: Bool
}

enum AnimeSyntheticSeasonKey {

    private static let base = 100_000

    static func make(providerID: Int) -> Int? {
        let maximumIdentifier = ProgressPersistencePolicy.maximumIdentifier
        guard providerID != 0,
              providerID != Int.min,
              (-maximumIdentifier...maximumIdentifier).contains(providerID) else {
            return nil
        }
        if providerID > 0 {
            let (value, overflow) = base.addingReportingOverflow(providerID)
            return overflow ? nil : value
        }
        let (value, overflow) = (-base).addingReportingOverflow(providerID)
        return overflow ? nil : value
    }

    static func providerID(from seasonNumber: Int) -> Int? {
        if seasonNumber > base {
            return seasonNumber - base
        }
        if seasonNumber < -base {
            return seasonNumber + base
        }
        return nil
    }

    static func isSynthetic(_ seasonNumber: Int) -> Bool {
        providerID(from: seasonNumber) != nil
    }
}

struct EpisodePlaybackContext: Codable, Equatable, Sendable {
    let localSeasonNumber: Int
    let localEpisodeNumber: Int
    let anilistMediaId: Int?

    let canonicalAniListMediaId: Int?

    let malMediaId: Int?
    let kitsuMediaId: Int?
    let tmdbSeasonNumber: Int?
    let tmdbEpisodeNumber: Int?
    let tmdbEpisodeOffset: Int?
    let animeAbsoluteEpisodeNumber: Int?
    let animeSeasonEpisodeCount: Int?
    let isSpecial: Bool
    let titleOnlySearch: Bool

    init(
        localSeasonNumber: Int,
        localEpisodeNumber: Int,
        anilistMediaId: Int?,
        canonicalAniListMediaId: Int? = nil,
        malMediaId: Int? = nil,
        kitsuMediaId: Int? = nil,
        tmdbSeasonNumber: Int?,
        tmdbEpisodeNumber: Int?,
        tmdbEpisodeOffset: Int?,
        animeAbsoluteEpisodeNumber: Int?,
        animeSeasonEpisodeCount: Int?,
        isSpecial: Bool,
        titleOnlySearch: Bool
    ) {
        self.localSeasonNumber = localSeasonNumber
        self.localEpisodeNumber = localEpisodeNumber
        self.anilistMediaId = anilistMediaId
        self.canonicalAniListMediaId = canonicalAniListMediaId
        self.malMediaId = malMediaId
        self.kitsuMediaId = kitsuMediaId
        self.tmdbSeasonNumber = tmdbSeasonNumber
        self.tmdbEpisodeNumber = tmdbEpisodeNumber
        self.tmdbEpisodeOffset = tmdbEpisodeOffset
        self.animeAbsoluteEpisodeNumber = animeAbsoluteEpisodeNumber
        self.animeSeasonEpisodeCount = animeSeasonEpisodeCount
        self.isSpecial = isSpecial
        self.titleOnlySearch = titleOnlySearch
    }

    var resolvedTMDBSeasonNumber: Int? {
        tmdbSeasonNumber
    }

    var hasAnimeMediaId: Bool {
        anilistMediaId != nil || canonicalAniListMediaId != nil || kitsuMediaId != nil
    }

    var positiveAniListMediaId: Int? {
        if let canonicalAniListMediaId, canonicalAniListMediaId > 0 {
            return canonicalAniListMediaId
        }
        guard let anilistMediaId, anilistMediaId > 0 else { return nil }
        return anilistMediaId
    }

    var exactMALMediaId: Int? {
        if let malMediaId, malMediaId > 0 { return malMediaId }
        guard let anilistMediaId,
              anilistMediaId < 0,
              anilistMediaId != Int.min else { return nil }
        return -anilistMediaId
    }

    var resolvedTMDBEpisodeNumber: Int? {
        if let tmdbEpisodeNumber {
            return tmdbEpisodeNumber
        }
        guard tmdbSeasonNumber != nil, let tmdbEpisodeOffset else {
            return nil
        }
        let (result, overflow) = tmdbEpisodeOffset.addingReportingOverflow(localEpisodeNumber)
        return overflow ? nil : result
    }

    func forEpisodeNumber(_ episodeNumber: Int) -> EpisodePlaybackContext {
        let absoluteEpisodeNumber = animeAbsoluteEpisodeNumber.flatMap { absolute -> Int? in
            let (base, subtractionOverflow) = absolute.subtractingReportingOverflow(
                localEpisodeNumber
            )
            guard !subtractionOverflow else { return nil }
            let (translated, additionOverflow) = base.addingReportingOverflow(episodeNumber)
            guard !additionOverflow else { return nil }
            return max(1, translated)
        }
        let translatedTMDBEpisodeNumber = tmdbEpisodeOffset.flatMap { offset -> Int? in
            let (translated, overflow) = offset.addingReportingOverflow(episodeNumber)
            return overflow ? nil : translated
        } ?? (episodeNumber == localEpisodeNumber ? tmdbEpisodeNumber : nil)

        return EpisodePlaybackContext(
            localSeasonNumber: localSeasonNumber,
            localEpisodeNumber: episodeNumber,
            anilistMediaId: anilistMediaId,
            canonicalAniListMediaId: canonicalAniListMediaId,
            malMediaId: malMediaId,
            kitsuMediaId: kitsuMediaId,
            tmdbSeasonNumber: tmdbSeasonNumber,
            tmdbEpisodeNumber: translatedTMDBEpisodeNumber,
            tmdbEpisodeOffset: tmdbEpisodeOffset,
            animeAbsoluteEpisodeNumber: absoluteEpisodeNumber,
            animeSeasonEpisodeCount: animeSeasonEpisodeCount,
            isSpecial: isSpecial,
            titleOnlySearch: titleOnlySearch
        )
    }

    func withKitsuMediaId(_ kitsuId: Int?) -> EpisodePlaybackContext {
        EpisodePlaybackContext(
            localSeasonNumber: localSeasonNumber,
            localEpisodeNumber: localEpisodeNumber,
            anilistMediaId: anilistMediaId,
            canonicalAniListMediaId: canonicalAniListMediaId,
            malMediaId: malMediaId,
            kitsuMediaId: kitsuId ?? kitsuMediaId,
            tmdbSeasonNumber: tmdbSeasonNumber,
            tmdbEpisodeNumber: tmdbEpisodeNumber,
            tmdbEpisodeOffset: tmdbEpisodeOffset,
            animeAbsoluteEpisodeNumber: animeAbsoluteEpisodeNumber,
            animeSeasonEpisodeCount: animeSeasonEpisodeCount,
            isSpecial: isSpecial,
            titleOnlySearch: titleOnlySearch
        )
    }

    func withCanonicalAniListMediaId(_ canonicalID: Int?) -> EpisodePlaybackContext {
        EpisodePlaybackContext(
            localSeasonNumber: localSeasonNumber,
            localEpisodeNumber: localEpisodeNumber,
            anilistMediaId: anilistMediaId,
            canonicalAniListMediaId: canonicalID ?? canonicalAniListMediaId,
            malMediaId: malMediaId,
            kitsuMediaId: kitsuMediaId,
            tmdbSeasonNumber: tmdbSeasonNumber,
            tmdbEpisodeNumber: tmdbEpisodeNumber,
            tmdbEpisodeOffset: tmdbEpisodeOffset,
            animeAbsoluteEpisodeNumber: animeAbsoluteEpisodeNumber,
            animeSeasonEpisodeCount: animeSeasonEpisodeCount,
            isSpecial: isSpecial,
            titleOnlySearch: titleOnlySearch
        )
    }

    func withMALMediaId(_ malID: Int?) -> EpisodePlaybackContext {
        EpisodePlaybackContext(
            localSeasonNumber: localSeasonNumber,
            localEpisodeNumber: localEpisodeNumber,
            anilistMediaId: anilistMediaId,
            canonicalAniListMediaId: canonicalAniListMediaId,
            malMediaId: malID ?? malMediaId,
            kitsuMediaId: kitsuMediaId,
            tmdbSeasonNumber: tmdbSeasonNumber,
            tmdbEpisodeNumber: tmdbEpisodeNumber,
            tmdbEpisodeOffset: tmdbEpisodeOffset,
            animeAbsoluteEpisodeNumber: animeAbsoluteEpisodeNumber,
            animeSeasonEpisodeCount: animeSeasonEpisodeCount,
            isSpecial: isSpecial,
            titleOnlySearch: titleOnlySearch
        )
    }
}

enum AnimeEpisodeIdentityPolicy {
    static func isSameEpisode(
        _ lhs: EpisodePlaybackContext,
        _ rhs: EpisodePlaybackContext,
        providerAliases: [Int: Int] = [:],
        allowLegacyLocalCoordinates: Bool = false
    ) -> Bool {
        func canonical(_ id: Int) -> Int { providerAliases[id] ?? id }
        func hasSecondaryContradiction() -> Bool {
            if let lhsKitsu = lhs.kitsuMediaId,
               let rhsKitsu = rhs.kitsuMediaId,
               lhsKitsu != rhsKitsu { return true }
            if let lhsSeason = lhs.resolvedTMDBSeasonNumber,
               let lhsEpisode = lhs.resolvedTMDBEpisodeNumber,
               let rhsSeason = rhs.resolvedTMDBSeasonNumber,
               let rhsEpisode = rhs.resolvedTMDBEpisodeNumber,
               (lhsSeason != rhsSeason || lhsEpisode != rhsEpisode) {
                return true
            }
            return false
        }

        if let lhsRaw = lhs.anilistMediaId,
           let rhsRaw = rhs.anilistMediaId,
           lhsRaw == rhsRaw {
            if let lhsCanonical = lhs.canonicalAniListMediaId,
               let rhsCanonical = rhs.canonicalAniListMediaId,
               lhsCanonical != rhsCanonical { return false }
            return !hasSecondaryContradiction()
                && lhs.localEpisodeNumber == rhs.localEpisodeNumber
        }

        let lhsProvider = lhs.canonicalAniListMediaId
            ?? lhs.anilistMediaId.map(canonical)
        let rhsProvider = rhs.canonicalAniListMediaId
            ?? rhs.anilistMediaId.map(canonical)

        if let lhsProvider, let rhsProvider {
            let sameNamespace = (lhsProvider > 0) == (rhsProvider > 0)
            if lhsProvider == rhsProvider {
                return !hasSecondaryContradiction()
                    && lhs.localEpisodeNumber == rhs.localEpisodeNumber
            }

            if sameNamespace { return false }
        }

        if let lhsMAL = lhs.exactMALMediaId,
           let rhsMAL = rhs.exactMALMediaId,
           lhsMAL == rhsMAL,
           !hasSecondaryContradiction(),
           lhs.localEpisodeNumber == rhs.localEpisodeNumber {
            return true
        }

        if let lhsKitsu = lhs.kitsuMediaId,
           let rhsKitsu = rhs.kitsuMediaId,
           lhsKitsu == rhsKitsu,
           !hasSecondaryContradiction(),
           lhs.localEpisodeNumber == rhs.localEpisodeNumber {
            return true
        }

        if let lhsSeason = lhs.resolvedTMDBSeasonNumber,
           let lhsEpisode = lhs.resolvedTMDBEpisodeNumber,
           let rhsSeason = rhs.resolvedTMDBSeasonNumber,
           let rhsEpisode = rhs.resolvedTMDBEpisodeNumber,
           lhsSeason == rhsSeason,
           lhsEpisode == rhsEpisode,
           !hasSecondaryContradiction() {
            return true
        }

        guard lhsProvider == nil,
              rhsProvider == nil,
              lhs.kitsuMediaId == nil,
              rhs.kitsuMediaId == nil,
              allowLegacyLocalCoordinates else { return false }
        return lhs.localSeasonNumber == rhs.localSeasonNumber
            && lhs.localEpisodeNumber == rhs.localEpisodeNumber
    }
}

enum MediaInfo {
    case movie(id: Int, title: String, posterURL: String? = nil, isAnime: Bool = false)
    case episode(showId: Int, seasonNumber: Int, episodeNumber: Int, showTitle: String? = nil, showPosterURL: String? = nil, isAnime: Bool = false)
}
