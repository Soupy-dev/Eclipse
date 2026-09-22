import Foundation

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
                    pending.subscribers[id] = subscriber
                    if let latest = pending.latest { onUpdate?(latest) }
                    if let matchingEntryID, let fresh = pending.latestFresh,
                       fresh.entries.contains(where: { $0.id == matchingEntryID }) {
                        completeMatchingSubscriber(id, entries: fresh.entries, pending: pending, key: key)
                    }
                    return
                }
                let pending = PendingLoad(token: begin(key))
                pending.subscribers[id] = subscriber
                pendingLoads[key] = pending
                pending.task = Task { @MainActor in
                    do {
                        let entries = try await self.fetch(pending, key: key, cached: cached, now: now, fetchPage: fetchPage)
                        self.complete(pending, key: key, result: .success(entries))
                    } catch {
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
        var seen = Set<String>()
        var estimatedBytes = 0
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
            let previousCount = entries.count
            for entry in page.entries where seen.insert(entry.id).inserted {
                guard entries.count < TrackerLibraryPolicy.maximumEntries else { throw TrackerLibraryError.tooLarge }
                entries.append(entry)
                estimatedBytes += Self.cost(entry)
            }
            if page.next != nil && entries.count == previousCount { throw TrackerLibraryError.invalidResponse }
            cursor = page.next
            let snapshot = TrackerLibrarySnapshot(entries: entries, isComplete: cursor == nil, isStale: false, fetchedAt: now())
            store(snapshot, key: key, token: pending.token, estimatedBytes: estimatedBytes)
            if cursor != nil, let cached {
                var visible = entries
                try TrackerLibraryPolicy.appendPreservingCache(cached.entries, to: &visible)
                try publish(TrackerLibrarySnapshot(entries: visible, isComplete: false, isStale: true, fetchedAt: cached.fetchedAt), fresh: snapshot, pending: pending, key: key)
            } else { try publish(snapshot, fresh: snapshot, pending: pending, key: key) }
        }
        try requireSubscribers(pending, key: key)
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
        if traktCollectionIsUnpaginated(kind: kind, section: section) {
            guard requested == 1, entries.count <= maximumEntries else { throw TrackerLibraryError.tooLarge }
            for name in ["X-Pagination-Page", "X-Pagination-Page-Count", "X-Pagination-Item-Count"] {
                guard let raw = response.value(forHTTPHeaderField: name) else { continue }
                guard let value = Int(raw), value >= 0 else { throw TrackerLibraryError.invalidResponse }
                if name == "X-Pagination-Item-Count" {
                    guard value == entries.count else { throw TrackerLibraryError.invalidResponse }
                } else {
                    guard value == 1 || (name == "X-Pagination-Page-Count" && value == 0 && entries.isEmpty) else {
                        throw TrackerLibraryError.invalidResponse
                    }
                }
            }
            return TrackerLibraryPage(entries: entries, next: nil)
        }
        return TrackerLibraryPage(entries: entries, next: try traktNextPage(response: response, requested: requested, count: entries.count))
    }

    static func traktNextPage(response: HTTPURLResponse, requested: Int, count: Int) throws -> TrackerLibraryCursor? {
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
        if count == 0 { return nil }
        if let pages {
            guard pages >= requested else { throw TrackerLibraryError.invalidResponse }
            return requested < pages ? .page(requested + 1) : nil
        }
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
        guard rows.count <= TrackerLibraryPolicy.pageSize else { throw TrackerLibraryError.tooLarge }
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
    static func animeTarget(_ entry: TrackerLibraryEntry) throws -> TrackerLibraryPlaybackTarget {
        try TrackerLibraryPolicy.validate(entry)
        guard entry.kind == .anime, entry.service != .trakt else { throw TrackerLibraryError.unavailable }
        if entry.status == .completed || entry.total.map({ $0 > 0 && entry.progress >= $0 }) == true { return .caughtUp }
        guard entry.progress < 100_000 else { throw TrackerLibraryError.invalidResponse }
        return .animeEpisode(entry.progress + 1)
    }

    static func uniqueSeason(providerIDs: [Int: Int], acceptedIDs: Set<Int>) -> Int? {
        let matches = providerIDs.filter { acceptedIDs.contains($0.value) }.map(\.key)
        return matches.count == 1 ? matches.first : nil
    }

    static func isKnownFutureDate(_ raw: String?, now: Date = Date()) -> Bool {
        guard let raw, raw.count >= 10 else { return false }
        let date = String(raw.prefix(10))
        let formatter = DateFormatter()
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
