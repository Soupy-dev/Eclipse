package dev.soupy.eclipse.android.data

import android.net.Uri
import dev.soupy.eclipse.android.core.model.DetailTarget
import dev.soupy.eclipse.android.core.model.EpisodeProgressBackup
import dev.soupy.eclipse.android.core.model.MangaLibrarySnapshot
import dev.soupy.eclipse.android.core.model.MangaProgress
import dev.soupy.eclipse.android.core.model.MovieProgressBackup
import dev.soupy.eclipse.android.core.model.TrackerAccountSnapshot
import dev.soupy.eclipse.android.core.model.TrackerStateSnapshot
import dev.soupy.eclipse.android.core.model.normalizedUserRatingOutOf10
import dev.soupy.eclipse.android.core.model.progressPercent
import dev.soupy.eclipse.android.core.network.EclipseHttpClient
import dev.soupy.eclipse.android.core.network.EclipseJson
import dev.soupy.eclipse.android.core.network.NetworkResult
import dev.soupy.eclipse.android.core.storage.TrackerStore
import java.security.SecureRandom
import java.time.Instant
import kotlin.math.roundToInt
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

data class TrackerLocalSyncCandidateCounts(
    val animeItems: Int = 0,
    val mangaItems: Int = 0,
) {
    val totalItems: Int
        get() = animeItems + mangaItems
}

data class TrackerRemoteAnimeProgress(
    val aniListId: Int,
    val title: String = "",
    val progress: Int,
    val isComplete: Boolean = false,
)

data class TrackerRemoteMangaProgress(
    val aniListId: Int,
    val progress: Int,
    val isComplete: Boolean = false,
)

class TrackerRepository(
    private val trackerStore: TrackerStore,
    private val progressRepository: ProgressRepository,
    private val syncClient: TrackerSyncClient = TrackerSyncClient(),
    private val httpClient: EclipseHttpClient = EclipseHttpClient(),
    private val myAnimeListClientId: String = "",
    private val myAnimeListClientSecret: String = "",
) {
    private val aniListToMalAnimeIdCache = mutableMapOf<Int, Int>()
    private val aniListToMalMangaIdCache = mutableMapOf<Int, Int>()
    private var pendingMyAnimeListCodeVerifier: String? = null

    suspend fun loadSnapshot(): Result<TrackerStateSnapshot> = runCatching {
        trackerStore.read()
    }

    fun authorizationUrl(service: String): String? =
        if (service.isMyAnimeListService()) {
            myAnimeListAuthorizationUrl()
        } else {
            service.oauthProvider()?.authorizationUrl()
        }

    suspend fun exchangeOAuthCallback(callbackUri: String): Result<TrackerStateSnapshot> = runCatching {
        val uri = Uri.parse(callbackUri)
        if (
            uri.scheme.equals("luna", ignoreCase = true) &&
            uri.host.equals(MyAnimeListCallbackHost, ignoreCase = true)
        ) {
            return@runCatching exchangeMyAnimeListOAuthCallback(uri)
        }

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

    suspend fun setAutoSyncRatings(enabled: Boolean): Result<TrackerStateSnapshot> = runCatching {
        val updated = trackerStore.read().copy(autoSyncRatings = enabled)
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

    suspend fun syncStoredProgress(
        targetService: String? = null,
        respectSyncEnabled: Boolean = true,
    ): Result<TrackerSyncSummary> = runCatching {
        val progress = progressRepository.loadSnapshot().getOrThrow()
        val showTitles = progress.showMetadata.mapValues { (_, metadata) -> metadata.title }
        val items = progress.movieProgress
            .filter { it.isWatched || it.progressPercent >= TrackerWatchedThreshold }
            .map(MovieProgressBackup::toTrackerSyncItem) +
            progress.episodeProgress
                .filter { it.isWatched || it.progressPercent >= TrackerWatchedThreshold }
                .map { episode -> episode.toTrackerSyncItem(showTitles[episode.showId.toString()]) }

        syncItems(
            items = items,
            targetService = targetService,
            respectSyncEnabled = respectSyncEnabled,
        )
    }

    suspend fun localSyncCandidateCounts(snapshot: MangaLibrarySnapshot): Result<TrackerLocalSyncCandidateCounts> = runCatching {
        val progress = progressRepository.loadSnapshot().getOrThrow()
        val animeItems = progress.movieProgress.count { it.isWatched || it.progressPercent >= TrackerWatchedThreshold } +
            progress.episodeProgress.count { it.isWatched || it.progressPercent >= TrackerWatchedThreshold }
        TrackerLocalSyncCandidateCounts(
            animeItems = animeItems,
            mangaItems = snapshot.toAniListMangaProgressSyncItems().size,
        )
    }

    suspend fun syncStoredMangaProgress(
        snapshot: MangaLibrarySnapshot,
        targetService: String? = null,
        respectSyncEnabled: Boolean = true,
    ): Result<TrackerSyncSummary> = runCatching {
        val state = trackerStore.read()
        val connectedAccounts = state.connectedAccounts()
        val originalAccounts = connectedAccounts
            .filter { account -> account.service.normalizedTrackerService() in MangaTrackerServices }
            .filter { account -> targetService == null || account.service.matchesTrackerService(targetService) }
        val accounts = originalAccounts.toMutableList()
        val items = snapshot.toAniListMangaProgressSyncItems()

        if ((respectSyncEnabled && !state.syncEnabled) || accounts.isEmpty() || items.isEmpty()) {
            return@runCatching TrackerSyncSummary(
                state = state,
                attemptedAccounts = if (!respectSyncEnabled || state.syncEnabled) accounts.size else 0,
                attemptedItems = items.size,
                skippedItems = if (respectSyncEnabled && !state.syncEnabled) items.size else 0,
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
                var result = syncMangaProgress(account, item)
                if (result.isAuthFailure && !account.refreshToken.isNullOrBlank()) {
                    account.refreshIfNeeded(force = true)
                        .onSuccess { refreshed ->
                            account = refreshed
                            accounts[accountIndex] = refreshed
                            result = syncMangaProgress(refreshed, item)
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
            state.withAccounts(connectedAccounts.replaceAccounts(originalAccounts, accounts))
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

    suspend fun syncRemoteAnimeProgress(
        targetService: String,
        entries: List<TrackerRemoteAnimeProgress>,
    ): Result<TrackerSyncSummary> = runCatching {
        val items = entries
            .filter { entry -> entry.aniListId > 0 && entry.progress > 0 }
            .map { entry ->
                TrackerSyncItem(
                    target = DetailTarget.AniListMediaTarget(entry.aniListId),
                    title = entry.title,
                    anilistMediaId = entry.aniListId,
                    anilistEpisodeNumber = entry.progress,
                    progressPercent = 1.0,
                    isFinished = entry.isComplete,
                )
            }
        syncItems(
            items = items,
            targetService = targetService,
            respectSyncEnabled = false,
        )
    }

    suspend fun syncRemoteMangaProgress(
        targetService: String,
        entries: List<TrackerRemoteMangaProgress>,
    ): Result<TrackerSyncSummary> = runCatching {
        val state = trackerStore.read()
        val connectedAccounts = state.connectedAccounts()
        val originalAccounts = connectedAccounts
            .filter { account -> account.service.normalizedTrackerService() in MangaTrackerServices }
            .filter { account -> account.service.matchesTrackerService(targetService) }
        val accounts = originalAccounts.toMutableList()
        val items = entries
            .filter { entry -> entry.aniListId > 0 && entry.progress > 0 }
            .map { entry ->
                AniListMangaProgressSyncItem(
                    mediaId = entry.aniListId,
                    progress = entry.progress,
                    isComplete = entry.isComplete,
                )
            }

        if (accounts.isEmpty() || items.isEmpty()) {
            return@runCatching TrackerSyncSummary(
                state = state,
                attemptedAccounts = accounts.size,
                attemptedItems = items.size,
                skippedItems = 0,
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
                var result = syncMangaProgress(account, item)
                if (result.isAuthFailure && !account.refreshToken.isNullOrBlank()) {
                    account.refreshIfNeeded(force = true)
                        .onSuccess { refreshed ->
                            account = refreshed
                            accounts[accountIndex] = refreshed
                            result = syncMangaProgress(refreshed, item)
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
            state.withAccounts(connectedAccounts.replaceAccounts(originalAccounts, accounts))
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

    suspend fun syncUserRating(
        anilistMediaId: Int?,
        ratingOutOf10: Double,
    ): Result<TrackerSyncSummary> = runCatching {
        val mediaId = anilistMediaId?.takeIf { it > 0 }
        val state = trackerStore.read()
        val originalAccounts = state.connectedAccounts().filter { account ->
            account.service.normalizedTrackerService() in RatingTrackerServices
        }
        if (!state.syncEnabled || !state.autoSyncRatings || mediaId == null || originalAccounts.isEmpty()) {
            return@runCatching TrackerSyncSummary(
                state = state,
                attemptedAccounts = if (state.syncEnabled && state.autoSyncRatings) originalAccounts.size else 0,
                attemptedItems = if (mediaId == null) 0 else 1,
                skippedItems = 1,
            )
        }

        val accounts = originalAccounts.toMutableList()
        val rating = normalizedUserRatingOutOf10(ratingOutOf10)
        var syncedItems = 0
        var skippedItems = 0
        val failures = mutableListOf<String>()

        accounts.indices.forEach { accountIndex ->
            var account = accounts[accountIndex].refreshIfNeeded()
                .onFailure { error -> failures += error.message ?: "Token refresh failed for ${accounts[accountIndex].service}." }
                .getOrDefault(accounts[accountIndex])
            accounts[accountIndex] = account
            var result = syncRating(account, mediaId, rating)
            if (result.isAuthFailure && !account.refreshToken.isNullOrBlank()) {
                account.refreshIfNeeded(force = true)
                    .onSuccess { refreshed ->
                        account = refreshed
                        accounts[accountIndex] = refreshed
                        result = syncRating(refreshed, mediaId, rating)
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

        val refreshedState = if (accounts != originalAccounts) {
            state.withAccounts(
                accounts = state.connectedAccounts()
                    .filterNot { account -> account.service.normalizedTrackerService() in RatingTrackerServices } + accounts,
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
            attemptedItems = 1,
            syncedItems = syncedItems,
            skippedItems = skippedItems,
            failures = failures,
        )
    }

    suspend fun syncUserRatingAndNote(
        service: String,
        anilistMediaId: Int?,
        ratingOutOf10: Double,
        note: String,
    ): Result<TrackerSyncSummary> = runCatching {
        val mediaId = anilistMediaId?.takeIf { it > 0 }
        val state = trackerStore.read()
        val targetService = service.normalizedTrackerService()
        val originalAccount = state.connectedAccounts().firstOrNull { account ->
            account.service.matchesTrackerService(targetService) &&
                account.service.normalizedTrackerService() in RatingTrackerServices
        }
        if (!state.syncEnabled || mediaId == null || originalAccount == null) {
            return@runCatching TrackerSyncSummary(
                state = state,
                attemptedAccounts = if (state.syncEnabled && originalAccount != null) 1 else 0,
                attemptedItems = if (mediaId == null) 0 else 1,
                skippedItems = 1,
            )
        }

        var account = originalAccount.refreshIfNeeded().getOrDefault(originalAccount)
        var result = syncRating(
            account = account,
            anilistMediaId = mediaId,
            ratingOutOf10 = normalizedUserRatingOutOf10(ratingOutOf10),
            note = note,
        )
        val failures = mutableListOf<String>()
        if (result.isAuthFailure && !account.refreshToken.isNullOrBlank()) {
            account.refreshIfNeeded(force = true)
                .onSuccess { refreshed ->
                    account = refreshed
                    result = syncRating(
                        account = refreshed,
                        anilistMediaId = mediaId,
                        ratingOutOf10 = normalizedUserRatingOutOf10(ratingOutOf10),
                        note = note,
                    )
                }
                .onFailure { error ->
                    failures += error.message ?: "Token refresh failed for ${account.service}."
                }
        }
        result.message?.let(failures::add)

        val refreshedState = if (account != originalAccount) {
            state.withAccounts(
                accounts = state.connectedAccounts()
                    .filterNot { it.service.matchesTrackerService(targetService) } + account,
            )
        } else {
            state
        }
        val updatedState = if (result.synced || failures.isNotEmpty()) {
            refreshedState.copy(lastSyncDate = Instant.now().toString())
        } else {
            refreshedState
        }
        if (updatedState != state) {
            trackerStore.write(updatedState)
        }

        TrackerSyncSummary(
            state = updatedState,
            attemptedAccounts = 1,
            attemptedItems = 1,
            syncedItems = if (result.synced) 1 else 0,
            skippedItems = if (result.skipped) 1 else 0,
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

    private suspend fun syncItems(
        items: List<TrackerSyncItem>,
        targetService: String? = null,
        respectSyncEnabled: Boolean = true,
    ): TrackerSyncSummary {
        val state = trackerStore.read()
        val connectedAccounts = state.connectedAccounts()
        val originalAccounts = connectedAccounts
            .filter { account -> targetService == null || account.service.matchesTrackerService(targetService) }
        val accounts = originalAccounts.toMutableList()
        if ((respectSyncEnabled && !state.syncEnabled) || accounts.isEmpty() || items.isEmpty()) {
            return TrackerSyncSummary(
                state = state,
                attemptedAccounts = if (!respectSyncEnabled || state.syncEnabled) accounts.size else 0,
                attemptedItems = items.size,
                skippedItems = if (respectSyncEnabled && !state.syncEnabled) items.size else 0,
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
            state.withAccounts(connectedAccounts.replaceAccounts(originalAccounts, accounts))
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

    private fun myAnimeListAuthorizationUrl(): String? {
        val clientId = myAnimeListClientId.trim()
        if (clientId.isBlank()) return null

        val verifier = generateMyAnimeListCodeVerifier()
        pendingMyAnimeListCodeVerifier = verifier
        return Uri.parse("https://myanimelist.net/v1/oauth2/authorize")
            .buildUpon()
            .appendQueryParameter("response_type", "code")
            .appendQueryParameter("client_id", clientId)
            .appendQueryParameter("redirect_uri", MyAnimeListRedirectUri)
            .appendQueryParameter("code_challenge", verifier)
            .appendQueryParameter("code_challenge_method", "plain")
            .build()
            .toString()
    }

    private suspend fun exchangeMyAnimeListOAuthCallback(uri: Uri): TrackerStateSnapshot {
        uri.getQueryParameter("error")
            ?.takeIf { it.isNotBlank() }
            ?.let { error("MyAnimeList authorization was cancelled: $it") }

        val code = uri.getQueryParameter("code")?.trim()
            ?: error("MyAnimeList callback did not include an authorization code.")
        require(code.isNotBlank()) { "MyAnimeList callback did not include an authorization code." }

        val verifier = pendingMyAnimeListCodeVerifier
            ?: error("MyAnimeList callback did not have a matching code verifier.")
        val token = exchangeMyAnimeListAuthorizationCode(code, verifier)
        val identity = fetchMyAnimeListIdentity(token.accessToken).getOrDefault(TrackerIdentity())
        pendingMyAnimeListCodeVerifier = null
        return saveManualAccount(
            TrackerAccountDraft(
                service = MyAnimeListServiceName,
                username = identity.username,
                accessToken = token.accessToken,
                refreshToken = token.refreshToken,
                expiresAt = token.expiresAtFromNow(),
                userId = identity.userId,
            ),
        ).getOrThrow()
    }

    private suspend fun exchangeMyAnimeListAuthorizationCode(
        code: String,
        codeVerifier: String,
    ): OAuthTokenResponse {
        val fields = mutableMapOf(
            "client_id" to myAnimeListClientId.trim(),
            "code" to code,
            "code_verifier" to codeVerifier,
            "grant_type" to "authorization_code",
            "redirect_uri" to MyAnimeListRedirectUri,
        )
        myAnimeListClientSecret.trim().takeIf(String::isNotBlank)?.let { secret ->
            fields["client_secret"] = secret
        }
        return when (val result = httpClient.postForm(MyAnimeListTokenUrl, fields)) {
            is NetworkResult.Success -> {
                val response = EclipseJson.decodeFromString(OAuthTokenResponse.serializer(), result.value)
                require(response.accessToken.isNotBlank()) {
                    "MyAnimeList did not return an access token."
                }
                response
            }
            is NetworkResult.Failure -> error(result.toTrackerOAuthMessage("MyAnimeList token exchange failed."))
        }
    }

    private suspend fun exchangeMyAnimeListRefreshToken(refreshToken: String): OAuthTokenResponse {
        val fields = mutableMapOf(
            "client_id" to myAnimeListClientId.trim(),
            "grant_type" to "refresh_token",
            "refresh_token" to refreshToken,
        )
        myAnimeListClientSecret.trim().takeIf(String::isNotBlank)?.let { secret ->
            fields["client_secret"] = secret
        }
        return when (val result = httpClient.postForm(MyAnimeListTokenUrl, fields)) {
            is NetworkResult.Success -> {
                val response = EclipseJson.decodeFromString(OAuthTokenResponse.serializer(), result.value)
                require(response.accessToken.isNotBlank()) {
                    "MyAnimeList did not return an access token."
                }
                response
            }
            is NetworkResult.Failure -> error(result.toTrackerOAuthMessage("MyAnimeList token refresh failed."))
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

    private suspend fun fetchMyAnimeListIdentity(accessToken: String): Result<TrackerIdentity> = runCatching {
        when (
            val result = httpClient.get(
                url = "https://api.myanimelist.net/v2/users/@me",
                headers = accessToken.bearerAuthorizationHeader(),
            )
        ) {
            is NetworkResult.Success -> {
                val root = EclipseJson.parseToJsonElement(result.value).jsonObject
                TrackerIdentity(
                    username = root["name"]?.jsonPrimitive?.contentOrNull.orEmpty(),
                    userId = root["id"]?.jsonPrimitive?.intOrNull?.toString().orEmpty(),
                )
            }
            is NetworkResult.Failure -> error(result.toTrackerOAuthMessage("MyAnimeList identity lookup failed."))
        }
    }

    private suspend fun syncMangaProgress(
        account: TrackerAccountSnapshot,
        item: AniListMangaProgressSyncItem,
    ): TrackerItemSyncResult = when (account.service.normalizedTrackerService()) {
        "anilist" -> syncAniListMangaProgress(account, item)
        "myanimelist",
        "mal" -> syncMyAnimeListMangaProgress(account, item)
        else -> TrackerItemSyncResult(skipped = true, message = "Unsupported manga tracker ${account.service}.")
    }

    private suspend fun syncRating(
        account: TrackerAccountSnapshot,
        anilistMediaId: Int,
        ratingOutOf10: Double,
        note: String? = null,
    ): TrackerItemSyncResult = when (account.service.normalizedTrackerService()) {
        "anilist" -> syncAniListRating(account, anilistMediaId, ratingOutOf10, note)
        "myanimelist",
        "mal" -> syncMyAnimeListAnimeRating(account, anilistMediaId, ratingOutOf10, note)
        else -> TrackerItemSyncResult(skipped = true, message = "Unsupported rating tracker ${account.service}.")
    }

    private suspend fun syncAniListRating(
        account: TrackerAccountSnapshot,
        anilistMediaId: Int,
        ratingOutOf10: Double,
        note: String?,
    ): TrackerItemSyncResult {
        if (!account.isConnected || account.accessToken.isBlank()) {
            return TrackerItemSyncResult(skipped = true, message = "AniList is not connected.")
        }
        val rating = normalizedUserRatingOutOf10(ratingOutOf10)
        val firstResult = postAniListRating(
            account = account,
            anilistMediaId = anilistMediaId,
            ratingOutOf10 = rating,
            note = note,
            includeCurrentStatus = false,
        )
        val finalResult = if (firstResult is NetworkResult.Failure.Http && firstResult.code == 400) {
            postAniListRating(
                account = account,
                anilistMediaId = anilistMediaId,
                ratingOutOf10 = rating,
                note = note,
                includeCurrentStatus = true,
            )
        } else {
            firstResult
        }
        return when (finalResult) {
            is NetworkResult.Success -> {
                val error = finalResult.value.graphQlErrorMessage()
                if (error == null) {
                    TrackerItemSyncResult(synced = true)
                } else {
                    TrackerItemSyncResult(message = "AniList rating: $error")
                }
            }
            is NetworkResult.Failure -> TrackerItemSyncResult(
                message = finalResult.toTrackerOAuthMessage("AniList rating sync failed."),
            )
        }
    }

    private suspend fun postAniListRating(
        account: TrackerAccountSnapshot,
        anilistMediaId: Int,
        ratingOutOf10: Double,
        note: String?,
        includeCurrentStatus: Boolean,
    ): NetworkResult<String> {
        val body = EclipseJson.encodeToString(
            buildJsonObject {
                put(
                    "query",
                    aniListRatingMutation(
                        anilistMediaId = anilistMediaId,
                        ratingOutOf10 = ratingOutOf10,
                        note = note,
                        includeCurrentStatus = includeCurrentStatus,
                    ),
                )
            },
        )
        return httpClient.postJson(
            url = "https://graphql.anilist.co",
            body = body,
            headers = account.accessToken.bearerAuthorizationHeader(),
        )
    }

    private suspend fun syncMyAnimeListAnimeRating(
        account: TrackerAccountSnapshot,
        anilistMediaId: Int,
        ratingOutOf10: Double,
        note: String?,
    ): TrackerItemSyncResult {
        if (!account.isConnected || account.accessToken.isBlank()) {
            return TrackerItemSyncResult(skipped = true, message = "MyAnimeList is not connected.")
        }
        val malId = resolveMyAnimeListAnimeId(anilistMediaId)
            ?: return TrackerItemSyncResult(skipped = true, message = "MAL rating sync could not map AniList $anilistMediaId.")
        return when (
            val result = httpClient.patchForm(
                url = "https://api.myanimelist.net/v2/anime/$malId/my_list_status",
                fields = buildMap {
                    put("score", ratingOutOf10.toMyAnimeListScore().toString())
                    note?.let { put("comments", it) }
                },
                headers = account.accessToken.bearerAuthorizationHeader(),
            )
        ) {
            is NetworkResult.Success -> TrackerItemSyncResult(synced = true)
            is NetworkResult.Failure -> TrackerItemSyncResult(
                message = result.toTrackerOAuthMessage("MAL rating sync failed."),
            )
        }
    }

    private suspend fun resolveMyAnimeListAnimeId(anilistId: Int): Int? {
        aniListToMalAnimeIdCache[anilistId]?.let { return it }
        val body = EclipseJson.encodeToString(
            buildJsonObject {
                put("query", myAnimeListAnimeIdQuery(anilistId))
            },
        )
        val result = httpClient.postJson(url = "https://graphql.anilist.co", body = body)
        val malId = when (result) {
            is NetworkResult.Success -> runCatching {
                EclipseJson.parseToJsonElement(result.value)
                    .jsonObject["data"]
                    ?.jsonObject
                    ?.get("Media")
                    ?.jsonObject
                    ?.get("idMal")
                    ?.jsonPrimitive
                    ?.intOrNull
            }.getOrNull()
            is NetworkResult.Failure -> null
        } ?: return null
        aniListToMalAnimeIdCache[anilistId] = malId
        return malId
    }

    private suspend fun syncMyAnimeListMangaProgress(
        account: TrackerAccountSnapshot,
        item: AniListMangaProgressSyncItem,
    ): TrackerItemSyncResult {
        if (!account.isConnected || account.accessToken.isBlank()) {
            return TrackerItemSyncResult(skipped = true, message = "MyAnimeList is not connected.")
        }
        val malId = resolveMyAnimeListMangaId(item.mediaId)
            ?: return TrackerItemSyncResult(skipped = true, message = "MAL manga sync could not map AniList ${item.mediaId}.")
        return when (
            val result = httpClient.patchForm(
                url = "https://api.myanimelist.net/v2/manga/$malId/my_list_status",
                fields = mapOf(
                    "status" to if (item.isComplete) "completed" else "reading",
                    "num_chapters_read" to item.progress.coerceAtLeast(0).toString(),
                ),
                headers = account.accessToken.bearerAuthorizationHeader(),
            )
        ) {
            is NetworkResult.Success -> TrackerItemSyncResult(synced = true)
            is NetworkResult.Failure -> TrackerItemSyncResult(
                message = result.toTrackerOAuthMessage("MAL manga sync failed."),
            )
        }
    }

    private suspend fun resolveMyAnimeListMangaId(anilistId: Int): Int? {
        aniListToMalMangaIdCache[anilistId]?.let { return it }
        val body = EclipseJson.encodeToString(
            buildJsonObject {
                put("query", myAnimeListMangaIdQuery(anilistId))
            },
        )
        val result = httpClient.postJson(url = "https://graphql.anilist.co", body = body)
        val malId = when (result) {
            is NetworkResult.Success -> runCatching {
                EclipseJson.parseToJsonElement(result.value)
                    .jsonObject["data"]
                    ?.jsonObject
                    ?.get("Media")
                    ?.jsonObject
                    ?.get("idMal")
                    ?.jsonPrimitive
                    ?.intOrNull
            }.getOrNull()
            is NetworkResult.Failure -> null
        } ?: return null
        aniListToMalMangaIdCache[anilistId] = malId
        return malId
    }

    private suspend fun TrackerAccountSnapshot.refreshIfNeeded(
        force: Boolean = false,
    ): Result<TrackerAccountSnapshot> = runCatching {
        if (service.isMyAnimeListService()) {
            val savedRefreshToken = refreshToken?.trim()?.takeIf(String::isNotBlank)
                ?: return@runCatching this
            if (!force && !shouldRefreshToken()) return@runCatching this
            val response = exchangeMyAnimeListRefreshToken(savedRefreshToken)
            return@runCatching copy(
                accessToken = response.accessToken,
                refreshToken = response.refreshToken?.trim()?.takeIf(String::isNotBlank) ?: savedRefreshToken,
                expiresAt = response.expiresAtFromNow() ?: expiresAt,
            )
        }

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

private const val MyAnimeListServiceName = "MyAnimeList"
private const val MyAnimeListCallbackHost = "mal-callback"
private const val MyAnimeListRedirectUri = "luna://mal-callback"
private const val MyAnimeListTokenUrl = "https://myanimelist.net/v1/oauth2/token"
private val MyAnimeListCodeVerifierCharacters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~".toCharArray()

private fun generateMyAnimeListCodeVerifier(length: Int = 96): String {
    val random = SecureRandom()
    return CharArray(length) {
        MyAnimeListCodeVerifierCharacters[random.nextInt(MyAnimeListCodeVerifierCharacters.size)]
    }.concatToString()
}

private fun OAuthTokenResponse.expiresAtFromNow(now: Instant = Instant.now()): String? =
    expiresIn
        ?.takeIf { it > 0 }
        ?.let { seconds -> now.plusSeconds(seconds).toString() }

private fun String.isMyAnimeListService(): Boolean {
    val normalized = normalizedTrackerService()
    return normalized == "myanimelist" || normalized == "mal"
}

private fun String.matchesTrackerService(target: String): Boolean {
    val normalized = normalizedTrackerService()
    val normalizedTarget = target.normalizedTrackerService()
    return normalized == normalizedTarget ||
        normalized in setOf("myanimelist", "mal") && normalizedTarget in setOf("myanimelist", "mal")
}

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

private fun List<TrackerAccountSnapshot>.replaceAccounts(
    originals: List<TrackerAccountSnapshot>,
    replacements: List<TrackerAccountSnapshot>,
): List<TrackerAccountSnapshot> {
    if (originals.isEmpty()) return this
    val originalServices = originals.map { account -> account.service.normalizedTrackerService() }.toSet()
    return filterNot { account -> account.service.normalizedTrackerService() in originalServices } + replacements
}

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

private val MangaTrackerServices = setOf("anilist", "myanimelist", "mal")
private val RatingTrackerServices = setOf("anilist", "myanimelist", "mal")

private fun aniListRatingMutation(
    anilistMediaId: Int,
    ratingOutOf10: Double,
    note: String? = null,
    includeCurrentStatus: Boolean = false,
): String {
    val statusArgument = if (includeCurrentStatus) ",\n            status: CURRENT" else ""
    val notesArgument = note?.let { ",\n            notes: ${it.graphQlStringLiteral()}" }.orEmpty()
    return """
        mutation {
            SaveMediaListEntry(
                mediaId: $anilistMediaId$statusArgument,
                scoreRaw: ${ratingOutOf10.toAniListScoreRaw()}$notesArgument
            ) {
                id
                score
                notes
            }
        }
    """.trimIndent()
}

private fun Double.toAniListScoreRaw(): Int =
    (normalizedUserRatingOutOf10(this) * 10.0).roundToInt().coerceIn(5, 100)

private fun Double.toMyAnimeListScore(): Int =
    normalizedUserRatingOutOf10(this).roundToInt().coerceIn(1, 10)

private fun String.graphQlStringLiteral(): String =
    buildString {
        append('"')
        this@graphQlStringLiteral.forEach { char ->
            when (char) {
                '\\' -> append("\\\\")
                '"' -> append("\\\"")
                '\n' -> append("\\n")
                '\r' -> append("\\r")
                '\t' -> append("\\t")
                else -> append(char)
            }
        }
        append('"')
    }

private fun myAnimeListAnimeIdQuery(anilistId: Int): String = """
    query {
        Media(id: $anilistId, type: ANIME) {
            idMal
        }
    }
""".trimIndent()

private fun myAnimeListMangaIdQuery(anilistId: Int): String = """
    query {
        Media(id: $anilistId, type: MANGA) {
            idMal
        }
    }
""".trimIndent()

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
