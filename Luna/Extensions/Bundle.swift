//
//  Bundle.swift
//  Luna
//
//  Created by Dominic on 04.11.25.
//

import Foundation

extension Bundle {
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    var buildNumber: String {
        infoDictionary?["CFBundleVersion"] as? String ?? "1"
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

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            autoCheckEnabledKey: true,
            updateAvailableKey: false,
            latestVersionKey: "",
            latestReleaseURLKey: "",
            pendingPromptKey: false,
            lastPromptedVersionKey: ""
        ])
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
        guard isAutoCheckEnabled else { return }

        if let lastCheckDate,
           Date().timeIntervalSince(lastCheckDate) < autoCheckInterval {
            return
        }

        await checkForUpdates(force: false)
    }

    static func checkForUpdates(force: Bool) async {
        registerDefaults()

        if !force && !isAutoCheckEnabled {
            return
        }

        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckTimestampKey)

        do {
            let release = try await fetchLatestRelease()
            let latestVersion = normalizedVersionString(from: release.tagName)
            let currentVersion = normalizedVersionString(from: Bundle.main.appVersion)
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
                Logger.shared.log("Update available: current=\(Bundle.main.appVersion), latest=\(release.tagName)", type: "Update")
            } else {
                Logger.shared.log("App is up to date: current=\(Bundle.main.appVersion), latest=\(release.tagName)", type: "Update")
            }
        } catch {
            Logger.shared.log("GitHub release check failed: \(error.localizedDescription)", type: "Update")
        }
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

