import Foundation
import CryptoKit

public struct SkyStreamPackageValidationLimits: Codable, Sendable, Hashable {
    public var maximumArchiveBytes: UInt64
    public var maximumExpandedBytes: UInt64
    public var maximumEntryCount: Int
    public var maximumManifestBytes: UInt64
    public var maximumScriptBytes: UInt64
    public var maximumProviderCount: Int
    public var supportedManifestVersions: Set<Int>

    public init(
        maximumArchiveBytes: UInt64 = 20 * 1_024 * 1_024,
        maximumExpandedBytes: UInt64 = 50 * 1_024 * 1_024,
        maximumEntryCount: Int = 64,
        maximumManifestBytes: UInt64 = 512 * 1_024,
        maximumScriptBytes: UInt64 = 10 * 1_024 * 1_024,
        maximumProviderCount: Int = 64,
        supportedManifestVersions: Set<Int> = [1]
    ) {
        self.maximumArchiveBytes = maximumArchiveBytes
        self.maximumExpandedBytes = maximumExpandedBytes
        self.maximumEntryCount = maximumEntryCount
        self.maximumManifestBytes = maximumManifestBytes
        self.maximumScriptBytes = maximumScriptBytes
        self.maximumProviderCount = maximumProviderCount
        self.supportedManifestVersions = supportedManifestVersions
    }

    public static let `default` = SkyStreamPackageValidationLimits()
}

public enum SkyStreamPackageValidationError: Error, Sendable, Equatable {
    case unavailable
    case archiveMustBeARegularFile
    case archiveTooLarge(actual: UInt64, maximum: UInt64)
    case unreadableArchive(String)
    case invalidExpectedChecksum(kind: String)
    case checksumMismatch(kind: String, expected: String, actual: String)
    case stagingDirectoryAlreadyExists
    case stagingParentUnavailable
    case tooManyEntries(actual: Int, maximum: Int)
    case expandedDataTooLarge(actual: UInt64, maximum: UInt64)
    case invalidEntryPath(String)
    case invalidUTF8EntryPath
    case duplicateEntryPath(String)
    case fileDirectoryCollision(String)
    case encryptedEntryNotAllowed(String)
    case unsupportedEntryType(String)
    case unsupportedArchiveLayout(String)
    case symbolicLinkNotAllowed(String)
    case requiredFileMissing(String)
    case requiredFileMustBeRegular(String)
    case requiredFileTooLarge(path: String, actual: UInt64, maximum: UInt64)
    case invalidRequiredFileUTF8(String)
    case invalidManifestJSON(String)
    case invalidManifestField(String)
    case invalidPackageIdentifier(String)
    case packageIdentifierMismatch(expected: String, actual: String)
    case invalidPluginVersion(Int)
    case unsupportedManifestVersion(Int)
    case tooManyProviders(actual: Int, maximum: Int)
    case invalidProviderIdentifier(String)
    case duplicateProviderIdentifier(String)
    case duplicateDomain(String)
    case invalidURL(field: String)
    case extractionFailed(path: String, reason: String)
    case atomicMoveFailed(String)
}

extension SkyStreamPackageValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "SkyStream package execution is available only on iPhone and iPad."
        case .archiveMustBeARegularFile:
            return "The SkyStream package must be a regular local archive file."
        case .archiveTooLarge(let actual, let maximum):
            return "The compressed package is \(actual) bytes; the limit is \(maximum) bytes."
        case .unreadableArchive(let reason):
            return "The SkyStream package is not a readable ZIP archive: \(reason)"
        case .invalidExpectedChecksum(let kind):
            return "The expected \(kind) SHA-256 value is malformed."
        case .checksumMismatch(let kind, let expected, let actual):
            return "The \(kind) SHA-256 does not match (expected \(expected), got \(actual))."
        case .stagingDirectoryAlreadyExists:
            return "The staging directory already exists; it will not be overwritten."
        case .stagingParentUnavailable:
            return "The staging directory parent is unavailable or is not a directory."
        case .tooManyEntries(let actual, let maximum):
            return "The package has \(actual) entries; the limit is \(maximum)."
        case .expandedDataTooLarge(let actual, let maximum):
            return "The expanded package is \(actual) bytes; the limit is \(maximum) bytes."
        case .invalidEntryPath(let path):
            return "The package contains an unsafe entry path: \(path)"
        case .invalidUTF8EntryPath:
            return "The package contains an entry path that is not valid UTF-8."
        case .duplicateEntryPath(let path):
            return "The package contains duplicate or Unicode/case-colliding entries: \(path)"
        case .fileDirectoryCollision(let path):
            return "A package entry collides with a file/directory path: \(path)"
        case .encryptedEntryNotAllowed(let path):
            return "Encrypted ZIP entries are not allowed in SkyStream packages: \(path)"
        case .unsupportedEntryType(let path):
            return "The package contains an unsupported special entry type: \(path)"
        case .unsupportedArchiveLayout(let reason):
            return "The package uses an unsupported ZIP layout: \(reason)"
        case .symbolicLinkNotAllowed(let path):
            return "Symbolic links are not allowed in SkyStream packages: \(path)"
        case .requiredFileMissing(let path):
            return "The package is missing required root file \(path)."
        case .requiredFileMustBeRegular(let path):
            return "Required root entry \(path) must be a regular file."
        case .requiredFileTooLarge(let path, let actual, let maximum):
            return "\(path) is \(actual) bytes; the limit is \(maximum) bytes."
        case .invalidRequiredFileUTF8(let path):
            return "\(path) is not valid UTF-8."
        case .invalidManifestJSON(let reason):
            return "plugin.json is malformed: \(reason)"
        case .invalidManifestField(let field):
            return "plugin.json contains an invalid \(field) value."
        case .invalidPackageIdentifier(let identifier):
            return "The plugin package identifier is invalid: \(identifier)"
        case .packageIdentifierMismatch(let expected, let actual):
            return "The package identifies as \(actual), but \(expected) was requested."
        case .invalidPluginVersion(let version):
            return "The plugin version must be a positive integer (got \(version))."
        case .unsupportedManifestVersion(let version):
            return "SkyStream manifest version \(version) is unsupported."
        case .tooManyProviders(let actual, let maximum):
            return "The plugin declares \(actual) providers; the limit is \(maximum)."
        case .invalidProviderIdentifier(let identifier):
            return "The provider identifier is invalid: \(identifier)"
        case .duplicateProviderIdentifier(let identifier):
            return "The plugin declares a duplicate provider identifier: \(identifier)"
        case .duplicateDomain(let domain):
            return "The plugin declares a duplicate domain: \(domain)"
        case .invalidURL(let field):
            return "plugin.json contains an invalid URL in \(field)."
        case .extractionFailed(let path, let reason):
            return "Failed to extract \(path): \(reason)"
        case .atomicMoveFailed(let reason):
            return "The validated package could not be moved into staging atomically: \(reason)"
        }
    }
}

#if os(iOS) && !targetEnvironment(macCatalyst)
import ZIPFoundation

public enum SkyStreamPackageValidator {
    private static let manifestPath = "plugin.json"
    private static let scriptPath = "plugin.js"
    private static let ioChunkSize = 64 * 1_024
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    private struct CheckedEntry {
        let archiveEntry: Entry
        let path: String
        let canonicalPath: String
    }

    public static func validateAndExtract(
        archiveAt archiveURL: URL,
        to stagingDirectory: URL,
        expectedPackageName: String? = nil,
        expectedArchiveSHA256: String? = nil,
        expectedScriptSHA256: String? = nil,
        limits: SkyStreamPackageValidationLimits = .default,
        fileManager: FileManager = .default
    ) throws -> SkyStreamValidatedPackage {
        guard archiveURL.isFileURL, stagingDirectory.isFileURL else {
            throw SkyStreamPackageValidationError.archiveMustBeARegularFile
        }

        let archiveValues = try? archiveURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard archiveValues?.isRegularFile == true,
              archiveValues?.isSymbolicLink != true else {
            throw SkyStreamPackageValidationError.archiveMustBeARegularFile
        }
        if let fileSize = archiveValues?.fileSize, fileSize >= 0,
           UInt64(fileSize) > limits.maximumArchiveBytes {
            throw SkyStreamPackageValidationError.archiveTooLarge(
                actual: UInt64(fileSize),
                maximum: limits.maximumArchiveBytes
            )
        }

        let normalizedStagingURL = stagingDirectory.standardizedFileURL
        guard normalizedStagingURL.path != "/", !normalizedStagingURL.lastPathComponent.isEmpty else {
            throw SkyStreamPackageValidationError.stagingParentUnavailable
        }
        guard !fileManager.fileExists(atPath: normalizedStagingURL.path) else {
            throw SkyStreamPackageValidationError.stagingDirectoryAlreadyExists
        }

        let parentURL = normalizedStagingURL.deletingLastPathComponent()
        var parentIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: parentURL.path, isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue else {
            throw SkyStreamPackageValidationError.stagingParentUnavailable
        }

        let archiveData = try readBoundedArchive(
            at: archiveURL,
            maximumBytes: limits.maximumArchiveBytes
        )
        let archiveByteCount = UInt64(archiveData.count)
        let archiveHash = sha256Hex(archiveData)
        if let expectedArchiveSHA256 {
            let expected = try normalizedSHA256(expectedArchiveSHA256, kind: "archive")
            guard expected == archiveHash else {
                throw SkyStreamPackageValidationError.checksumMismatch(
                    kind: "archive",
                    expected: expected,
                    actual: archiveHash
                )
            }
        }
        try inspectRawZIPMetadata(archiveData, limits: limits)

        let temporaryRoot = parentURL.appendingPathComponent(
            ".\(normalizedStagingURL.lastPathComponent).skystream-\(UUID().uuidString)",
            isDirectory: true
        )
        let temporaryArchiveURL = temporaryRoot.appendingPathComponent("package.sky", isDirectory: false)
        let payloadURL = temporaryRoot.appendingPathComponent("payload", isDirectory: true)

        try fileManager.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        var shouldRemoveTemporaryRoot = true
        defer {
            if shouldRemoveTemporaryRoot || fileManager.fileExists(atPath: temporaryRoot.path) {
                try? fileManager.removeItem(at: temporaryRoot)
            }
        }

        try archiveData.write(to: temporaryArchiveURL, options: [.atomic])
        try fileManager.createDirectory(
            at: payloadURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )

        let archive: Archive
        do {
            archive = try Archive(url: temporaryArchiveURL, accessMode: .read)
        } catch {
            throw SkyStreamPackageValidationError.unreadableArchive(error.localizedDescription)
        }

        let entries = try inspectEntries(in: archive, limits: limits)
        let expandedByteCount = try extract(
            entries,
            from: archive,
            to: payloadURL,
            limits: limits,
            fileManager: fileManager
        )

        let manifestURL = payloadURL.appendingPathComponent(manifestPath, isDirectory: false)
        let scriptURL = payloadURL.appendingPathComponent(scriptPath, isDirectory: false)
        let manifestData = try Data(contentsOf: manifestURL, options: [.mappedIfSafe])
        let scriptData = try Data(contentsOf: scriptURL, options: [.mappedIfSafe])

        guard String(data: manifestData, encoding: .utf8) != nil else {
            throw SkyStreamPackageValidationError.invalidRequiredFileUTF8(manifestPath)
        }
        guard String(data: scriptData, encoding: .utf8) != nil else {
            throw SkyStreamPackageValidationError.invalidRequiredFileUTF8(scriptPath)
        }

        var manifest: SkyStreamPluginManifest
        do {
            try SkyStreamJSONEnvelopeValidator.validate(
                manifestData,
                limits: .packageManifest
            )
            manifest = try JSONDecoder().decode(SkyStreamPluginManifest.self, from: manifestData)
        } catch {
            throw SkyStreamPackageValidationError.invalidManifestJSON(error.localizedDescription)
        }
        try validateManifest(manifest, expectedPackageName: expectedPackageName, limits: limits)
        sanitizeOptionalIconURLs(in: &manifest)

        let scriptHash = sha256Hex(scriptData)
        if let expectedScriptSHA256 {
            let expected = try normalizedSHA256(expectedScriptSHA256, kind: "script")
            guard expected == scriptHash else {
                throw SkyStreamPackageValidationError.checksumMismatch(
                    kind: "script",
                    expected: expected,
                    actual: scriptHash
                )
            }
        }

        try fileManager.removeItem(at: temporaryArchiveURL)
        guard !fileManager.fileExists(atPath: normalizedStagingURL.path) else {
            throw SkyStreamPackageValidationError.stagingDirectoryAlreadyExists
        }
        do {
            try fileManager.moveItem(at: payloadURL, to: normalizedStagingURL)
        } catch {
            throw SkyStreamPackageValidationError.atomicMoveFailed(error.localizedDescription)
        }

        shouldRemoveTemporaryRoot = false
        try? fileManager.removeItem(at: temporaryRoot)

        return SkyStreamValidatedPackage(
            manifest: manifest,
            archiveSHA256: archiveHash,
            scriptSHA256: scriptHash,
            stagingDirectory: normalizedStagingURL,
            archiveByteCount: archiveByteCount,
            expandedByteCount: expandedByteCount,
            entryCount: entries.count
        )
    }

    private static func readBoundedArchive(at url: URL, maximumBytes: UInt64) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var result = Data()
        if maximumBytes <= UInt64(Int.max) {
            result.reserveCapacity(Int(min(maximumBytes, UInt64(2 * 1_024 * 1_024))))
        }

        while true {
            let remainingBeforeFailure = maximumBytes >= UInt64(result.count)
                ? maximumBytes - UInt64(result.count)
                : 0
            let nextRead = Int(min(UInt64(ioChunkSize), remainingBeforeFailure + 1))
            guard nextRead > 0 else {
                throw SkyStreamPackageValidationError.archiveTooLarge(
                    actual: UInt64(result.count),
                    maximum: maximumBytes
                )
            }
            guard let chunk = try handle.read(upToCount: nextRead), !chunk.isEmpty else { break }
            result.append(chunk)
            if UInt64(result.count) > maximumBytes {
                throw SkyStreamPackageValidationError.archiveTooLarge(
                    actual: UInt64(result.count),
                    maximum: maximumBytes
                )
            }
        }
        return result
    }

    private static func inspectRawZIPMetadata(
        _ data: Data,
        limits: SkyStreamPackageValidationLimits
    ) throws {
        let endSignature: UInt32 = 0x0605_4B50
        let centralSignature: UInt32 = 0x0201_4B50
        let localSignature: UInt32 = 0x0403_4B50
        let minimumEndSize = 22
        guard data.count >= minimumEndSize else {
            throw SkyStreamPackageValidationError.unsupportedArchiveLayout("missing end record")
        }

        let earliestCandidate = max(0, data.count - minimumEndSize - Int(UInt16.max))
        var endOffset: Int?
        for offset in stride(from: data.count - minimumEndSize, through: earliestCandidate, by: -1) {
            guard readUInt32(data, at: offset) == endSignature,
                  let commentLength = readUInt16(data, at: offset + 20) else {
                continue
            }
            if offset + minimumEndSize + Int(commentLength) == data.count {
                endOffset = offset
                break
            }
        }
        guard let endOffset,
              let diskNumber = readUInt16(data, at: endOffset + 4),
              let centralDisk = readUInt16(data, at: endOffset + 6),
              let entriesOnDisk = readUInt16(data, at: endOffset + 8),
              let entryCountRaw = readUInt16(data, at: endOffset + 10),
              let centralSizeRaw = readUInt32(data, at: endOffset + 12),
              let centralOffsetRaw = readUInt32(data, at: endOffset + 16) else {
            throw SkyStreamPackageValidationError.unsupportedArchiveLayout("truncated end record")
        }
        guard diskNumber == 0, centralDisk == 0, entriesOnDisk == entryCountRaw else {
            throw SkyStreamPackageValidationError.unsupportedArchiveLayout("multi-disk archive")
        }
        guard entryCountRaw != UInt16.max,
              centralSizeRaw != UInt32.max,
              centralOffsetRaw != UInt32.max else {
            throw SkyStreamPackageValidationError.unsupportedArchiveLayout("ZIP64 archive")
        }

        let entryCount = Int(entryCountRaw)
        guard entryCount <= limits.maximumEntryCount else {
            throw SkyStreamPackageValidationError.tooManyEntries(
                actual: entryCount,
                maximum: limits.maximumEntryCount
            )
        }
        let centralOffset = Int(centralOffsetRaw)
        let centralSize = Int(centralSizeRaw)
        let (centralEnd, centralOverflow) = centralOffset.addingReportingOverflow(centralSize)
        guard !centralOverflow, centralOffset >= 0, centralEnd == endOffset else {
            throw SkyStreamPackageValidationError.unsupportedArchiveLayout("invalid central directory bounds")
        }

        var cursor = centralOffset
        var occupiedLocalRanges: [Range<Int>] = []
        occupiedLocalRanges.reserveCapacity(entryCount)

        for _ in 0..<entryCount {
            guard cursor + 46 <= centralEnd,
                  readUInt32(data, at: cursor) == centralSignature,
                  let versionMadeBy = readUInt16(data, at: cursor + 4),
                  let flags = readUInt16(data, at: cursor + 8),
                  let method = readUInt16(data, at: cursor + 10),
                  let compressedSizeRaw = readUInt32(data, at: cursor + 20),
                  let uncompressedSizeRaw = readUInt32(data, at: cursor + 24),
                  let nameLength = readUInt16(data, at: cursor + 28),
                  let extraLength = readUInt16(data, at: cursor + 30),
                  let commentLength = readUInt16(data, at: cursor + 32),
                  let startingDisk = readUInt16(data, at: cursor + 34),
                  let externalAttributes = readUInt32(data, at: cursor + 38),
                  let localOffsetRaw = readUInt32(data, at: cursor + 42) else {
                throw SkyStreamPackageValidationError.unsupportedArchiveLayout("truncated central entry")
            }
            guard compressedSizeRaw != UInt32.max,
                  uncompressedSizeRaw != UInt32.max,
                  localOffsetRaw != UInt32.max,
                  startingDisk == 0 else {
                throw SkyStreamPackageValidationError.unsupportedArchiveLayout("ZIP64 or split entry")
            }
            guard method == 0 || method == 8 else {
                throw SkyStreamPackageValidationError.unsupportedArchiveLayout("unsupported compression method")
            }

            let headerLength = 46 + Int(nameLength) + Int(extraLength) + Int(commentLength)
            let (nextCursor, cursorOverflow) = cursor.addingReportingOverflow(headerLength)
            guard !cursorOverflow, nextCursor <= centralEnd else {
                throw SkyStreamPackageValidationError.unsupportedArchiveLayout("invalid central entry bounds")
            }
            let nameStart = cursor + 46
            let nameEnd = nameStart + Int(nameLength)
            let nameData = data.subdata(in: nameStart..<nameEnd)
            guard let path = String(data: nameData, encoding: .utf8), !path.isEmpty else {
                throw SkyStreamPackageValidationError.invalidUTF8EntryPath
            }

            let encryptionMask: UInt16 = (1 << 0) | (1 << 6) | (1 << 13)
            guard flags & encryptionMask == 0 else {
                throw SkyStreamPackageValidationError.encryptedEntryNotAllowed(path)
            }

            let creatorSystem = UInt8(truncatingIfNeeded: versionMadeBy >> 8)
            if creatorSystem == 3 || creatorSystem == 19 {
                let mode = UInt16(truncatingIfNeeded: externalAttributes >> 16) & 0xF000
                let isRegular = mode == 0 || mode == 0x8000
                let isDirectory = mode == 0x4000
                let isSymlink = mode == 0xA000
                if isSymlink {
                    throw SkyStreamPackageValidationError.symbolicLinkNotAllowed(path)
                }
                guard isRegular || isDirectory else {
                    throw SkyStreamPackageValidationError.unsupportedEntryType(path)
                }
            }

            let localOffset = Int(localOffsetRaw)
            guard localOffset >= 0,
                  localOffset + 30 <= centralOffset,
                  readUInt32(data, at: localOffset) == localSignature,
                  let localFlags = readUInt16(data, at: localOffset + 6),
                  let localMethod = readUInt16(data, at: localOffset + 8),
                  let localNameLength = readUInt16(data, at: localOffset + 26),
                  let localExtraLength = readUInt16(data, at: localOffset + 28) else {
                throw SkyStreamPackageValidationError.unsupportedArchiveLayout("invalid local header")
            }
            guard localFlags & encryptionMask == 0 else {
                throw SkyStreamPackageValidationError.encryptedEntryNotAllowed(path)
            }
            guard localMethod == method else {
                throw SkyStreamPackageValidationError.unsupportedArchiveLayout("compression method mismatch")
            }

            let localNameStart = localOffset + 30
            let localNameEnd = localNameStart + Int(localNameLength)
            let dataStart = localNameEnd + Int(localExtraLength)
            let compressedSize = Int(compressedSizeRaw)
            let (dataEnd, dataOverflow) = dataStart.addingReportingOverflow(compressedSize)
            guard !dataOverflow,
                  localNameEnd <= centralOffset,
                  dataStart <= centralOffset,
                  dataEnd <= centralOffset,
                  data.subdata(in: localNameStart..<localNameEnd) == nameData else {
                throw SkyStreamPackageValidationError.unsupportedArchiveLayout("local entry bounds or name mismatch")
            }
            occupiedLocalRanges.append(localOffset..<dataEnd)
            cursor = nextCursor
        }

        guard cursor == centralEnd else {
            throw SkyStreamPackageValidationError.unsupportedArchiveLayout("central directory entry count mismatch")
        }
        let orderedRanges = occupiedLocalRanges.sorted { $0.lowerBound < $1.lowerBound }
        if orderedRanges.count > 1 {
            for pairIndex in 1..<orderedRanges.count
            where orderedRanges[pairIndex].lowerBound < orderedRanges[pairIndex - 1].upperBound {
                throw SkyStreamPackageValidationError.unsupportedArchiveLayout("overlapping local entries")
            }
        }
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func inspectEntries(
        in archive: Archive,
        limits: SkyStreamPackageValidationLimits
    ) throws -> [CheckedEntry] {
        var checked: [CheckedEntry] = []
        checked.reserveCapacity(min(limits.maximumEntryCount, 16))
        var seenExact: Set<String> = []
        var seenCanonical: Set<String> = []
        var canonicalFiles: Set<String> = []
        var requiredTypes: [String: Entry.EntryType] = [:]
        var predictedExpandedBytes: UInt64 = 0

        for entry in archive {
            if checked.count == limits.maximumEntryCount {
                throw SkyStreamPackageValidationError.tooManyEntries(
                    actual: checked.count + 1,
                    maximum: limits.maximumEntryCount
                )
            }

            let decodedAsUTF8 = entry.path(using: .utf8)
            guard !decodedAsUTF8.isEmpty, decodedAsUTF8 == entry.path else {
                throw SkyStreamPackageValidationError.invalidUTF8EntryPath
            }
            let path = try validatedRelativePath(entry.path, isDirectory: entry.type == .directory)
            let canonicalPath = canonicalArchivePath(path)

            guard seenExact.insert(path).inserted, seenCanonical.insert(canonicalPath).inserted else {
                throw SkyStreamPackageValidationError.duplicateEntryPath(path)
            }
            if entry.type == .symlink {
                throw SkyStreamPackageValidationError.symbolicLinkNotAllowed(path)
            }

            let components = canonicalPath.split(separator: "/", omittingEmptySubsequences: false)
            if components.count > 1 {
                for endIndex in 1..<components.count {
                    let ancestor = components[..<endIndex].joined(separator: "/")
                    if canonicalFiles.contains(ancestor) {
                        throw SkyStreamPackageValidationError.fileDirectoryCollision(path)
                    }
                }
            }
            if entry.type == .file {
                let filePrefix = canonicalPath + "/"
                if seenCanonical.contains(where: { $0.hasPrefix(filePrefix) }) {
                    throw SkyStreamPackageValidationError.fileDirectoryCollision(path)
                }
                canonicalFiles.insert(canonicalPath)
            }

            let (newTotal, overflow) = predictedExpandedBytes.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, newTotal <= limits.maximumExpandedBytes else {
                throw SkyStreamPackageValidationError.expandedDataTooLarge(
                    actual: overflow ? UInt64.max : newTotal,
                    maximum: limits.maximumExpandedBytes
                )
            }
            predictedExpandedBytes = newTotal

            if path == manifestPath || path == scriptPath {
                requiredTypes[path] = entry.type
                guard entry.type == .file else {
                    throw SkyStreamPackageValidationError.requiredFileMustBeRegular(path)
                }
                let maximum = path == manifestPath
                    ? limits.maximumManifestBytes
                    : limits.maximumScriptBytes
                guard entry.uncompressedSize <= maximum else {
                    throw SkyStreamPackageValidationError.requiredFileTooLarge(
                        path: path,
                        actual: entry.uncompressedSize,
                        maximum: maximum
                    )
                }
            }

            checked.append(CheckedEntry(
                archiveEntry: entry,
                path: path,
                canonicalPath: canonicalPath
            ))
        }

        for requiredPath in [manifestPath, scriptPath] {
            guard requiredTypes[requiredPath] != nil else {
                throw SkyStreamPackageValidationError.requiredFileMissing(requiredPath)
            }
        }
        return checked
    }

    private static func extract(
        _ entries: [CheckedEntry],
        from archive: Archive,
        to rootURL: URL,
        limits: SkyStreamPackageValidationLimits,
        fileManager: FileManager
    ) throws -> UInt64 {

        let standardizedRoot = rootURL.standardizedFileURL
        let rootPrefix = standardizedRoot.path.hasSuffix("/")
            ? standardizedRoot.path
            : standardizedRoot.path + "/"
        var expandedByteCount: UInt64 = 0

        for checked in entries {
            let destinationURL = rootURL
                .appendingPathComponent(checked.path, isDirectory: checked.archiveEntry.type == .directory)
                .standardizedFileURL
            guard destinationURL.path.hasPrefix(rootPrefix) else {
                throw SkyStreamPackageValidationError.invalidEntryPath(checked.path)
            }

            if checked.archiveEntry.type == .directory {

                continue
            }

            do {
                let shouldPersist = checked.path == manifestPath || checked.path == scriptPath
                var outputHandle: FileHandle?
                if shouldPersist {
                    try fileManager.createDirectory(
                        at: destinationURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true,
                        attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
                    )
                    guard fileManager.createFile(
                        atPath: destinationURL.path,
                        contents: nil,
                        attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
                    ) else {
                        throw SkyStreamPackageValidationError.fileDirectoryCollision(checked.path)
                    }
                    outputHandle = try FileHandle(forWritingTo: destinationURL)
                }
                defer { try? outputHandle?.close() }
                var entryByteCount: UInt64 = 0
                let maximumEntryBytes: UInt64? = checked.path == manifestPath
                    ? limits.maximumManifestBytes
                    : (checked.path == scriptPath ? limits.maximumScriptBytes : nil)

                _ = try archive.extract(
                    checked.archiveEntry,
                    bufferSize: ioChunkSize,
                    skipCRC32: false,
                    progress: nil
                ) { chunk in
                    let chunkCount = UInt64(chunk.count)
                    let (nextEntryCount, entryOverflow) = entryByteCount.addingReportingOverflow(chunkCount)
                    if entryOverflow || maximumEntryBytes.map({ nextEntryCount > $0 }) == true {
                        throw SkyStreamPackageValidationError.requiredFileTooLarge(
                            path: checked.path,
                            actual: entryOverflow ? UInt64.max : nextEntryCount,
                            maximum: maximumEntryBytes ?? limits.maximumExpandedBytes
                        )
                    }
                    let (nextTotal, totalOverflow) = expandedByteCount.addingReportingOverflow(chunkCount)
                    if totalOverflow || nextTotal > limits.maximumExpandedBytes {
                        throw SkyStreamPackageValidationError.expandedDataTooLarge(
                            actual: totalOverflow ? UInt64.max : nextTotal,
                            maximum: limits.maximumExpandedBytes
                        )
                    }

                    try outputHandle?.write(contentsOf: chunk)
                    entryByteCount = nextEntryCount
                    expandedByteCount = nextTotal
                }
            } catch let validationError as SkyStreamPackageValidationError {
                throw validationError
            } catch {
                throw SkyStreamPackageValidationError.extractionFailed(
                    path: checked.path,
                    reason: error.localizedDescription
                )
            }
        }

        return expandedByteCount
    }

    private static func validatedRelativePath(_ rawPath: String, isDirectory: Bool) throws -> String {
        guard !rawPath.isEmpty,
              !rawPath.contains("\0"),
              !rawPath.contains("\\"),
              !rawPath.hasPrefix("/"),
              !rawPath.hasPrefix("//") else {
            throw SkyStreamPackageValidationError.invalidEntryPath(rawPath)
        }

        let scalars = Array(rawPath.unicodeScalars)
        if scalars.count >= 2,
           CharacterSet.letters.contains(scalars[0]),
           scalars[1] == ":" {
            throw SkyStreamPackageValidationError.invalidEntryPath(rawPath)
        }

        var path = rawPath
        if isDirectory {
            while path.hasSuffix("/") { path.removeLast() }
        } else if path.hasSuffix("/") {
            throw SkyStreamPackageValidationError.invalidEntryPath(rawPath)
        }
        guard !path.isEmpty else {
            throw SkyStreamPackageValidationError.invalidEntryPath(rawPath)
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SkyStreamPackageValidationError.invalidEntryPath(rawPath)
        }
        return path
    }

    private static func canonicalArchivePath(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: posixLocale)
            .precomposedStringWithCanonicalMapping
    }

    private static func validateManifest(
        _ manifest: SkyStreamPluginManifest,
        expectedPackageName: String?,
        limits: SkyStreamPackageValidationLimits
    ) throws {
        guard isValidPackageIdentifier(manifest.packageName) else {
            throw SkyStreamPackageValidationError.invalidPackageIdentifier(manifest.packageName)
        }
        if let expectedPackageName, expectedPackageName != manifest.packageName {
            throw SkyStreamPackageValidationError.packageIdentifierMismatch(
                expected: expectedPackageName,
                actual: manifest.packageName
            )
        }
        guard manifest.version > 0 else {
            throw SkyStreamPackageValidationError.invalidPluginVersion(manifest.version)
        }
        if let manifestVersion = manifest.manifestVersion,
           !limits.supportedManifestVersions.contains(manifestVersion) {
            throw SkyStreamPackageValidationError.unsupportedManifestVersion(manifestVersion)
        }

        guard isBoundedNonempty(manifest.name, maximumUTF8Bytes: 256) else {
            throw SkyStreamPackageValidationError.invalidManifestField("name")
        }
        if let description = manifest.description,
           !isBoundedNonempty(description, maximumUTF8Bytes: 4 * 1_024) {
            throw SkyStreamPackageValidationError.invalidManifestField("description")
        }
        try validateStrings(manifest.authors, field: "authors", maximumCount: 64)
        try validateStrings(manifest.languages, field: "languages", maximumCount: 64)
        try validateStrings(manifest.categories, field: "categories", maximumCount: 64)

        guard manifest.baseURL.utf8.count <= 8 * 1_024,
              manifest.baseURL.isEmpty || isHTTPURL(manifest.baseURL) else {
            throw SkyStreamPackageValidationError.invalidURL(field: "baseUrl")
        }
        let domains = manifest.domains ?? []
        let providers = manifest.providers ?? []
        guard domains.count <= limits.maximumProviderCount else {
            throw SkyStreamPackageValidationError.invalidManifestField("domains")
        }
        guard providers.count <= limits.maximumProviderCount else {
            throw SkyStreamPackageValidationError.tooManyProviders(
                actual: providers.count,
                maximum: limits.maximumProviderCount
            )
        }

        var providerIDs: Set<String> = []
        for provider in providers {
            guard isValidProviderIdentifier(provider.id),
                  isBoundedNonempty(provider.name, maximumUTF8Bytes: 256) else {
                throw SkyStreamPackageValidationError.invalidProviderIdentifier(provider.id)
            }
            guard provider.languages.map({ values in
                values.count <= 64 && values.allSatisfy {
                    isBoundedNonempty($0, maximumUTF8Bytes: 256)
                }
            }) ?? true,
            provider.categories.map({ values in
                values.count <= 64 && values.allSatisfy {
                    isBoundedNonempty($0, maximumUTF8Bytes: 256)
                }
            }) ?? true else {
                throw SkyStreamPackageValidationError.invalidManifestField(
                    "providers[\(provider.id)].languages/categories"
                )
            }
            guard providerIDs.insert(provider.id).inserted else {
                throw SkyStreamPackageValidationError.duplicateProviderIdentifier(provider.id)
            }
            if let baseURL = provider.baseURL,
               (baseURL.utf8.count > 8 * 1_024 || !isHTTPURL(baseURL)) {
                throw SkyStreamPackageValidationError.invalidURL(field: "providers[\(provider.id)].baseUrl")
            }
        }

        if let providerID = manifest.providerID, !isValidProviderIdentifier(providerID) {
            throw SkyStreamPackageValidationError.invalidProviderIdentifier(providerID)
        }

        var domainNames: Set<String> = []
        var domainURLs: Set<String> = []
        for domain in domains {
            guard isBoundedNonempty(domain.name, maximumUTF8Bytes: 256),
                  domain.url.utf8.count <= 8 * 1_024,
                  isHTTPURL(domain.url) else {
                throw SkyStreamPackageValidationError.invalidURL(field: "domains")
            }
            let canonicalName = domain.name.folding(options: [.caseInsensitive], locale: posixLocale)
            let canonicalURL = domain.url.folding(options: [.caseInsensitive], locale: posixLocale)
            guard domainNames.insert(canonicalName).inserted,
                  domainURLs.insert(canonicalURL).inserted else {
                throw SkyStreamPackageValidationError.duplicateDomain(domain.name)
            }
        }
    }

    private static func validateStrings(
        _ values: [String],
        field: String,
        maximumCount: Int
    ) throws {
        guard values.count <= maximumCount,
              values.allSatisfy({ isBoundedNonempty($0, maximumUTF8Bytes: 256) }) else {
            throw SkyStreamPackageValidationError.invalidManifestField(field)
        }
    }

    private static func sanitizeOptionalIconURLs(in manifest: inout SkyStreamPluginManifest) {
        if let iconURL = manifest.iconURL,
           iconURL.utf8.count > 8 * 1_024 || !isHTTPSURL(iconURL) {
            manifest.iconURL = nil
        }
        guard var providers = manifest.providers else { return }
        for index in providers.indices {
            if let iconURL = providers[index].iconURL,
               iconURL.utf8.count > 8 * 1_024 || !isHTTPSURL(iconURL) {
                providers[index].iconURL = nil
            }
        }
        manifest.providers = providers
    }

    private static func isBoundedNonempty(_ value: String, maximumUTF8Bytes: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= maximumUTF8Bytes
    }

    private static func isValidPackageIdentifier(_ identifier: String) -> Bool {
        SkyStreamStableID.isValidPackageName(identifier)
    }

    private static func isValidProviderIdentifier(_ identifier: String) -> Bool {
        SkyStreamStableID.isValidProviderID(identifier)
    }

    private static func isHTTPURL(_ string: String) -> Bool {
        isURL(string, allowedSchemes: ["http", "https"])
    }

    private static func isHTTPSURL(_ string: String) -> Bool {
        isURL(string, allowedSchemes: ["https"])
    }

    private static func isURL(_ string: String, allowedSchemes: Set<String>) -> Bool {
        guard let components = URLComponents(string: string),
              let scheme = components.scheme?.lowercased(),
              allowedSchemes.contains(scheme),
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil else {
            return false
        }
        return true
    }

    private static func normalizedSHA256(_ rawValue: String, kind: String) throws -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasPrefix("sha256:") {
            value.removeFirst("sha256:".count)
        }
        guard value.count == 64,
              value.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "0123456789abcdef").contains($0)
              }) else {
            throw SkyStreamPackageValidationError.invalidExpectedChecksum(kind: kind)
        }
        return value
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

#else

public enum SkyStreamPackageValidator {
    @available(*, unavailable, message: "SkyStream packages are available only on iPhone and iPad.")
    public static func validateAndExtract(
        archiveAt archiveURL: URL,
        to stagingDirectory: URL,
        expectedPackageName: String? = nil,
        expectedArchiveSHA256: String? = nil,
        expectedScriptSHA256: String? = nil,
        limits: SkyStreamPackageValidationLimits = .default,
        fileManager: FileManager = .default
    ) throws -> SkyStreamValidatedPackage {
        throw SkyStreamPackageValidationError.unavailable
    }
}

#endif
