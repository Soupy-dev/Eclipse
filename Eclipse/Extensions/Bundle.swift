import Foundation

extension Bundle {
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    var buildNumber: String {
        infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
    var releaseVersion: String {
        let version = infoDictionary?["EclipseReleaseVersion"] as? String
        let trimmedVersion = version?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedVersion = trimmedVersion,
           !trimmedVersion.isEmpty,
           !trimmedVersion.hasPrefix("$(") {
            return trimmedVersion
        }
        return appVersion
    }
    var distributionChannel: String {
        let channel = infoDictionary?["EclipseDistributionChannel"] as? String
        let trimmedChannel = channel?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedChannel = trimmedChannel, !trimmedChannel.isEmpty {
            return trimmedChannel
        }
        return "GitHub"
    }
    var isAppleReviewedDistribution: Bool {
        let normalized = distributionChannel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
        return normalized == "testflight" || normalized == "appstore"
    }
    var usesGitHubReleaseUpdates: Bool {
        !isAppleReviewedDistribution
    }
    var allowsNuvioPlugins: Bool {
        !isAppleReviewedDistribution
    }
}

enum GitHubReleaseChecker {
    private static let owner = "Soupy-dev"
    private static let repo = "Eclipse"

    private static let autoCheckEnabledKey = "githubReleaseAutoCheckEnabled"
    private static let lastCheckTimestampKey = "githubReleaseLastCheckTimestamp"
    private static let updateAvailableKey = "githubReleaseUpdateAvailable"
    private static let latestVersionKey = "githubReleaseLatestVersion"
    private static let latestReleaseURLKey = "githubReleaseURL"
    private static let pendingPromptKey = "githubReleaseShowAlertPending"
    private static let lastPromptedVersionKey = "githubReleaseLastPromptedVersion"

    // Keep release checks lightweight and avoid excessive GitHub API calls.
    private static let autoCheckInterval: TimeInterval = 6 * 3600

    static var isGitHubReleaseUpdatesAvailable: Bool {
        Bundle.main.usesGitHubReleaseUpdates
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            autoCheckEnabledKey: true,
            updateAvailableKey: false,
            latestVersionKey: "",
            latestReleaseURLKey: "",
            pendingPromptKey: false,
            lastPromptedVersionKey: ""
        ])
        refreshCachedUpdateStateForCurrentVersion()
    }

    private static var isAutoCheckEnabled: Bool {
        UserDefaults.standard.bool(forKey: autoCheckEnabledKey)
    }

    private static var lastCheckDate: Date? {
        let timestamp = UserDefaults.standard.double(forKey: lastCheckTimestampKey)
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }

    static func checkForUpdatesIfNeeded() async {
        registerDefaults()
        guard isGitHubReleaseUpdatesAvailable else {
            clearCachedUpdateState()
            return
        }
        guard isAutoCheckEnabled else { return }

        if let lastCheckDate,
           Date().timeIntervalSince(lastCheckDate) < autoCheckInterval {
            return
        }

        await checkForUpdates(force: false)
    }

    static func checkForUpdates(force: Bool) async {
        registerDefaults()
        guard isGitHubReleaseUpdatesAvailable else {
            clearCachedUpdateState()
            return
        }

        if !force && !isAutoCheckEnabled {
            return
        }

        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckTimestampKey)

        do {
            let release = try await fetchLatestRelease()
            let latestVersion = normalizedVersionString(from: release.tagName)
            let currentVersion = normalizedVersionString(from: Bundle.main.releaseVersion)
            let updateAvailable = isVersion(latestVersion, newerThan: currentVersion)

            UserDefaults.standard.set(updateAvailable, forKey: updateAvailableKey)
            UserDefaults.standard.set(release.tagName, forKey: latestVersionKey)
            UserDefaults.standard.set(release.htmlUrl, forKey: latestReleaseURLKey)

            if updateAvailable {
                let lastPromptedVersion = UserDefaults.standard.string(forKey: lastPromptedVersionKey) ?? ""
                if lastPromptedVersion != release.tagName {
                    UserDefaults.standard.set(true, forKey: pendingPromptKey)
                }
            } else {
                UserDefaults.standard.set(false, forKey: pendingPromptKey)
            }

            if updateAvailable {
                Logger.shared.log("Update available: currentRelease=\(Bundle.main.releaseVersion), appVersion=\(Bundle.main.appVersion), latest=\(release.tagName)", type: "Update")
            } else {
                Logger.shared.log("App is up to date: currentRelease=\(Bundle.main.releaseVersion), appVersion=\(Bundle.main.appVersion), latest=\(release.tagName)", type: "Update")
            }
        } catch {
            Logger.shared.log("GitHub release check failed: \(error.localizedDescription)", type: "Update")
        }
    }

    static var shouldShowPendingUpdatePrompt: Bool {
        registerDefaults()
        guard isGitHubReleaseUpdatesAvailable else {
            clearCachedUpdateState()
            return false
        }

        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: pendingPromptKey),
              defaults.bool(forKey: updateAvailableKey) else {
            return false
        }

        let latestVersion = defaults.string(forKey: latestVersionKey) ?? ""
        let currentVersion = normalizedVersionString(from: Bundle.main.releaseVersion)
        return isVersion(normalizedVersionString(from: latestVersion), newerThan: currentVersion)
    }

    private static func fetchLatestRelease() async throws -> GitHubRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.custom.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }

        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    private static func normalizedVersionString(from rawValue: String) -> String {
        rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "v", with: "", options: [.caseInsensitive, .anchored])
    }

    private static func versionComponents(from version: String) -> [Int] {
        var components: [Int] = []
        var currentNumber = ""

        for character in version {
            if character.isNumber {
                currentNumber.append(character)
            } else if !currentNumber.isEmpty {
                components.append(Int(currentNumber) ?? 0)
                currentNumber.removeAll(keepingCapacity: true)
            }
        }

        if !currentNumber.isEmpty {
            components.append(Int(currentNumber) ?? 0)
        }

        return components
    }

    private static func isVersion(_ left: String, newerThan right: String) -> Bool {
        let leftComponents = versionComponents(from: left)
        let rightComponents = versionComponents(from: right)

        guard !leftComponents.isEmpty else { return false }

        let maxCount = max(leftComponents.count, rightComponents.count)
        for index in 0..<maxCount {
            let l = index < leftComponents.count ? leftComponents[index] : 0
            let r = index < rightComponents.count ? rightComponents[index] : 0

            if l > r { return true }
            if l < r { return false }
        }

        return false
    }

    private static func refreshCachedUpdateStateForCurrentVersion() {
        guard isGitHubReleaseUpdatesAvailable else {
            clearCachedUpdateState()
            return
        }

        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: updateAvailableKey) || defaults.bool(forKey: pendingPromptKey) else {
            return
        }

        let latestVersion = normalizedVersionString(from: defaults.string(forKey: latestVersionKey) ?? "")
        let currentVersion = normalizedVersionString(from: Bundle.main.releaseVersion)
        guard !latestVersion.isEmpty else {
            defaults.set(false, forKey: updateAvailableKey)
            defaults.set(false, forKey: pendingPromptKey)
            return
        }

        guard !isVersion(latestVersion, newerThan: currentVersion) else {
            return
        }

        defaults.set(false, forKey: updateAvailableKey)
        defaults.set(false, forKey: pendingPromptKey)
    }

    private static func clearCachedUpdateState() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: updateAvailableKey)
        defaults.set(false, forKey: pendingPromptKey)
        defaults.set("", forKey: latestVersionKey)
        defaults.set("", forKey: latestReleaseURLKey)
    }

    static func consumePendingUpdatePrompt() {
        let latestVersion = UserDefaults.standard.string(forKey: latestVersionKey) ?? ""
        UserDefaults.standard.set(false, forKey: pendingPromptKey)

        if !latestVersion.isEmpty {
            UserDefaults.standard.set(latestVersion, forKey: lastPromptedVersionKey)
        }
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlUrl: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlUrl = "html_url"
    }
}

