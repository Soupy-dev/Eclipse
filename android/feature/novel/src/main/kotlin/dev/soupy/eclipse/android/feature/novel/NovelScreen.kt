package dev.soupy.eclipse.android.feature.novel

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import dev.soupy.eclipse.android.core.design.GlassPanel
import dev.soupy.eclipse.android.core.design.HeroBackdrop
import dev.soupy.eclipse.android.core.design.PosterImage
import dev.soupy.eclipse.android.core.design.SectionHeading

data class NovelScreenState(
    val isLoading: Boolean = false,
    val errorMessage: String? = null,
    val noticeMessage: String? = null,
    val query: String = "",
    val isSearching: Boolean = false,
    val novelCount: Int = 0,
    val readChapterCount: Int = 0,
    val importedFromBackup: Boolean = false,
    val searchResults: List<NovelCatalogItemRow> = emptyList(),
    val savedItems: List<NovelCatalogItemRow> = emptyList(),
    val catalogs: List<NovelCatalogSectionRow> = emptyList(),
    val recent: List<NovelProgressRow> = emptyList(),
    val modules: List<NovelModuleRow> = emptyList(),
)

data class NovelCatalogSectionRow(
    val id: String,
    val title: String,
    val items: List<NovelCatalogItemRow>,
)

data class NovelCatalogItemRow(
    val id: String,
    val aniListId: Int,
    val title: String,
    val subtitle: String,
    val coverUrl: String? = null,
    val description: String? = null,
    val format: String? = null,
    val totalChapters: Int? = null,
    val isSaved: Boolean = false,
    val isFavorite: Boolean = false,
    val readChapterCount: Int = 0,
    val unreadChapterCount: Int? = null,
    val lastReadChapter: String? = null,
)

data class NovelProgressRow(
    val id: String,
    val aniListId: Int? = null,
    val title: String,
    val subtitle: String,
    val coverUrl: String? = null,
    val readChapterCount: Int = 0,
    val unreadChapterCount: Int? = null,
)

data class NovelModuleRow(
    val id: String,
    val name: String,
    val subtitle: String,
    val isActive: Boolean,
)

@Composable
fun NovelRoute(
    state: NovelScreenState,
    onRefresh: () -> Unit,
    onQueryChange: (String) -> Unit,
    onSearch: () -> Unit,
    onSaveItem: (String) -> Unit,
    onRemoveItem: (Int) -> Unit,
    onReadNext: (Int) -> Unit,
    onUnreadLast: (Int) -> Unit,
    onToggleFavorite: (Int) -> Unit,
    onClearProgress: (String) -> Unit,
    onAddModule: (String) -> Unit,
    onSetModuleActive: (String, Boolean) -> Unit,
    onUpdateModule: (String) -> Unit,
    onUpdateAllModules: () -> Unit,
    onRemoveModule: (String) -> Unit,
) {
    var moduleUrl by rememberSaveable { mutableStateOf("") }

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding(),
        verticalArrangement = Arrangement.spacedBy(18.dp),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 18.dp),
    ) {
        item {
            HeroBackdrop(
                title = "Novels",
                subtitle = "${state.novelCount} saved - ${state.readChapterCount} chapters read",
                imageUrl = state.recent.firstOrNull()?.coverUrl,
                supportingText = "Light novel progress, reader history, and novel-capable Kanzen modules now hydrate from Android storage and Luna backups.",
            )
        }

        if (state.importedFromBackup) {
            item {
                GlassPanel {
                    Text(
                        text = "Imported staged novel data from the local Luna backup.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.tertiary,
                    )
                }
            }
        }

        state.noticeMessage?.let { notice ->
            item {
                GlassPanel {
                    Text(
                        text = notice,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.tertiary,
                    )
                }
            }
        }

        state.errorMessage?.let { message ->
            item {
                GlassPanel {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text(
                            text = message,
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.error,
                        )
                        Button(onClick = onRefresh) {
                            Text("Retry")
                        }
                    }
                }
            }
        }

        item {
            GlassPanel {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(
                        text = "AniList Novel Search",
                        style = MaterialTheme.typography.titleLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    OutlinedTextField(
                        value = state.query,
                        onValueChange = onQueryChange,
                        label = { Text("Title") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                        keyboardActions = KeyboardActions(onSearch = { onSearch() }),
                    )
                    Button(
                        onClick = onSearch,
                        enabled = state.query.isNotBlank() && !state.isSearching,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(if (state.isSearching) "Searching..." else "Search Novels")
                    }
                }
            }
        }

        item {
            GlassPanel {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(
                        text = "Add Novel Module",
                        style = MaterialTheme.typography.titleLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    OutlinedTextField(
                        value = moduleUrl,
                        onValueChange = { moduleUrl = it },
                        label = { Text("Module URL") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Button(
                        onClick = {
                            onAddModule(moduleUrl)
                            moduleUrl = ""
                        },
                        enabled = moduleUrl.isNotBlank(),
                    ) {
                        Text("Save Module")
                    }
                    OutlinedButton(
                        onClick = onUpdateAllModules,
                        enabled = state.modules.isNotEmpty(),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text("Update All Modules")
                    }
                }
            }
        }

        item {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                StatPanel("Novels", state.novelCount.toString(), Modifier.weight(1f))
                StatPanel("Modules", state.modules.size.toString(), Modifier.weight(1f))
            }
        }

        if (state.searchResults.isNotEmpty()) {
            item {
                SectionHeading(
                    title = "Search Results",
                    subtitle = "Save AniList novels directly into the Android library.",
                )
            }
            items(state.searchResults, key = { it.id }) { item ->
                NovelItemCard(
                    item = item,
                    onSave = { onSaveItem(item.id) },
                    onRemove = { onRemoveItem(item.aniListId) },
                    onReadNext = { onReadNext(item.aniListId) },
                    onUnreadLast = { onUnreadLast(item.aniListId) },
                    onToggleFavorite = { onToggleFavorite(item.aniListId) },
                )
            }
        }

        if (state.savedItems.isNotEmpty()) {
            item {
                SectionHeading(
                    title = "Saved Novels",
                    subtitle = "Library items persisted in Android storage and backup export.",
                )
            }
            items(state.savedItems, key = { it.id }) { item ->
                NovelItemCard(
                    item = item,
                    onSave = { onSaveItem(item.id) },
                    onRemove = { onRemoveItem(item.aniListId) },
                    onReadNext = { onReadNext(item.aniListId) },
                    onUnreadLast = { onUnreadLast(item.aniListId) },
                    onToggleFavorite = { onToggleFavorite(item.aniListId) },
                )
            }
        }

        if (state.catalogs.isNotEmpty()) {
            items(state.catalogs, key = { it.id }) { section ->
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    SectionHeading(
                        title = section.title,
                        subtitle = "AniList novel browse row.",
                    )
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        items(section.items, key = { it.id }) { item ->
                            NovelCatalogCard(
                                item = item,
                                onSave = { onSaveItem(item.id) },
                                onRemove = { onRemoveItem(item.aniListId) },
                                onReadNext = { onReadNext(item.aniListId) },
                                onUnreadLast = { onUnreadLast(item.aniListId) },
                                onToggleFavorite = { onToggleFavorite(item.aniListId) },
                                modifier = Modifier.width(170.dp),
                            )
                        }
                    }
                }
            }
        }

        if (state.recent.isNotEmpty()) {
            item {
                SectionHeading(
                    title = "Reading",
                    subtitle = "Recent novel progress restored on Android.",
                )
            }
            items(state.recent, key = { it.id }) { row ->
                NovelProgressCard(
                    row = row,
                    onReadNext = { row.aniListId?.let(onReadNext) },
                    onUnreadLast = { row.aniListId?.let(onUnreadLast) },
                    onClearProgress = { onClearProgress(row.id) },
                )
            }
        }

        if (state.modules.isNotEmpty()) {
            item {
                SectionHeading(
                    title = "Novel Modules",
                    subtitle = "Installed Kanzen modules marked for novel reading.",
                )
            }
            items(state.modules, key = { it.id }) { row ->
                NovelModuleCard(
                    row = row,
                    onActiveChanged = { active -> onSetModuleActive(row.id, active) },
                    onUpdate = { onUpdateModule(row.id) },
                    onRemove = { onRemoveModule(row.id) },
                )
            }
        }

        if (!state.isLoading && state.errorMessage == null && state.searchResults.isEmpty() && state.savedItems.isEmpty() && state.catalogs.isEmpty() && state.recent.isEmpty() && state.modules.isEmpty()) {
            item {
                GlassPanel {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text(
                            text = "No novel data yet",
                            style = MaterialTheme.typography.titleLarge,
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                        Text(
                            text = "Import a Luna backup with novel progress or install novel-capable Kanzen modules as the Android reader runtime lands.",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.74f),
                        )
                        Button(onClick = onRefresh) {
                            Text("Refresh")
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun NovelCatalogCard(
    item: NovelCatalogItemRow,
    onSave: () -> Unit,
    onRemove: () -> Unit,
    onReadNext: () -> Unit,
    onUnreadLast: () -> Unit,
    onToggleFavorite: () -> Unit,
    modifier: Modifier = Modifier,
) {
    GlassPanel(modifier = modifier) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            PosterImage(
                imageUrl = item.coverUrl,
                contentDescription = item.title,
                modifier = Modifier
                    .fillMaxWidth()
                    .aspectRatio(2f / 3f),
            )
            Text(
                text = item.title,
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            if (item.subtitle.isNotBlank()) {
                Text(
                    text = item.subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.tertiary,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            ProgressSummary(item)
            item.description?.takeIf { it.isNotBlank() }?.let {
                Text(
                    text = it,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.72f),
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (item.isSaved) {
                OutlinedButton(
                    onClick = onRemove,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text("Remove")
                }
                Button(
                    onClick = onReadNext,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text("Read Next")
                }
                OutlinedButton(
                    onClick = onUnreadLast,
                    enabled = item.readChapterCount > 0,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text("Unread Last")
                }
                OutlinedButton(
                    onClick = onToggleFavorite,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(if (item.isFavorite) "Unfavorite" else "Favorite")
                }
            } else {
                Button(
                    onClick = onSave,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text("Save")
                }
            }
        }
    }
}

@Composable
private fun NovelItemCard(
    item: NovelCatalogItemRow,
    onSave: () -> Unit,
    onRemove: () -> Unit,
    onReadNext: () -> Unit,
    onUnreadLast: () -> Unit,
    onToggleFavorite: () -> Unit,
) {
    GlassPanel {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            PosterImage(
                imageUrl = item.coverUrl,
                contentDescription = item.title,
                modifier = Modifier
                    .width(96.dp)
                    .aspectRatio(2f / 3f),
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
                if (item.subtitle.isNotBlank()) {
                    Text(
                        text = item.subtitle,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.tertiary,
                    )
                }
                ProgressSummary(item)
                item.description?.takeIf { it.isNotBlank() }?.let {
                    Text(
                        text = it,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.74f),
                        maxLines = 3,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                if (item.isSaved) {
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Button(onClick = onReadNext) {
                            Text("Read Next")
                        }
                        OutlinedButton(
                            onClick = onUnreadLast,
                            enabled = item.readChapterCount > 0,
                        ) {
                            Text("Unread Last")
                        }
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        OutlinedButton(onClick = onToggleFavorite) {
                            Text(if (item.isFavorite) "Unfavorite" else "Favorite")
                        }
                        OutlinedButton(onClick = onRemove) {
                            Text("Remove")
                        }
                    }
                } else {
                    Button(onClick = onSave) {
                        Text("Save to Library")
                    }
                }
            }
        }
    }
}

@Composable
private fun ProgressSummary(item: NovelCatalogItemRow) {
    val progress = listOfNotNull(
        item.lastReadChapter?.let { "Chapter $it" },
        item.totalChapters?.takeIf { it > 0 }?.let { "${item.readChapterCount}/$it read" }
            ?: item.readChapterCount.takeIf { it > 0 }?.let { "$it read" },
        item.unreadChapterCount?.takeIf { it > 0 }?.let { "$it unread" },
        if (item.isFavorite) "Favorite" else null,
    ).joinToString(" - ")
    if (progress.isNotBlank()) {
        Text(
            text = progress,
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.primary,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun StatPanel(
    title: String,
    value: String,
    modifier: Modifier = Modifier,
) {
    GlassPanel(modifier = modifier) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                text = value,
                style = MaterialTheme.typography.headlineMedium,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = title,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.tertiary,
            )
        }
    }
}

@Composable
private fun NovelProgressCard(
    row: NovelProgressRow,
    onReadNext: () -> Unit,
    onUnreadLast: () -> Unit,
    onClearProgress: () -> Unit,
) {
    GlassPanel {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                PosterImage(
                    imageUrl = row.coverUrl,
                    contentDescription = row.title,
                    modifier = Modifier
                        .width(92.dp)
                        .aspectRatio(2f / 3f),
                )
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        text = row.title,
                        style = MaterialTheme.typography.titleLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (row.subtitle.isNotBlank()) {
                        Text(
                            text = row.subtitle,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.tertiary,
                        )
                    }
                    val progress = listOfNotNull(
                        row.readChapterCount.takeIf { it > 0 }?.let { "$it read" },
                        row.unreadChapterCount?.takeIf { it > 0 }?.let { "$it unread" },
                    ).joinToString(" - ")
                    if (progress.isNotBlank()) {
                        Text(
                            text = progress,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.primary,
                        )
                    }
                }
            }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Button(
                    onClick = onReadNext,
                    enabled = row.aniListId != null,
                ) {
                    Text("Read Next")
                }
                OutlinedButton(
                    onClick = onUnreadLast,
                    enabled = row.aniListId != null && row.readChapterCount > 0,
                ) {
                    Text("Unread Last")
                }
                OutlinedButton(onClick = onClearProgress) {
                    Text("Reset")
                }
            }
        }
    }
}

@Composable
private fun NovelModuleCard(
    row: NovelModuleRow,
    onActiveChanged: (Boolean) -> Unit,
    onUpdate: () -> Unit,
    onRemove: () -> Unit,
) {
    GlassPanel {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        text = row.name,
                        style = MaterialTheme.typography.titleLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        text = listOf(
                            row.subtitle,
                            if (row.isActive) "Active" else "Inactive",
                        ).filter(String::isNotBlank).joinToString(" - "),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.tertiary,
                    )
                }
                Switch(
                    checked = row.isActive,
                    onCheckedChange = onActiveChanged,
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedButton(onClick = onUpdate) {
                    Text("Update")
                }
                OutlinedButton(onClick = onRemove) {
                    Text("Remove")
                }
            }
        }
    }
}
