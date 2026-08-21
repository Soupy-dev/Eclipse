//
//  KanzenRunnerController.swift
//  Kanzen
//
//  Created by Dawud Osman on 12/05/2025.
//

import Foundation

final class KanzenRunnerController {
    private let moduleRunner: KanzenModuleRunner

    init(moduleRunner: KanzenModuleRunner) {
        self.moduleRunner = moduleRunner
    }

    func loadScript(
        _ script: String,
        moduleID: UUID,
        moduleName: String,
        isNovel: Bool = false
    ) async throws {
        try await moduleRunner.loadScript(
            script,
            moduleID: moduleID,
            moduleName: moduleName,
            isNovel: isNovel
        )
    }

    func extractImages(params: Any) async throws -> [String]? {
        guard let raw = try await moduleRunner.invoke("extractImages", arguments: [params]) else {
            return nil
        }
        return (raw as? [Any])?.compactMap { $0 as? String }.prefix(512).map { $0 }
    }

    func homeSections(page: Int = 0) async throws -> [[String: Any]]? {
        arrayOfDictionaries(
            from: try await moduleRunner.invoke(
                "homeSections",
                arguments: [page],
                optional: true
            )
        )
    }

    func homeSectionItems(sectionId: String, page: Int = 0) async throws -> [[String: Any]]? {
        arrayOfDictionaries(
            from: try await moduleRunner.invoke(
                "homeSectionItems",
                arguments: [sectionId, page],
                optional: true
            )
        )
    }

    func searchFilters() async throws -> [[String: Any]]? {
        arrayOfDictionaries(
            from: try await moduleRunner.invoke(
                "searchFilters",
                arguments: [],
                optional: true
            )
        )
    }

    func searchAdvanced(
        _ input: String,
        filters: [String: Any],
        page: Int = 0
    ) async throws -> [[String: Any]]? {
        let primary = try await moduleRunner.invoke(
            "searchResultsAdvanced",
            arguments: [input, filters, page],
            optional: true
        )
        if let primary {
            return arrayOfDictionaries(from: primary)
        }
        return arrayOfDictionaries(
            from: try await moduleRunner.invoke(
                "advancedSearchResults",
                arguments: [input, filters, page],
                optional: true
            )
        )
    }

    func extractChapters(params: Any) async throws -> Any? {
        try await moduleRunner.invoke("extractChapters", arguments: [params])
    }

    func extractDetails(params: Any) async throws -> [String: Any]? {
        try await moduleRunner.invoke("extractDetails", arguments: [params]) as? [String: Any]
    }

    func extractText(params: Any) async throws -> String? {
        try await moduleRunner.invoke("extractText", arguments: [params]) as? String
    }

    func searchInput(_ input: String, page: Int = 0) async throws -> [[String: Any]]? {
        arrayOfDictionaries(
            from: try await moduleRunner.invoke(
                "searchResults",
                arguments: [input, page]
            )
        )
    }

    private func arrayOfDictionaries(from raw: Any?) -> [[String: Any]]? {
        if let values = raw as? [[String: Any]] {
            return Array(values.prefix(512))
        }
        if let values = raw as? [Any] {
            return values.prefix(512).compactMap { $0 as? [String: Any] }
        }
        if let dictionary = raw as? [String: Any] {
            for key in [
                "sections", "items", "results", "data", "home", "catalogs",
                "filters", "filterGroups", "groups"
            ] {
                if let values = dictionary[key] as? [[String: Any]] {
                    return Array(values.prefix(512))
                }
                if let values = dictionary[key] as? [Any] {
                    return values.prefix(512).compactMap { $0 as? [String: Any] }
                }
            }
        }
        return nil
    }
}
