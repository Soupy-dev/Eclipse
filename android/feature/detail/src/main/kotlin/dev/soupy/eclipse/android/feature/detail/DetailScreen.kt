package dev.soupy.eclipse.android.feature.detail

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import dev.soupy.eclipse.android.core.design.ErrorPanel
import dev.soupy.eclipse.android.core.design.GlassPanel
import dev.soupy.eclipse.android.core.design.HeroBackdrop
import dev.soupy.eclipse.android.core.design.LoadingPanel
import dev.soupy.eclipse.android.core.design.MetadataChips
import dev.soupy.eclipse.android.core.design.PosterImage
import dev.soupy.eclipse.android.core.design.SectionHeading
import dev.soupy.eclipse.android.core.model.InAppPlayer
import dev.soupy.eclipse.android.core.model.PlaybackSettingsSnapshot
import dev.soupy.eclipse.android.core.model.PlayerSource
import dev.soupy.eclipse.android.core.player.EclipsePlayerSurface
import dev.soupy.eclipse.android.core.player.PlaybackProgressSnapshot

data class DetailEpisodeRow(
    val id: String,
    val title: String,
    val subtitle: String? = null,
    val imageUrl: String? = null,
    val overview: String? = null,
)

data class DetailStreamRow(
    val id: String,
    val title: String,
    val subtitle: String? = null,
    val supportingText: String? = null,
    val playable: Boolean = false,
    val playerSource: PlayerSource? = null,
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
    val episodesTitle: String? = null,
    val episodes: List<DetailEpisodeRow> = emptyList(),
    val isResolvingStreams: Boolean = false,
    val streamStatusMessage: String? = null,
    val streamCandidates: List<DetailStreamRow> = emptyList(),
    val playerSource: PlayerSource? = null,
)

@Composable
fun DetailRoute(
    state: DetailScreenState,
    onRetry: () -> Unit,
    onSaveToLibrary: () -> Unit,
    onQueueResume: () -> Unit,
    onQueueDownload: () -> Unit,
    onResolveStreams: () -> Unit,
    onPlayStream: (String) -> Unit,
    onPlaybackProgress: (PlaybackProgressSnapshot) -> Unit,
    preferredPlayer: InAppPlayer = InAppPlayer.NORMAL,
    playbackSettings: PlaybackSettingsSnapshot = PlaybackSettingsSnapshot(),
) {
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
                            text = "Save this title to the Android library. Direct in-app playback now updates Continue Watching automatically, and the manual resume button is still here as a fallback.",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.78f),
                        )
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Button(onClick = onSaveToLibrary) {
                                Text("Save to Library")
                            }
                            OutlinedButton(onClick = onQueueResume) {
                                Text("Queue Resume")
                            }
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            OutlinedButton(onClick = onQueueDownload) {
                                Text("Queue Download")
                            }
                            Button(onClick = onResolveStreams) {
                                Text(if (state.isResolvingStreams) "Resolving..." else "Resolve Streams")
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
                                text = "Playback for this source type is still pending Android torrent or alternate-player support.",
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
                onProgress = onPlaybackProgress,
            )
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

        state.episodesTitle?.let { title ->
            if (state.episodes.isNotEmpty()) {
                item {
                    SectionHeading(
                        title = title,
                        subtitle = "The first loaded episode group for this Android detail flow.",
                    )
                }
                items(state.episodes, key = { it.id }) { episode ->
                    GlassPanel {
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
                        }
                    }
                }
            }
        }
    }
}

