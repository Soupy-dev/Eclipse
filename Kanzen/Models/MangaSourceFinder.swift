//
//  MangaSourceFinder.swift
//  Kanzen
//
//  Created by Eclipse on 2025.
//

import Foundation

struct SourceMatch: Identifiable {
    let id = UUID()
    let module: ModuleDataContainer
    let manga: Manga
    let titleScore: Double
    let chapterCount: Int?
    let confidence: SourceMatchConfidence

    enum SourceMatchConfidence: Comparable {
        case low, medium, high
    }
}

final class MangaSourceFinder: ObservableObject {
    @Published var matches: [SourceMatch] = []
    @Published var isSearching = false
    @Published var hasFinished = false

    private var searchGeneration = UUID()
    private var searchTask: Task<Void, Never>?
    private var refineTask: Task<Void, Never>?

    deinit {
        searchTask?.cancel()
        refineTask?.cancel()
    }

    func searchAllModules(for manga: AniListManga) {
        searchTask?.cancel()
        refineTask?.cancel()

        let generation = UUID()
        searchGeneration = generation
        matches = []
        isSearching = true
        hasFinished = false

        let isNovel = manga.format == "NOVEL"
        let modules = ModuleManager.shared.modules.filter {
            ($0.moduleData.novel == true) == isNovel
        }
        let titles = manga.allTitleCandidates
        guard !modules.isEmpty, !titles.isEmpty else {
            isSearching = false
            hasFinished = true
            return
        }

        // Process installed legacy modules in one structured task. The JSC
        // runner itself owns exactly two bounded lanes; repeated UI reloads
        // cancel this coordinator instead of stranding GCD worker threads.
        searchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var allMatches: [SourceMatch] = []
            for module in modules {
                guard !Task.isCancelled, searchGeneration == generation else { return }
                allMatches.append(contentsOf: await searchModule(module, titles: titles))
            }
            guard !Task.isCancelled, searchGeneration == generation else { return }
            matches = sorted(allMatches)
            isSearching = false
            hasFinished = true
            searchTask = nil
        }
    }

    @MainActor
    private func searchModule(
        _ module: ModuleDataContainer,
        titles: [String]
    ) async -> [SourceMatch] {
        let engine = KanzenEngine()
        do {
            let script = try ModuleManager.shared.getModuleScript(module: module)
            try await engine.loadScript(script, module: module)
        } catch {
            ReaderLogger.shared.log(
                "SourceFinder failed to load legacy module \(module.moduleData.sourceName): \(error.localizedDescription)",
                type: "Error"
            )
            return []
        }

        var seenIDs = Set<String>()
        var results: [Manga] = []
        for title in titles {
            guard !Task.isCancelled else { return [] }
            do {
                let raw = try await engine.searchInput(title, page: 0) ?? []
                for dictionary in raw {
                    guard let resultTitle = dictionary["title"] as? String else { continue }
                    let imageURL = (dictionary["imageURL"] as? String)
                        ?? (dictionary["image"] as? String)
                        ?? ""
                    let mangaID = (dictionary["id"] as? String)
                        ?? (dictionary["href"] as? String)
                        ?? ""
                    guard !mangaID.isEmpty,
                          seenIDs.insert("\(module.id.uuidString):\(mangaID)").inserted else {
                        continue
                    }
                    results.append(
                        Manga(
                            title: resultTitle,
                            imageURL: imageURL,
                            mangaId: mangaID,
                            parentModule: module
                        )
                    )
                }
            } catch {
                ReaderLogger.shared.log(
                    "SourceFinder legacy search failed for \(module.moduleData.sourceName): \(error.localizedDescription)",
                    type: "Error"
                )
                return []
            }
        }

        return results.compactMap { result in
            let score = titles.map {
                JaroWinklerSimilarity.calculateSimilarity(
                    original: $0,
                    result: result.title
                )
            }.max() ?? 0
            guard score >= 0.85 else { return nil }
            return SourceMatch(
                module: module,
                manga: result,
                titleScore: score,
                chapterCount: nil,
                confidence: .high
            )
        }
    }

    func refineTopMatchesWithChapterCounts(for manga: AniListManga, topN: Int = 3) {
        refineTask?.cancel()
        let generation = searchGeneration
        let candidates = Array(matches.prefix(max(0, min(topN, 8))))
        guard !candidates.isEmpty else { return }
        let expectedChapterCount = manga.chapters

        refineTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var refined: [SourceMatch] = []
            for candidate in candidates {
                guard !Task.isCancelled, searchGeneration == generation else { return }
                refined.append(
                    await refinedMatch(
                        candidate,
                        expectedChapterCount: expectedChapterCount
                    )
                )
            }
            guard !Task.isCancelled, searchGeneration == generation else { return }
            var updated = matches
            updated.removeFirst(min(candidates.count, updated.count))
            updated.insert(contentsOf: sorted(refined), at: 0)
            matches = updated
            refineTask = nil
        }
    }

    @MainActor
    private func refinedMatch(
        _ candidate: SourceMatch,
        expectedChapterCount: Int?
    ) async -> SourceMatch {
        var chapterCount: Int?
        do {
            let engine = KanzenEngine()
            let script = try ModuleManager.shared.getModuleScript(module: candidate.module)
            try await engine.loadScript(script, module: candidate.module)
            if let result = try await engine.extractChapters(params: candidate.manga.mangaId) {
                let count: Int
                if let dictionary = result as? [String: Any] {
                    count = dictionary.values.reduce(into: 0) { total, value in
                        total += (value as? [Any])?.count ?? 0
                    }
                } else {
                    count = (result as? [Any])?.count ?? 0
                }
                chapterCount = count > 0 ? count : nil
            }
        } catch {
            return candidate
        }

        var confidence = candidate.confidence
        if let expectedChapterCount, let chapterCount {
            let ratio = Double(chapterCount) / Double(max(expectedChapterCount, 1))
            if ratio >= 0.9, candidate.titleScore >= 0.75 {
                confidence = .high
            }
        }
        return SourceMatch(
            module: candidate.module,
            manga: candidate.manga,
            titleScore: candidate.titleScore,
            chapterCount: chapterCount,
            confidence: confidence
        )
    }

    private func sorted(_ values: [SourceMatch]) -> [SourceMatch] {
        values.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            let lhsCount = lhs.chapterCount ?? 0
            let rhsCount = rhs.chapterCount ?? 0
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            return lhs.titleScore > rhs.titleScore
        }
    }
}
