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
import android.media.AudioManager
import android.net.Uri
import android.os.Bundle
import android.provider.Browser
import android.util.TypedValue
import android.view.GestureDetector
import android.view.MotionEvent
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.unit.dp
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.Player
import androidx.media3.common.PlaybackException
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
import kotlin.math.abs
import kotlin.math.roundToInt
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer
import org.videolan.libvlc.interfaces.IMedia
import org.videolan.libvlc.util.VLCVideoLayout

private const val VlcSubtitleSlaveType = 0
private const val VlcExternalSubtitlePriority = 4
private const val VlcDisabledTrackId = -1

object EclipsePictureInPictureState {
    @Volatile
    var enabled: Boolean = false
}

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
    onPlaybackReady: (PlayerSource) -> Unit = {},
    onPlaybackFailure: (PlayerSource, String, Boolean) -> Unit = { _, _, _ -> },
) {
    DisposableEffect(source?.uri, preferredPlayer, settings.pictureInPictureEnabled) {
        val active = source != null &&
            preferredPlayer == InAppPlayer.VLC &&
            settings.pictureInPictureEnabled
        EclipsePictureInPictureState.enabled = active
        onDispose {
            if (EclipsePictureInPictureState.enabled == active) {
                EclipsePictureInPictureState.enabled = false
            }
        }
    }

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
                    text = "Choose a stream to start playback.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.8f),
                )
            }
        }
        return
    }

    val context = LocalContext.current
    val onProgressState = rememberUpdatedState(onProgress)
    val onPlaybackReadyState = rememberUpdatedState(onPlaybackReady)
    val onPlaybackFailureState = rememberUpdatedState(onPlaybackFailure)
    val settingsState = rememberUpdatedState(settings)
    val skipSegmentsState = rememberUpdatedState(skipSegments)
    var progressPercent by remember(source.uri) { mutableStateOf(0f) }
    var currentPositionSeconds by remember(source.uri) { mutableStateOf(0.0) }
    var subtitlesEnabled by remember(source.uri, settings.enableSubtitlesByDefault) {
        mutableStateOf(settings.enableSubtitlesByDefault)
    }
    var selectedSubtitleLanguage by remember(source.uri, settings.defaultSubtitleLanguage) {
        mutableStateOf(settings.defaultSubtitleLanguage)
    }
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
                    text = "Only direct HTTP(S) media streams are accepted. Torrent, magnet, BTIH, and .torrent sources are rejected before playback.",
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
            settings = settings,
            onProgress = onProgressState.value,
            onPlaybackReady = onPlaybackReadyState.value,
            onPlaybackFailure = onPlaybackFailureState.value,
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

    val mediaItem = remember(source, selectedSubtitleLanguage, subtitlesEnabled) {
        source.toMediaItem(
            defaultSubtitleLanguage = selectedSubtitleLanguage,
            enableSubtitlesByDefault = subtitlesEnabled,
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
                setPlaybackSpeed(settings.defaultPlaybackSpeed.toFloat())
                playWhenReady = false
            }
    }

    LaunchedEffect(exoPlayer, settings.defaultPlaybackSpeed) {
        exoPlayer.setPlaybackSpeed(settings.defaultPlaybackSpeed.toFloat())
    }

    var reportedPlaybackReady by remember(source.uri) { mutableStateOf(false) }

    LaunchedEffect(
        exoPlayer,
        subtitlesEnabled,
        selectedSubtitleLanguage,
        settings.preferredAnimeAudioLanguage,
    ) {
        val textLanguage = selectedSubtitleLanguage.normalizedLanguageCode()
        val audioLanguage = settings.preferredAnimeAudioLanguage.normalizedLanguageCode()
        val parameters = exoPlayer.trackSelectionParameters
            .buildUpon()
            .setPreferredAudioLanguage(audioLanguage)
            .setTrackTypeDisabled(C.TRACK_TYPE_TEXT, !subtitlesEnabled)
            .setSelectUndeterminedTextLanguage(subtitlesEnabled)
            .apply {
                if (subtitlesEnabled) {
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
                if (playbackState == Player.STATE_READY && !reportedPlaybackReady) {
                    reportedPlaybackReady = true
                    onPlaybackReadyState.value(source)
                }
                if (playbackState == Player.STATE_ENDED) {
                    emitProgressSnapshot(forceFinished = true)
                }
            }

            override fun onPlayerError(error: PlaybackException) {
                onPlaybackFailureState.value(
                    source,
                    error.message ?: "Playback failed.",
                    error.message.isLikelySourceFailure(),
                )
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

        PlaybackTrackControls(
            source = source,
            preferredAudioLanguage = settings.preferredAnimeAudioLanguage,
            subtitlesEnabled = subtitlesEnabled,
            selectedSubtitleLanguage = selectedSubtitleLanguage,
            onSubtitlesEnabledChanged = { subtitlesEnabled = it },
            onSubtitleLanguageChanged = {
                selectedSubtitleLanguage = it
                subtitlesEnabled = true
            },
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
                        enabled = settings.doubleTapSeekEnabled,
                        seekDeltaMs = (settings.doubleTapSeekSeconds * 1_000.0).toLong(),
                        twoFingerPlayPauseEnabled = settings.playerTwoFingerTapPlayPauseEnabled,
                        brightnessGestureEnabled = settings.brightnessGestureEnabled,
                        volumeGestureEnabled = settings.volumeGestureEnabled,
                        onSeek = { emitProgressSnapshot() },
                    )
                }
            },
            update = { playerView ->
                playerView.player = exoPlayer
                playerView.applySubtitleStyle(settings)
                playerView.installDoubleTapSeek(
                    exoPlayer = exoPlayer,
                    enabled = settings.doubleTapSeekEnabled,
                    seekDeltaMs = (settings.doubleTapSeekSeconds * 1_000.0).toLong(),
                    twoFingerPlayPauseEnabled = settings.playerTwoFingerTapPlayPauseEnabled,
                    brightnessGestureEnabled = settings.brightnessGestureEnabled,
                    volumeGestureEnabled = settings.volumeGestureEnabled,
                    onSeek = { emitProgressSnapshot() },
                )
            },
        )
    }
}

@Composable
private fun PlaybackTrackControls(
    source: PlayerSource,
    preferredAudioLanguage: String,
    subtitlesEnabled: Boolean,
    selectedSubtitleLanguage: String,
    onSubtitlesEnabledChanged: (Boolean) -> Unit,
    onSubtitleLanguageChanged: (String) -> Unit,
) {
    GlassPanel(
        modifier = Modifier.fillMaxWidth(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(12.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Text(
                text = "Audio: ${preferredAudioLanguage.ifBlank { "Auto" }}",
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.72f),
            )
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (subtitlesEnabled) {
                    Button(onClick = { onSubtitlesEnabledChanged(false) }) {
                        Text("Subtitles On")
                    }
                } else {
                    OutlinedButton(onClick = { onSubtitlesEnabledChanged(true) }) {
                        Text("Subtitles Off")
                    }
                }
                source.subtitles.take(4).forEach { subtitle ->
                    val language = subtitle.language ?: subtitle.label
                    val selected = subtitlesEnabled &&
                        language.normalizedLanguageCode().matchesLanguage(selectedSubtitleLanguage.normalizedLanguageCode())
                    if (selected) {
                        Button(onClick = { onSubtitleLanguageChanged(language) }) {
                            Text(subtitle.label)
                        }
                    } else {
                        OutlinedButton(onClick = { onSubtitleLanguageChanged(language) }) {
                            Text(subtitle.label)
                        }
                    }
                }
            }
            Text(
                text = "Subtitle style follows Settings and updates this player immediately.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.62f),
            )
        }
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
                onHoldEnd = { exoPlayer.setPlaybackSpeed(settings.defaultPlaybackSpeed.toFloat()) },
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

private data class VlcTrackOption(
    val id: Int,
    val name: String,
)

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
    enabled: Boolean,
    seekDeltaMs: Long,
    twoFingerPlayPauseEnabled: Boolean,
    brightnessGestureEnabled: Boolean,
    volumeGestureEnabled: Boolean,
    onSeek: () -> Unit,
) {
    var verticalMode: VerticalGestureMode? = null
    var startY = 0f
    var startX = 0f
    var startBrightness = currentWindowBrightness()
    val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
    var startVolume = audioManager?.getStreamVolume(AudioManager.STREAM_MUSIC) ?: 0
    val detector = GestureDetector(
        context,
        object : GestureDetector.SimpleOnGestureListener() {
            override fun onDoubleTap(e: MotionEvent): Boolean {
                if (!enabled) return false
                val viewWidth = width.takeIf { it > 0 } ?: return false
                val deltaMs = if (e.x < viewWidth / 2f) {
                    -seekDeltaMs
                } else {
                    seekDeltaMs
                }
                exoPlayer.seekBy(deltaMs)
                onSeek()
                return true
            }
        },
    )

    setOnTouchListener { _, event ->
        val handledVertical = handleVerticalPlayerGesture(
            event = event,
            brightnessGestureEnabled = brightnessGestureEnabled,
            volumeGestureEnabled = volumeGestureEnabled,
            audioManager = audioManager,
            start = VerticalGestureStart(
                mode = verticalMode,
                startX = startX,
                startY = startY,
                startBrightness = startBrightness,
                startVolume = startVolume,
            ),
            onStartChanged = { next ->
                verticalMode = next.mode
                startX = next.startX
                startY = next.startY
                startBrightness = next.startBrightness
                startVolume = next.startVolume
            },
        )
        if (handledVertical) return@setOnTouchListener true
        if (
            twoFingerPlayPauseEnabled &&
            event.pointerCount >= 2 &&
            event.actionMasked == MotionEvent.ACTION_POINTER_UP
        ) {
            if (exoPlayer.isPlaying) {
                exoPlayer.pause()
            } else {
                exoPlayer.play()
            }
            return@setOnTouchListener true
        }
        detector.onTouchEvent(event)
        false
    }
}

@SuppressLint("ClickableViewAccessibility")
private fun VLCVideoLayout.installVlcGestures(
    mediaPlayer: MediaPlayer,
    enabled: Boolean,
    seekDeltaMs: Long,
    twoFingerPlayPauseEnabled: Boolean,
    brightnessGestureEnabled: Boolean,
    volumeGestureEnabled: Boolean,
    onSeek: () -> Unit,
) {
    var verticalMode: VerticalGestureMode? = null
    var startY = 0f
    var startX = 0f
    var startBrightness = currentWindowBrightness()
    val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
    var startVolume = audioManager?.getStreamVolume(AudioManager.STREAM_MUSIC) ?: 0
    val detector = GestureDetector(
        context,
        object : GestureDetector.SimpleOnGestureListener() {
            override fun onDoubleTap(e: MotionEvent): Boolean {
                if (!enabled) return false
                val viewWidth = width.takeIf { it > 0 } ?: return false
                val deltaMs = if (e.x < viewWidth / 2f) {
                    -seekDeltaMs
                } else {
                    seekDeltaMs
                }
                mediaPlayer.seekBy(deltaMs)
                onSeek()
                return true
            }
        },
    )

    setOnTouchListener { _, event ->
        val handledVertical = handleVerticalPlayerGesture(
            event = event,
            brightnessGestureEnabled = brightnessGestureEnabled,
            volumeGestureEnabled = volumeGestureEnabled,
            audioManager = audioManager,
            start = VerticalGestureStart(
                mode = verticalMode,
                startX = startX,
                startY = startY,
                startBrightness = startBrightness,
                startVolume = startVolume,
            ),
            onStartChanged = { next ->
                verticalMode = next.mode
                startX = next.startX
                startY = next.startY
                startBrightness = next.startBrightness
                startVolume = next.startVolume
            },
        )
        if (handledVertical) return@setOnTouchListener true
        if (
            twoFingerPlayPauseEnabled &&
            event.pointerCount >= 2 &&
            event.actionMasked == MotionEvent.ACTION_POINTER_UP
        ) {
            if (mediaPlayer.isPlaying) {
                mediaPlayer.pause()
            } else {
                mediaPlayer.play()
            }
            return@setOnTouchListener true
        }
        detector.onTouchEvent(event)
        false
    }
}

private enum class VerticalGestureMode {
    BRIGHTNESS,
    VOLUME,
}

private data class VerticalGestureStart(
    val mode: VerticalGestureMode?,
    val startX: Float,
    val startY: Float,
    val startBrightness: Float,
    val startVolume: Int,
)

private fun android.view.View.handleVerticalPlayerGesture(
    event: MotionEvent,
    brightnessGestureEnabled: Boolean,
    volumeGestureEnabled: Boolean,
    audioManager: AudioManager?,
    start: VerticalGestureStart,
    onStartChanged: (VerticalGestureStart) -> Unit,
): Boolean {
    if (!brightnessGestureEnabled && !volumeGestureEnabled) return false

    when (event.actionMasked) {
        MotionEvent.ACTION_DOWN -> {
            onStartChanged(
                VerticalGestureStart(
                    mode = null,
                    startX = event.x,
                    startY = event.y,
                    startBrightness = currentWindowBrightness(),
                    startVolume = audioManager?.getStreamVolume(AudioManager.STREAM_MUSIC) ?: 0,
                ),
            )
            return false
        }
        MotionEvent.ACTION_MOVE -> {
            val deltaX = event.x - start.startX
            val deltaY = event.y - start.startY
            val mode = start.mode ?: when {
                abs(deltaY) < 24f || abs(deltaY) < abs(deltaX) -> null
                start.startX < width / 2f && brightnessGestureEnabled -> VerticalGestureMode.BRIGHTNESS
                start.startX >= width / 2f && volumeGestureEnabled -> VerticalGestureMode.VOLUME
                else -> null
            }?.also { nextMode ->
                onStartChanged(start.copy(mode = nextMode))
            } ?: return false
            val fraction = (-deltaY / height.coerceAtLeast(1).toFloat()).coerceIn(-1f, 1f)
            when (mode) {
                VerticalGestureMode.BRIGHTNESS -> setWindowBrightness(start.startBrightness + fraction)
                VerticalGestureMode.VOLUME -> {
                    val manager = audioManager ?: return false
                    val maxVolume = manager.getStreamMaxVolume(AudioManager.STREAM_MUSIC).coerceAtLeast(1)
                    val target = (start.startVolume + fraction * maxVolume)
                        .roundToInt()
                        .coerceIn(0, maxVolume)
                    manager.setStreamVolume(AudioManager.STREAM_MUSIC, target, 0)
                }
            }
            return true
        }
        MotionEvent.ACTION_UP,
        MotionEvent.ACTION_CANCEL -> {
            val wasActive = start.mode != null
            onStartChanged(start.copy(mode = null))
            return wasActive
        }
    }

    return false
}

private fun android.view.View.currentWindowBrightness(): Float {
    val value = context.findActivity()?.window?.attributes?.screenBrightness ?: -1f
    return value.takeIf { it >= 0f } ?: 0.5f
}

private fun android.view.View.setWindowBrightness(value: Float) {
    val activity = context.findActivity() ?: return
    val attributes = activity.window.attributes
    attributes.screenBrightness = value.coerceIn(0.02f, 1f)
    activity.window.attributes = attributes
}

private fun ExoPlayer.seekBy(deltaMs: Long) {
    val currentPosition = currentPosition.coerceAtLeast(0L)
    val duration = duration.takeIf { it > 0L && it != C.TIME_UNSET }
    val targetPosition = duration?.let { durationMs ->
        (currentPosition + deltaMs).coerceIn(0L, (durationMs - 1_000L).coerceAtLeast(0L))
    } ?: (currentPosition + deltaMs).coerceAtLeast(0L)
    seekTo(targetPosition)
}

private fun MediaPlayer.seekBy(deltaMs: Long) {
    val currentPosition = time.coerceAtLeast(0L)
    val duration = length.takeIf { it > 0L }
    val targetPosition = duration?.let { durationMs ->
        (currentPosition + deltaMs).coerceIn(0L, (durationMs - 1_000L).coerceAtLeast(0L))
    } ?: (currentPosition + deltaMs).coerceAtLeast(0L)
    setTime(targetPosition)
}

@Composable
private fun EmbeddedVlcPlayerPanel(
    source: PlayerSource,
    modifier: Modifier = Modifier,
    settings: PlaybackSettingsSnapshot,
    onProgress: (PlaybackProgressSnapshot) -> Unit,
    onPlaybackReady: (PlayerSource) -> Unit,
    onPlaybackFailure: (PlayerSource, String, Boolean) -> Unit,
) {
    var session by remember(source.uri) { mutableStateOf<VlcSession?>(null) }
    var playbackError by remember(source.uri) { mutableStateOf<String?>(null) }
    var audioTracks by remember(source.uri) { mutableStateOf(emptyList<VlcTrackOption>()) }
    var subtitleTracks by remember(source.uri) { mutableStateOf(emptyList<VlcTrackOption>()) }
    var selectedAudioTrackId by remember(source.uri) { mutableStateOf(VlcDisabledTrackId) }
    var selectedSubtitleTrackId by remember(source.uri) { mutableStateOf(VlcDisabledTrackId) }
    var userSelectedAudioTrack by remember(source.uri) { mutableStateOf(false) }
    var userSelectedSubtitleTrack by remember(source.uri) { mutableStateOf(false) }
    var autoAudioApplied by remember(source.uri, settings.preferredAnimeAudioLanguage) { mutableStateOf(false) }
    var autoSubtitleApplied by remember(
        source.uri,
        settings.enableSubtitlesByDefault,
        settings.defaultSubtitleLanguage,
    ) {
        mutableStateOf(false)
    }

    fun refreshVlcTracks(player: MediaPlayer?) {
        if (player == null) return
        audioTracks = player.vlcAudioTrackOptions()
        subtitleTracks = player.vlcSubtitleTrackOptions()
        selectedAudioTrackId = player.getAudioTrack()
        selectedSubtitleTrackId = player.getSpuTrack()
    }

    DisposableEffect(source.uri) {
        onDispose {
            session?.release()
            session = null
        }
    }

    LaunchedEffect(session, settings.defaultPlaybackSpeed) {
        session?.mediaPlayer?.setRate(settings.defaultPlaybackSpeed.toFloat())
    }

    LaunchedEffect(session) {
        while (isActive) {
            refreshVlcTracks(session?.mediaPlayer)
            delay(if (audioTracks.isEmpty() && subtitleTracks.isEmpty()) 300L else 1_000L)
        }
    }

    LaunchedEffect(session, audioTracks, settings.preferredAnimeAudioLanguage) {
        if (autoAudioApplied || userSelectedAudioTrack || !source.isAnimeLike()) return@LaunchedEffect
        val player = session?.mediaPlayer ?: return@LaunchedEffect
        val preferred = preferredVlcTrack(audioTracks, settings.preferredAnimeAudioLanguage) ?: return@LaunchedEffect
        if (player.setAudioTrack(preferred.id)) {
            selectedAudioTrackId = preferred.id
            autoAudioApplied = true
        }
    }

    LaunchedEffect(session, subtitleTracks, settings.enableSubtitlesByDefault, settings.defaultSubtitleLanguage) {
        if (autoSubtitleApplied || userSelectedSubtitleTrack) return@LaunchedEffect
        val player = session?.mediaPlayer ?: return@LaunchedEffect
        if (!settings.enableSubtitlesByDefault) {
            player.setSpuTrack(VlcDisabledTrackId)
            selectedSubtitleTrackId = VlcDisabledTrackId
            autoSubtitleApplied = true
            return@LaunchedEffect
        }
        val preferred = preferredVlcTrack(subtitleTracks, settings.defaultSubtitleLanguage)
            ?: subtitleTracks.firstOrNull()
            ?: return@LaunchedEffect
        if (player.setSpuTrack(preferred.id)) {
            selectedSubtitleTrackId = preferred.id
            autoSubtitleApplied = true
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

    Column(
        modifier = modifier
            .fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        VlcPlaybackTrackControls(
            audioTracks = audioTracks,
            subtitleTracks = subtitleTracks,
            selectedAudioTrackId = selectedAudioTrackId,
            selectedSubtitleTrackId = selectedSubtitleTrackId,
            showSubtitleStyleSummary = settings.enableVLCSubtitleEditMenu,
            subtitleStyleSummary = settings.vlcSubtitleStyleSummary(),
            onAudioTrackSelected = { track ->
                val player = session?.mediaPlayer ?: return@VlcPlaybackTrackControls
                userSelectedAudioTrack = true
                if (player.setAudioTrack(track.id)) {
                    selectedAudioTrackId = track.id
                }
                refreshVlcTracks(player)
            },
            onSubtitleDisabled = {
                val player = session?.mediaPlayer ?: return@VlcPlaybackTrackControls
                userSelectedSubtitleTrack = true
                player.setSpuTrack(VlcDisabledTrackId)
                selectedSubtitleTrackId = VlcDisabledTrackId
                refreshVlcTracks(player)
            },
            onSubtitleTrackSelected = { track ->
                val player = session?.mediaPlayer ?: return@VlcPlaybackTrackControls
                userSelectedSubtitleTrack = true
                if (player.setSpuTrack(track.id)) {
                    selectedSubtitleTrackId = track.id
                }
                refreshVlcTracks(player)
            },
        )

        Surface(
            modifier = Modifier
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
                                    settings = settings,
                                )
                            }.onSuccess { created ->
                                session?.release()
                                session = created
                                refreshVlcTracks(created.mediaPlayer)
                                onPlaybackReady(source)
                                layout.installVlcGestures(
                                    mediaPlayer = created.mediaPlayer,
                                    enabled = settings.doubleTapSeekEnabled,
                                    seekDeltaMs = (settings.doubleTapSeekSeconds * 1_000.0).toLong(),
                                    twoFingerPlayPauseEnabled = settings.playerTwoFingerTapPlayPauseEnabled,
                                    brightnessGestureEnabled = settings.brightnessGestureEnabled,
                                    volumeGestureEnabled = settings.volumeGestureEnabled,
                                    onSeek = {
                                        onProgress(
                                            PlaybackProgressSnapshot(
                                                positionMs = created.mediaPlayer.time.coerceAtLeast(0L),
                                                durationMs = created.mediaPlayer.length.coerceAtLeast(0L),
                                            ),
                                        )
                                    },
                                )
                                playbackError = null
                            }.onFailure { error ->
                                val message = error.message ?: "Embedded VLC playback failed."
                                playbackError = message
                                onPlaybackFailure(source, message, message.isLikelySourceFailure())
                            }
                        }
                    },
                    update = { layout ->
                        session?.mediaPlayer?.let { mediaPlayer ->
                            mediaPlayer.setRate(settings.defaultPlaybackSpeed.toFloat())
                            layout.installVlcGestures(
                                mediaPlayer = mediaPlayer,
                                enabled = settings.doubleTapSeekEnabled,
                                seekDeltaMs = (settings.doubleTapSeekSeconds * 1_000.0).toLong(),
                                twoFingerPlayPauseEnabled = settings.playerTwoFingerTapPlayPauseEnabled,
                                brightnessGestureEnabled = settings.brightnessGestureEnabled,
                                volumeGestureEnabled = settings.volumeGestureEnabled,
                                onSeek = {
                                    onProgress(
                                        PlaybackProgressSnapshot(
                                            positionMs = mediaPlayer.time.coerceAtLeast(0L),
                                            durationMs = mediaPlayer.length.coerceAtLeast(0L),
                                        ),
                                    )
                                },
                            )
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
}

@Composable
private fun VlcPlaybackTrackControls(
    audioTracks: List<VlcTrackOption>,
    subtitleTracks: List<VlcTrackOption>,
    selectedAudioTrackId: Int,
    selectedSubtitleTrackId: Int,
    showSubtitleStyleSummary: Boolean,
    subtitleStyleSummary: String,
    onAudioTrackSelected: (VlcTrackOption) -> Unit,
    onSubtitleDisabled: () -> Unit,
    onSubtitleTrackSelected: (VlcTrackOption) -> Unit,
) {
    GlassPanel(
        modifier = Modifier.fillMaxWidth(),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(12.dp),
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                VlcTrackDropdown(
                    modifier = Modifier.weight(1f),
                    title = "Audio",
                    selectedLabel = audioTracks.firstOrNull { it.id == selectedAudioTrackId }?.name
                        ?: "Auto",
                    emptyLabel = "No audio tracks",
                    tracks = audioTracks,
                    onTrackSelected = onAudioTrackSelected,
                )
                VlcSubtitleDropdown(
                    modifier = Modifier.weight(1f),
                    selectedLabel = subtitleTracks.firstOrNull { it.id == selectedSubtitleTrackId }?.name
                        ?: if (selectedSubtitleTrackId == VlcDisabledTrackId) "Off" else "Auto",
                    tracks = subtitleTracks,
                    onDisabled = onSubtitleDisabled,
                    onTrackSelected = onSubtitleTrackSelected,
                )
            }
            if (showSubtitleStyleSummary) {
                Text(
                    text = subtitleStyleSummary,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.62f),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun VlcTrackDropdown(
    modifier: Modifier = Modifier,
    title: String,
    selectedLabel: String,
    emptyLabel: String,
    tracks: List<VlcTrackOption>,
    onTrackSelected: (VlcTrackOption) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Box(modifier = modifier) {
        OutlinedButton(
            modifier = Modifier.fillMaxWidth(),
            onClick = { expanded = true },
        ) {
            Text(
                text = "$title: $selectedLabel",
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
        ) {
            if (tracks.isEmpty()) {
                DropdownMenuItem(
                    text = { Text(emptyLabel) },
                    onClick = { expanded = false },
                )
            } else {
                tracks.forEach { track ->
                    DropdownMenuItem(
                        text = {
                            Text(
                                text = track.name,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        },
                        onClick = {
                            expanded = false
                            onTrackSelected(track)
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun VlcSubtitleDropdown(
    modifier: Modifier = Modifier,
    selectedLabel: String,
    tracks: List<VlcTrackOption>,
    onDisabled: () -> Unit,
    onTrackSelected: (VlcTrackOption) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Box(modifier = modifier) {
        OutlinedButton(
            modifier = Modifier.fillMaxWidth(),
            onClick = { expanded = true },
        ) {
            Text(
                text = "Subtitles: $selectedLabel",
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        DropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false },
        ) {
            DropdownMenuItem(
                text = { Text("Disable Subtitles") },
                onClick = {
                    expanded = false
                    onDisabled()
                },
            )
            if (tracks.isEmpty()) {
                DropdownMenuItem(
                    text = { Text("No subtitles in stream") },
                    onClick = { expanded = false },
                )
            } else {
                tracks.forEach { track ->
                    DropdownMenuItem(
                        text = {
                            Text(
                                text = track.name,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        },
                        onClick = {
                            expanded = false
                            onTrackSelected(track)
                        },
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
            settings: PlaybackSettingsSnapshot,
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
            source.vlcSubtitleUris().forEach { subtitleUri ->
                media.addSlave(IMedia.Slave(VlcSubtitleSlaveType, VlcExternalSubtitlePriority, subtitleUri))
            }
            mediaPlayer.media = media
            media.release()
            mediaPlayer.play()
            mediaPlayer.setRate(settings.defaultPlaybackSpeed.toFloat())
            return VlcSession(mediaPlayer, libVlc)
        }
    }
}

private fun MediaPlayer.vlcAudioTrackOptions(): List<VlcTrackOption> =
    runCatching {
        getAudioTracks()
            ?.map { track ->
                VlcTrackOption(
                    id = track.id,
                    name = track.name?.takeIf { it.isNotBlank() } ?: "Audio ${track.id}",
                )
            }
            .orEmpty()
    }.getOrDefault(emptyList())

private fun MediaPlayer.vlcSubtitleTrackOptions(): List<VlcTrackOption> =
    runCatching {
        getSpuTracks()
            ?.filter { track -> track.id >= 0 && !track.name.isDisabledTrackName() }
            ?.map { track ->
                VlcTrackOption(
                    id = track.id,
                    name = track.name?.takeIf { it.isNotBlank() } ?: "Subtitle ${track.id}",
                )
            }
            .orEmpty()
    }.getOrDefault(emptyList())

private fun preferredVlcTrack(
    tracks: List<VlcTrackOption>,
    preferredLanguage: String,
): VlcTrackOption? {
    val languageTokens = languageTokens(preferredLanguage)
    if (tracks.isEmpty() || languageTokens.isEmpty()) return null
    val dialogueTokens = setOf("dialogue", "dialog", "full", "complete", "cc")
    val lessPreferredTokens = setOf("sign", "songs", "song", "karaoke", "forced")
    return tracks
        .map { track ->
            val lowerName = track.name.lowercase()
            val score = languageTokens.count { token -> lowerName.contains(token) } * 100 +
                dialogueTokens.count { token -> lowerName.contains(token) } * 10 -
                lessPreferredTokens.count { token -> lowerName.contains(token) } * 8
            track to score
        }
        .filter { (_, score) -> score > 0 }
        .maxWithOrNull(
            compareBy<Pair<VlcTrackOption, Int>> { it.second }
                .thenByDescending { -it.first.id },
        )
        ?.first
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
    InAppPlayer.MPV -> null
    InAppPlayer.NORMAL,
    InAppPlayer.EXTERNAL -> null
}

private fun InAppPlayer.externalPanelLabel(): String = when (this) {
    InAppPlayer.VLC -> "VLC"
    InAppPlayer.MPV -> "External Player"
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

private fun PlayerSource.vlcSubtitleUris(): List<String> =
    subtitles
        .mapNotNull { subtitle -> subtitle.uri?.takeIf { it.isNotBlank() } }
        .distinct()

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

private fun String?.isDisabledTrackName(): Boolean {
    val lower = this?.trim()?.lowercase().orEmpty()
    return lower.contains("disable") || lower.contains("off") || lower.contains("none")
}

private fun languageTokens(preferredLanguage: String): Set<String> {
    val lower = preferredLanguage.trim().lowercase()
    if (lower.isBlank()) return emptySet()
    return when (lower) {
        "jpn", "ja", "jp" -> setOf("jpn", "ja", "jp", "japanese")
        "eng", "en" -> setOf("eng", "en", "us", "uk", "english")
        "spa", "es", "esp" -> setOf("spa", "es", "esp", "spanish", "lat")
        "fre", "fra", "fr" -> setOf("fre", "fra", "fr", "french")
        "ger", "deu", "de" -> setOf("ger", "deu", "de", "german")
        "ita", "it" -> setOf("ita", "it", "italian")
        "por", "pt" -> setOf("por", "pt", "br", "portuguese")
        "rus", "ru" -> setOf("rus", "ru", "russian")
        "chi", "zho", "zh" -> setOf("chi", "zho", "zh", "chinese", "mandarin", "cantonese")
        "kor", "ko" -> setOf("kor", "ko", "korean")
        else -> setOf(lower)
    }
}

private fun PlayerSource.isAnimeLike(): Boolean =
    context?.anilistMediaId != null ||
        context?.isSpecial == true ||
        context?.titleOnlySearch == true

private fun PlaybackSettingsSnapshot.vlcSubtitleStyleSummary(): String =
    "Subtitle style: ${subtitleFontSize.roundToInt()}sp, stroke ${"%.1f".format(subtitleStrokeWidth)}, offset ${"%.0f".format(subtitleVerticalOffset)}"

private fun String.isTorrentLikeUri(): Boolean {
    val clean = trim()
    return clean.startsWith("magnet:", ignoreCase = true) ||
        clean.contains("btih:", ignoreCase = true) ||
        clean.substringBefore('?').substringBefore('#').endsWith(".torrent", ignoreCase = true)
}

private fun String?.isLikelySourceFailure(): Boolean {
    val message = this?.lowercase().orEmpty()
    return listOf(
        "http 401",
        "http 403",
        "http 404",
        "http 410",
        "http 451",
        "response code: 401",
        "response code: 403",
        "response code: 404",
        "source error",
        "unable to connect",
        "failed to connect",
        "connection refused",
        "unknownhost",
    ).any(message::contains)
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

