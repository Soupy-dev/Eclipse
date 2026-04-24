package dev.soupy.eclipse.android.data

import dev.soupy.eclipse.android.core.model.ContinueWatchingRecord
import dev.soupy.eclipse.android.core.model.DetailTarget
import dev.soupy.eclipse.android.core.model.EpisodeProgressBackup
import dev.soupy.eclipse.android.core.model.MovieProgressBackup
import dev.soupy.eclipse.android.core.model.ProgressDataBackup
import dev.soupy.eclipse.android.core.model.ShowMetadataBackup
import dev.soupy.eclipse.android.core.model.hasUserData
import dev.soupy.eclipse.android.core.model.progressPercent
import dev.soupy.eclipse.android.core.model.withWatchedThreshold
import dev.soupy.eclipse.android.core.network.EclipseJson
import dev.soupy.eclipse.android.core.storage.ProgressStore
import java.time.Instant
import kotlinx.serialization.SerializationException
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement

data class MovieProgressDraft(
    val movieId: Int,
    val title: String,
    val posterUrl: String? = null,
    val currentTimeSeconds: Double,
    val totalDurationSeconds: Double,
    val isFinished: Boolean = false,
    val lastServiceId: String? = null,
    val lastHref: String? = null,
)

data class EpisodeProgressDraft(
    val showId: Int,
    val seasonNumber: Int,
    val episodeNumber: Int,
    val showTitle: String,
    val showPosterUrl: String? = null,
    val anilistMediaId: Int? = null,
    val currentTimeSeconds: Double,
    val totalDurationSeconds: Double,
    val isFinished: Boolean = false,
    val lastServiceId: String? = null,
    val lastHref: String? = null,
)

class ProgressRepository(
    private val progressStore: ProgressStore,
) {
    suspend fun loadSnapshot(): Result<ProgressDataBackup> = runCatching {
        progressStore.read().normalized()
    }

    suspend fun restoreFromBackup(progressData: JsonElement): Result<ProgressDataBackup> = runCatching {
        val decoded = decodeProgressData(progressData).normalized()
        progressStore.write(decoded)
        decoded
    }

    suspend fun exportForBackup(fallback: JsonElement): JsonElement {
        val snapshot = progressStore.read().normalized()
        return if (snapshot.hasUserData) {
            EclipseJson.encodeToJsonElement(snapshot)
        } else {
            fallback
        }
    }

    suspend fun recordMovieProgress(draft: MovieProgressDraft): Result<ProgressDataBackup> = runCatching {
        require(draft.movieId > 0) { "Movie progress requires a TMDB movie id." }
        require(draft.totalDurationSeconds > 0.0) { "Movie progress requires a duration." }
        val now = Instant.now().toString()
        val snapshot = progressStore.read()
        val entry = MovieProgressBackup(
            id = draft.movieId,
            title = draft.title,
            posterUrl = draft.posterUrl,
            currentTime = if (draft.isFinished) draft.totalDurationSeconds else draft.currentTimeSeconds.coerceIn(0.0, draft.totalDurationSeconds),
            totalDuration = draft.totalDurationSeconds,
            isWatched = draft.isFinished,
            lastUpdated = now,
            lastServiceId = draft.lastServiceId,
            lastHref = draft.lastHref,
        ).withWatchedThreshold()
        val updated = snapshot.copy(
            movieProgress = listOf(entry) + snapshot.movieProgress.filterNot { it.id == draft.movieId },
        ).normalized()
        progressStore.write(updated)
        updated
    }

    suspend fun recordEpisodeProgress(draft: EpisodeProgressDraft): Result<ProgressDataBackup> = runCatching {
        require(draft.showId > 0) { "Episode progress requires a TMDB show id." }
        require(draft.seasonNumber >= 0) { "Episode progress requires a season number." }
        require(draft.episodeNumber > 0) { "Episode progress requires an episode number." }
        require(draft.totalDurationSeconds > 0.0) { "Episode progress requires a duration." }
        val now = Instant.now().toString()
        val id = episodeProgressId(draft.showId, draft.seasonNumber, draft.episodeNumber)
        val snapshot = progressStore.read()
        val entry = EpisodeProgressBackup(
            id = id,
            showId = draft.showId,
            seasonNumber = draft.seasonNumber,
            episodeNumber = draft.episodeNumber,
            anilistMediaId = draft.anilistMediaId,
            currentTime = if (draft.isFinished) draft.totalDurationSeconds else draft.currentTimeSeconds.coerceIn(0.0, draft.totalDurationSeconds),
            totalDuration = draft.totalDurationSeconds,
            isWatched = draft.isFinished,
            lastUpdated = now,
            lastServiceId = draft.lastServiceId,
            lastHref = draft.lastHref,
        ).withWatchedThreshold()
        val metadata = ShowMetadataBackup(
            showId = draft.showId,
            title = draft.showTitle,
            posterUrl = draft.showPosterUrl,
        )
        val updated = snapshot.copy(
            episodeProgress = listOf(entry) + snapshot.episodeProgress.filterNot { it.id == id },
            showMetadata = snapshot.showMetadata + (draft.showId.toString() to metadata),
        ).normalized()
        progressStore.write(updated)
        updated
    }

    suspend fun markMovieWatched(movieId: Int, watched: Boolean): Result<ProgressDataBackup> = runCatching {
        val snapshot = progressStore.read()
        val now = Instant.now().toString()
        val existing = snapshot.movieProgress.firstOrNull { it.id == movieId }
            ?: MovieProgressBackup(id = movieId, lastUpdated = now)
        val safeDuration = existing.totalDuration.takeIf { it > 0.0 } ?: existing.currentTime.coerceAtLeast(1.0)
        val updatedEntry = existing.copy(
            currentTime = if (watched) safeDuration else 0.0,
            totalDuration = safeDuration,
            isWatched = watched,
            lastUpdated = now,
        )
        write(snapshot.copy(movieProgress = listOf(updatedEntry) + snapshot.movieProgress.filterNot { it.id == movieId }))
    }

    suspend fun markEpisodeWatched(
        showId: Int,
        seasonNumber: Int,
        episodeNumber: Int,
        watched: Boolean,
    ): Result<ProgressDataBackup> = runCatching {
        val snapshot = progressStore.read()
        val now = Instant.now().toString()
        val id = episodeProgressId(showId, seasonNumber, episodeNumber)
        val existing = snapshot.episodeProgress.firstOrNull { it.id == id }
            ?: EpisodeProgressBackup(id = id, showId = showId, seasonNumber = seasonNumber, episodeNumber = episodeNumber)
        val safeDuration = existing.totalDuration.takeIf { it > 0.0 } ?: existing.currentTime.coerceAtLeast(1.0)
        val updatedEntry = existing.copy(
            currentTime = if (watched) safeDuration else 0.0,
            totalDuration = safeDuration,
            isWatched = watched,
            lastUpdated = now,
        )
        write(snapshot.copy(episodeProgress = listOf(updatedEntry) + snapshot.episodeProgress.filterNot { it.id == id }))
    }

    suspend fun markPreviousEpisodesWatched(
        showId: Int,
        seasonNumber: Int,
        throughEpisodeExclusive: Int,
        watched: Boolean,
    ): Result<ProgressDataBackup> = runCatching {
        if (throughEpisodeExclusive <= 1) return@runCatching progressStore.read().normalized()
        val now = Instant.now().toString()
        val snapshot = progressStore.read()
        val updatedById = snapshot.episodeProgress.associateBy { it.id }.toMutableMap()
        for (episode in 1 until throughEpisodeExclusive) {
            val id = episodeProgressId(showId, seasonNumber, episode)
            val existing = updatedById[id]
                ?: EpisodeProgressBackup(id = id, showId = showId, seasonNumber = seasonNumber, episodeNumber = episode)
            val safeDuration = existing.totalDuration.takeIf { it > 0.0 } ?: existing.currentTime.coerceAtLeast(1.0)
            updatedById[id] = existing.copy(
                currentTime = if (watched) safeDuration else 0.0,
                totalDuration = safeDuration,
                isWatched = watched,
                lastUpdated = now,
            )
        }
        write(snapshot.copy(episodeProgress = updatedById.values.toList()))
    }

    suspend fun removeContinueWatching(id: String): Result<ProgressDataBackup> = runCatching {
        val snapshot = progressStore.read()
        val updated = when {
            id.startsWith("progress:movie:") -> {
                val movieId = id.substringAfterLast(":").toIntOrNull()
                snapshot.copy(movieProgress = snapshot.movieProgress.filterNot { it.id == movieId })
            }
            id.startsWith("progress:show:") -> {
                val showId = id.substringAfterLast(":").toIntOrNull()
                snapshot.copy(
                    episodeProgress = snapshot.episodeProgress.filterNot { it.showId == showId },
                    showMetadata = snapshot.showMetadata.filterKeys { it != showId?.toString() },
                )
            }
            else -> snapshot
        }
        write(updated)
    }

    suspend fun continueWatching(limit: Int = 20): List<ContinueWatchingRecord> {
        val snapshot = progressStore.read().normalized()
        val movies = snapshot.movieProgress
            .filter { !it.isWatched && it.progressPercent > 0.05 && it.progressPercent < 0.85 }
            .map { movie ->
                ContinueWatchingRecord(
                    id = "progress:movie:${movie.id}",
                    detailTarget = DetailTarget.TmdbMovie(movie.id),
                    title = movie.title.ifBlank { "Movie ${movie.id}" },
                    subtitle = remainingLabel(movie.currentTime, movie.totalDuration),
                    imageUrl = movie.posterUrl,
                    progressPercent = movie.progressPercent.toFloat(),
                    progressLabel = "${(movie.progressPercent * 100.0).toInt()}% watched",
                    updatedAt = movie.lastUpdated.toEpochMillisOrZero(),
                )
            }

        val mostRecentEpisodesByShow = snapshot.episodeProgress
            .filter { !it.isWatched && it.progressPercent > 0.05 && it.progressPercent < 0.85 }
            .groupBy { it.showId }
            .mapNotNull { (_, episodes) -> episodes.maxByOrNull { it.lastUpdated.toEpochMillisOrZero() } }
            .map { episode ->
                val metadata = snapshot.showMetadata[episode.showId.toString()]
                ContinueWatchingRecord(
                    id = "progress:show:${episode.showId}",
                    detailTarget = DetailTarget.TmdbShow(episode.showId),
                    title = metadata?.title?.ifBlank { null } ?: "Show ${episode.showId}",
                    subtitle = "S${episode.seasonNumber} E${episode.episodeNumber} | ${remainingLabel(episode.currentTime, episode.totalDuration)}",
                    imageUrl = metadata?.posterUrl,
                    progressPercent = episode.progressPercent.toFloat(),
                    progressLabel = "${(episode.progressPercent * 100.0).toInt()}% watched",
                    updatedAt = episode.lastUpdated.toEpochMillisOrZero(),
                )
            }

        return (movies + mostRecentEpisodesByShow)
            .sortedByDescending { it.updatedAt }
            .take(limit)
    }

    private suspend fun write(snapshot: ProgressDataBackup): ProgressDataBackup {
        val normalized = snapshot.normalized()
        progressStore.write(normalized)
        return normalized
    }
}

private fun decodeProgressData(progressData: JsonElement): ProgressDataBackup =
    runCatching { EclipseJson.decodeFromJsonElement<ProgressDataBackup>(progressData) }
        .recoverCatching {
            EclipseJson.decodeFromString<ProgressDataBackup>(progressData.toString())
        }
        .getOrElse { error ->
            if (error is SerializationException) ProgressDataBackup() else ProgressDataBackup()
        }

private fun ProgressDataBackup.normalized(): ProgressDataBackup = copy(
    movieProgress = movieProgress.map { it.withWatchedThreshold() }.sortedByDescending { it.lastUpdated.toEpochMillisOrZero() },
    episodeProgress = episodeProgress
        .map { entry -> entry.copy(id = entry.id.ifBlank { episodeProgressId(entry.showId, entry.seasonNumber, entry.episodeNumber) }).withWatchedThreshold() }
        .distinctBy { it.id }
        .sortedByDescending { it.lastUpdated.toEpochMillisOrZero() },
    showMetadata = showMetadata.mapKeys { (key, value) -> key.ifBlank { value.showId.toString() } },
)

private fun episodeProgressId(showId: Int, seasonNumber: Int, episodeNumber: Int): String =
    "ep_${showId}_s${seasonNumber}_e${episodeNumber}"

private fun remainingLabel(currentTime: Double, totalDuration: Double): String {
    val remainingMinutes = ((totalDuration - currentTime).coerceAtLeast(0.0) / 60.0).toInt()
    return if (remainingMinutes < 60) {
        "$remainingMinutes min left"
    } else {
        val hours = remainingMinutes / 60
        val minutes = remainingMinutes % 60
        if (minutes > 0) "${hours}h ${minutes}m left" else "${hours}h left"
    }
}

private fun String?.toEpochMillisOrZero(): Long =
    this?.let { runCatching { Instant.parse(it).toEpochMilli() }.getOrDefault(0L) } ?: 0L
