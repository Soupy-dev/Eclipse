// Copyright 2026 Eclipse contributors
// SPDX-License-Identifier: Apache-2.0
//
// Substantially modified Swift host for the public Mangayomi JavaScript
// extension interface at commit 4eec7aca6f1c8bd563d0bc79bcf895f46bb30b74.
// See Eclipse/Legal/ReaderExtensions/NOTICE.txt. This file contains no source
// catalog, provider script, logo, or provider-specific configuration.

import CommonCrypto
import CryptoKit
import Foundation
import JavaScriptCore
import SwiftSoup

struct ReaderExtensionJavaScriptValidation: Hashable, Sendable {
    var capabilities: Set<ReaderExtensionCapability>
    var preferenceSchemaFingerprint: String?
    var secretPreferenceKeys: Set<String>
}

final class JavaScriptReaderProvider: ReaderSourceProvider {
    let source: ReaderExtensionInstalledSource
    private let scriptData: Data
    private let network: ReaderExtensionNetworkClient
    private let approvedDomains: Set<String>
    private let consentScopeID: String
    private let preferenceStore: ReaderExtensionPreferenceStore
    private let runtimeIdentity: ReaderExtensionLanguageCompatibilityPolicy.RuntimeIdentity
    private let onRuntimeIntegrityFailure: ((ReaderExtensionSourceID, String?) -> Void)?

    init(
        source: ReaderExtensionInstalledSource,
        scriptData: Data,
        network: ReaderExtensionNetworkClient,
        approvedDomains: Set<String>,
        consentScopeID: String,
        preferenceStore: ReaderExtensionPreferenceStore,
        runtimeIdentity: ReaderExtensionLanguageCompatibilityPolicy.RuntimeIdentity? = nil,
        onRuntimeIntegrityFailure: ((ReaderExtensionSourceID, String?) -> Void)? = nil
    ) throws {
        guard source.implementation == .javascript else { throw ReaderExtensionError.unsupportedSource }
        _ = try ReaderExtensionSecurityPolicy.validateScript(scriptData)
        self.source = source
        self.scriptData = scriptData
        self.network = network
        self.approvedDomains = approvedDomains
        self.consentScopeID = consentScopeID
        self.preferenceStore = preferenceStore
        self.runtimeIdentity = runtimeIdentity ?? .init(
            upstreamID: source.upstreamID,
            language: source.language,
            isCompatibilityRepair: false
        )
        self.onRuntimeIntegrityFailure = onRuntimeIntegrityFailure
    }

    func popular(page: Int) async throws -> ReaderExtensionPagedResult {
        try decodePaged(try await execute(.popular(max(1, page))))
    }

    func latest(page: Int) async throws -> ReaderExtensionPagedResult {
        try decodePaged(try await execute(.latest(max(1, page))))
    }

    func search(query: String, page: Int, filters: [ReaderExtensionFilter]) async throws -> ReaderExtensionPagedResult {
        try decodePaged(try await execute(.search(query: query, page: max(1, page), filters: filters)))
    }

    func detail(itemKey: String) async throws -> ReaderExtensionItem {
        let object = try object(try await execute(.detail(itemKey)))
        let item = try parseItem(object, fallbackKey: itemKey)
            .merging(seed: ReaderExtensionItemSeedCache.item(scopeID: consentScopeID, sourceID: source.id, key: itemKey))
        ReaderExtensionItemSeedCache.record(item, scopeID: consentScopeID, sourceID: source.id)
        return item
    }

    func chapters(itemKey: String) async throws -> [ReaderExtensionChapter] {
        let object = try object(try await execute(.detail(itemKey)))
        let rows = object["chapters"] as? [[String: Any]] ?? object["episodes"] as? [[String: Any]] ?? []
        return try rows.prefix(10_000).compactMap(parseChapter)
    }

    func pages(chapterKey: String) async throws -> [ReaderExtensionPage] {
        let data = try await execute(.pages(chapterKey))
        try ReaderExtensionJSONPreflight.validate(data, limits: .init(
            maximumBytes: ReaderExtensionSecurityPolicy.maximumDOMBytes,
            maximumContainerEntries: 10_000,
            maximumTotalTokens: 250_000
        ))
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw ReaderExtensionError.resultInvalid("page list is not an array")
        }
        var seen = Set<String>()
        return try rows.prefix(10_000).enumerated().compactMap { index, value in
            let rawURL: String
            let headers: [String: String]
            if let string = value as? String {
                rawURL = string; headers = [:]
            } else if let object = value as? [String: Any], let string = object["url"] as? String {
                rawURL = string; headers = object["headers"] as? [String: String] ?? [:]
            } else { return nil }
            guard let url = ReaderExtensionMangayomiURLParser.url(rawURL, relativeTo: source.baseURL) else { return nil }
            // Page images are passive resources. Do cheap syntax/archive
            // admission here; the pinned fetch path performs DNS/private-range
            // enforcement immediately before each network hop.
            try ReaderExtensionSecurityPolicy.validatePublicURLSyntax(url)
            try ReaderExtensionSecurityPolicy.validateNotArchive(data: Data(), response: nil, url: url)
            guard seen.insert(url.absoluteString).inserted else { return nil }
            return ReaderExtensionPage(key: "\(index):\(url.absoluteString)", url: url, headers: headers)
        }
    }

    func chapterHTML(chapterKey: String, chapterTitle: String) async throws -> String {
        let data = try await execute(.chapterHTML(title: chapterTitle, key: chapterKey))
        try ReaderExtensionJSONPreflight.validate(data, limits: .init(
            maximumBytes: ReaderExtensionSecurityPolicy.maximumDOMBytes,
            maximumDepth: 4,
            maximumContainerEntries: 1,
            maximumTotalTokens: 4
        ))
        let value: String
        if let decoded = try? JSONDecoder().decode(String.self, from: data) { value = decoded }
        else { value = String(data: data, encoding: .utf8) ?? "" }
        return try ReaderExtensionNovelSanitizer.sanitize(value, baseURL: source.baseURL, approvedDomains: approvedDomains)
    }

    func resourceHeaders() async throws -> [String: String] {
        let data = try await execute(.resourceHeaders)
        try ReaderExtensionJSONPreflight.validate(data, limits: .init(
            maximumBytes: 256 * 1_024,
            maximumDepth: 2,
            maximumContainerEntries: ReaderExtensionSecurityPolicy.maximumHeaderCount,
            maximumTopLevelEntries: ReaderExtensionSecurityPolicy.maximumHeaderCount,
            maximumTotalTokens: ReaderExtensionSecurityPolicy.maximumHeaderCount * 3 + 2,
            maximumStringBytes: 64 * 1_024
        ))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReaderExtensionError.resultInvalid("resource headers are not an object")
        }
        var headers: [String: String] = [:]
        headers.reserveCapacity(object.count)
        for name in object.keys.sorted() {
            guard let value = object[name] as? String else {
                throw ReaderExtensionError.resultInvalid("resource header values must be strings")
            }
            headers[name] = value
        }
        return try ReaderExtensionSecurityPolicy.sanitizedHeaders(
            headers,
            crossOrigin: false
        )
    }

    func filters() async throws -> [ReaderExtensionFilter] {
        let data = try await execute(.filters)
        try ReaderExtensionJSONPreflight.validate(data, limits: .init(
            maximumBytes: ReaderExtensionSecurityPolicy.maximumDOMBytes,
            maximumContainerEntries: 200,
            maximumTotalTokens: 50_000
        ))
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return Self.parseFilters(rows)
    }

    func preferences() async throws -> [ReaderExtensionPreference] {
        let data = try await execute(.preferences)
        try ReaderExtensionJSONPreflight.validate(data, limits: .init(
            maximumBytes: ReaderExtensionSecurityPolicy.maximumDOMBytes,
            maximumContainerEntries: ReaderExtensionSecurityPolicy.maximumPreferenceCount,
            maximumTotalTokens: 50_000
        ))
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return ReaderExtensionJavaScriptPreferenceSchema.preferences(from: rows)
    }

    private func execute(_ operation: ReaderExtensionJavaScriptOperation) async throws -> Data {
        do {
            return try await ReaderExtensionJavaScriptRuntime.execute(
                scriptData: scriptData,
                source: source,
                operation: operation,
                network: network,
                approvedDomains: approvedDomains,
                preferenceStore: preferenceStore,
                runtimeIdentity: runtimeIdentity
            )
        } catch ReaderExtensionError.runtimeTimedOut {
            onRuntimeIntegrityFailure?(source.id, source.activeContentDigest)
            throw ReaderExtensionError.runtimeTimedOut
        } catch ReaderExtensionError.sourceQuarantined {
            onRuntimeIntegrityFailure?(source.id, source.activeContentDigest)
            throw ReaderExtensionError.sourceQuarantined
        } catch ReaderExtensionError.runtimeIntegrityFailed(let phase) {
            onRuntimeIntegrityFailure?(source.id, source.activeContentDigest)
            throw ReaderExtensionError.runtimeIntegrityFailed(phase)
        }
    }

    private func decodePaged(_ data: Data) throws -> ReaderExtensionPagedResult {
        let result = try object(
            data,
            maximumContainerEntries: ReaderExtensionSecurityPolicy.maximumResultRows,
            maximumTotalTokens: 50_000
        )
        let rows = result["list"] as? [[String: Any]] ?? []
        let items = try rows.prefix(ReaderExtensionSecurityPolicy.maximumResultRows).enumerated().map {
            try parseItem($0.element, fallbackKey: "item-\($0.offset)")
        }
        ReaderExtensionItemSeedCache.record(items, scopeID: consentScopeID, sourceID: source.id)
        return ReaderExtensionPagedResult(items: items, hasNextPage: result["hasNextPage"] as? Bool ?? false)
    }

    static let modelledOptionKeys: Set<String> = ["name", "label", "value", "type", "type_name"]

    static func parseFilters(_ rows: [[String: Any]], depth: Int = 0) -> [ReaderExtensionFilter] {
        guard depth < 8 else { return [] }
        return rows.prefix(200).enumerated().map { index, row in
            let abiType = row["type"] as? String
            let abiTypeName = row["type_name"] as? String
            let semanticType = abiTypeName ?? (row["kind"] as? String) ?? abiType
            let key = (row["key"] as? String) ?? "\(abiType ?? semanticType ?? "filter")-\(index)"
            let declaredTitle = (row["name"] as? String) ?? (row["title"] as? String)
            // `type` is commonly a provider-specific discriminator consumed by
            // search(), while `type_name` describes the Mangayomi UI/ABI kind.
            // They are independent and both must survive a round trip.
            let rawKind = (semanticType ?? "text").lowercased()
            let optionRows = (row["values"] as? [[String: Any]]) ?? (row["options"] as? [[String: Any]]) ?? []
            let options = optionRows.prefix(200).map { optionRow in
                var extras: [String: ReaderExtensionJSONValue] = [:]
                for (name, raw) in optionRow where !Self.modelledOptionKeys.contains(name) {
                    guard extras.count < 16, name.utf8.count <= 128,
                          let value = ReaderExtensionJSONValue(foundationObject: raw) else { continue }
                    extras[name] = value
                }
                return ReaderExtensionFilterOption(
                    label: (optionRow["name"] as? String) ?? (optionRow["label"] as? String) ?? "",
                    value: String(describing: optionRow["value"] ?? ""),
                    abiType: optionRow["type"] as? String,
                    abiTypeName: optionRow["type_name"] as? String,
                    abiExtras: extras.isEmpty ? nil : extras
                )
            }
            let filtersRows = row["filters"] as? [[String: Any]]
            let stateRows = rawKind.contains("group") ? row["state"] as? [[String: Any]] : nil
            let nestedRows = filtersRows
                ?? stateRows
                ?? []
            let kind: ReaderExtensionFilterKind = rawKind.contains("separator") ? .separator
                : rawKind.contains("header") ? .header
                : rawKind.contains("group") ? .group
                : rawKind.contains("sort") ? .sort
                : rawKind.contains("select") ? .select
                : rawKind.contains("check") ? .toggle
                : rawKind.contains("tri") ? .triState
                : .text
            // SeparatorFilter carries layout, not user-visible copy. Falling
            // back to its generated persistence key surfaced implementation
            // strings as bogus filter labels.
            let title = kind == .separator ? "" : (declaredTitle ?? key)
            let abiState: ReaderExtensionJSONValue? = kind == .group || kind == .header || kind == .separator
                ? nil
                : row["state"].flatMap { ReaderExtensionJSONValue(foundationObject: $0) }
            let abiValue = row["value"].flatMap { ReaderExtensionJSONValue(foundationObject: $0) }
            let sortAscending: Bool? = kind == .sort
                ? ((row["state"] as? [String: Any])?["ascending"] as? Bool ?? false)
                : nil
            let value: ReaderExtensionPreferenceValue
            var declaredOptionIndex: Int?
            switch kind {
            case .group, .header, .separator:
                value = .string("")
            case .toggle:
                value = .bool((row["state"] as? Bool) ?? false)
            case .triState:
                value = .number((row["state"] as? NSNumber)?.doubleValue ?? 0)
            case .select:
                if let selected = (row["state"] as? NSNumber)?.intValue,
                   options.indices.contains(selected) {
                    value = .string(options[selected].value)
                    declaredOptionIndex = selected
                } else if let selected = row["state"] as? String {
                    value = .string(selected)
                    declaredOptionIndex = options.firstIndex { $0.value == selected }
                } else {
                    value = .string(options.first?.value ?? "")
                    declaredOptionIndex = options.isEmpty ? nil : 0
                }
            case .sort:
                if let state = row["state"] as? [String: Any],
                   let selected = (state["index"] as? NSNumber)?.intValue,
                   options.indices.contains(selected) {
                    value = .string(options[selected].value)
                    declaredOptionIndex = selected
                } else if let selected = (row["state"] as? NSNumber)?.intValue,
                          options.indices.contains(selected) {
                    value = .string(options[selected].value)
                    declaredOptionIndex = selected
                } else {
                    value = .string(options.first?.value ?? "")
                    declaredOptionIndex = options.isEmpty ? nil : 0
                }
            case .text:
                if let boolean = row["state"] as? Bool { value = .bool(boolean) }
                else if let number = row["state"] as? NSNumber { value = .number(number.doubleValue) }
                else if let list = row["state"] as? [String] { value = .stringList(list) }
                else { value = .string(String(describing: row["state"] ?? "")) }
            }
            return ReaderExtensionFilter(
                key: key,
                title: title,
                kind: kind,
                options: options,
                value: value,
                abiType: abiType,
                abiTypeName: abiTypeName,
                abiState: abiState,
                abiValue: abiValue,
                abiChildrenKey: filtersRows != nil ? "filters" : (stateRows != nil ? "state" : nil),
                sortAscending: sortAscending,
                selectedOptionIndex: declaredOptionIndex,
                children: parseFilters(nestedRows, depth: depth + 1)
            )
        }
    }

    private func object(
        _ data: Data,
        maximumContainerEntries: Int = 10_000,
        maximumTotalTokens: Int = 300_000
    ) throws -> [String: Any] {
        try ReaderExtensionJSONPreflight.validate(data, limits: .init(
            maximumBytes: ReaderExtensionSecurityPolicy.maximumDOMBytes,
            maximumContainerEntries: maximumContainerEntries,
            maximumTotalTokens: maximumTotalTokens
        ))
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReaderExtensionError.resultInvalid("expected an object")
        }
        return result
    }

    private func parseItem(_ row: [String: Any], fallbackKey: String) throws -> ReaderExtensionItem {
        let suppliedKey = (row["link"] as? String) ?? (row["url"] as? String)
        let rawKey = suppliedKey ?? fallbackKey
        let url = ReaderExtensionMangayomiURLParser.url(rawKey, relativeTo: source.baseURL)
        let title = (row["name"] as? String) ?? (row["title"] as? String) ?? fallbackKey
        let statusNumber = (row["status"] as? NSNumber)?.intValue
        let status: ReaderExtensionPublicationStatus = statusNumber == 0 ? .ongoing : statusNumber == 1 ? .completed : statusNumber == 2 ? .hiatus : statusNumber == 3 ? .cancelled : statusNumber == 4 ? .finished : .unknown
        let genres = row["genre"] as? [String] ?? row["genres"] as? [String] ?? []
        // Mangayomi hands getDetail/getPageList the exact link string the
        // extension returned. Canonicalizing it here broke every source whose
        // URL arithmetic depends on its own shape: WeebCentral branches on
        // startsWith("http") and its chapter keys are bare ULIDs, while
        // MangaDex prefixes its api origin onto a relative path.
        let key = String(rawKey.prefix(4_096))
        if suppliedKey != nil,
           ReaderExtensionSecurityPolicy.persistableProviderContentKey(key) == nil {
            throw ReaderExtensionError.resultInvalid("item identity contained authorization data")
        }
        let rawCover = ((row["imageUrl"] as? String) ?? (row["coverURL"] as? String))
            .flatMap { ReaderExtensionMangayomiURLParser.url($0, relativeTo: source.baseURL) }
        return ReaderExtensionItem(
            key: key,
            title: String(title.prefix(1_024)),
            url: url,
            coverURL: ReaderExtensionSecurityPolicy.validatedAssetURL(
                rawCover,
                sourceID: source.id,
                approvedDomains: approvedDomains,
                consentScopeID: consentScopeID
            ),
            description: (row["description"] as? String).map { String($0.prefix(512 * 1_024)) },
            author: (row["author"] as? String).map { String($0.prefix(4_096)) },
            artist: (row["artist"] as? String).map { String($0.prefix(4_096)) },
            status: status,
            tags: Array(genres.prefix(200)),
            maturity: source.maturity
        )
    }

    private func parseChapter(_ row: [String: Any]) throws -> ReaderExtensionChapter? {
        guard let rawKey = (row["url"] as? String) ?? (row["link"] as? String) else { return nil }
        let url = ReaderExtensionMangayomiURLParser.url(rawKey, relativeTo: source.baseURL)
        let title = (row["name"] as? String) ?? (row["title"] as? String) ?? rawKey
        return ReaderExtensionChapter(
            key: String(rawKey.prefix(4_096)),
            title: String(title.prefix(1_024)),
            url: url,
            uploadedAt: ReaderExtensionJavaScriptRuntime.date(row["dateUpload"]),
            scanlator: (row["scanlator"] as? String).map { String($0.prefix(512)) },
            isFiller: row["isFiller"] as? Bool ?? false,
            thumbnailURL: ReaderExtensionSecurityPolicy.validatedAssetURL(
                (row["thumbnailUrl"] as? String).flatMap { ReaderExtensionMangayomiURLParser.url($0, relativeTo: source.baseURL) },
                sourceID: source.id,
                approvedDomains: approvedDomains,
                consentScopeID: consentScopeID
            ),
            summary: (row["description"] as? String).map { String($0.prefix(16 * 1_024)) }
        )
    }

}

/// Parses only the bounded preference shapes in Mangayomi's audited contract.
/// Declared defaults remain runtime fallbacks; they are never copied into
/// profile metadata or Keychain merely because a source declared them.
private enum ReaderExtensionJavaScriptPreferenceSchema {
    private static let maximumSchemaBytes = 512 * 1_024

    static func decodeRows(_ rawJSON: String) -> [[String: Any]]? {
        guard let data = rawJSON.data(using: .utf8), data.count <= maximumSchemaBytes,
              (try? ReaderExtensionJSONPreflight.validate(data, limits: .init(
                maximumBytes: maximumSchemaBytes,
                maximumContainerEntries: ReaderExtensionSecurityPolicy.maximumPreferenceCount,
                maximumTotalTokens: 50_000
              ))) != nil,
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return Array(rows.prefix(ReaderExtensionSecurityPolicy.maximumPreferenceCount))
    }

    static func defaults(from rows: [[String: Any]]) -> [String: ReaderExtensionPreferenceValue] {
        var result: [String: ReaderExtensionPreferenceValue] = [:]
        for row in rows.prefix(ReaderExtensionSecurityPolicy.maximumPreferenceCount) {
            guard let key = validatedKey(row["key"] as? String),
                  result[key] == nil,
                  let value = declaredDefault(from: row),
                  (try? ReaderExtensionSecurityPolicy.validatePreference(key: key, value: value)) != nil else { continue }
            result[key] = value
        }
        return result
    }

    static func preferences(from rows: [[String: Any]]) -> [ReaderExtensionPreference] {
        var seenKeys = Set<String>()
        var preferences: [ReaderExtensionPreference] = []
        preferences.reserveCapacity(min(rows.count, ReaderExtensionSecurityPolicy.maximumPreferenceCount))
        for row in rows.prefix(ReaderExtensionSecurityPolicy.maximumPreferenceCount) {
            guard let key = validatedKey(row["key"] as? String),
                  seenKeys.insert(key).inserted else { continue }
            let payload = preferencePayload(row)
            let title = boundedString(payload["title"] as? String, fallback: key, maximum: 1_024)
            let summary = boundedOptionalString(payload["summary"] as? String, maximum: 4_096)
            let dialogTitle = boundedOptionalString(payload["dialogTitle"] as? String, maximum: 1_024)
            let dialogMessage = boundedOptionalString(payload["dialogMessage"] as? String, maximum: 4_096)
            let inputHint = boundedOptionalString(payload["text"] as? String, maximum: 1_024)
            let entries = Array((payload["entries"] as? [String] ?? []).prefix(ReaderExtensionSecurityPolicy.maximumPreferenceListCount))
            let entryValues = Array((payload["entryValues"] as? [String] ?? []).prefix(ReaderExtensionSecurityPolicy.maximumPreferenceListCount))
            let options = zip(entries, entryValues).compactMap { label, value -> ReaderExtensionFilterOption? in
                guard label.utf8.count <= 4_096,
                      value.utf8.count <= ReaderExtensionSecurityPolicy.maximumPreferenceValueBytes else { return nil }
                return ReaderExtensionFilterOption(label: label, value: value)
            }

            let kind: ReaderExtensionPreferenceKind
            if row["listPreference"] != nil || row["multiSelectListPreference"] != nil {
                kind = .select
            } else if row["checkBoxPreference"] != nil
                        || row["switchPreferenceCompat"] != nil
                        || row["switchPreference"] != nil {
                kind = .toggle
            } else {
                let inputType = String(describing: payload["inputType"] ?? "").lowercased()
                let secret = inputType.contains("password") || inputType.contains("secret")
                    || ReaderExtensionSecurityPolicy.isCredentialLikePreferenceKey(key)
                kind = secret ? .secret : .text
            }

            let fallback: ReaderExtensionPreferenceValue
            switch kind {
            case .toggle: fallback = .bool(false)
            case .select where row["multiSelectListPreference"] != nil: fallback = .stringList([])
            default: fallback = .string("")
            }
            let defaultValue: ReaderExtensionPreferenceValue
            if let candidate = declaredDefault(from: row),
               (try? ReaderExtensionSecurityPolicy.validatePreference(key: key, value: candidate)) != nil {
                defaultValue = candidate
            } else {
                defaultValue = fallback
            }
            preferences.append(ReaderExtensionPreference(
                key: key,
                title: title,
                summary: summary,
                kind: kind,
                options: options,
                defaultValue: defaultValue,
                dialogTitle: dialogTitle,
                dialogMessage: dialogMessage,
                inputHint: inputHint
            ))
        }
        return preferences
    }

    private static func declaredDefault(from row: [String: Any]) -> ReaderExtensionPreferenceValue? {
        if let payload = row["listPreference"] as? [String: Any],
           let values = payload["entryValues"] as? [String],
           let number = payload["valueIndex"] as? NSNumber {
            let rawIndex = number.doubleValue
            guard rawIndex.isFinite, rawIndex.rounded(.towardZero) == rawIndex else { return nil }
            let index = number.intValue
            guard values.indices.contains(index) else { return nil }
            return .string(values[index])
        }
        if let payload = row["multiSelectListPreference"] as? [String: Any],
           let values = payload["values"] as? [String] {
            return .stringList(Array(values.prefix(ReaderExtensionSecurityPolicy.maximumPreferenceListCount)))
        }
        if let payload = (row["checkBoxPreference"] as? [String: Any])
            ?? (row["switchPreferenceCompat"] as? [String: Any])
            ?? (row["switchPreference"] as? [String: Any]),
           let value = payload["value"] as? Bool {
            return .bool(value)
        }
        if let payload = row["editTextPreference"] as? [String: Any],
           let value = payload["value"] as? String {
            return .string(value)
        }

        let payload = preferencePayload(row)
        if let value = payload["value"] as? Bool { return .bool(value) }
        if let value = payload["value"] as? String { return .string(value) }
        if let values = payload["values"] as? [String] {
            return .stringList(Array(values.prefix(ReaderExtensionSecurityPolicy.maximumPreferenceListCount)))
        }
        return nil
    }

    private static func preferencePayload(_ row: [String: Any]) -> [String: Any] {
        (row["editTextPreference"] as? [String: Any])
            ?? (row["checkBoxPreference"] as? [String: Any])
            ?? (row["switchPreferenceCompat"] as? [String: Any])
            ?? (row["switchPreference"] as? [String: Any])
            ?? (row["listPreference"] as? [String: Any])
            ?? (row["multiSelectListPreference"] as? [String: Any])
            ?? row
    }

    private static func validatedKey(_ key: String?) -> String? {
        guard let key, !key.isEmpty,
              key.utf8.count <= ReaderExtensionSecurityPolicy.maximumPreferenceKeyBytes,
              !key.contains("\0"), !key.contains("\r"), !key.contains("\n") else { return nil }
        return key
    }

    private static func boundedString(_ value: String?, fallback: String, maximum: Int) -> String {
        guard let value else { return fallback }
        return String(value.prefix(maximum))
    }

    private static func boundedOptionalString(_ value: String?, maximum: Int) -> String? {
        value.map { String($0.prefix(maximum)) }
    }
}

/// Dart's Uri.parse repairs invalid characters while preserving existing
/// percent-escapes, and Mangayomi extensions rely on that: WeebCentral emits
/// `sort=Latest Updates` (raw space) next to `display_mode=Full%20Display`
/// in one URL. Foundation's whole-string repair re-encodes the existing
/// escape to `%2520` whenever any other character needs fixing, which the
/// site answers with a redirect to an unparseable compact page.
enum ReaderExtensionMangayomiURLParser {
    private static let allowedCharacters: CharacterSet = {
        var characters = CharacterSet.urlQueryAllowed
        characters.formUnion(.urlPathAllowed)
        characters.formUnion(.urlHostAllowed)
        characters.formUnion(.urlFragmentAllowed)
        characters.formUnion(.urlUserAllowed)
        characters.formUnion(.urlPasswordAllowed)
        characters.insert(charactersIn: "%#/?:@[]!$&'()*+,;=-._~")
        return characters
    }()

    static func url(_ rawValue: String, relativeTo baseURL: URL?) -> URL? {
        guard let repaired = rawValue.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else {
            return nil
        }
        return URL(string: repaired, relativeTo: baseURL)?.absoluteURL
    }
}

enum ReaderExtensionJavaScriptOperation {
    case popular(Int)
    case latest(Int)
    case search(query: String, page: Int, filters: [ReaderExtensionFilter])
    case detail(String)
    case pages(String)
    case chapterHTML(title: String, key: String)
    case resourceHeaders
    case filters
    case preferences
    case validation

    fileprivate var expression: String {
        switch self {
        case .popular(let page): return "extensionInstance.getPopular(\(page))"
        case .latest(let page):
            return "__readerInvokeOptional('getLatestUpdates', [\(page)], {list: [], hasNextPage: false})"
        case .search(let query, let page, let filters):
            // Mangayomi always passes the source's own getFilterList() output
            // to search; extensions index it positionally. A bare [] from
            // global search is a TypeError before the first fetch.
            if filters.isEmpty {
                return "(async function() { return await extensionInstance.search(\(Self.literal(query)), \(page), await __readerInvokeOptional('getFilterList', [], [])); })()"
            }
            return "extensionInstance.search(\(Self.literal(query)), \(page), \(Self.filterLiteral(filters)))"
        case .detail(let key): return "extensionInstance.getDetail(\(Self.literal(key)))"
        case .pages(let key): return "extensionInstance.getPageList(\(Self.literal(key)))"
        case .chapterHTML(let title, let key):
            // Mangayomi always runs the extension's cleanHtmlContent over the
            // fetched chapter body; the MProvider default returns it verbatim.
            return "(async function() { return await extensionInstance.cleanHtmlContent(await extensionInstance.getHtmlContent(\(Self.literal(title)), \(Self.literal(key)))); })()"
        case .resourceHeaders:
            // Mangayomi passes the effective source base URL to getHeaders.
            // Some extensions use it to choose origin-specific hotlink
            // headers; invoking it with no argument silently loses them.
            return "__readerInvokeOptional('getHeaders', [extensionInstance.source.baseUrl], {})"
        case .filters:
            return "__readerInvokeOptional('getFilterList', [], [])"
        case .preferences:
            return Self.optionalPreferencesExpression
        case .validation:
            return """
            (async function() {
              const differs = function(name) {
                return typeof extensionInstance[name] === 'function' && extensionInstance[name] !== MProvider.prototype[name];
              };
              const names = ['getPopular','getLatestUpdates','search','getDetail','getPageList','getHtmlContent','getFilterList','getSourcePreferences'];
              let overrides = names.filter(differs);
              overrides = overrides.filter(function(name) {
                if (name !== 'getLatestUpdates' && name !== 'getFilterList') return true;
                return !__readerIsExactOptionalStub(name);
              });
              const preferences = await __readerInitializePreferenceDefaults();
              if (!__readerPreferencesImplemented) overrides = overrides.filter(name => name !== 'getSourcePreferences');
              return { overrides, preferences };
            })()
            """
        }
    }

    private static func literal(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value), let string = String(data: data, encoding: .utf8) else { return "\"\"" }
        return string
    }

    private static let optionalPreferencesExpression = """
    __readerInitializePreferenceDefaults()
    """

    static func filterLiteral(_ filters: [ReaderExtensionFilter]) -> String {
        func selectedIndex(_ filter: ReaderExtensionFilter) -> Int? {
            filter.resolvedOptionIndex
        }

        func scalarState(_ value: ReaderExtensionPreferenceValue) -> Any {
            switch value {
            case .string(let value): return value
            case .bool(let value): return value
            case .number(let value): return value
            case .stringList(let value): return value
            case .secretReference: return NSNull()
            }
        }

        func state(_ filter: ReaderExtensionFilter) -> Any {
            if filter.kind == .sort {
                var object: [String: ReaderExtensionJSONValue]
                if case .object(let existing)? = filter.abiState {
                    object = existing
                } else {
                    object = [:]
                }
                object["index"] = .number(Double(selectedIndex(filter) ?? 0))
                let preservedAscending: Bool
                if case .bool(let existing)? = object["ascending"] {
                    preservedAscending = existing
                } else {
                    preservedAscending = false
                }
                object["ascending"] = .bool(filter.sortAscending ?? preservedAscending)
                object["type_name"] = .string("SortState")
                return ReaderExtensionJSONValue.object(object).foundationObject
            }
            if filter.kind == .select {
                // Mangayomi's SelectFilter state is always the selected option
                // index. Some providers omit an initial state; emitting the
                // option value string in that case breaks their search ABI.
                return selectedIndex(filter) ?? 0
            }
            return scalarState(filter.value)
        }

        func rows(_ filters: [ReaderExtensionFilter], depth: Int) -> [[String: Any]] {
            guard depth < 8 else { return [] }
            return filters.prefix(200).map { filter in
                var row: [String: Any] = [:]
                if filter.kind != .separator { row["name"] = filter.title }
                if let abiType = filter.abiType { row["type"] = abiType }
                if let abiTypeName = filter.abiTypeName { row["type_name"] = abiTypeName }
                if filter.abiTypeName == nil {
                    row["type_name"] = Self.canonicalABIType(for: filter.kind)
                }
                if !filter.key.isEmpty { row["key"] = filter.key }
                if filter.kind == .group || !filter.children.isEmpty {
                    let nested = rows(filter.children, depth: depth + 1)
                    row[filter.abiChildrenKey == "filters" ? "filters" : "state"] = nested
                } else if filter.kind != .header && filter.kind != .separator {
                    row["state"] = state(filter)
                }
                if let abiValue = filter.abiValue { row["value"] = abiValue.foundationObject }
                if filter.kind == .select || filter.kind == .sort || !filter.options.isEmpty {
                    row["values"] = filter.options.map { option in
                        var value: [String: Any] = [:]
                        // Unknown provider fields are restored first so a
                        // hostile extras blob can never shadow the modelled
                        // identity keys written below.
                        for (name, extra) in option.abiExtras ?? [:] {
                            value[name] = extra.foundationObject
                        }
                        value["name"] = option.label
                        value["value"] = option.value
                        if let abiType = option.abiType { value["type"] = abiType }
                        value["type_name"] = option.abiTypeName ?? "SelectOption"
                        return value
                    }
                }
                return row
            }
        }
        let rows = rows(filters, depth: 0)
        guard JSONSerialization.isValidJSONObject(rows), let data = try? JSONSerialization.data(withJSONObject: rows), let string = String(data: data, encoding: .utf8) else { return "[]" }
        return string
    }

    private static func canonicalABIType(for kind: ReaderExtensionFilterKind) -> String {
        switch kind {
        case .text: return "TextFilter"
        case .toggle: return "CheckBox"
        case .select: return "SelectFilter"
        case .triState: return "TriState"
        case .sort: return "SortFilter"
        case .group: return "GroupFilter"
        case .header: return "HeaderFilter"
        case .separator: return "SeparatorFilter"
        }
    }
}

final class ReaderExtensionRuntimeAdmissionGate: @unchecked Sendable {
    final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var releaseOperation: (() -> Void)?

        fileprivate init(release: @escaping () -> Void) {
            releaseOperation = release
        }

        func release() {
            let operation = lock.withReaderRuntimeLock { () -> (() -> Void)? in
                defer { releaseOperation = nil }
                return releaseOperation
            }
            operation?()
        }

        deinit { release() }
    }

    private let globalPermit: DispatchSemaphore
    private let lock = NSLock()
    private var sourcePermits: [ReaderExtensionSourceID: DispatchSemaphore] = [:]
    private var sourceWaiters: [ReaderExtensionSourceID: Int] = [:]

    init(maximumConcurrentOperations: Int) {
        globalPermit = DispatchSemaphore(value: max(1, maximumConcurrentOperations))
    }

    func acquire(
        sourceID: ReaderExtensionSourceID,
        timeout: TimeInterval
    ) -> Lease? {
        let sourcePermit = lock.withReaderRuntimeLock { () -> DispatchSemaphore in
            sourceWaiters[sourceID, default: 0] += 1
            if let existing = sourcePermits[sourceID] { return existing }
            let created = DispatchSemaphore(value: 1)
            sourcePermits[sourceID] = created
            return created
        }
        defer {
            lock.withReaderRuntimeLock {
                let next = max(0, (sourceWaiters[sourceID] ?? 1) - 1)
                if next == 0 { sourceWaiters[sourceID] = nil }
                else { sourceWaiters[sourceID] = next }
            }
        }

        let deadline = DispatchTime.now() + timeout
        guard sourcePermit.wait(timeout: deadline) == .success else { return nil }
        guard globalPermit.wait(timeout: deadline) == .success else {
            sourcePermit.signal()
            return nil
        }
        return Lease { [globalPermit = self.globalPermit] in
            globalPermit.signal()
            sourcePermit.signal()
        }
    }

#if DEBUG
    func waiterCountForTesting(sourceID: ReaderExtensionSourceID) -> Int {
        lock.withReaderRuntimeLock { sourceWaiters[sourceID] ?? 0 }
    }
#endif
}

enum ReaderExtensionRuntimeQuarantineDurability {
    /// Returns only after either the source+digest deny marker or removal of
    /// the exact executable blob completed. The latter is the fail-closed
    /// fallback when both independent marker representations are unavailable.
    static func enforce(
        persistMarker: () throws -> Void,
        removeExactExecutable: () throws -> Void
    ) -> Bool {
        do {
            try persistMarker()
            return true
        } catch {
            do {
                try removeExactExecutable()
                return true
            } catch {
                return false
            }
        }
    }
}

enum ReaderExtensionJavaScriptRuntime {
    private struct QuarantineKey: Hashable {
        let sourceID: ReaderExtensionSourceID
        let digest: String
    }

    private static let queueLock = NSLock()
    private static var queues: [ReaderExtensionSourceID: DispatchQueue] = [:]
    private static let admissionQueue = DispatchQueue(label: "app.eclipse.reader-extensions.runtime-admission", qos: .userInitiated, attributes: .concurrent)
    private static let timeoutQueue = DispatchQueue(label: "app.eclipse.reader-extensions.runtime-timeout", qos: .utility)
    private static let maximumNonDrainingOperations = 2
    // Source serialization is acquired before the global stuck-worker budget.
    // A second call for a hung source therefore waits without consuming the
    // permit another independent source needs to make progress. The stuck-
    // worker budget is a degradation threshold, not the concurrency ceiling:
    // capping the gate at it halved healthy multi-source browse throughput.
    private static let admissionGate = ReaderExtensionRuntimeAdmissionGate(
        maximumConcurrentOperations: ReaderExtensionSecurityPolicy.maximumConcurrentRuntimeOperations
    )
    private static let quarantineLock = NSLock()
    private static var quarantinedDigests = Set<QuarantineKey>()
    private static var quarantineDurabilityUnavailable = false
    private static let nonDrainingLock = NSLock()
    private static var nonDrainingOperationCount = 0

    static func bootstrapValidate(
        scriptData: Data,
        source: ReaderExtensionInstalledSource
    ) async throws -> ReaderExtensionJavaScriptValidation {
        _ = try ReaderExtensionSecurityPolicy.validateScript(scriptData)
        var validationSource = source
        validationSource.activeContentDigest = SHA256.hash(data: scriptData).map { String(format: "%02x", $0) }.joined()
        let data = try await execute(
            scriptData: scriptData,
            source: validationSource,
            operation: .validation,
            network: ReaderExtensionDenyNetworkClient(),
            approvedDomains: [],
            preferenceStore: ReaderExtensionInMemoryPreferenceStore(values: source.preferences)
        )
        try ReaderExtensionJSONPreflight.validate(data, limits: .init(
            maximumBytes: ReaderExtensionSecurityPolicy.maximumDOMBytes,
            maximumContainerEntries: 200,
            maximumTotalTokens: 10_000
        ))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let overrideNames = object["overrides"] as? [String] else {
            throw ReaderExtensionError.runtimeFailed("network-disabled export validation failed")
        }
        let mapping: [String: ReaderExtensionCapability] = [
            "getPopular": .popular,
            "getLatestUpdates": .latest,
            "search": .search,
            "getDetail": .detail,
            "getPageList": .pages,
            "getHtmlContent": .chapterHTML,
            "getFilterList": .filters,
            "getSourcePreferences": .preferences
        ]
        let capabilities = Set(overrideNames.compactMap { mapping[$0] })
        let required: Set<ReaderExtensionCapability> = source.mediaType == .manga
            ? [.popular, .search, .detail, .pages]
            : [.popular, .search, .detail, .chapterHTML]
        guard required.isSubset(of: capabilities) else {
            let missing = required.subtracting(capabilities).map(\.rawValue).sorted().joined(separator: ", ")
            throw ReaderExtensionError.invalidManifest("DefaultExtension does not implement required exports: \(missing)")
        }
        let preferences = (object["preferences"] as? [[String: Any]] ?? []).prefix(200).map { $0 }
        let preferenceData = try JSONSerialization.data(withJSONObject: preferences, options: [.sortedKeys])
        guard preferenceData.count <= 512 * 1_024 else { throw ReaderExtensionError.contentTooLarge }
        let secretKeys = Set(preferences.compactMap { row -> String? in
            let key = (row["key"] as? String) ?? ""
            let payload = (row["editTextPreference"] as? [String: Any]) ?? row
            let inputType = String(describing: payload["inputType"] ?? "").lowercased()
            let isSecret = inputType.contains("password") || inputType.contains("secret")
                || ReaderExtensionSecurityPolicy.isCredentialLikePreferenceKey(key)
            return isSecret && !key.isEmpty ? key : nil
        })
        return ReaderExtensionJavaScriptValidation(
            capabilities: capabilities,
            preferenceSchemaFingerprint: capabilities.contains(.preferences)
                ? SHA256.hash(data: preferenceData).map { String(format: "%02x", $0) }.joined()
                : nil,
            secretPreferenceKeys: secretKeys
        )
    }

    static func execute(
        scriptData: Data,
        source: ReaderExtensionInstalledSource,
        operation: ReaderExtensionJavaScriptOperation,
        network: ReaderExtensionNetworkClient,
        approvedDomains: Set<String>,
        preferenceStore: ReaderExtensionPreferenceStore,
        runtimeIdentity providedRuntimeIdentity: ReaderExtensionLanguageCompatibilityPolicy.RuntimeIdentity? = nil
    ) async throws -> Data {
        guard !quarantineLock.withReaderRuntimeLock({ quarantineDurabilityUnavailable }) else {
            throw ReaderExtensionError.runtimeUnavailable
        }
        let exactDigest = SHA256.hash(data: scriptData).map { String(format: "%02x", $0) }.joined()
        let digest = source.activeContentDigest?.lowercased() ?? exactDigest
        let quarantineKey = QuarantineKey(sourceID: source.id, digest: digest)
        let durablyQuarantined: Bool
        do {
            durablyQuarantined = try ReaderExtensionPersistence.runtimeQuarantineContains(
                sourceID: source.id,
                digest: digest
            )
        } catch {
            // Corrupt or unreadable fail-safe state must never become an
            // executable-source admission bypass.
            throw ReaderExtensionError.runtimeUnavailable
        }
        guard !durablyQuarantined,
              !quarantineLock.withReaderRuntimeLock({ quarantinedDigests.contains(quarantineKey) }) else {
            throw ReaderExtensionError.sourceQuarantined
        }
        if source.activeContentDigest != nil, digest != exactDigest {
            // Executable metadata is trusted only when it names these exact
            // bytes. Quarantine the metadata digest synchronously so a failed
            // rollback write or delayed callback cannot re-admit it.
            quarantine(quarantineKey)
            throw ReaderExtensionError.runtimeIntegrityFailed("source content digest validation")
        }
        let code = try ReaderExtensionSecurityPolicy.validateScript(scriptData)
        let runtimeIdentity = providedRuntimeIdentity ?? .init(
            upstreamID: source.upstreamID,
            language: source.language,
            isCompatibilityRepair: false
        )
        let queue = providerQueue(source.id)
        return try await withCheckedThrowingContinuation { continuation in
            admissionQueue.async {
                guard nonDrainingLock.withReaderRuntimeLock({ nonDrainingOperationCount < maximumNonDrainingOperations }) else {
                    continuation.resume(throwing: ReaderExtensionError.runtimeUnavailable)
                    return
                }
                guard let admissionLease = admissionGate.acquire(
                    sourceID: source.id,
                    timeout: ReaderExtensionSecurityPolicy.operationTimeout
                ) else {
                    continuation.resume(throwing: ReaderExtensionError.runtimeUnavailable)
                    return
                }
                let completion = ReaderExtensionRuntimeCompletion(continuation)
                timeoutQueue.asyncAfter(deadline: .now() + ReaderExtensionSecurityPolicy.operationTimeout) {
                    if completion.failTimedOut() {
                        nonDrainingLock.withReaderRuntimeLock { nonDrainingOperationCount += 1 }
                        // A timeout is routinely a slow origin, not tampering:
                        // each fetch may legally block 35s, so two slow
                        // responses cross the 60s watchdog. Block the digest
                        // for this session only — the durable marker deletes
                        // the executable and bricks the install until the
                        // user reinstalls.
                        quarantineForSessionOnly(quarantineKey)
                    }
                }
                queue.async {
                    defer {
                        if completion.wasTimedOut {
                            nonDrainingLock.withReaderRuntimeLock { nonDrainingOperationCount = max(0, nonDrainingOperationCount - 1) }
                        }
                        admissionLease.release()
                    }
                    guard !completion.isFinished else { return }
                    do {
                        let result = try run(
                            code: code,
                            source: source,
                            operation: operation,
                            network: network,
                            approvedDomains: approvedDomains,
                            preferenceStore: preferenceStore,
                            runtimeIdentity: runtimeIdentity
                        )
                        completion.succeed(result)
                    } catch {
                        if case ReaderExtensionError.runtimeIntegrityFailed = error {
                            // Publish quarantine before resuming the awaiting
                            // provider. Its rollback callback is intentionally
                            // asynchronous and persistence may fail, but this
                            // digest must become unusable immediately.
                            quarantine(quarantineKey)
                        }
                        completion.fail(error)
                    }
                }
            }
        }
    }

    static func clearQuarantine(sourceID: ReaderExtensionSourceID, digest: String) {
        let key = QuarantineKey(sourceID: sourceID, digest: digest.lowercased())
        do {
            try ReaderExtensionPersistence.clearRuntimeQuarantine(sourceID: sourceID, digest: digest)
            _ = quarantineLock.withReaderRuntimeLock { quarantinedDigests.remove(key) }
        } catch {
            // A stale marker is intentionally fail-closed. It can be retried
            // by a later verified replacement or removal.
        }
    }

    static func clearQuarantineAfterVerifiedReplacementOrRemoval(
        sourceIDs: Set<ReaderExtensionSourceID>,
        retaining referencedEntries: Set<ReaderExtensionRuntimeQuarantineEntry>
    ) {
        guard !sourceIDs.isEmpty else { return }
        let processEntries = quarantineLock.withReaderRuntimeLock {
            Set(quarantinedDigests.map {
                ReaderExtensionRuntimeQuarantineEntry(sourceID: $0.sourceID, digest: $0.digest)
            })
        }
        guard let durableEntries = try? ReaderExtensionPersistence.runtimeQuarantineEntries() else {
            return
        }
        let candidates = ReaderExtensionRuntimeQuarantineClearPolicy.eligibleEntries(
            available: durableEntries.union(processEntries),
            sourceIDs: sourceIDs,
            referenced: referencedEntries
        )
        for entry in candidates {
            do {
                try ReaderExtensionPersistence.clearRuntimeQuarantine(
                    sourceID: entry.sourceID,
                    digest: entry.digest
                )
                let key = QuarantineKey(sourceID: entry.sourceID, digest: entry.digest)
                _ = quarantineLock.withReaderRuntimeLock { quarantinedDigests.remove(key) }
            } catch {
                // Clear each exact unreferenced pair independently. A failed
                // durable removal leaves its process marker in place, and a
                // marker still referenced by any profile is never attempted.
            }
        }
    }

    private static func quarantineForSessionOnly(_ key: QuarantineKey) {
        _ = quarantineLock.withReaderRuntimeLock { quarantinedDigests.insert(key) }
    }

    private static func quarantine(_ key: QuarantineKey) {
        _ = quarantineLock.withReaderRuntimeLock { quarantinedDigests.insert(key) }
        // This checkpoint is deliberately independent of installed-source
        // metadata. A failed rollback transaction therefore cannot make the
        // bad source+digest pair executable after relaunch.
        let durable = ReaderExtensionRuntimeQuarantineDurability.enforce(
            persistMarker: {
                try ReaderExtensionPersistence.markRuntimeQuarantined(
                    sourceID: key.sourceID,
                    digest: key.digest
                )
            },
            removeExactExecutable: {
                let contentStore = try ReaderExtensionContentStore()
                try contentStore.removeExecutable(digest: key.digest)
            }
        )
        if !durable {
            quarantineLock.withReaderRuntimeLock { quarantineDurabilityUnavailable = true }
        }
    }

#if DEBUG
    static func declaredPreferenceDefaultsForTesting(
        rawJSON: String
    ) -> [String: ReaderExtensionPreferenceValue]? {
        guard let rows = ReaderExtensionJavaScriptPreferenceSchema.decodeRows(rawJSON) else { return nil }
        return ReaderExtensionJavaScriptPreferenceSchema.defaults(from: rows)
    }

    static func setQuarantinedForTesting(
        _ quarantined: Bool,
        sourceID: ReaderExtensionSourceID,
        digest: String
    ) {
        let key = QuarantineKey(sourceID: sourceID, digest: digest.lowercased())
        quarantineLock.withReaderRuntimeLock {
            if quarantined { quarantinedDigests.insert(key) }
            else { quarantinedDigests.remove(key) }
        }
        if !quarantined {
            try? ReaderExtensionPersistence.clearRuntimeQuarantine(
                sourceID: sourceID,
                digest: digest
            )
        }
    }

    static func setNonDrainingOperationCountForTesting(_ count: Int) {
        nonDrainingLock.withReaderRuntimeLock {
            nonDrainingOperationCount = max(0, count)
        }
    }

    static func setQuarantineDurabilityUnavailableForTesting(_ unavailable: Bool) {
        quarantineLock.withReaderRuntimeLock { quarantineDurabilityUnavailable = unavailable }
    }
#endif

    static func date(_ raw: Any?) -> Date? {
        if let number = raw as? NSNumber {
            let value = number.doubleValue
            return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1_000 : value)
        }
        if let value = raw as? String {
            if let number = TimeInterval(value) { return Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1_000 : number) }
            return ISO8601DateFormatter().date(from: value)
        }
        return nil
    }

    private static func providerQueue(_ id: ReaderExtensionSourceID) -> DispatchQueue {
        queueLock.withReaderRuntimeLock {
            if let existing = queues[id] { return existing }
            let queue = DispatchQueue(label: "app.eclipse.reader-extensions.runtime.\(id.rawValue.prefix(12))", qos: .userInitiated)
            queues[id] = queue
            return queue
        }
    }

    private static func run(
        code: String,
        source: ReaderExtensionInstalledSource,
        operation: ReaderExtensionJavaScriptOperation,
        network: ReaderExtensionNetworkClient,
        approvedDomains: Set<String>,
        preferenceStore: ReaderExtensionPreferenceStore,
        runtimeIdentity: ReaderExtensionLanguageCompatibilityPolicy.RuntimeIdentity
    ) throws -> Data {
        guard let context = JSContext() else { throw ReaderExtensionError.runtimeUnavailable }
        let dom = ReaderExtensionDOMBridge(baseURL: source.baseURL)
        let fetchBudget = ReaderExtensionFetchBudget()
        let timerHost = ReaderExtensionRuntimeTimerHost()
        defer { timerHost.cancelAll() }
        var exceptionRaised = false
        context.exceptionHandler = { _, _ in exceptionRaised = true }
        configureBridges(context, source: source, network: network, approvedDomains: approvedDomains, preferenceStore: preferenceStore, dom: dom, fetchBudget: fetchBudget, timerHost: timerHost)
        context.evaluateScript(hostPrelude(source: source, runtimeIdentity: runtimeIdentity))
        guard !exceptionRaised else { throw ReaderExtensionError.runtimeIntegrityFailed("host initialization") }
        context.evaluateScript(lockdownScript)
        guard !exceptionRaised else { throw ReaderExtensionError.runtimeIntegrityFailed("sandbox initialization") }
        context.evaluateScript(code)
        guard !exceptionRaised else { throw ReaderExtensionError.runtimeIntegrityFailed("source initialization") }
        context.evaluateScript("var extensionInstance = new DefaultExtension();")
        guard !exceptionRaised else { throw ReaderExtensionError.runtimeIntegrityFailed("source bootstrap") }
        let invocation = """
        var __readerDone = false;
        var __readerResult = null;
        var __readerFailed = false;
        var __readerFailurePhase = null;
        var __readerFailureMessage = null;
        var __readerOperationStarted = false;
        Promise.resolve(__readerInitializePreferenceDefaults()).then(async function() {
          __readerOperationStarted = true;
          return await (\(operation.expression));
        }).then(function(value) {
          __readerResult = JSON.stringify(value);
          __readerDone = true;
        }).catch(function(error) {
          __readerFailurePhase = __readerOperationStarted ? 'operation' : 'preference-schema';
          __readerFailureMessage = String(error && error.message !== undefined ? error.message : error);
          __readerFailed = true;
          __readerDone = true;
        });
        """
        context.evaluateScript(invocation)
        guard !exceptionRaised else { throw ReaderExtensionError.runtimeFailed("source operation failed") }
        // The outer admission watchdog owns timeout/quarantine semantics. Keep
        // this promise pump just inside that bound so valid Mangayomi methods
        // can sequence multiple awaited requests instead of failing at 2s.
        let deadline = Date().addingTimeInterval(
            max(1, ReaderExtensionSecurityPolicy.operationTimeout - 1)
        )
        while context.objectForKeyedSubscript("__readerDone")?.toBool() != true && Date() < deadline {
            context.evaluateScript("void 0")
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        guard context.objectForKeyedSubscript("__readerDone")?.toBool() == true else {
            throw ReaderExtensionError.runtimeFailed("source promise did not settle")
        }
        if context.objectForKeyedSubscript("__readerFailed")?.toBool() == true {
            if context.objectForKeyedSubscript("__readerFailurePhase")?.toString() == "preference-schema" {
                throw ReaderExtensionError.runtimeIntegrityFailed("preference schema initialization")
            }
            if let message = context.objectForKeyedSubscript("__readerFailureMessage")?.toString(),
               !message.isEmpty {
                // The provider-controlled message never reaches logs. The
                // classification below is derived from static host strings and
                // engine-generated TypeError shapes only, so a failure keeps
                // enough attribution to distinguish "the sandbox refused a
                // fetch" from "the page did not match the source's selectors".
                ReaderLogger.shared.log(
                    "JavaScript source operation rejected source=\(source.id.rawValue.prefix(12)) reason=\(Self.classifyFailureMessage(message)); provider message omitted",
                    type: "ReaderSandbox"
                )
                let consentPrefix = "This source needs permission to contact "
                if message.hasPrefix(consentPrefix), message.hasSuffix(".") {
                    let rawHost = String(message.dropFirst(consentPrefix.count).dropLast())
                    if let host = ReaderExtensionSecurityPolicy.canonicalHost(rawHost) {
                        throw ReaderExtensionError.domainConsentRequired(host)
                    }
                }
                let verificationSuffix = " is asking for a browser verification check."
                if message.hasSuffix(verificationSuffix) {
                    let rawHost = String(message.dropLast(verificationSuffix.count))
                    if let host = ReaderExtensionSecurityPolicy.canonicalHost(rawHost) {
                        throw ReaderExtensionError.browserVerificationRequired(host)
                    }
                }
            }
            throw ReaderExtensionError.runtimeFailed("source operation rejected")
        }
        guard let json = context.objectForKeyedSubscript("__readerResult")?.toString(),
              let data = json.data(using: .utf8), data.count <= ReaderExtensionSecurityPolicy.maximumDOMBytes else {
            throw ReaderExtensionError.runtimeFailed("source operation rejected")
        }
        return data
    }

    private static func classifyFailureMessage(_ message: String) -> String {
        let hostRefusals: [(ReaderExtensionError, String)] = [
            (.contentTooLarge, "host-content-too-large"),
            (.insecureURL, "host-url-refused"),
            (.privateNetworkDestination, "host-private-network-refused"),
            (.runtimeTimedOut, "host-timeout")
        ]
        for (error, label) in hostRefusals where message == error.localizedDescription {
            return label
        }
        if message == "Reader extension network request failed" { return "host-network-error" }
        if message.hasPrefix("This source needs permission to contact ") { return "domain-consent" }
        let lowered = message.lowercased()
        if lowered.contains("is not an object") || lowered.contains("is not a function")
            || lowered.contains("undefined is not") || lowered.contains("null is not")
            || lowered.contains("cannot read propert") {
            return "selector-mismatch-or-provider-bug"
        }
        return "provider-reported-error"
    }

    private static func configureBridges(
        _ context: JSContext,
        source: ReaderExtensionInstalledSource,
        network: ReaderExtensionNetworkClient,
        approvedDomains: Set<String>,
        preferenceStore: ReaderExtensionPreferenceStore,
        dom: ReaderExtensionDOMBridge,
        fetchBudget: ReaderExtensionFetchBudget,
        timerHost: ReaderExtensionRuntimeTimerHost
    ) {
        let http: @convention(block) (String, String, String, String) -> String = { method, rawURL, rawHeaders, rawBody in
            do {
                guard fetchBudget.admit(), let url = ReaderExtensionMangayomiURLParser.url(rawURL, relativeTo: source.baseURL) else {
                    throw ReaderExtensionError.contentTooLarge
                }
                let headerData = Data(rawHeaders.utf8)
                try ReaderExtensionJSONPreflight.validate(headerData, limits: .init(
                    maximumBytes: 64 * 1_024,
                    maximumDepth: 4,
                    maximumContainerEntries: ReaderExtensionSecurityPolicy.maximumHeaderCount,
                    maximumTotalTokens: ReaderExtensionSecurityPolicy.maximumHeaderCount * 2 + 4,
                    maximumStringBytes: ReaderExtensionSecurityPolicy.maximumHeaderBytes
                ))
                let headers = (try? JSONSerialization.jsonObject(with: headerData) as? [String: String]) ?? [:]
                let body = requestBody(rawBody, headers: headers)
                let request = ReaderExtensionNetworkRequest(
                    method: ReaderExtensionNetworkRequest.Method(rawValue: method.uppercased()) ?? .get,
                    url: url,
                    headers: headers,
                    body: body,
                    sourceID: source.id,
                    approvedDomains: approvedDomains,
                    baseDomain: source.baseURL.host
                )
                let response = try blockingRequest(network, request: request)
                guard fetchBudget.consume(response) else {
                    throw ReaderExtensionError.contentTooLarge
                }
                let object: [String: Any] = [
                    "body": response.bodyString,
                    "headers": response.headers,
                    "isRedirect": response.finalURL != url,
                    "persistentConnection": false,
                    "reasonPhrase": HTTPURLResponse.localizedString(forStatusCode: response.statusCode),
                    "statusCode": response.statusCode,
                    "request": [
                        "method": method.uppercased(),
                        "url": response.finalURL.absoluteString,
                        "headers": response.extensionVisibleRequestHeaders
                    ]
                ]
                return jsonString(object, fallback: "{}")
            } catch let error as ReaderExtensionError {
                if let context = JSContext.current() { context.exception = JSValue(newErrorFromMessage: error.localizedDescription, in: context) }
                return "{}"
            } catch {
                if let context = JSContext.current() { context.exception = JSValue(newErrorFromMessage: "Reader extension network request failed", in: context) }
                return "{}"
            }
        }
        context.setObject(http, forKeyedSubscript: "__readerHTTP" as NSString)

        let validatedPreferenceDefaults: @convention(block) (String) -> String = { rawJSON in
            guard let rows = ReaderExtensionJavaScriptPreferenceSchema.decodeRows(rawJSON) else { return "" }
            let object = ReaderExtensionJavaScriptPreferenceSchema.defaults(from: rows)
                .mapValues(\.jsonObject)
            return jsonString(object, fallback: "")
        }
        context.setObject(validatedPreferenceDefaults, forKeyedSubscript: "__readerValidatedPreferenceDefaults" as NSString)

        let readPreference: (String, String) -> String = { key, fallback in
            guard key.utf8.count <= 256 else { return fallback }
            let persistedValue = preferenceStore.value(for: key).flatMap { value -> ReaderExtensionPreferenceValue? in
                // A secretReference is only a metadata marker. If its Keychain
                // entry was cleared, it must never become the literal value.
                value.isSecret ? nil : value
            }
            let secretValue = preferenceStore.mayReadSecret(key)
                ? (try? preferenceStore.secret(for: key)).flatMap { $0 }.map(ReaderExtensionPreferenceValue.string)
                : nil
            let value = secretValue
                ?? persistedValue
            return value.map { jsonFragmentString($0.jsonObject, fallback: fallback) } ?? fallback
        }
        let preferenceGet: @convention(block) (String, String) -> String = { key, fallback in
            readPreference(key, fallback)
        }
        context.setObject(preferenceGet, forKeyedSubscript: "__readerPreferenceGet" as NSString)
        let preferenceStringGet: @convention(block) (String, String) -> String = { key, fallback in
            readPreference(key, fallback)
        }
        context.setObject(preferenceStringGet, forKeyedSubscript: "__readerPreferenceStringGet" as NSString)

        let preferenceSet: @convention(block) (String, String) -> Bool = { key, raw in
            guard key.utf8.count <= 256,
                  let data = raw.data(using: .utf8),
                  data.count <= ReaderExtensionSecurityPolicy.maximumPreferenceValueBytes + 1_024,
                  (try? ReaderExtensionJSONPreflight.validate(data, limits: .init(
                    maximumBytes: ReaderExtensionSecurityPolicy.maximumPreferenceValueBytes + 1_024,
                    maximumDepth: 8,
                    maximumContainerEntries: ReaderExtensionSecurityPolicy.maximumPreferenceListCount,
                    maximumTotalTokens: 1_000
                  ))) != nil,
                  let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return false }
            do {
                if preferenceStore.shouldStoreAsSecret(key) {
                    try preferenceStore.setSecret(String(describing: value), for: key)
                } else {
                    try preferenceStore.setValue(.string(String(describing: value)), for: key)
                }
                return true
            } catch { return false }
        }
        context.setObject(preferenceSet, forKeyedSubscript: "__readerPreferenceSet" as NSString)

        let parseHTML: @convention(block) (String) -> Int32 = { Int32(dom.parse($0)) }
        let select: @convention(block) (Int32, String) -> [Int32] = { dom.select(Int($0), selector: $1).map(Int32.init) }
        let string: @convention(block) (Int32, String) -> String = { dom.string(Int($0), property: $1) }
        let attribute: @convention(block) (Int32, String) -> String = { dom.attribute(Int($0), name: $1) }
        let sibling: @convention(block) (Int32, Bool) -> Int32 = { Int32(dom.sibling(Int($0), next: $1)) }
        let children: @convention(block) (Int32) -> [Int32] = { dom.children(Int($0)).map(Int32.init) }
        let parent: @convention(block) (Int32) -> Int32 = { Int32(dom.parent(Int($0))) }
        context.setObject(parseHTML, forKeyedSubscript: "__readerParseHTML" as NSString)
        context.setObject(select, forKeyedSubscript: "__readerDOMSelect" as NSString)
        context.setObject(string, forKeyedSubscript: "__readerDOMString" as NSString)
        context.setObject(attribute, forKeyedSubscript: "__readerDOMAttribute" as NSString)
        context.setObject(sibling, forKeyedSubscript: "__readerDOMSibling" as NSString)
        context.setObject(children, forKeyedSubscript: "__readerDOMChildren" as NSString)
        context.setObject(parent, forKeyedSubscript: "__readerDOMParent" as NSString)

        let scheduleTimer: @convention(block) (Int32, Double, Bool) -> Bool = { [weak context] identifier, milliseconds, repeats in
            timerHost.schedule(identifier: identifier, milliseconds: milliseconds, repeats: repeats) { firedIdentifier in
                _ = context?.evaluateScript("__readerFireTimer(\(firedIdentifier))")
            }
        }
        context.setObject(scheduleTimer, forKeyedSubscript: "__readerScheduleTimer" as NSString)
        let cancelTimer: @convention(block) (Int32) -> Void = { timerHost.cancel(identifier: $0) }
        context.setObject(cancelTimer, forKeyedSubscript: "__readerCancelTimer" as NSString)

        let base64Encode: @convention(block) (String) -> String = { input in
            guard input.utf8.count <= ReaderExtensionSecurityPolicy.maximumDOMBytes else { return "" }
            var bytes: [UInt8] = []
            bytes.reserveCapacity(input.unicodeScalars.count)
            for scalar in input.unicodeScalars {
                guard scalar.value <= 0xff else {
                    if let context = JSContext.current() {
                        context.exception = JSValue(newErrorFromMessage: "btoa input contains characters outside Latin-1", in: context)
                    }
                    return ""
                }
                bytes.append(UInt8(scalar.value))
            }
            return Data(bytes).base64EncodedString()
        }
        context.setObject(base64Encode, forKeyedSubscript: "__readerBase64Encode" as NSString)
        let base64Decode: @convention(block) (String) -> String = { input in
            guard input.utf8.count <= ReaderExtensionSecurityPolicy.maximumDOMBytes,
                  let data = Data(base64Encoded: input, options: [.ignoreUnknownCharacters]) else {
                if let context = JSContext.current() {
                    context.exception = JSValue(newErrorFromMessage: "atob input is not valid base64", in: context)
                }
                return ""
            }
            return String(data.map { Character(UnicodeScalar($0)) })
        }
        context.setObject(base64Decode, forKeyedSubscript: "__readerBase64Decode" as NSString)

        let crypto: @convention(block) (String, String, String, Bool) -> String = { text, iv, key, encrypt in
            aesCBC(text: text, iv: iv, key: key, encrypt: encrypt) ?? text
        }
        context.setObject(crypto, forKeyedSubscript: "__readerCryptoHandler" as NSString)
    }

    private static func blockingRequest(_ network: ReaderExtensionNetworkClient, request: ReaderExtensionNetworkRequest) throws -> ReaderExtensionNetworkResponse {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ReaderExtensionBlockingResponse()
        Task.detached {
            do { box.set(.success(try await network.request(request))) }
            catch { box.set(.failure(error)) }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 35) == .success else { throw ReaderExtensionError.runtimeTimedOut }
        return try box.result.get()
    }

    private static func requestBody(_ raw: String, headers: [String: String]) -> Data? {
        guard raw != "null", !raw.isEmpty,
              let data = raw.data(using: .utf8),
              data.count <= ReaderExtensionSecurityPolicy.maximumRequestBodyBytes else { return nil }
        if headers.first(where: { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame })?.value.lowercased().contains("application/json") == true { return data }
        let structurallyBounded = (try? ReaderExtensionJSONPreflight.validate(data, limits: .init(
            maximumBytes: ReaderExtensionSecurityPolicy.maximumRequestBodyBytes,
            maximumContainerEntries: 1_000,
            maximumTotalTokens: 10_000
        ))) != nil
        if structurallyBounded, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            var components = URLComponents()
            components.queryItems = object.map { URLQueryItem(name: $0.key, value: String(describing: $0.value)) }
            return components.percentEncodedQuery?.data(using: .utf8)
        }
        if structurallyBounded, let value = try? JSONDecoder().decode(String.self, from: data) { return Data(value.utf8) }
        return data
    }

    private static func jsonString(_ object: Any, fallback: String) -> String {
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object), data.count <= ReaderExtensionSecurityPolicy.maximumResponseBytes, let value = String(data: data, encoding: .utf8) else { return fallback }
        return value
    }

    private static func jsonFragmentString(_ object: Any, fallback: String) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.fragmentsAllowed]
        ),
        data.count <= ReaderExtensionSecurityPolicy.maximumPreferenceValueBytes + 1_024,
        let value = String(data: data, encoding: .utf8) else { return fallback }
        return value
    }

    private static func aesCBC(text: String, iv: String, key: String, encrypt: Bool) -> String? {
        let input = encrypt ? Data(text.utf8) : Data(base64Encoded: text)
        guard let input, [16, 24, 32].contains(key.utf8.count), iv.utf8.count == kCCBlockSizeAES128 else { return nil }
        let keyData = Data(key.utf8), ivData = Data(iv.utf8)
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { outBytes in
            input.withUnsafeBytes { inBytes in
                keyData.withUnsafeBytes { keyBytes in
                    ivData.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress, keyData.count, ivBytes.baseAddress, inBytes.baseAddress, input.count, outBytes.baseAddress, outputCapacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        output.removeSubrange(moved..<output.count)
        return encrypt ? output.base64EncodedString() : String(data: output, encoding: .utf8)
    }

    private static func hostPrelude(
        source: ReaderExtensionInstalledSource,
        runtimeIdentity: ReaderExtensionLanguageCompatibilityPolicy.RuntimeIdentity
    ) -> String {
        let sourceObject: [String: Any] = [
            "id": runtimeIdentity.upstreamID,
            "name": source.name,
            "baseUrl": source.baseURL.absoluteString,
            "apiUrl": source.apiURL?.absoluteString ?? "",
            "lang": runtimeIdentity.language,
            "isNsfw": source.maturity == .mature,
            "itemType": source.mediaType == .novel ? 2 : 0,
            "additionalParams": source.additionalParameters ?? "",
            "dateFormat": source.dateFormat ?? "",
            "dateFormatLocale": source.dateFormatLocale ?? ""
        ]
        let sourceJSON = jsonString(sourceObject, fallback: "{}")
        return """
        class MProvider {
          get source() { return \(sourceJSON); }
          get supportsLatest() { return true; }
          getHeaders(url) { return {}; }
          async getPopular(page) { throw new Error('not implemented'); }
          async getLatestUpdates(page) { throw new Error('not implemented'); }
          async search(query, page, filters) { throw new Error('not implemented'); }
          async getDetail(url) { throw new Error('not implemented'); }
          async getPageList(url) { throw new Error('not implemented'); }
          async getHtmlContent(name, url) { throw new Error('not implemented'); }
          async cleanHtmlContent(html) { return html; }
          getFilterList() { return []; }
          getSourcePreferences() { return []; }
        }
        const __readerFunctionToString = Function.prototype.toString;
        function __readerOptionalNotImplemented(error, name) {
          const message = String(error && error.message !== undefined ? error.message : error).trim().toLowerCase();
          const normalizedName = String(name).toLowerCase();
          return message === normalizedName + ' not implemented'
            || message === normalizedName + '() not implemented'
            || message === normalizedName + ' not implemented.'
            || message === normalizedName + '() not implemented.';
        }
        function __readerIsExactOptionalStub(name) {
          const method = extensionInstance[name];
          if (typeof method !== 'function') return false;
          const source = __readerFunctionToString.call(method);
          const open = source.indexOf('{');
          const close = source.lastIndexOf('}');
          if (open < 0 || close <= open) return false;
          let body = source.slice(open + 1, close).replace(/\\s+/g, ' ').trim();
          if (body.endsWith(';')) body = body.slice(0, -1).trim();
          const messages = [
            name + ' not implemented', name + '() not implemented',
            name + ' not implemented.', name + '() not implemented.'
          ];
          return messages.some(function(message) {
            return body === "throw new Error('" + message + "')"
              || body === 'throw new Error("' + message + '")'
              || body === "throw Error('" + message + "')"
              || body === 'throw Error("' + message + '")';
          });
        }
        async function __readerInvokeOptional(name, args, fallback) {
          try {
            return await Promise.resolve(extensionInstance[name].apply(extensionInstance, args));
          } catch (error) {
            if (__readerOptionalNotImplemented(error, name)) return fallback;
            throw error;
          }
        }
        class Client {
          constructor(options) { this.options = options || {}; }
          async __send(method, url, headers, body) { return JSON.parse(__readerHTTP(method, String(url), JSON.stringify(headers || {}), JSON.stringify(body === undefined ? null : body))); }
          async head(url, headers) { return this.__send('HEAD', url, headers); }
          async get(url, headers) { return this.__send('GET', url, headers); }
          async post(url, headers, body) { return this.__send('POST', url, headers, body); }
          async put(url, headers, body) { return this.__send('PUT', url, headers, body); }
          async patch(url, headers, body) { return this.__send('PATCH', url, headers, body); }
          async delete(url, headers, body) { return this.__send('DELETE', url, headers, body); }
        }
        class SharedPreferences {
          get(key, defaultValue) {
            const normalizedKey = String(key);
            const hasDeclaredDefault = Object.prototype.hasOwnProperty.call(__readerPreferenceDefaults, normalizedKey);
            const fallbackValue = hasDeclaredDefault
              ? __readerPreferenceDefaults[normalizedKey]
              : (defaultValue === undefined ? null : defaultValue);
            return JSON.parse(__readerPreferenceGet(normalizedKey, JSON.stringify(fallbackValue)));
          }
          getString(key, defaultValue) { const fallback = JSON.stringify(defaultValue === undefined ? '' : String(defaultValue)); const value = JSON.parse(__readerPreferenceStringGet(String(key), fallback)); return value === null || value === undefined ? defaultValue : String(value); }
          setString(key, value) { return __readerPreferenceSet(String(key), JSON.stringify(String(value))); }
        }
        var __readerPreferenceRows = [];
        var __readerPreferenceDefaults = Object.create(null);
        var __readerPreferenceDefaultsReady = false;
        var __readerPreferencesImplemented = false;
        async function __readerInitializePreferenceDefaults() {
          if (__readerPreferenceDefaultsReady) return __readerPreferenceRows;
          const differs = typeof extensionInstance.getSourcePreferences === 'function'
            && extensionInstance.getSourcePreferences !== MProvider.prototype.getSourcePreferences;
          let rows = [];
          if (differs) {
            try {
              const candidate = await Promise.resolve(extensionInstance.getSourcePreferences());
              rows = Array.isArray(candidate) ? candidate.slice(0, 200) : [];
              __readerPreferencesImplemented = true;
            } catch (error) {
              const message = String(error && error.message !== undefined ? error.message : error).trim();
              if (!/^getSourcePreferences(?:\\(\\))?\\s+not implemented[.!]?$/i.test(message)) throw error;
            }
          }
          const serialized = JSON.stringify(rows);
          const normalizedDefaultsJSON = typeof serialized === 'string'
            ? __readerValidatedPreferenceDefaults(serialized)
            : '';
          if (typeof normalizedDefaultsJSON !== 'string' || normalizedDefaultsJSON.length === 0) {
            throw new Error('invalid or oversized source preference schema');
          }
          const normalizedDefaults = JSON.parse(normalizedDefaultsJSON);
          if (normalizedDefaults === null || typeof normalizedDefaults !== 'object' || Array.isArray(normalizedDefaults)) {
            throw new Error('invalid source preference defaults');
          }
          __readerPreferenceDefaults = normalizedDefaults;
          __readerPreferenceRows = rows;
          __readerPreferenceDefaultsReady = true;
          return __readerPreferenceRows;
        }
        class Element {
          constructor(handle) { this.__handle = Number(handle || 0); }
          // The audited Mangayomi bridge returns an Element from every
          // single-element lookup even when nothing matched, and its string
          // accessors answer "" for the missing element. Extensions rely on
          // it: WeebCentral probes pagination as selectFirst('button').text
          // on pages that legitimately have no button.
          select(selector) { return __readerDOMSelect(this.__handle, String(selector)).map(id => new Element(id)); }
          selectFirst(selector) { const values = this.select(selector); return values.length ? values[0] : new Element(0); }
          attr(name) { return __readerDOMAttribute(this.__handle, String(name)); }
          hasAttr(name) { return this.attr(name) !== ''; }
          get text() { return __readerDOMString(this.__handle, 'text'); }
          get innerHtml() { return __readerDOMString(this.__handle, 'innerHtml'); }
          get outerHtml() { return __readerDOMString(this.__handle, 'outerHtml'); }
          get className() { return __readerDOMString(this.__handle, 'className'); }
          get getHref() { return this.attr('href'); }
          get getSrc() { return this.attr('src') || this.attr('data-src') || this.attr('data-lazy-src'); }
          get children() { return __readerDOMChildren(this.__handle).map(id => new Element(id)); }
          get nextElementSibling() { return new Element(__readerDOMSibling(this.__handle, true)); }
          get previousElementSibling() { return new Element(__readerDOMSibling(this.__handle, false)); }
          get parent() { return new Element(__readerDOMParent(this.__handle)); }
          getElementById(id) { return this.selectFirst('#' + String(id)); }
          getElementsByClassName(name) { return this.select('.' + String(name)); }
          getElementsByTagName(name) { return this.select(String(name)); }
        }
        class Document extends Element {
          constructor(html) {
            const rawHTML = String(html);
            super(__readerParseHTML(rawHTML));
            // Mangayomi's audited Document contract exposes the exact input
            // string, not a normalized SwiftSoup serialization.
            this.html = rawHTML;
          }
        }
        String.prototype.substringAfter = function(pattern) { const i = this.indexOf(pattern); return i < 0 ? String(this) : this.substring(i + String(pattern).length); };
        String.prototype.substringAfterLast = function(pattern) { const i = this.lastIndexOf(pattern); return i < 0 ? String(this) : this.substring(i + String(pattern).length); };
        String.prototype.substringBefore = function(pattern) { const i = this.indexOf(pattern); return i < 0 ? String(this) : this.substring(0, i); };
        String.prototype.substringBeforeLast = function(pattern) { const i = this.lastIndexOf(pattern); return i < 0 ? String(this) : this.substring(0, i); };
        function substringAfter(value, pattern) { return String(value).substringAfter(pattern); }
        function substringAfterLast(value, pattern) { return String(value).substringAfterLast(pattern); }
        function substringBefore(value, pattern) { return String(value).substringBefore(pattern); }
        function substringBeforeLast(value, pattern) { return String(value).substringBeforeLast(pattern); }
        function cryptoHandler(text, iv, key, encrypt) { return __readerCryptoHandler(String(text), String(iv), String(key), Boolean(encrypt)); }
        var __readerTimerCallbacks = Object.create(null);
        var __readerTimerSequence = 1;
        function __readerFireTimer(id) {
          const entry = __readerTimerCallbacks[id];
          if (!entry) return;
          if (!entry.repeats) delete __readerTimerCallbacks[id];
          if (typeof entry.callback === 'function') entry.callback.apply(undefined, entry.args);
        }
        function __readerRegisterTimer(callback, delay, repeats, args) {
          const id = __readerTimerSequence++;
          __readerTimerCallbacks[id] = { callback: callback, args: args, repeats: repeats };
          if (!__readerScheduleTimer(id, Number(delay) || 0, repeats)) {
            delete __readerTimerCallbacks[id];
            return 0;
          }
          return id;
        }
        function setTimeout(callback, delay) { return __readerRegisterTimer(callback, delay, false, Array.prototype.slice.call(arguments, 2)); }
        function setInterval(callback, delay) { return __readerRegisterTimer(callback, delay, true, Array.prototype.slice.call(arguments, 2)); }
        function clearTimeout(id) { delete __readerTimerCallbacks[id]; __readerCancelTimer(Number(id) || 0); }
        function clearInterval(id) { clearTimeout(id); }
        function atob(input) { return __readerBase64Decode(String(input)); }
        function btoa(input) { return __readerBase64Encode(String(input)); }
        class TextEncoder {
          get encoding() { return 'utf-8'; }
          encode(input) {
            const escaped = unescape(encodeURIComponent(input === undefined ? '' : String(input)));
            const bytes = new Uint8Array(escaped.length);
            for (let i = 0; i < escaped.length; i++) bytes[i] = escaped.charCodeAt(i);
            return bytes;
          }
        }
        class TextDecoder {
          constructor(label) {
            const normalized = (label === undefined ? 'utf-8' : String(label)).toLowerCase();
            if (normalized !== 'utf-8' && normalized !== 'utf8' && normalized !== 'unicode-1-1-utf-8') {
              throw new RangeError('unsupported TextDecoder encoding');
            }
          }
          get encoding() { return 'utf-8'; }
          decode(input) {
            if (input === undefined || input === null) return '';
            const bytes = input instanceof Uint8Array
              ? input
              : new Uint8Array(ArrayBuffer.isView(input) ? input.buffer : input);
            let escaped = '';
            for (let i = 0; i < bytes.length; i++) escaped += String.fromCharCode(bytes[i]);
            try { return decodeURIComponent(escape(escaped)); } catch (_) { return escaped; }
          }
        }
        function unpackJs(packedJS) {
          const source = String(packedJS);
          if (source.length > 1024 * 1024) return source;
          const match = source.match(/\\}\\s*\\(\\s*'((?:[^'\\\\]|\\\\.)*)'\\s*,\\s*(\\d+)\\s*,\\s*(\\d+)\\s*,\\s*'((?:[^'\\\\]|\\\\.)*)'\\s*\\.split\\('\\|'\\)/);
          if (!match) return source;
          const payload = match[1].replace(/\\\\'/g, "'").replace(/\\\\\\\\/g, '\\\\');
          const radix = parseInt(match[2], 10) || 36;
          const keywords = match[4].split('|');
          const alphabet = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'.slice(0, Math.max(2, Math.min(radix, 62)));
          function tokenIndex(token) {
            if (radix <= 36) { const value = parseInt(token, radix); return Number.isNaN(value) ? -1 : value; }
            let value = 0;
            for (const character of token) {
              const digit = alphabet.indexOf(character);
              if (digit < 0) return -1;
              value = value * radix + digit;
            }
            return value;
          }
          return payload.replace(/\\b[0-9a-zA-Z]+\\b/g, function(token) {
            const index = tokenIndex(token);
            if (index < 0 || index >= keywords.length) return token;
            return keywords[index] === '' ? token : keywords[index];
          });
        }
        console.log = console.warn = console.error = function() {};
        """
    }

    private static let lockdownScript = """
    (function() {
      const FunctionPrototype = Function.prototype;
      const AsyncFunction = Object.getPrototypeOf(async function(){}).constructor;
      const GeneratorFunction = Object.getPrototypeOf(function*(){}).constructor;
      const AsyncGeneratorFunction = Object.getPrototypeOf(async function*(){}).constructor;
      try { Object.defineProperty(FunctionPrototype, 'constructor', { value: undefined, writable: false, configurable: false }); } catch (_) {}
      try { Object.defineProperty(AsyncFunction.prototype, 'constructor', { value: undefined, writable: false, configurable: false }); } catch (_) {}
      try { Object.defineProperty(GeneratorFunction.prototype, 'constructor', { value: undefined, writable: false, configurable: false }); } catch (_) {}
      try { Object.defineProperty(AsyncGeneratorFunction.prototype, 'constructor', { value: undefined, writable: false, configurable: false }); } catch (_) {}
      try { Object.defineProperty(Reflect, 'construct', { value: undefined, writable: false, configurable: false }); } catch (_) {}
      Object.defineProperty(globalThis, 'eval', { value: undefined, writable: false, configurable: false });
      Object.defineProperty(globalThis, 'Function', { value: undefined, writable: false, configurable: false });
      Object.defineProperty(globalThis, 'WebAssembly', { value: undefined, writable: false, configurable: false });
    })();
    """
}

private enum ReaderExtensionDOMSelectorPreflight {
    private static let maximumBytes = 1_024
    private static let maximumNestingDepth = 8
    private static let maximumWorkTokens = 128
    // Every 18-digit unsigned decimal fits in the 64-bit Int used by supported
    // iOS devices. Longer runs are rejected before SwiftSoup force-unwraps its
    // positional pseudo-class integer conversion.
    private static let maximumDecimalRunLength = 18

    static func permits(_ selector: String) -> Bool {
        let bytes = Array(selector.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumBytes,
              !bytes.contains(where: { $0 == 0 || $0 < 0x09 }) else { return false }

        // SwiftSoup exposes NSRegularExpression through these selector forms.
        // Reader extensions do not need regular-expression selectors, and
        // admitting source-controlled patterns would move catastrophic regex
        // work outside JavaScriptCore's operation deadline.
        let compact = selector.lowercased().filter { !$0.isWhitespace }
        guard !compact.contains(":matches("),
              !compact.contains(":matchesown("),
              !compact.contains("~=") else { return false }

        var parentheses = 0
        var brackets = 0
        var quote: UInt8?
        var escaped = false
        var workTokens = 1
        var previousWasWhitespace = false
        var decimalRunLength = 0
        for byte in bytes {
            if let activeQuote = quote {
                if escaped { escaped = false; continue }
                if byte == 0x5c { escaped = true; continue }
                if byte == activeQuote { quote = nil }
                continue
            }
            if byte == 0x22 || byte == 0x27 {
                quote = byte
                decimalRunLength = 0
                continue
            }
            if (0x30...0x39).contains(byte) {
                decimalRunLength += 1
                guard decimalRunLength <= maximumDecimalRunLength else { return false }
            } else {
                decimalRunLength = 0
            }
            switch byte {
            case 0x28: // (
                parentheses += 1
                guard parentheses <= maximumNestingDepth else { return false }
                workTokens += 1
            case 0x29: // )
                guard parentheses > 0 else { return false }
                parentheses -= 1
            case 0x5b: // [
                brackets += 1
                guard brackets <= maximumNestingDepth else { return false }
                workTokens += 1
            case 0x5d: // ]
                guard brackets > 0 else { return false }
                brackets -= 1
            case 0x2c, 0x3e, 0x2b, 0x7e, 0x3a, 0x23, 0x2e, 0x2a: // , > + ~ : # . *
                workTokens += 1
            case 0x09, 0x0a, 0x0c, 0x0d, 0x20:
                if !previousWasWhitespace { workTokens += 1 }
                previousWasWhitespace = true
                guard workTokens <= maximumWorkTokens else { return false }
                continue
            default:
                break
            }
            previousWasWhitespace = false
            guard workTokens <= maximumWorkTokens else { return false }
        }
        return quote == nil && !escaped && parentheses == 0 && brackets == 0
    }
}

// Timers fire on the provider queue's run loop, which the operation's promise
// pump keeps spinning; everything here runs on that one thread. Delays are
// clamped so a source cannot park an operation past its watchdog for free.
final class ReaderExtensionRuntimeTimerHost {
    private static let maximumLiveTimers = 512
    private static let maximumDelayMilliseconds: Double = 30_000
    private var timers: [Int32: Timer] = [:]

    func schedule(
        identifier: Int32,
        milliseconds: Double,
        repeats: Bool,
        fire: @escaping (Int32) -> Void
    ) -> Bool {
        guard timers.count < Self.maximumLiveTimers else { return false }
        let clamped = min(max(milliseconds.isFinite ? milliseconds : 0, 0), Self.maximumDelayMilliseconds) / 1_000
        let timer = Timer(timeInterval: repeats ? max(clamped, 0.001) : clamped, repeats: repeats) { [weak self] _ in
            if !repeats { self?.timers.removeValue(forKey: identifier) }
            fire(identifier)
        }
        timers[identifier] = timer
        RunLoop.current.add(timer, forMode: .default)
        return true
    }

    func cancel(identifier: Int32) {
        timers.removeValue(forKey: identifier)?.invalidate()
    }

    func cancelAll() {
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()
    }
}

final class ReaderExtensionDOMBridge {
    private static let maximumBridgeCallsPerOperation = 65_536
    private static let maximumBridgeWorkUnitsPerOperation = 262_144
    private let baseURL: URL
    private var elements: [Int: Element] = [:]
    private var subtreeElementCountByHandle: [Int: Int] = [:]
    private var nextHandle = 1
    private var parsedInputBytes = 0
    private var retainedDocumentCount = 0
    private var returnedBytes = 0
    private var bridgeCalls = 0
    private var bridgeWorkUnits = 0

    init(baseURL: URL) { self.baseURL = baseURL }

    func parse(_ html: String) -> Int {
        let byteCount = html.utf8.count
        guard retainedDocumentCount < ReaderExtensionSecurityPolicy.maximumDOMDocumentsPerOperation,
              byteCount <= ReaderExtensionSecurityPolicy.maximumDOMBytes - parsedInputBytes,
              admitWork(1 + byteCount / 1_024) else { return 0 }
        // Count every admitted parse attempt. A malicious source cannot submit
        // many malformed documents just below the individual limit and make
        // SwiftSoup repeatedly allocate them outside the operation budget.
        parsedInputBytes += byteCount
        guard (try? ReaderExtensionHTMLPreflight.validate(
            html,
            maximumBytes: ReaderExtensionSecurityPolicy.maximumDOMBytes,
            maximumNodeTokens: ReaderExtensionSecurityPolicy.maximumDOMElementsPerDocument
        )) != nil else { return 0 }
        guard let document = try? SwiftSoup.parse(html, baseURL.absoluteString) else { return 0 }
        guard let elementCount = try? document.getAllElements().size(),
              elementCount <= ReaderExtensionSecurityPolicy.maximumDOMElementsPerDocument else { return 0 }
        // The audited DOM contract exposes the whole Document, not only body.
        // Several official extensions select <head> metadata and <title>.
        let handle = store(document)
        if handle != 0 {
            retainedDocumentCount += 1
            subtreeElementCountByHandle[handle] = max(1, elementCount)
        }
        return handle
    }

    func select(_ handle: Int, selector: String) -> [Int] {
        guard ReaderExtensionDOMSelectorPreflight.permits(selector),
              let root = elements[handle],
              admitTraversal(of: root, handle: handle),
              let selected = try? root.select(selector).array() else { return [] }
        return selected.prefix(ReaderExtensionSecurityPolicy.maximumDOMSelectedRows).compactMap {
            let handle = store($0)
            return handle == 0 ? nil : handle
        }
    }

    func string(_ handle: Int, property: String) -> String {
        // Check the aggregate output budget before asking SwiftSoup to traverse
        // and serialize a retained document. boundedOutput remains the exact
        // byte authority after serialization.
        guard returnedBytes < ReaderExtensionSecurityPolicy.maximumDOMReturnedBytesPerOperation,
              let element = elements[handle],
              admitTraversal(of: element, handle: handle) else { return "" }
        let value: String
        switch property {
        case "text": value = (try? element.text()) ?? ""
        case "innerHtml": value = (try? element.html()) ?? ""
        case "outerHtml": value = (try? element.outerHtml()) ?? ""
        case "className": value = (try? element.className()) ?? ""
        default: value = ""
        }
        return boundedOutput(value, perCallMaximum: 512 * 1_024)
    }

    func attribute(_ handle: Int, name: String) -> String {
        guard returnedBytes < ReaderExtensionSecurityPolicy.maximumDOMReturnedBytesPerOperation,
              name.utf8.count <= 128,
              let element = elements[handle],
              admitWork(1) else { return "" }
        return boundedOutput((try? element.attr(name)) ?? "", perCallMaximum: 64 * 1_024)
    }

    func sibling(_ handle: Int, next: Bool) -> Int {
        guard let element = elements[handle],
              admitWork(1),
              let sibling = try? (next ? element.nextElementSibling() : element.previousElementSibling()) else { return 0 }
        return store(sibling)
    }

    func parent(_ handle: Int) -> Int {
        guard let element = elements[handle],
              admitWork(1),
              let parent = element.parent() else { return 0 }
        return store(parent)
    }

    func children(_ handle: Int) -> [Int] {
        guard let element = elements[handle],
              admitWork(max(1, element.children().size())) else { return [] }
        return element.children().array().prefix(ReaderExtensionSecurityPolicy.maximumDOMSelectedRows).compactMap {
            let handle = store($0)
            return handle == 0 ? nil : handle
        }
    }

    private func store(_ element: Element) -> Int {
        guard elements.count < ReaderExtensionSecurityPolicy.maximumDOMHandlesPerOperation else { return 0 }
        let handle = nextHandle
        nextHandle += 1
        elements[handle] = element
        return handle
    }

    // Traversal-shaped work (select, text serialization) is charged at the
    // receiver's true subtree element count instead of an inherited estimate.
    // The previous model priced every selected row at the whole document's
    // size, which exhausted the budget after ~9 rows of an ordinary 32-row
    // catalog page and broke real sources mid-loop.
    private func admitTraversal(of element: Element, handle: Int) -> Bool {
        if let cached = subtreeElementCountByHandle[handle] {
            return admitWork(cached)
        }
        let remaining = Self.maximumBridgeWorkUnitsPerOperation - bridgeWorkUnits
        guard remaining > 0 else { return false }
        guard let count = boundedSubtreeElementCount(element, limit: remaining) else {
            // The aborted walk consumed the remaining budget's worth of CPU;
            // charge exactly that so refused calls cannot repeat it for free.
            bridgeWorkUnits = Self.maximumBridgeWorkUnitsPerOperation
            return false
        }
        subtreeElementCountByHandle[handle] = count
        return admitWork(count)
    }

    private func boundedSubtreeElementCount(_ element: Element, limit: Int) -> Int? {
        var count = 1
        guard count <= limit else { return nil }
        var stack = element.children().array()
        while let next = stack.popLast() {
            count += 1
            guard count <= limit else { return nil }
            stack.append(contentsOf: next.children().array())
        }
        return count
    }

    private func admitWork(_ units: Int) -> Bool {
        guard units > 0,
              bridgeCalls < Self.maximumBridgeCallsPerOperation,
              units <= Self.maximumBridgeWorkUnitsPerOperation - bridgeWorkUnits else { return false }
        bridgeCalls += 1
        bridgeWorkUnits += units
        return true
    }

    private func boundedOutput(_ value: String, perCallMaximum: Int) -> String {
        let remaining = ReaderExtensionSecurityPolicy.maximumDOMReturnedBytesPerOperation - returnedBytes
        guard remaining > 0 else { return "" }
        let output = ReaderExtensionRuntimeMemoryBounds.utf8Prefix(
            value,
            maximumBytes: min(perCallMaximum, remaining)
        )
        returnedBytes += output.utf8.count
        return output
    }

#if DEBUG
    var budgetStateForTesting: (
        parsedBytes: Int,
        documents: Int,
        returnedBytes: Int,
        bridgeCalls: Int,
        bridgeWorkUnits: Int
    ) {
        (parsedInputBytes, retainedDocumentCount, returnedBytes, bridgeCalls, bridgeWorkUnits)
    }
#endif
}

final class ReaderExtensionFetchBudget {
    private let lock = NSLock()
    private var count = 0
    private var responseBytes = 0

    func admit() -> Bool {
        lock.withReaderRuntimeLock {
            count += 1
            return count <= ReaderExtensionSecurityPolicy.maximumFetchesPerOperation
        }
    }

    func consume(_ response: ReaderExtensionNetworkResponse) -> Bool {
        var bytes = response.body.count
        for (name, value) in response.headers {
            let added = name.utf8.count + value.utf8.count
            guard added <= Int.max - bytes else { return false }
            bytes += added
        }
        let finalURLBytes = response.finalURL.absoluteString.utf8.count
        guard finalURLBytes <= Int.max - bytes else { return false }
        return consumeResponseBytes(bytes + finalURLBytes)
    }

    func consumeResponseBytes(_ bytes: Int) -> Bool {
        guard bytes >= 0 else { return false }
        return lock.withReaderRuntimeLock {
            let maximum = ReaderExtensionSecurityPolicy.maximumFetchResponseBytesPerOperation
            guard bytes <= maximum - responseBytes else { return false }
            responseBytes += bytes
            return true
        }
    }

#if DEBUG
    var stateForTesting: (requests: Int, responseBytes: Int) {
        lock.withReaderRuntimeLock { (count, responseBytes) }
    }
#endif
}

private enum ReaderExtensionRuntimeMemoryBounds {
    static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        guard maximumBytes > 0, value.utf8.count > maximumBytes else {
            return maximumBytes > 0 ? value : ""
        }
        var bytes = Data(value.utf8.prefix(maximumBytes))
        // UTF-8 scalars use at most four bytes, so at most three removals are
        // needed to land on a valid scalar boundary.
        while !bytes.isEmpty {
            if let output = String(data: bytes, encoding: .utf8) { return output }
            bytes.removeLast()
        }
        return ""
    }
}

private final class ReaderExtensionRuntimeCompletion {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var timedOut = false
    init(_ continuation: CheckedContinuation<Data, Error>) { self.continuation = continuation }
    var isFinished: Bool { lock.withReaderRuntimeLock { continuation == nil } }
    func succeed(_ data: Data) { settle(.success(data)) }
    @discardableResult func fail(_ error: Error) -> Bool { settle(.failure(error)) }
    @discardableResult func failTimedOut() -> Bool {
        lock.lock()
        guard let value = continuation else { lock.unlock(); return false }
        continuation = nil
        timedOut = true
        lock.unlock()
        value.resume(throwing: ReaderExtensionError.runtimeTimedOut)
        return true
    }
    var wasTimedOut: Bool { lock.withReaderRuntimeLock { timedOut } }
    @discardableResult private func settle(_ result: Result<Data, Error>) -> Bool {
        let value = lock.withReaderRuntimeLock { () -> CheckedContinuation<Data, Error>? in let value = continuation; continuation = nil; return value }
        guard let value else { return false }; value.resume(with: result); return true
    }
}

private final class ReaderExtensionBlockingResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<ReaderExtensionNetworkResponse, Error>?
    func set(_ value: Result<ReaderExtensionNetworkResponse, Error>) { lock.withReaderRuntimeLock { stored = value } }
    var result: Result<ReaderExtensionNetworkResponse, Error> { lock.withReaderRuntimeLock { stored ?? .failure(ReaderExtensionError.runtimeUnavailable) } }
}

final class ReaderExtensionDenyNetworkClient: ReaderExtensionNetworkClient, @unchecked Sendable {
    func request(_ request: ReaderExtensionNetworkRequest) async throws -> ReaderExtensionNetworkResponse {
        throw ReaderExtensionError.runtimeFailed("network is disabled during validation")
    }
}

enum ReaderExtensionItemSeedCache {
    private struct Entry {
        let item: ReaderExtensionItem
        let bytes: Int
    }

    private struct GlobalKey: Hashable {
        let namespace: String
        let itemKey: String
    }

    private static let lock = NSLock()
    private static var values: [String: [String: Entry]] = [:]
    private static var sourceOrder: [String: [String]] = [:]
    private static var sourceBytes: [String: Int] = [:]
    private static var globalOrder: [GlobalKey] = []
    private static var totalBytes = 0
    private static let maximumItemsPerSource = 500
    private static let maximumBytesPerItem = 128 * 1_024
    private static let maximumBytesPerSource = 2 * 1_024 * 1_024
    private static let maximumGlobalBytes = 8 * 1_024 * 1_024

    private static func namespace(scopeID: String, sourceID: ReaderExtensionSourceID) -> String {
        "\(scopeID):\(sourceID.rawValue)"
    }

    static func record(_ items: [ReaderExtensionItem], scopeID: String, sourceID: ReaderExtensionSourceID) {
        items.forEach { record($0, scopeID: scopeID, sourceID: sourceID) }
    }

    static func record(_ item: ReaderExtensionItem, scopeID: String, sourceID: ReaderExtensionSourceID) {
        guard let bounded = boundedItem(item) else { return }
        let entry = Entry(item: bounded, bytes: byteCost(bounded))
        guard entry.bytes <= maximumBytesPerItem else { return }
        lock.withReaderRuntimeLock {
            let namespace = namespace(scopeID: scopeID, sourceID: sourceID)
            removeEntry(namespace: namespace, itemKey: bounded.key)
            var namespaceValues = values[namespace] ?? [:]
            namespaceValues[bounded.key] = entry
            values[namespace] = namespaceValues
            var order = sourceOrder[namespace] ?? []
            order.append(bounded.key)
            sourceOrder[namespace] = order
            sourceBytes[namespace, default: 0] += entry.bytes
            totalBytes += entry.bytes
            globalOrder.append(GlobalKey(namespace: namespace, itemKey: bounded.key))

            while (sourceOrder[namespace]?.count ?? 0) > maximumItemsPerSource
                    || (sourceBytes[namespace] ?? 0) > maximumBytesPerSource {
                guard let oldest = sourceOrder[namespace]?.first else { break }
                removeEntry(namespace: namespace, itemKey: oldest)
            }
            while totalBytes > maximumGlobalBytes {
                guard let oldest = globalOrder.first else { break }
                if !removeEntry(namespace: oldest.namespace, itemKey: oldest.itemKey) {
                    globalOrder.removeFirst()
                }
            }
        }
    }

    static func item(scopeID: String, sourceID: ReaderExtensionSourceID, key: String) -> ReaderExtensionItem? {
        lock.withReaderRuntimeLock {
            let namespace = namespace(scopeID: scopeID, sourceID: sourceID)
            guard let entry = values[namespace]?[key] else { return nil }
            sourceOrder[namespace]?.removeAll { $0 == key }
            sourceOrder[namespace]?.append(key)
            let globalKey = GlobalKey(namespace: namespace, itemKey: key)
            globalOrder.removeAll { $0 == globalKey }
            globalOrder.append(globalKey)
            return entry.item
        }
    }

    static func clear(scopeID: String) {
        lock.withReaderRuntimeLock {
            let prefix = scopeID + ":"
            let namespaces = values.keys.filter { $0.hasPrefix(prefix) }
            for namespace in namespaces {
                guard let namespaceValues = values[namespace] else { continue }
                for key in Array(namespaceValues.keys) {
                    removeEntry(namespace: namespace, itemKey: key)
                }
            }
        }
    }

    static func clearAll() {
        lock.withReaderRuntimeLock {
            values.removeAll()
            sourceOrder.removeAll()
            sourceBytes.removeAll()
            globalOrder.removeAll()
            totalBytes = 0
        }
    }

    @discardableResult
    private static func removeEntry(namespace: String, itemKey: String) -> Bool {
        guard var namespaceValues = values[namespace],
              let removed = namespaceValues.removeValue(forKey: itemKey) else { return false }
        totalBytes = max(0, totalBytes - removed.bytes)
        sourceBytes[namespace] = max(0, (sourceBytes[namespace] ?? 0) - removed.bytes)
        sourceOrder[namespace]?.removeAll { $0 == itemKey }
        globalOrder.removeAll { $0.namespace == namespace && $0.itemKey == itemKey }
        if namespaceValues.isEmpty {
            values[namespace] = nil
            sourceOrder[namespace] = nil
            sourceBytes[namespace] = nil
        } else {
            values[namespace] = namespaceValues
        }
        return true
    }

    private static func boundedItem(_ item: ReaderExtensionItem) -> ReaderExtensionItem? {
        guard !item.key.isEmpty, item.key.utf8.count <= 4_096 else { return nil }
        var copy = item
        copy.title = ReaderExtensionRuntimeMemoryBounds.utf8Prefix(copy.title, maximumBytes: 4 * 1_024)
        copy.description = copy.description.map {
            ReaderExtensionRuntimeMemoryBounds.utf8Prefix($0, maximumBytes: 64 * 1_024)
        }
        copy.author = copy.author.map {
            ReaderExtensionRuntimeMemoryBounds.utf8Prefix($0, maximumBytes: 4 * 1_024)
        }
        copy.artist = copy.artist.map {
            ReaderExtensionRuntimeMemoryBounds.utf8Prefix($0, maximumBytes: 4 * 1_024)
        }
        copy.url = boundedURL(copy.url)
        copy.coverURL = boundedURL(copy.coverURL)
        var tagBytes = 0
        copy.tags = copy.tags.prefix(100).compactMap { tag in
            let bounded = ReaderExtensionRuntimeMemoryBounds.utf8Prefix(tag, maximumBytes: 512)
            let bytes = bounded.utf8.count
            guard !bounded.isEmpty, bytes <= 16 * 1_024 - tagBytes else { return nil }
            tagBytes += bytes
            return bounded
        }
        return copy
    }

    private static func boundedURL(_ url: URL?) -> URL? {
        guard let url, url.absoluteString.utf8.count <= 16 * 1_024 else { return nil }
        return url
    }

    private static func byteCost(_ item: ReaderExtensionItem) -> Int {
        var result = 256 + item.key.utf8.count + item.title.utf8.count
        result += item.url?.absoluteString.utf8.count ?? 0
        result += item.coverURL?.absoluteString.utf8.count ?? 0
        result += item.description?.utf8.count ?? 0
        result += item.author?.utf8.count ?? 0
        result += item.artist?.utf8.count ?? 0
        result += item.tags.reduce(0) { $0 + $1.utf8.count + 16 }
        return result
    }

#if DEBUG
    static var stateForTesting: (items: Int, namespaces: Int, bytes: Int) {
        lock.withReaderRuntimeLock {
            (values.values.reduce(0) { $0 + $1.count }, values.count, totalBytes)
        }
    }
#endif
}

private extension NSLock {
    func withReaderRuntimeLock<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}
