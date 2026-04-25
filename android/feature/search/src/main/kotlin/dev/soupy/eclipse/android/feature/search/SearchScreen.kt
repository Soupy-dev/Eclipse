package dev.soupy.eclipse.android.feature.search

import android.content.res.Configuration
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import dev.soupy.eclipse.android.core.design.ErrorPanel
import dev.soupy.eclipse.android.core.design.LoadingPanel
import dev.soupy.eclipse.android.core.design.MediaPosterCard
import dev.soupy.eclipse.android.core.design.SectionHeading
import dev.soupy.eclipse.android.core.model.DetailTarget
import dev.soupy.eclipse.android.core.model.MediaCarouselSection

data class SearchSourceRow(
    val id: String,
    val label: String,
    val subtitle: String? = null,
    val isTmdb: Boolean = false,
)

private enum class SearchFilter(val label: String) {
    ALL("All"),
    MOVIES("Movies"),
    TV("TV Shows"),
}

data class SearchScreenState(
    val query: String = "",
    val isSearching: Boolean = false,
    val errorMessage: String? = null,
    val recentQueries: List<String> = emptyList(),
    val sections: List<MediaCarouselSection> = emptyList(),
    val sourceOptions: List<SearchSourceRow> = listOf(SearchSourceRow("tmdb", "TMDB", "Movies and TV shows", isTmdb = true)),
    val selectedSourceId: String = "tmdb",
    val mediaColumnsPortrait: Int = 3,
    val mediaColumnsLandscape: Int = 5,
)

@Composable
fun SearchRoute(
    state: SearchScreenState,
    onQueryChange: (String) -> Unit,
    onSearch: () -> Unit,
    onRecentQuery: (String) -> Unit,
    onSourceSelected: (String) -> Unit,
    onSelect: (DetailTarget) -> Unit,
) {
    val configuration = LocalConfiguration.current
    val columnCount = if (configuration.orientation == Configuration.ORIENTATION_LANDSCAPE) {
        state.mediaColumnsLandscape
    } else {
        state.mediaColumnsPortrait
    }.coerceIn(2, 8)
    var selectedFilter by rememberSaveable { mutableStateOf(SearchFilter.ALL) }
    val results = state.sections.flatMap { it.items }
    val selectedSource = state.sourceOptions.firstOrNull { it.id == state.selectedSourceId }
        ?: state.sourceOptions.firstOrNull()
    val isTmdbSearch = selectedSource?.isTmdb != false
    val filteredResults = if (!isTmdbSearch) {
        results
    } else {
        when (selectedFilter) {
            SearchFilter.ALL -> results
            SearchFilter.MOVIES -> results.filter { it.detailTarget is DetailTarget.TmdbMovie }
            SearchFilter.TV -> results.filter { it.detailTarget is DetailTarget.TmdbShow }
        }
    }

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding(),
        verticalArrangement = Arrangement.spacedBy(16.dp),
        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 16.dp),
    ) {
        item {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = state.query,
                    onValueChange = onQueryChange,
                    label = { Text("Search ${selectedSource?.label ?: "TMDB"}") },
                    modifier = Modifier.weight(1f),
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

        if (state.sourceOptions.isNotEmpty()) {
            item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    SectionHeading(
                        title = "Source",
                        subtitle = selectedSource?.subtitle,
                    )
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        items(state.sourceOptions, key = { it.id }) { source ->
                            if (source.id == state.selectedSourceId) {
                                Button(onClick = { onSourceSelected(source.id) }) {
                                    Text(source.label)
                                }
                            } else {
                                androidx.compose.material3.OutlinedButton(onClick = { onSourceSelected(source.id) }) {
                                    Text(source.label)
                                }
                            }
                        }
                    }
                }
            }
        }

        if (results.isNotEmpty() && isTmdbSearch) {
            item {
                LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    items(SearchFilter.entries, key = { it.name }) { filter ->
                        if (filter == selectedFilter) {
                            Button(onClick = { selectedFilter = filter }) {
                                Text(filter.label)
                            }
                        } else {
                            androidx.compose.material3.OutlinedButton(onClick = { selectedFilter = filter }) {
                                Text(filter.label)
                            }
                        }
                    }
                }
            }
        }

        if (state.query.isBlank() && state.recentQueries.isNotEmpty()) {
            item {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    SectionHeading(
                        title = "Recent Searches",
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
                    message = if (isTmdbSearch) {
                        "Looking across movies and TV shows."
                    } else {
                        "Asking ${selectedSource?.label ?: "the selected service"}."
                    },
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
                    message = if (isTmdbSearch) {
                        "Search for a movie or TV show."
                    } else {
                        "Search the selected service source."
                    },
                )
            }
        }

        if (results.isNotEmpty() && filteredResults.isEmpty()) {
            item {
                ErrorPanel(
                    title = "No ${selectedFilter.label.lowercase()} found",
                    message = "Try another filter or search for something else.",
                )
            }
        }

        if (filteredResults.isNotEmpty()) {
            item {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    SectionHeading(
                        title = if (isTmdbSearch) "Search Results" else "${selectedSource?.label ?: "Service"} Results",
                        subtitle = if (isTmdbSearch) {
                            "${filteredResults.size} ${selectedFilter.label.lowercase()} result${if (filteredResults.size == 1) "" else "s"}"
                        } else {
                            "${filteredResults.size} service result${if (filteredResults.size == 1) "" else "s"}"
                        },
                    )
                    filteredResults.chunked(columnCount).forEach { rowItems ->
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            rowItems.forEach { item ->
                                MediaPosterCard(
                                    item = item,
                                    onClick = { onSelect(item.detailTarget) },
                                    modifier = Modifier.weight(1f),
                                )
                            }
                            repeat(columnCount - rowItems.size) {
                                Column(modifier = Modifier.weight(1f)) {}
                            }
                        }
                    }
                }
            }
        }
    }
}

