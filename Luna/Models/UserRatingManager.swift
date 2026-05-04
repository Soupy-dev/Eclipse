//
//  UserRatingManager.swift
//  Luna
//
//  Persists user star ratings (1-10) and private notes for media items,
//  then feeds ratings back into the RecommendationEngine for taste scoring.
//

import Foundation

final class UserRatingManager {
    static let shared = UserRatingManager()

    private struct RatingStore: Codable {
        var ratings: [String: Int] = [:]
        var notes: [String: String] = [:]
    }

    private var ratings: [Int: Int] = [:] // tmdbId -> 1...10
    private var notes: [Int: String] = [:] // tmdbId -> private note/comment
    private let fileURL: URL
    private let lock = NSLock()

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = docs.appendingPathComponent("UserRatings.json")
        let store = Self.load(from: fileURL)
        ratings = store.ratings
        notes = store.notes
    }

    func rating(for tmdbId: Int) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return ratings[tmdbId]
    }

    func note(for tmdbId: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        return notes[tmdbId] ?? ""
    }

    func setRating(_ value: Int, for tmdbId: Int) {
        let clamped = max(1, min(10, value))
        lock.lock()
        ratings[tmdbId] = clamped
        let snapshot = currentStore()
        lock.unlock()
        save(snapshot)
        RecommendationEngine.shared.invalidateCache()
    }

    func removeRating(for tmdbId: Int) {
        lock.lock()
        ratings.removeValue(forKey: tmdbId)
        let snapshot = currentStore()
        lock.unlock()
        save(snapshot)
        RecommendationEngine.shared.invalidateCache()
    }

    func setNote(_ value: String, for tmdbId: Int) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        if trimmed.isEmpty {
            notes.removeValue(forKey: tmdbId)
        } else {
            notes[tmdbId] = value
        }
        let snapshot = currentStore()
        lock.unlock()
        save(snapshot)
    }

    /// All ratings as (tmdbId, stars) for the recommendation engine.
    func allRatings() -> [(tmdbId: Int, stars: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return ratings.map { (tmdbId: $0.key, stars: $0.value) }
    }

    /// All ratings as a dictionary for backup.
    func getRatingsForBackup() -> [String: Int] {
        lock.lock()
        defer { lock.unlock() }
        return Dictionary(uniqueKeysWithValues: ratings.map { (String($0.key), $0.value) })
    }

    /// All private notes as a dictionary for backup.
    func getNotesForBackup() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return Dictionary(uniqueKeysWithValues: notes.map { (String($0.key), $0.value) })
    }

    /// Restores ratings and notes from backup, replacing current data.
    func restoreRatingsAndNotes(ratings backupRatings: [String: Int], notes backupNotes: [String: String]) {
        let restoredRatings = Dictionary(uniqueKeysWithValues: backupRatings.compactMap { key, value -> (Int, Int)? in
            guard let intKey = Int(key) else { return nil }
            return (intKey, max(1, min(10, value)))
        })
        let restoredNotes = Dictionary(uniqueKeysWithValues: backupNotes.compactMap { key, value -> (Int, String)? in
            guard let intKey = Int(key) else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return (intKey, value)
        })

        lock.lock()
        ratings = restoredRatings
        notes = restoredNotes
        let snapshot = currentStore()
        lock.unlock()
        save(snapshot)
        RecommendationEngine.shared.invalidateCache()
    }

    /// Restores ratings from older backup callers, preserving any existing notes.
    func restoreRatings(_ backup: [String: Int]) {
        let existingNotes = getNotesForBackup()
        restoreRatingsAndNotes(ratings: backup, notes: existingNotes)
    }

    // MARK: - Persistence

    private func currentStore() -> RatingStore {
        RatingStore(
            ratings: Dictionary(uniqueKeysWithValues: ratings.map { (String($0.key), $0.value) }),
            notes: Dictionary(uniqueKeysWithValues: notes.map { (String($0.key), $0.value) })
        )
    }

    private func save(_ store: RatingStore) {
        guard let jsonData = try? JSONEncoder().encode(store) else { return }
        try? jsonData.write(to: fileURL, options: .atomic)
    }

    private static func load(from url: URL) -> (ratings: [Int: Int], notes: [Int: String]) {
        guard let data = try? Data(contentsOf: url) else {
            return ([:], [:])
        }

        if let store = try? JSONDecoder().decode(RatingStore.self, from: data) {
            return (
                ratings: parseRatings(store.ratings),
                notes: parseNotes(store.notes)
            )
        }

        // Legacy format was just [tmdbId: rating].
        if let legacyRatings = try? JSONDecoder().decode([String: Int].self, from: data) {
            return (parseRatings(legacyRatings), [:])
        }

        return ([:], [:])
    }

    private static func parseRatings(_ source: [String: Int]) -> [Int: Int] {
        Dictionary(uniqueKeysWithValues: source.compactMap { key, value in
            guard let intKey = Int(key) else { return nil }
            return (intKey, max(1, min(10, value)))
        })
    }

    private static func parseNotes(_ source: [String: String]) -> [Int: String] {
        Dictionary(uniqueKeysWithValues: source.compactMap { key, value in
            guard let intKey = Int(key) else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return (intKey, value)
        })
    }
}
