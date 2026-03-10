//
//  MangaSourceFinder.swift
//  Kanzen
//
//  Created by Luna on 2025.
//

import Foundation

// MARK: - Source Match Result

/// A single search result from a module, scored against the AniList manga.
struct SourceMatch: Identifiable {
    let id = UUID()
    let module: ModuleDataContainer
    let manga: Manga            // The module's search result
    let titleScore: Double      // Jaro-Winkler similarity (0…1)
    let chapterCount: Int?      // Number of chapters if we extracted them
    let confidence: SourceMatchConfidence

    enum SourceMatchConfidence: Comparable {
        case low, medium, high
    }
}

// MARK: - Source Finder

/// Searches all installed modules in parallel for a given AniList manga,
/// scores and ranks the results, and can auto-pick the best one.
final class MangaSourceFinder: ObservableObject {
    @Published var matches: [SourceMatch] = []
    @Published var isSearching = false
    @Published var hasFinished = false

    /// The auto-picked best match (only used in auto mode).
    @Published var autoPickedMatch: SourceMatch?

    /// Search all installed modules for the given AniList manga.
    /// Uses all title variants (English, Romaji, Native) for each module.
    /// Filters modules by type: novel modules for NOVEL format, non-novel for everything else.
    func searchAllModules(for manga: AniListManga) {
        let isNovel = manga.format == "NOVEL"
        let modules = ModuleManager.shared.modules.filter { module in
            let moduleIsNovel = module.moduleData.novel == true
            return moduleIsNovel == isNovel
        }
        guard !modules.isEmpty else {
            hasFinished = true
            return
        }

        isSearching = true
        matches = []
        autoPickedMatch = nil

        let titleCandidates = manga.allTitleCandidates
        guard !titleCandidates.isEmpty else {
            isSearching = false
            hasFinished = true
            return
        }

        let aniListChapters = manga.chapters
        let group = DispatchGroup()
        var allMatches: [SourceMatch] = []
        let lock = NSLock()

        for module in modules {
            group.enter()
            searchModule(module, titles: titleCandidates, aniListChapters: aniListChapters) { moduleMatches in
                lock.lock()
                allMatches.append(contentsOf: moduleMatches)
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }

            // Sort: highest confidence first, then highest chapter count, then highest title score
            let sorted = allMatches.sorted { a, b in
                if a.confidence != b.confidence { return a.confidence > b.confidence }
                let aC = a.chapterCount ?? 0
                let bC = b.chapterCount ?? 0
                if aC != bC { return aC > bC }
                return a.titleScore > b.titleScore
            }

            self.matches = sorted
            self.autoPickedMatch = sorted.first
            self.isSearching = false
            self.hasFinished = true
        }
    }

    // MARK: - Per-Module Search

    private func searchModule(
        _ module: ModuleDataContainer,
        titles: [String],
        aniListChapters: Int?,
        completion: @escaping ([SourceMatch]) -> Void
    ) {
        // Load module script
        let engine = KanzenEngine()
        do {
            let script = try ModuleManager.shared.getModuleScript(module: module)
            try engine.loadScript(script)
        } catch {
            Logger.shared.log("SourceFinder: Failed to load module \(module.moduleData.sourceName): \(error.localizedDescription)", type: "Error")
            completion([])
            return
        }

        // Search with each title variant, collect unique results
        var seenIds = Set<String>()
        var allResults: [Manga] = []
        let titleGroup = DispatchGroup()
        let resultLock = NSLock()

        for title in titles {
            titleGroup.enter()
            engine.searchInput(title, page: 0) { results in
                if let results = results {
                    let mangas = results.compactMap { dict -> Manga? in
                        guard let t = dict["title"] as? String else { return nil }
                        let imageURL = (dict["imageURL"] as? String) ?? (dict["image"] as? String) ?? ""
                        let mangaId = (dict["id"] as? String) ?? (dict["href"] as? String) ?? ""
                        guard !mangaId.isEmpty else { return nil }
                        return Manga(title: t, imageURL: imageURL, mangaId: mangaId, parentModule: module)
                    }

                    resultLock.lock()
                    for m in mangas {
                        let key = "\(module.id)-\(m.mangaId)"
                        if seenIds.insert(key).inserted {
                            allResults.append(m)
                        }
                    }
                    resultLock.unlock()
                }
                titleGroup.leave()
            }
        }

        titleGroup.notify(queue: .global(qos: .userInitiated)) {
            // Score each result against all title variants — take the best score
            let matches: [SourceMatch] = allResults.compactMap { result in
                let bestScore = titles.map { candidate in
                    JaroWinklerSimilarity.calculateSimilarity(original: candidate, result: result.title)
                }.max() ?? 0.0

                // Only show 85%+ matches
                guard bestScore >= 0.85 else { return nil }

                let confidence: SourceMatch.SourceMatchConfidence = .high

                return SourceMatch(
                    module: module,
                    manga: result,
                    titleScore: bestScore,
                    chapterCount: nil, // We don't fetch chapters during search to keep it fast
                    confidence: confidence
                )
            }

            completion(matches)
        }
    }

    // MARK: - Chapter Count Fetching (for auto mode)

    /// For the top N candidates, fetch chapter counts to make a better auto-pick.
    /// This is only used when auto mode is enabled.
    func refineTopMatchesWithChapterCounts(for manga: AniListManga, topN: Int = 3) {
        let candidates = Array(matches.prefix(topN))
        guard !candidates.isEmpty else { return }

        let aniListChapters = manga.chapters
        let group = DispatchGroup()
        var refined: [SourceMatch] = []
        let lock = NSLock()

        for candidate in candidates {
            group.enter()

            let engine = KanzenEngine()
            do {
                let script = try ModuleManager.shared.getModuleScript(module: candidate.module)
                try engine.loadScript(script)
            } catch {
                lock.lock()
                refined.append(candidate)
                lock.unlock()
                group.leave()
                continue
            }

            engine.extractChapters(params: candidate.manga.mangaId) { result in
                var chapterCount: Int? = nil
                if let result = result {
                    var total = 0
                    if let dictResult = result as? [String: Any] {
                        // Kanzen format: count chapters across all languages
                        for (_, value) in dictResult {
                            if let chapters = value as? [Any?] {
                                total += chapters.count
                            }
                        }
                    } else if let arrResult = result as? [[String: Any]] {
                        // Sora format: flat array of chapter dicts
                        total = arrResult.count
                    }
                    if total > 0 {
                        chapterCount = total
                    }
                }

                // Re-score with chapter info
                var newConfidence = candidate.confidence
                if let aniCh = aniListChapters, let srcCh = chapterCount {
                    // If source has ≥90% of AniList chapters, boost confidence
                    let ratio = Double(srcCh) / Double(max(aniCh, 1))
                    if ratio >= 0.9 && candidate.titleScore >= 0.75 {
                        newConfidence = .high
                    }
                }

                let updated = SourceMatch(
                    module: candidate.module,
                    manga: candidate.manga,
                    titleScore: candidate.titleScore,
                    chapterCount: chapterCount,
                    confidence: newConfidence
                )

                lock.lock()
                refined.append(updated)
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }

            // Re-sort refined matches: confidence → chapter count → title score
            let sorted = refined.sorted { a, b in
                if a.confidence != b.confidence { return a.confidence > b.confidence }
                let aC = a.chapterCount ?? 0
                let bC = b.chapterCount ?? 0
                if aC != bC { return aC > bC }
                return a.titleScore > b.titleScore
            }

            // Replace top N in matches with refined versions
            var updated = self.matches
            let removeCount = min(topN, updated.count)
            updated.removeFirst(removeCount)
            updated.insert(contentsOf: sorted, at: 0)
            self.matches = updated
            self.autoPickedMatch = updated.first
        }
    }
}
