import Foundation
import Security
import SwiftUI

struct MacStremioAddon: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    var manifestID: String
    var name: String
    var summary: String?
    var logo: String?
    var baseURL: String
    var idPrefixes: [String]
    var isActive: Bool
}

struct MacStremioStream: Identifiable, Hashable, Sendable {
    let id: String
    let sourceID: String
    let addonName: String
    let title: String
    let detail: String?
    let url: URL
    let headers: [String: String]
    let size: Int64?
    let metadataText: String

    var formattedSize: String? {
        size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }
}

/// A small, deterministic policy layer shared by the Mac Stremio and legacy-Service paths.
/// Metadata inspection is deliberately bounded because provider-controlled labels can be large.
enum MacServiceStreamPolicy {
    private static let maximumMetadataCharacters = 8_192
    private static let minimumSimilarityRange = 0.50...1.00
    private static let defaultMinimumSimilarity = 0.85

    enum QualityPreference {
        case manual
        case automatic
        case highest
        case target(Int)
        case lowest

        init(defaults: UserDefaults = .standard) {
            switch defaults.string(forKey: "servicesAutoModeQualityPreference")?.lowercased() {
            case "manual": self = .manual
            case "highest": self = .highest
            case "2160p": self = .target(2160)
            case "1080p": self = .target(1080)
            case "720p": self = .target(720)
            case "480p": self = .target(480)
            case "lowest": self = .lowest
            // `best` was briefly used by the first Mac settings screen. Treat it as Auto so
            // existing local preferences remain useful while canonical values migrate to `auto`.
            case "best", "auto", nil: self = .automatic
            default: self = .automatic
            }
        }
    }

    struct Analysis {
        let qualityHeight: Int?
        let detectedLanguages: Set<String>
        let hasLanguageData: Bool
        let sourceScore: Int
        let sizeMB: Double?
    }

    static func apply<T>(to values: [T], metadata: (T) -> [String], defaults: UserDefaults = .standard) -> [T] {
        let includedLanguages = configuredLanguages(forKey: "servicesIncludedStreamLanguages", defaults: defaults)
        let hiddenLanguages = configuredLanguages(forKey: "servicesHiddenStreamLanguages", defaults: defaults)
        let hideUnknownLanguage = defaults.bool(forKey: "servicesHideStreamsWithoutLanguageData")
        let hideUnknownQuality = defaults.bool(forKey: "servicesHideStreamsWithoutDetectedQuality")
        let hiddenQualities = configuredHiddenQualities(defaults: defaults)
        let preference = QualityPreference(defaults: defaults)

        let candidates = values.enumerated().compactMap { index, value -> (Int, T, Analysis)? in
            let analysis = analyze(metadata(value))

            if hideUnknownQuality, analysis.qualityHeight == nil { return nil }
            if let height = analysis.qualityHeight, hiddenQualities.contains(height) { return nil }

            // Included languages are an allowlist: once nonempty, a stream must positively match.
            // Hidden languages are a denylist and win if a stream matches both lists.
            if !includedLanguages.isEmpty,
               analysis.detectedLanguages.isDisjoint(with: includedLanguages) {
                return nil
            }
            if !hiddenLanguages.isEmpty,
               !analysis.detectedLanguages.isDisjoint(with: hiddenLanguages) {
                return nil
            }
            if hideUnknownLanguage, !analysis.hasLanguageData { return nil }

            return (index, value, analysis)
        }

        guard preference != .manual else { return candidates.map(\.1) }
        return candidates.sorted { lhs, rhs in
            isPreferred(lhs.2, over: rhs.2, preference: preference, lhsIndex: lhs.0, rhsIndex: rhs.0)
        }
        .map(\.1)
    }

    static func minimumSimilarity(defaults: UserDefaults = .standard) -> Double {
        guard let stored = defaults.object(forKey: "servicesResultMinimumSimilarity") as? NSNumber,
              stored.doubleValue.isFinite else {
            return defaultMinimumSimilarity
        }
        return max(minimumSimilarityRange.lowerBound, min(stored.doubleValue, minimumSimilarityRange.upperBound))
    }

    static func dropsMismatchedResults(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: "servicesDropMismatchedResults") == nil
            ? true
            : defaults.bool(forKey: "servicesDropMismatchedResults")
    }

    static func titleSimilarity(expected: String, result: String) -> Double {
        let lhs = normalizedTitle(expected)
        let rhs = normalizedTitle(result)
        guard !lhs.isEmpty, !rhs.isEmpty else { return lhs == rhs ? 1 : 0 }
        if lhs == rhs { return 1 }

        let editScore = normalizedLevenshtein(lhs, rhs)
        let tokenScore = tokenOverlap(lhs, rhs)
        var score = editScore * 0.72 + tokenScore * 0.28
        if lhs.contains(rhs) || rhs.contains(lhs) { score += 0.08 }
        return max(0, min(score, 1))
    }

    private static func analyze(_ values: [String]) -> Analysis {
        let text = boundedMetadata(values)
        let lower = text.lowercased()
        let tokens = Set(lower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
        let knownLanguages = Set(languageDefinitions.compactMap { language -> String? in
            language.aliases.contains(where: tokens.contains) ? language.canonical : nil
        })
        // Keep longer raw tokens for user-entered languages that are not in Eclipse's built-in
        // aliases. They participate only in explicit include/exclude matching, not in the
        // "has language data" decision, which prevents arbitrary title words from defeating the
        // unknown-language toggle.
        let languages = knownLanguages.union(tokens.filter { $0.count >= 3 })
        let hasGenericLanguageData = containsPhrase("dual audio", in: lower)
            || containsPhrase("multi audio", in: lower)
            || containsPhrase("multi language", in: lower)
            || containsPhrase("multilingual", in: lower)

        let sourceScore: Int
        if lower.contains("remux") { sourceScore = 9 }
        else if lower.contains("bluray") || lower.contains("blu-ray") || lower.contains("bdrip") || lower.contains("brrip") { sourceScore = 8 }
        else if lower.contains("web-dl") || lower.contains("webdl") { sourceScore = 7 }
        else if lower.contains("webrip") || tokens.contains("web") { sourceScore = 6 }
        else if lower.contains("hdtv") || lower.contains("hdrip") { sourceScore = 5 }
        else if lower.contains("dvd") { sourceScore = 4 }
        else if lower.contains("hdcam") || tokens.contains("cam") || tokens.contains("telesync") { sourceScore = 1 }
        else { sourceScore = 3 }

        return Analysis(
            qualityHeight: detectedResolution(in: text),
            detectedLanguages: languages,
            hasLanguageData: !knownLanguages.isEmpty || hasGenericLanguageData,
            sourceScore: sourceScore,
            sizeMB: largestFileSizeMB(in: text)
        )
    }

    private static func isPreferred(
        _ lhs: Analysis,
        over rhs: Analysis,
        preference: QualityPreference,
        lhsIndex: Int,
        rhsIndex: Int
    ) -> Bool {
        let lhsRank = qualityRank(lhs.qualityHeight, preference: preference)
        let rhsRank = qualityRank(rhs.qualityHeight, preference: preference)
        if lhsRank.band != rhsRank.band { return lhsRank.band > rhsRank.band }
        if lhsRank.distance != rhsRank.distance { return lhsRank.distance < rhsRank.distance }
        if lhs.sourceScore != rhs.sourceScore { return lhs.sourceScore > rhs.sourceScore }
        if lhs.sizeMB != rhs.sizeMB { return (lhs.sizeMB ?? 0) > (rhs.sizeMB ?? 0) }
        return lhsIndex < rhsIndex
    }

    private static func qualityRank(_ height: Int?, preference: QualityPreference) -> (band: Int, distance: Int) {
        guard let height else { return (0, Int.max) }
        switch preference {
        case .manual:
            return (1, 0)
        case .automatic, .highest:
            return (1, -height)
        case .lowest:
            return (1, height)
        case .target(let target):
            if height == target { return (3, 0) }
            if height < target { return (2, target - height) }
            return (1, height - target)
        }
    }

    static func boundedMetadata(_ values: [String]) -> String {
        var remaining = maximumMetadataCharacters
        var parts: [String] = []
        for value in values.prefix(16) where remaining > 0 {
            let trimmed = String(value.prefix(remaining)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let part = String(trimmed.prefix(remaining))
            parts.append(part)
            remaining -= part.count
        }
        return parts.joined(separator: " \u{2022} ")
    }

    private static func detectedResolution(in text: String) -> Int? {
        let patterns: [(Int, String)] = [
            (2160, #"(?<![a-z0-9])(?:2160(?:p|i)?|4k|uhd)(?![a-z0-9])(?!\s*(?:mb|mib|gb|gib)\b)"#),
            (1440, #"(?<![a-z0-9])1440(?:p|i)?(?![a-z0-9])(?!\s*(?:mb|mib|gb|gib)\b)"#),
            (1080, #"(?<![a-z0-9])1080(?:p|i)?(?![a-z0-9])(?!\s*(?:mb|mib|gb|gib)\b)"#),
            (720, #"(?<![a-z0-9])720(?:p|i)?(?![a-z0-9])(?!\s*(?:mb|mib|gb|gib)\b)"#),
            (480, #"(?<![a-z0-9])480(?:p|i)?(?![a-z0-9])(?!\s*(?:mb|mib|gb|gib)\b)"#),
            (360, #"(?<![a-z0-9])360(?:p|i)?(?![a-z0-9])(?!\s*(?:mb|mib|gb|gib)\b)"#)
        ]
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for (height, pattern) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               regex.firstMatch(in: text, range: range) != nil {
                return height
            }
        }
        return nil
    }

    private static func largestFileSizeMB(in text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*(gb|gib|mb|mib)"#, options: .caseInsensitive) else { return nil }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
        return matches.compactMap { match -> Double? in
            guard let valueRange = Range(match.range(at: 1), in: text),
                  let unitRange = Range(match.range(at: 2), in: text),
                  let value = Double(text[valueRange]) else { return nil }
            return text[unitRange].lowercased().hasPrefix("g") ? value * 1_024 : value
        }
        .max()
    }

    private static func configuredLanguages(forKey key: String, defaults: UserDefaults) -> Set<String> {
        let configured = defaults.stringArray(forKey: key) ?? []
        return Set(configured.prefix(40).compactMap { configuredLanguage in
            let values = configuredLanguage.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            let tokens = Set(values)
            if let canonical = languageDefinitions.first(where: { !$0.aliases.isDisjoint(with: tokens) })?.canonical {
                return canonical
            }
            return values.first(where: { $0.count >= 3 })
        })
    }

    private static func configuredHiddenQualities(defaults: UserDefaults) -> Set<Int> {
        let supported = Set([2160, 1440, 1080, 720, 480, 360])
        let values = (defaults.array(forKey: "servicesHiddenStreamQualities") ?? []).compactMap { value -> Int? in
            if let value = value as? Int { return value }
            if let value = value as? NSNumber { return value.intValue }
            if let value = value as? String { return Int(value) }
            return nil
        }
        return Set(values.filter(supported.contains))
    }

    private static func containsPhrase(_ phrase: String, in text: String) -> Bool {
        text.range(of: #"(?<![a-z0-9])"# + NSRegularExpression.escapedPattern(for: phrase) + #"(?![a-z0-9])"#, options: .regularExpression) != nil
    }

    private static func normalizedTitle(_ value: String) -> String {
        String(value.prefix(512)).folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: #"(?i)\s*(?:-|\u{2013}|\u{2014})?\s*(?:s\d{1,3}e\d{1,4}|e\d{1,4}|episode\s+\d{1,4})$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func tokenOverlap(_ lhs: String, _ rhs: String) -> Double {
        let ignored: Set<String> = ["a", "an", "and", "the", "of", "to", "in", "on", "tv", "series", "episode"]
        let lhsTokens = Set(lhs.split(separator: " ").map(String.init).filter { $0.count > 1 && !ignored.contains($0) })
        let rhsTokens = Set(rhs.split(separator: " ").map(String.init).filter { $0.count > 1 && !ignored.contains($0) })
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return 0 }
        return Double(lhsTokens.intersection(rhsTokens).count) / Double(max(lhsTokens.count, rhsTokens.count))
    }

    private static func normalizedLevenshtein(_ lhs: String, _ rhs: String) -> Double {
        let left = Array(lhs.prefix(256))
        let right = Array(rhs.prefix(256))
        guard !left.isEmpty, !right.isEmpty else { return left == right ? 1 : 0 }
        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1] + Array(repeating: 0, count: right.count)
            for (rightIndex, rightCharacter) in right.enumerated() {
                current[rightIndex + 1] = min(
                    current[rightIndex] + 1,
                    previous[rightIndex + 1] + 1,
                    previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                )
            }
            previous = current
        }
        return 1 - Double(previous[right.count]) / Double(max(left.count, right.count))
    }

    private static let languageDefinitions: [(canonical: String, aliases: Set<String>)] = [
        ("english", ["english", "eng"]), ("japanese", ["japanese", "jpn"]),
        ("hindi", ["hindi", "hin"]), ("korean", ["korean", "kor"]),
        ("chinese", ["chinese", "mandarin", "cantonese", "zho", "chi"]),
        ("spanish", ["spanish", "spa"]), ("latino", ["latino", "latin"]),
        ("french", ["french", "fra", "fre"]), ("german", ["german", "deu", "ger"]),
        ("italian", ["italian", "ita"]), ("portuguese", ["portuguese", "por"]),
        ("russian", ["russian", "rus"]), ("arabic", ["arabic", "ara"]),
        ("tamil", ["tamil", "tam"]), ("telugu", ["telugu", "tel"]),
        ("bengali", ["bengali", "ben"]), ("malayalam", ["malayalam", "mal"]),
        ("kannada", ["kannada", "kan"]), ("marathi", ["marathi", "mar"]),
        ("turkish", ["turkish", "tur"]), ("polish", ["polish", "pol"]),
        ("dutch", ["dutch", "nld", "dut"]), ("indonesian", ["indonesian", "ind"]),
        ("thai", ["thai", "tha"]), ("vietnamese", ["vietnamese", "vie"]),
        ("ukrainian", ["ukrainian", "ukr"]), ("swedish", ["swedish", "swe"]),
        ("norwegian", ["norwegian", "nor", "nob"]), ("danish", ["danish", "dan"]),
        ("finnish", ["finnish", "fin"]), ("czech", ["czech", "ces", "cze"]),
        ("greek", ["greek", "ell", "gre"]), ("hebrew", ["hebrew", "heb"]),
        ("romanian", ["romanian", "ron", "rum"]), ("hungarian", ["hungarian", "hun"])
    ]
}

extension MacServiceStreamPolicy.QualityPreference: Equatable {}

@MainActor
final class MacStremioStore: ObservableObject {
    static let shared = MacStremioStore()

    @Published private(set) var addons: [MacStremioAddon] = []
    @Published private(set) var isInstalling = false
    @Published var lastError: String?

    private let storageKey = "macStremioAddons.v1"
    private let decoder = JSONDecoder()
    private var persistedOrder: [UUID] = []
    private var unresolvedRecords: [UUID: PersistedAddon] = [:]
    private var legacyPlaintextIDs = Set<UUID>()
    private var deletionTombstones = Set<UUID>()
    private var storageWriteBlocked = false
    private var activeServiceOperation: UUID?
    private var addonMutationRevision: UInt64 = 0

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: storageKey) {
            let state = Self.decodeStoredState(data)
            storageWriteBlocked = state.refusesOverwrite
            deletionTombstones = state.deletionTombstones
            persistedOrder = state.records.map(\.id)
            var loaded: [MacStremioAddon] = []
            var migratedLegacyURL = false

            for record in state.records {
                if let legacyURL = record.legacyBaseURL {
                    guard Self.isSupportedBaseURL(legacyURL) else {
                        unresolvedRecords[record.id] = record
                        continue
                    }
                    loaded.append(record.addon(baseURL: legacyURL))
                    legacyPlaintextIDs.insert(record.id)
                    // A legacy URL remains the source of truth until its exact value is confirmed
                    // in Keychain. Failed migration never removes the preexisting plaintext copy.
                    if !storageWriteBlocked,
                       Self.secureURL(legacyURL, addonID: record.id) {
                        legacyPlaintextIDs.remove(record.id)
                        migratedLegacyURL = true
                    }
                    continue
                }

                switch MacStremioURLKeychain.read(addonID: record.id) {
                case .success(let secureURL?):
                    guard Self.isSupportedBaseURL(secureURL) else {
                        unresolvedRecords[record.id] = record
                        continue
                    }
                    loaded.append(record.addon(baseURL: secureURL))

                case .success(nil), .failure:
                    // Preserve the metadata record if Keychain is temporarily unavailable or the
                    // item is missing. A later save must not silently delete this addon.
                    unresolvedRecords[record.id] = record
                }
            }
            addons = loaded
            if storageWriteBlocked {
                lastError = "Saved Stremio addon data could not be read safely. Eclipse preserved it and disabled addon changes."
            } else {
                let deletedCredentials = retryPendingKeychainDeletions()
                if state.needsEnvelopeMigration || migratedLegacyURL || deletedCredentials {
                    _ = persist()
                }
            }
        } else if defaults.object(forKey: storageKey) != nil {
            // An unexpected UserDefaults type is still user data. Preserve it rather than treating
            // the store as empty and replacing it on the next settings action.
            storageWriteBlocked = true
            lastError = "Saved Stremio addon data could not be read safely. Eclipse preserved it and disabled addon changes."
        }
        Task { [weak self] in await self?.refreshInstalledAddonsIfEnabled() }
    }

    func install(from enteredURL: String) async -> Bool {
        guard !storageWriteBlocked else {
            lastError = ServiceError.storageLocked.localizedDescription
            return false
        }
        guard let operationID = beginServiceOperation() else {
            lastError = ServiceError.operationInProgress.localizedDescription
            return false
        }
        let startingRevision = addonMutationRevision
        lastError = nil
        defer { finishServiceOperation(operationID) }

        do {
            let baseURL = try Self.normalizedBaseURL(enteredURL)
            let manifestURL = try Self.endpointURL(baseURL: baseURL, appending: ["manifest.json"])
            let data = try await Self.fetchBounded(url: manifestURL, maximumBytes: 1_000_000)
            let manifest = try decoder.decode(Manifest.self, from: data)
            guard !manifest.id.isEmpty, !manifest.name.isEmpty else { throw ServiceError.invalidManifest }
            guard addonMutationRevision == startingRevision else { throw ServiceError.addonStateChanged }

            let existingAddon = addons.first(where: { $0.manifestID == manifest.id })
            let existingRecord = unresolvedRecords.values.first(where: { $0.manifestID == manifest.id })
            let existingID = existingAddon?.id ?? existingRecord?.id
            let addonID = existingID ?? UUID()
            let canonicalURL = baseURL.absoluteString

            let previousKeychainURL: String?
            switch MacStremioURLKeychain.read(addonID: addonID) {
            case .success(let value): previousKeychainURL = value
            case .failure: throw ServiceError.secureStorageUnavailable
            }
            guard previousKeychainURL == canonicalURL
                    || Self.secureURL(canonicalURL, addonID: addonID) else {
                throw ServiceError.secureStorageUnavailable
            }

            let addon = MacStremioAddon(
                id: addonID,
                manifestID: manifest.id,
                name: manifest.name,
                summary: manifest.description,
                logo: manifest.logo,
                baseURL: canonicalURL,
                idPrefixes: manifest.idPrefixes ?? [],
                isActive: existingAddon?.isActive ?? existingRecord?.isActive ?? true
            )

            let oldAddons = addons
            let oldUnresolvedRecords = unresolvedRecords
            let oldLegacyPlaintextIDs = legacyPlaintextIDs
            let oldDeletionTombstones = deletionTombstones
            let oldPersistedOrder = persistedOrder
            unresolvedRecords[addon.id] = nil
            legacyPlaintextIDs.remove(addon.id)
            deletionTombstones.remove(addon.id)
            if let index = addons.firstIndex(where: { $0.id == addon.id }) {
                addons[index] = addon
            } else {
                addons.removeAll { $0.manifestID == addon.manifestID }
                addons.append(addon)
            }

            guard persist() else {
                addons = oldAddons
                unresolvedRecords = oldUnresolvedRecords
                legacyPlaintextIDs = oldLegacyPlaintextIDs
                deletionTombstones = oldDeletionTombstones
                persistedOrder = oldPersistedOrder
                Self.restoreKeychain(previousURL: previousKeychainURL, addonID: addonID)
                throw ServiceError.persistenceFailed
            }
            addonMutationRevision &+= 1
            persistSuccessfulDeletionRetries()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func setActive(_ addon: MacStremioAddon, active: Bool) {
        guard !storageWriteBlocked else {
            lastError = ServiceError.storageLocked.localizedDescription
            return
        }
        guard let index = addons.firstIndex(where: { $0.id == addon.id }) else { return }
        let previous = addons[index].isActive
        addons[index].isActive = active
        if !persist() {
            addons[index].isActive = previous
            lastError = ServiceError.persistenceFailed.localizedDescription
        } else {
            addonMutationRevision &+= 1
            persistSuccessfulDeletionRetries()
        }
    }

    func remove(_ addon: MacStremioAddon) {
        guard !storageWriteBlocked else {
            lastError = ServiceError.storageLocked.localizedDescription
            return
        }
        let oldAddons = addons
        let oldOrder = persistedOrder
        let oldUnresolvedRecords = unresolvedRecords
        let oldLegacyPlaintextIDs = legacyPlaintextIDs
        let oldTombstones = deletionTombstones

        addons.removeAll { $0.id == addon.id }
        persistedOrder.removeAll { $0 == addon.id }
        unresolvedRecords[addon.id] = nil
        legacyPlaintextIDs.remove(addon.id)
        deletionTombstones.insert(addon.id)
        guard persist() else {
            addons = oldAddons
            persistedOrder = oldOrder
            unresolvedRecords = oldUnresolvedRecords
            legacyPlaintextIDs = oldLegacyPlaintextIDs
            deletionTombstones = oldTombstones
            lastError = ServiceError.persistenceFailed.localizedDescription
            return
        }
        addonMutationRevision &+= 1

        // The tombstone reaches defaults before deletion is attempted, so a crash or Keychain
        // failure cannot turn this credential into an unreachable orphan.
        persistSuccessfulDeletionRetries()
    }

    func move(from source: IndexSet, to destination: Int) {
        guard !storageWriteBlocked else {
            lastError = ServiceError.storageLocked.localizedDescription
            return
        }
        let previous = addons
        addons.move(fromOffsets: source, toOffset: destination)
        if !persist() {
            addons = previous
            lastError = ServiceError.persistenceFailed.localizedDescription
        } else {
            addonMutationRevision &+= 1
            persistSuccessfulDeletionRetries()
        }
    }

    func refreshInstalledAddonsIfEnabled() async {
        guard UserDefaults.standard.object(forKey: "autoUpdateServicesEnabled") == nil
                || UserDefaults.standard.bool(forKey: "autoUpdateServicesEnabled") else { return }
        await updateAll()
    }

    func updateAll() async {
        guard !addons.isEmpty else { return }
        guard !storageWriteBlocked else {
            lastError = ServiceError.storageLocked.localizedDescription
            return
        }
        guard let operationID = beginServiceOperation() else {
            lastError = ServiceError.operationInProgress.localizedDescription
            return
        }
        lastError = nil
        defer { finishServiceOperation(operationID) }

        let targets = addons.map {
            (id: $0.id, manifestID: $0.manifestID, name: $0.name, baseURL: $0.baseURL)
        }
        let targetsByID = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, $0) })
        var refreshed: [UUID: Manifest] = [:]
        var failures: [String] = []
        for target in targets {
            do {
                guard let baseURL = URL(string: target.baseURL) else { throw ServiceError.invalidURL }
                let manifestURL = try Self.endpointURL(baseURL: baseURL, appending: ["manifest.json"])
                let data = try await Self.fetchBounded(url: manifestURL, maximumBytes: 1_000_000)
                let manifest = try decoder.decode(Manifest.self, from: data)
                guard manifest.id == target.manifestID, !manifest.name.isEmpty else { throw ServiceError.invalidManifest }
                refreshed[target.id] = manifest
            } catch {
                failures.append(target.name)
            }
        }

        // Merge only refreshed metadata into whatever state exists now. IDs removed while the
        // requests were running stay removed; current order, active toggles, URLs, and newly
        // installed addons remain untouched.
        let beforeMerge = addons
        for index in addons.indices {
            let current = addons[index]
            guard let target = targetsByID[current.id],
                  current.manifestID == target.manifestID,
                  current.baseURL == target.baseURL,
                  let manifest = refreshed[current.id] else { continue }
            addons[index].name = manifest.name
            addons[index].summary = manifest.description
            addons[index].logo = manifest.logo
            addons[index].idPrefixes = manifest.idPrefixes ?? []
        }
        if !persist() {
            addons = beforeMerge
            lastError = ServiceError.persistenceFailed.localizedDescription
            return
        }
        if addons != beforeMerge { addonMutationRevision &+= 1 }
        persistSuccessfulDeletionRetries()
        lastError = failures.isEmpty ? nil : "Could not update: \(failures.joined(separator: ", "))."
    }

    func streams(for item: MacMediaItem, season: Int?, episode: Int?) async throws -> [MacStremioStream] {
        let active = addons.filter(\.isActive)
        guard !active.isEmpty else { throw ServiceError.noActiveAddons }
        if item.mediaType == "tv", (season == nil || episode == nil) {
            throw ServiceError.episodeRequired
        }

        let imdbID = try? await fetchIMDbID(for: item)
        let ids = Self.contentIDs(item: item, imdbID: imdbID, season: season, episode: episode)
        let type = item.mediaType == "tv" ? "series" : "movie"

        return await withTaskGroup(of: (Int, [MacStremioStream]).self) { group in
            for (addonIndex, addon) in active.enumerated() {
                group.addTask {
                    for contentID in ids where Self.addon(addon, supports: contentID) {
                        if let streams = try? await Self.fetchStreams(addon: addon, type: type, contentID: contentID),
                           !streams.isEmpty {
                            return (addonIndex, streams)
                        }
                    }
                    return (addonIndex, [])
                }
            }

            var ordered = Array(repeating: [MacStremioStream](), count: active.count)
            for await (index, result) in group { ordered[index] = result }
            // Source order is the primary order, matching the user's installed-addon order.
            // Quality preference ranks streams within each source, so a slower addon cannot jump
            // ahead merely because its network task completed first.
            let merged = ordered.flatMap { streams in
                MacServiceStreamPolicy.apply(to: streams) { [$0.metadataText] }
            }
            var seen = Set<String>()
            return merged.filter { seen.insert($0.url.absoluteString).inserted }
        }
    }

    private func fetchIMDbID(for item: MacMediaItem) async throws -> String? {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "TMDB_API_KEY") as? String, !key.isEmpty else { return nil }
        let kind = item.mediaType == "tv" ? "tv" : "movie"
        guard let url = URL(string: "https://api.themoviedb.org/3/\(kind)/\(item.id)/external_ids?api_key=\(key)") else { return nil }
        let (data, response) = try await URLSession.shared.data(from: url)
        try Self.validate(response: response, data: data, maximumBytes: 500_000)
        return try decoder.decode(ExternalIDs.self, from: data).imdbID
    }

    @discardableResult
    private func persist() -> Bool {
        guard !storageWriteBlocked else { return false }
        synchronizePersistedOrder()

        var recordsByID = unresolvedRecords
        for addon in addons {
            // Only data that was already plaintext before the Keychain migration may remain so.
            // Fresh installs and URL changes are secured transactionally before reaching here.
            let retainedLegacyURL = legacyPlaintextIDs.contains(addon.id) ? addon.baseURL : nil
            recordsByID[addon.id] = PersistedAddon(addon: addon, legacyBaseURL: retainedLegacyURL)
        }

        let records = persistedOrder.compactMap { recordsByID[$0] }
        let envelope = PersistedEnvelope(
            version: PersistedEnvelope.currentVersion,
            addons: records,
            deletionTombstones: deletionTombstones.sorted { $0.uuidString < $1.uuidString }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(envelope) else { return false }
        UserDefaults.standard.set(data, forKey: storageKey)
        return UserDefaults.standard.data(forKey: storageKey) == data
    }

    private func synchronizePersistedOrder() {
        let loadedIDs = addons.map(\.id)
        let loadedSet = Set(loadedIDs)
        var iterator = loadedIDs.makeIterator()
        persistedOrder = persistedOrder.compactMap { id in
            loadedSet.contains(id) ? iterator.next() : id
        }
        let existing = Set(persistedOrder)
        persistedOrder.append(contentsOf: loadedIDs.filter { !existing.contains($0) })
    }

    private func beginServiceOperation() -> UUID? {
        guard activeServiceOperation == nil else { return nil }
        let id = UUID()
        activeServiceOperation = id
        isInstalling = true
        return id
    }

    private func finishServiceOperation(_ id: UUID) {
        guard activeServiceOperation == id else { return }
        activeServiceOperation = nil
        isInstalling = false
    }

    @discardableResult
    private func retryPendingKeychainDeletions() -> Bool {
        var changed = false
        for id in Array(deletionTombstones) where MacStremioURLKeychain.remove(addonID: id) {
            deletionTombstones.remove(id)
            changed = true
        }
        return changed
    }

    private func persistSuccessfulDeletionRetries() {
        // Call only after the current non-sensitive state (including tombstones) is durable.
        // If clearing the tombstones fails, the on-disk copies safely retry next launch.
        if retryPendingKeychainDeletions() { _ = persist() }
    }

    private static func normalizedBaseURL(_ value: String) throws -> URL {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("stremio://") { text = "https://" + text.dropFirst("stremio://".count) }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.fragment == nil else { throw ServiceError.invalidURL }
        components.scheme = scheme
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix("/manifest.json") {
            path.removeLast("/manifest.json".count)
        } else if path.lowercased() == "manifest.json" {
            path = ""
        }
        components.percentEncodedPath = path
        guard let url = components.url else { throw ServiceError.invalidURL }
        return url
    }

    private static func isSupportedBaseURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              components.url != nil else { return false }
        return ["http", "https"].contains(scheme) && components.fragment == nil
    }

    nonisolated private static func endpointURL(baseURL: URL, appending pathComponents: [String]) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.fragment == nil else { throw ServiceError.invalidURL }

        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/%?#\\")
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        for component in pathComponents {
            guard !component.isEmpty, component != ".", component != "..",
                  let encoded = component.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw ServiceError.invalidURL
            }
            path += "/" + encoded
        }
        components.scheme = scheme
        components.percentEncodedPath = path
        guard let url = components.url else { throw ServiceError.invalidURL }
        return url
    }

    nonisolated private static func fetchBounded(url: URL, maximumBytes: Int) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse,
              let finalScheme = http.url?.scheme?.lowercased(),
              ["http", "https"].contains(finalScheme),
              http.url?.fragment == nil,
              200..<300 ~= http.statusCode else {
            throw ServiceError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let expectedLength = http.expectedContentLength
        guard expectedLength < 0 || expectedLength <= Int64(maximumBytes) else {
            throw ServiceError.responseTooLarge
        }

        var data = Data()
        if expectedLength > 0 {
            data.reserveCapacity(min(maximumBytes, Int(expectedLength)))
        }
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw ServiceError.responseTooLarge }
            data.append(byte)
        }
        return data
    }

    private static func secureURL(_ value: String, addonID: UUID) -> Bool {
        if MacStremioURLKeychain.write(value, addonID: addonID) { return true }
        // Never infer success from an in-memory cache after a failed write. Confirm the exact
        // value from Keychain before allowing defaults to omit a legacy URL.
        if case .success(let confirmed?) = MacStremioURLKeychain.read(addonID: addonID) {
            return confirmed == value
        }
        return false
    }

    private static func restoreKeychain(previousURL: String?, addonID: UUID) {
        if let previousURL {
            _ = MacStremioURLKeychain.write(previousURL, addonID: addonID)
        } else {
            _ = MacStremioURLKeychain.remove(addonID: addonID)
        }
    }

    private static func contentIDs(item: MacMediaItem, imdbID: String?, season: Int?, episode: Int?) -> [String] {
        let suffix = item.mediaType == "tv" ? ":\(season ?? 1):\(episode ?? 1)" : ""
        return [imdbID.map { "\($0)\(suffix)" }, "tmdb:\(item.id)\(suffix)"].compactMap { $0 }
    }

    nonisolated private static func addon(_ addon: MacStremioAddon, supports contentID: String) -> Bool {
        guard !addon.idPrefixes.isEmpty else { return true }
        return addon.idPrefixes.contains { contentID.hasPrefix($0) }
    }

    nonisolated private static func fetchStreams(addon: MacStremioAddon, type: String, contentID: String) async throws -> [MacStremioStream] {
        guard let baseURL = URL(string: addon.baseURL) else { throw ServiceError.invalidURL }
        let url = try endpointURL(baseURL: baseURL, appending: ["stream", type, "\(contentID).json"])
        let data = try await fetchBounded(url: url, maximumBytes: 10_000_000)
        let decoded = try JSONDecoder().decode(StreamResponse.self, from: data)
        return decoded.streams.prefix(300).compactMap { stream in
            guard let rawURL = stream.url,
                  let url = URL(string: rawURL),
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
                  let host = components.host, !host.isEmpty,
                  components.fragment == nil else { return nil }
            let name = stream.name?.boundedNonempty(maximum: 512)
            let streamTitle = stream.title?.boundedNonempty(maximum: 512)
            let detail = stream.description?.boundedNonempty(maximum: 4_096)
            let filename = stream.behaviorHints?.filename?.boundedNonempty(maximum: 1_024)
            return MacStremioStream(
                id: "\(addon.id.uuidString):\(rawURL)",
                sourceID: "stremio:\(addon.id.uuidString)",
                addonName: addon.name,
                title: name ?? streamTitle ?? "Stream",
                detail: detail,
                url: url,
                headers: stream.behaviorHints?.proxyHeaders?.request ?? [:],
                size: stream.behaviorHints?.videoSize,
                metadataText: MacServiceStreamPolicy.boundedMetadata([name, streamTitle, detail, filename].compactMap { $0 })
            )
        }
    }

    nonisolated private static func validate(response: URLResponse, data: Data, maximumBytes: Int) throws {
        guard data.count <= maximumBytes else { throw ServiceError.responseTooLarge }
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw ServiceError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }
}

private extension MacStremioStore {
    struct PersistedEnvelope: Encodable {
        static let currentVersion = 2

        let version: Int
        let addons: [PersistedAddon]
        let deletionTombstones: [UUID]
    }

    struct DecodedStoredState {
        var records: [PersistedAddon]
        var deletionTombstones: Set<UUID>
        var needsEnvelopeMigration: Bool
        var refusesOverwrite: Bool
    }

    static func decodeStoredState(_ data: Data) -> DecodedStoredState {
        guard data.count <= 16_000_000,
              let root = try? JSONSerialization.jsonObject(with: data) else {
            return DecodedStoredState(records: [], deletionTombstones: [], needsEnvelopeMigration: false, refusesOverwrite: true)
        }

        let rawRecords: [Any]
        var tombstones = Set<UUID>()
        let needsMigration: Bool
        var refused = false

        if let legacyRecords = root as? [Any] {
            rawRecords = legacyRecords
            needsMigration = true
        } else if let envelope = root as? [String: Any],
                  let version = envelope["version"] as? NSNumber,
                  version.intValue == PersistedEnvelope.currentVersion,
                  let records = envelope["addons"] as? [Any],
                  let rawTombstones = envelope["deletionTombstones"] as? [Any] {
            rawRecords = records
            needsMigration = false
            for raw in rawTombstones {
                guard let text = raw as? String, let id = UUID(uuidString: text), tombstones.insert(id).inserted else {
                    refused = true
                    continue
                }
            }
        } else {
            // Unknown versions and malformed top-level shapes remain byte-for-byte untouched.
            return DecodedStoredState(records: [], deletionTombstones: [], needsEnvelopeMigration: false, refusesOverwrite: true)
        }

        var decoded: [PersistedAddon] = []
        var seenIDs = Set<UUID>()
        for rawRecord in rawRecords {
            guard JSONSerialization.isValidJSONObject(rawRecord),
                  let recordData = try? JSONSerialization.data(withJSONObject: rawRecord),
                  let record = try? JSONDecoder().decode(PersistedAddon.self, from: recordData),
                  seenIDs.insert(record.id).inserted else {
                refused = true
                continue
            }
            decoded.append(record)
        }

        if !tombstones.isDisjoint(with: seenIDs) {
            // An ID cannot be both installed and pending deletion. Refuse to choose which state
            // wins and preserve the original blob for a future recovery path.
            refused = true
        }
        return DecodedStoredState(
            records: decoded,
            deletionTombstones: tombstones,
            needsEnvelopeMigration: needsMigration,
            refusesOverwrite: refused
        )
    }

    /// Defaults keep only non-sensitive addon metadata. `baseURL` remains an optional coding key
    /// solely to decode and retain plaintext that already existed before Keychain migration.
    struct PersistedAddon: Codable {
        let id: UUID
        var manifestID: String
        var name: String
        var summary: String?
        var logo: String?
        var legacyBaseURL: String?
        var idPrefixes: [String]
        var isActive: Bool

        enum CodingKeys: String, CodingKey {
            case id, manifestID, name, summary, logo, idPrefixes, isActive
            case legacyBaseURL = "baseURL"
        }

        init(addon: MacStremioAddon, legacyBaseURL: String?) {
            id = addon.id
            manifestID = addon.manifestID
            name = addon.name
            summary = addon.summary
            logo = addon.logo
            self.legacyBaseURL = legacyBaseURL
            idPrefixes = addon.idPrefixes
            isActive = addon.isActive
        }

        func addon(baseURL: String) -> MacStremioAddon {
            MacStremioAddon(
                id: id,
                manifestID: manifestID,
                name: name,
                summary: summary,
                logo: logo,
                baseURL: baseURL,
                idPrefixes: idPrefixes,
                isActive: isActive
            )
        }
    }

    struct Manifest: Decodable {
        let id: String
        let name: String
        let description: String?
        let logo: String?
        let idPrefixes: [String]?
    }

    struct ExternalIDs: Decodable {
        let imdbID: String?
        enum CodingKeys: String, CodingKey { case imdbID = "imdb_id" }
    }

    struct StreamResponse: Decodable { let streams: [Stream] }
    struct Stream: Decodable {
        let url: String?
        let title: String?
        let name: String?
        let description: String?
        let behaviorHints: BehaviorHints?
    }
    struct BehaviorHints: Decodable {
        let proxyHeaders: ProxyHeaders?
        let videoSize: Int64?
        let filename: String?

        enum CodingKeys: String, CodingKey { case proxyHeaders, videoSize, filename }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            proxyHeaders = try? container.decodeIfPresent(ProxyHeaders.self, forKey: .proxyHeaders)
            filename = try? container.decodeIfPresent(String.self, forKey: .filename)
            if let value = try? container.decodeIfPresent(Int64.self, forKey: .videoSize) { videoSize = value }
            else if let value = try? container.decodeIfPresent(Double.self, forKey: .videoSize) { videoSize = Int64(value) }
            else if let value = try? container.decodeIfPresent(String.self, forKey: .videoSize) { videoSize = Int64(value) }
            else { videoSize = nil }
        }
    }
    struct ProxyHeaders: Decodable { let request: [String: String]? }

    enum ServiceError: LocalizedError {
        case invalidURL, invalidManifest, noActiveAddons, episodeRequired, responseTooLarge, http(Int)
        case operationInProgress, addonStateChanged, secureStorageUnavailable, storageLocked, persistenceFailed
        var errorDescription: String? {
            switch self {
            case .invalidURL: "Enter a valid HTTP or HTTPS Stremio manifest URL. URL fragments are not supported."
            case .invalidManifest: "The addon returned an invalid manifest."
            case .noActiveAddons: "Install and enable at least one Stremio addon in Settings."
            case .episodeRequired: "Choose a season and episode before searching for TV streams."
            case .responseTooLarge: "The addon response was too large."
            case .http(let code): "The addon returned HTTP \(code)."
            case .operationInProgress: "Another Stremio addon operation is already in progress."
            case .addonStateChanged: "The addon list changed while installation was running. Try again."
            case .secureStorageUnavailable: "The addon URL could not be saved securely in Keychain. No changes were made."
            case .storageLocked: "Saved Stremio addon data could not be read safely. Eclipse preserved it and disabled addon changes."
            case .persistenceFailed: "The Stremio addon change could not be saved. No changes were made."
            }
        }
    }
}

/// Stores complete addon endpoints outside UserDefaults because configured Stremio URLs commonly
/// embed authorization tokens in their path. No URL or credential is logged from this seam.
private enum MacStremioURLKeychain {
    enum ReadResult {
        case success(String?)
        case failure
    }

    private static let service = "app.Eclipse.Soupy.mac.stremio-addon-urls.v1"

    static func read(addonID: UUID) -> ReadResult {
        var result: CFTypeRef?
        var query = baseQuery(addonID: addonID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return .success(nil) }
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else { return .failure }
        return .success(value)
    }

    @discardableResult
    static func write(_ value: String, addonID: UUID) -> Bool {
        guard let data = value.data(using: .utf8), !data.isEmpty else { return false }
        let query = baseQuery(addonID: addonID)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var insertion = query
        insertion[kSecValueData as String] = data
        insertion[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        insertion[kSecAttrLabel as String] = "Eclipse Stremio addon URL"
        return SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func remove(addonID: UUID) -> Bool {
        let status = SecItemDelete(baseQuery(addonID: addonID) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(addonID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: addonID.uuidString
        ]
    }
}

private extension String {
    func boundedNonempty(maximum: Int) -> String? {
        let value = String(prefix(maximum)).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
