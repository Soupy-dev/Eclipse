import Foundation

protocol ProfileScopedStore: AnyObject {

    func flushPendingWrites(forProfile outgoing: UUID)

    func switchProfile(to profileID: UUID)

    func discardStore(forProfile profileID: UUID)
}

extension ProfileScopedStore {

    func flushPendingWrites(forProfile outgoing: UUID) {}
}

extension ProgressManager: ProfileScopedStore {}
extension LibraryManager: ProfileScopedStore {}
extension UserRatingManager: ProfileScopedStore {}
extension CatalogManager: ProfileScopedStore {}
extension TrackerManager: ProfileScopedStore {}
extension RecommendationEngine: ProfileScopedStore {}
extension UpNextResolutionCache: ProfileScopedStore {}

final class ServiceStoreScopeReclaimer: ProfileScopedStore {
    static let shared = ServiceStoreScopeReclaimer()
    private init() {}

    func switchProfile(to profileID: UUID) {

    }

    func discardStore(forProfile profileID: UUID) {
        ServiceStoreScope.discardStore(forProfile: profileID)
    }
}

extension ServiceStoreScopeReclaimer {}

#if !os(tvOS)

final class ReaderUpscaleModelReclaimer: ProfileScopedStore {
    static let shared = ReaderUpscaleModelReclaimer()
    private init() {}

    func switchProfile(to profileID: UUID) {

    }

    func discardStore(forProfile profileID: UUID) {
        KanzenReaderUpscaleModelStore.discardModel(forProfile: profileID)
    }
}
#endif

#if !os(tvOS)
extension MangaLibraryManager: ProfileScopedStore {}
extension MangaReadingProgressManager: ProfileScopedStore {}
extension MangaCatalogManager: ProfileScopedStore {}
extension KanzenCustomCatalogManager: ProfileScopedStore {}
#endif

enum ProfileScopedStoreRegistry {

    static var all: [ProfileScopedStore] {
        var stores: [ProfileScopedStore] = [
            ProgressManager.shared,
            LibraryManager.shared,
            UserRatingManager.shared,
            CatalogManager.shared,
            TrackerManager.shared,
            RecommendationEngine.shared,
            UpNextResolutionCache.shared,
            ServiceStoreScopeReclaimer.shared
        ]
        #if !os(tvOS)
        stores.append(contentsOf: [
            MangaLibraryManager.shared,
            MangaReadingProgressManager.shared,
            MangaCatalogManager.shared,
            KanzenCustomCatalogManager.shared,
            ReaderUpscaleModelReclaimer.shared
        ] as [ProfileScopedStore])
        #endif
        return stores
    }
}
