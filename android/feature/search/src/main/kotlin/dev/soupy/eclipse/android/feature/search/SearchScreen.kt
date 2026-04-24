package dev.soupy.eclipse.android.feature.search

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import dev.soupy.eclipse.android.core.design.ErrorPanel
import dev.soupy.eclipse.android.core.design.LoadingPanel
import dev.soupy.eclipse.android.core.design.MediaPosterCard
import dev.soupy.eclipse.android.core.design.SectionHeading
import dev.soupy.eclipse.android.core.model.DetailTarget
import dev.soupy.eclipse.android.core.model.MediaCarouselSection

data class SearchScreenState(
    val query: String = "",
    val isSearching: Boolean = false,
    val errorMessage: String? = null,
    val recentQueries: List<String> = emptyList(),
    val sections: List<MediaCarouselSection> = emptyList(),
)

@Composable
fun SearchRoute(
    state: SearchScreenState,
    onQueryChange: (String) -> Unit,
    onSearch: () -> Unit,
    onRecentQuery: (String) -> Unit,
    onSelect: (DetailTarget) -> Unit,
) {
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding(),
        verticalArrangement = Arrangement.spacedBy(18.dp),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 18.dp),
    ) {
        item {
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    text = "SEARCH",
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.tertiary,
                )
                Text(
                    text = "Search TMDB and AniList together.",
                    style = MaterialTheme.typography.displayMedium,
                    color = MaterialTheme.colorScheme.onBackground,
                )
            }
        }

        item {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = state.query,
                    onValueChange = onQueryChange,
                    label = { Text("Movie, show, or anime title") },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    keyboardActions = KeyboardActions(onSearch = { onSearch() }),
                )
                Button(
                    onClick = onSearch,
                    enabled = state.query.isNotBlank() && !state.isSearching,
                ) {
                    Text("Search")
                }
            }
        }

        if (state.query.isBlank() && state.recentQueries.isNotEmpty()) {
            item {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    SectionHeading(
                        title = "Recent Searches",
                        subtitle = "Saved locally on Android so repeated searches feel closer to Luna.",
                    )
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        items(state.recentQueries, key = { it }) { query ->
                            Button(onClick = { onRecentQuery(query) }) {
                                Text(query)
                            }
                        }
                    }
                }
            }
        }

        if (state.isSearching) {
            item {
                LoadingPanel(
                    title = "Searching",
                    message = "Looking across TMDB and AniList without collapsing anime into a single generic flow.",
                )
            }
        }

        state.errorMessage?.let { error ->
            item {
                ErrorPanel(
                    title = "Search hit a snag",
                    message = error,
                    actionLabel = "Retry",
                    onAction = onSearch,
                )
            }
        }

        if (state.query.isBlank() && state.sections.isEmpty()) {
            item {
                ErrorPanel(
                    title = "Start with a title",
                    message = "This screen is wired for multi-page TMDB search, AniList queries, and local recent searches.",
                )
            }
        }

        items(state.sections, key = { it.id }) { section ->
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                SectionHeading(
                    title = section.title,
                    subtitle = section.subtitle,
                )
                LazyRow(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    items(section.items, key = { it.id }) { item ->
                        MediaPosterCard(
                            item = item,
                            onClick = { onSelect(it.detailTarget) },
                            modifier = Modifier.width(208.dp),
                        )
                    }
                }
            }
        }
    }
}

