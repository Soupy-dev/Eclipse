package dev.soupy.eclipse.android.data

import dev.soupy.eclipse.android.core.network.EclipseJson
import dev.soupy.eclipse.android.core.storage.AppSettings
import dev.soupy.eclipse.android.core.storage.SettingsStore
import java.net.HttpURLConnection
import java.net.URL
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

data class ReleaseCheckSummary(
    val latestVersion: String,
    val releaseUrl: String,
    val updateAvailable: Boolean,
    val checked: Boolean,
)

class ReleaseRepository(
    private val settingsStore: SettingsStore,
    private val currentVersion: String,
) {
    suspend fun checkForUpdatesIfNeeded(): Result<ReleaseCheckSummary?> = runCatching {
        val settings = settingsStore.settings.first()
        if (!settings.githubReleaseAutoCheckEnabled) return@runCatching null
        val now = System.currentTimeMillis()
        val elapsed = now - settings.githubReleaseLastCheckTimestamp
        if (elapsed in 0 until AutoCheckIntervalMillis) return@runCatching null
        checkForUpdates(forcePrompt = false, settings = settings)
    }

    suspend fun checkForUpdates(forcePrompt: Boolean = true): Result<ReleaseCheckSummary> = runCatching {
        checkForUpdates(forcePrompt = forcePrompt, settings = settingsStore.settings.first())
    }

    suspend fun consumePendingPrompt() {
        settingsStore.consumeGitHubReleasePrompt()
    }

    private suspend fun checkForUpdates(
        forcePrompt: Boolean,
        settings: AppSettings,
    ): ReleaseCheckSummary {
        val release = fetchLatestRelease()
        val latestVersion = release.tagName
        val updateAvailable = normalizedVersion(latestVersion).isNewerThan(normalizedVersion(currentVersion))
        val shouldPrompt = updateAvailable &&
            (forcePrompt || settings.githubReleaseLastPromptedVersion != latestVersion)

        settingsStore.saveGitHubReleaseCheck(
            latestVersion = latestVersion,
            releaseUrl = release.htmlUrl,
            updateAvailable = updateAvailable,
            prompt = shouldPrompt,
        )

        return ReleaseCheckSummary(
            latestVersion = latestVersion,
            releaseUrl = release.htmlUrl,
            updateAvailable = updateAvailable,
            checked = true,
        )
    }

    private suspend fun fetchLatestRelease(): GitHubRelease = withContext(Dispatchers.IO) {
        val connection = (URL(GitHubLatestReleaseUrl).openConnection() as HttpURLConnection).apply {
            connectTimeout = 15_000
            readTimeout = 15_000
            requestMethod = "GET"
            setRequestProperty("Accept", "application/vnd.github+json")
            setRequestProperty("User-Agent", "Eclipse-Android")
        }
        try {
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            val body = stream?.bufferedReader()?.use { it.readText() }.orEmpty()
            if (status !in 200..299) {
                error("GitHub release check failed with HTTP $status.")
            }
            EclipseJson.decodeFromString(GitHubRelease.serializer(), body)
        } finally {
            connection.disconnect()
        }
    }
}

@Serializable
private data class GitHubRelease(
    @SerialName("tag_name") val tagName: String,
    @SerialName("html_url") val htmlUrl: String,
)

private const val GitHubLatestReleaseUrl = "https://api.github.com/repos/Soupy-dev/Luna/releases/latest"
private const val AutoCheckIntervalMillis = 6L * 60L * 60L * 1_000L

private fun normalizedVersion(raw: String): String =
    raw.trim().removePrefix("v").removePrefix("V")

private fun String.isNewerThan(other: String): Boolean {
    val left = versionComponents()
    val right = other.versionComponents()
    if (left.isEmpty()) return false
    val maxCount = maxOf(left.size, right.size)
    repeat(maxCount) { index ->
        val l = left.getOrElse(index) { 0 }
        val r = right.getOrElse(index) { 0 }
        if (l > r) return true
        if (l < r) return false
    }
    return false
}

private fun String.versionComponents(): List<Int> {
    val components = mutableListOf<Int>()
    val current = StringBuilder()
    forEach { char ->
        if (char.isDigit()) {
            current.append(char)
        } else if (current.isNotEmpty()) {
            components += current.toString().toIntOrNull() ?: 0
            current.clear()
        }
    }
    if (current.isNotEmpty()) {
        components += current.toString().toIntOrNull() ?: 0
    }
    return components
}
