//
//  AlgorithmManager.swift
//  Sora
//
//  Created by Francesco on 20/08/25.
//

import Foundation

enum SimilarityAlgorithm: String, CaseIterable {
    case hybrid = "hybrid"
    case jaroWinkler = "jaro_winkler"
    case levenshtein = "levenshtein"

    var displayName: String {
        switch self {
        case .hybrid:
            return "Hybrid"
        case .jaroWinkler:
            return "Jaro-Winkler Similarity"
        case .levenshtein:
            return "Levenshtein Distance"
        }
    }

    var description: String {
        switch self {
        case .hybrid:
            return "Combines both algorithms for optimal matching across different string types and lengths."
        case .jaroWinkler:
            return "When matching names, titles, or short strings where prefix similarity are important."
        case .levenshtein:
            return "When you need precise differences across all text available."
        }
    }
}

class AlgorithmManager: ObservableObject {
    static let shared = AlgorithmManager()

    private struct SimilarityCacheKey: Hashable {
        let algorithm: SimilarityAlgorithm
        let original: String
        let result: String
    }

    private static let similarityCacheLimit = 4_000
    private let similarityCacheLock = NSLock()
    private var similarityCache: [SimilarityCacheKey: Double] = [:]

    private var isReloadingForProfileSwitch = false

    @Published var selectedAlgorithm: SimilarityAlgorithm {
        didSet {
            guard !isReloadingForProfileSwitch else { return }
            ProfileSettingsStore.active.set(selectedAlgorithm.rawValue, forKey: "selectedSimilarityAlgorithm")
        }
    }

    private init() {
        let savedAlgorithm = ProfileSettingsStore.active.string(forKey: "selectedSimilarityAlgorithm") ?? SimilarityAlgorithm.hybrid.rawValue
        self.selectedAlgorithm = SimilarityAlgorithm(rawValue: savedAlgorithm) ?? .hybrid
    }

    func reloadForActiveProfile() {
        isReloadingForProfileSwitch = true
        defer { isReloadingForProfileSwitch = false }
        let saved = ProfileSettingsStore.active.string(forKey: "selectedSimilarityAlgorithm")
            ?? SimilarityAlgorithm.hybrid.rawValue
        selectedAlgorithm = SimilarityAlgorithm(rawValue: saved) ?? .hybrid
    }

    func calculateSimilarity(original: String, result: String) -> Double {
        guard !original.isEmpty && !result.isEmpty else {
            return original.isEmpty && result.isEmpty ? 1.0 : 0.0
        }

        let cleanOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanResult = result.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanOriginal.isEmpty && !cleanResult.isEmpty else {
            return cleanOriginal.isEmpty && cleanResult.isEmpty ? 1.0 : 0.0
        }

        let algorithm = selectedAlgorithm
        let key = SimilarityCacheKey(
            algorithm: algorithm,
            original: cleanOriginal,
            result: cleanResult
        )

        similarityCacheLock.lock()
        let cachedScore = similarityCache[key]
        similarityCacheLock.unlock()
        if let cachedScore {
            return cachedScore
        }

        let score: Double
        switch algorithm {
        case .levenshtein:
            score = LevenshteinDistance.calculateSimilarity(original: cleanOriginal, result: cleanResult)
        case .jaroWinkler:
            score = JaroWinklerSimilarity.calculateSimilarity(original: cleanOriginal, result: cleanResult)
        case .hybrid:
            score = HybridSimilarity.calculateSimilarity(original: cleanOriginal, result: cleanResult)
        }

        similarityCacheLock.lock()
        if similarityCache.count >= AlgorithmManager.similarityCacheLimit {
            similarityCache.removeAll(keepingCapacity: true)
        }
        similarityCache[key] = score
        similarityCacheLock.unlock()

        return score
    }
}
