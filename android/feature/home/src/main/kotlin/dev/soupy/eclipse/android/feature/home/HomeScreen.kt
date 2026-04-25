package dev.soupy.eclipse.android.feature.home

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.soupy.eclipse.android.core.design.ErrorPanel
import dev.soupy.eclipse.android.core.design.GlassPanel
import dev.soupy.eclipse.android.core.design.HeroBackdrop
import dev.soupy.eclipse.android.core.design.LoadingPanel
import dev.soupy.eclipse.android.core.design.MediaPosterCard
import dev.soupy.eclipse.android.core.design.PosterImage
import dev.soupy.eclipse.android.core.design.SectionHeading
import dev.soupy.eclipse.android.core.model.DetailTarget
import dev.soupy.eclipse.android.core.model.ExploreMediaCard
import dev.soupy.eclipse.android.core.model.MediaCarouselSection

data class HomeScreenState(
    val isLoading: Boolean = false,
    val errorMessage: String? = null,
    val hero: ExploreMediaCard? = null,
    val sections: List<MediaCarouselSection> = emptyList(),
)

@Composable
fun HomeRoute(
    state: HomeScreenState,
    onRefresh: () -> Unit,
    onSelect: (DetailTarget) -> Unit,
) {
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding(),
        verticalArrangement = Arrangement.spacedBy(24.dp),
        contentPadding = PaddingValues(bottom = 18.dp),
    ) {
        state.hero?.let { hero ->
            item {
                HeroBackdrop(
                    title = hero.title,
                    subtitle = hero.badge ?: hero.subtitle,
                    imageUrl = hero.backdropUrl ?: hero.imageUrl,
                    supportingText = hero.overview,
                    height = 440.dp,
                    primaryActionLabel = "Watch Now",
                    onPrimaryAction = { onSelect(hero.detailTarget) },
                    modifier = Modifier.clickable { onSelect(hero.detailTarget) },
                )
            }
        }

        if (state.isLoading && state.sections.isEmpty()) {
            item {
                LoadingPanel(
                    title = "Loading discovery",
                    message = "Fetching rows.",
                    modifier = Modifier.padding(horizontal = 16.dp),
                )
            }
        }

        state.errorMessage?.let { error ->
            item {
                ErrorPanel(
                    title = "Home couldn't finish loading",
                    message = error,
                    actionLabel = "Try Again",
                    onAction = onRefresh,
                    modifier = Modifier.padding(horizontal = 16.dp),
                )
            }
        }

        items(state.sections, key = { it.id }) { section ->
            HomeSection(
                section = section,
                onSelect = onSelect,
                modifier = Modifier.padding(horizontal = 16.dp),
            )
        }

        if (!state.isLoading && state.errorMessage == null && state.sections.isEmpty()) {
            item {
                ErrorPanel(
                    title = "Nothing landed yet",
                    message = "There were no browse sections to show.",
                    actionLabel = "Refresh",
                    onAction = onRefresh,
                    modifier = Modifier.padding(horizontal = 16.dp),
                )
            }
        }
    }
}

@Composable
private fun HomeSection(
    section: MediaCarouselSection,
    onSelect: (DetailTarget) -> Unit,
    modifier: Modifier = Modifier,
) {
    val lowerTitle = section.title.lowercase()
    val useLandscapeCards = section.id.contains("continue", ignoreCase = true) ||
        lowerTitle.contains("network") ||
        lowerTitle.contains("company") ||
        lowerTitle.contains("featured")
    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        SectionHeading(
            title = section.title,
            subtitle = section.subtitle,
        )
        LazyRow(horizontalArrangement = Arrangement.spacedBy(if (useLandscapeCards) 14.dp else 16.dp)) {
            items(section.items, key = { it.id }) { item ->
                if (useLandscapeCards) {
                    HomeLandscapeCard(
                        item = item,
                        onClick = { onSelect(item.detailTarget) },
                    )
                } else {
                    MediaPosterCard(
                        item = item,
                        onClick = { onSelect(it.detailTarget) },
                        modifier = Modifier.width(108.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun HomeLandscapeCard(
    item: ExploreMediaCard,
    onClick: () -> Unit,
) {
    GlassPanel(
        modifier = Modifier
            .width(260.dp)
            .clickable(onClick = onClick),
        contentPadding = PaddingValues(10.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(138.dp)
                    .clip(RoundedCornerShape(12.dp)),
            ) {
                PosterImage(
                    imageUrl = item.backdropUrl ?: item.imageUrl,
                    contentDescription = item.title,
                    modifier = Modifier.fillMaxSize(),
                )
            }
            Text(
                text = item.title,
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            item.subtitle?.takeIf { it.isNotBlank() }?.let {
                Text(
                    text = it,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.68f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

