package dev.soupy.eclipse.android.core.player

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.pm.ActivityInfo
import android.graphics.Color
import android.graphics.Typeface
import android.net.Uri
import android.os.Bundle
import android.provider.Browser
import android.util.TypedValue
import android.view.GestureDetector
import android.view.MotionEvent
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.unit.dp
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.Player
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.CaptionStyleCompat
import androidx.media3.ui.PlayerView
import dev.soupy.eclipse.android.core.design.GlassPanel
import dev.soupy.eclipse.android.core.model.InAppPlayer
import dev.soupy.eclipse.android.core.model.PlaybackSettingsSnapshot
import dev.soupy.eclipse.android.core.model.PlayerSource
import dev.soupy.eclipse.android.core.model.SkipSegment
import dev.soupy.eclipse.android.core.model.SubtitleTrack
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer
import org.videolan.libvlc.util.VLCVideoLayout

private const val DoubleTapSeekDeltaMs = 10_000L

data class PlaybackProgressSnapshot(
    val positionMs: Long,
    val durationMs: Long,
    val isFinished: Boolean = false,
)

@Composable
fun EclipsePlayerSurface(
    modifier: Modifier = Modifier,
    source: PlayerSource? = null,
    preferredPlayer: InAppPlayer = InAppPlayer.NORMAL,
    settings: PlaybackSettingsSnapshot = PlaybackSettingsSnapshot(),
    skipSegments: List<SkipSegment> = emptyList(),
    nextEpisodeLabel: String? = null,
    onNextEpisode: () -> Unit = {},
    onProgress: (PlaybackProgressSnapshot) -> Unit = {},
) {
    if (source == null) {
        GlassPanel(
            modifier = modifier
                .fillMaxWidth()
                .aspectRatio(16 / 9f),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    text = "Ready to play",
                    style = MaterialTheme.typography.titleLarge,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Text(
                    text = "Media3/ExoPlayer is wired here for direct playback, VLC can use the embedded LibVLC backend, and mpv/custom external players can receive direct Android handoff intents.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.8f),
                )
            }
        }
        return
    }

    val context = LocalContext.current
    val onProgressState = rememberUpdatedState(onProgress)
    val settingsState = rememberUpdatedState(settings)
    val skipSegmentsState = rememberUpdatedState(skipSegments)
    var progressPercent by remember(source.uri) { mutableStateOf(0f) }
    var currentPositionSeconds by remember(source.uri) { mutableStateOf(0.0) }
    LockLandscapeWhenRequested(settings.alwaysLandscape)

    if (source.uri.isTorrentLikeUri()) {
        GlassPanel(
            modifier = modifier
                .fillMaxWidth()
                .aspectRatio(16 / 9f),
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    text = "Source Blocked",
                    style = MaterialTheme.typography.titleLarge,
                    color = MaterialTheme.colorScheme.error,
                )
                Text(
                    text = "Android only accepts direct HTTP(S) media streams. Torrent, magnet, BTIH, and .torrent sources are rejected before playback.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.78f),
                )
            }
        }
        return
    }

    val nativePlayerPackage = preferredPlayer.nativePackageName()
    if (preferredPlayer == InAppPlayer.VLC) {
        EmbeddedVlcPlayerPanel(
            source = source,
            modifier = modifier,
            onProgress = onProgressState.value,
        )
        return
    }

    if (preferredPlayer == InAppPlayer.EXTERNAL || nativePlayerPackage != null) {
        ExternalPlayerPanel(
            source = source,
            playerLabel = preferredPlayer.externalPanelLabel(),
            externalPlayer = nativePlayerPackage ?: settings.externalPlayer,
            modifier = modifier,
        )
        return
    }

    val mediaItem = remember(source, settings.defaultSubtitleLanguage, settings.enableSubtitlesByDefault) {
        source.toMediaItem(
            defaultSubtitleLanguage = settings.defaultSubtitleLanguage,
            enableSubtitlesByDefault = settings.enableSubtitlesByDefault,
        )
    }

    val exoPlayer = remember(mediaItem, source.headers) {
        val httpFactory = DefaultHttpDataSource.Factory()
            .setDefaultRequestProperties(source.headers)
        val mediaSourceFactory = DefaultMediaSourceFactory(
            DefaultDataSource.Factory(context, httpFactory),
        )

        ExoPlayer.Builder(context)
            .setMediaSourceFactory(mediaSourceFactory)
            .build()
            .apply {
                setMediaItem(mediaItem)
                prepare()
                playWhenReady = false
            }
    }

    LaunchedEffect(
        exoPlayer,
        settings.enableSubtitlesByDefault,
        settings.defaultSubtitleLanguage,
        settings.preferredAnimeAudioLanguage,
    ) {
        val textLanguage = settings.defaultSubtitleLanguage.normalizedLanguageCode()
        val audioLanguage = settings.preferredAnimeAudioLanguage.normalizedLanguageCode()
        val parameters = exoPlayer.trackSelectionParameters
            .buildUpon()
            .setPreferredAudioLanguage(audioLanguage)
            .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, !settings.enableSubtitlesByDefault)
            .setSelectUndeterminedTextLanguage(settings.enableSubtitlesByDefault)
            .apply {
                if (settings.enableSubtitlesByDefault) {
                    setPreferredTextLanguage(textLanguage)
                }
            }
            .build()
        exoPlayer.trackSelectionParameters = parameters
    }

    fun progressSnapshot(forceFinished: Boolean = false): PlaybackProgressSnapshot? {
        val durationMs = exoPlayer.duration
        if (durationMs <= 0L || durationMs == C.TIME_UNSET) {
            return null
        }

        val positionMs = exoPlayer.currentPosition
            .coerceAtLeast(0L)
            .coerceAtMost(durationMs)
        progressPercent = if (forceFinished) {
            1f
        } else {
            (positionMs.toFloat() / durationMs.toFloat()).coerceIn(0f, 1f)
        }
        currentPositionSeconds = positionMs / 1_000.0
        return PlaybackProgressSnapshot(
            positionMs = positionMs,
            durationMs = durationMs,
            isFinished = forceFinished || positionMs >= durationMs - 1_500L,
        )
    }

    fun emitProgressSnapshot(forceFinished: Boolean = false) {
        progressSnapshot(forceFinished)?.let(onProgressState.value)
    }

    LaunchedEffect(exoPlayer) {
        var secondsSinceProgressEmit = 0
        while (isActive) {
            delay(1_000L)
            val snapshot = progressSnapshot() ?: continue
            if (!exoPlayer.isPlaying) {
                secondsSinceProgressEmit = 0
                continue
            }

            val currentSettings = settingsState.value
            val activeSegment = if (currentSettings.aniSkipAutoSkip) {
                skipSegmentsState.value.activeAt(snapshot.positionMs / 1_000.0)
            } else {
                null
            }
            if (activeSegment != null) {
                exoPlayer.seekTo((activeSegment.endTime * 1_000.0).toLong())
                emitProgressSnapshot()
                secondsSinceProgressEmit = 0
                continue
            }

            secondsSinceProgressEmit += 1
            if (secondsSinceProgressEmit >= 15) {
                onProgressState.value(snapshot)
                secondsSinceProgressEmit = 0
            }
        }
    }

    DisposableEffect(exoPlayer) {
        val listener = object : Player.Listener {
            override fun onIsPlayingChanged(isPlaying: Boolean) {
                if (!isPlaying) {
                    emitProgressSnapshot()
                }
            }

            override fun onPlaybackStateChanged(playbackState: Int) {
                if (playbackState == Player.STATE_ENDED) {
                    emitProgressSnapshot(forceFinished = true)
                }
            }
        }
        exoPlayer.addListener(listener)
        onDispose {
            emitProgressSnapshot()
            exoPlayer.removeListener(listener)
            exoPlayer.release()
        }
    }

    Column(
        modifier = modifier
            .fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        PlaybackShortcutRow(
            exoPlayer = exoPlayer,
            settings = settings,
            progressPercent = progressPercent,
            currentPositionSeconds = currentPositionSeconds,
            skipSegments = skipSegments,
            nextEpisodeLabel = nextEpisodeLabel,
            onNextEpisode = onNextEpisode,
            onProgressChanged = { emitProgressSnapshot() },
        )

        AndroidView(
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(16 / 9f),
            factory = { viewContext ->
                PlayerView(viewContext).apply {
                    player = exoPlayer
                    useController = true
                    applySubtitleStyle(settings)
                    installDoubleTapSeek(
                        exoPlayer = exoPlayer,
                        onSeek = { emitProgressSnapshot() },
                    )
                }
            },
            update = { playerView ->
                playerView.player = exoPlayer
                playerView.applySubtitleStyle(settings)
                playerView.installDoubleTapSeek(
                    exoPlayer = exoPlayer,
                    onSeek = { emitProgressSnapshot() },
                )
            },
        )
    }
}

@Composable
private fun LockLandscapeWhenRequested(alwaysLandscape: Boolean) {
    val activity = LocalContext.current.findActivity()
    DisposableEffect(activity, alwaysLandscape) {
        val previousOrientation = activity?.requestedOrientation
        if (activity != null && alwaysLandscape) {
            activity.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        }
        onDispose {
            if (activity != null && previousOrientation != null) {
                activity.requestedOrientation = previousOrientation
            }
        }
    }
}

@Composable
private fun PlaybackShortcutRow(
    exoPlayer: ExoPlayer,
    settings: PlaybackSettingsSnapshot,
    progressPercent: Float,
    currentPositionSeconds: Double,
    skipSegments: List<SkipSegment>,
    nextEpisodeLabel: String?,
    onNextEpisode: () -> Unit,
    onProgressChanged: () -> Unit,
) {
    val showNextEpisode = settings.showNextEpisodeButton &&
        nextEpisodeLabel != null &&
        progressPercent * 100f >= settings.nextEpisodeThreshold
    val manualSkipSegment = skipSegments.nextManualSkip(currentPositionSeconds)

    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.End,
    ) {
        if (manualSkipSegment != null) {
            Button(
                onClick = {
                    exoPlayer.seekTo((manualSkipSegment.endTime * 1_000.0).toLong())
                    onProgressChanged()
                },
                modifier = Modifier.padding(end = 10.dp),
            ) {
                Text(manualSkipSegment.type.displayLabel)
            }
        }

        if (showNextEpisode) {
            Button(onClick = onNextEpisode) {
                Text(nextEpisodeLabel)
            }
        }

        if (settings.holdSpeed > 1.0) {
            HoldSpeedSurface(
                speed = settings.holdSpeed,
                onHoldStart = { exoPlayer.setPlaybackSpeed(settings.holdSpeed.toFloat()) },
                onHoldEnd = { exoPlayer.setPlaybackSpeed(1f) },
            )
        }

        if (settings.skip85sEnabled && (settings.skip85sAlwaysVisible || manualSkipSegment == null)) {
            Button(
                onClick = {
                    exoPlayer.seekBy(85_000L)
                    onProgressChanged()
                },
                modifier = Modifier.padding(start = 10.dp),
            ) {
                Text("Skip 85s")
            }
        }
    }
}

private fun List<SkipSegment>.activeAt(positionSeconds: Double): SkipSegment? =
    firstOrNull { segment ->
        positionSeconds >= segment.startTime && positionSeconds < segment.endTime
    }

private fun List<SkipSegment>.nextManualSkip(positionSeconds: Double): SkipSegment? =
    firstOrNull { segment ->
        positionSeconds >= segment.startTime - 8.0 && positionSeconds < segment.endTime
    }

@Composable
private fun HoldSpeedSurface(
    speed: Double,
    onHoldStart: () -> Unit,
    onHoldEnd: () -> Unit,
) {
    Surface(
        modifier = Modifier.pointerInput(speed) {
            detectTapGestures(
                onPress = {
                    onHoldStart()
                    try {
                        tryAwaitRelease()
                    } finally {
                        onHoldEnd()
                    }
                },
            )
        },
        shape = MaterialTheme.shapes.small,
        color = MaterialTheme.colorScheme.primary,
        contentColor = MaterialTheme.colorScheme.onPrimary,
    ) {
        Text(
            text = "Hold %.2fx".format(speed),
            style = MaterialTheme.typography.labelLarge,
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
        )
    }
}

@SuppressLint("ClickableViewAccessibility")
private fun PlayerView.installDoubleTapSeek(
    exoPlayer: ExoPlayer,
    onSeek: () -> Unit,
) {
    val detector = GestureDetector(
        context,
        object : GestureDetector.SimpleOnGestureListener() {
            override fun onDoubleTap(e: MotionEvent): Boolean {
                val viewWidth = width.takeIf { it > 0 } ?: return false
                val deltaMs = if (e.x < viewWidth / 2f) {
                    -DoubleTapSeekDeltaMs
                } else {
                    DoubleTapSeekDeltaMs
                }
                exoPlayer.seekBy(deltaMs)
                onSeek()
                return true
            }
        },
    )

    setOnTouchListener { _, event ->
        detector.onTouchEvent(event)
        false
    }
}

private fun ExoPlayer.seekBy(deltaMs: Long) {
    val currentPosition = currentPosition.coerceAtLeast(0L)
    val duration = duration.takeIf { it > 0L && it != C.TIME_UNSET }
    val targetPosition = duration?.let { durationMs ->
        (currentPosition + deltaMs).coerceIn(0L, (durationMs - 1_000L).coerceAtLeast(0L))
    } ?: (currentPosition + deltaMs).coerceAtLeast(0L)
    seekTo(targetPosition)
}

@Composable
private fun EmbeddedVlcPlayerPanel(
    source: PlayerSource,
    modifier: Modifier = Modifier,
    onProgress: (PlaybackProgressSnapshot) -> Unit,
) {
    var session by remember(source.uri) { mutableStateOf<VlcSession?>(null) }
    var playbackError by remember(source.uri) { mutableStateOf<String?>(null) }

    DisposableEffect(source.uri) {
        onDispose {
            session?.release()
            session = null
        }
    }

    LaunchedEffect(session) {
        while (isActive) {
            val player = session?.mediaPlayer
            if (player != null) {
                val positionMs = player.time.coerceAtLeast(0L)
                val durationMs = player.length.coerceAtLeast(0L)
                onProgress(
                    PlaybackProgressSnapshot(
                        positionMs = positionMs,
                        durationMs = durationMs,
                        isFinished = durationMs > 0L && positionMs >= (durationMs - 1_000L).coerceAtLeast(0L),
                    ),
                )
            }
            delay(1_000L)
        }
    }

    Surface(
        modifier = modifier
            .fillMaxWidth()
            .aspectRatio(16 / 9f),
        color = androidx.compose.ui.graphics.Color.Black,
    ) {
        key(source.uri) {
            AndroidView(
                modifier = Modifier.fillMaxSize(),
                factory = { context ->
                    VLCVideoLayout(context).also { layout ->
                        runCatching {
                            VlcSession.create(
                                context = context,
                                layout = layout,
                                source = source,
                            )
                        }.onSuccess { created ->
                            session?.release()
                            session = created
                            playbackError = null
                        }.onFailure { error ->
                            playbackError = error.message ?: "Embedded VLC playback failed."
                        }
                    }
                },
            )
        }
        playbackError?.let { error ->
            GlassPanel(
                modifier = Modifier.padding(16.dp),
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        text = "Embedded VLC unavailable",
                        style = MaterialTheme.typography.titleLarge,
                        color = MaterialTheme.colorScheme.error,
                    )
                    Text(
                        text = error,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.78f),
                    )
                }
            }
        }
    }
}

private class VlcSession(
    val mediaPlayer: MediaPlayer,
    private val libVlc: LibVLC,
) {
    fun release() {
        runCatching { mediaPlayer.stop() }
        runCatching { mediaPlayer.detachViews() }
        runCatching { mediaPlayer.release() }
        runCatching { libVlc.release() }
    }

    companion object {
        fun create(
            context: Context,
            layout: VLCVideoLayout,
            source: PlayerSource,
        ): VlcSession {
            val libVlc = LibVLC(
                context.applicationContext,
                arrayListOf(
                    "--network-caching=1500",
                    "--http-reconnect",
                ),
            )
            val mediaPlayer = MediaPlayer(libVlc)
            mediaPlayer.attachViews(layout, null, false, false)
            val media = Media(libVlc, Uri.parse(source.uri))
            source.headers.forEach { (name, value) ->
                media.addOption(":http-header=$name: $value")
            }
            mediaPlayer.media = media
            media.release()
            mediaPlayer.play()
            return VlcSession(mediaPlayer, libVlc)
        }
    }
}

@Composable
private fun ExternalPlayerPanel(
    source: PlayerSource,
    playerLabel: String,
    externalPlayer: String,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    var launchError by remember(source.uri) { mutableStateOf<String?>(null) }

    GlassPanel(
        modifier = modifier
            .fillMaxWidth()
            .aspectRatio(16 / 9f),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(
                text = source.title ?: playerLabel,
                style = MaterialTheme.typography.titleLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = "Open this direct stream with $playerLabel.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.78f),
            )
            Button(
                onClick = {
                    launchError = runCatching {
                        context.startActivity(source.externalPlayerIntent(externalPlayer))
                    }.exceptionOrNull()?.let { error ->
                        if (error is ActivityNotFoundException) {
                            "$playerLabel is not installed or cannot open this stream."
                        } else {
                            error.message ?: "$playerLabel launch failed."
                        }
                    }
                },
            ) {
                Text("Open $playerLabel")
            }
            launchError?.let {
                Text(
                    text = it,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error,
                )
            }
        }
    }
}

private fun PlayerSource.externalPlayerIntent(externalPlayer: String): Intent {
    val streamUri = Uri.parse(uri)
    val preferredPackage = externalPlayer.trim().takeUnless {
        it.isBlank() || it.equals("none", ignoreCase = true)
    }
    val openIntent = Intent(Intent.ACTION_VIEW).apply {
        setDataAndType(streamUri, mimeType ?: "video/*")
        putExtra(Intent.EXTRA_TITLE, title)
        preferredPackage?.let(::setPackage)
        if (headers.isNotEmpty()) {
            putExtra(
                Browser.EXTRA_HEADERS,
                Bundle().apply {
                    headers.forEach { (name, value) -> putString(name, value) }
                },
            )
        }
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    return Intent.createChooser(openIntent, title ?: "Open stream").apply {
        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }
}

private fun InAppPlayer.nativePackageName(): String? = when (this) {
    InAppPlayer.VLC -> "org.videolan.vlc"
    InAppPlayer.MPV -> "is.xyz.mpv"
    InAppPlayer.NORMAL,
    InAppPlayer.EXTERNAL -> null
}

private fun InAppPlayer.externalPanelLabel(): String = when (this) {
    InAppPlayer.VLC -> "VLC"
    InAppPlayer.MPV -> "mpv"
    InAppPlayer.EXTERNAL -> "External Player"
    InAppPlayer.NORMAL -> "Normal Player"
}

private fun PlayerSource.toMediaItem(
    defaultSubtitleLanguage: String,
    enableSubtitlesByDefault: Boolean,
): MediaItem {
    val subtitleConfigurations = subtitles.mapNotNull { subtitle ->
        subtitle.toSubtitleConfiguration(
            defaultSubtitleLanguage = defaultSubtitleLanguage,
            enableSubtitlesByDefault = enableSubtitlesByDefault,
        )
    }

    return MediaItem.Builder()
        .setUri(uri)
        .apply {
            mimeType?.let(::setMimeType)
            if (subtitleConfigurations.isNotEmpty()) {
                setSubtitleConfigurations(subtitleConfigurations)
            }
        }
        .build()
}

private fun SubtitleTrack.toSubtitleConfiguration(
    defaultSubtitleLanguage: String,
    enableSubtitlesByDefault: Boolean,
): MediaItem.SubtitleConfiguration? {
    val subtitleUri = uri?.takeIf { it.isNotBlank() } ?: return null
    val normalizedLanguage = language?.normalizedLanguageCode()
    val defaultLanguage = defaultSubtitleLanguage.normalizedLanguageCode()
    val selectionFlags = if (
        isDefault ||
        enableSubtitlesByDefault && normalizedLanguage != null && normalizedLanguage.matchesLanguage(defaultLanguage)
    ) {
        C.SELECTION_FLAG_DEFAULT
    } else {
        0
    }

    return MediaItem.SubtitleConfiguration.Builder(Uri.parse(subtitleUri))
        .setMimeType(format.toSubtitleMimeType())
        .setLanguage(normalizedLanguage)
        .setLabel(label)
        .setId(id)
        .setSelectionFlags(selectionFlags)
        .build()
}

private fun PlayerView.applySubtitleStyle(settings: PlaybackSettingsSnapshot) {
    subtitleView?.apply {
        setApplyEmbeddedStyles(false)
        setFixedTextSize(
            TypedValue.COMPLEX_UNIT_SP,
            settings.subtitleFontSize.toFloat().coerceIn(16f, 54f),
        )
        setBottomPaddingFraction(settings.subtitleVerticalOffset.toBottomPaddingFraction())
        setStyle(
            CaptionStyleCompat(
                settings.subtitleForegroundColor.toAndroidColor(Color.WHITE),
                Color.TRANSPARENT,
                Color.TRANSPARENT,
                if (settings.subtitleStrokeWidth > 0.0) {
                    CaptionStyleCompat.EDGE_TYPE_OUTLINE
                } else {
                    CaptionStyleCompat.EDGE_TYPE_NONE
                },
                settings.subtitleStrokeColor.toAndroidColor(Color.BLACK),
                Typeface.DEFAULT_BOLD,
            ),
        )
    }
}

private fun String?.toSubtitleMimeType(): String {
    val raw = this?.trim().orEmpty()
    return when (raw.lowercase()) {
        "vtt", "webvtt", "text/vtt", "text/webvtt" -> MimeTypes.TEXT_VTT
        "srt", "subrip", "application/x-subrip" -> MimeTypes.APPLICATION_SUBRIP
        "ssa", "ass", "text/x-ssa" -> MimeTypes.TEXT_SSA
        "ttml", "application/ttml+xml" -> MimeTypes.APPLICATION_TTML
        "" -> MimeTypes.TEXT_VTT
        else -> raw.takeIf { it.contains('/') } ?: MimeTypes.TEXT_VTT
    }
}

private fun String?.toAndroidColor(fallback: Int): Int =
    runCatching {
        val value = this?.trim()?.takeIf { it.isNotBlank() } ?: return@runCatching fallback
        Color.parseColor(if (value.startsWith("#")) value else "#$value")
    }.getOrDefault(fallback)

private fun Double.toBottomPaddingFraction(): Float =
    (0.08f + (-this.toFloat() / 100f)).coerceIn(0.02f, 0.28f)

private fun String.normalizedLanguageCode(): String =
    trim()
        .lowercase()
        .replace('_', '-')
        .takeIf { it.isNotBlank() }
        ?: "und"

private fun String.matchesLanguage(other: String): Boolean =
    this == other || substringBefore('-') == other.substringBefore('-')

private fun String.isTorrentLikeUri(): Boolean {
    val clean = trim()
    return clean.startsWith("magnet:", ignoreCase = true) ||
        clean.contains("btih:", ignoreCase = true) ||
        clean.substringBefore('?').substringBefore('#').endsWith(".torrent", ignoreCase = true)
}

private fun Context.findActivity(): Activity? = when (this) {
    is Activity -> this
    is ContextWrapper -> baseContext.findActivity()
    else -> null
}

enum class PlayerBackend {
    NORMAL,
    VLC,
    MPV,
    EXTERNAL,
}

data class PlaybackSessionState(
    val backend: PlayerBackend = PlayerBackend.NORMAL,
    val preferredInAppPlayer: InAppPlayer = InAppPlayer.NORMAL,
    val currentSource: PlayerSource? = null,
)

