//
//  MangaHomeViewModel.swift
//  Kanzen
//
//  Created by Luna on 2025.
//

import Foundation
import SwiftUI

final class MangaHomeViewModel: ObservableObject {
    @Published var catalogResults: [String: [AniListManga]] = [:]
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var hasLoadedContent = false

    func loadContent(catalogManager: MangaCatalogManager) {
        guard !hasLoadedContent else { return }

        isLoading = true
        errorMessage = nil

        let needsLightNovels = catalogManager.hasEnabledLightNovelCatalogs

        Task {
            do {
                var allCatalogs = try await AniListMangaService.shared.fetchAllMangaCatalogs()

                if needsLightNovels {
                    let lnCatalogs = try await AniListMangaService.shared.fetchAllLightNovelCatalogs()
                    allCatalogs.merge(lnCatalogs) { _, new in new }
                }

                let catalogSnapshot = allCatalogs
                await MainActor.run {
                    self.catalogResults = catalogSnapshot
                    self.isLoading = false
                    self.hasLoadedContent = true
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    func resetContent() {
        catalogResults = [:]
        isLoading = true
        errorMessage = nil
        hasLoadedContent = false
    }
}
