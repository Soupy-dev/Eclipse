package dev.soupy.eclipse.android.feature.novel

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.pm.ActivityInfo
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import dev.soupy.eclipse.android.core.design.GlassPanel
import dev.soupy.eclipse.android.core.design.HeroBackdrop
import dev.soupy.eclipse.android.core.design.PosterImage
import dev.soupy.eclipse.android.core.design.SectionHeading
import kotlinx.coroutines.delay

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
    val selectedDetail: NovelCatalogItemRow? = null,
    val isDetailLoading: Boolean = false,
    val detailError: String? = null,
    val readerSettings: NovelReaderSettingsRow = NovelReaderSettingsRow(),
    val readerCacheSummary: String = "Reader cache empty.",
    val reader: NovelReaderPanelRow? = null,
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
    val moduleId: String? = null,
    val contentParams: String? = null,
    val sourceName: String? = null,
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
    val moduleId: String? = null,
    val contentParams: String? = null,
    val sourceName: String? = null,
    val readChapterCount: Int = 0,
    val unreadChapterCount: Int? = null,
)

data class NovelModuleRow(
    val id: String,
    val name: String,
    val subtitle: String,
    val isActive: Boolean,
)

data class NovelReaderPanelRow(
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
    val chapters: List<NovelReaderChapterRow> = emptyList(),
    val isLoadingChapters: Boolean = false,
    val isLoadingContent: Boolean = false,
    val contentMessage: String? = null,
    val contentError: String? = null,
    val textContent: String? = null,
)

data class NovelReaderChapterRow(
    val number: Int,
    val title: String? = null,
    val params: String? = null,
    val sourceName: String? = null,
    val isRead: Boolean,
    val isCurrent: Boolean,
)

data class NovelReaderSettingsRow(
    val readingMode: Int = 2,
    val readerFontSize: Double = 16.0,
    val readerFontFamily: String = "-apple-system",
    val readerFontWeight: String = "normal",
    val readerColorPreset: Int = 0,
    val readerLineSpacing: Double = 1.6,
    val readerMargin: Double = 4.0,
    val readerTextAlignment: String = "left",
)

@OptIn(ExperimentalLayoutApi::class)
@Composable
fun NovelRoute(
    state: NovelScreenState,
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
    onClearReaderCache: () -> Unit,
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

        state.selectedDetail?.let { detail ->
            item {
                NovelDetailPanel(
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
                )
            }
        }

        state.reader?.let { reader ->
            item {
                NovelReaderPanel(
                    reader = reader,
                    readerSettings = state.readerSettings,
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

        item {
            GlassPanel {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(
                        text = "Reader Cache",
                        style = MaterialTheme.typography.titleLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Text(
                        text = state.readerCacheSummary,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.tertiary,
                    )
                    OutlinedButton(
                        onClick = onClearReaderCache,
                        enabled = state.readerCacheSummary != "Reader cache empty.",
                    ) {
                        Text("Clear Reader Cache")
                    }
                }
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
                    onOpenDetail = { onOpenDetail(item.id) },
                    onOpenReader = { onOpenReader(item.aniListId) },
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
                    onOpenDetail = { onOpenDetail(item.id) },
                    onOpenReader = { onOpenReader(item.aniListId) },
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
                    subtitle = "Recent novel progress restored on Android.",
                )
            }
            items(state.recent, key = { it.id }) { row ->
                NovelProgressCard(
                    row = row,
                    onOpenReader = { row.aniListId?.let(onOpenReader) },
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
                            text = "Import a Luna backup with novel progress or install novel-capable Kanzen modules to populate this library.",
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
private fun NovelDetailPanel(
    item: NovelCatalogItemRow,
    isLoading: Boolean,
    errorMessage: String?,
    onClose: () -> Unit,
    onSave: () -> Unit,
    onRemove: () -> Unit,
    onOpenReader: () -> Unit,
    onReadNext: () -> Unit,
    onUnreadLast: () -> Unit,
    onToggleFavorite: () -> Unit,
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
        }
    }
}

@Composable
private fun NovelCatalogCard(
    item: NovelCatalogItemRow,
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
private fun NovelItemCard(
    item: NovelCatalogItemRow,
    onSave: () -> Unit,
    onRemove: () -> Unit,
    onOpenDetail: () -> Unit,
    onOpenReader: () -> Unit,
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
private fun NovelReaderPanel(
    reader: NovelReaderPanelRow,
    readerSettings: NovelReaderSettingsRow,
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
    val readerTextStyle = MaterialTheme.typography.bodyLarge.copy(
        fontSize = readerSettings.readerFontSize.coerceIn(12.0, 32.0).sp,
        fontFamily = readerSettings.fontFamily(),
        fontWeight = readerSettings.fontWeight(),
        lineHeight = (readerSettings.readerFontSize.coerceIn(12.0, 32.0) *
            readerSettings.readerLineSpacing.coerceIn(1.0, 2.4)).sp,
        textAlign = readerSettings.textAlign(),
    )
    var controlsVisible by rememberSaveable(reader.aniListId) { mutableStateOf(true) }
    var autoScrollEnabled by rememberSaveable(reader.aniListId, reader.currentChapter) { mutableStateOf(false) }
    var autoScrollSpeed by rememberSaveable(reader.aniListId) { mutableStateOf(2) }
    var orientationLocked by rememberSaveable(reader.aniListId) { mutableStateOf(false) }
    val textScrollState = rememberScrollState()
    val activity = LocalContext.current.findActivity()

    DisposableEffect(activity, orientationLocked) {
        val previousOrientation = activity?.requestedOrientation
        if (orientationLocked) {
            activity?.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        }
        onDispose {
            if (orientationLocked && previousOrientation != null) {
                activity.requestedOrientation = previousOrientation
            }
        }
    }

    LaunchedEffect(autoScrollEnabled, autoScrollSpeed, reader.textContent) {
        while (autoScrollEnabled) {
            delay(90L)
            if (textScrollState.maxValue <= 0) continue
            val next = (textScrollState.value + autoScrollSpeed).coerceAtMost(textScrollState.maxValue)
            textScrollState.scrollTo(next)
            if (next >= textScrollState.maxValue) {
                autoScrollEnabled = false
            }
        }
    }

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
                        text = "Current chapter ${reader.currentChapter} - ${readerSettings.modeLabel()}",
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
                OutlinedButton(onClick = { controlsVisible = !controlsVisible }) {
                    Text(if (controlsVisible) "Hide Controls" else "Show Controls")
                }
                OutlinedButton(onClick = { orientationLocked = !orientationLocked }) {
                    Text(if (orientationLocked) "Unlock Orientation" else "Lock Landscape")
                }
                Button(
                    onClick = { autoScrollEnabled = !autoScrollEnabled },
                    enabled = !reader.textContent.isNullOrBlank(),
                ) {
                    Text(if (autoScrollEnabled) "Stop Scroll" else "Auto Scroll")
                }
                OutlinedButton(
                    onClick = { autoScrollSpeed = (autoScrollSpeed - 1).coerceAtLeast(1) },
                    enabled = autoScrollSpeed > 1,
                ) {
                    Text("Slower")
                }
                OutlinedButton(
                    onClick = { autoScrollSpeed = (autoScrollSpeed + 1).coerceAtMost(8) },
                    enabled = autoScrollSpeed < 8,
                ) {
                    Text("Faster ${autoScrollSpeed}x")
                }
            }

            if (controlsVisible) {
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
            }

            if (reader.isLoadingContent) {
                Text(
                    text = reader.contentMessage ?: "Loading chapter text...",
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
            reader.textContent?.takeIf { it.isNotBlank() }?.let { content ->
                Column(
                    modifier = Modifier
                        .heightIn(max = 680.dp)
                        .background(readerSettings.readerBackgroundColor())
                        .verticalScroll(textScrollState)
                        .padding(
                            horizontal = readerSettings.horizontalPadding(),
                            vertical = 16.dp,
                        ),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    content.readerParagraphs().forEach { paragraph ->
                        Text(
                            text = paragraph,
                            style = readerTextStyle,
                            color = readerSettings.readerTextColor(),
                        )
                    }
                }
            }
        }
    }
}

private fun NovelReaderChapterRow.buttonLabel(): String =
    title?.takeIf { it.isNotBlank() }?.let { value ->
        if (value.length <= 12) value else "Ch $number"
    } ?: "Ch $number"

private fun NovelReaderSettingsRow.modeLabel(): String =
    when (readingMode) {
        0 -> "Paged"
        1 -> "Webtoon"
        else -> "Auto"
    }

private fun NovelReaderSettingsRow.horizontalPadding() =
    readerMargin.coerceIn(0.0, 12.0).dp

private fun NovelReaderSettingsRow.textAlign(): TextAlign =
    when (readerTextAlignment.lowercase()) {
        "center" -> TextAlign.Center
        "right" -> TextAlign.End
        "justify" -> TextAlign.Justify
        else -> TextAlign.Start
    }

private fun NovelReaderSettingsRow.fontFamily(): FontFamily =
    when (readerFontFamily.lowercase()) {
        "georgia",
        "times new roman",
        "charter",
        "new york" -> FontFamily.Serif
        "helvetica" -> FontFamily.SansSerif
        else -> FontFamily.Default
    }

private fun NovelReaderSettingsRow.fontWeight(): FontWeight =
    when (readerFontWeight.lowercase()) {
        "300",
        "light" -> FontWeight.Light
        "600",
        "semibold" -> FontWeight.SemiBold
        "bold",
        "700" -> FontWeight.Bold
        else -> FontWeight.Normal
    }

private fun NovelReaderSettingsRow.readerBackgroundColor(): Color =
    when (readerColorPreset.coerceIn(0, 4)) {
        0 -> Color(0xFFFFFFFF)
        1 -> Color(0xFFF9F1E4)
        2 -> Color(0xFF49494D)
        3 -> Color(0xFF121212)
        else -> Color(0xFF000000)
    }

private fun NovelReaderSettingsRow.readerTextColor(): Color =
    when (readerColorPreset.coerceIn(0, 4)) {
        0 -> Color(0xFF000000)
        1 -> Color(0xFF4F321C)
        2 -> Color(0xFFD7D7D8)
        3 -> Color(0xFFEAEAEA)
        else -> Color(0xFFFFFFFF)
    }

private tailrec fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}

private fun String.readerParagraphs(): List<String> =
    replace(Regex("""(?i)<br\s*/?>"""), "\n")
        .replace(Regex("""(?i)</p>"""), "\n\n")
        .replace(Regex("""<[^>]+>"""), "")
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .split(Regex("""\n{2,}"""))
        .map { paragraph -> paragraph.trim() }
        .filter(String::isNotBlank)
        .ifEmpty { listOf(trim()) }

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
