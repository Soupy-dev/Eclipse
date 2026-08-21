import Combine
import Foundation

final class ReaderContentFilter: ObservableObject {
    static let shared = ReaderContentFilter()

    @Published private(set) var isKidsProfileActive: Bool = ProfileManager.shared.isKidsModeActive

    private init() {}

    func activeProfileDidChange() {
        let isKids = ProfileManager.shared.isKidsModeActive
        guard isKids != isKidsProfileActive else { return }
        if Thread.isMainThread {
            isKidsProfileActive = isKids
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.isKidsProfileActive = isKids
            }
        }
    }

    var isKidsModeActive: Bool { ProfileManager.shared.isKidsModeActive }

    func allows(_ item: ReaderExtensionItem) -> Bool {
        guard isKidsModeActive else { return true }
        switch item.maturity {
        case .mature, .unknown:
            return false
        case .safe: break
        }
        if item.tags.contains(where: MaturityRating.containsMatureText) {
            return false
        }
        return allowsText(item.title) && allowsText(item.description ?? "")
    }

    func allows(libraryItem: MangaLibraryItem) -> Bool {
        guard isKidsModeActive else { return true }

        guard let raw = libraryItem.contentRating,
              let rating = ReaderContentRating(rawValue: raw) else {
            return false
        }
        switch rating {
        case .suggestive, .nsfw, .unknown:
            return false
        case .safe: break
        }
        return allowsText(libraryItem.title)
    }

    func allows(downloadedTitle: ReaderDownloadedTitle) -> Bool {
        guard isKidsModeActive else { return true }

        guard let raw = downloadedTitle.contentRating,
              let rating = ReaderContentRating(rawValue: raw) else {
            return false
        }
        switch rating {
        case .suggestive, .nsfw, .unknown:
            return false
        case .safe: break
        }
        return allowsText(downloadedTitle.title)
    }

    func allowsText(_ text: String) -> Bool {
        guard isKidsModeActive else { return true }
        return !MaturityRating.containsMatureText(text)
    }

    func allowsLegacy(title: String, tags: [String]?, description: String?) -> Bool {
        guard isKidsModeActive else { return true }
        if let tags, tags.contains(where: MaturityRating.containsMatureText) {
            return false
        }
        return allowsText(title) && allowsText(description ?? "")
    }

    func derivedLegacyRating(tags: [String]?, description: String?) -> Int? {
        if let tags, tags.contains(where: MaturityRating.containsMatureText) {
            return ReaderContentRating.nsfw.rawValue
        }
        if let description, MaturityRating.containsMatureText(description) {
            return ReaderContentRating.nsfw.rawValue
        }
        return nil
    }

    func derivedReaderExtensionRating(for item: ReaderExtensionItem) -> Int {
        let declared = item.eclipseContentRating.rawValue
        guard let derived = derivedLegacyRating(tags: item.tags, description: item.description) else {
            return declared
        }
        return max(declared, derived)
    }

    func allows(downloadItem: ReaderDownloadItem) -> Bool {
        guard isKidsModeActive else { return true }

        guard let raw = downloadItem.contentRating,
              let rating = ReaderContentRating(rawValue: raw) else {
            return false
        }
        switch rating {
        case .suggestive, .nsfw, .unknown:
            return false
        case .safe: break
        }
        return allowsText(downloadItem.mangaTitle)
    }

    func allows(source: MangaHomeSource) -> Bool {
        guard isKidsModeActive else { return true }
        if let extensionSource = source.readerExtensionSource,
           extensionSource.maturity != .safe {
            return false
        }
        return allowsText(source.name)
    }

    func filterHomeItems(_ items: [MangaHomeItem]) -> [MangaHomeItem] {
        guard isKidsModeActive else { return items }
        return items.filter { item in
            if let extensionItem = item.readerExtensionItem {
                return allows(extensionItem)
            }

            return allowsLegacy(title: item.title, tags: item.tags, description: item.subtitle)
        }
    }

    func filterSources(_ sources: [MangaHomeSource]) -> [MangaHomeSource] {
        guard isKidsModeActive else { return sources }
        return sources.filter { allows(source: $0) }
    }
}
