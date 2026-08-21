// Copyright 2026 Eclipse contributors
// SPDX-License-Identifier: Apache-2.0
//
// This file is an Eclipse-owned, substantially modified Swift implementation
// informed by the public interfaces in Mangayomi commit
// 4eec7aca6f1c8bd563d0bc79bcf895f46bb30b74. It contains no provider code.
// See Eclipse/Legal/ReaderExtensions/NOTICE.txt for provenance and notices.

import CryptoKit
import Foundation

struct ReaderExtensionSourceID: RawRepresentable, Codable, Hashable, Sendable, Identifiable,
    CustomStringConvertible
{
    let rawValue: String

    var id: String { rawValue }
    var description: String { rawValue }

    init(rawValue: String) {
        self.rawValue = String(rawValue.lowercased().filter { $0.isHexDigit }.prefix(64))
    }

    init(repositoryURL: URL, upstreamID: String, language: String, mediaType: ReaderExtensionMediaType) {
        let material = [
            ReaderExtensionURLCanonicalizer.canonicalString(repositoryURL),
            upstreamID.trimmingCharacters(in: .whitespacesAndNewlines),
            language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            mediaType.rawValue
        ].joined(separator: "\u{1f}")
        rawValue = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var isValid: Bool { rawValue.count == 64 && rawValue.allSatisfy(\.isHexDigit) }
}

enum ReaderExtensionMediaType: String, Codable, Hashable, Sendable, CaseIterable {
    case manga
    case novel
}

enum ReaderExtensionImplementation: String, Codable, Hashable, Sendable {
    case javascript
    case madara
    case mangaReader
    case mangaBox
    case mmrcms
    case nepNep
    case unsupportedNative

    static func catalogValue(typeSource: String, sourceCodeLanguage: ReaderExtensionCodeLanguage) -> Self {
        guard sourceCodeLanguage == .dart else {
            return sourceCodeLanguage == .javascript ? .javascript : .unsupportedNative
        }
        switch typeSource.lowercased().filter({ $0.isLetter }) {
        case "madara": return .madara
        case "mangareader": return .mangaReader
        case "mangabox": return .mangaBox
        case "mmrcms": return .mmrcms
        case "nepnep": return .nepNep
        default: return .unsupportedNative
        }
    }
}

enum ReaderExtensionCodeLanguage: String, Codable, Hashable, Sendable {
    case dart
    case javascript
    case unsupported

    init(catalogValue: Int) {
        switch catalogValue {
        case 0: self = .dart
        case 1: self = .javascript
        default: self = .unsupported
        }
    }
}

enum ReaderExtensionMaturity: String, Codable, Hashable, Sendable {
    case safe
    case mature
    case unknown
}

enum ReaderExtensionCapability: String, Codable, Hashable, Sendable {
    case popular
    case latest
    case search
    case detail
    case pages
    case chapterHTML
    case filters
    case preferences
}

enum ReaderExtensionLicenseKind: String, Codable, Hashable, Sendable {
    case apache2
    case mit
    case bsd2
    case bsd3
    case isc
    case mpl2
    case gpl3
    case restrictive
    case unknown

    var permitsInstallation: Bool {
        switch self {
        case .restrictive: return false
        default: return true
        }
    }

    var requiresUnknownLicenseOverride: Bool { self == .unknown }
}

struct ReaderExtensionLicense: Codable, Hashable, Sendable {
    var kind: ReaderExtensionLicenseKind
    var name: String
    var url: URL?
    var textSHA256: String?
    var detectedAt: Date

    static let unknown = ReaderExtensionLicense(
        kind: .unknown,
        name: "Unknown",
        url: nil,
        textSHA256: nil,
        detectedAt: .distantPast
    )

    var provenanceFingerprint: String {
        let material = [kind.rawValue, name.lowercased(), url.map(ReaderExtensionURLCanonicalizer.canonicalString) ?? "", textSHA256 ?? ""].joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct ReaderExtensionRepositoryRecord: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var indexURL: URL
    var name: String
    var websiteURL: URL?
    var license: ReaderExtensionLicense
    var addedAt: Date
    var lastRefreshedAt: Date?
    var sourceCount: Int
    var isEnabled: Bool
    var errorMessage: String?

    init(
        indexURL: URL,
        name: String = "",
        websiteURL: URL? = nil,
        license: ReaderExtensionLicense = .unknown,
        addedAt: Date = Date(),
        lastRefreshedAt: Date? = nil,
        sourceCount: Int = 0,
        isEnabled: Bool = true,
        errorMessage: String? = nil
    ) {
        let canonical = ReaderExtensionURLCanonicalizer.canonicalString(indexURL)
        id = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        self.indexURL = indexURL
        self.name = name
        self.websiteURL = websiteURL
        self.license = license
        self.addedAt = addedAt
        self.lastRefreshedAt = lastRefreshedAt
        self.sourceCount = sourceCount
        self.isEnabled = isEnabled
        self.errorMessage = errorMessage
    }

    var displayName: String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? (indexURL.host ?? indexURL.absoluteString) : value
    }
}

struct ReaderExtensionCatalogSource: Codable, Hashable, Sendable, Identifiable {
    var id: ReaderExtensionSourceID
    var upstreamID: String
    var repositoryID: String
    var repositoryURL: URL
    var name: String
    var baseURL: URL
    var apiURL: URL?
    var iconURL: URL? = nil
    var language: String
    var mediaType: ReaderExtensionMediaType
    var implementation: ReaderExtensionImplementation
    var sourceCodeURL: URL?
    var version: String
    var maturity: ReaderExtensionMaturity
    var hasCloudflare: Bool
    var dateFormat: String?
    var dateFormatLocale: String?
    var additionalParameters: String?
    var notes: String?
    var license: ReaderExtensionLicense

    var isInstallable: Bool {
        implementation != .unsupportedNative && license.kind.permitsInstallation
            && (implementation != .javascript || sourceCodeURL != nil)
    }

    var codeProvenanceFingerprint: String {
        let material = [
            ReaderExtensionURLCanonicalizer.canonicalString(repositoryURL),
            upstreamID,
            sourceCodeURL.map(ReaderExtensionURLCanonicalizer.canonicalString) ?? implementation.rawValue
        ].joined(separator: "\u{1f}")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct ReaderExtensionInstalledSource: Codable, Hashable, Sendable, Identifiable {
    var id: ReaderExtensionSourceID
    var upstreamID: String
    var repositoryID: String
    var repositoryURL: URL
    var name: String
    var baseURL: URL
    var apiURL: URL?
    var iconURL: URL? = nil
    var language: String
    /// `nil` identifies installations created before Eclipse exposed a
    /// source's language at install time. New installations record the
    /// current selection contract so compatibility repair never overrides a
    /// language the user explicitly chose.
    var languageSelectionVersion: Int?
    var mediaType: ReaderExtensionMediaType
    var implementation: ReaderExtensionImplementation
    var sourceCodeURL: URL?
    var version: String
    var maturity: ReaderExtensionMaturity
    var license: ReaderExtensionLicense
    var hasCloudflare: Bool
    var dateFormat: String?
    var dateFormatLocale: String?
    var additionalParameters: String?
    var codeProvenanceFingerprint: String
    var enabled: Bool
    var sortIndex: Int
    var installedAt: Date
    var updatedAt: Date
    var activeContentDigest: String?
    var rollbackContentDigest: String?
    var rollbackSourceSnapshot: ReaderExtensionInstalledSourceRollbackSnapshot?
    var declaredDomains: Set<String>
    var preferences: [String: ReaderExtensionPreferenceValue]
    var runtimeCapabilities: Set<ReaderExtensionCapability>
    var preferenceSchemaFingerprint: String?
    var secretPreferenceKeys: Set<String>
    var requiresReinstall: Bool
    var lastError: String?

    init(catalog: ReaderExtensionCatalogSource, sortIndex: Int) {
        id = catalog.id
        upstreamID = catalog.upstreamID
        repositoryID = catalog.repositoryID
        repositoryURL = catalog.repositoryURL
        name = catalog.name
        baseURL = catalog.baseURL
        apiURL = catalog.apiURL
        iconURL = catalog.iconURL
        language = catalog.language
        languageSelectionVersion = ReaderExtensionLanguageCompatibilityPolicy.explicitSelectionVersion
        mediaType = catalog.mediaType
        implementation = catalog.implementation
        sourceCodeURL = catalog.sourceCodeURL
        version = catalog.version
        maturity = catalog.maturity
        license = catalog.license
        hasCloudflare = catalog.hasCloudflare
        dateFormat = catalog.dateFormat
        dateFormatLocale = catalog.dateFormatLocale
        additionalParameters = catalog.additionalParameters
        codeProvenanceFingerprint = catalog.codeProvenanceFingerprint
        enabled = true
        self.sortIndex = sortIndex
        installedAt = Date()
        updatedAt = Date()
        activeContentDigest = nil
        rollbackContentDigest = nil
        rollbackSourceSnapshot = nil
        declaredDomains = ReaderExtensionSecurityPolicy.canonicalHosts(
            [catalog.baseURL.host, catalog.apiURL?.host, catalog.sourceCodeURL?.host].compactMap { $0 }
        )
        preferences = [:]
        runtimeCapabilities = []
        preferenceSchemaFingerprint = nil
        secretPreferenceKeys = []
        requiresReinstall = false
        lastError = nil
    }

    var isRunnable: Bool {
        enabled && !requiresReinstall && implementation != .unsupportedNative
            && license.kind.permitsInstallation
            && (implementation != .javascript || activeContentDigest != nil)
    }

    func metadataForBackup() -> Self {
        var copy = self
        let sanitizedSecretKeys = Set(copy.secretPreferenceKeys.sorted().filter {
            (try? ReaderExtensionSecurityPolicy.validatePreferenceSecret(key: $0, value: nil)) != nil
        }.prefix(ReaderExtensionSecurityPolicy.maximumPreferenceCount))
        copy.activeContentDigest = nil
        copy.rollbackContentDigest = nil
        copy.rollbackSourceSnapshot = nil
        copy.declaredDomains = []
        copy.license.url = ReaderExtensionSecurityPolicy.sanitizedMetadataDisplayURL(copy.license.url)
        // Backup metadata cannot prove the license/owner/domain assertions of
        // either JavaScript or a native parser source. Every restored source is
        // inert until its repository is fetched again and Manager update policy
        // revalidates the current catalog entry.
        copy.requiresReinstall = true
        copy.lastError = nil
        copy.preferences = copy.preferences.filter { key, value in
            !value.isSecret
                && !sanitizedSecretKeys.contains(key)
                && !ReaderExtensionSecurityPolicy.isCredentialLikePreferenceKey(key)
                && (try? ReaderExtensionSecurityPolicy.validatePreference(key: key, value: value)) != nil
        }
        // Key names describe the validated preference schema; they are not
        // credentials. Retaining this bounded set prevents an exact-byte
        // reinstall from looking like newly expanded secret access, while all
        // corresponding values remain device-only in Keychain.
        copy.secretPreferenceKeys = sanitizedSecretKeys
        return copy
    }
}

/// The complete metadata that was paired with the one retained last-known-good
/// JavaScript digest. This is deliberately non-recursive: Eclipse retains one
/// prior version, and an untrusted persisted value cannot create an arbitrarily
/// deep chain of historical source records.
struct ReaderExtensionInstalledSourceRollbackSnapshot: Codable, Hashable, Sendable {
    var id: ReaderExtensionSourceID
    var upstreamID: String
    var repositoryID: String
    var repositoryURL: URL
    var name: String
    var baseURL: URL
    var apiURL: URL?
    var iconURL: URL? = nil
    var language: String
    var languageSelectionVersion: Int?
    var mediaType: ReaderExtensionMediaType
    var implementation: ReaderExtensionImplementation
    var sourceCodeURL: URL?
    var version: String
    var maturity: ReaderExtensionMaturity
    var license: ReaderExtensionLicense
    var hasCloudflare: Bool
    var dateFormat: String?
    var dateFormatLocale: String?
    var additionalParameters: String?
    var codeProvenanceFingerprint: String
    var enabled: Bool
    var sortIndex: Int
    var installedAt: Date
    var updatedAt: Date
    var activeContentDigest: String
    var declaredDomains: Set<String>
    var preferences: [String: ReaderExtensionPreferenceValue]
    var runtimeCapabilities: Set<ReaderExtensionCapability>
    var preferenceSchemaFingerprint: String?
    var secretPreferenceKeys: Set<String>
    var requiresReinstall: Bool
    var lastError: String?

    init?(source: ReaderExtensionInstalledSource) {
        guard let digest = source.activeContentDigest,
              digest.count == 64,
              digest.allSatisfy(\.isHexDigit) else { return nil }
        id = source.id
        upstreamID = source.upstreamID
        repositoryID = source.repositoryID
        repositoryURL = source.repositoryURL
        name = source.name
        baseURL = source.baseURL
        apiURL = source.apiURL
        iconURL = source.iconURL
        language = source.language
        languageSelectionVersion = source.languageSelectionVersion
        mediaType = source.mediaType
        implementation = source.implementation
        sourceCodeURL = source.sourceCodeURL
        version = source.version
        maturity = source.maturity
        license = source.license
        hasCloudflare = source.hasCloudflare
        dateFormat = source.dateFormat
        dateFormatLocale = source.dateFormatLocale
        additionalParameters = source.additionalParameters
        codeProvenanceFingerprint = source.codeProvenanceFingerprint
        enabled = source.enabled
        sortIndex = source.sortIndex
        installedAt = source.installedAt
        updatedAt = source.updatedAt
        activeContentDigest = digest.lowercased()
        declaredDomains = source.declaredDomains
        // Preferences are profile-owned overlay data, not executable-version
        // metadata. Keeping them in a shared LKG snapshot would leak one
        // profile's choices into the installed-software store; rollback merges
        // the current profile's validated values instead.
        preferences = [:]
        runtimeCapabilities = source.runtimeCapabilities
        preferenceSchemaFingerprint = source.preferenceSchemaFingerprint
        secretPreferenceKeys = source.secretPreferenceKeys
        requiresReinstall = source.requiresReinstall
        lastError = source.lastError
    }

    func installedSource() -> ReaderExtensionInstalledSource {
        let catalog = ReaderExtensionCatalogSource(
            id: id,
            upstreamID: upstreamID,
            repositoryID: repositoryID,
            repositoryURL: repositoryURL,
            name: name,
            baseURL: baseURL,
            apiURL: apiURL,
            iconURL: iconURL,
            language: language,
            mediaType: mediaType,
            implementation: implementation,
            sourceCodeURL: sourceCodeURL,
            version: version,
            maturity: maturity,
            hasCloudflare: hasCloudflare,
            dateFormat: dateFormat,
            dateFormatLocale: dateFormatLocale,
            additionalParameters: additionalParameters,
            notes: nil,
            license: license
        )
        var source = ReaderExtensionInstalledSource(catalog: catalog, sortIndex: sortIndex)
        source.codeProvenanceFingerprint = codeProvenanceFingerprint
        source.languageSelectionVersion = languageSelectionVersion
        source.enabled = enabled
        source.installedAt = installedAt
        source.updatedAt = updatedAt
        source.activeContentDigest = activeContentDigest
        source.rollbackContentDigest = nil
        source.rollbackSourceSnapshot = nil
        source.declaredDomains = declaredDomains
        source.preferences = preferences
        source.runtimeCapabilities = runtimeCapabilities
        source.preferenceSchemaFingerprint = preferenceSchemaFingerprint
        source.secretPreferenceKeys = secretPreferenceKeys
        source.requiresReinstall = requiresReinstall
        source.lastError = lastError
        return source
    }
}

extension ReaderExtensionInstalledSource {
    @discardableResult
    mutating func removeAuthenticationPreferenceMetadata() -> Bool {
        let previous = preferences
        preferences = preferences.filter { key, value in
            !value.isSecret
                && !secretPreferenceKeys.contains(key)
                && !ReaderExtensionSecurityPolicy.isCredentialLikePreferenceKey(key)
        }
        return preferences != previous
    }

    func restoringLastKnownGood(afterFailureOf failedDigest: String?) -> Self? {
        guard activeContentDigest == failedDigest,
              let snapshot = rollbackSourceSnapshot,
              snapshot.activeContentDigest != failedDigest else { return nil }
        var restored = snapshot.installedSource()
        // Enablement, order, and preferences belong to the user, not to an
        // executable version. Roll back only code-coupled metadata. Preference
        // values are revalidated against the restored secret boundary so an
        // update cannot leave a newly ordinary plaintext credential visible to
        // the older runtime.
        restored.enabled = enabled
        restored.sortIndex = sortIndex
        var retainedPreferences: [String: ReaderExtensionPreferenceValue] = [:]
        for (key, value) in preferences.sorted(by: { $0.key < $1.key })
            .prefix(ReaderExtensionSecurityPolicy.maximumPreferenceCount) {
            let mustRemainSecret = restored.secretPreferenceKeys.contains(key)
                || ReaderExtensionSecurityPolicy.isCredentialLikePreferenceKey(key)
            if mustRemainSecret {
                guard (try? ReaderExtensionSecurityPolicy.validatePreferenceSecret(key: key, value: nil)) != nil else {
                    continue
                }
                retainedPreferences[key] = .secretReference(key)
            } else if value.isSecret {
                // A secret declared only by the failed schema stays in
                // Keychain, but the older schema cannot request it.
                continue
            } else if (try? ReaderExtensionSecurityPolicy.validatePreference(key: key, value: value)) != nil {
                retainedPreferences[key] = value
            }
        }
        restored.preferences = retainedPreferences
        restored.lastError = "The latest source version was rolled back after a runtime integrity failure."
        return restored
    }
}

struct ReaderExtensionBackupSnapshot: Codable, Hashable, Sendable {
    var repositories: [ReaderExtensionRepositoryRecord]
    var installedSources: [ReaderExtensionInstalledSource]
    var showMatureSources: Bool
    var autoUpdateSources: Bool
    var lastAutoUpdate: Date?
}

struct ReaderExtensionPrivateCloudKeychainConfiguration: Codable, Hashable, Sendable {
    var secrets: [String: String]
    var userApprovedDomains: [String]

    static let empty = ReaderExtensionPrivateCloudKeychainConfiguration(
        secrets: [:],
        userApprovedDomains: []
    )
}

struct ReaderExtensionPrivateCloudSourceConfiguration: Codable, Hashable, Sendable, Identifiable {
    var id: ReaderExtensionSourceID { sourceID }
    var sourceID: ReaderExtensionSourceID
    var upstreamID: String
    var repositoryID: String
    var repositoryURL: String
    var language: String
    var mediaType: ReaderExtensionMediaType
    var implementation: ReaderExtensionImplementation
    var codeProvenanceFingerprint: String
    var preferenceSchemaFingerprint: String?
    var ordinaryPreferences: [String: ReaderExtensionPreferenceValue]
    var keychain: ReaderExtensionPrivateCloudKeychainConfiguration

    init(
        source: ReaderExtensionInstalledSource,
        ordinaryPreferences: [String: ReaderExtensionPreferenceValue],
        keychain: ReaderExtensionPrivateCloudKeychainConfiguration
    ) {
        sourceID = source.id
        upstreamID = source.upstreamID
        repositoryID = source.repositoryID
        repositoryURL = ReaderExtensionURLCanonicalizer.canonicalString(source.repositoryURL)
        language = source.language.lowercased()
        mediaType = source.mediaType
        implementation = source.implementation
        codeProvenanceFingerprint = source.codeProvenanceFingerprint.lowercased()
        preferenceSchemaFingerprint = source.preferenceSchemaFingerprint?.lowercased()
        self.ordinaryPreferences = ordinaryPreferences
        self.keychain = keychain
    }
}

struct ReaderExtensionPrivateCloudConfiguration: Codable, Hashable, Sendable {
    var schemaVersion: Int
    var profileID: UUID
    var configurationIsComplete: Bool
    var sources: [ReaderExtensionPrivateCloudSourceConfiguration]

    init(
        profileID: UUID,
        sources: [ReaderExtensionPrivateCloudSourceConfiguration],
        configurationIsComplete: Bool = true
    ) {
        schemaVersion = 1
        self.profileID = profileID
        self.configurationIsComplete = configurationIsComplete
        self.sources = sources
    }
}

enum ReaderExtensionPrivateCloudConfigurationPolicy {
    static let maximumPayloadBytes = 8 * 1_024 * 1_024
    static let maximumApprovedDomainCount = 64

    static func validate(
        _ configuration: ReaderExtensionPrivateCloudConfiguration
    ) throws {
        guard configuration.schemaVersion == 1,
              configuration.configurationIsComplete,
              configuration.sources.count <= ReaderExtensionPersistence.maximumInstalledSourceCount,
              Set(configuration.sources.map(\.sourceID)).count == configuration.sources.count else {
            throw ReaderExtensionError.persistenceFailed("Reader private-cloud configuration is incomplete")
        }
        for source in configuration.sources {
            try validate(source)
        }
        guard try JSONEncoder().encode(configuration).count <= maximumPayloadBytes else {
            throw ReaderExtensionError.contentTooLarge
        }
    }

    static func validate(
        _ configuration: ReaderExtensionPrivateCloudSourceConfiguration
    ) throws {
        guard configuration.sourceID.isValid,
              !configuration.upstreamID.isEmpty,
              configuration.upstreamID.utf8.count <= 128,
              !configuration.repositoryID.isEmpty,
              configuration.repositoryID.utf8.count <= 128,
              configuration.repositoryURL.utf8.count <= 16 * 1_024,
              configuration.language.utf8.count <= 64,
              configuration.codeProvenanceFingerprint.count == 64,
              configuration.codeProvenanceFingerprint.allSatisfy(\.isHexDigit),
              configuration.preferenceSchemaFingerprint.map({
                  $0.count == 64 && $0.allSatisfy(\.isHexDigit)
              }) ?? true,
              configuration.ordinaryPreferences.count
                <= ReaderExtensionSecurityPolicy.maximumPreferenceCount,
              configuration.keychain.secrets.count
                <= ReaderExtensionSecurityPolicy.maximumPreferenceCount,
              configuration.keychain.userApprovedDomains.count
                <= maximumApprovedDomainCount,
              Set(configuration.ordinaryPreferences.keys)
                .isDisjoint(with: configuration.keychain.secrets.keys) else {
            throw ReaderExtensionError.contentTooLarge
        }
        guard let repositoryURL = URL(string: configuration.repositoryURL),
              ReaderExtensionURLCanonicalizer.canonicalString(repositoryURL)
                == configuration.repositoryURL,
              (try? ReaderExtensionSecurityPolicy.validateRepositoryURLSyntax(repositoryURL)) != nil else {
            throw ReaderExtensionError.insecureURL
        }
        for (key, value) in configuration.ordinaryPreferences {
            guard !ReaderExtensionSecurityPolicy.isCredentialLikePreferenceKey(key) else {
                throw ReaderExtensionError.persistenceFailed("Reader credential preference used ordinary storage")
            }
            try ReaderExtensionSecurityPolicy.validatePreference(key: key, value: value)
        }
        for (key, value) in configuration.keychain.secrets {
            try ReaderExtensionSecurityPolicy.validatePreferenceSecret(key: key, value: value)
        }
        let domains = Set(configuration.keychain.userApprovedDomains)
        let canonicalDomains = ReaderExtensionSecurityPolicy.canonicalHosts(domains)
        guard domains.count == configuration.keychain.userApprovedDomains.count,
              canonicalDomains == domains,
              configuration.keychain.userApprovedDomains == domains.sorted() else {
            throw ReaderExtensionError.insecureURL
        }
    }

    static func identityMatches(
        _ incoming: ReaderExtensionPrivateCloudSourceConfiguration,
        source: ReaderExtensionInstalledSource
    ) -> Bool {
        incoming.sourceID == source.id
            && incoming.upstreamID == source.upstreamID
            && incoming.repositoryID == source.repositoryID
            && incoming.repositoryURL
                == ReaderExtensionURLCanonicalizer.canonicalString(source.repositoryURL)
            && incoming.language == source.language.lowercased()
            && incoming.mediaType == source.mediaType
            && incoming.implementation == source.implementation
            && incoming.codeProvenanceFingerprint
                == source.codeProvenanceFingerprint.lowercased()
            && incoming.preferenceSchemaFingerprint
                == source.preferenceSchemaFingerprint?.lowercased()
    }
}

enum ReaderExtensionPublicationStatus: String, Codable, Hashable, Sendable {
    case ongoing
    case completed
    case hiatus
    case cancelled
    case finished
    case unknown
}

struct ReaderExtensionItem: Codable, Hashable, Sendable, Identifiable {
    var id: String { key }
    var key: String
    var title: String
    var url: URL?
    var coverURL: URL?
    var description: String?
    var author: String?
    var artist: String?
    var status: ReaderExtensionPublicationStatus
    var tags: [String]
    var maturity: ReaderExtensionMaturity

    init(
        key: String,
        title: String,
        url: URL? = nil,
        coverURL: URL? = nil,
        description: String? = nil,
        author: String? = nil,
        artist: String? = nil,
        status: ReaderExtensionPublicationStatus = .unknown,
        tags: [String] = [],
        maturity: ReaderExtensionMaturity = .unknown
    ) {
        self.key = key
        self.title = title
        self.url = url
        self.coverURL = coverURL
        self.description = description
        self.author = author
        self.artist = artist
        self.status = status
        self.tags = tags
        self.maturity = maturity
    }

    func merging(seed: ReaderExtensionItem?) -> ReaderExtensionItem {
        guard let seed else { return self }
        var result = self
        if result.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || result.title == result.key {
            result.title = seed.title
        }
        result.url = result.url ?? seed.url
        result.coverURL = result.coverURL ?? seed.coverURL
        result.description = result.description ?? seed.description
        result.author = result.author ?? seed.author
        result.artist = result.artist ?? seed.artist
        if result.status == .unknown { result.status = seed.status }
        if result.tags.isEmpty { result.tags = seed.tags }
        if result.maturity == .unknown { result.maturity = seed.maturity }
        return result
    }
}

struct ReaderExtensionChapter: Codable, Hashable, Sendable, Identifiable {
    var id: String { key }
    var key: String
    var title: String
    var url: URL?
    var uploadedAt: Date?
    var scanlator: String?
    var isFiller: Bool
    var thumbnailURL: URL?
    var summary: String?
}

enum ReaderExtensionSafeMetadata {
    static func sanitizedURL(_ url: URL?) -> URL? {
        guard let url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil else { return nil }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func sanitizedURLString(_ url: URL?) -> String? {
        sanitizedURL(url)?.absoluteString
    }

    /// Returns only a metadata-safe provider URL. The saved fallback is
    /// sanitized again because it may have been written by an older build
    /// before Reader Extension cover redaction was enforced everywhere.
    static func sanitizedURLString(_ url: URL?, fallback: String?) -> String? {
        if let primary = sanitizedURLString(url) { return primary }
        guard let fallback, let fallbackURL = URL(string: fallback) else { return nil }
        return sanitizedURLString(fallbackURL)
    }

    static func opaqueKey(_ value: String) -> String {
        "opaque:" + SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct ReaderExtensionPage: Codable, Hashable, Sendable, Identifiable {
    var id: String { key }
    var key: String
    var url: URL
    var headers: [String: String]
    /// Full provider request material exists only for the current process and
    /// is intentionally excluded from CodingKeys. The manager moves it into
    /// its profile-scoped opaque request registry before any network dispatch.
    private(set) var transientRequestHeaders: [String: String]

    init(key: String, url: URL, headers: [String: String] = [:]) {
        self.key = key
        self.url = url
        self.headers = Self.safeMetadataHeaders(headers)
        transientRequestHeaders = Self.boundedTransientHeaders(headers)
    }

    private enum CodingKeys: String, CodingKey { case key, url, headers }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        key = try box.decode(String.self, forKey: .key)
        url = try box.decode(URL.self, forKey: .url)
        headers = Self.safeMetadataHeaders(try box.decodeIfPresent([String: String].self, forKey: .headers) ?? [:])
        transientRequestHeaders = headers
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(ReaderExtensionSafeMetadata.opaqueKey(key), forKey: .key)
        guard let safeURL = ReaderExtensionSafeMetadata.sanitizedURL(url) else {
            throw EncodingError.invalidValue(url, EncodingError.Context(
                codingPath: encoder.codingPath,
                debugDescription: "Reader page URL was not safe metadata"
            ))
        }
        try box.encode(safeURL, forKey: .url)
        try box.encode(Self.safeMetadataHeaders(headers), forKey: .headers)
    }

    private static func safeMetadataHeaders(_ input: [String: String]) -> [String: String] {
        let allowed: Set<String> = [
            "accept", "accept-language", "cache-control", "if-modified-since",
            "if-none-match", "range", "referer", "user-agent"
        ]
        var output: [String: String] = [:]
        for (name, rawValue) in input.prefix(64) {
            let lower = name.lowercased()
            guard allowed.contains(lower) else { continue }
            var value = String(rawValue.prefix(8 * 1_024))
            guard !value.contains("\r"), !value.contains("\n") else { continue }
            let loweredValue = value.lowercased()
            guard !loweredValue.contains("bearer "), !loweredValue.contains("basic ") else { continue }
            if lower == "referer" {
                guard let url = URL(string: value),
                      let safeValue = ReaderExtensionSafeMetadata.sanitizedURLString(url) else { continue }
                value = safeValue
            }
            output[name] = value
        }
        return output
    }

    private static func boundedTransientHeaders(_ input: [String: String]) -> [String: String] {
        var output: [String: String] = [:]
        var totalBytes = 0
        for (name, value) in input.prefix(64) {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty,
                  !trimmedName.contains(":"),
                  !trimmedName.contains("\r"),
                  !trimmedName.contains("\n"),
                  !value.contains("\r"),
                  !value.contains("\n") else { continue }
            let boundedValue = String(value.prefix(8 * 1_024))
            let addedBytes = trimmedName.utf8.count + boundedValue.utf8.count
            guard totalBytes + addedBytes <= 32 * 1_024 else { break }
            totalBytes += addedBytes
            output[trimmedName] = boundedValue
        }
        return output
    }
}

/// An opaque, process-local handle for one remote page. The URL and request
/// headers deliberately stay in `ReaderExtensionManager`; reader views and
/// download metadata never receive cookies, authorization values, or signed
/// page URLs.
struct ReaderExtensionPageResource: Hashable, Sendable {
    let requestID: UUID
    let sourceID: ReaderExtensionSourceID
    let key: String
}

extension Notification.Name {
    static let readerExtensionAuthenticationDidChange = Notification.Name(
        "Eclipse.ReaderExtensions.AuthenticationDidChange"
    )
}

struct ReaderExtensionPagedResult: Codable, Hashable, Sendable {
    var items: [ReaderExtensionItem]
    var hasNextPage: Bool
}

struct ReaderExtensionPageResult: Codable, Hashable, Sendable {
    var pages: [ReaderExtensionPage]
    var chapterHTML: String?
}

enum ReaderExtensionFilterKind: String, Codable, Hashable, Sendable {
    case text
    case toggle
    case select
    case triState
    case sort
    case group
    case header
    case separator
}

struct ReaderExtensionFilterOption: Codable, Hashable, Sendable, Identifiable {
    var id: String { value }
    var label: String
    var value: String
    var abiType: String?
    var abiTypeName: String?
    /// Provider-defined option fields Eclipse does not model. Comix's Sort
    /// options carry the query key in `param` and read it back in search();
    /// dropping unknown keys turned its entire sort control into
    /// `undefined=desc`. Options are data, so anything declared is echoed
    /// back verbatim rather than filtered to a known set.
    var abiExtras: [String: ReaderExtensionJSONValue]?

    init(
        label: String,
        value: String,
        abiType: String? = nil,
        abiTypeName: String? = nil,
        abiExtras: [String: ReaderExtensionJSONValue]? = nil
    ) {
        self.label = label
        self.value = value
        self.abiType = abiType
        self.abiTypeName = abiTypeName
        self.abiExtras = abiExtras
    }
}

/// A bounded JSON value retained only to round-trip extension ABI metadata.
/// It deliberately remains provider-neutral and never carries executable code.
enum ReaderExtensionJSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([ReaderExtensionJSONValue])
    case object([String: ReaderExtensionJSONValue])

    init?(foundationObject value: Any, depth: Int = 0) {
        guard depth < 8 else { return nil }
        switch value {
        case is NSNull:
            self = .null
        case let value as NSNumber where CFGetTypeID(value) == CFBooleanGetTypeID():
            self = .bool(value.boolValue)
        case let value as NSNumber where value.doubleValue.isFinite:
            // Foundation bridges JSON 0 and 1 through NSNumber, and `as Bool`
            // also succeeds for those values. CFBoolean identity is the only
            // reliable distinction; select indices must remain numbers.
            self = .number(value.doubleValue)
        case let value as String:
            self = .string(String(value.prefix(64 * 1_024)))
        case let values as [Any]:
            self = .array(values.prefix(200).compactMap {
                ReaderExtensionJSONValue(foundationObject: $0, depth: depth + 1)
            })
        case let values as [String: Any]:
            self = .object(Dictionary(uniqueKeysWithValues: values.prefix(200).compactMap { key, value in
                guard key.utf8.count <= 256,
                      let converted = ReaderExtensionJSONValue(foundationObject: value, depth: depth + 1) else {
                    return nil
                }
                return (key, converted)
            }))
        default:
            return nil
        }
    }

    var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(\.foundationObject)
        case .object(let values): return values.mapValues(\.foundationObject)
        }
    }
}

struct ReaderExtensionFilter: Codable, Hashable, Sendable, Identifiable {
    var id: String { key }
    var key: String
    var abiType: String?
    var abiTypeName: String?
    var abiState: ReaderExtensionJSONValue?
    var abiValue: ReaderExtensionJSONValue?
    var abiChildrenKey: String?
    var title: String
    var kind: ReaderExtensionFilterKind
    var options: [ReaderExtensionFilterOption]
    var value: ReaderExtensionPreferenceValue
    /// Mangayomi models sort direction separately from the selected option.
    /// `nil` is used by every non-sort filter; sort filters always normalize
    /// to a concrete value while parsing the provider schema.
    var sortAscending: Bool?
    /// Authoritative selection for select/sort filters. Mangayomi identifies
    /// the choice positionally (`filter.values[filter.state]`) and option
    /// values are not required to be unique — Comix declares nine sort
    /// options sharing two value strings. Matching by value therefore
    /// collapsed seven distinct sorts onto two. `value` is retained for
    /// display and for native families that key off the option string.
    var selectedOptionIndex: Int?
    var children: [ReaderExtensionFilter]

    init(
        key: String,
        title: String,
        kind: ReaderExtensionFilterKind,
        options: [ReaderExtensionFilterOption],
        value: ReaderExtensionPreferenceValue,
        abiType: String? = nil,
        abiTypeName: String? = nil,
        abiState: ReaderExtensionJSONValue? = nil,
        abiValue: ReaderExtensionJSONValue? = nil,
        abiChildrenKey: String? = nil,
        sortAscending: Bool? = nil,
        selectedOptionIndex: Int? = nil,
        children: [ReaderExtensionFilter] = []
    ) {
        self.key = key
        self.abiType = abiType
        self.abiTypeName = abiTypeName
        self.abiState = abiState
        self.abiValue = abiValue
        self.abiChildrenKey = abiChildrenKey
        self.title = title
        self.kind = kind
        self.options = options
        self.value = value
        self.sortAscending = sortAscending
        self.selectedOptionIndex = selectedOptionIndex
        self.children = children
    }

    /// Resolves the chosen option, preferring the positional selection and
    /// falling back to a value match for filters built before an index was
    /// recorded.
    var resolvedOptionIndex: Int? {
        if let selectedOptionIndex, options.indices.contains(selectedOptionIndex) {
            return selectedOptionIndex
        }
        switch value {
        case .string(let selected):
            return options.firstIndex { $0.value == selected }
        case .number(let selected):
            guard let index = Int(exactly: selected) else { return nil }
            return options.indices.contains(index) ? index : nil
        default:
            return nil
        }
    }
}

enum ReaderExtensionPreferenceKind: String, Codable, Hashable, Sendable {
    case header
    case toggle
    case select
    case text
    case secret
}

struct ReaderExtensionPreference: Codable, Hashable, Sendable, Identifiable {
    var id: String { key }
    var key: String
    var title: String
    var summary: String?
    var kind: ReaderExtensionPreferenceKind
    var options: [ReaderExtensionFilterOption]
    var defaultValue: ReaderExtensionPreferenceValue
    var dialogTitle: String? = nil
    var dialogMessage: String? = nil
    var inputHint: String? = nil
}

enum ReaderExtensionPreferenceValue: Codable, Hashable, Sendable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case stringList([String])
    case secretReference(String)

    private enum CodingKeys: String, CodingKey { case type, string, bool, number, list }
    private enum ValueType: String, Codable { case string, bool, number, stringList, secretReference }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        switch try box.decode(ValueType.self, forKey: .type) {
        case .string: self = .string(try box.decode(String.self, forKey: .string))
        case .bool: self = .bool(try box.decode(Bool.self, forKey: .bool))
        case .number: self = .number(try box.decode(Double.self, forKey: .number))
        case .stringList: self = .stringList(try box.decode([String].self, forKey: .list))
        case .secretReference: self = .secretReference(try box.decode(String.self, forKey: .string))
        }
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .string(let value):
            try box.encode(ValueType.string, forKey: .type); try box.encode(value, forKey: .string)
        case .bool(let value):
            try box.encode(ValueType.bool, forKey: .type); try box.encode(value, forKey: .bool)
        case .number(let value):
            try box.encode(ValueType.number, forKey: .type); try box.encode(value, forKey: .number)
        case .stringList(let value):
            try box.encode(ValueType.stringList, forKey: .type); try box.encode(value, forKey: .list)
        case .secretReference(let value):
            try box.encode(ValueType.secretReference, forKey: .type); try box.encode(value, forKey: .string)
        }
    }

    var isSecret: Bool {
        if case .secretReference = self { return true }
        return false
    }

    var jsonObject: Any {
        switch self {
        case .string(let value), .secretReference(let value): return value
        case .bool(let value): return value
        case .number(let value): return value
        case .stringList(let value): return value
        }
    }
}

enum ReaderExtensionError: LocalizedError, Equatable {
    case invalidRepositoryURL
    case invalidManifest(String)
    case sourceNotFound
    case unsupportedSource
    case restrictiveLicense(String)
    case unknownLicenseNeedsConsent
    case updateConsentRequired(String)
    case insecureURL
    case privateNetworkDestination
    case domainConsentRequired(String)
    case contentTooLarge
    case unsupportedArchive
    case invalidScriptEncoding
    case prohibitedScriptConstruct(String)
    case runtimeUnavailable
    case runtimeTimedOut
    case sourceQuarantined
    case runtimeIntegrityFailed(String)
    case runtimeFailed(String)
    case resultInvalid(String)
    case persistenceFailed(String)
    case browserVerificationRequired(String)

    var errorDescription: String? {
        switch self {
        case .invalidRepositoryURL: return "Reader extension repositories must use a direct HTTPS index URL."
        case .invalidManifest(let reason): return "Invalid reader extension repository: \(reason)"
        case .sourceNotFound: return "The reader extension source is no longer present in its repository."
        case .unsupportedSource: return "This source requires an Eclipse update."
        case .restrictiveLicense(let name): return "The source license (\(name)) does not permit installation."
        case .unknownLicenseNeedsConsent: return "The source license could not be verified. Explicit consent is required."
        case .updateConsentRequired(let reason): return "This update needs your approval because it changes \(reason)."
        case .insecureURL: return "Only secure public HTTPS destinations are allowed."
        case .privateNetworkDestination: return "Reader extensions cannot access local or private networks."
        case .domainConsentRequired(let domain): return "This source needs permission to contact \(domain)."
        case .contentTooLarge: return "The reader extension response exceeded Eclipse's safety limit."
        case .unsupportedArchive: return "Downloaded ebook and archive files are not supported."
        case .invalidScriptEncoding: return "The extension script is not valid UTF-8 JavaScript."
        case .prohibitedScriptConstruct(let construct): return "The extension uses prohibited dynamic code: \(construct)."
        case .runtimeUnavailable: return "The reader extension runtime is unavailable. If relaunching Eclipse does not restore it, reader storage needs repair."
        case .runtimeTimedOut: return "The reader extension took too long and was stopped."
        case .sourceQuarantined: return "This reader extension version was quarantined after a runtime failure."
        case .runtimeIntegrityFailed(let phase): return "Reader extension integrity check failed during \(phase)."
        case .runtimeFailed(let message): return "Reader extension failed: \(message)"
        case .resultInvalid(let message): return "Reader extension returned invalid data: \(message)"
        case .persistenceFailed(let message): return "Reader extension state could not be saved: \(message)"
        case .browserVerificationRequired(let host): return "\(host) is asking for a browser verification check."
        }
    }
}

enum ReaderExtensionSourceUpdateConsentPolicy {
    static let unknownLicenseReason = "the source license could not be verified"

    static func reason(for error: ReaderExtensionError) -> String? {
        switch error {
        case .updateConsentRequired(let reason): return reason
        case .unknownLicenseNeedsConsent: return unknownLicenseReason
        case .domainConsentRequired(let domain): return "network access to \(domain)"
        default: return nil
        }
    }
}

enum ReaderExtensionMetadataReacquisitionPolicy {
    static func needsCodeReacquisition(
        _ source: ReaderExtensionInstalledSource,
        blockedSourceIDs: Set<ReaderExtensionSourceID>
    ) -> Bool {
        guard !blockedSourceIDs.contains(source.id),
              source.implementation != .unsupportedNative,
              source.license.kind.permitsInstallation else { return false }
        return source.requiresReinstall
            || (source.implementation == .javascript && source.activeContentDigest == nil)
    }

    static func fetchAuthorizedDomains(
        allowScopeExpansion: Bool,
        reacquiresMetadataOnlyInstall: Bool,
        catalogInstallationDomains: Set<String>,
        currentInstallationDomains: Set<String>,
        runtimeAuthorizedDomains: () -> Set<String>
    ) -> Set<String> {
        if allowScopeExpansion { return catalogInstallationDomains }
        if reacquiresMetadataOnlyInstall,
           catalogInstallationDomains.isSubset(of: currentInstallationDomains) {
            return catalogInstallationDomains
        }
        return runtimeAuthorizedDomains()
    }

    static func allowsUnknownLicense(
        allowScopeExpansion: Bool,
        currentLicenseKind: ReaderExtensionLicenseKind
    ) -> Bool {
        allowScopeExpansion || currentLicenseKind == .unknown
    }
}

enum ReaderExtensionLanguageInfo {
    static func canonicalCode(_ rawValue: String) -> String {
        rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    static func displayName(_ rawValue: String, locale: Locale = .current) -> String {
        let code = canonicalCode(rawValue)
        guard !code.isEmpty else { return "Unknown" }
        if code == "all" || code == "multi" { return "Multilingual" }
        let base = code.split(separator: "-").first.map(String.init) ?? code
        let language = locale.localizedString(forLanguageCode: base)
            ?? Locale(identifier: "en").localizedString(forLanguageCode: base)
            ?? code.uppercased()
        if code == base { return language.capitalized(with: locale) }
        return "\(language.capitalized(with: locale)) (\(code.uppercased()))"
    }

    static func priority(
        _ rawValue: String,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> Int {
        let code = canonicalCode(rawValue)
        let base = code.split(separator: "-").first.map(String.init) ?? code
        for (index, rawPreferred) in preferredLanguages.enumerated() {
            let preferred = canonicalCode(rawPreferred)
            let preferredBase = preferred.split(separator: "-").first.map(String.init) ?? preferred
            if code == preferred || base == preferredBase { return index }
        }
        if base == "en" { return preferredLanguages.count }
        if code == "all" || code == "multi" { return preferredLanguages.count + 1 }
        return preferredLanguages.count + 2
    }
}

/// Repairs one legacy installation shape produced before repository rows
/// exposed their language. The old MangaDex manifest placed Arabic first, so
/// an English-device install could durably select that row while appearing to
/// be the generic MangaDex source. Replacing its source ID would orphan
/// library routes, downloads, preferences, and Keychain state. Instead, keep
/// that identity and adapt only the JavaScript runtime presentation.
///
/// This is intentionally a fingerprinted compatibility rule, not a generic
/// locale override. New installs carry `languageSelectionVersion` and are
/// never changed, so an explicit Arabic choice remains Arabic.
enum ReaderExtensionLanguageCompatibilityPolicy {
    struct RuntimeIdentity: Equatable, Sendable {
        let upstreamID: String
        let language: String
        let isCompatibilityRepair: Bool
    }

    static let explicitSelectionVersion = 1

    private static let legacyMangaDexArabicID = "202373705"
    private static let mangaDexEnglishID = "810342358"
    private static let legacyMangaDexSourceID = "842777284c7656c54922835625169381aeaa2ea532bd1d5fb7ece85750c163cf"
    private static let mangaDexRepositoryID = "70e6f3228cd355efba57691881bb4bba4b68fddcb021668f2b4d191d63c788f0"
    private static let mangaDexRepositoryURL = "https://m2k3a.github.io/mangayomi-extensions/index.json"
    private static let legacyMangaDexProvenance = "4eae8a59504b92be41f616502c367d04d5f6616e008071365940009ecbad4924"
    private static let mangaDexScriptURL = "https://raw.githubusercontent.com/m2k3a/mangayomi-extensions/main/javascript/manga/src/all/mangadex.js"
    private static let mangaDexBaseURL = "https://mangadex.org"
    private static let mangaDexAPIURL = "https://api.mangadex.org"

    static func runtimeIdentity(
        for source: ReaderExtensionInstalledSource,
        preferredLanguages: [String] = Locale.preferredLanguages
    ) -> RuntimeIdentity {
        guard shouldRepairLegacyMangaDexArabic(
            source,
            preferredLanguages: preferredLanguages
        ) else {
            return RuntimeIdentity(
                upstreamID: source.upstreamID,
                language: source.language,
                isCompatibilityRepair: false
            )
        }
        return RuntimeIdentity(
            upstreamID: mangaDexEnglishID,
            language: "en",
            isCompatibilityRepair: true
        )
    }

    private static func shouldRepairLegacyMangaDexArabic(
        _ source: ReaderExtensionInstalledSource,
        preferredLanguages: [String]
    ) -> Bool {
        guard source.languageSelectionVersion == nil,
              preferredLanguageBase(preferredLanguages.first) == "en",
              ReaderExtensionLanguageInfo.canonicalCode(source.language)
                .split(separator: "-").first.map(String.init) == "ar",
              source.upstreamID == legacyMangaDexArabicID,
              source.id.rawValue == legacyMangaDexSourceID,
              source.repositoryID == mangaDexRepositoryID,
              canonical(source.repositoryURL) == mangaDexRepositoryURL,
              source.codeProvenanceFingerprint == legacyMangaDexProvenance,
              source.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare("MangaDex") == .orderedSame,
              source.mediaType == .manga,
              source.implementation == .javascript,
              canonical(source.sourceCodeURL) == mangaDexScriptURL,
              canonical(source.baseURL) == mangaDexBaseURL,
              canonical(source.apiURL) == mangaDexAPIURL else {
            return false
        }
        return true
    }

    private static func preferredLanguageBase(_ rawValue: String?) -> String {
        guard let rawValue else { return "" }
        return ReaderExtensionLanguageInfo.canonicalCode(rawValue)
            .split(separator: "-").first.map(String.init) ?? ""
    }

    private static func canonical(_ url: URL?) -> String? {
        url.map(ReaderExtensionURLCanonicalizer.canonicalString)
    }
}

extension ReaderExtensionInstalledSource {
    var effectiveLanguage: String {
        ReaderExtensionLanguageCompatibilityPolicy.runtimeIdentity(for: self).language
    }
}

enum ReaderExtensionURLCanonicalizer {
    static func canonicalString(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return url.absoluteString
        }
        components.scheme = components.scheme?.lowercased()
        if let host = components.host {
            components.host = ReaderExtensionSecurityPolicy.canonicalHost(host)
                ?? host.lowercased()
        }
        components.fragment = nil
        if (components.scheme == "https" && components.port == 443) ||
            (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        if components.path.count > 1 && components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.url?.absoluteString ?? url.absoluteString
    }
}

/// Mangayomi repository pages commonly expose an `add-repo` deep link instead
/// of making users copy each catalog URL. Accept that public interchange shape
/// at the text-field boundary, but return only Reader catalog URLs that pass
/// Eclipse's existing HTTPS syntax policy. The extracted destinations still
/// go through DNS/public-network validation before they are fetched.
enum ReaderExtensionRepositoryInput {
    private static let maximumInputBytes = 64 * 1_024
    private static let maximumNestedLinkDepth = 2
    private static let supportedCatalogKeys = ["manga_url", "novel_url"]

    static func repositoryURLs(from rawValue: String) throws -> [URL] {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= maximumInputBytes,
              let url = URL(string: value) else {
            throw ReaderExtensionError.invalidRepositoryURL
        }
        return try repositoryURLs(from: url, depth: 0)
    }

    private static func repositoryURLs(from url: URL, depth: Int) throws -> [URL] {
        guard depth <= maximumNestedLinkDepth else {
            throw ReaderExtensionError.invalidRepositoryURL
        }
        if (try? ReaderExtensionSecurityPolicy.validateRepositoryURLSyntax(url)) != nil {
            return [url]
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased() else {
            throw ReaderExtensionError.invalidRepositoryURL
        }

        if scheme == "mangayomi", isMangayomiAddRepositoryLink(components) {
            return try extractedCatalogURLs(from: components)
        }

        if scheme == "https",
           ReaderExtensionSecurityPolicy.canonicalHost(components.host) == "intradeus.github.io",
           components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "http-protocol-redirector",
           let nestedValue = components.queryItems?.first(where: { $0.name == "r" })?.value,
           nestedValue.utf8.count <= maximumInputBytes,
           let nestedURL = URL(string: nestedValue) {
            return try repositoryURLs(from: nestedURL, depth: depth + 1)
        }

        throw ReaderExtensionError.invalidRepositoryURL
    }

    private static func isMangayomiAddRepositoryLink(_ components: URLComponents) -> Bool {
        let host = components.host?.lowercased()
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        return host == "add-repo" || path == "add-repo"
    }

    private static func extractedCatalogURLs(from components: URLComponents) throws -> [URL] {
        let items = components.queryItems ?? []
        var urls: [URL] = []
        var seen = Set<String>()
        for key in supportedCatalogKeys {
            for value in items.lazy.filter({ $0.name.lowercased() == key }).compactMap(\.value) {
                guard value.utf8.count <= maximumInputBytes, let url = URL(string: value) else {
                    throw ReaderExtensionError.invalidRepositoryURL
                }
                try ReaderExtensionSecurityPolicy.validateRepositoryURLSyntax(url)
                let canonical = ReaderExtensionURLCanonicalizer.canonicalString(url)
                if seen.insert(canonical).inserted { urls.append(url) }
            }
        }
        guard !urls.isEmpty else { throw ReaderExtensionError.invalidRepositoryURL }
        return urls
    }
}
