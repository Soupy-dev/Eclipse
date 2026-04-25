package dev.soupy.eclipse.android.feature.library

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Button
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.soupy.eclipse.android.core.design.ErrorPanel
import dev.soupy.eclipse.android.core.design.GlassPanel
import dev.soupy.eclipse.android.core.design.HeroBackdrop
import dev.soupy.eclipse.android.core.design.LoadingPanel
import dev.soupy.eclipse.android.core.design.PosterImage
import dev.soupy.eclipse.android.core.design.SectionHeading
import dev.soupy.eclipse.android.core.model.DetailTarget

data class LibraryMetric(
    val label: String,
    val value: String,
    val supportingText: String,
)

data class LibrarySavedItemRow(
    val id: String,
    val title: String,
    val subtitle: String? = null,
    val overview: String? = null,
    val imageUrl: String? = null,
    val backdropUrl: String? = null,
    val mediaLabel: String? = null,
    val detailTarget: DetailTarget,
)

data class ContinueWatchingRow(
    val id: String,
    val title: String,
    val subtitle: String? = null,
    val imageUrl: String? = null,
    val backdropUrl: String? = null,
    val progressPercent: Float = 0f,
    val progressLabel: String? = null,
    val detailTarget: DetailTarget,
)

data class LibraryCollectionRow(
    val id: String,
    val name: String,
    val description: String? = null,
    val itemCount: Int = 0,
    val items: List<LibrarySavedItemRow> = emptyList(),
    val canDelete: Boolean = true,
)

data class LibraryScreenState(
    val isLoading: Boolean = true,
    val errorMessage: String? = null,
    val heroTitle: String = "Library",
    val heroSubtitle: String? = "Saved media",
    val heroImageUrl: String? = null,
    val heroSupportingText: String? = null,
    val metrics: List<LibraryMetric> = emptyList(),
    val continueWatching: List<ContinueWatchingRow> = emptyList(),
    val savedItems: List<LibrarySavedItemRow> = emptyList(),
    val collections: List<LibraryCollectionRow> = emptyList(),
)

@Composable
fun LibraryRoute(
    state: LibraryScreenState,
    onRefresh: () -> Unit,
    onSelect: (DetailTarget) -> Unit,
    onRemoveSaved: (String) -> Unit,
    onRemoveContinueWatching: (String) -> Unit,
    onCreateCollection: (String) -> Unit,
    onDeleteCollection: (String) -> Unit,
    onRemoveFromCollection: (String, String) -> Unit,
) {
    var collectionName by rememberSaveable { mutableStateOf("") }
    val bookmarks = state.collections.firstOrNull { it.name.equals("Bookmarks", ignoreCase = true) }
    val bookmarkItems = bookmarks?.items?.takeIf { it.isNotEmpty() } ?: state.savedItems
    val visibleCollections = state.collections.filterNot { it.name.equals("Bookmarks", ignoreCase = true) }
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
                    title = "Loading library",
                    message = "Fetching saved titles.",
                )
            }
        }

        state.errorMessage?.let { error ->
            item {
                ErrorPanel(
                    title = "Library couldn't load",
                    message = error,
                    actionLabel = "Retry",
                    onAction = onRefresh,
                )
            }
        }

        if (state.continueWatching.isNotEmpty()) {
            item {
                SectionHeading(
                    title = "Continue Watching",
                    subtitle = "Resume entries sync from playback and tracker imports.",
                )
            }
            items(state.continueWatching, key = { it.id }) { item ->
                ContinueWatchingCard(
                    item = item,
                    onOpen = { onSelect(item.detailTarget) },
                    onRemove = { onRemoveContinueWatching(item.id) },
                )
            }
        }

        item {
            SectionHeading(
                title = "Bookmarks",
                subtitle = "${bookmarkItems.size} saved title${if (bookmarkItems.size == 1) "" else "s"}.",
            )
        }

        if (bookmarkItems.isEmpty()) {
            item {
                GlassPanel {
                    Text(
                        text = "No bookmarked media yet.",
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.78f),
                    )
                }
            }
        } else {
            item {
                LazyRow(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    items(bookmarkItems, key = { it.id }) { item ->
                        LibraryPosterTile(
                            item = item,
                            onOpen = { onSelect(item.detailTarget) },
                            modifier = Modifier.width(108.dp),
                        )
                    }
                }
            }
        }

        item {
            SectionHeading(
                title = "Collections",
                subtitle = "${visibleCollections.size} custom collection${if (visibleCollections.size == 1) "" else "s"}.",
            )
        }

        item {
            GlassPanel {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(
                        text = "Create Collection",
                        style = MaterialTheme.typography.titleLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    OutlinedTextField(
                        value = collectionName,
                        onValueChange = { collectionName = it },
                        modifier = Modifier.fillMaxWidth(),
                        label = { Text("Collection name") },
                        singleLine = true,
                    )
                    Button(
                        onClick = {
                            onCreateCollection(collectionName)
                            collectionName = ""
                        },
                        enabled = collectionName.isNotBlank(),
                    ) {
                        Text("Create")
                    }
                }
            }
        }

        if (visibleCollections.isNotEmpty()) {
            item {
                LazyRow(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    items(visibleCollections, key = { it.id }) { collection ->
                        CollectionPreviewCard(
                            row = collection,
                            onOpen = {
                                collection.items.firstOrNull()?.detailTarget?.let(onSelect)
                            },
                            onDelete = { onDeleteCollection(collection.id) },
                        )
                    }
                }
            }
        }

        if (state.savedItems.isNotEmpty()) {
            item {
                SectionHeading(
                    title = "Saved",
                    subtitle = "Pinned titles stay separate from playback progress, matching the Luna direction.",
                )
            }
            items(state.savedItems, key = { it.id }) { item ->
                SavedLibraryCard(
                    item = item,
                    onOpen = { onSelect(item.detailTarget) },
                    onRemove = { onRemoveSaved(item.id) },
                )
            }
        }

        if (!state.isLoading && state.errorMessage == null &&
            state.continueWatching.isEmpty() && state.savedItems.isEmpty() && state.collections.all { it.items.isEmpty() }
        ) {
            item {
                GlassPanel {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text(
                            text = "Nothing saved yet",
                            style = MaterialTheme.typography.titleLarge,
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                        Text(
                            text = "Open a detail page, then bookmark it or start watching to build your library.",
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.8f),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun LibraryPosterTile(
    item: LibrarySavedItemRow,
    onOpen: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier.clickable(onClick = onOpen),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        PosterImage(
            imageUrl = item.imageUrl ?: item.backdropUrl,
            contentDescription = item.title,
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(2f / 3f)
                .clip(RoundedCornerShape(14.dp)),
        )
        Text(
            text = item.title,
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onBackground,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun CollectionPreviewCard(
    row: LibraryCollectionRow,
    onOpen: () -> Unit,
    onDelete: () -> Unit,
) {
    GlassPanel(
        modifier = Modifier
            .width(250.dp)
            .clickable(enabled = row.items.isNotEmpty(), onClick = onOpen),
        contentPadding = PaddingValues(12.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                val preview = row.items.take(3)
                if (preview.isEmpty()) {
                    Box(
                        modifier = Modifier
                            .width(132.dp)
                            .aspectRatio(16 / 9f),
                    )
                } else {
                    preview.forEach { item ->
                        PosterImage(
                            imageUrl = item.imageUrl ?: item.backdropUrl,
                            contentDescription = item.title,
                            modifier = Modifier
                                .width(64.dp)
                                .aspectRatio(2f / 3f)
                                .clip(RoundedCornerShape(10.dp)),
                        )
                    }
                }
            }
            Text(
                text = row.name,
                style = MaterialTheme.typography.titleLarge,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                text = "${row.itemCount} item${if (row.itemCount == 1) "" else "s"}",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.72f),
            )
            OutlinedButton(
                onClick = onDelete,
                enabled = row.canDelete,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Delete")
            }
        }
    }
}

@Composable
private fun CollectionCard(
    row: LibraryCollectionRow,
    onSelect: (DetailTarget) -> Unit,
    onDelete: () -> Unit,
    onRemoveItem: (String) -> Unit,
) {
    GlassPanel {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text(
                        text = row.name,
                        style = MaterialTheme.typography.titleLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Text(
                        text = row.description ?: "${row.itemCount} item${if (row.itemCount == 1) "" else "s"}",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.tertiary,
                    )
                }
                OutlinedButton(
                    onClick = onDelete,
                    enabled = row.canDelete,
                ) {
                    Text("Delete")
                }
            }
            if (row.items.isEmpty()) {
                Text(
                    text = "No saved media in this collection yet.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.72f),
                )
            } else {
                row.items.forEach { item ->
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Text(
                            text = item.title,
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.onSurface,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        Button(onClick = { onSelect(item.detailTarget) }) {
                            Text("Open")
                        }
                        OutlinedButton(onClick = { onRemoveItem(item.id) }) {
                            Text("Remove")
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun LibraryMetrics(
    metrics: List<LibraryMetric>,
) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        metrics.chunked(2).forEach { rowMetrics ->
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                rowMetrics.forEach { metric ->
                    GlassPanel(
                        modifier = Modifier.weight(1f),
                    ) {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(
                                text = metric.label.uppercase(),
                                style = MaterialTheme.typography.labelLarge,
                                color = MaterialTheme.colorScheme.tertiary,
                            )
                            Text(
                                text = metric.value,
                                style = MaterialTheme.typography.headlineMedium,
                                color = MaterialTheme.colorScheme.onSurface,
                            )
                            Text(
                                text = metric.supportingText,
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.72f),
                            )
                        }
                    }
                }
                if (rowMetrics.size == 1) {
                    Spacer(modifier = Modifier.weight(1f))
                }
            }
        }
    }
}

@Composable
private fun ContinueWatchingCard(
    item: ContinueWatchingRow,
    onOpen: () -> Unit,
    onRemove: () -> Unit,
) {
    GlassPanel {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                PosterImage(
                    imageUrl = item.imageUrl ?: item.backdropUrl,
                    contentDescription = item.title,
                    modifier = Modifier
                        .width(94.dp)
                        .aspectRatio(0.72f),
                )
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        text = item.title,
                        style = MaterialTheme.typography.titleLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    item.subtitle?.let {
                        Text(
                            text = it,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.tertiary,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    item.progressLabel?.let {
                        Text(
                            text = it,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.76f),
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }

            LinearProgressIndicator(
                progress = { item.progressPercent.coerceIn(0f, 1f) },
                modifier = Modifier.fillMaxWidth(),
            )

            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(onClick = onOpen) {
                    Text("Open")
                }
                OutlinedButton(onClick = onRemove) {
                    Text("Remove")
                }
            }
        }
    }
}

@Composable
private fun SavedLibraryCard(
    item: LibrarySavedItemRow,
    onOpen: () -> Unit,
    onRemove: () -> Unit,
) {
    GlassPanel {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                PosterImage(
                    imageUrl = item.imageUrl ?: item.backdropUrl,
                    contentDescription = item.title,
                    modifier = Modifier
                        .width(94.dp)
                        .aspectRatio(0.72f),
                )
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    item.mediaLabel?.let {
                        Text(
                            text = it.uppercase(),
                            style = MaterialTheme.typography.labelLarge,
                            color = MaterialTheme.colorScheme.tertiary,
                        )
                    }
                    Text(
                        text = item.title,
                        style = MaterialTheme.typography.titleLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    item.subtitle?.let {
                        Text(
                            text = it,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.76f),
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    item.overview?.takeIf { it.isNotBlank() }?.let {
                        Text(
                            text = it,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f),
                            maxLines = 3,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(onClick = onOpen) {
                    Text("Open")
                }
                OutlinedButton(onClick = onRemove) {
                    Text("Remove")
                }
            }
        }
    }
}
