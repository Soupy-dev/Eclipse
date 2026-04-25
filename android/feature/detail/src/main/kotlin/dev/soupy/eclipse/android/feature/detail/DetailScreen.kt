package dev.soupy.eclipse.android.feature.detail

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Bookmark
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.Star
import androidx.compose.material.icons.rounded.StarBorder
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.soupy.eclipse.android.core.design.ErrorPanel
import dev.soupy.eclipse.android.core.design.GlassPanel
import dev.soupy.eclipse.android.core.design.LoadingPanel
import dev.soupy.eclipse.android.core.design.PosterImage
import dev.soupy.eclipse.android.core.design.SectionHeading
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
    val isSpecial: Boolean = false,
    val titleOnlySearch: Boolean = false,
    val searchTitle: String? = null,
    val serviceHref: String? = null,
)

data class DetailCastRow(
    val id: String,
    val name: String,
    val role: String? = null,
    val imageUrl: String? = null,
)

data class DetailFactRow(
    val label: String,
    val value: String,
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

private data class SpecialEpisodeGroup(
    val key: String,
    val title: String,
    val subtitle: String,
    val imageUrl: String?,
    val episodes: List<DetailEpisodeRow>,
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
    val detailFacts: List<DetailFactRow> = emptyList(),
    val contentRating: String? = null,
    val userRating: Int? = null,
    val cast: List<DetailCastRow> = emptyList(),
    val episodesTitle: String? = null,
    val episodes: List<DetailEpisodeRow> = emptyList(),
    val isMovie: Boolean = false,
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
    onPlaybackProgress: (PlaybackProgressSnapshot) -> Unit,
    preferredPlayer: InAppPlayer = InAppPlayer.NORMAL,
    playbackSettings: PlaybackSettingsSnapshot = PlaybackSettingsSnapshot(),
) {
    val regularEpisodes = state.episodes.filterNot { it.isSpecial }
    val specialEpisodeGroups = state.episodes
        .filter { it.isSpecial }
        .groupBy { it.specialGroupKey() }
        .map { (key, episodes) ->
            val first = episodes.first()
            val title = first.searchTitle?.takeIf { it.isNotBlank() } ?: first.title
            val formatLabel = first.subtitle?.substringBefore("|")?.trim()?.takeIf { it.isNotBlank() } ?: "Special"
            SpecialEpisodeGroup(
                key = key,
                title = title,
                subtitle = if (episodes.size == 1) formatLabel else "$formatLabel - ${episodes.size} eps",
                imageUrl = first.imageUrl,
                episodes = episodes,
            )
        }
    val specialGroupKeys = specialEpisodeGroups.map { it.key }
    var selectedSpecialGroupKey by remember(state.title, specialGroupKeys) {
        mutableStateOf<String?>(null)
    }
    val activeSpecialGroup = specialEpisodeGroups.firstOrNull {
        it.key == (selectedSpecialGroupKey ?: if (regularEpisodes.isEmpty()) specialEpisodeGroups.firstOrNull()?.key else null)
    }
    val episodeSeasons = regularEpisodes
        .mapNotNull { it.seasonNumber ?: it.tmdbSeasonNumber }
        .distinct()
        .sorted()
    var selectedSeason by remember(state.title, episodeSeasons) {
        mutableStateOf(episodeSeasons.firstOrNull { it > 0 } ?: episodeSeasons.firstOrNull())
    }
    val isSeasonedShow = episodeSeasons.size > 1
    val visibleEpisodes = activeSpecialGroup?.episodes ?: if (isSeasonedShow && selectedSeason != null) {
        regularEpisodes.filter { episode ->
            (episode.seasonNumber ?: episode.tmdbSeasonNumber) == selectedSeason
        }
    } else {
        regularEpisodes
    }

    if (!state.hasSelection && !state.isLoading) {
        ErrorPanel(
            title = "Open something first",
            message = "Pick a movie, show, or anime card to view details.",
            modifier = Modifier
                .fillMaxSize()
                .statusBarsPadding()
                .padding(horizontal = 20.dp, vertical = 18.dp),
        )
        return
    }

    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        verticalArrangement = Arrangement.spacedBy(16.dp),
        contentPadding = PaddingValues(bottom = 28.dp),
    ) {
        if (state.isLoading) {
            item {
                LoadingPanel(
                    title = "Loading",
                    message = "Fetching details.",
                    modifier = Modifier
                        .statusBarsPadding()
                        .padding(horizontal = 20.dp, vertical = 18.dp),
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
                    modifier = Modifier
                        .statusBarsPadding()
                        .padding(horizontal = 20.dp, vertical = 18.dp),
                )
            }
        }

        if (state.title.isNotBlank()) {
            item {
                DetailHero(
                    title = state.title,
                    subtitle = state.subtitle,
                    imageUrl = state.backdropUrl ?: state.posterUrl,
                )
            }
        }

        if (!state.overview.isNullOrBlank()) {
            item {
                SynopsisBlock(
                    text = state.overview,
                    modifier = Modifier.padding(horizontal = 20.dp),
                )
            }
        }

        if (state.title.isNotBlank()) {
            item {
                DetailActions(
                    isResolvingStreams = state.isResolvingStreams,
                    selectedEpisodeLabel = state.selectedEpisodeLabel,
                    isMovie = state.isMovie,
                    collections = state.collections,
                    onResolveStreams = onResolveStreams,
                    onSaveToLibrary = onSaveToLibrary,
                    onQueueDownload = onQueueDownload,
                    onAddToCollection = onAddToCollection,
                    modifier = Modifier.padding(horizontal = 16.dp),
                )
            }
        }

        if (state.detailFacts.isNotEmpty()) {
            item {
                DetailFactsCard(
                    facts = state.detailFacts,
                    modifier = Modifier.padding(horizontal = 20.dp),
                )
            }
        }

        if (state.streamStatusMessage != null || state.streamCandidates.isNotEmpty()) {
            item {
                SectionHeading(
                    title = "Streams",
                    subtitle = state.streamStatusMessage,
                    modifier = Modifier.padding(horizontal = 20.dp),
                )
            }
        }

        if (state.streamStatusMessage != null && state.streamCandidates.isEmpty()) {
            item {
                GlassPanel(modifier = Modifier.padding(horizontal = 20.dp)) {
                    Text(
                        text = state.streamStatusMessage,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.78f),
                    )
                }
            }
        }

        if (state.streamCandidates.isNotEmpty()) {
            items(state.streamCandidates, key = { it.id }) { stream ->
                StreamCandidateCard(
                    stream = stream,
                    onPlayStream = onPlayStream,
                    modifier = Modifier.padding(horizontal = 20.dp),
                )
            }
        }

        state.playerSource?.let { playerSource ->
            item {
                EclipsePlayerSurface(
                    source = playerSource,
                    preferredPlayer = preferredPlayer,
                    settings = playbackSettings,
                    skipSegments = state.skipSegments,
                    nextEpisodeLabel = state.nextEpisodeLabel(),
                    onNextEpisode = onPlayNextEpisode,
                    onProgress = onPlaybackProgress,
                    modifier = Modifier.padding(horizontal = 20.dp),
                )
            }
        }

        state.skipStatusMessage?.let { message ->
            item {
                GlassPanel(modifier = Modifier.padding(horizontal = 20.dp)) {
                    Text(
                        text = message,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.78f),
                    )
                }
            }
        }

        if (state.cast.isNotEmpty()) {
            item {
                SectionHeading(
                    title = "Cast",
                    modifier = Modifier.padding(horizontal = 20.dp),
                )
            }
            item {
                LazyRow(
                    horizontalArrangement = Arrangement.spacedBy(14.dp),
                    contentPadding = PaddingValues(horizontal = 20.dp),
                ) {
                    items(state.cast, key = { it.id }) { cast ->
                        CastMember(cast = cast)
                    }
                }
            }
        }

        if (state.title.isNotBlank()) {
            item {
                StarRatingSection(
                    rating = state.userRating,
                    onSetRating = onSetRating,
                    onClearRating = onClearRating,
                    modifier = Modifier.padding(horizontal = 20.dp),
                )
            }
        }

        state.episodesTitle?.let { title ->
            if (state.episodes.isNotEmpty()) {
                if (isSeasonedShow && !state.seasonMenu) {
                    item {
                        SectionHeading(
                            title = "Seasons",
                            modifier = Modifier.padding(horizontal = 20.dp),
                        )
                    }
                    item {
                        StyledSeasonSelector(
                            episodeSeasons = episodeSeasons,
                            selectedSeason = selectedSeason,
                            onSelectSeason = {
                                selectedSpecialGroupKey = null
                                selectedSeason = it
                            },
                        )
                    }
                }

                if (specialEpisodeGroups.isNotEmpty()) {
                    item {
                        SpecialsOvaSection(
                            groups = specialEpisodeGroups,
                            selectedKey = activeSpecialGroup?.key,
                            onSelectGroup = { selectedSpecialGroupKey = it },
                            modifier = Modifier.padding(top = 2.dp),
                        )
                    }
                }

                item {
                    EpisodesHeader(
                        title = activeSpecialGroup?.title ?: title,
                        isSeasonedShow = isSeasonedShow,
                        seasonMenu = state.seasonMenu,
                        episodeSeasons = episodeSeasons,
                        selectedSeason = selectedSeason,
                        onSelectSeason = {
                            selectedSpecialGroupKey = null
                            selectedSeason = it
                        },
                        modifier = Modifier.padding(horizontal = 20.dp),
                    )
                }

                if (state.horizontalEpisodeList) {
                    item {
                        LazyRow(
                            horizontalArrangement = Arrangement.spacedBy(14.dp),
                            contentPadding = PaddingValues(horizontal = 20.dp),
                        ) {
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
                            modifier = Modifier.padding(horizontal = 20.dp),
                        )
                    }
                }
            }
        }

    }
}

@Composable
private fun DetailHero(
    title: String,
    subtitle: String?,
    imageUrl: String?,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = modifier
            .fillMaxWidth()
            .height(390.dp),
    ) {
        PosterImage(
            imageUrl = imageUrl,
            contentDescription = title,
            modifier = Modifier.fillMaxSize(),
        )
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(
                    Brush.verticalGradient(
                        colors = listOf(
                            Color.Transparent,
                            Color(0x44200E34),
                            Color(0xFF15081F),
                        ),
                    ),
                ),
        )
        Column(
            modifier = Modifier
                .align(Alignment.BottomCenter)
                .padding(horizontal = 20.dp, vertical = 18.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            subtitle?.takeIf { it.isNotBlank() }?.let {
                Text(
                    text = it.uppercase(),
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.tertiary,
                    textAlign = TextAlign.Center,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Text(
                text = title,
                style = MaterialTheme.typography.displaySmall,
                fontWeight = FontWeight.Bold,
                color = Color.White,
                textAlign = TextAlign.Center,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun SynopsisBlock(
    text: String,
    modifier: Modifier = Modifier,
) {
    var expanded by remember(text) { mutableStateOf(false) }
    Text(
        text = text,
        modifier = modifier
            .fillMaxWidth()
            .clickable { expanded = !expanded },
        style = MaterialTheme.typography.bodyLarge,
        color = MaterialTheme.colorScheme.onBackground.copy(alpha = 0.9f),
        maxLines = if (expanded) Int.MAX_VALUE else 3,
        overflow = TextOverflow.Ellipsis,
    )
}

@Composable
private fun MetadataStrip(
    values: List<String>,
    modifier: Modifier = Modifier,
) {
    LazyRow(
        modifier = modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        items(values, key = { it }) { value ->
            Box(
                modifier = Modifier
                    .clip(RoundedCornerShape(100.dp))
                    .background(Color.White.copy(alpha = 0.12f))
                    .padding(horizontal = 12.dp, vertical = 7.dp),
            ) {
                Text(
                    text = value,
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onBackground,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun DetailActions(
    isResolvingStreams: Boolean,
    selectedEpisodeLabel: String?,
    isMovie: Boolean,
    collections: List<DetailCollectionRow>,
    onResolveStreams: () -> Unit,
    onSaveToLibrary: () -> Unit,
    onQueueDownload: () -> Unit,
    onAddToCollection: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    var collectionsExpanded by remember(collections) { mutableStateOf(false) }

    Row(
        modifier = modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Button(
            onClick = onResolveStreams,
            modifier = Modifier
                .weight(1f)
                .height(48.dp),
            colors = ButtonDefaults.buttonColors(
                containerColor = Color.White.copy(alpha = 0.20f),
                contentColor = Color.White,
            ),
        ) {
            Icon(
                imageVector = Icons.Rounded.PlayArrow,
                contentDescription = null,
            )
            Spacer(modifier = Modifier.width(6.dp))
            Text(
                text = when {
                    isResolvingStreams -> "Resolving"
                    selectedEpisodeLabel != null -> "Play $selectedEpisodeLabel"
                    else -> "Play"
                },
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        DetailIconButton(
            icon = Icons.Rounded.Bookmark,
            contentDescription = "Bookmark",
            onClick = onSaveToLibrary,
        )
        if (isMovie) {
            DetailIconButton(
                icon = Icons.Rounded.Download,
                contentDescription = "Download",
                onClick = onQueueDownload,
            )
        }
        Box {
            DetailIconButton(
                icon = Icons.Rounded.Add,
                contentDescription = "Add to collection",
                onClick = { collectionsExpanded = true },
            )
            DropdownMenu(
                expanded = collectionsExpanded,
                onDismissRequest = { collectionsExpanded = false },
            ) {
                if (collections.isEmpty()) {
                    DropdownMenuItem(
                        text = { Text("No collections yet") },
                        onClick = { collectionsExpanded = false },
                    )
                } else {
                    collections.forEach { collection ->
                        DropdownMenuItem(
                            text = {
                                Text(
                                    if (collection.isSelected) {
                                        "${collection.name} (added)"
                                    } else {
                                        collection.name
                                    },
                                )
                            },
                            onClick = {
                                onAddToCollection(collection.id)
                                collectionsExpanded = false
                            },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun DetailIconButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    contentDescription: String,
    onClick: () -> Unit,
) {
    IconButton(
        onClick = onClick,
        modifier = Modifier
            .size(48.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(Color.White.copy(alpha = 0.12f)),
    ) {
        Icon(
            imageVector = icon,
            contentDescription = contentDescription,
            tint = Color.White,
        )
    }
}

@Composable
private fun StarRatingSection(
    rating: Int?,
    onSetRating: (Int) -> Unit,
    onClearRating: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            text = "Your Rating",
            style = MaterialTheme.typography.labelLarge,
            fontWeight = FontWeight.SemiBold,
            color = Color.White.copy(alpha = 0.7f),
        )
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            (1..5).forEach { value ->
                Icon(
                    imageVector = if ((rating ?: 0) >= value) Icons.Rounded.Star else Icons.Rounded.StarBorder,
                    contentDescription = "Rate $value",
                    tint = if ((rating ?: 0) >= value) Color(0xFFFFD54F) else Color.White.copy(alpha = 0.32f),
                    modifier = Modifier
                        .size(30.dp)
                        .clickable {
                            if (rating == value) {
                                onClearRating()
                            } else {
                                onSetRating(value)
                            }
                        },
                )
            }
            rating?.let {
                Text(
                    text = "$it/5",
                    style = MaterialTheme.typography.labelMedium,
                    color = Color.White.copy(alpha = 0.5f),
                    modifier = Modifier.padding(start = 4.dp),
                )
            }
        }
    }
}

@Composable
private fun DetailFactsCard(
    facts: List<DetailFactRow>,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            text = "Details",
            style = MaterialTheme.typography.titleLarge,
            color = MaterialTheme.colorScheme.onBackground,
        )
        GlassPanel(contentPadding = PaddingValues(16.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                facts.forEach { fact ->
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(16.dp),
                    ) {
                        Text(
                            text = fact.label,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.68f),
                            modifier = Modifier.width(92.dp),
                        )
                        Text(
                            text = fact.value,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurface,
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun StreamCandidateCard(
    stream: DetailStreamRow,
    onPlayStream: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    GlassPanel(
        modifier = modifier,
        contentPadding = PaddingValues(16.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                text = stream.title,
                style = MaterialTheme.typography.titleMedium,
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

@Composable
private fun CastMember(
    cast: DetailCastRow,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.width(92.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        PosterImage(
            imageUrl = cast.imageUrl,
            contentDescription = cast.name,
            modifier = Modifier
                .size(78.dp)
                .clip(CircleShape),
        )
        Text(
            text = cast.name,
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onBackground,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            textAlign = TextAlign.Center,
        )
        cast.role?.let {
            Text(
                text = it,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onBackground.copy(alpha = 0.68f),
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                textAlign = TextAlign.Center,
            )
        }
    }
}

@Composable
private fun EpisodesHeader(
    title: String,
    isSeasonedShow: Boolean,
    seasonMenu: Boolean,
    episodeSeasons: List<Int>,
    selectedSeason: Int?,
    onSelectSeason: (Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = title,
            style = MaterialTheme.typography.titleLarge,
            color = MaterialTheme.colorScheme.onBackground,
        )
        if (isSeasonedShow && seasonMenu) {
            SeasonDropdown(
                episodeSeasons = episodeSeasons,
                selectedSeason = selectedSeason,
                onSelectSeason = onSelectSeason,
            )
        }
    }
}

@Composable
private fun SeasonDropdown(
    episodeSeasons: List<Int>,
    selectedSeason: Int?,
    onSelectSeason: (Int) -> Unit,
) {
    var expanded by remember(episodeSeasons, selectedSeason) { mutableStateOf(false) }
    Box {
        OutlinedButton(onClick = { expanded = true }) {
            Text(seasonLabel(selectedSeason ?: episodeSeasons.firstOrNull() ?: 1))
        }
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
        ) {
            episodeSeasons.forEach { season ->
                DropdownMenuItem(
                    text = { Text(seasonLabel(season)) },
                    onClick = {
                        onSelectSeason(season)
                        expanded = false
                    },
                )
            }
        }
    }
}

@Composable
private fun StyledSeasonSelector(
    episodeSeasons: List<Int>,
    selectedSeason: Int?,
    onSelectSeason: (Int) -> Unit,
) {
    LazyRow(
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        contentPadding = PaddingValues(horizontal = 20.dp),
    ) {
        items(episodeSeasons, key = { it }) { season ->
            val selected = season == selectedSeason
            Column(
                modifier = Modifier
                    .width(82.dp)
                    .clickable { onSelectSeason(season) },
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Box(
                    modifier = Modifier
                        .size(width = 82.dp, height = 122.dp)
                        .clip(RoundedCornerShape(12.dp))
                        .background(
                            Brush.linearGradient(
                                colors = listOf(
                                    Color(0xFF5F2EA0),
                                    Color(0xFF21102F),
                                    Color(0xFF0C0711),
                                ),
                            ),
                        )
                        .border(
                            width = if (selected) 2.dp else 0.dp,
                            color = if (selected) MaterialTheme.colorScheme.tertiary else Color.Transparent,
                            shape = RoundedCornerShape(12.dp),
                        ),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        text = if (season == 0) "OVA" else "S$season",
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                        color = Color.White,
                    )
                }
                Text(
                    text = seasonLabel(season),
                    style = MaterialTheme.typography.labelMedium,
                    color = if (selected) MaterialTheme.colorScheme.tertiary else MaterialTheme.colorScheme.onBackground,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    textAlign = TextAlign.Center,
                )
            }
        }
    }
}

@Composable
private fun SpecialsOvaSection(
    groups: List<SpecialEpisodeGroup>,
    selectedKey: String?,
    onSelectGroup: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        SectionHeading(
            title = "Specials & OVAs",
            modifier = Modifier.padding(horizontal = 20.dp),
        )
        LazyRow(
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            contentPadding = PaddingValues(horizontal = 20.dp),
        ) {
            items(groups, key = { it.key }) { group ->
                val selected = group.key == selectedKey
                Column(
                    modifier = Modifier
                        .width(86.dp)
                        .clickable { onSelectGroup(group.key) },
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    PosterImage(
                        imageUrl = group.imageUrl,
                        contentDescription = group.title,
                        modifier = Modifier
                            .size(width = 80.dp, height = 120.dp)
                            .clip(RoundedCornerShape(12.dp))
                            .border(
                                width = if (selected) 2.dp else 0.dp,
                                color = if (selected) MaterialTheme.colorScheme.tertiary else Color.Transparent,
                                shape = RoundedCornerShape(12.dp),
                            ),
                    )
                    Text(
                        text = group.title,
                        style = MaterialTheme.typography.labelMedium,
                        fontWeight = FontWeight.Medium,
                        color = if (selected) MaterialTheme.colorScheme.tertiary else Color.White,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                        textAlign = TextAlign.Center,
                    )
                    Text(
                        text = group.subtitle,
                        style = MaterialTheme.typography.labelSmall,
                        color = Color.White.copy(alpha = 0.65f),
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        textAlign = TextAlign.Center,
                    )
                }
            }
        }
    }
}

private fun seasonLabel(season: Int): String =
    if (season == 0) "Specials & OVAs" else "Season $season"

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun EpisodeCard(
    episode: DetailEpisodeRow,
    onResolveEpisodeStreams: (String) -> Unit,
    onMarkEpisodeWatched: (String) -> Unit,
    onMarkEpisodeUnwatched: (String) -> Unit,
    onMarkPreviousEpisodesWatched: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    var menuExpanded by remember(episode.id) { mutableStateOf(false) }
    GlassPanel(
        modifier = modifier.combinedClickable(
            onClick = { onResolveEpisodeStreams(episode.id) },
            onLongClick = { menuExpanded = true },
        ),
        contentPadding = PaddingValues(12.dp),
    ) {
        Box {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                PosterImage(
                    imageUrl = episode.imageUrl,
                    contentDescription = episode.title,
                    modifier = Modifier
                        .width(126.dp)
                        .height(74.dp)
                        .clip(RoundedCornerShape(10.dp)),
                )
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(
                        text = episode.title,
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    episode.subtitle?.let {
                        Text(
                            text = it,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.tertiary,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    episode.overview?.takeIf { it.isNotBlank() }?.let {
                        Text(
                            text = it,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.72f),
                            maxLines = 3,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
            DropdownMenu(
                expanded = menuExpanded,
                onDismissRequest = { menuExpanded = false },
            ) {
                DropdownMenuItem(
                    text = { Text("Play") },
                    onClick = {
                        menuExpanded = false
                        onResolveEpisodeStreams(episode.id)
                    },
                )
                DropdownMenuItem(
                    text = { Text("Mark Watched") },
                    onClick = {
                        menuExpanded = false
                        onMarkEpisodeWatched(episode.id)
                    },
                )
                DropdownMenuItem(
                    text = { Text("Mark Unwatched") },
                    onClick = {
                        menuExpanded = false
                        onMarkEpisodeUnwatched(episode.id)
                    },
                )
                DropdownMenuItem(
                    text = { Text("Mark Previous Watched") },
                    onClick = {
                        menuExpanded = false
                        onMarkPreviousEpisodesWatched(episode.id)
                    },
                )
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

private fun DetailEpisodeRow.specialGroupKey(): String =
    searchTitle
        ?.trim()
        ?.takeIf { it.isNotBlank() }
        ?.lowercase()
        ?: id.substringBeforeLast('-', id)
