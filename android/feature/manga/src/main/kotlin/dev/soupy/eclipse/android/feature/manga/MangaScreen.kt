package dev.soupy.eclipse.android.feature.manga

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
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
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.text.input.ImeAction
import dev.soupy.eclipse.android.core.design.ContentImage
import dev.soupy.eclipse.android.core.design.GlassPanel
import dev.soupy.eclipse.android.core.design.HeroBackdrop
import dev.soupy.eclipse.android.core.design.PosterImage
import dev.soupy.eclipse.android.core.design.SectionHeading

data class MangaScreenState(
    val isLoading: Boolean = false,
    val errorMessage: String? = null,
    val noticeMessage: String? = null,
    val query: String = "",
    val isSearching: Boolean = false,
    val savedCount: Int = 0,
    val readChapterCount: Int = 0,
    val novelCount: Int = 0,
    val importedFromBackup: Boolean = false,
    val searchResults: List<MangaCatalogItemRow> = emptyList(),
    val savedItems: List<MangaCatalogItemRow> = emptyList(),
    val catalogs: List<MangaCatalogSectionRow> = emptyList(),
    val collections: List<MangaCollectionRow> = emptyList(),
    val recent: List<MangaProgressRow> = emptyList(),
    val modules: List<MangaModuleRow> = emptyList(),
    val selectedDetail: MangaCatalogItemRow? = null,
    val isDetailLoading: Boolean = false,
    val detailError: String? = null,
    val reader: MangaReaderPanelRow? = null,
)

data class MangaCatalogSectionRow(
    val id: String,
    val title: String,
    val items: List<MangaCatalogItemRow>,
)

data class MangaCatalogItemRow(
    val id: String,
    val aniListId: Int,
    val title: String,
    val subtitle: String,
    val coverUrl: String? = null,
    val description: String? = null,
    val format: String? = null,
    val totalChapters: Int? = null,
    val moduleId: String? = null,
    val contentParams: String? = null,
    val sourceName: String? = null,
    val isSaved: Boolean = false,
    val isFavorite: Boolean = false,
    val readChapterCount: Int = 0,
    val unreadChapterCount: Int? = null,
    val lastReadChapter: String? = null,
)

data class MangaCollectionRow(
    val id: String,
    val name: String,
    val subtitle: String,
    val itemIds: Set<Int> = emptySet(),
    val isEditable: Boolean = false,
)

data class MangaProgressRow(
    val id: String,
    val aniListId: Int? = null,
    val title: String,
    val subtitle: String,
    val coverUrl: String? = null,
    val moduleId: String? = null,
    val contentParams: String? = null,
    val sourceName: String? = null,
    val readChapterCount: Int = 0,
    val unreadChapterCount: Int? = null,
)

data class MangaModuleRow(
    val id: String,
    val name: String,
    val subtitle: String,
    val isActive: Boolean,
)

data class MangaReaderPanelRow(
    val aniListId: Int,
    val title: String,
    val coverUrl: String? = null,
    val format: String? = null,
    val totalChapters: Int? = null,
    val moduleId: String? = null,
    val contentParams: String? = null,
    val sourceName: String? = null,
    val readChapterCount: Int = 0,
    val unreadChapterCount: Int? = null,
    val lastReadChapter: String? = null,
    val currentChapter: Int = 1,
    val chapters: List<MangaReaderChapterRow> = emptyList(),
    val isLoadingChapters: Boolean = false,
    val isLoadingContent: Boolean = false,
    val contentMessage: String? = null,
    val contentError: String? = null,
    val pageImageUrls: List<String> = emptyList(),
)

data class MangaReaderChapterRow(
    val number: Int,
    val title: String? = null,
    val params: String? = null,
    val sourceName: String? = null,
    val isRead: Boolean,
    val isCurrent: Boolean,
)

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun MangaRoute(
    state: MangaScreenState,
    onRefresh: () -> Unit,
    onQueryChange: (String) -> Unit,
    onSearch: () -> Unit,
    onSaveItem: (String) -> Unit,
    onRemoveItem: (Int) -> Unit,
    onOpenDetail: (String) -> Unit,
    onCloseDetail: () -> Unit,
    onReadNext: (Int) -> Unit,
    onUnreadLast: (Int) -> Unit,
    onReadPrevious: (Int) -> Unit,
    onOpenReader: (Int) -> Unit,
    onCloseReader: () -> Unit,
    onReadChapter: (Int, Int) -> Unit,
    onToggleFavorite: (Int) -> Unit,
    onClearProgress: (String) -> Unit,
    onAddModule: (String) -> Unit,
    onSetModuleActive: (String, Boolean) -> Unit,
    onUpdateModule: (String) -> Unit,
    onUpdateAllModules: () -> Unit,
    onRemoveModule: (String) -> Unit,
    onCreateCollection: (String) -> Unit,
    onDeleteCollection: (String) -> Unit,
    onAddItemToCollection: (String, Int) -> Unit,
    onRemoveItemFromCollection: (String, Int) -> Unit,
) {
    var moduleUrl by rememberSaveable { mutableStateOf("") }
    var collectionName by rememberSaveable { mutableStateOf("") }
    val editableCollections = state.collections.filter { collection -> collection.isEditable }

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding(),
        verticalArrangement = Arrangement.spacedBy(18.dp),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 18.dp),
    ) {
        item {
            HeroBackdrop(
                title = "Manga",
                subtitle = "${state.savedCount} saved - ${state.readChapterCount} chapters read",
                imageUrl = state.recent.firstOrNull()?.coverUrl,
                supportingText = if (state.novelCount > 0) {
                    "${state.novelCount} novel progress ${if (state.novelCount == 1) "entry" else "entries"} restored with manga history."
                } else {
                    "Kanzen library, progress, module, and catalog data now load from Android storage and Luna backups."
                },
            )
        }

        if (state.importedFromBackup) {
            item {
                GlassPanel {
                    Text(
                        text = "Imported staged manga data from the local Luna backup.",
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

        state.selectedDetail?.let { detail ->
            item {
                MangaDetailPanel(
                    item = detail,
                    isLoading = state.isDetailLoading,
                    errorMessage = state.detailError,
                    onClose = onCloseDetail,
                    onSave = { onSaveItem(detail.id) },
                    onRemove = { onRemoveItem(detail.aniListId) },
                    onOpenReader = { onOpenReader(detail.aniListId) },
                    onReadNext = { onReadNext(detail.aniListId) },
                    onUnreadLast = { onUnreadLast(detail.aniListId) },
                    onToggleFavorite = { onToggleFavorite(detail.aniListId) },
                    collections = editableCollections,
                    onAddToCollection = { collectionId -> onAddItemToCollection(collectionId, detail.aniListId) },
                    onRemoveFromCollection = { collectionId -> onRemoveItemFromCollection(collectionId, detail.aniListId) },
                )
            }
        }

        state.reader?.let { reader ->
            item {
                MangaReaderPanel(
                    reader = reader,
                    onClose = onCloseReader,
                    onReadChapter = { chapter -> onReadChapter(reader.aniListId, chapter) },
                    onReadNext = { onReadNext(reader.aniListId) },
                    onReadPrevious = { onReadPrevious(reader.aniListId) },
                    onUnreadLast = { onUnreadLast(reader.aniListId) },
                )
            }
        }

        item {
            GlassPanel {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(
                        text = "AniList Manga Search",
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
                        Text(if (state.isSearching) "Searching..." else "Search Manga")
                    }
                }
            }
        }

        item {
            GlassPanel {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(
                        text = "Add Kanzen Module",
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
                StatPanel("Collections", state.collections.size.toString(), Modifier.weight(1f))
                StatPanel("Modules", state.modules.size.toString(), Modifier.weight(1f))
            }
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
                        label = { Text("Collection Name") },
                        singleLine = true,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Button(
                        onClick = {
                            onCreateCollection(collectionName)
                            collectionName = ""
                        },
                        enabled = collectionName.isNotBlank(),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text("Create")
                    }
                }
            }
        }

        if (state.searchResults.isNotEmpty()) {
            item {
                SectionHeading(
                    title = "Search Results",
                    subtitle = "Save AniList manga directly into the Android library.",
                )
            }
            items(state.searchResults, key = { it.id }) { item ->
                MangaSearchResultCard(
                    item = item,
                    onSave = { onSaveItem(item.id) },
                    onRemove = { onRemoveItem(item.aniListId) },
                    onOpenDetail = { onOpenDetail(item.id) },
                    onOpenReader = { onOpenReader(item.aniListId) },
                    onReadNext = { onReadNext(item.aniListId) },
                    onUnreadLast = { onUnreadLast(item.aniListId) },
                    onToggleFavorite = { onToggleFavorite(item.aniListId) },
                    collections = editableCollections,
                    onAddToCollection = { collectionId -> onAddItemToCollection(collectionId, item.aniListId) },
                    onRemoveFromCollection = { collectionId -> onRemoveItemFromCollection(collectionId, item.aniListId) },
                )
            }
        }

        if (state.savedItems.isNotEmpty()) {
            item {
                SectionHeading(
                    title = "Saved Manga",
                    subtitle = "Library items persisted in Android storage and backup export.",
                )
            }
            items(state.savedItems, key = { it.id }) { item ->
                MangaSearchResultCard(
                    item = item,
                    onSave = { onSaveItem(item.id) },
                    onRemove = { onRemoveItem(item.aniListId) },
                    onOpenDetail = { onOpenDetail(item.id) },
                    onOpenReader = { onOpenReader(item.aniListId) },
                    onReadNext = { onReadNext(item.aniListId) },
                    onUnreadLast = { onUnreadLast(item.aniListId) },
                    onToggleFavorite = { onToggleFavorite(item.aniListId) },
                    collections = editableCollections,
                    onAddToCollection = { collectionId -> onAddItemToCollection(collectionId, item.aniListId) },
                    onRemoveFromCollection = { collectionId -> onRemoveItemFromCollection(collectionId, item.aniListId) },
                )
            }
        }

        if (state.catalogs.isNotEmpty()) {
            items(state.catalogs, key = { it.id }) { section ->
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    SectionHeading(
                        title = section.title,
                        subtitle = "AniList manga browse row.",
                    )
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                        items(section.items, key = { it.id }) { item ->
                            MangaCatalogCard(
                                item = item,
                                onSave = { onSaveItem(item.id) },
                                onRemove = { onRemoveItem(item.aniListId) },
                                onOpenDetail = { onOpenDetail(item.id) },
                                onOpenReader = { onOpenReader(item.aniListId) },
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
                    subtitle = "Recent manga and novel progress restored on Android.",
                )
            }
            items(state.recent, key = { it.id }) { row ->
                MangaProgressCard(
                    row = row,
                    onOpenReader = { row.aniListId?.let(onOpenReader) },
                    onReadNext = { row.aniListId?.let(onReadNext) },
                    onUnreadLast = { row.aniListId?.let(onUnreadLast) },
                    onClearProgress = { onClearProgress(row.id) },
                )
            }
        }

        if (state.collections.isNotEmpty()) {
            item {
                SectionHeading(
                    title = "Collections",
                    subtitle = "Kanzen library collections from Android storage.",
                )
            }
            items(state.collections, key = { it.id }) { row ->
                MangaCollectionCard(
                    row = row,
                    onDelete = { onDeleteCollection(row.id) },
                )
            }
        }

        if (state.modules.isNotEmpty()) {
            item {
                SectionHeading(
                    title = "Modules",
                    subtitle = "Installed Kanzen module records ready for the runtime.",
                )
            }
            items(state.modules, key = { it.id }) { row ->
                MangaModuleCard(
                    row = row,
                    onActiveChanged = { active -> onSetModuleActive(row.id, active) },
                    onUpdate = { onUpdateModule(row.id) },
                    onRemove = { onRemoveModule(row.id) },
                )
            }
        }

        if (!state.isLoading && state.errorMessage == null && state.catalogs.isEmpty() && state.collections.isEmpty() && state.recent.isEmpty() && state.modules.isEmpty()) {
            item {
                GlassPanel {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        Text(
                            text = "No manga library data yet",
                            style = MaterialTheme.typography.titleLarge,
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                        Text(
                            text = "Import a Luna backup or add Kanzen modules as the Android reader runtime lands.",
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
private fun MangaDetailPanel(
    item: MangaCatalogItemRow,
    isLoading: Boolean,
    errorMessage: String?,
    onClose: () -> Unit,
    onSave: () -> Unit,
    onRemove: () -> Unit,
    onOpenReader: () -> Unit,
    onReadNext: () -> Unit,
    onUnreadLast: () -> Unit,
    onToggleFavorite: () -> Unit,
    collections: List<MangaCollectionRow>,
    onAddToCollection: (String) -> Unit,
    onRemoveFromCollection: (String) -> Unit,
) {
    GlassPanel {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                PosterImage(
                    imageUrl = item.coverUrl,
                    contentDescription = item.title,
                    modifier = Modifier
                        .width(112.dp)
                        .aspectRatio(2f / 3f),
                )
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        text = item.title,
                        style = MaterialTheme.typography.headlineSmall,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 3,
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
                    item.sourceName?.takeIf { it.isNotBlank() }?.let { source ->
                        Text(
                            text = "Source: $source",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.68f),
                        )
                    }
                    if (isLoading) {
                        Text(
                            text = "Loading module details...",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.primary,
                        )
                    }
                    errorMessage?.let { message ->
                        Text(
                            text = message,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.error,
                        )
                    }
                }
            }

            item.description?.takeIf { it.isNotBlank() }?.let { description ->
                Text(
                    text = description,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.78f),
                )
            }

            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                if (item.isSaved) {
                    Button(onClick = onOpenReader) {
                        Text("Reader")
                    }
                    Button(onClick = onReadNext) {
                        Text("Read Next")
                    }
                    OutlinedButton(
                        onClick = onUnreadLast,
                        enabled = item.readChapterCount > 0,
                    ) {
                        Text("Unread Last")
                    }
                    OutlinedButton(onClick = onToggleFavorite) {
                        Text(if (item.isFavorite) "Unfavorite" else "Favorite")
                    }
                    OutlinedButton(onClick = onRemove) {
                        Text("Remove")
                    }
                } else {
                    Button(onClick = onSave) {
                        Text("Save to Library")
                    }
                }
                OutlinedButton(onClick = onClose) {
                    Text("Close")
                }
            }

            if (item.isSaved) {
                CollectionActions(
                    item = item,
                    collections = collections,
                    onAddToCollection = onAddToCollection,
                    onRemoveFromCollection = onRemoveFromCollection,
                )
            }
        }
    }
}

@Composable
private fun MangaCatalogCard(
    item: MangaCatalogItemRow,
    onSave: () -> Unit,
    onRemove: () -> Unit,
    onOpenDetail: () -> Unit,
    onOpenReader: () -> Unit,
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
            OutlinedButton(
                onClick = onOpenDetail,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Details")
            }
            if (item.isSaved) {
                OutlinedButton(
                    onClick = onRemove,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text("Remove")
                }
                Button(
                    onClick = onOpenReader,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text("Reader")
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
private fun MangaSearchResultCard(
    item: MangaCatalogItemRow,
    onSave: () -> Unit,
    onRemove: () -> Unit,
    onOpenDetail: () -> Unit,
    onOpenReader: () -> Unit,
    onReadNext: () -> Unit,
    onUnreadLast: () -> Unit,
    onToggleFavorite: () -> Unit,
    collections: List<MangaCollectionRow> = emptyList(),
    onAddToCollection: (String) -> Unit = {},
    onRemoveFromCollection: (String) -> Unit = {},
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
                OutlinedButton(onClick = onOpenDetail) {
                    Text("Details")
                }
                if (item.isSaved) {
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Button(onClick = onOpenReader) {
                            Text("Reader")
                        }
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
                    CollectionActions(
                        item = item,
                        collections = collections,
                        onAddToCollection = onAddToCollection,
                        onRemoveFromCollection = onRemoveFromCollection,
                    )
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
private fun CollectionActions(
    item: MangaCatalogItemRow,
    collections: List<MangaCollectionRow>,
    onAddToCollection: (String) -> Unit,
    onRemoveFromCollection: (String) -> Unit,
) {
    if (collections.isEmpty()) return
    FlowRow(
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        collections.forEach { collection ->
            val containsItem = item.aniListId in collection.itemIds
            OutlinedButton(
                onClick = {
                    if (containsItem) {
                        onRemoveFromCollection(collection.id)
                    } else {
                        onAddToCollection(collection.id)
                    }
                },
            ) {
                Text(if (containsItem) "Remove ${collection.name}" else "Add ${collection.name}")
            }
        }
    }
}

@Composable
private fun ProgressSummary(item: MangaCatalogItemRow) {
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
private fun MangaProgressCard(
    row: MangaProgressRow,
    onOpenReader: () -> Unit,
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
                row.coverUrl?.let { cover ->
                    PosterImage(
                        imageUrl = cover,
                        contentDescription = row.title,
                        modifier = Modifier
                            .weight(0.34f)
                            .aspectRatio(2f / 3f),
                    )
                }
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        text = row.title,
                        style = MaterialTheme.typography.titleLarge,
                        color = MaterialTheme.colorScheme.onSurface,
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
                    onClick = onOpenReader,
                    enabled = row.aniListId != null,
                ) {
                    Text("Reader")
                }
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
private fun MangaReaderPanel(
    reader: MangaReaderPanelRow,
    onClose: () -> Unit,
    onReadChapter: (Int) -> Unit,
    onReadNext: () -> Unit,
    onReadPrevious: () -> Unit,
    onUnreadLast: () -> Unit,
) {
    var chapterInput by rememberSaveable(reader.aniListId, reader.currentChapter) {
        mutableStateOf(reader.currentChapter.toString())
    }
    val targetChapter = chapterInput.toIntOrNull()
        ?.coerceAtLeast(1)
        ?.let { chapter -> reader.totalChapters?.let { chapter.coerceAtMost(it) } ?: chapter }

    GlassPanel {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                PosterImage(
                    imageUrl = reader.coverUrl,
                    contentDescription = reader.title,
                    modifier = Modifier
                        .width(86.dp)
                        .aspectRatio(2f / 3f),
                )
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        text = reader.title,
                        style = MaterialTheme.typography.titleLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Text(
                        text = listOfNotNull(
                            reader.format?.replace('_', ' '),
                            reader.sourceName,
                            reader.lastReadChapter?.let { "Last read chapter $it" },
                            reader.totalChapters?.let { "${reader.readChapterCount}/$it read" }
                                ?: reader.readChapterCount.takeIf { it > 0 }?.let { "$it read" },
                            reader.unreadChapterCount?.takeIf { it > 0 }?.let { "$it unread" },
                        ).joinToString(" - ").ifBlank { "Chapter progress" },
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.tertiary,
                    )
                    Text(
                        text = "Current chapter ${reader.currentChapter}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.primary,
                    )
                    if (reader.isLoadingChapters) {
                        Text(
                            text = "Loading module chapters...",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.tertiary,
                        )
                    }
                }
            }

            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                reader.chapters.forEach { chapter ->
                    if (chapter.isCurrent) {
                        Button(onClick = { onReadChapter(chapter.number) }) {
                            Text(chapter.buttonLabel())
                        }
                    } else {
                        OutlinedButton(onClick = { onReadChapter(chapter.number) }) {
                            Text(if (chapter.isRead) "Read ${chapter.number}" else chapter.buttonLabel())
                        }
                    }
                }
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                OutlinedTextField(
                    value = chapterInput,
                    onValueChange = { value -> chapterInput = value.filter(Char::isDigit).take(5) },
                    label = { Text("Chapter") },
                    singleLine = true,
                    modifier = Modifier.weight(1f),
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                )
                Button(
                    onClick = { targetChapter?.let(onReadChapter) },
                    enabled = targetChapter != null,
                ) {
                    Text("Mark Read")
                }
            }

            FlowRow(
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Button(onClick = { onReadChapter(reader.currentChapter) }) {
                    Text("Mark Current Read")
                }
                OutlinedButton(onClick = onReadNext) {
                    Text("Next Chapter")
                }
                OutlinedButton(
                    onClick = onReadPrevious,
                    enabled = reader.currentChapter > 1,
                ) {
                    Text("Previous")
                }
                OutlinedButton(
                    onClick = onUnreadLast,
                    enabled = reader.readChapterCount > 0,
                ) {
                    Text("Unread Last")
                }
                OutlinedButton(onClick = onClose) {
                    Text("Close")
                }
            }

            if (reader.isLoadingContent) {
                Text(
                    text = reader.contentMessage ?: "Loading chapter pages...",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.tertiary,
                )
            }
            reader.contentError?.let { error ->
                Text(
                    text = error,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.error,
                )
            }
            if (reader.pageImageUrls.isNotEmpty()) {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    reader.pageImageUrls.forEachIndexed { index, imageUrl ->
                        ContentImage(
                            imageUrl = imageUrl,
                            contentDescription = "${reader.title} page ${index + 1}",
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }
        }
    }
}

private fun MangaReaderChapterRow.buttonLabel(): String =
    title?.takeIf { it.isNotBlank() }?.let { value ->
        if (value.length <= 12) value else "Ch $number"
    } ?: "Ch $number"

@Composable
private fun MangaCollectionCard(
    row: MangaCollectionRow,
    onDelete: () -> Unit,
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
                    )
                    if (row.subtitle.isNotBlank()) {
                        Text(
                            text = row.subtitle,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.tertiary,
                        )
                    }
                }
                if (row.isEditable) {
                    OutlinedButton(onClick = onDelete) {
                        Text("Delete")
                    }
                }
            }
            if (row.itemIds.isNotEmpty()) {
                Text(
                    text = "${row.itemIds.size} ${if (row.itemIds.size == 1) "title" else "titles"}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.primary,
                )
            }
        }
    }
}

@Composable
private fun MangaModuleCard(
    row: MangaModuleRow,
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
