package dev.soupy.eclipse.android.data

import android.net.Uri
import dev.soupy.eclipse.android.core.model.DetailTarget
import dev.soupy.eclipse.android.core.model.EpisodeProgressBackup
import dev.soupy.eclipse.android.core.model.MangaLibrarySnapshot
import dev.soupy.eclipse.android.core.model.MangaProgress
import dev.soupy.eclipse.android.core.model.MovieProgressBackup
import dev.soupy.eclipse.android.core.model.TrackerAccountSnapshot
import dev.soupy.eclipse.android.core.model.TrackerStateSnapshot
import dev.soupy.eclipse.android.core.model.progressPercent
import dev.soupy.eclipse.android.core.network.EclipseHttpClient
import dev.soupy.eclipse.android.core.network.EclipseJson
import dev.soupy.eclipse.android.core.network.NetworkResult
import dev.soupy.eclipse.android.core.storage.TrackerStore
import java.time.Instant
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

data class TrackerAccountDraft(
    val service: String,
    val username: String,
    val accessToken: String,
    val refreshToken: String? = null,
    val expiresAt: String? = null,
    val userId: String = "",
)

private data class AniListMangaProgressSyncItem(
    val mediaId: Int,
    val progress: Int,
    val isComplete: Boolean,
)

class TrackerRepository(
    private val trackerStore: TrackerStore,
    private val progressRepository: ProgressRepository,
    private val syncClient: TrackerSyncClient = TrackerSyncClient(),
    private val httpClient: EclipseHttpClient = EclipseHttpClient(),
) {
    suspend fun loadSnapshot(): Result<TrackerStateSnapshot> = runCatching {
        trackerStore.read()
    }

    fun authorizationUrl(service: String): String? =
        service.oauthProvider()?.authorizationUrl()

    suspend fun exchangeOAuthCallback(callbackUri: String): Result<TrackerStateSnapshot> = runCatching {
        val uri = Uri.parse(callbackUri)
        val provider = OAuthProvider.entries.firstOrNull { candidate ->
            uri.scheme.equals("luna", ignoreCase = true) &&
                uri.host.equals(candidate.callbackHost, ignoreCase = true)
        } ?: error("Eclipse received an unsupported tracker callback.")

        uri.getQueryParameter("error")
            ?.takeIf { it.isNotBlank() }
            ?.let { error("Tracker authorization was cancelled: $it") }

        val code = uri.getQueryParameter("code")?.trim()
            ?: error("Tracker callback did not include an authorization code.")
        require(code.isNotBlank()) { "Tracker callback did not include an authorization code." }

        val token = exchangeAuthorizationCode(provider, code)
        val identity = fetchIdentity(provider, token.accessToken).getOrDefault(TrackerIdentity())
        saveManualAccount(
            TrackerAccountDraft(
                service = provider.service,
                username = identity.username,
                accessToken = token.accessToken,
                refreshToken = token.refreshToken,
                expiresAt = token.expiresAtFromNow(),
                userId = identity.userId,
            ),
        ).getOrThrow()
    }

    suspend fun restoreFromBackup(snapshot: TrackerStateSnapshot): Result<TrackerStateSnapshot> = runCatching {
        trackerStore.write(snapshot)
        snapshot
    }

    suspend fun saveManualAccount(draft: TrackerAccountDraft): Result<TrackerStateSnapshot> = runCatching {
        val service = draft.service.trim().ifBlank { "Tracker" }
        val accessToken = draft.accessToken.trim()
        require(accessToken.isNotBlank()) { "Tracker token or PIN is required." }

        val current = trackerStore.read()
        val account = TrackerAccountSnapshot(
            service = service,
            username = draft.username.trim(),
            accessToken = accessToken,
            refreshToken = draft.refreshToken?.trim()?.takeIf(String::isNotBlank),
            expiresAt = draft.expiresAt?.trim()?.takeIf(String::isNotBlank),
            userId = draft.userId.trim(),
            isConnected = true,
        )
        val accounts = listOf(account) + current.accounts.filterNot {
            it.service.equals(service, ignoreCase = true)
        }
        val updated = current.copy(
            accounts = accounts,
            syncEnabled = current.syncEnabled,
            lastSyncDate = current.lastSyncDate,
            provider = service,
            accessToken = accessToken,
            refreshToken = account.refreshToken,
            userName = account.username.takeIf(String::isNotBlank),
        )
        trackerStore.write(updated)
        updated
    }

    suspend fun setSyncEnabled(enabled: Boolean): Result<TrackerStateSnapshot> = runCatching {
        val updated = trackerStore.read().copy(syncEnabled = enabled)
        trackerStore.write(updated)
        updated
    }

    suspend fun markSyncAttempted(): Result<TrackerStateSnapshot> = runCatching {
        val updated = trackerStore.read().copy(lastSyncDate = Instant.now().toString())
        trackerStore.write(updated)
        updated
    }

    suspend fun syncPlaybackProgress(draft: TrackerPlaybackProgressDraft): Result<TrackerSyncSummary> = runCatching {
        syncItems(listOf(draft.toTrackerSyncItem()))
    }

    suspend fun syncStoredProgress(): Result<TrackerSyncSummary> = runCatching {
        val progress = progressRepository.loadSnapshot().getOrThrow()
        val showTitles = progress.showMetadata.mapValues { (_, metadata) -> metadata.title }
        val items = progress.movieProgress
            .filter { it.isWatched || it.progressPercent >= TrackerWatchedThreshold }
            .map(MovieProgressBackup::toTrackerSyncItem) +
            progress.episodeProgress
                .filter { it.isWatched || it.progressPercent >= TrackerWatchedThreshold }
                .map { episode -> episode.toTrackerSyncItem(showTitles[episode.showId.toString()]) }

        syncItems(items)
    }

    suspend fun syncStoredMangaProgress(snapshot: MangaLibrarySnapshot): Result<TrackerSyncSummary> = runCatching {
        val state = trackerStore.read()
        val originalAccounts = state.connectedAccounts().filter { account ->
            account.service.normalizedTrackerService() == "anilist"
        }
        val accounts = originalAccounts.toMutableList()
        val items = snapshot.toAniListMangaProgressSyncItems()

        if (!state.syncEnabled || accounts.isEmpty() || items.isEmpty()) {
            return@runCatching TrackerSyncSummary(
                state = state,
                attemptedAccounts = if (state.syncEnabled) accounts.size else 0,
                attemptedItems = items.size,
                skippedItems = if (!state.syncEnabled) items.size else 0,
            )
        }

        var syncedItems = 0
        var skippedItems = 0
        val failures = mutableListOf<String>()

        accounts.indices.forEach { accountIndex ->
            var account = accounts[accountIndex].refreshIfNeeded()
                .onFailure { error -> failures += error.message ?: "Token refresh failed for ${accounts[accountIndex].service}." }
                .getOrDefault(accounts[accountIndex])
            accounts[accountIndex] = account
            items.forEach { item ->
                var result = syncAniListMangaProgress(account, item)
                if (result.isAuthFailure && !account.refreshToken.isNullOrBlank()) {
                    account.refreshIfNeeded(force = true)
                        .onSuccess { refreshed ->
                            account = refreshed
                            accounts[accountIndex] = refreshed
                            result = syncAniListMangaProgress(refreshed, item)
                        }
                        .onFailure { error ->
                            failures += error.message ?: "Token refresh failed for ${account.service}."
                        }
                }
                when {
                    result.synced -> syncedItems += 1
                    result.skipped -> skippedItems += 1
                    result.message != null -> failures += result.message
                    else -> skippedItems += 1
                }
            }
        }

        val refreshedState = if (accounts != originalAccounts) {
            state.withAccounts(
                accounts = state.connectedAccounts()
                    .filterNot { account -> account.service.normalizedTrackerService() == "anilist" } + accounts,
            )
        } else {
            state
        }
        val updatedState = if (syncedItems > 0 || failures.isNotEmpty()) {
            refreshedState.copy(lastSyncDate = Instant.now().toString())
        } else {
            refreshedState
        }
        if (updatedState != state) {
            trackerStore.write(updatedState)
        }

        TrackerSyncSummary(
            state = updatedState,
            attemptedAccounts = accounts.size,
            attemptedItems = items.size,
            syncedItems = syncedItems,
            skippedItems = skippedItems,
            failures = failures,
        )
    }

    suspend fun disconnect(service: String): Result<TrackerStateSnapshot> = runCatching {
        val normalized = service.trim()
        require(normalized.isNotBlank()) { "Tracker service is required." }
        val current = trackerStore.read()
        val accounts = current.accounts.filterNot {
            it.service.equals(normalized, ignoreCase = true)
        }
        val primary = accounts.firstOrNull()
        val updated = current.copy(
            accounts = accounts,
            provider = primary?.service,
            accessToken = primary?.accessToken,
            refreshToken = primary?.refreshToken,
            userName = primary?.username,
        )
        trackerStore.write(updated)
        updated
    }

    suspend fun exportState(fallback: TrackerStateSnapshot): TrackerStateSnapshot {
        val state = trackerStore.read()
        return if (state.accounts.isNotEmpty() || state.accessToken != null || state.provider != null) {
            state
        } else {
            fallback
        }
    }

    private suspend fun syncItems(items: List<TrackerSyncItem>): TrackerSyncSummary {
        val state = trackerStore.read()
        val originalAccounts = state.connectedAccounts()
        val accounts = originalAccounts.toMutableList()
        if (!state.syncEnabled || accounts.isEmpty() || items.isEmpty()) {
            return TrackerSyncSummary(
                state = state,
                attemptedAccounts = if (state.syncEnabled) accounts.size else 0,
                attemptedItems = items.size,
                skippedItems = if (!state.syncEnabled) items.size else 0,
            )
        }

        var syncedItems = 0
        var skippedItems = 0
        val failures = mutableListOf<String>()

        accounts.indices.forEach { accountIndex ->
            var account = accounts[accountIndex].refreshIfNeeded()
                .onFailure { error -> failures += error.message ?: "Token refresh failed for ${accounts[accountIndex].service}." }
                .getOrDefault(accounts[accountIndex])
            accounts[accountIndex] = account
            items.forEach { item ->
                var result = syncClient.sync(account, item)
                if (result.isAuthFailure && !account.refreshToken.isNullOrBlank()) {
                    account.refreshIfNeeded(force = true)
                        .onSuccess { refreshed ->
                            account = refreshed
                            accounts[accountIndex] = refreshed
                            result = syncClient.sync(refreshed, item)
                        }
                        .onFailure { error ->
                            failures += error.message ?: "Token refresh failed for ${account.service}."
                        }
                }
                when {
                    result.synced -> syncedItems += 1
                    result.skipped -> skippedItems += 1
                    result.message != null -> failures += result.message
                    else -> skippedItems += 1
                }
            }
        }

        val refreshedState = if (accounts != originalAccounts) {
            state.withAccounts(accounts)
        } else {
            state
        }
        val updatedState = if (syncedItems > 0 || failures.isNotEmpty()) {
            refreshedState.copy(lastSyncDate = Instant.now().toString())
        } else {
            refreshedState
        }
        if (updatedState != state) {
            trackerStore.write(updatedState)
        }

        return TrackerSyncSummary(
            state = updatedState,
            attemptedAccounts = accounts.size,
            attemptedItems = items.size,
            syncedItems = syncedItems,
            skippedItems = skippedItems,
            failures = failures,
        )
    }

    private suspend fun exchangeAuthorizationCode(
        provider: OAuthProvider,
        code: String,
    ): OAuthTokenResponse {
        val body = EclipseJson.encodeToString(
            OAuthTokenRequest(
                grantType = "authorization_code",
                clientId = provider.clientId,
                clientSecret = provider.clientSecret,
                redirectUri = provider.redirectUri,
                code = code,
            ),
        )

        return when (val result = httpClient.postJson(provider.tokenUrl, body)) {
            is NetworkResult.Success -> {
                val response = EclipseJson.decodeFromString(OAuthTokenResponse.serializer(), result.value)
                require(response.accessToken.isNotBlank()) {
                    "${provider.service} did not return an access token."
                }
                response
            }
            is NetworkResult.Failure -> error(result.toTrackerOAuthMessage("${provider.service} token exchange failed."))
        }
    }

    private suspend fun exchangeRefreshToken(
        provider: OAuthProvider,
        refreshToken: String,
    ): OAuthTokenResponse {
        val body = EclipseJson.encodeToString(
            OAuthTokenRequest(
                grantType = "refresh_token",
                clientId = provider.clientId,
                clientSecret = provider.clientSecret,
                redirectUri = provider.redirectUri,
                refreshToken = refreshToken,
            ),
        )

        return when (val result = httpClient.postJson(provider.tokenUrl, body)) {
            is NetworkResult.Success -> {
                val response = EclipseJson.decodeFromString(OAuthTokenResponse.serializer(), result.value)
                require(response.accessToken.isNotBlank()) {
                    "${provider.service} did not return an access token."
                }
                response
            }
            is NetworkResult.Failure -> error(result.toTrackerOAuthMessage("${provider.service} token refresh failed."))
        }
    }

    private suspend fun fetchIdentity(
        provider: OAuthProvider,
        accessToken: String,
    ): Result<TrackerIdentity> = runCatching {
        when (provider) {
            OAuthProvider.AniList -> fetchAniListIdentity(accessToken)
            OAuthProvider.Trakt -> fetchTraktIdentity(accessToken)
        }
    }

    private suspend fun fetchAniListIdentity(accessToken: String): TrackerIdentity {
        val body = EclipseJson.encodeToString(
            buildJsonObject {
                put("query", AniListViewerQuery)
            },
        )
        return when (
            val result = httpClient.postJson(
                url = "https://graphql.anilist.co",
                body = body,
                headers = accessToken.bearerAuthorizationHeader(),
            )
        ) {
            is NetworkResult.Success -> {
                val viewer = EclipseJson.parseToJsonElement(result.value)
                    .jsonObject["data"]
                    ?.jsonObject
                    ?.get("Viewer")
                    ?.jsonObject
                TrackerIdentity(
                    username = viewer?.get("name")?.jsonPrimitive?.contentOrNull.orEmpty(),
                    userId = viewer?.get("id")?.jsonPrimitive?.intOrNull?.toString().orEmpty(),
                )
            }
            is NetworkResult.Failure -> error(result.toTrackerOAuthMessage("AniList identity lookup failed."))
        }
    }

    private suspend fun fetchTraktIdentity(accessToken: String): TrackerIdentity {
        return when (
            val result = httpClient.get(
                url = "https://api.trakt.tv/users/settings",
                headers = accessToken.bearerAuthorizationHeader() + mapOf(
                    "trakt-api-key" to OAuthProvider.Trakt.clientId,
                    "trakt-api-version" to "2",
                ),
            )
        ) {
            is NetworkResult.Success -> {
                val user = EclipseJson.parseToJsonElement(result.value)
                    .jsonObject["user"]
                    ?.jsonObject
                TrackerIdentity(
                    username = user?.get("username")?.jsonPrimitive?.contentOrNull.orEmpty(),
                    userId = user?.get("ids")
                        ?.jsonObject
                        ?.get("slug")
                        ?.jsonPrimitive
                        ?.contentOrNull
                        .orEmpty(),
                )
            }
            is NetworkResult.Failure -> error(result.toTrackerOAuthMessage("Trakt identity lookup failed."))
        }
    }

    private suspend fun syncAniListMangaProgress(
        account: TrackerAccountSnapshot,
        item: AniListMangaProgressSyncItem,
    ): TrackerItemSyncResult {
        if (!account.isConnected || account.accessToken.isBlank()) {
            return TrackerItemSyncResult(skipped = true, message = "AniList is not connected.")
        }
        val body = EclipseJson.encodeToString(
            buildJsonObject {
                put("query", aniListSaveMangaProgressMutation(item))
            },
        )
        return when (
            val result = httpClient.postJson(
                url = "https://graphql.anilist.co",
                body = body,
                headers = account.accessToken.bearerAuthorizationHeader(),
            )
        ) {
            is NetworkResult.Success -> {
                val error = result.value.graphQlErrorMessage()
                if (error == null) {
                    TrackerItemSyncResult(synced = true)
                } else {
                    TrackerItemSyncResult(message = "AniList manga: $error")
                }
            }
            is NetworkResult.Failure -> TrackerItemSyncResult(
                message = result.toTrackerOAuthMessage("AniList manga sync failed."),
            )
        }
    }

    private suspend fun TrackerAccountSnapshot.refreshIfNeeded(
        force: Boolean = false,
    ): Result<TrackerAccountSnapshot> = runCatching {
        val provider = service.oauthProvider() ?: return@runCatching this
        val savedRefreshToken = refreshToken?.trim()?.takeIf(String::isNotBlank)
            ?: return@runCatching this
        if (!force && !shouldRefreshToken()) return@runCatching this

        val response = exchangeRefreshToken(provider, savedRefreshToken)
        copy(
            accessToken = response.accessToken,
            refreshToken = response.refreshToken?.trim()?.takeIf(String::isNotBlank) ?: savedRefreshToken,
            expiresAt = response.expiresAtFromNow() ?: expiresAt,
        )
    }
}

private enum class OAuthProvider(
    val service: String,
    val callbackHost: String,
    val authorizeUrl: String,
    val tokenUrl: String,
    val clientId: String,
    val clientSecret: String,
    val redirectUri: String,
) {
    AniList(
        service = "AniList",
        callbackHost = "anilist-callback",
        authorizeUrl = "https://anilist.co/api/v2/oauth/authorize",
        tokenUrl = "https://anilist.co/api/v2/oauth/token",
        clientId = "33908",
        clientSecret = "1TeOfbdHy3Uk88UQdE8HKoJDtdI5ARHP4sDCi5Jh",
        redirectUri = "luna://anilist-callback",
    ),
    Trakt(
        service = "Trakt",
        callbackHost = "trakt-callback",
        authorizeUrl = "https://trakt.tv/oauth/authorize",
        tokenUrl = "https://api.trakt.tv/oauth/token",
        clientId = "e92207aaef82a1b0b42d5901efa4756b6c417911b7b031b986d37773c234ccab",
        clientSecret = "03c457ea5986e900f140243c69d616313533cedcc776e42e07a6ddd3ab699035",
        redirectUri = "luna://trakt-callback",
    );

    fun authorizationUrl(): String =
        Uri.parse(authorizeUrl)
            .buildUpon()
            .appendQueryParameter("client_id", clientId)
            .appendQueryParameter("redirect_uri", redirectUri)
            .appendQueryParameter("response_type", "code")
            .build()
            .toString()
}

@Serializable
private data class OAuthTokenRequest(
    @SerialName("grant_type") val grantType: String,
    @SerialName("client_id") val clientId: String,
    @SerialName("client_secret") val clientSecret: String,
    @SerialName("redirect_uri") val redirectUri: String,
    val code: String? = null,
    @SerialName("refresh_token") val refreshToken: String? = null,
)

@Serializable
private data class OAuthTokenResponse(
    @SerialName("access_token") val accessToken: String,
    @SerialName("refresh_token") val refreshToken: String? = null,
    @SerialName("expires_in") val expiresIn: Long? = null,
)

private data class TrackerIdentity(
    val username: String = "",
    val userId: String = "",
)

private fun OAuthTokenResponse.expiresAtFromNow(now: Instant = Instant.now()): String? =
    expiresIn
        ?.takeIf { it > 0 }
        ?.let { seconds -> now.plusSeconds(seconds).toString() }

private fun String.oauthProvider(): OAuthProvider? {
    val normalized = normalizedTrackerService()
    return OAuthProvider.entries.firstOrNull { provider ->
        provider.service.normalizedTrackerService() == normalized
    }
}

private fun String.bearerAuthorizationHeader(): Map<String, String> =
    mapOf("Authorization" to "Bearer $this")

private fun NetworkResult.Failure.toTrackerOAuthMessage(prefix: String): String = when (this) {
    is NetworkResult.Failure.Http -> "$prefix HTTP $code${body?.takeIf { it.isNotBlank() }?.let { ": $it" }.orEmpty()}"
    is NetworkResult.Failure.Connectivity -> "$prefix ${throwable.message ?: "network unavailable"}"
    is NetworkResult.Failure.Serialization -> "$prefix ${throwable.message ?: "unexpected response"}"
}

private val TrackerItemSyncResult.isAuthFailure: Boolean
    get() = message?.contains("HTTP 401", ignoreCase = true) == true ||
        message?.contains("unauthorized", ignoreCase = true) == true ||
        message?.contains("invalid token", ignoreCase = true) == true

private fun TrackerAccountSnapshot.shouldRefreshToken(now: Instant = Instant.now()): Boolean =
    expiresAt
        ?.let { value -> runCatching { Instant.parse(value) }.getOrNull() }
        ?.isBefore(now.plusSeconds(300))
        ?: false

private fun MangaLibrarySnapshot.toAniListMangaProgressSyncItems(): List<AniListMangaProgressSyncItem> =
    readingProgress.mapNotNull { (progressId, progress) ->
        val mediaId = progress.aniListMediaId(progressId) ?: return@mapNotNull null
        val chapter = progress.lastReadChapterNumber().takeIf { it > 0 } ?: return@mapNotNull null
        AniListMangaProgressSyncItem(
            mediaId = mediaId,
            progress = chapter,
            isComplete = progress.totalChapters?.takeIf { it > 0 }?.let { total -> chapter >= total } == true,
        )
    }.groupBy { item -> item.mediaId }
        .values
        .map { entries ->
            entries.maxBy { item -> item.progress }.copy(
                isComplete = entries.any { item -> item.isComplete },
            )
        }

private fun MangaProgress.aniListMediaId(progressId: String): Int? =
    contentParams
        ?.substringAfter("anilist:", missingDelimiterValue = "")
        ?.toIntOrNull()
        ?.takeIf { it > 0 }
        ?: progressId
            .substringAfter("anilist-manga:", missingDelimiterValue = "")
            .toIntOrNull()
            ?.takeIf { it > 0 }
        ?: progressId.toIntOrNull()?.takeIf { it > 0 }

private fun MangaProgress.lastReadChapterNumber(): Int =
    lastReadChapter?.toIntOrNull()
        ?: readChapterNumbers.mapNotNull(String::toIntOrNull).maxOrNull()
        ?: 0

private fun aniListSaveMangaProgressMutation(item: AniListMangaProgressSyncItem): String = """
    mutation {
        SaveMediaListEntry(
            mediaId: ${item.mediaId},
            progress: ${item.progress},
            status: ${if (item.isComplete) "COMPLETED" else "CURRENT"}
        ) {
            id
            progress
            status
        }
    }
""".trimIndent()

private fun String.graphQlErrorMessage(): String? =
    runCatching {
        val root = EclipseJson.parseToJsonElement(this).jsonObject
        root["errors"]?.jsonArray?.firstOrNull()?.jsonObject?.get("message")?.toString()?.trim('"')
    }.getOrNull()

private const val AniListViewerQuery = """
    query Viewer {
      Viewer {
        id
        name
      }
    }
"""

private fun TrackerStateSnapshot.connectedAccounts(): List<TrackerAccountSnapshot> {
    val modern = accounts.filter { it.isConnected && it.accessToken.isNotBlank() }
    if (modern.isNotEmpty()) return modern
    val provider = provider?.takeIf { it.isNotBlank() }
    val token = accessToken?.takeIf { it.isNotBlank() }
    return if (provider != null && token != null) {
        listOf(
            TrackerAccountSnapshot(
                service = provider,
                username = userName.orEmpty(),
                accessToken = token,
                refreshToken = refreshToken,
                isConnected = true,
            ),
        )
    } else {
        emptyList()
    }
}

private fun TrackerStateSnapshot.withAccounts(accounts: List<TrackerAccountSnapshot>): TrackerStateSnapshot {
    val connected = accounts.filter { account -> account.isConnected && account.accessToken.isNotBlank() }
    val primary = connected.firstOrNull { account ->
        provider?.let { currentProvider -> account.service.equals(currentProvider, ignoreCase = true) } == true
    } ?: connected.firstOrNull()
    return copy(
        accounts = connected,
        provider = primary?.service ?: provider,
        accessToken = primary?.accessToken ?: accessToken,
        refreshToken = primary?.refreshToken ?: refreshToken,
        userName = primary?.username?.takeIf(String::isNotBlank) ?: userName,
    )
}

private fun MovieProgressBackup.toTrackerSyncItem(): TrackerSyncItem = TrackerSyncItem(
    target = DetailTarget.TmdbMovie(id),
    title = title.ifBlank { "Movie $id" },
    progressPercent = progressPercent,
    isFinished = isWatched,
)

private fun EpisodeProgressBackup.toTrackerSyncItem(showTitle: String?): TrackerSyncItem = TrackerSyncItem(
    target = DetailTarget.TmdbShow(showId),
    title = showTitle?.takeIf { it.isNotBlank() } ?: "Show $showId",
    seasonNumber = seasonNumber,
    episodeNumber = episodeNumber,
    anilistMediaId = anilistMediaId,
    anilistEpisodeNumber = episodeNumber,
    progressPercent = progressPercent,
    isFinished = isWatched,
)
