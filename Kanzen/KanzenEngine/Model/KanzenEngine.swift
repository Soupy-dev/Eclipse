//
//  KanzenEngine.swift
//  Kanzen
//
//  Created by Dawud Osman on 12/05/2025.
//

import SwiftUI

final class KanzenEngine: ObservableObject, @unchecked Sendable {
    private let controller: KanzenRunnerController

    init() {
        controller = KanzenRunnerController(moduleRunner: KanzenModuleRunner())
    }

    init(
        workerPool: KanzenLegacyJavaScriptWorkerPool,
        quarantineStore: KanzenLegacyJavaScriptQuarantineStore,
        timeouts: KanzenModuleRunner.Timeouts
    ) {
        controller = KanzenRunnerController(
            moduleRunner: KanzenModuleRunner(
                workerPool: workerPool,
                quarantineStore: quarantineStore,
                timeouts: timeouts
            )
        )
    }

    func loadScript(
        _ script: String,
        module: ModuleDataContainer
    ) async throws {
        try await loadScript(
            script,
            moduleID: module.id,
            moduleName: module.moduleData.sourceName,
            isNovel: module.moduleData.novel == true
        )
    }

    func loadScript(
        _ script: String,
        moduleID: UUID,
        moduleName: String,
        isNovel: Bool = false
    ) async throws {
        try await controller.loadScript(
            script,
            moduleID: moduleID,
            moduleName: moduleName,
            isNovel: isNovel
        )
    }

    func extractDetails(params: Any) async throws -> [String: Any]? {
        try await controller.extractDetails(params: params)
    }

    func extractImages(params: Any) async throws -> [String]? {
        try await controller.extractImages(params: params)
    }

    func homeSections(page: Int = 0) async throws -> [[String: Any]]? {
        try await controller.homeSections(page: page)
    }

    func homeSectionItems(sectionId: String, page: Int = 0) async throws -> [[String: Any]]? {
        try await controller.homeSectionItems(sectionId: sectionId, page: page)
    }

    func searchFilters() async throws -> [[String: Any]]? {
        try await controller.searchFilters()
    }

    func searchAdvanced(
        _ input: String,
        filters: [String: Any],
        page: Int = 0
    ) async throws -> [[String: Any]]? {
        try await controller.searchAdvanced(input, filters: filters, page: page)
    }

    func extractChapters(params: Any) async throws -> Any? {
        try await controller.extractChapters(params: params)
    }

    func extractText(params: Any) async throws -> String? {
        try await controller.extractText(params: params)
    }

    func searchInput(_ input: String, page: Int = 0) async throws -> [[String: Any]]? {
        try await controller.searchInput(input, page: page)
    }

    // Transitional callback façades remain asynchronous. Legacy views are
    // migrated to the async functions below; these keep reader/controller
    // objects source-compatible without ever evaluating JSC on the caller.
    func extractDetails(params: Any, completion: @escaping ([String: Any]?) -> Void) {
        bridge({ try await self.extractDetails(params: params) }, completion: completion)
    }

    func extractImages(params: Any, completion: @escaping ([String]?) -> Void) {
        bridge({ try await self.extractImages(params: params) }, completion: completion)
    }

    func homeSections(page: Int = 0, completion: @escaping ([[String: Any]]?) -> Void) {
        bridge({ try await self.homeSections(page: page) }, completion: completion)
    }

    func homeSectionItems(
        sectionId: String,
        page: Int = 0,
        completion: @escaping ([[String: Any]]?) -> Void
    ) {
        bridge(
            { try await self.homeSectionItems(sectionId: sectionId, page: page) },
            completion: completion
        )
    }

    func searchFilters(completion: @escaping ([[String: Any]]?) -> Void) {
        bridge({ try await self.searchFilters() }, completion: completion)
    }

    func searchAdvanced(
        _ input: String,
        filters: [String: Any],
        page: Int = 0,
        completion: @escaping ([[String: Any]]?) -> Void
    ) {
        bridge(
            { try await self.searchAdvanced(input, filters: filters, page: page) },
            completion: completion
        )
    }

    func extractChapters(params: Any, completion: @escaping (Any?) -> Void) {
        bridge({ try await self.extractChapters(params: params) }, completion: completion)
    }

    func extractText(params: Any, completion: @escaping (String?) -> Void) {
        bridge({ try await self.extractText(params: params) }, completion: completion)
    }

    func searchInput(
        _ input: String,
        page: Int = 0,
        completion: @escaping ([[String: Any]]?) -> Void
    ) {
        bridge({ try await self.searchInput(input, page: page) }, completion: completion)
    }

    private func bridge<Value>(
        _ operation: @escaping () async throws -> Value?,
        completion: @escaping (Value?) -> Void
    ) {
        Task {
            let value: Value?
            do {
                value = try await operation()
            } catch {
                ReaderLogger.shared.log(
                    "Legacy module operation failed: \(error.localizedDescription)",
                    type: "Error"
                )
                value = nil
            }
            await MainActor.run {
                completion(value)
            }
        }
    }
}
