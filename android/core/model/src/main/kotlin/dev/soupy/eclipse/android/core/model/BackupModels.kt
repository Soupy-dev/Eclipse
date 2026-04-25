package dev.soupy.eclipse.android.core.model

import kotlin.math.roundToInt
import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonEncoder
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.jsonObject

@Serializable
data class BackupCollection(
    @Serializable(with = StringOrNumberAsStringSerializer::class)
    val id: String = "",
    val name: String = "",
    val items: List<JsonElement> = emptyList(),
    val description: String? = null,
)

@Serializable
data class BackupProgressEntry(
    val key: String,
    val positionMs: Long = 0,
    val durationMs: Long = 0,
    val updatedAt: Long = 0,
    val context: EpisodePlaybackContext? = null,
)

@Serializable
data class MovieProgressBackup(
    val id: Int,
    val title: String = "",
    @SerialName("posterURL") val posterUrl: String? = null,
    val currentTime: Double = 0.0,
    val totalDuration: Double = 0.0,
    val isWatched: Boolean = false,
    val lastUpdated: String? = null,
    val lastServiceId: String? = null,
    val lastHref: String? = null,
)

@Serializable
data class EpisodeProgressBackup(
    val id: String = "",
    val showId: Int,
    val seasonNumber: Int,
    val episodeNumber: Int,
    val anilistMediaId: Int? = null,
    val currentTime: Double = 0.0,
    val totalDuration: Double = 0.0,
    val isWatched: Boolean = false,
    val lastUpdated: String? = null,
    val lastServiceId: String? = null,
    val lastHref: String? = null,
)

@Serializable
data class ShowMetadataBackup(
    val showId: Int,
    val title: String,
    @SerialName("posterURL") val posterUrl: String? = null,
)

@Serializable
data class ProgressDataBackup(
    val movieProgress: List<MovieProgressBackup> = emptyList(),
    val episodeProgress: List<EpisodeProgressBackup> = emptyList(),
    val showMetadata: Map<String, ShowMetadataBackup> = emptyMap(),
)

@Serializable
data class BackupCatalog(
    val id: String = "",
    val title: String? = null,
    val type: String? = null,
    val manifestUrl: String? = null,
    val name: String? = null,
    val source: String? = null,
    val isEnabled: Boolean = true,
    val order: Int = 0,
    val displayStyle: String = "standard",
) {
    val displayName: String
        get() = name ?: title ?: id

    val resolvedSource: String
        get() = source ?: type ?: "Local"
}

@Serializable
data class ServiceBackup(
    @Serializable(with = StringOrNumberAsStringSerializer::class)
    val id: String = "",
    val name: String = "",
    val manifestUrl: String? = null,
    val scriptUrl: String? = null,
    val transportUrl: String? = null,
    val enabled: Boolean = true,
    val sortIndex: Long = 0,
    val sourceKind: String? = null,
    val configurationJson: String? = null,
    val url: String? = null,
    val jsonMetadata: String? = null,
    val jsScript: String? = null,
    val isActive: Boolean? = null,
) {
    val active: Boolean
        get() = isActive ?: enabled

    val resolvedName: String
        get() = name.ifBlank { id.ifBlank { url ?: scriptUrl ?: manifestUrl ?: "Service" } }

    val resolvedManifestUrl: String?
        get() = manifestUrl ?: url?.takeIf { jsScript.isNullOrBlank() }

    val resolvedScriptUrl: String?
        get() = scriptUrl ?: url?.takeIf { !jsScript.isNullOrBlank() }
}

@Serializable
data class StremioAddonBackup(
    @Serializable(with = StringOrNumberAsStringSerializer::class)
    val id: String = "",
    val name: String = "",
    val manifestUrl: String? = null,
    val transportUrl: String? = null,
    val enabled: Boolean = true,
    val sortIndex: Long = 0,
    val sourceKind: String? = null,
    val configuredURL: String? = null,
    @SerialName("manifestJSON") val manifestJson: String? = null,
    val isActive: Boolean? = null,
) {
    val active: Boolean
        get() = isActive ?: enabled

    val resolvedTransportUrl: String
        get() = transportUrl ?: configuredURL ?: manifestUrl ?: id

    val resolvedManifestId: String
        get() = id.ifBlank { resolvedTransportUrl }

    val resolvedName: String
        get() = name.ifBlank { resolvedManifestId }
}

@Serializable
data class ModuleBackup(
    @Serializable(with = StringOrNumberAsStringSerializer::class)
    val id: String = "",
    val name: String = "",
    val manifestUrl: String? = null,
    val enabled: Boolean = true,
    val moduleData: JsonElement = JsonObject(emptyMap()),
    val localPath: String? = null,
    val moduleurl: String? = null,
    val isActive: Boolean? = null,
) {
    val active: Boolean
        get() = isActive ?: enabled
}

@Serializable
data class TrackerAccountSnapshot(
    val service: String,
    val username: String = "",
    val accessToken: String = "",
    val refreshToken: String? = null,
    val expiresAt: String? = null,
    val userId: String = "",
    val isConnected: Boolean = true,
)

@Serializable
data class TrackerStateSnapshot(
    val accounts: List<TrackerAccountSnapshot> = emptyList(),
    val syncEnabled: Boolean = true,
    val lastSyncDate: String? = null,
    val provider: String? = null,
    val accessToken: String? = null,
    val refreshToken: String? = null,
    val userName: String? = null,
)

@Serializable
data class MangaProgressBackup(
    val readChapterNumbers: Set<String> = emptySet(),
    val lastReadChapter: String? = null,
    val lastReadDate: String? = null,
    val pagePositions: Map<String, Int> = emptyMap(),
    val title: String? = null,
    @SerialName("coverURL") val coverUrl: String? = null,
    val format: String? = null,
    val totalChapters: Int? = null,
    val moduleUUID: String? = null,
    val contentParams: String? = null,
    val isNovel: Boolean? = null,
)

@Serializable
data class BackupData(
    @Serializable(with = StringOrNumberAsStringSerializer::class)
    val version: String = "1.0",
    val createdDate: String? = null,
    val accentColor: String? = null,
    val tmdbLanguage: String = "en-US",
    val selectedAppearance: String = "system",
    val enableSubtitlesByDefault: Boolean = false,
    val defaultSubtitleLanguage: String = "eng",
    val enableVLCSubtitleEditMenu: Boolean = false,
    val preferredAnimeAudioLanguage: String = "jpn",
    @Serializable(with = InAppPlayerBackupSerializer::class)
    val inAppPlayer: InAppPlayer = InAppPlayer.VLC,
    @SerialName("playerChoice")
    @Serializable(with = InAppPlayerBackupSerializer::class)
    val legacyPlayerChoice: InAppPlayer? = null,
    val showScheduleTab: Boolean = true,
    val showLocalScheduleTime: Boolean = true,
    val holdSpeedPlayer: Double = 2.0,
    val externalPlayer: String = "none",
    val alwaysLandscape: Boolean = false,
    val aniSkipAutoSkip: Boolean = false,
    val skip85sEnabled: Boolean = false,
    val showNextEpisodeButton: Boolean = true,
    val nextEpisodeThreshold: Double = 0.90,
    val vlcHeaderProxyEnabled: Boolean = true,
    val subtitleForegroundColor: String? = null,
    val subtitleStrokeColor: String? = null,
    val subtitleStrokeWidth: Double = 1.0,
    val subtitleFontSize: Double = 30.0,
    val subtitleVerticalOffset: Double = -6.0,
    val showKanzen: Boolean = false,
    val kanzenAutoMode: Boolean = false,
    val kanzenAutoUpdateModules: Boolean = true,
    val autoUpdateServicesEnabled: Boolean = true,
    val githubReleaseAutoCheckEnabled: Boolean = true,
    val githubReleaseUpdateAvailable: Boolean = false,
    val githubReleaseLatestVersion: String = "",
    val githubReleaseURL: String = "",
    val seasonMenu: Boolean = false,
    val horizontalEpisodeList: Boolean = false,
    val mediaColumnsPortrait: Int = 3,
    val mediaColumnsLandscape: Int = 5,
    val readingMode: Int = 2,
    val readerFontSize: Double = 16.0,
    val readerFontFamily: String = "-apple-system",
    val readerFontWeight: String = "normal",
    val readerColorPreset: Int = 0,
    val readerTextAlignment: String = "left",
    val readerLineSpacing: Double = 1.6,
    val readerMargin: Double = 4.0,
    val autoClearCacheEnabled: Boolean = false,
    val autoClearCacheThresholdMB: Double = 500.0,
    val highQualityThreshold: Double = 0.9,
    @SerialName("filterHorror") val filterHorrorContent: Boolean = false,
    val selectedSimilarityAlgorithm: String = SimilarityAlgorithm.HYBRID.id,
    val collections: List<BackupCollection> = emptyList(),
    val progressData: JsonElement = JsonObject(emptyMap()),
    val trackerState: TrackerStateSnapshot = TrackerStateSnapshot(),
    val catalogs: List<BackupCatalog> = emptyList(),
    val services: List<ServiceBackup> = emptyList(),
    val stremioAddons: List<StremioAddonBackup>? = null,
    val mangaCollections: List<BackupCollection> = emptyList(),
    val mangaReadingProgress: Map<String, MangaProgressBackup> = emptyMap(),
    val mangaProgressData: JsonElement = JsonArray(emptyList()),
    val mangaCatalogs: List<BackupCatalog> = emptyList(),
    val kanzenModules: List<ModuleBackup> = emptyList(),
    val recommendationCache: JsonElement = JsonArray(emptyList()),
    @SerialName("userRatings") val userRatings: Map<String, Int> = emptyMap(),
) {
    val resolvedInAppPlayer: InAppPlayer
        get() = (legacyPlayerChoice ?: inAppPlayer).let { player ->
            if (player == InAppPlayer.MPV) InAppPlayer.EXTERNAL else player
        }

    fun nextEpisodeThresholdPercent(): Int {
        val percent = if (nextEpisodeThreshold <= 1.0) {
            nextEpisodeThreshold * 100.0
        } else {
            nextEpisodeThreshold
        }
        return percent.roundToInt().coerceIn(70, 98)
    }
}

data class BackupDocument(
    val payload: BackupData,
    val unknownKeys: Map<String, JsonElement> = emptyMap(),
) {
    fun encode(json: Json): String = json.encodeToString(JsonObject.serializer(), toJsonObject(json))

    fun toJsonObject(json: Json): JsonObject {
        val known = json.encodeToJsonElement(payload).jsonObject
        return JsonObject(known + unknownKeys)
    }

    companion object {
        fun decode(json: Json, raw: String): BackupDocument {
            val root = try {
                json.parseToJsonElement(raw).jsonObject
            } catch (error: IllegalStateException) {
                throw SerializationException("Backup root is not a JSON object", error)
            }
            val payload = json.decodeFromJsonElement<BackupData>(root)
            val knownKeys = BackupData.serializer().descriptor.elementNames()
            val unknownKeys = root.filterKeys { it !in knownKeys }
            return BackupDocument(payload = payload, unknownKeys = unknownKeys)
        }
    }
}

fun JsonElement.hasBackupData(): Boolean = when (this) {
    is JsonArray -> isNotEmpty()
    is JsonObject -> isNotEmpty()
    JsonNull -> false
    else -> true
}

object StringOrNumberAsStringSerializer : KSerializer<String> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("StringOrNumberAsString", PrimitiveKind.STRING)

    override fun deserialize(decoder: Decoder): String {
        val jsonDecoder = decoder as? JsonDecoder ?: return decoder.decodeString()
        return when (val element = jsonDecoder.decodeJsonElement()) {
            JsonNull -> ""
            is JsonPrimitive -> element.content
            else -> element.toString()
        }
    }

    override fun serialize(encoder: Encoder, value: String) {
        encoder.encodeString(value)
    }
}

object InAppPlayerBackupSerializer : KSerializer<InAppPlayer> {
    override val descriptor: SerialDescriptor =
        PrimitiveSerialDescriptor("InAppPlayerBackup", PrimitiveKind.STRING)

    override fun deserialize(decoder: Decoder): InAppPlayer {
        val raw = (decoder as? JsonDecoder)
            ?.decodeJsonElement()
            ?.let { element ->
                when (element) {
                    JsonNull -> ""
                    is JsonPrimitive -> element.content
                    else -> element.toString()
                }
            }
            ?: decoder.decodeString()

        return when (raw.trim().lowercase()) {
            "vlc" -> InAppPlayer.VLC
            "mpv" -> InAppPlayer.EXTERNAL
            "external", "outplayer", "outside" -> InAppPlayer.EXTERNAL
            "normal", "default", "media3", "exoplayer" -> InAppPlayer.NORMAL
            else -> InAppPlayer.VLC
        }
    }

    override fun serialize(encoder: Encoder, value: InAppPlayer) {
        val jsonEncoder = encoder as? JsonEncoder
        val encoded = when (value) {
            InAppPlayer.NORMAL -> "Normal"
            InAppPlayer.VLC -> "VLC"
            InAppPlayer.MPV -> "External"
            InAppPlayer.EXTERNAL -> "External"
        }
        if (jsonEncoder != null) {
            jsonEncoder.encodeJsonElement(JsonPrimitive(encoded))
        } else {
            encoder.encodeString(encoded)
        }
    }
}

private fun SerialDescriptor.elementNames(): Set<String> =
    (0 until elementsCount).map(::getElementName).toSet()
