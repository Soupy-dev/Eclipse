package dev.soupy.eclipse.android.data

import dev.soupy.eclipse.android.core.model.DetailTarget
import dev.soupy.eclipse.android.core.model.EpisodePlaybackContext
import dev.soupy.eclipse.android.core.model.TrackerAccountSnapshot
import dev.soupy.eclipse.android.core.network.EclipseHttpClient
import dev.soupy.eclipse.android.core.network.EclipseJson
import dev.soupy.eclipse.android.core.network.NetworkResult
import java.time.Instant
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put

data class TrackerPlaybackProgressDraft(
    val target: DetailTarget,
    val title: String,
    val seasonNumber: Int? = null,
    val episodeNumber: Int? = null,
    val anilistMediaId: Int? = null,
    val progressPercent: Double,
    val isFinished: Boolean = false,
    val playbackContext: EpisodePlaybackContext? = null,
)

data class TrackerSyncSummary(
    val state: dev.soupy.eclipse.android.core.model.TrackerStateSnapshot,
    val attemptedAccounts: Int = 0,
    val attemptedItems: Int = 0,
    val syncedItems: Int = 0,
    val skippedItems: Int = 0,
    val failures: List<String> = emptyList(),
) {
    val statusMessage: String
        get() = when {
            attemptedAccounts == 0 -> "No connected tracker accounts are ready to sync."
            attemptedItems == 0 -> "No watched local progress is ready to sync yet."
            failures.isNotEmpty() && syncedItems == 0 -> "Tracker sync failed: ${failures.first()}"
            failures.isNotEmpty() -> "Synced $syncedItems tracker item${syncedItems.s()} with ${failures.size} issue${failures.size.s()}."
            syncedItems > 0 -> "Synced $syncedItems tracker item${syncedItems.s()}."
            else -> "Tracker sync skipped $skippedItems item${skippedItems.s()} with no eligible remote updates."
        }
}

internal data class TrackerSyncItem(
    val target: DetailTarget,
    val title: String,
    val seasonNumber: Int? = null,
    val episodeNumber: Int? = null,
    val anilistMediaId: Int? = null,
    val anilistEpisodeNumber: Int? = episodeNumber,
    val progressPercent: Double,
    val isFinished: Boolean = false,
) {
    val isWatchedEnough: Boolean
        get() = isFinished || progressPercent >= TrackerWatchedThreshold
}

internal data class TrackerItemSyncResult(
    val synced: Boolean = false,
    val skipped: Boolean = false,
    val message: String? = null,
)

class TrackerSyncClient(
    private val httpClient: EclipseHttpClient = EclipseHttpClient(),
) {
    internal suspend fun sync(
        account: TrackerAccountSnapshot,
        item: TrackerSyncItem,
    ): TrackerItemSyncResult {
        if (!account.isConnected || account.accessToken.isBlank()) {
            return TrackerItemSyncResult(skipped = true, message = "${account.service} is not connected.")
        }
        return when (account.service.normalizedTrackerService()) {
            "anilist" -> syncAniList(account, item)
            "trakt" -> syncTrakt(account, item)
            else -> TrackerItemSyncResult(skipped = true, message = "Unsupported tracker ${account.service}.")
        }
    }

    private suspend fun syncAniList(
        account: TrackerAccountSnapshot,
        item: TrackerSyncItem,
    ): TrackerItemSyncResult {
        if (!item.isWatchedEnough) {
            return TrackerItemSyncResult(skipped = true, message = "AniList waits until 85% watched.")
        }
        val mediaId = item.anilistMediaId
            ?: return TrackerItemSyncResult(skipped = true, message = "AniList sync needs an AniList media id.")
        val episodeNumber = item.anilistEpisodeNumber
            ?: return TrackerItemSyncResult(skipped = true, message = "AniList sync needs an episode number.")

        val body = EclipseJson.encodeToString(
            buildJsonObject {
                put("query", aniListSaveMediaListMutation(mediaId, episodeNumber))
            },
        )
        return when (
            val result = httpClient.postJson(
                url = "https://graphql.anilist.co",
                body = body,
                headers = mapOf("Authorization" to "Bearer ${account.accessToken}"),
            )
        ) {
            is NetworkResult.Success -> {
                val error = result.value.graphQlErrorMessage()
                if (error == null) {
                    TrackerItemSyncResult(synced = true)
                } else {
                    TrackerItemSyncResult(message = "AniList: $error")
                }
            }
            is NetworkResult.Failure.Http -> TrackerItemSyncResult(message = "AniList HTTP ${result.code}: ${result.body.orEmpty()}")
            is NetworkResult.Failure.Connectivity -> TrackerItemSyncResult(message = "AniList connectivity: ${result.throwable.message}")
            is NetworkResult.Failure.Serialization -> TrackerItemSyncResult(message = "AniList serialization: ${result.throwable.message}")
        }
    }

    private suspend fun syncTrakt(
        account: TrackerAccountSnapshot,
        item: TrackerSyncItem,
    ): TrackerItemSyncResult {
        if (!item.isWatchedEnough) {
            return TrackerItemSyncResult(skipped = true, message = "Trakt history waits until 85% watched.")
        }
        val payload = item.toTraktHistoryPayload(Instant.now().toString())
            ?: return TrackerItemSyncResult(skipped = true, message = "Trakt sync needs TMDB movie or episode metadata.")
        return when (
            val result = httpClient.postJson(
                url = "https://api.trakt.tv/sync/history",
                body = EclipseJson.encodeToString(payload),
                headers = mapOf(
                    "Authorization" to "Bearer ${account.accessToken}",
                    "trakt-api-key" to TraktClientId,
                    "trakt-api-version" to "2",
                ),
            )
        ) {
            is NetworkResult.Success -> TrackerItemSyncResult(synced = true)
            is NetworkResult.Failure.Http -> TrackerItemSyncResult(message = "Trakt HTTP ${result.code}: ${result.body.orEmpty()}")
            is NetworkResult.Failure.Connectivity -> TrackerItemSyncResult(message = "Trakt connectivity: ${result.throwable.message}")
            is NetworkResult.Failure.Serialization -> TrackerItemSyncResult(message = "Trakt serialization: ${result.throwable.message}")
        }
    }
}

internal fun TrackerPlaybackProgressDraft.toTrackerSyncItem(): TrackerSyncItem {
    val context = playbackContext
    val traktSeason = context?.resolvedTMDBSeasonNumber ?: seasonNumber
    val traktEpisode = context?.resolvedTMDBEpisodeNumber ?: episodeNumber
    return TrackerSyncItem(
        target = target,
        title = title,
        seasonNumber = traktSeason,
        episodeNumber = traktEpisode,
        anilistMediaId = anilistMediaId ?: context?.anilistMediaId,
        anilistEpisodeNumber = context?.localEpisodeNumber ?: episodeNumber,
        progressPercent = progressPercent,
        isFinished = isFinished,
    )
}

internal fun TrackerSyncItem.toTraktHistoryPayload(watchedAt: String): JsonObject? = when (val detailTarget = target) {
    is DetailTarget.TmdbMovie -> buildJsonObject {
        put(
            "movies",
            buildJsonArray {
                add(
                    buildJsonObject {
                        put("ids", buildJsonObject { put("tmdb", detailTarget.id) })
                        put("watched_at", watchedAt)
                    },
                )
            },
        )
    }
    is DetailTarget.TmdbShow -> {
        val season = seasonNumber ?: return null
        val episode = episodeNumber ?: return null
        buildJsonObject {
            put(
                "shows",
                buildJsonArray {
                    add(
                        buildJsonObject {
                            put("ids", buildJsonObject { put("tmdb", detailTarget.id) })
                            put(
                                "seasons",
                                buildJsonArray {
                                    add(
                                        buildJsonObject {
                                            put("number", season)
                                            put(
                                                "episodes",
                                                buildJsonArray {
                                                    add(
                                                        buildJsonObject {
                                                            put("number", episode)
                                                            put("watched_at", watchedAt)
                                                        },
                                                    )
                                                },
                                            )
                                        },
                                    )
                                },
                            )
                        },
                    )
                },
            )
        }
    }
    is DetailTarget.AniListMediaTarget -> null
}

internal fun aniListSaveMediaListMutation(
    mediaId: Int,
    progress: Int,
): String = """
    mutation {
        SaveMediaListEntry(
            mediaId: $mediaId,
            progress: $progress,
            status: CURRENT
        ) {
            id
            progress
            status
        }
    }
""".trimIndent()

internal fun String.normalizedTrackerService(): String =
    trim()
        .lowercase()
        .replace(" ", "")
        .replace("-", "")

private fun String.graphQlErrorMessage(): String? =
    runCatching {
        val root = EclipseJson.parseToJsonElement(this).jsonObject
        root["errors"]?.jsonArray?.firstOrNull()?.jsonObject?.get("message")?.toString()?.trim('"')
    }.getOrNull()

private fun Int.s(): String = if (this == 1) "" else "s"

internal const val TrackerWatchedThreshold = 0.85

private const val TraktClientId = "e92207aaef82a1b0b42d5901efa4756b6c417911b7b031b986d37773c234ccab"
