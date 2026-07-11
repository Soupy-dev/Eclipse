import Foundation

struct DownloadPathIdentityOwner: Equatable {
    let id: String
    let mediaIdentity: String
    let isMovie: Bool
    let relativePaths: [String]
}

struct DownloadPathIdentityRequest: Equatable {
    let itemID: String
    let mediaIdentity: String
    let tmdbID: Int
    let isMovie: Bool
    let baseComponent: String
    let episodeComponent: String
}

enum DownloadPathIdentityPolicy {
    static func normalizedRelativePath(_ relativePath: String) -> String? {
        let trimmed = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = trimmed
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !components.isEmpty,
              !components.contains(where: { $0 == "." || $0 == ".." }) else {
            return nil
        }
        return components.joined(separator: "/")
    }

    static func canonicalString(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }

    static func canonicalRelativePath(_ relativePath: String) -> String {
        canonicalString(normalizedRelativePath(relativePath) ?? relativePath)
    }

    static func exactPathIsAvailable(
        _ relativePath: String,
        claimantID: String,
        owners: [DownloadPathIdentityOwner]
    ) -> Bool {
        let key = canonicalRelativePath(relativePath)
        return !owners.contains { owner in
            owner.id != claimantID && owner.relativePaths.contains {
                canonicalRelativePath($0) == key
            }
        }
    }

    static func pathIsReferenced(
        _ relativePath: String,
        excludingIDs: Set<String>,
        owners: [DownloadPathIdentityOwner]
    ) -> Bool {
        let key = canonicalRelativePath(relativePath)
        return owners.contains { owner in
            !excludingIDs.contains(owner.id) && owner.relativePaths.contains {
                canonicalRelativePath($0) == key
            }
        }
    }

    static func videoReservationIsAvailable(
        _ relativePath: String,
        request: DownloadPathIdentityRequest,
        owners: [DownloadPathIdentityOwner]
    ) -> Bool {
        guard exactPathIsAvailable(relativePath, claimantID: request.itemID, owners: owners),
              let candidateNamespace = videoNamespaceKey(relativePath, isMovie: request.isMovie) else {
            return false
        }
        return !owners.contains { owner in
            owner.id != request.itemID &&
                owner.mediaIdentity != request.mediaIdentity &&
                owner.relativePaths.contains {
                    videoNamespaceKey($0, isMovie: owner.isMovie) == candidateNamespace
                }
        }
    }

    static func allocateVideoRelativePath(
        request: DownloadPathIdentityRequest,
        owners: [DownloadPathIdentityOwner],
        fileExtension: String,
        forceIdentitySuffix: Bool = false,
        isAdditionallyUnavailable: (String) -> Bool = { _ in false }
    ) -> String {
        var suffixes: [String?] = forceIdentitySuffix ? [] : [nil]
        suffixes.append(contentsOf: identitySuffixCandidates(request: request).map(Optional.some))

        for suffix in suffixes {
            let candidate = videoRelativePath(
                request: request,
                fileExtension: fileExtension,
                identitySuffix: suffix
            )
            if videoReservationIsAvailable(candidate, request: request, owners: owners),
               !isAdditionallyUnavailable(candidate) {
                return candidate
            }
        }

        let token = stableIdentityToken(mediaIdentity: request.mediaIdentity)
        for ordinal in 2...999 {
            let suffix = request.tmdbID > 0
                ? "[TMDB \(request.tmdbID) - \(token)-\(ordinal)]"
                : "[ID \(token)-\(ordinal)]"
            let candidate = videoRelativePath(
                request: request,
                fileExtension: fileExtension,
                identitySuffix: suffix
            )
            if videoReservationIsAvailable(candidate, request: request, owners: owners),
               !isAdditionallyUnavailable(candidate) {
                return candidate
            }
        }

        return videoRelativePath(
            request: request,
            fileExtension: fileExtension,
            identitySuffix: "[ID \(token)-overflow]"
        )
    }

    static func videoRelativePath(
        request: DownloadPathIdentityRequest,
        fileExtension: String,
        identitySuffix: String? = nil
    ) -> String {
        let base = fileComponent(request.baseComponent, appending: identitySuffix)
        if request.isMovie {
            return "\(base).\(fileExtension)"
        }
        return "\(base)/\(request.episodeComponent).\(fileExtension)"
    }

    static func subtitleRelativePath(videoRelativePath: String, fileExtension: String) -> String {
        "\((videoRelativePath as NSString).deletingPathExtension).sub.\(fileExtension)"
    }

    static func hlsPartialRelativePath(videoRelativePath: String) -> String {
        let directory = (videoRelativePath as NSString).deletingLastPathComponent
        let fileName = (videoRelativePath as NSString).lastPathComponent
        return directory.isEmpty ? ".\(fileName).partial" : "\(directory)/.\(fileName).partial"
    }

    static func identitySuffixCandidates(request: DownloadPathIdentityRequest) -> [String] {
        let token = stableIdentityToken(mediaIdentity: request.mediaIdentity)
        if request.tmdbID > 0 {
            return ["[TMDB \(request.tmdbID)]", "[TMDB \(request.tmdbID) - \(token)]"]
        }
        return ["[ID \(token)]"]
    }

    static func stableIdentityToken(mediaIdentity: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in mediaIdentity.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(String(hash, radix: 16).prefix(8)).uppercased()
    }

    static func fileComponent(_ base: String, appending suffix: String?) -> String {
        guard let suffix, !suffix.isEmpty else { return String(base.prefix(80)) }
        let suffixWithSpace = " \(suffix)"
        let availableCount = max(1, 80 - suffixWithSpace.count)
        let shortenedBase = String(base.prefix(availableCount))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(shortenedBase)\(suffixWithSpace)"
    }

    private static func videoNamespaceKey(_ relativePath: String, isMovie: Bool) -> String? {
        guard let normalized = normalizedRelativePath(relativePath) else { return nil }
        let components = normalized.split(separator: "/").map(String.init)
        if isMovie {
            guard components.count == 1, var stem = components.last else { return nil }
            stem = (stem as NSString).deletingPathExtension
            if stem.lowercased().hasSuffix(".sub") {
                stem = String(stem.dropLast(4))
            }
            return "movie:\(canonicalString(stem))"
        }
        guard let folder = components.first else { return nil }
        return "show:\(canonicalString(folder))"
    }
}
