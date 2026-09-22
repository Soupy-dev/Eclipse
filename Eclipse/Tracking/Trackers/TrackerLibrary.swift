import Foundation

enum TrackerLibrarySettings {
    static let enabledKey = "trackerDeepLibraryEnabled"
    static let defaultEnabled = false

    static var isEnabled: Bool {
        isEnabled(defaults: ProfileSettingsStore.active)
    }

    static func isEnabled(defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    }
}

enum TrackerLibrarySource: String, CaseIterable, Identifiable {
    case local
    case anilist
    case myAnimeList
    case trakt

    var id: String { rawValue }
    var title: String {
        switch self {
        case .local: return "My Library"
        case .anilist: return "AniList"
        case .myAnimeList: return "MAL"
        case .trakt: return "Trakt"
        }
    }
    var service: TrackerService? {
        switch self {
        case .local: return nil
        case .anilist: return .anilist
        case .myAnimeList: return .myAnimeList
        case .trakt: return .trakt
        }
    }
}

enum TrackerLibraryKind: String, CaseIterable, Identifiable {
    case anime = "ANIME"
    case manga = "MANGA"
    case movie = "MOVIE"
    case show = "SHOW"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .anime: return "Anime"
        case .manga: return "Manga"
        case .movie: return "Movies"
        case .show: return "Shows"
        }
    }
    var isManga: Bool { self == .manga }
    var isVideo: Bool { !isManga }
    var unit: String { isManga ? "chapters" : self == .movie ? "plays" : "episodes" }
    var traktPath: String { self == .movie ? "movies" : "shows" }
    static func supportedKinds(for service: TrackerService) -> [Self] {
        service == .trakt ? [.movie, .show] : [.anime, .manga]
    }
    var malPath: String { self == .anime ? "anime" : "manga" }
    var malListKind: TrackerRemoteProgressBoundary.MALListKind {
        self == .anime ? .anime : .manga
    }

    func malFields(listStatusKey: String) -> String {
        let progress = self == .anime ? "num_episodes_watched" : "num_chapters_read"
        let repeating = self == .anime ? "is_rewatching" : "is_rereading"
        let total = self == .anime ? "num_episodes" : "num_chapters"
        return "\(listStatusKey){status,score,\(progress),\(repeating),updated_at},\(total),genres,mean,main_picture,start_date,media_type"
    }
}

enum TrackerLibraryStatus: String, CaseIterable, Identifiable {
    case current = "CURRENT"
    case planning = "PLANNING"
    case completed = "COMPLETED"
    case paused = "PAUSED"
    case dropped = "DROPPED"
    case repeating = "REPEATING"

    var id: String { rawValue }

    func title(for kind: TrackerLibraryKind) -> String {
        switch self {
        case .current: return kind == .anime ? "Watching" : "Reading"
        case .planning: return kind == .anime ? "Planning to Watch" : "Planning to Read"
        case .completed: return "Completed"
        case .paused: return "Paused"
        case .dropped: return "Dropped"
        case .repeating: return kind == .anime ? "Rewatching" : "Rereading"
        }
    }

    func malValue(for kind: TrackerLibraryKind) -> String {
        switch self {
        case .current, .repeating: return kind == .anime ? "watching" : "reading"
        case .planning: return kind == .anime ? "plan_to_watch" : "plan_to_read"
        case .completed: return "completed"
        case .paused: return "on_hold"
        case .dropped: return "dropped"
        }
    }

    static func fromMAL(_ value: String, repeating: Bool) -> Self? {
        let status: Self?
        switch value {
        case "watching", "reading": status = .current
        case "plan_to_watch", "plan_to_read": status = .planning
        case "completed": status = .completed
        case "on_hold": status = .paused
        case "dropped": status = .dropped
        default: status = nil
        }
        guard let status else { return nil }
        return repeating ? .repeating : status
    }
}

struct TrackerLibrarySession: Hashable {
    let owner: UUID
    let operationGeneration: UInt64
    let accountGeneration: UInt64
    let serviceGeneration: UInt64
    let service: TrackerService
    let userID: String

    func authorizes(_ current: Self, enabled: Bool, isKids: Bool) -> Bool {
        enabled && !isKids && self == current
    }
}

struct TrackerLibraryEntry: Identifiable, Equatable {
    let service: TrackerService
    let kind: TrackerLibraryKind
    let mediaID: Int
    let entryID: Int?
    let aniListID: Int?
    let malID: Int?
    let title: String
    let alternateTitles: [String]
    let coverLarge: String?
    let coverMedium: String?
    let total: Int?
    let genres: [String]
    let averageScore: Double?
    var status: TrackerLibraryStatus
    var progress: Int
    var score: Double
    var updatedAt: Date?
    var tmdbID: Int? = nil
    var traktSlug: String? = nil
    var format: String? = nil
    var year: Int? = nil
    var imdbID: String? = nil
    var customLists: [String] = []
    var customListMembershipIsKnown = false

    var id: String { "\(service.rawValue):\(kind.rawValue):\(mediaID)" }
    var coverURL: URL? {
        let value = ImageDataSaverSettings.isEnabled()
            ? coverMedium ?? coverLarge : coverLarge ?? coverMedium
        return value.flatMap(TrackerLibraryPolicy.imageURL)
    }
    var websiteURL: URL? {
        if service == .trakt {
            return URL(string: "https://trakt.tv/\(kind.traktPath)/\(mediaID)")
        }
        let host = service == .anilist ? "anilist.co" : "myanimelist.net"
        return URL(string: "https://\(host)/\(kind.malPath)/\(mediaID)")
    }
}

struct TrackerLibraryEdit: Equatable {
    var status: TrackerLibraryStatus
    var progress: Int
    var score: Double

    init(entry: TrackerLibraryEntry) {
        status = entry.status
        progress = entry.progress
        score = entry.score
    }

    func validate(against original: TrackerLibraryEntry) throws {
        guard (0...TrackerLibraryPolicy.maximumProgress).contains(progress),
              score.isFinite, (0...100).contains(score),
              original.service != .myAnimeList || score.truncatingRemainder(dividingBy: 10) == 0 else {
            throw TrackerLibraryError.invalidEdit
        }
        if progress != original.progress, let total = original.total, total > 0, progress > total {
            throw TrackerLibraryError.progressExceedsTotal
        }
    }

    func conflicts(original: TrackerLibraryEntry, current: TrackerLibraryEntry) -> Bool {
        original.id != current.id
            || (status != original.status && current.status != original.status && current.status != status)
            || (progress != original.progress && current.progress != original.progress && current.progress != progress)
            || (score != original.score && current.score != original.score && current.score != score)
    }

    func aniListValues(original: TrackerLibraryEntry) -> [String: Any] {
        var values: [String: Any] = [:]
        if status != original.status { values["status"] = status.rawValue }
        if progress != original.progress { values["progress"] = progress }
        if score != original.score { values["scoreRaw"] = Int(score.rounded()) }
        return values
    }

    func malValues(original: TrackerLibraryEntry) -> [String: String] {
        var values: [String: String] = [:]
        if status != original.status {
            values["status"] = status.malValue(for: original.kind)
            values[original.kind == .anime ? "is_rewatching" : "is_rereading"] = status == .repeating ? "true" : "false"
        }
        if progress != original.progress {
            values[original.kind == .anime ? "num_watched_episodes" : "num_chapters_read"] = String(progress)
        }
        if score != original.score { values["score"] = String(Int((score / 10).rounded())) }
        return values
    }
}

enum TrackerLibraryError: LocalizedError {
    case unavailable
    case invalidResponse
    case tooLarge
    case invalidEdit
    case progressExceedsTotal
    case conflict
    case missingEntry
    case missingList
    case noMatch
    case requestFailed(Int)
    case rateLimited(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Enable Deep Library Integration and connect this tracker in Settings to view its library."
        case .invalidResponse: return "The tracker returned an unreadable response. Refresh the library before trying again."
        case .tooLarge: return "This list exceeds the supported library limit. Select a status to load a smaller list."
        case .invalidEdit: return "Enter a valid progress count and rating."
        case .progressExceedsTotal: return "Progress cannot exceed the known episode or chapter total."
        case .conflict: return "This entry changed on the tracker while you were editing. Refresh the library before saving again."
        case .missingEntry: return "This entry is no longer on your tracker list. Refresh the library."
        case .missingList: return "This tracker list is no longer available. Choose another list or refresh to try again."
        case .noMatch: return "This title could not be matched to Eclipse metadata. You can still edit it or open its tracker page."
        case .requestFailed(let status): return "The tracker could not complete the request (\(status)). Try again later."
        case .rateLimited(let delay):
            if delay.isFinite, delay <= 86_400 {
                return "The tracker has paused requests. Try again in \(max(1, Int(ceil(delay / 60)))) minutes."
            }
            return "The tracker has paused requests. Try again later."
        }
    }
}

enum TrackerLibraryPolicy {
    static let maximumProgress = 100_000
    static let maximumEntries = 20_000
    static let maximumPageCount = 200
    static let pageSize = 100
    static let maximumResponseBytes = 4 * 1_024 * 1_024

    static func customListNames(_ names: [String]) throws -> [String] {
        guard names.count <= 100 else { throw TrackerLibraryError.tooLarge }
        var seen = Set<String>()
        return try names.filter { name in
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name.utf8.count <= 256,
                  !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw TrackerLibraryError.invalidResponse
            }
            return seen.insert(name).inserted
        }
    }

    static func visibleEntries(_ entries: [TrackerLibraryEntry], status: TrackerLibraryStatus?, section: TrackerLibrarySection) throws -> [TrackerLibraryEntry] {
        if case .aniListCustomList(let name) = section {
            guard entries.allSatisfy(\.customListMembershipIsKnown) else { throw TrackerLibraryError.invalidResponse }
            return entries.filter { $0.customLists.contains(name) && (status == nil || $0.status == status) }
        }
        return status.map { selected in entries.filter { $0.status == selected } } ?? entries
    }

    static func imageURL(_ value: String) -> URL? {
        guard value.utf8.count <= 8_192,
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil else { return nil }
        return components.url
    }

    static func allowsMALPage(_ url: URL, kind: TrackerLibraryKind) -> Bool {
        guard [.anime, .manga].contains(kind),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil, components.fragment == nil else { return false }
        return TrackerRemoteProgressBoundary.isAllowedMALPageURL(url, listKind: kind.malListKind)
    }

    static func validate(_ entry: TrackerLibraryEntry) throws {
        guard TrackerRemoteProgressBoundary.positiveIdentifier(entry.mediaID) != nil,
              TrackerLibraryKind.supportedKinds(for: entry.service).contains(entry.kind),
              !entry.title.isEmpty, entry.title.utf8.count <= 4_096,
              entry.alternateTitles.count <= 3,
              entry.alternateTitles.allSatisfy({ $0.utf8.count <= 4_096 }),
              (0...maximumProgress).contains(entry.progress),
              entry.total.map({ (0...maximumProgress).contains($0) }) ?? true,
              entry.score.isFinite, (0...100).contains(entry.score),
              entry.service != .myAnimeList || entry.score.truncatingRemainder(dividingBy: 10) == 0,
              entry.averageScore.map({ $0.isFinite && (0...100).contains($0) }) ?? true,
              entry.genres.count <= 64,
              entry.genres.allSatisfy({ $0.utf8.count <= 256 }) else {
            throw TrackerLibraryError.invalidResponse
        }
    }

    static func append(_ page: [TrackerLibraryEntry], to entries: inout [TrackerLibraryEntry]) throws {
        guard page.count <= pageSize * 10 else { throw TrackerLibraryError.tooLarge }
        var seen = Set(entries.map(\.id))
        for entry in page where seen.insert(entry.id).inserted {
            guard entries.count < maximumEntries else { throw TrackerLibraryError.tooLarge }
            entries.append(entry)
        }
    }

    static func filtered(_ entries: [TrackerLibraryEntry], search: String, genre: String?) -> [TrackerLibraryEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            (genre.map { entry.genres.contains($0) } ?? true)
                && (query.isEmpty || ([entry.title] + entry.alternateTitles).contains {
                    $0.localizedStandardContains(query)
                })
        }.sorted {
            let left = $0.updatedAt ?? .distantPast
            let right = $1.updatedAt ?? .distantPast
            if left != right { return left > right }
            if $0.title != $1.title { return $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return $0.id < $1.id
        }
    }
}

struct TrackerAniListLibraryPage: Decodable {
    let data: Body?
    let errors: [GraphQLError]?

    struct GraphQLError: Decodable { let message: String? }
    struct Body: Decodable {
        let MediaListCollection: Collection?
        let MediaList: Entry?
        let SaveMediaListEntry: Entry?
    }
    struct Collection: Decodable {
        let hasNextChunk: Bool
        let lists: [Group]
    }
    struct Group: Decodable { let entries: [Entry] }
    struct Entry: Decodable {
        let id: Int
        let mediaId: Int
        let status: String
        let progress: Int
        let score: Double
        let updatedAt: Int?
        let customLists: [String: Bool]?
        let media: Media
    }
    struct Media: Decodable {
        let id: Int
        let idMal: Int?
        let type: String
        let title: Title
        let coverImage: Cover?
        let episodes: Int?
        let chapters: Int?
        let genres: [String]?
        let averageScore: Double?
        let format: String?
        let startDate: StartDate?
    }
    struct StartDate: Decodable { let year: Int? }
    struct Title: Decodable { let english: String?; let romaji: String?; let native: String? }
    struct Cover: Decodable { let large: String?; let medium: String? }

    static let entryFields = """
        id mediaId status progress score(format: POINT_100) updatedAt customLists
        media { id idMal type title { english romaji native } coverImage { large medium } episodes chapters genres averageScore format startDate { year } }
        """

    static func decode(_ bytes: Data, kind: TrackerLibraryKind) throws -> (entries: [TrackerLibraryEntry], hasNext: Bool) {
        guard bytes.count <= TrackerLibraryPolicy.maximumResponseBytes else { throw TrackerLibraryError.tooLarge }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        guard value.errors?.isEmpty != false,
              let collection = value.data?.MediaListCollection,
              collection.lists.count <= 100 else { throw TrackerLibraryError.invalidResponse }
        var entries: [TrackerLibraryEntry] = []
        var indexes: [String: Int] = [:]
        for group in collection.lists {
            guard group.entries.count <= TrackerLibraryPolicy.pageSize * 10 else { throw TrackerLibraryError.tooLarge }
            for entry in group.entries {
                let normalized = try entry.normalized(kind: kind)
                if let index = indexes[normalized.id] {
                    guard entries[index] == normalized else { throw TrackerLibraryError.invalidResponse }
                    continue
                }
                guard entries.count < TrackerLibraryPolicy.pageSize * 10 else { throw TrackerLibraryError.tooLarge }
                indexes[normalized.id] = entries.count
                entries.append(normalized)
            }
        }
        return (entries, collection.hasNextChunk)
    }
}

extension TrackerAniListLibraryPage.Entry {
    func normalized(kind: TrackerLibraryKind) throws -> TrackerLibraryEntry {
        guard mediaId == media.id,
              media.type == kind.rawValue,
              TrackerRemoteProgressBoundary.positiveIdentifier(id) != nil,
              let normalizedStatus = TrackerLibraryStatus(rawValue: status) else { throw TrackerLibraryError.invalidResponse }
        let titles = [media.title.english, media.title.romaji, media.title.native].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let customNames = try TrackerLibraryPolicy.customListNames(customLists.map { Array($0.keys) } ?? [])
        let entry = TrackerLibraryEntry(
            service: .anilist, kind: kind, mediaID: mediaId, entryID: id,
            aniListID: media.id, malID: TrackerRemoteProgressBoundary.positiveIdentifier(media.idMal),
            title: titles.first ?? "Untitled", alternateTitles: titles,
            coverLarge: media.coverImage?.large, coverMedium: media.coverImage?.medium,
            total: kind == .anime ? media.episodes : media.chapters,
            genres: media.genres ?? [], averageScore: media.averageScore,
            status: normalizedStatus, progress: progress, score: score,
            updatedAt: updatedAt.map { Date(timeIntervalSince1970: Double($0)) },
            format: TrackerLibraryPolicy.validatedFormat(media.format),
            year: TrackerLibraryPolicy.validatedYear(media.startDate?.year),
            customLists: customNames.filter { customLists?[$0] == true }.sorted(),
            customListMembershipIsKnown: customLists != nil
        )
        try TrackerLibraryPolicy.validate(entry)
        return entry
    }
}

struct TrackerAniListLibraryListsResponse: Decodable {
    let data: Body?
    let errors: [TrackerAniListLibraryPage.GraphQLError]?
    struct Body: Decodable { let User: User? }
    struct User: Decodable { let id: Int; let mediaListOptions: Options? }
    struct Options: Decodable { let animeList: ListOptions?; let mangaList: ListOptions? }
    struct ListOptions: Decodable { let customLists: [String] }

    static func decode(_ data: Data, kind: TrackerLibraryKind, userID: Int) throws -> [String] {
        guard data.count <= TrackerLibraryPolicy.maximumResponseBytes else { throw TrackerLibraryError.tooLarge }
        let response = try JSONDecoder().decode(Self.self, from: data)
        guard [.anime, .manga].contains(kind), response.errors?.isEmpty != false,
              let user = response.data?.User, user.id == userID,
              let options = user.mediaListOptions,
              let list = kind == .anime ? options.animeList : options.mangaList else { throw TrackerLibraryError.invalidResponse }
        return try TrackerLibraryPolicy.customListNames(list.customLists)
    }
}

struct TrackerMALLibraryPage: Decodable {
    let data: [Entry]
    let paging: Paging?
    struct Entry: Decodable { let node: Node; let list_status: Status }
    struct Paging: Decodable { let next: String? }
    struct Node: Decodable {
        let id: Int
        let title: String
        let main_picture: Picture?
        let num_episodes: Int?
        let num_chapters: Int?
        let genres: [Genre]?
        let mean: Double?
        let my_list_status: Status?
        let start_date: String?
        let media_type: String?
    }
    struct Picture: Decodable { let large: String?; let medium: String? }
    struct Genre: Decodable { let name: String }
    struct Status: Decodable {
        let status: String
        let score: Double
        let num_episodes_watched: Int?
        let num_chapters_read: Int?
        let is_rewatching: Bool?
        let is_rereading: Bool?
        let updated_at: String?
    }

    static func decode(_ bytes: Data, kind: TrackerLibraryKind) throws -> (entries: [TrackerLibraryEntry], next: URL?) {
        guard bytes.count <= TrackerLibraryPolicy.maximumResponseBytes else { throw TrackerLibraryError.tooLarge }
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        guard value.data.count <= TrackerLibraryPolicy.pageSize else { throw TrackerLibraryError.tooLarge }
        let entries = try value.data.map { try $0.node.normalized(status: $0.list_status, kind: kind) }
        var next: URL?
        if let raw = value.paging?.next {
            guard raw.utf8.count <= 8_192,
                  let url = URL(string: raw),
                  TrackerLibraryPolicy.allowsMALPage(url, kind: kind) else {
                throw TrackerLibraryError.invalidResponse
            }
            next = url
        }
        return (entries, next)
    }
}

extension TrackerMALLibraryPage.Node {
    func normalized(status: TrackerMALLibraryPage.Status, kind: TrackerLibraryKind) throws -> TrackerLibraryEntry {
        guard let normalizedStatus = TrackerLibraryStatus.fromMAL(
            status.status,
            repeating: (kind == .anime ? status.is_rewatching : status.is_rereading) ?? false
        ) else { throw TrackerLibraryError.invalidResponse }
        let progress = kind == .anime ? status.num_episodes_watched : status.num_chapters_read
        guard let progress else { throw TrackerLibraryError.invalidResponse }
        let entry = TrackerLibraryEntry(
            service: .myAnimeList, kind: kind, mediaID: id, entryID: nil,
            aniListID: nil, malID: id, title: title, alternateTitles: [],
            coverLarge: main_picture?.large, coverMedium: main_picture?.medium,
            total: kind == .anime ? num_episodes : num_chapters,
            genres: genres?.map(\.name) ?? [], averageScore: mean.map { $0 * 10 },
            status: normalizedStatus, progress: progress, score: status.score * 10,
            updatedAt: status.updated_at.flatMap { ISO8601DateFormatter().date(from: $0) },
            format: TrackerLibraryPolicy.validatedFormat(media_type),
            year: TrackerLibraryPolicy.validatedYear(start_date.flatMap { Int($0.prefix(4)) })
        )
        try TrackerLibraryPolicy.validate(entry)
        return entry
    }
}

struct TrackerCollectionTarget: Hashable {
    let title: String
    let kind: TrackerLibraryKind
    let aniListID: Int?
    let malID: Int?
    let tmdbID: Int?

    init(title: String, kind: TrackerLibraryKind, aniListID: Int? = nil, malID: Int? = nil, tmdbID: Int? = nil) {
        self.title = title
        self.kind = kind
        self.aniListID = TrackerLibraryPolicy.validatedIdentifier(aniListID)
        self.malID = TrackerLibraryPolicy.validatedIdentifier(malID)
        self.tmdbID = TrackerLibraryPolicy.validatedIdentifier(tmdbID)
    }

    init(media: TMDBSearchResult) {
        self.init(title: media.displayTitle, kind: media.isMovie ? .movie : .show,
                  aniListID: media.animeIdentitySeed?.anilistId,
                  malID: media.animeIdentitySeed?.malId, tmdbID: media.id)
    }

    func kind(for service: TrackerService) -> TrackerLibraryKind {
        service == .trakt ? kind : kind == .manga ? .manga : .anime
    }

    func supports(_ service: TrackerService) -> Bool {
        service != .trakt || kind != .manga
    }

    func candidate(service: TrackerService, mediaID: Int) throws -> TrackerLibraryEntry {
        let result = TrackerLibraryEntry(service: service, kind: kind(for: service), mediaID: mediaID,
            entryID: nil, aniListID: service == .anilist ? mediaID : aniListID,
            malID: service == .myAnimeList ? mediaID : malID, title: title, alternateTitles: [],
            coverLarge: nil, coverMedium: nil, total: nil, genres: [], averageScore: nil,
            status: .planning, progress: 0, score: 0, updatedAt: nil, tmdbID: tmdbID)
        try TrackerLibraryPolicy.validate(result)
        return result
    }

    func hasExactIdentity(for service: TrackerService) -> Bool {
        switch service {
        case .anilist: return aniListID != nil || malID != nil
        case .myAnimeList: return malID != nil || aniListID != nil
        case .trakt: return tmdbID != nil
        }
    }
}

struct TrackerCollectionAniListResponse: Decodable {
    let data: Body?
    let errors: [TrackerAniListLibraryPage.GraphQLError]?
    struct Body: Decodable {
        let Media: Item?
        let Page: Page?
    }
    struct Page: Decodable { let media: [Item] }
    struct Item: Decodable {
        let id: Int
        let mediaListEntry: TrackerAniListLibraryPage.Entry?
        let membershipWasReturned: Bool
        private let media: TrackerAniListLibraryPage.Media

        init(from decoder: Decoder) throws {
            media = try TrackerAniListLibraryPage.Media(from: decoder)
            id = media.id
            let container = try decoder.container(keyedBy: CodingKeys.self)
            membershipWasReturned = container.contains(.mediaListEntry)
            mediaListEntry = try container.decodeIfPresent(TrackerAniListLibraryPage.Entry.self, forKey: .mediaListEntry)
        }
        private enum CodingKeys: String, CodingKey { case mediaListEntry }

        func candidate(kind: TrackerLibraryKind) throws -> TrackerLibraryEntry {
            guard media.type == kind.rawValue else { throw TrackerLibraryError.invalidResponse }
            let titles = [media.title.english, media.title.romaji, media.title.native].compactMap { $0 }.filter { !$0.isEmpty }
            let entry = TrackerLibraryEntry(service: .anilist, kind: kind, mediaID: media.id,
                entryID: nil, aniListID: media.id, malID: media.idMal,
                title: titles.first ?? "Untitled", alternateTitles: titles,
                coverLarge: media.coverImage?.large, coverMedium: media.coverImage?.medium,
                total: kind == .manga ? media.chapters : media.episodes, genres: media.genres ?? [],
                averageScore: media.averageScore, status: .planning, progress: 0, score: 0, updatedAt: nil,
                format: media.format, year: media.startDate?.year)
            try TrackerLibraryPolicy.validate(entry)
            return entry
        }
    }
    static let fields = "id idMal type title { english romaji native } coverImage { large medium } episodes chapters genres averageScore format startDate { year }"

    func validatedItems() throws -> [Item] {
        guard errors?.isEmpty != false, let data else { throw TrackerLibraryError.invalidResponse }
        let items = data.Page?.media ?? data.Media.map { [$0] } ?? []
        guard items.count <= 20 else { throw TrackerLibraryError.tooLarge }
        return items
    }
}

struct TrackerCollectionMALSearch: Decodable {
    let data: [Item]
    struct Item: Decodable { let node: TrackerMALLibraryPage.Node }
}

extension TrackerMALLibraryPage.Node {
    func collectionCandidate(kind: TrackerLibraryKind) throws -> TrackerLibraryEntry {
        let format = media_type?.uppercased()
        let animeFormats = ["TV", "TV_SPECIAL", "MOVIE", "OVA", "ONA", "SPECIAL", "MUSIC"]
        let mangaFormats = ["MANGA", "NOVEL", "LIGHT_NOVEL", "ONE_SHOT", "MANHWA", "MANHUA", "DOUJINSHI", "OEL"]
        if let format, (kind == .anime ? mangaFormats : animeFormats).contains(format) {
            throw TrackerLibraryError.invalidResponse
        }
        return try normalized(status: .init(status: TrackerLibraryStatus.planning.malValue(for: kind), score: 0,
            num_episodes_watched: 0, num_chapters_read: 0, is_rewatching: false, is_rereading: false,
            updated_at: nil), kind: kind)
    }
}

extension TraktLibraryAction {
    var collectionMembership: (section: TrackerLibrarySection, included: Bool)? {
        switch self {
        case .watchlist(let included): return (.watchlist, included)
        case .collection(let included): return (.collection, included)
        case .customList(let id, let included): return (.customList(id: id, name: ""), included)
        case .history, .rating: return nil
        }
    }
}

@MainActor
enum TrackerCollectionAddition {
    static func perform(
        isAuthorized: () -> Bool,
        read: () async throws -> TrackerLibraryEntry?,
        write: () async throws -> TrackerLibraryEntry
    ) async throws -> TrackerLibraryEntry {
        try Task.checkCancellation()
        guard isAuthorized() else { throw CancellationError() }
        if let existing = try await read() {
            try Task.checkCancellation()
            guard isAuthorized() else { throw CancellationError() }
            return existing
        }
        try Task.checkCancellation()
        guard isAuthorized() else { throw CancellationError() }
        do {
            let saved = try await write()
            try Task.checkCancellation()
            guard isAuthorized() else { throw CancellationError() }
            return saved
        } catch {
            try Task.checkCancellation()
            guard isAuthorized() else { throw CancellationError() }
            if let saved = try? await read() {
                try Task.checkCancellation()
                guard isAuthorized() else { throw CancellationError() }
                return saved
            }
            throw error
        }
    }
}
