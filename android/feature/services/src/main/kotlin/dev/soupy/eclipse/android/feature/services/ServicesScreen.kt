package dev.soupy.eclipse.android.feature.services

import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.Button
import androidx.compose.material3.FilterChip
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.unit.dp
import dev.soupy.eclipse.android.core.design.ErrorPanel
import dev.soupy.eclipse.android.core.design.GlassPanel
import dev.soupy.eclipse.android.core.design.HeroBackdrop
import dev.soupy.eclipse.android.core.design.LoadingPanel
import dev.soupy.eclipse.android.core.design.SectionHeading
import org.json.JSONObject

data class ServiceSourceRow(
    val id: String,
    val autoModeId: String,
    val name: String,
    val subtitle: String? = null,
    val configurationJson: String? = null,
    val configurationSummary: String? = null,
    val enabled: Boolean = true,
    val selectedInAutoMode: Boolean = false,
)

data class StremioAddonRow(
    val transportUrl: String,
    val autoModeId: String,
    val name: String,
    val subtitle: String? = null,
    val enabled: Boolean = true,
    val selectedInAutoMode: Boolean = false,
    val configured: Boolean = true,
    val configurable: Boolean = false,
    val configurationRequired: Boolean = false,
    val configurationUrl: String? = null,
    val types: List<String> = emptyList(),
    val resources: List<String> = emptyList(),
    val idPrefixes: List<String> = emptyList(),
    val catalogCount: Int = 0,
)

data class ServicesScreenState(
    val isLoading: Boolean = true,
    val isMutating: Boolean = false,
    val errorMessage: String? = null,
    val noticeMessage: String? = null,
    val autoModeEnabled: Boolean = true,
    val autoModeSelectedCount: Int = 0,
    val serviceCount: Int = 0,
    val addonCount: Int = 0,
    val services: List<ServiceSourceRow> = emptyList(),
    val stremioAddons: List<StremioAddonRow> = emptyList(),
)

@Composable
fun ServicesRoute(
    state: ServicesScreenState,
    onAutoModeChanged: (Boolean) -> Unit,
    onAutoModeSourceChanged: (String, Boolean) -> Unit,
    onAddService: (String, String, String?) -> Unit,
    onSaveServiceConfiguration: (String, String?) -> Unit,
    onImportAddon: (String) -> Unit,
    onToggleServiceEnabled: (String, String, Boolean) -> Unit,
    onToggleAddonEnabled: (String, String, Boolean) -> Unit,
    onMoveServiceUp: (String) -> Unit,
    onMoveServiceDown: (String) -> Unit,
    onMoveAddonUp: (String) -> Unit,
    onMoveAddonDown: (String) -> Unit,
    onRefreshAddon: (String) -> Unit,
    onRefreshAllAddons: () -> Unit,
    onRemoveService: (String, String) -> Unit,
    onRemoveAddon: (String, String) -> Unit,
) {
    var serviceName by rememberSaveable { mutableStateOf("") }
    var serviceScriptUrl by rememberSaveable { mutableStateOf("") }
    var serviceManifestUrl by rememberSaveable { mutableStateOf("") }
    var addonTransportUrl by rememberSaveable { mutableStateOf("") }
    var activeConfigurationUrl by rememberSaveable { mutableStateOf<String?>(null) }
    var activeServiceConfigurationId by rememberSaveable { mutableStateOf<String?>(null) }
    val uriHandler = LocalUriHandler.current
    val activeServiceConfiguration = state.services.firstOrNull { service -> service.id == activeServiceConfigurationId }

    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding(),
        verticalArrangement = Arrangement.spacedBy(18.dp),
        contentPadding = PaddingValues(horizontal = 20.dp, vertical = 18.dp),
    ) {
        item {
            HeroBackdrop(
                title = "Services",
                subtitle = "Runtime sources and addons",
                imageUrl = null,
                supportingText = "Android now has real source management here: Room-backed services, Stremio addon import, ordering, and Auto Mode source selection. Auto Mode may not always be accurate.",
            )
        }

        if (state.isLoading) {
            item {
                LoadingPanel(
                    title = "Loading sources",
                    message = "Hydrating Android-side services, addons, and Auto Mode selection.",
                )
            }
        }

        state.errorMessage?.let { error ->
            item {
                ErrorPanel(
                    title = "Services hit a snag",
                    message = error,
                )
            }
        }

        state.noticeMessage?.let { notice ->
            item {
                GlassPanel {
                    Text(
                        text = notice,
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                }
            }
        }

        activeConfigurationUrl?.let { configurationUrl ->
            item {
                StremioConfigurationPanel(
                    configurationUrl = configurationUrl,
                    onOpenExternal = { uriHandler.openUri(configurationUrl) },
                    onClose = { activeConfigurationUrl = null },
                )
            }
        }

        activeServiceConfiguration?.let { service ->
            item {
                CustomServiceConfigurationPanel(
                    service = service,
                    onSave = { configurationJson ->
                        onSaveServiceConfiguration(service.id, configurationJson)
                        activeServiceConfigurationId = null
                    },
                    onClose = { activeServiceConfigurationId = null },
                )
            }
        }

        item {
            SectionHeading(
                title = "Auto Mode",
                subtitle = "Enabled for ${state.autoModeSelectedCount} selected source${if (state.autoModeSelectedCount == 1) "" else "s"}.",
            )
        }

        item {
            GlassPanel {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    Column(
                        modifier = Modifier.weight(1f),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text(
                            text = "Use Auto Mode",
                            style = MaterialTheme.typography.titleLarge,
                            color = MaterialTheme.colorScheme.onSurface,
                        )
                        Text(
                            text = "Let Eclipse pick from the sources you marked below. This may not always be accurate, especially until parity search heuristics and stream scoring are fully ported.",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.75f),
                        )
                    }
                    Switch(
                        checked = state.autoModeEnabled,
                        onCheckedChange = onAutoModeChanged,
                    )
                }
            }
        }

        item {
            SectionHeading(
                title = "Add Sources",
                subtitle = "Manual service records and Stremio transport URLs are both persisted now.",
            )
        }

        item {
            GlassPanel {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(
                        text = "Custom Service",
                        style = MaterialTheme.typography.titleLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    OutlinedTextField(
                        value = serviceName,
                        onValueChange = { serviceName = it },
                        modifier = Modifier.fillMaxWidth(),
                        label = { Text("Display name") },
                        singleLine = true,
                    )
                    OutlinedTextField(
                        value = serviceScriptUrl,
                        onValueChange = { serviceScriptUrl = it },
                        modifier = Modifier.fillMaxWidth(),
                        label = { Text("Script URL") },
                        singleLine = true,
                    )
                    OutlinedTextField(
                        value = serviceManifestUrl,
                        onValueChange = { serviceManifestUrl = it },
                        modifier = Modifier.fillMaxWidth(),
                        label = { Text("Manifest URL (optional)") },
                        singleLine = true,
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Button(
                            onClick = {
                                onAddService(
                                    serviceName,
                                    serviceScriptUrl,
                                    serviceManifestUrl.takeIf { it.isNotBlank() },
                                )
                                serviceName = ""
                                serviceScriptUrl = ""
                                serviceManifestUrl = ""
                            },
                            enabled = !state.isMutating && serviceName.isNotBlank() && serviceScriptUrl.isNotBlank(),
                        ) {
                            Text("Save Service")
                        }
                        Text(
                            text = "Use this for JS-backed provider definitions until the manifest/runtime bridge is fully wired.",
                            modifier = Modifier.weight(1f),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f),
                        )
                    }
                }
            }
        }

        item {
            GlassPanel {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(
                        text = "Stremio Addon",
                        style = MaterialTheme.typography.titleLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    OutlinedTextField(
                        value = addonTransportUrl,
                        onValueChange = { addonTransportUrl = it },
                        modifier = Modifier.fillMaxWidth(),
                        label = { Text("Transport or manifest URL") },
                        singleLine = true,
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        Button(
                            onClick = {
                                onImportAddon(addonTransportUrl)
                                addonTransportUrl = ""
                            },
                            enabled = !state.isMutating && addonTransportUrl.isNotBlank(),
                        ) {
                            Text("Import Addon")
                        }
                        Text(
                            text = "The Android app now fetches and persists the addon manifest immediately so this screen can reflect real Stremio state.",
                            modifier = Modifier.weight(1f),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f),
                        )
                    }
                }
            }
        }

        item {
            SectionHeading(
                title = "Services (${state.serviceCount})",
                subtitle = "Enable, order, and include them in Auto Mode.",
            )
        }

        if (state.services.isEmpty()) {
            item {
                EmptyStatePanel(
                    title = "No custom services yet",
                    message = "Add a JS service above and it will persist here. Ordering and Auto Mode selection already work on Android for these saved entries.",
                )
            }
        } else {
            items(state.services, key = { it.id }) { service ->
                ServiceCard(
                    title = service.name,
                    subtitle = listOfNotNull(
                        service.subtitle,
                        service.configurationSummary,
                    ).joinToString("\n").ifBlank { null },
                    enabled = service.enabled,
                    selectedInAutoMode = service.selectedInAutoMode,
                    autoModeEnabled = state.autoModeEnabled,
                    onEnabledChanged = { enabled ->
                        onToggleServiceEnabled(service.id, service.autoModeId, enabled)
                    },
                    onAutoModeChanged = { enabled ->
                        onAutoModeSourceChanged(service.autoModeId, enabled)
                    },
                    onMoveUp = { onMoveServiceUp(service.id) },
                    onMoveDown = { onMoveServiceDown(service.id) },
                    onConfigure = { activeServiceConfigurationId = service.id },
                    onRemove = { onRemoveService(service.id, service.autoModeId) },
                )
            }
        }

        item {
            SectionHeading(
                title = "Stremio Addons (${state.addonCount})",
                subtitle = "Imported addon manifests, sorted and ready for later stream resolution.",
            )
        }

        item {
            OutlinedButton(
                onClick = onRefreshAllAddons,
                enabled = state.stremioAddons.isNotEmpty() && !state.isMutating,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Update All Addons")
            }
        }

        if (state.stremioAddons.isEmpty()) {
            item {
                EmptyStatePanel(
                    title = "No addons imported yet",
                    message = "Paste a Torrentio or other Stremio transport URL above. The manifest will be fetched and stored on-device.",
                )
            }
        } else {
            items(state.stremioAddons, key = { it.transportUrl }) { addon ->
                ServiceCard(
                    title = addon.name,
                    subtitle = listOfNotNull(
                        addon.subtitle,
                        addon.types.takeIf { it.isNotEmpty() }?.joinToString(prefix = "Types: "),
                        addon.resources.takeIf { it.isNotEmpty() }?.joinToString(prefix = "Resources: "),
                        addon.idPrefixes.takeIf { it.isNotEmpty() }?.take(5)?.joinToString(prefix = "IDs: "),
                        addon.catalogCount.takeIf { it > 0 }?.let { "$it catalog${if (it == 1) "" else "s"}" },
                        addon.configurationUrl?.let { "Configure: $it" },
                        when {
                            addon.configurationRequired -> "Configuration required before streams are usable"
                            addon.configurable -> "Configurable addon"
                            addon.configured -> "Configured import"
                            else -> null
                        },
                    ).joinToString("\n").ifBlank { null },
                    enabled = addon.enabled,
                    selectedInAutoMode = addon.selectedInAutoMode,
                    autoModeEnabled = state.autoModeEnabled,
                    onEnabledChanged = { enabled ->
                        onToggleAddonEnabled(addon.transportUrl, addon.autoModeId, enabled)
                    },
                    onAutoModeChanged = { enabled ->
                        onAutoModeSourceChanged(addon.autoModeId, enabled)
                    },
                    onMoveUp = { onMoveAddonUp(addon.transportUrl) },
                    onMoveDown = { onMoveAddonDown(addon.transportUrl) },
                    onConfigure = addon.configurationUrl?.let { configurationUrl ->
                        { activeConfigurationUrl = configurationUrl }
                    },
                    onRefresh = { onRefreshAddon(addon.transportUrl) },
                    onRemove = { onRemoveAddon(addon.transportUrl, addon.autoModeId) },
                )
            }
        }
    }
}

@Composable
private fun StremioConfigurationPanel(
    configurationUrl: String,
    onOpenExternal: () -> Unit,
    onClose: () -> Unit,
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
                        text = "Addon Configuration",
                        style = MaterialTheme.typography.titleLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Text(
                        text = configurationUrl,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.tertiary,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                OutlinedButton(onClick = onClose) {
                    Text("Close")
                }
            }
            AndroidView(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(520.dp),
                factory = { context ->
                    WebView(context).apply {
                        tag = configurationUrl
                        webViewClient = WebViewClient()
                        settings.javaScriptEnabled = true
                        settings.domStorageEnabled = true
                        loadUrl(configurationUrl)
                    }
                },
                update = { webView ->
                    if (webView.tag != configurationUrl) {
                        webView.tag = configurationUrl
                        webView.loadUrl(configurationUrl)
                    }
                },
            )
            OutlinedButton(
                onClick = onOpenExternal,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text("Open Browser")
            }
        }
    }
}

private data class ConfigFormRow(
    val key: String = "",
    val value: String = "",
)

@Composable
private fun CustomServiceConfigurationPanel(
    service: ServiceSourceRow,
    onSave: (String?) -> Unit,
    onClose: () -> Unit,
) {
    var rows by remember(service.id, service.configurationJson) {
        mutableStateOf(service.configurationJson.toConfigRows())
    }
    val hasRows = rows.any { row -> row.key.isNotBlank() || row.value.isNotBlank() }

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
                        text = "Provider Configuration",
                        style = MaterialTheme.typography.titleLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Text(
                        text = listOfNotNull(service.name, service.configurationSummary).joinToString(" | "),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.72f),
                    )
                }
                OutlinedButton(onClick = onClose) {
                    Text("Close")
                }
            }

            rows.forEachIndexed { index, row ->
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    OutlinedTextField(
                        value = row.key,
                        onValueChange = { value ->
                            rows = rows.updated(index, row.copy(key = value))
                        },
                        modifier = Modifier.weight(0.42f),
                        label = { Text("Key") },
                        singleLine = true,
                    )
                    OutlinedTextField(
                        value = row.value,
                        onValueChange = { value ->
                            rows = rows.updated(index, row.copy(value = value))
                        },
                        modifier = Modifier.weight(0.58f),
                        label = { Text("Value") },
                        singleLine = true,
                    )
                }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedButton(
                    onClick = { rows = rows + ConfigFormRow() },
                    enabled = rows.size < 24,
                ) {
                    Text("Add Setting")
                }
                OutlinedButton(
                    onClick = { rows = listOf(ConfigFormRow()) },
                    enabled = hasRows,
                ) {
                    Text("Clear")
                }
                Button(
                    onClick = { onSave(rows.toConfigurationJson()) },
                ) {
                    Text("Save")
                }
            }
        }
    }
}

@Composable
private fun ServiceCard(
    title: String,
    subtitle: String?,
    enabled: Boolean,
    selectedInAutoMode: Boolean,
    autoModeEnabled: Boolean,
    onEnabledChanged: (Boolean) -> Unit,
    onAutoModeChanged: (Boolean) -> Unit,
    onMoveUp: () -> Unit,
    onMoveDown: () -> Unit,
    onConfigure: (() -> Unit)? = null,
    onRefresh: (() -> Unit)? = null,
    onRemove: () -> Unit,
) {
    GlassPanel {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        text = title,
                        style = MaterialTheme.typography.titleLarge,
                        color = MaterialTheme.colorScheme.onSurface,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                    subtitle?.let {
                        Text(
                            text = it,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.72f),
                            maxLines = 4,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
                Switch(
                    checked = enabled,
                    onCheckedChange = onEnabledChanged,
                )
            }

            FilterChip(
                selected = selectedInAutoMode,
                onClick = { onAutoModeChanged(!selectedInAutoMode) },
                enabled = autoModeEnabled && enabled,
                label = {
                    Text(if (selectedInAutoMode) "Included in Auto Mode" else "Add to Auto Mode")
                },
            )

            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedButton(onClick = onMoveUp) {
                    Text("Up")
                }
                OutlinedButton(onClick = onMoveDown) {
                    Text("Down")
                }
                onRefresh?.let { refresh ->
                    OutlinedButton(onClick = refresh) {
                        Text("Refresh")
                    }
                }
                onConfigure?.let { configure ->
                    Button(onClick = configure) {
                        Text("Configure")
                    }
                }
                OutlinedButton(onClick = onRemove) {
                    Text("Remove")
                }
            }
        }
    }
}

private fun String?.toConfigRows(): List<ConfigFormRow> {
    val raw = this?.takeIf { it.isNotBlank() } ?: return listOf(ConfigFormRow())
    val parsed = runCatching {
        val json = JSONObject(raw)
        val keys = json.keys()
        buildList {
            while (keys.hasNext()) {
                val key = keys.next()
                val value = json.opt(key)
                    ?.takeUnless { it == JSONObject.NULL }
                    ?.toString()
                    .orEmpty()
                add(ConfigFormRow(key = key, value = value))
            }
        }
    }.getOrDefault(emptyList())
    return parsed.ifEmpty { listOf(ConfigFormRow()) }
}

private fun List<ConfigFormRow>.updated(
    index: Int,
    row: ConfigFormRow,
): List<ConfigFormRow> = mapIndexed { currentIndex, currentRow ->
    if (currentIndex == index) row else currentRow
}

private fun List<ConfigFormRow>.toConfigurationJson(): String? {
    val json = JSONObject()
    filter { row -> row.key.isNotBlank() }
        .forEach { row ->
            json.put(row.key.trim(), row.value.typedJsonValue())
        }
    return json.takeIf { it.length() > 0 }?.toString()
}

private fun String.typedJsonValue(): Any {
    val clean = trim()
    return when {
        clean.equals("true", ignoreCase = true) -> true
        clean.equals("false", ignoreCase = true) -> false
        clean.toLongOrNull() != null -> clean.toLong()
        clean.toDoubleOrNull() != null -> clean.toDouble()
        else -> this
    }
}

@Composable
private fun EmptyStatePanel(
    title: String,
    message: String,
) {
    GlassPanel {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = message,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.76f),
            )
        }
    }
}
