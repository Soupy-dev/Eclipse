package dev.soupy.eclipse.android.feature.detail

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.soupy.eclipse.android.core.design.ErrorPanel
import dev.soupy.eclipse.android.core.design.GlassPanel
import dev.soupy.eclipse.android.core.design.HeroBackdrop
import dev.soupy.eclipse.android.core.design.LoadingPanel
import dev.soupy.eclipse.android.core.design.MediaPosterCard
import dev.soupy.eclipse.android.core.design.MetadataChips
import dev.soupy.eclipse.android.core.design.PosterImage
import dev.soupy.eclipse.android.core.design.SectionHeading
import dev.soupy.eclipse.android.core.model.ExploreMediaCard
import dev.soupy.eclipse.android.core.model.InAppPlayer
import dev.soupy.eclipse.android.core.model.PlaybackSettingsSnapshot
import dev.soupy.eclipse.android.core.model.PlayerSource
import dev.soupy.eclipse.android.core.model.SkipSegment
import dev.soupy.eclipse.android.core.player.EclipsePlayerSurface
import dev.soupy.eclipse.android.core.player.PlaybackProgressSnapshot

data class DetailEpisodeRow(
    val id: String,
    val title: String,
    val subtitle: String? = null,
    val imageUrl: String? = null,
    val overview: String? = null,
    val seasonNumber: Int? = null,
    val episodeNumber: Int? = null,
    val runtimeMinutes: Int? = null,
    val tmdbSeasonNumber: Int? = null,
    val tmdbEpisodeNumber: Int? = null,
)

data class DetailCastRow(
    val id: String,
    val name: String,
    val role: String? = null,
    val imageUrl: String? = null,
)

data class DetailStreamRow(
    val id: String,
    val title: String,
    val subtitle: String? = null,
    val supportingText: String? = null,
    val playable: Boolean = false,
    val playerSource: PlayerSource? = null,
)

data class DetailCollectionRow(
    val id: String,
    val name: String,
    val isSelected: Boolean = false,
)

data class DetailScreenState(
    val hasSelection: Boolean = false,
    val isLoading: Boolean = false,
    val errorMessage: String? = null,
    val title: String = "",
    val subtitle: String? = null,
    val overview: String? = null,
    val posterUrl: String? = null,
    val backdropUrl: String? = null,
    val metadataChips: List<String> = emptyList(),
    val contentRating: String? = null,
    val userRating: Int? = null,
    val cast: List<DetailCastRow> = emptyList(),
    val recommendations: List<ExploreMediaCard> = emptyList(),
    val episodesTitle: String? = null,
    val episodes: List<DetailEpisodeRow> = emptyList(),
    val isResolvingStreams: Boolean = false,
    val streamStatusMessage: String? = null,
    val streamCandidates: List<DetailStreamRow> = emptyList(),
    val playerSource: PlayerSource? = null,
    val skipSegments: List<SkipSegment> = emptyList(),
    val skipStatusMessage: String? = null,
    val selectedEpisodeId: String? = null,
    val selectedEpisodeLabel: String? = null,
    val seasonMenu: Boolean = false,
    val horizontalEpisodeList: Boolean = false,
    val collections: List<DetailCollectionRow> = emptyList(),
)

@Composable
fun DetailRoute(
    state: DetailScreenState,
    onRetry: () -> Unit,
    onSaveToLibrary: () -> Unit,
    onAddToCollection: (String) -> Unit,
    onQueueResume: () -> Unit,
    onQueueDownload: () -> Unit,
    onSetRating: (Int) -> Unit,
    onClearRating: () -> Unit,
    onMarkWatched: () -> Unit,
    onMarkUnwatched: () -> Unit,
    onResolveStreams: () -> Unit,
    onResolveEpisodeStreams: (String) -> Unit,
    onMarkEpisodeWatched: (String) -> Unit,
    onMarkEpisodeUnwatched: (String) -> Unit,
    onMarkPreviousEpisodesWatched: (String) -> Unit,
    onPlayStream: (String) -> Unit,
    onPlayNextEpisode: () -> Unit,
    onSelectRecommendation: (ExploreMediaCard) -> Unit,
    onPlaybackProgress: (PlaybackProgressSnapshot) -> Unit,
    preferredPlayer: InAppPlayer = InAppPlayer.NORMAL,
    playbackSettings: PlaybackSettingsSnapshot = PlaybackSettingsSnapshot(),
) {
    val episodeSeasons = state.episodes
        .mapNotNull { it.seasonNumber ?: it.tmdbSeasonNumber }
        .distinct()
        .sorted()
    var selectedSeason by remember(state.title, episodeSeasons) {
        mutableStateOf(episodeSeasons.firstOrNull())
    }
    val visibleEpisodes = if (state.seasonMenu && selectedSeason != null) {
        state.episodes.filter { episode ->
            (episode.seasonNumber ?: episode.tmdbSeasonNumber) == selectedSeason
        }
    } else {
        state.episodes
    }

    if (!state.hasSelection && !state.isLoading) {
        ErrorPanel(
            title = "Open something first",
            message = "Home, Search, and Schedule now feed this detail screen. Pick a movie, show, or anime card and the Android detail flow will load it here.",
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .padding(horizontal = 20.dp, vertical = 18.dp),
        )
        return
    }

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding(),
        verticalArrangement = Arrangement.spacedBy(18.dp),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 18.dp),
    ) {
        if (state.isLoading) {
            item {
                LoadingPanel(
                    title = "Loading detail",
                    message = "Hydrating metadata and the first detail view for Android.",
                )
            }
        }

        state.errorMessage?.let { error ->
            item {
                ErrorPanel(
                    title = "Detail couldn't finish loading",
                    message = error,
                    actionLabel = "Retry",
                    onAction = onRetry,
                )
            }
        }

        if (state.title.isNotBlank()) {
            item {
                HeroBackdrop(
                    title = state.title,
                    subtitle = state.subtitle,
                    imageUrl = state.backdropUrl ?: state.posterUrl,
                    supportingText = state.overview,
                )
            }
        }

        if (state.metadataChips.isNotEmpty()) {
            item {
                MetadataChips(values = state.metadataChips)
            }
        }

        if (state.title.isNotBlank()) {
            item {
                GlassPanel {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text(
                            text = "Quick actions",
                            style = MaterialTheme.typography.titleLarge,
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                        Text(
                            text = "Save this title to the Android library. Direct in-app playback now updates Continue Watching automatically, and episode rows can resolve their own streams when metadata is available.",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.78f),
                        )
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            Button(
                                onClick = onSaveToLibrary,
                                modifier = Modifier.weight(1f),
                            ) {
                                Text("Save to Library")
                            }
                            OutlinedButton(
                                onClick = onQueueResume,
                                modifier = Modifier.weight(1f),
                            ) {
                                Text("Queue Resume")
                            }
                        }
                        if (state.collections.isNotEmpty()) {
                            Text(
                                text = "Add to collection",
                                style = MaterialTheme.typography.titleMedium,
                                color = MaterialTheme.colorScheme.onSurface,
                            )
                            LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                items(state.collections, key = { it.id }) { collection ->
                                    OutlinedButton(
                                        onClick = { onAddToCollection(collection.id) },
                                    ) {
                                        Text(
                                            if (collection.isSelected) {
                                                "${collection.name} (added)"
                                            } else {
                                                collection.name
                                            },
                                        )
                                    }
                                }
                            }
                        }
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            OutlinedButton(
                                onClick = onQueueDownload,
                                modifier = Modifier.weight(1f),
                            ) {
                                Text("Queue Download")
                            }
                            Button(
                                onClick = onResolveStreams,
                                modifier = Modifier.weight(1f),
                            ) {
                                Text(
                                    when {
                                        state.isResolvingStreams -> "Resolving..."
                                        state.selectedEpisodeLabel != null -> "Resolve ${state.selectedEpisodeLabel}"
                                        else -> "Resolve Streams"
                                    },
                                )
                            }
                        }
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            OutlinedButton(
                                onClick = onMarkWatched,
                                modifier = Modifier.weight(1f),
                            ) {
                                Text("Mark Watched")
                            }
                            OutlinedButton(
                                onClick = onMarkUnwatched,
                                modifier = Modifier.weight(1f),
                            ) {
                                Text("Mark Unwatched")
                            }
                        }
                        Text(
                            text = state.userRating?.let { "Your rating: $it/5" } ?: "Your rating",
                            style = MaterialTheme.typography.titleMedium,
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            (1..3).forEach { rating ->
                                if (state.userRating == rating) {
                                    Button(
                                        onClick = { onSetRating(rating) },
                                        modifier = Modifier.weight(1f),
                                    ) {
                                        Text(rating.toString())
                                    }
                                } else {
                                    OutlinedButton(
                                        onClick = { onSetRating(rating) },
                                        modifier = Modifier.weight(1f),
                                    ) {
                                        Text(rating.toString())
                                    }
                                }
                            }
                        }
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                        ) {
                            (4..5).forEach { rating ->
                                if (state.userRating == rating) {
                                    Button(
                                        onClick = { onSetRating(rating) },
                                        modifier = Modifier.weight(1f),
                                    ) {
                                        Text(rating.toString())
                                    }
                                } else {
                                    OutlinedButton(
                                        onClick = { onSetRating(rating) },
                                        modifier = Modifier.weight(1f),
                                    ) {
                                        Text(rating.toString())
                                    }
                                }
                            }
                            if (state.userRating != null) {
                                OutlinedButton(
                                    onClick = onClearRating,
                                    modifier = Modifier.weight(1f),
                                ) {
                                    Text("Clear")
                                }
                            }
                        }
                    }
                }
            }
        }

        if (state.streamStatusMessage != null || state.streamCandidates.isNotEmpty()) {
            item {
                SectionHeading(
                    title = "Streams",
                    subtitle = state.streamStatusMessage ?: "Resolved Stremio addon candidates for this Android detail page.",
                )
            }
        }

        if (state.streamStatusMessage != null && state.streamCandidates.isEmpty()) {
            item {
                GlassPanel {
                    Text(
                        text = state.streamStatusMessage,
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                }
            }
        }

        if (state.streamCandidates.isNotEmpty()) {
            items(state.streamCandidates, key = { it.id }) { stream ->
                GlassPanel {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text(
                            text = stream.title,
                            style = MaterialTheme.typography.titleLarge,
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                        stream.subtitle?.let {
                            Text(
                                text = it,
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.tertiary,
                            )
                        }
                        stream.supportingText?.let {
                            Text(
                                text = it,
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.76f),
                            )
                        }
                        if (stream.playable) {
                            Button(onClick = { onPlayStream(stream.id) }) {
                                Text("Play Stream")
                            }
                        } else {
                            Text(
                                text = "Only direct HTTP(S) stream URLs are accepted for playback.",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f),
                            )
                        }
                    }
                }
            }
        }

        item {
            EclipsePlayerSurface(
                source = state.playerSource,
                preferredPlayer = preferredPlayer,
                settings = playbackSettings,
                skipSegments = state.skipSegments,
                nextEpisodeLabel = state.nextEpisodeLabel(),
                onNextEpisode = onPlayNextEpisode,
                onProgress = onPlaybackProgress,
            )
        }

        state.skipStatusMessage?.let { message ->
            item {
                GlassPanel {
                    Text(
                        text = message,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.78f),
                    )
                }
            }
        }

        if (!state.overview.isNullOrBlank()) {
            item {
                GlassPanel {
                    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text(
                            text = "Overview",
                            style = MaterialTheme.typography.titleLarge,
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                        Text(
                            text = state.overview,
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.82f),
                        )
                    }
                }
            }
        }

        if (state.cast.isNotEmpty()) {
            item {
                SectionHeading(
                    title = "Cast",
                    subtitle = "Top billed cast from TMDB.",
                )
            }
            item {
                LazyRow(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    items(state.cast, key = { it.id }) { cast ->
                        GlassPanel(modifier = Modifier.width(154.dp)) {
                            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                                PosterImage(
                                    imageUrl = cast.imageUrl,
                                    contentDescription = cast.name,
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .height(170.dp),
                                )
                                Text(
                                    text = cast.name,
                                    style = MaterialTheme.typography.titleMedium,
                                    color = MaterialTheme.colorScheme.onSurface,
                                )
                                cast.role?.let {
                                    Text(
                                        text = it,
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.72f),
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }

        state.episodesTitle?.let { title ->
            if (state.episodes.isNotEmpty()) {
                item {
                    SectionHeading(
                        title = title,
                        subtitle = "TMDB episode stills, runtimes, descriptions, and progress actions.",
                    )
                }
                if (state.seasonMenu && episodeSeasons.size > 1) {
                    item {
                        LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                            items(episodeSeasons, key = { it }) { season ->
                                if (season == selectedSeason) {
                                    Button(onClick = { selectedSeason = season }) {
                                        Text("Season $season")
                                    }
                                } else {
                                    OutlinedButton(onClick = { selectedSeason = season }) {
                                        Text("Season $season")
                                    }
                                }
                            }
                        }
                    }
                }
                if (state.horizontalEpisodeList) {
                    item {
                        LazyRow(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                            items(visibleEpisodes, key = { it.id }) { episode ->
                                EpisodeCard(
                                    episode = episode,
                                    onResolveEpisodeStreams = onResolveEpisodeStreams,
                                    onMarkEpisodeWatched = onMarkEpisodeWatched,
                                    onMarkEpisodeUnwatched = onMarkEpisodeUnwatched,
                                    onMarkPreviousEpisodesWatched = onMarkPreviousEpisodesWatched,
                                    modifier = Modifier.width(320.dp),
                                )
                            }
                        }
                    }
                } else {
                    items(visibleEpisodes, key = { it.id }) { episode ->
                        EpisodeCard(
                            episode = episode,
                            onResolveEpisodeStreams = onResolveEpisodeStreams,
                            onMarkEpisodeWatched = onMarkEpisodeWatched,
                            onMarkEpisodeUnwatched = onMarkEpisodeUnwatched,
                            onMarkPreviousEpisodesWatched = onMarkPreviousEpisodesWatched,
                        )
                    }
                }
            }
        }

        if (state.recommendations.isNotEmpty()) {
            item {
                SectionHeading(
                    title = "Recommendations",
                    subtitle = "Related TMDB titles.",
                )
            }
            item {
                LazyRow(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    items(state.recommendations, key = { it.id }) { item ->
                        MediaPosterCard(
                            item = item,
                            onClick = onSelectRecommendation,
                            modifier = Modifier.width(180.dp),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun EpisodeCard(
    episode: DetailEpisodeRow,
    onResolveEpisodeStreams: (String) -> Unit,
    onMarkEpisodeWatched: (String) -> Unit,
    onMarkEpisodeUnwatched: (String) -> Unit,
    onMarkPreviousEpisodesWatched: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    GlassPanel(modifier = modifier) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (episode.imageUrl != null) {
                PosterImage(
                    imageUrl = episode.imageUrl,
                    contentDescription = episode.title,
                    modifier = Modifier
                        .fillMaxWidth()
                        .width(220.dp),
                )
            }
            Text(
                text = episode.title,
                style = MaterialTheme.typography.titleLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )
            episode.subtitle?.let {
                Text(
                    text = it,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.tertiary,
                )
            }
            episode.overview?.takeIf { it.isNotBlank() }?.let {
                Text(
                    text = it,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.78f),
                )
            }
            if (episode.seasonNumber != null && episode.episodeNumber != null) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    Button(
                        onClick = { onResolveEpisodeStreams(episode.id) },
                        modifier = Modifier.weight(1f),
                    ) {
                        Text("Resolve")
                    }
                    OutlinedButton(
                        onClick = { onMarkEpisodeWatched(episode.id) },
                        modifier = Modifier.weight(1f),
                    ) {
                        Text("Watched")
                    }
                }
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    OutlinedButton(
                        onClick = { onMarkEpisodeUnwatched(episode.id) },
                        modifier = Modifier.weight(1f),
                    ) {
                        Text("Unwatched")
                    }
                    OutlinedButton(
                        onClick = { onMarkPreviousEpisodesWatched(episode.id) },
                        modifier = Modifier.weight(1f),
                    ) {
                        Text("Mark Previous")
                    }
                }
            }
        }
    }
}

private fun DetailScreenState.nextEpisodeLabel(): String? {
    val playableEpisodes = episodes.filter {
        it.seasonNumber != null && it.episodeNumber != null
    }
    if (playableEpisodes.size < 2) return null
    val currentIndex = selectedEpisodeId
        ?.let { id -> playableEpisodes.indexOfFirst { it.id == id } }
        ?.takeIf { it >= 0 }
        ?: 0
    val nextEpisode = playableEpisodes.getOrNull(currentIndex + 1) ?: return null
    return nextEpisode.subtitle?.let { "Next $it" } ?: "Next Episode"
}

