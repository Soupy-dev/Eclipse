import Foundation

enum TrackerLibraryDiagnostics {
    static func section(_ value: TrackerLibrarySection) -> String {
        switch value {
        case .list: return "list"
        case .watchlist: return "watchlist"
        case .history: return "history"
        case .collection: return "collection"
        case .customList: return "custom-list"
        case .aniListCustomList: return "anilist-custom-list"
        }
    }

    static func scope(_ key: TrackerLibraryCacheKey) -> String {
        "service=\(key.session.service.rawValue) kind=\(key.kind.rawValue) status=\(key.status?.rawValue ?? "all") section=\(section(key.section))"
    }

    static func cursor(_ value: TrackerLibraryCursor?) -> String {
        switch value {
        case .page(let page): return String(page)
        case .mal(let url):
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "offset" })?.value.flatMap(Int.init).map { "offset:\($0)" } ?? "mal-next"
        case nil: return "none"
        }
    }

    static func pagination(_ response: HTTPURLResponse) -> String {
        [("page", "X-Pagination-Page"), ("limit", "X-Pagination-Limit"),
         ("pages", "X-Pagination-Page-Count"), ("total", "X-Pagination-Item-Count")].map { label, name in
            guard let raw = response.value(forHTTPHeaderField: name) else { return "\(label)=absent" }
            return "\(label)=\(Int(raw).map(String.init) ?? "invalid")"
        }.joined(separator: " ")
    }

    static func failure(_ error: Error) -> String {
        if error is CancellationError { return "cancelled-or-authority-expired" }
        if error is TraktAuthenticationRequiredError { return "authentication-required" }
        if let refresh = error as? TraktOAuthRefreshFailure {
            return "token-refresh:http:\(refresh.statusCode) disposition=\(refresh.disposition == .authenticationRequired ? "authentication-required" : "retryable")"
        }
        if let value = error as? TrackerLibraryError {
            switch value {
            case .unavailable: return "unavailable"
            case .invalidResponse: return "invalid-response"
            case .tooLarge: return "bounds-exceeded"
            case .invalidEdit: return "invalid-edit"
            case .progressExceedsTotal: return "progress-exceeds-total"
            case .conflict: return "conflict"
            case .missingEntry: return "missing-entry"
            case .missingList: return "missing-list"
            case .noMatch: return "no-match"
            case .requestFailed(let status): return "http:\(status)"
            case .rateLimited: return "rate-limited"
            }
        }
        if let value = error as? DecodingError {
            let context: DecodingError.Context
            let category: String
            switch value {
            case .typeMismatch(_, let detail): context = detail; category = "type-mismatch"
            case .valueNotFound(_, let detail): context = detail; category = "null-required-value"
            case .keyNotFound(_, let detail): context = detail; category = "missing-required-key"
            case .dataCorrupted(let detail): context = detail; category = "corrupt-json"
            @unknown default: return "decode:unknown"
            }
            let fields: Set<String> = ["data", "errors", "MediaListCollection", "MediaList", "SaveMediaListEntry", "lists", "entries",
                "hasNextChunk", "id", "mediaId", "status", "progress", "score", "updatedAt", "customLists", "media", "title",
                "english", "romaji", "native", "coverImage", "large", "medium", "episodes", "chapters", "genres", "averageScore",
                "format", "startDate", "year", "movie", "show", "ids", "trakt", "tmdb", "imdb", "type", "plays", "rating",
                "node", "list_status", "my_list_status", "paging", "next", "name", "item_count", "main_picture", "num_episodes",
                "num_chapters", "num_episodes_watched", "num_chapters_read", "mean", "is_rewatching", "is_rereading", "updated_at",
                "User", "mediaListOptions", "animeList", "mangaList"]
            let path = context.codingPath.map { key in
                key.intValue.map { "[\($0)]" } ?? (fields.contains(key.stringValue) ? key.stringValue : "*")
            }.joined(separator: ".")
            return "decode:\(category) path=\(path.isEmpty ? "root" : path)"
        }
        if let value = error as? URLError { return "network:\(value.code.rawValue)" }
        return "other:\((error as NSError).code)"
    }

    static func graphQL(_ bytes: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let errors = object["errors"] as? [Any], !errors.isEmpty else { return "graphql-errors=0" }
        let statuses = errors.prefix(8).compactMap { ($0 as? [String: Any])?["status"] as? Int }
        return "graphql-errors=\(errors.count) graphql-status=\(statuses.map(String.init).joined(separator: ","))"
    }

    static func log(_ message: String) {
        Logger.shared.log("TrackerLibrary: \(message)", type: "TrackerLibrary")
    }
}

@MainActor
final class TrackerLibraryCooldown {
    static let shared = TrackerLibraryCooldown()
    private var deadlines: [TrackerService: Date] = [:]

    func record(_ response: HTTPURLResponse, service: TrackerService, now: Date = Date()) -> TimeInterval? {
        guard response.statusCode == 429 else { return nil }
        let parsed = response.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
        let delay = parsed.flatMap { $0.isFinite && $0 >= 0 ? max(1, $0) : nil } ?? 5
        deadlines[service] = max(deadlines[service] ?? .distantPast, now.addingTimeInterval(delay))
        return delay
    }

    func remaining(service: TrackerService, now: Date = Date()) -> TimeInterval {
        max(0, deadlines[service]?.timeIntervalSince(now) ?? 0)
    }

    func requireReady(service: TrackerService) throws {
        try Task.checkCancellation()
        let delay = remaining(service: service)
        if delay > 0 { throw TrackerLibraryError.rateLimited(delay) }
    }

    func waitUntilReady(service: TrackerService, isAuthorized: @escaping @MainActor () -> Bool) async throws {
        while remaining(service: service) > 0 {
            try Task.checkCancellation()
            guard isAuthorized() else { throw CancellationError() }
            let delay = min(60, remaining(service: service))
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        try Task.checkCancellation()
        guard isAuthorized() else { throw CancellationError() }
    }
}

enum TrackerLibrarySection: Hashable, Identifiable {
    case list
    case watchlist
    case history
    case collection
    case customList(id: Int, name: String)
    case aniListCustomList(name: String)

    var id: String {
        switch self {
        case .list: return "list"
        case .watchlist: return "watchlist"
        case .history: return "history"
        case .collection: return "collection"
        case .customList(let id, _): return "custom:\(id)"
        case .aniListCustomList(let name): return "anilist-custom:\(name)"
        }
    }
    var title: String {
        switch self {
        case .list: return "Library"
        case .watchlist: return "Watchlist"
        case .history: return "Watched History"
        case .collection: return "Collection"
        case .customList(_, let name): return name
        case .aniListCustomList(let name): return name
        }
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct TrackerLibraryList: Identifiable, Equatable {
    let id: Int
    let name: String
    let itemCount: Int?
}

@MainActor
final class TrackerLibraryMetadataRequest<Value> {
    let id = UUID()
    let task: Task<Value, Error>
    var subscribers = Set<UUID>()

    init(task: Task<Value, Error>) { self.task = task }
}

typealias TrackerLibraryListRequest = TrackerLibraryMetadataRequest<[TrackerLibraryList]>

extension Notification.Name {
    static let trackerLibraryInvalidated = Notification.Name("trackerLibraryInvalidated")
}

struct TrackerLibraryRefreshGate {
    private var dates: [TrackerLibrarySession: Date] = [:]

    mutating func begin(session: TrackerLibrarySession, now: Date = Date()) -> Bool {
        if let date = dates[session], (0..<1).contains(now.timeIntervalSince(date)) { return false }
        if dates.count >= 32 { dates.removeAll() }
        dates[session] = now
        return true
    }
}

enum TraktLibraryAction: Equatable {
    case rating(Int?)
    case watchlist(Bool)
    case collection(Bool)
    case history(Bool)
    case customList(id: Int, included: Bool)

    func request(entry: TrackerLibraryEntry) throws -> URLRequest {
        guard entry.service == .trakt, [.movie, .show].contains(entry.kind),
              TrackerLibraryPolicy.validatedIdentifier(entry.mediaID) != nil else { throw TrackerLibraryError.invalidEdit }
        let path: String
        var item: [String: Any] = ["ids": ["trakt": entry.mediaID]]
        switch self {
        case .rating(let rating):
            if let rating {
                guard (1...10).contains(rating) else { throw TrackerLibraryError.invalidEdit }
                item["rating"] = rating
                path = "sync/ratings"
            } else { path = "sync/ratings/remove" }
        case .watchlist(let included): path = included ? "sync/watchlist" : "sync/watchlist/remove"
        case .collection(let included): path = included ? "sync/collection" : "sync/collection/remove"
        case .history(let included): path = included ? "sync/history" : "sync/history/remove"
        case .customList(let id, let included):
            guard TrackerLibraryPolicy.validatedIdentifier(id) != nil else { throw TrackerLibraryError.invalidEdit }
            path = "users/me/lists/\(id)/items" + (included ? "" : "/remove")
        }
        guard let url = URL(string: "https://api.trakt.tv/\(path)") else { throw TrackerLibraryError.invalidEdit }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [entry.kind.traktPath: [item]])
        return request
    }

    static func validateResponse(_ data: Data) throws {
        guard data.count <= TrackerLibraryPolicy.maximumResponseBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["added"] is [String: Any] || object["deleted"] is [String: Any] || object["updated"] is [String: Any] else {
            throw TrackerLibraryError.invalidResponse
        }
        for key in ["added", "deleted", "updated", "existing"] where object[key] != nil {
            guard let counts = object[key] as? [String: Any], counts.count <= 8,
                  counts.values.allSatisfy({ value in
                      guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
                      let value = number.doubleValue
                      return value.isFinite && value >= 0 && value <= 100_000 && value.rounded() == value
                  }) else { throw TrackerLibraryError.invalidResponse }
        }
        if let value = object["not_found"] {
            guard let missing = value as? [String: Any], missing.count <= 8,
                  missing.values.allSatisfy({ $0 is [Any] }) else { throw TrackerLibraryError.invalidResponse }
            if missing.values.contains(where: { ($0 as? [Any])?.isEmpty == false }) { throw TrackerLibraryError.missingEntry }
        }
    }
}

struct TrackerLibrarySnapshot: Equatable {
    let entries: [TrackerLibraryEntry]
    let isComplete: Bool
    let isStale: Bool
    let fetchedAt: Date
}

struct TrackerLibraryCacheKey: Hashable {
    let session: TrackerLibrarySession
    let kind: TrackerLibraryKind
    let status: TrackerLibraryStatus?
    let section: TrackerLibrarySection
}

enum TrackerLibraryCursor: Hashable {
    case page(Int)
    case mal(URL)
}

struct TrackerLibraryPage {
    let entries: [TrackerLibraryEntry]
    let next: TrackerLibraryCursor?
    let expectedTotal: Int?
    let rawEntryCount: Int
    let providerEntryCount: Int

    init(entries: [TrackerLibraryEntry], next: TrackerLibraryCursor?, expectedTotal: Int? = nil, rawEntryCount: Int? = nil, providerEntryCount: Int? = nil) {
        self.entries = entries
        self.next = next
        self.expectedTotal = expectedTotal
        self.rawEntryCount = rawEntryCount ?? entries.count
        self.providerEntryCount = providerEntryCount ?? rawEntryCount ?? entries.count
    }
}

@MainActor
struct TrackerLibraryMembershipReceipts {
    static let maximumEntries = 512
    private struct Key: Hashable {
        let session: TrackerLibrarySession
        let entryID: String
        let sectionID: String
    }
    private struct Receipt {
        let included: Bool
        let generation: UUID
        let date: Date
    }
    private var values: [Key: Receipt] = [:]

    mutating func value(entry: TrackerLibraryEntry, section: TrackerLibrarySection, session: TrackerLibrarySession,
                        generation: UUID, now: Date = Date()) -> Bool? {
        let key = Key(session: session, entryID: entry.id, sectionID: section.id)
        guard let receipt = values[key] else { return nil }
        guard receipt.generation == generation,
              (0..<TrackerLibraryCache.freshInterval).contains(now.timeIntervalSince(receipt.date)) else {
            values.removeValue(forKey: key)
            return nil
        }
        return receipt.included
    }

    mutating func record(_ included: Bool, entry: TrackerLibraryEntry, section: TrackerLibrarySection,
                         session: TrackerLibrarySession, generation: UUID, now: Date = Date()) {
        let key = Key(session: session, entryID: entry.id, sectionID: section.id)
        values[key] = Receipt(included: included, generation: generation, date: now)
        while values.count > Self.maximumEntries {
            guard let oldest = values.min(by: { $0.value.date < $1.value.date })?.key else { break }
            values.removeValue(forKey: oldest)
        }
    }

    mutating func invalidate(session: TrackerLibrarySession) {
        values = values.filter { $0.key.session != session }
    }
}

struct TrackerLibraryResolutionQueue {
    private(set) var entries: [TrackerLibraryEntry] = []
    private var scheduled = Set<String>()
    private(set) var visible = Set<String>()
    private var selected = Set<String>()

    mutating func appear(_ entry: TrackerLibraryEntry) {
        visible.insert(entry.id)
        if scheduled.insert(entry.id).inserted { entries.append(entry) }
    }

    mutating func select(_ entry: TrackerLibraryEntry) {
        selected.insert(entry.id)
        if scheduled.insert(entry.id).inserted { entries.insert(entry, at: 0) }
        else if let index = entries.firstIndex(where: { $0.id == entry.id }), index > 0 {
            entries.insert(entries.remove(at: index), at: 0)
        }
    }

    mutating func disappear(_ entry: TrackerLibraryEntry) {
        visible.remove(entry.id)
        guard !selected.contains(entry.id), entries.contains(where: { $0.id == entry.id }) else { return }
        entries.removeAll { $0.id == entry.id }
        scheduled.remove(entry.id)
    }

    mutating func retry(_ entry: TrackerLibraryEntry) {
        entries.removeAll { $0.id == entry.id }
        scheduled.remove(entry.id)
        select(entry)
    }

    mutating func refreshMetadata(_ entry: TrackerLibraryEntry) {
        entries.removeAll { $0.id == entry.id }
        scheduled.remove(entry.id)
        if selected.contains(entry.id) { select(entry) }
        else if visible.contains(entry.id) { appear(entry) }
    }

    mutating func next() -> (entry: TrackerLibraryEntry, priority: TrackerRequestPriority)? {
        guard !entries.isEmpty else { return nil }
        let entry = entries.removeFirst()
        let priority: TrackerRequestPriority = selected.remove(entry.id) != nil ? .interactive : .visible
        return (entry, priority)
    }
}

@MainActor
final class TrackerLibraryCache {
    static let shared = TrackerLibraryCache()
    static let freshInterval: TimeInterval = 120
    static let staleInterval: TimeInterval = 86_400
    static let maximumKeys = 16
    static let maximumCachedEntries = 40_000
    static let maximumBytes = 16 * 1_024 * 1_024
    private var values: [TrackerLibraryCacheKey: TrackerLibrarySnapshot] = [:]
    private var costs: [TrackerLibraryCacheKey: Int] = [:]
    private var generations: [TrackerLibraryCacheKey: UUID] = [:]
    private final class SubscriptionCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }
    private struct Subscriber {
        let cancellation: SubscriptionCancellation
        let matchingEntryID: String?
        let isAuthorized: @MainActor () -> Bool
        let onUpdate: (@MainActor (TrackerLibrarySnapshot) -> Void)?
        let continuation: CheckedContinuation<[TrackerLibraryEntry], Error>
    }
    private final class PendingLoad {
        let token: UUID
        var task: Task<Void, Never>?
        var subscribers: [UUID: Subscriber] = [:]
        var latest: TrackerLibrarySnapshot?
        var latestFresh: TrackerLibrarySnapshot?

        init(token: UUID) { self.token = token }
    }
    private var pendingLoads: [TrackerLibraryCacheKey: PendingLoad] = [:]

    func snapshot(for key: TrackerLibraryCacheKey, now: Date = Date()) -> TrackerLibrarySnapshot? {
        guard let value = values[key] else { return nil }
        let age = now.timeIntervalSince(value.fetchedAt)
        guard age >= 0, age <= Self.staleInterval else {
            values.removeValue(forKey: key)
            costs.removeValue(forKey: key)
            return nil
        }
        return TrackerLibrarySnapshot(entries: value.entries, isComplete: value.isComplete,
            isStale: value.isStale || !value.isComplete || age >= Self.freshInterval, fetchedAt: value.fetchedAt)
    }

    func begin(_ key: TrackerLibraryCacheKey) -> UUID {
        if let pending = pendingLoads[key] { complete(pending, key: key, result: .failure(CancellationError())) }
        let token = UUID()
        generations[key] = token
        return token
    }

    func isCurrent(_ token: UUID, key: TrackerLibraryCacheKey) -> Bool { generations[key] == token }

    func finish(_ token: UUID, key: TrackerLibraryCacheKey) {
        if isCurrent(token, key: key) { generations.removeValue(forKey: key) }
    }

    private static func cost(_ entry: TrackerLibraryEntry) -> Int {
        256 + entry.title.utf8.count + entry.alternateTitles.reduce(0) { $0 + $1.utf8.count }
            + (entry.coverLarge?.utf8.count ?? 0) + (entry.coverMedium?.utf8.count ?? 0)
            + entry.genres.reduce(0) { $0 + $1.utf8.count }
            + entry.customLists.reduce(0) { $0 + $1.utf8.count }
    }

    func store(_ snapshot: TrackerLibrarySnapshot, key: TrackerLibraryCacheKey, token: UUID, estimatedBytes: Int? = nil) {
        guard isCurrent(token, key: key) else { return }
        if values[key]?.isComplete == true && !snapshot.isComplete { return }
        values[key] = snapshot
        costs[key] = estimatedBytes ?? snapshot.entries.reduce(0) { $0 + Self.cost($1) }
        while values.count > Self.maximumKeys || values.values.reduce(0, { $0 + $1.entries.count }) > Self.maximumCachedEntries
                || costs.values.reduce(0, +) > Self.maximumBytes {
            guard let oldest = values.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key else { break }
            values.removeValue(forKey: oldest)
            costs.removeValue(forKey: oldest)
        }
    }

    func invalidate(session: TrackerLibrarySession) {
        values = values.filter { $0.key.session != session }
        costs = costs.filter { $0.key.session != session }
        generations = generations.filter { $0.key.session != session }
        for (key, pending) in pendingLoads.filter({ $0.key.session == session }) {
            complete(pending, key: key, result: .failure(CancellationError()))
        }
    }

    func markStale(session: TrackerLibrarySession) {
        for (key, snapshot) in values where key.session == session {
            values[key] = TrackerLibrarySnapshot(entries: snapshot.entries, isComplete: snapshot.isComplete,
                isStale: true, fetchedAt: snapshot.fetchedAt)
        }
        for (key, pending) in pendingLoads.filter({ $0.key.session == session }) {
            complete(pending, key: key, result: .failure(CancellationError()))
        }
        generations = generations.filter { $0.key.session != session }
    }

    private func complete(_ pending: PendingLoad, key: TrackerLibraryCacheKey, result: Result<[TrackerLibraryEntry], Error>) {
        guard pendingLoads[key] === pending else { return }
        pendingLoads.removeValue(forKey: key)
        finish(pending.token, key: key)
        pending.task?.cancel()
        let subscribers = pending.subscribers.values
        pending.subscribers = [:]
        for subscriber in subscribers {
            if !subscriber.cancellation.isCancelled, subscriber.isAuthorized() { subscriber.continuation.resume(with: result) }
            else { subscriber.continuation.resume(throwing: CancellationError()) }
        }
    }

    private func removeSubscriber(_ id: UUID, key: TrackerLibraryCacheKey) {
        guard let pending = pendingLoads[key], let subscriber = pending.subscribers.removeValue(forKey: id) else { return }
        subscriber.continuation.resume(throwing: CancellationError())
        if pending.subscribers.isEmpty { complete(pending, key: key, result: .failure(CancellationError())) }
    }

    private func completeMatchingSubscriber(_ id: UUID, entries: [TrackerLibraryEntry], pending: PendingLoad, key: TrackerLibraryCacheKey) {
        guard pendingLoads[key] === pending, let subscriber = pending.subscribers.removeValue(forKey: id) else { return }
        if !subscriber.cancellation.isCancelled, subscriber.isAuthorized() {
            subscriber.continuation.resume(returning: entries)
        } else { subscriber.continuation.resume(throwing: CancellationError()) }
        if pending.subscribers.isEmpty { complete(pending, key: key, result: .success(entries)) }
    }

    private func requireSubscribers(_ pending: PendingLoad, key: TrackerLibraryCacheKey) throws {
        try Task.checkCancellation()
        guard pendingLoads[key] === pending, isCurrent(pending.token, key: key) else { throw CancellationError() }
        for (id, subscriber) in pending.subscribers where subscriber.cancellation.isCancelled || !subscriber.isAuthorized() {
            removeSubscriber(id, key: key)
        }
        guard !pending.subscribers.isEmpty else { throw CancellationError() }
    }

    private func publish(_ snapshot: TrackerLibrarySnapshot, fresh: TrackerLibrarySnapshot, pending: PendingLoad, key: TrackerLibraryCacheKey) throws {
        try requireSubscribers(pending, key: key)
        pending.latest = snapshot
        pending.latestFresh = fresh
        for (id, subscriber) in pending.subscribers {
            guard pendingLoads[key] === pending, isCurrent(pending.token, key: key) else { throw CancellationError() }
            if !subscriber.cancellation.isCancelled, subscriber.isAuthorized() {
                subscriber.onUpdate?(snapshot)
                if let entryID = subscriber.matchingEntryID, fresh.entries.contains(where: { $0.id == entryID }) {
                    completeMatchingSubscriber(id, entries: fresh.entries, pending: pending, key: key)
                }
            } else { removeSubscriber(id, key: key) }
        }
        try requireSubscribers(pending, key: key)
    }

    func load(
        key: TrackerLibraryCacheKey,
        forceRefresh: Bool,
        now: @escaping () -> Date = Date.init,
        isAuthorized: @escaping @MainActor () -> Bool,
        fetchPage: @escaping @MainActor (TrackerLibraryCursor) async throws -> TrackerLibraryPage,
        onUpdate: (@MainActor (TrackerLibrarySnapshot) -> Void)?
    ) async throws -> [TrackerLibraryEntry] {
        try await load(key: key, forceRefresh: forceRefresh, now: now, isAuthorized: isAuthorized,
            fetchPage: fetchPage, onUpdate: onUpdate, matchingEntryID: nil)
    }

    func contains(
        _ entryID: String,
        key: TrackerLibraryCacheKey,
        forceRefresh: Bool,
        now: @escaping () -> Date = Date.init,
        isAuthorized: @escaping @MainActor () -> Bool,
        fetchPage: @escaping @MainActor (TrackerLibraryCursor) async throws -> TrackerLibraryPage
    ) async throws -> Bool {
        let entries = try await load(key: key, forceRefresh: forceRefresh, now: now, isAuthorized: isAuthorized,
            fetchPage: fetchPage, onUpdate: nil, matchingEntryID: entryID)
        return entries.contains { $0.id == entryID }
    }

    private func load(
        key: TrackerLibraryCacheKey,
        forceRefresh: Bool,
        now: @escaping () -> Date,
        isAuthorized: @escaping @MainActor () -> Bool,
        fetchPage: @escaping @MainActor (TrackerLibraryCursor) async throws -> TrackerLibraryPage,
        onUpdate: (@MainActor (TrackerLibrarySnapshot) -> Void)?,
        matchingEntryID: String?
    ) async throws -> [TrackerLibraryEntry] {
        try Task.checkCancellation()
        guard isAuthorized() else { throw CancellationError() }
        let cached = snapshot(for: key, now: now())
        if let cached {
            onUpdate?(cached)
            try Task.checkCancellation()
            guard isAuthorized() else { throw CancellationError() }
            if cached.isComplete && !cached.isStale && !forceRefresh { return cached.entries }
        }
        let id = UUID()
        let cancellation = SubscriptionCancellation()
        let entries: [TrackerLibraryEntry] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled, !cancellation.isCancelled, isAuthorized() else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let subscriber = Subscriber(cancellation: cancellation, matchingEntryID: matchingEntryID, isAuthorized: isAuthorized, onUpdate: onUpdate, continuation: continuation)
                if let pending = pendingLoads[key] {
                    TrackerLibraryDiagnostics.log("load joined \(TrackerLibraryDiagnostics.scope(key)) subscribers=\(pending.subscribers.count + 1)")
                    pending.subscribers[id] = subscriber
                    if let latest = pending.latest { onUpdate?(latest) }
                    if let matchingEntryID, let fresh = pending.latestFresh,
                       fresh.entries.contains(where: { $0.id == matchingEntryID }) {
                        completeMatchingSubscriber(id, entries: fresh.entries, pending: pending, key: key)
                    }
                    return
                }
                let pending = PendingLoad(token: begin(key))
                TrackerLibraryDiagnostics.log("load started \(TrackerLibraryDiagnostics.scope(key)) cached=\(cached?.entries.count ?? 0) force=\(forceRefresh)")
                pending.subscribers[id] = subscriber
                pendingLoads[key] = pending
                pending.task = Task { @MainActor in
                    do {
                        let entries = try await self.fetch(pending, key: key, cached: cached, now: now, fetchPage: fetchPage)
                        self.complete(pending, key: key, result: .success(entries))
                    } catch {
                        TrackerLibraryDiagnostics.log("load failed \(TrackerLibraryDiagnostics.scope(key)) result=\(TrackerLibraryDiagnostics.failure(error)) retained=\(self.values[key]?.entries.count ?? 0)")
                        self.complete(pending, key: key, result: .failure(error))
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor in self.removeSubscriber(id, key: key) }
        }
        try Task.checkCancellation()
        guard isAuthorized() else { throw CancellationError() }
        return entries
    }

    private func fetch(
        _ pending: PendingLoad,
        key: TrackerLibraryCacheKey,
        cached: TrackerLibrarySnapshot?,
        now: @escaping () -> Date,
        fetchPage: @escaping @MainActor (TrackerLibraryCursor) async throws -> TrackerLibraryPage
    ) async throws -> [TrackerLibraryEntry] {
        var entries: [TrackerLibraryEntry] = []
        var indexes: [String: Int] = [:]
        var estimatedBytes = 0
        var receivedRows = 0
        var expectedTotal: Int?
        var cursor: TrackerLibraryCursor? = .page(1)
        var visited = Set<TrackerLibraryCursor>()
        while let current = cursor {
            try requireSubscribers(pending, key: key)
            guard visited.count < TrackerLibraryPolicy.maximumPageCount, visited.insert(current).inserted else {
                throw TrackerLibraryError.tooLarge
            }
            let page = try await TrackerRequestContext.$priority.withValue(visited.count == 1 ? .visible : .background) {
                try await fetchPage(current)
            }
            try requireSubscribers(pending, key: key)
            let maximumPageEntries = key.session.service == .trakt && TrackerLibraryPolicy.traktCollectionIsUnpaginated(kind: key.kind, section: key.section)
                ? TrackerLibraryPolicy.maximumEntries : TrackerLibraryPolicy.pageSize * 10
            guard page.entries.count <= maximumPageEntries else { throw TrackerLibraryError.tooLarge }
            guard page.providerEntryCount >= page.entries.count, page.rawEntryCount >= page.providerEntryCount else { throw TrackerLibraryError.invalidResponse }
            guard page.rawEntryCount <= TrackerLibraryPolicy.maximumEntries,
                  page.providerEntryCount <= TrackerLibraryPolicy.maximumEntries - receivedRows else { throw TrackerLibraryError.tooLarge }
            receivedRows += page.providerEntryCount
            guard receivedRows <= TrackerLibraryPolicy.maximumEntries else { throw TrackerLibraryError.tooLarge }
            if let total = page.expectedTotal { expectedTotal = total }
            let next = try TrackerLibraryPolicy.traktCompletionCursor(next: page.next,
                receivedCount: receivedRows, expectedTotal: expectedTotal)
            let previousCount = entries.count
            var changedVersions = 0
            for entry in page.entries {
                if let index = indexes[entry.id] {
                    if key.session.service == .anilist {
                        let earlier = entries[index]
                        let merged = try TrackerLibraryPolicy.mergedAniListDuplicate(earlier, entry)
                        if merged != earlier {
                            changedVersions += 1
                            entries[index] = merged
                            estimatedBytes += Self.cost(merged) - Self.cost(earlier)
                        }
                    }
                    continue
                }
                guard entries.count < TrackerLibraryPolicy.maximumEntries else { throw TrackerLibraryError.tooLarge }
                indexes[entry.id] = entries.count
                entries.append(entry)
                estimatedBytes += Self.cost(entry)
            }
            let allowsEmptyFilteredPage: Bool
            if key.session.service == .trakt, case .customList = key.section {
                allowsEmptyFilteredPage = page.entries.isEmpty
            } else if key.kind.isReader, key.session.service == .anilist || key.session.service == .myAnimeList {
                allowsEmptyFilteredPage = page.entries.isEmpty && page.rawEntryCount > 0
            } else { allowsEmptyFilteredPage = false }
            let allowsGroupedAniListPage = key.session.service == .anilist && !page.entries.isEmpty
            if next != nil && entries.count == previousCount && changedVersions == 0 && !allowsEmptyFilteredPage && !allowsGroupedAniListPage {
                throw TrackerLibraryError.invalidResponse
            }
            TrackerLibraryDiagnostics.log("page merged \(TrackerLibraryDiagnostics.scope(key)) cursor=\(TrackerLibraryDiagnostics.cursor(current)) rows=\(page.rawEntryCount) provider=\(page.providerEntryCount) visible=\(page.entries.count) received=\(receivedRows) expected=\(expectedTotal.map(String.init) ?? "unknown") added=\(entries.count - previousCount) duplicates=\(page.entries.count - entries.count + previousCount) versions=\(changedVersions) unique=\(entries.count) next=\(TrackerLibraryDiagnostics.cursor(next))")
            cursor = next
            let snapshot = TrackerLibrarySnapshot(entries: entries, isComplete: cursor == nil, isStale: false, fetchedAt: now())
            store(snapshot, key: key, token: pending.token, estimatedBytes: estimatedBytes)
            if cursor != nil, let cached {
                var visible = entries
                try TrackerLibraryPolicy.appendPreservingCache(cached.entries, to: &visible)
                try publish(TrackerLibrarySnapshot(entries: visible, isComplete: false, isStale: true, fetchedAt: cached.fetchedAt), fresh: snapshot, pending: pending, key: key)
            } else { try publish(snapshot, fresh: snapshot, pending: pending, key: key) }
        }
        try requireSubscribers(pending, key: key)
        TrackerLibraryDiagnostics.log("load complete \(TrackerLibraryDiagnostics.scope(key)) pages=\(visited.count) unique=\(entries.count)")
        return entries
    }
}

extension TrackerLibraryPolicy {
    static func validatedIdentifier(_ value: Int?) -> Int? { TrackerRemoteProgressBoundary.positiveIdentifier(value) }
    static func validatedYear(_ value: Int?) -> Int? { value.flatMap { (1800...2200).contains($0) ? $0 : nil } }
    static func validatedFormat(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return ["TV", "TV_SHORT", "MOVIE", "SPECIAL", "OVA", "ONA", "MUSIC", "MANGA", "NOVEL", "ONE_SHOT", "LIGHT_NOVEL", "MANHWA", "MANHUA", "DOUJINSHI"].contains(normalized) ? normalized : nil
    }
    static func validatedIMDB(_ value: String?) -> String? {
        guard let value, value.hasPrefix("tt"), (3...16).contains(value.count), value.dropFirst(2).allSatisfy(\.isNumber) else { return nil }
        return value
    }
    static func appendPreservingCache(_ previous: [TrackerLibraryEntry], to entries: inout [TrackerLibraryEntry]) throws {
        var seen = Set(entries.map(\.id))
        for entry in previous where seen.insert(entry.id).inserted {
            guard entries.count < maximumEntries else { break }
            entries.append(entry)
        }
    }
    static func traktPath(kind: TrackerLibraryKind, section: TrackerLibrarySection) throws -> String {
        guard [.movie, .show].contains(kind) else { throw TrackerLibraryError.unavailable }
        switch section {
        case .list, .watchlist: return "sync/watchlist/\(kind.traktPath)/added/desc"
        case .history: return "sync/watched/\(kind.traktPath)"
        case .collection: return "sync/collection/\(kind.traktPath)"
        case .customList(let id, _):
            guard validatedIdentifier(id) != nil else { throw TrackerLibraryError.unavailable }
            return "users/me/lists/\(id)/items/\(kind == .movie ? "movie" : "show")"
        case .aniListCustomList: throw TrackerLibraryError.unavailable
        }
    }
    static func traktCollectionIsUnpaginated(kind: TrackerLibraryKind, section: TrackerLibrarySection) -> Bool {
        kind == .show && section == .collection
    }

    static func traktLibraryPage(response: HTTPURLResponse, requested: Int, entries: [TrackerLibraryEntry],
                                 kind: TrackerLibraryKind, section: TrackerLibrarySection) throws -> TrackerLibraryPage {
        if traktCollectionIsUnpaginated(kind: kind, section: section), !traktHasPageHeaders(response) {
            guard requested == 1, entries.count <= maximumEntries else { throw TrackerLibraryError.tooLarge }
            let raw = response.value(forHTTPHeaderField: "X-Pagination-Item-Count")
            if let raw {
                guard let total = Int(raw), total == entries.count else { throw TrackerLibraryError.invalidResponse }
            }
            return TrackerLibraryPage(entries: entries, next: nil, expectedTotal: entries.count)
        }
        let allowsEmptyFilteredPage: Bool
        if case .customList = section { allowsEmptyFilteredPage = true }
        else { allowsEmptyFilteredPage = false }
        return TrackerLibraryPage(entries: entries, next: try traktNextPage(response: response, requested: requested,
            count: entries.count, allowsEmptyFilteredPage: allowsEmptyFilteredPage),
            expectedTotal: allowsEmptyFilteredPage ? nil : response.value(forHTTPHeaderField: "X-Pagination-Item-Count").flatMap(Int.init))
    }

    static func traktHasPaginationHeaders(_ response: HTTPURLResponse) -> Bool {
        ["X-Pagination-Page", "X-Pagination-Page-Count", "X-Pagination-Limit", "X-Pagination-Item-Count"].contains {
            response.value(forHTTPHeaderField: $0) != nil
        }
    }

    static func traktHasPageHeaders(_ response: HTTPURLResponse) -> Bool {
        ["X-Pagination-Page", "X-Pagination-Page-Count", "X-Pagination-Limit"].contains {
            response.value(forHTTPHeaderField: $0) != nil
        }
    }

    static func traktCompletionCursor(next: TrackerLibraryCursor?, receivedCount: Int, expectedTotal: Int?) throws -> TrackerLibraryCursor? {
        guard let expectedTotal else { return next }
        guard (0...maximumEntries).contains(expectedTotal) else { throw TrackerLibraryError.tooLarge }
        guard receivedCount <= expectedTotal else { throw TrackerLibraryError.invalidResponse }
        if receivedCount == expectedTotal { return nil }
        guard next != nil else { throw TrackerLibraryError.invalidResponse }
        return next
    }

    static func traktListsNextPage(response: HTTPURLResponse, requested: Int, count: Int) throws -> TrackerLibraryCursor? {
        if !traktHasPaginationHeaders(response) {
            guard requested == 1, (0...pageSize * 10).contains(count) else { throw TrackerLibraryError.tooLarge }
            return nil
        }
        return try traktNextPage(response: response, requested: requested, count: count)
    }

    static func traktNextPage(response: HTTPURLResponse, requested: Int, count: Int, allowsEmptyFilteredPage: Bool = false) throws -> TrackerLibraryCursor? {
        guard (1...maximumPageCount).contains(requested), (0...pageSize).contains(count) else { throw TrackerLibraryError.tooLarge }
        func number(_ name: String) throws -> Int? {
            guard let value = response.value(forHTTPHeaderField: name) else { return nil }
            guard let result = Int(value), result >= 0 else { throw TrackerLibraryError.invalidResponse }
            return result
        }
        let returned = try number("X-Pagination-Page")
        let pages = try number("X-Pagination-Page-Count")
        let limit = try number("X-Pagination-Limit")
        let total = try number("X-Pagination-Item-Count")
        guard returned == nil || returned == requested,
              limit.map({ $0 > 0 && $0 <= pageSize && count <= $0 }) ?? true,
              pages.map({ $0 <= maximumPageCount }) ?? true,
              total.map({ $0 <= maximumEntries }) ?? true else { throw TrackerLibraryError.tooLarge }
        if let pages {
            if pages == 0 && count == 0 && requested == 1 && (total ?? 0) == 0 { return nil }
            guard pages >= requested else { throw TrackerLibraryError.invalidResponse }
            guard count > 0 || allowsEmptyFilteredPage || requested == pages else {
                throw TrackerLibraryError.invalidResponse
            }
            return requested < pages ? .page(requested + 1) : nil
        }
        if count == 0 { return nil }
        return .page(requested + 1)
    }
}

struct TrackerTraktLibraryItem: Decodable {
    let type: String?
    let movie: Media?
    let show: Media?
    let listed_at: String?
    let last_watched_at: String?
    let last_collected_at: String?
    let collected_at: String?
    let plays: Int?
    let rating: Double?

    struct Media: Decodable {
        let title: String
        let year: Int?
        let ids: IDs
        let genres: [String]?
        let rating: Double?
        let aired_episodes: Int?
    }
    struct IDs: Decodable { let trakt: Int; let tmdb: Int?; let imdb: String?; let slug: String? }

    static func decode(_ data: Data, kind: TrackerLibraryKind, section: TrackerLibrarySection) throws -> [TrackerLibraryEntry] {
        guard data.count <= TrackerLibraryPolicy.maximumResponseBytes else { throw TrackerLibraryError.tooLarge }
        let items = try JSONDecoder().decode([Self].self, from: data)
        let maximumEntries = TrackerLibraryPolicy.traktCollectionIsUnpaginated(kind: kind, section: section)
            ? TrackerLibraryPolicy.maximumEntries : TrackerLibraryPolicy.pageSize
        guard items.count <= maximumEntries else { throw TrackerLibraryError.tooLarge }
        let fractionalDateParser = ISO8601DateFormatter()
        fractionalDateParser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let dateParser = ISO8601DateFormatter()
        return try items.map { item in
            guard [.movie, .show].contains(kind), let media = kind == .movie ? item.movie : item.show,
                  item.type == nil || item.type == (kind == .movie ? "movie" : "show") else { throw TrackerLibraryError.invalidResponse }
            let entry = TrackerLibraryEntry(service: .trakt, kind: kind, mediaID: media.ids.trakt,
                entryID: nil, aniListID: nil, malID: nil, title: media.title, alternateTitles: [],
                coverLarge: nil, coverMedium: nil, total: kind == .show ? media.aired_episodes : nil,
                genres: media.genres ?? [], averageScore: media.rating.map { $0 * 10 },
                status: section == .history ? .completed : .planning,
                progress: kind == .movie ? item.plays ?? 0 : 0, score: (item.rating ?? 0) * 10,
                updatedAt: parseDate(item.last_watched_at ?? item.last_collected_at ?? item.collected_at ?? item.listed_at,
                    fractional: fractionalDateParser, plain: dateParser),
                tmdbID: TrackerLibraryPolicy.validatedIdentifier(media.ids.tmdb),
                traktSlug: media.ids.slug.flatMap { $0.utf8.count <= 256 ? $0 : nil },
                format: kind == .movie ? "MOVIE" : "TV", year: TrackerLibraryPolicy.validatedYear(media.year),
                imdbID: TrackerLibraryPolicy.validatedIMDB(media.ids.imdb))
            try TrackerLibraryPolicy.validate(entry)
            return entry
        }
    }

    private static func parseDate(_ value: String?, fractional: ISO8601DateFormatter, plain: ISO8601DateFormatter) -> Date? {
        guard let value, value.utf8.count <= 64 else { return nil }
        return fractional.date(from: value) ?? plain.date(from: value)
    }
}

struct TrackerTraktLibraryList: Decodable {
    let name: String
    let ids: IDs
    let item_count: Int?
    struct IDs: Decodable { let trakt: Int }

    static func decode(_ data: Data) throws -> [TrackerLibraryList] {
        guard data.count <= TrackerLibraryPolicy.maximumResponseBytes else { throw TrackerLibraryError.tooLarge }
        let rows = try JSONDecoder().decode([Self].self, from: data)
        guard rows.count <= TrackerLibraryPolicy.pageSize * 10 else { throw TrackerLibraryError.tooLarge }
        return try rows.map { row in
            guard TrackerLibraryPolicy.validatedIdentifier(row.ids.trakt) != nil,
                  !row.name.isEmpty, row.name.utf8.count <= 1_024,
                  row.item_count.map({ (0...TrackerLibraryPolicy.maximumEntries).contains($0) }) ?? true else {
                throw TrackerLibraryError.invalidResponse
            }
            return TrackerLibraryList(id: row.ids.trakt, name: row.name, itemCount: row.item_count)
        }
    }
}

struct TrackerTraktLibraryRating: Decodable {
    let rating: Int
    let movie: Media?
    let show: Media?
    struct Media: Decodable { let ids: IDs }
    struct IDs: Decodable { let trakt: Int }

    static func decode(_ data: Data, kind: TrackerLibraryKind) throws -> [Int: Int] {
        guard data.count <= TrackerLibraryPolicy.maximumResponseBytes else { throw TrackerLibraryError.tooLarge }
        let rows = try JSONDecoder().decode([Self].self, from: data)
        guard rows.count <= TrackerLibraryPolicy.pageSize else { throw TrackerLibraryError.tooLarge }
        var ratings: [Int: Int] = [:]
        for row in rows {
            guard [.movie, .show].contains(kind), let media = kind == .movie ? row.movie : row.show,
                  TrackerLibraryPolicy.validatedIdentifier(media.ids.trakt) != nil, (1...10).contains(row.rating),
                  ratings[media.ids.trakt] == nil else { throw TrackerLibraryError.invalidResponse }
            ratings[media.ids.trakt] = row.rating
        }
        return ratings
    }
}

struct TrackerLibraryPlaybackIntent: Equatable {
    let entry: TrackerLibraryEntry
    let session: TrackerLibrarySession
}

struct TrackerLibraryPlaybackSnapshot: Equatable {
    let target: TrackerLibraryPlaybackTarget
    let intent: TrackerLibraryPlaybackIntent
    let metadataGeneration: UUID
    let currentEntry: TrackerLibraryEntry?

    init(target: TrackerLibraryPlaybackTarget, intent: TrackerLibraryPlaybackIntent,
         metadataGeneration: UUID, currentEntry: TrackerLibraryEntry? = nil) {
        self.target = target
        self.intent = intent
        self.metadataGeneration = metadataGeneration
        self.currentEntry = currentEntry
    }

    func isCurrent(for intent: TrackerLibraryPlaybackIntent, metadataGeneration: UUID?) -> Bool {
        self.intent == intent && self.metadataGeneration == metadataGeneration
    }
}

enum TrackerLibraryPlaybackTarget: Equatable {
    case animeEpisode(Int)
    case traktEpisode(season: Int, number: Int, tmdbID: Int?)
    case caughtUp
}

enum TrackerLibraryPlaybackPolicy {
    enum AnimeEpisodeResolution: Equatable {
        case episode(Int)
        case caughtUp
        case unaired
        case unavailable
    }

    static func animeTarget(_ entry: TrackerLibraryEntry) throws -> TrackerLibraryPlaybackTarget {
        try TrackerLibraryPolicy.validate(entry)
        guard entry.kind == .anime, entry.service != .trakt else { throw TrackerLibraryError.unavailable }
        if entry.status == .completed || entry.total.map({ $0 > 0 && entry.progress >= $0 }) == true { return .caughtUp }
        guard entry.progress < 100_000 else { throw TrackerLibraryError.invalidResponse }
        return .animeEpisode(entry.progress + 1)
    }

    static func resolveAnimeEpisode(
        nextCanonicalNumber: Int, service: TrackerService, tmdbShowID: Int,
        aniListID: Int?, malID: Int?, episodes: [AniListEpisode], now: Date = Date()
    ) -> AnimeEpisodeResolution {
        guard service == .anilist || service == .myAnimeList,
              (1...100_000).contains(nextCanonicalNumber), !episodes.isEmpty,
              episodes.count <= RemoteMediaNumericBoundary.maximumEpisodeCount else { return .unavailable }
        let selected: AniListEpisode
        if episodes.contains(where: { $0.unitProjection != nil }) {
            guard AnimeVerifiedEpisodeUnitPolicy.validatesInventory(episodes, tmdbShowID: tmdbShowID,
                aniListID: aniListID, malID: malID) else { return .unavailable }
            let ordered = episodes.sorted { $0.number < $1.number }
            let ranges = ordered.compactMap { episode in
                service == .myAnimeList ? episode.unitProjection?.canonicalMALEpisodeRange?.range
                    : episode.unitProjection?.canonicalAniListEpisodeRange?.range
            }
            guard ranges.count == ordered.count, let count = ranges.map(\.upperBound).max() else { return .unavailable }
            if nextCanonicalNumber == count + 1 { return .caughtUp }
            guard nextCanonicalNumber <= count else { return .unavailable }
            let matches = ordered.enumerated().filter { ranges[$0.offset].contains(nextCanonicalNumber) }
            if ordered.first?.unitProjection?.edition == .featurePart, service == .anilist {
                guard matches.count == ordered.count, let first = ordered.first else { return .unavailable }
                selected = first
            } else {
                guard matches.count == 1, let match = matches.first else { return .unavailable }
                selected = match.element
            }
        } else {
            guard !AnimeVerifiedEpisodeUnitPolicy.requiresVerifiedInventory(tmdbShowID: tmdbShowID,
                aniListID: aniListID, malID: malID) else { return .unavailable }
            let matches = episodes.filter { $0.number == nextCanonicalNumber }
            guard matches.count == 1, let episode = matches.first else { return .unavailable }
            selected = episode
        }
        return isKnownFutureDate(selected.airDate, now: now) ? .unaired : .episode(selected.number)
    }

    static func verifiedAnimeFeatureEpisode(
        entry: TrackerLibraryEntry, movie: TMDBMovieDetail, displaySeasonNumber: Int = 1
    ) -> AniListEpisode? {
        guard (try? TrackerLibraryPolicy.validate(entry)) != nil, entry.kind == .anime,
              entry.format?.uppercased() == "ONA" else { return nil }
        switch entry.service {
        case .anilist:
            guard entry.mediaID == 170_935, entry.aniListID == 170_935,
                  entry.malID == nil || entry.malID == 57_184,
                  entry.total == nil || entry.total == 1 else { return nil }
        case .myAnimeList:
            guard entry.mediaID == 57_184, entry.malID == 57_184,
                  entry.aniListID == nil || entry.aniListID == 170_935,
                  entry.total == nil || entry.total == 4 else { return nil }
        default: return nil
        }
        return AnimeVerifiedEpisodeUnitPolicy.razbliutoMovieEpisode(movie: movie,
            displaySeasonNumber: displaySeasonNumber)
    }

    static func uniqueSeason(providerIDs: [Int: Int], acceptedIDs: Set<Int>) -> Int? {
        let matches = providerIDs.filter { acceptedIDs.contains($0.value) }.map(\.key)
        return matches.count == 1 ? matches.first : nil
    }

    static func isKnownFutureDate(_ raw: String?, now: Date = Date()) -> Bool {
        guard let raw, raw.count >= 10 else { return false }
        let date = String(raw.prefix(10))
        let formatter = AppCalendar.dateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let parsed = formatter.date(from: date), formatter.string(from: parsed) == date else { return false }
        return date > formatter.string(from: now)
    }
}

struct TrackerTraktPlaybackProgress: Decodable {
    struct Episode: Decodable {
        struct IDs: Decodable { let tmdb: Int? }
        let season: Int
        let number: Int
        let ids: IDs?
    }
    let aired: Int
    let completed: Int
    let next_episode: Episode?

    enum CodingKeys: String, CodingKey { case aired, completed, next_episode }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        aired = try container.decode(Int.self, forKey: .aired)
        completed = try container.decode(Int.self, forKey: .completed)
        guard container.contains(.next_episode) else { throw TrackerLibraryError.invalidResponse }
        next_episode = try container.decodeIfPresent(Episode.self, forKey: .next_episode)
    }

    static func decode(_ data: Data) throws -> TrackerLibraryPlaybackTarget {
        guard data.count <= TrackerLibraryPolicy.maximumResponseBytes else { throw TrackerLibraryError.tooLarge }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard (0...100_000).contains(value.aired), (0...100_000).contains(value.completed) else { throw TrackerLibraryError.invalidResponse }
        guard let episode = value.next_episode else { return .caughtUp }
        guard (1...10_000).contains(episode.season), (1...100_000).contains(episode.number),
              episode.ids?.tmdb.map({ TrackerLibraryPolicy.validatedIdentifier($0) != nil }) ?? true else { throw TrackerLibraryError.invalidResponse }
        return .traktEpisode(season: episode.season, number: episode.number, tmdbID: episode.ids?.tmdb)
    }
}
