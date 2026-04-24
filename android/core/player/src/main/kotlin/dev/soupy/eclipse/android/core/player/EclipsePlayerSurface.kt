package dev.soupy.eclipse.android.core.player

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.Browser
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.unit.dp
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.PlayerView
import dev.soupy.eclipse.android.core.design.GlassPanel
import dev.soupy.eclipse.android.core.model.InAppPlayer
import dev.soupy.eclipse.android.core.model.PlaybackSettingsSnapshot
import dev.soupy.eclipse.android.core.model.PlayerSource
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive

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
                    text = "Normal player foundation",
                    style = MaterialTheme.typography.titleLarge,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                Text(
                    text = "Media3/ExoPlayer is wired here for Milestone 1. VLC, mpv, external-player handoff, AniSkip, and next-episode orchestration will hang off this boundary later.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.8f),
                )
            }
        }
        return
    }

    val context = LocalContext.current
    val onProgressState = rememberUpdatedState(onProgress)

    if (preferredPlayer == InAppPlayer.EXTERNAL) {
        ExternalPlayerPanel(
            source = source,
            modifier = modifier,
        )
        return
    }

    val exoPlayer = remember(source.uri, source.headers) {
        val httpFactory = DefaultHttpDataSource.Factory()
            .setDefaultRequestProperties(source.headers)
        val mediaSourceFactory = DefaultMediaSourceFactory(
            DefaultDataSource.Factory(context, httpFactory),
        )

        ExoPlayer.Builder(context)
            .setMediaSourceFactory(mediaSourceFactory)
            .build()
            .apply {
                setMediaItem(MediaItem.fromUri(source.uri))
                prepare()
                playWhenReady = false
            }
    }

    fun emitProgressSnapshot(forceFinished: Boolean = false) {
        val durationMs = exoPlayer.duration
        if (durationMs <= 0L || durationMs == C.TIME_UNSET) {
            return
        }

        val positionMs = exoPlayer.currentPosition
            .coerceAtLeast(0L)
            .coerceAtMost(durationMs)
        onProgressState.value(
            PlaybackProgressSnapshot(
                positionMs = positionMs,
                durationMs = durationMs,
                isFinished = forceFinished || positionMs >= durationMs - 1_500L,
            ),
        )
    }

    LaunchedEffect(exoPlayer) {
        while (isActive) {
            delay(15_000L)
            if (exoPlayer.isPlaying) {
                emitProgressSnapshot()
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
        if (preferredPlayer == InAppPlayer.VLC || preferredPlayer == InAppPlayer.MPV) {
            GlassPanel {
                Text(
                    text = "${preferredPlayer.name.lowercase()} backend is selected. Direct streams fall back to Normal playback until that Android backend lands.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.78f),
                )
            }
        }

        if (settings.skip85sEnabled) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End,
            ) {
                Button(
                    onClick = {
                        val currentPosition = exoPlayer.currentPosition.coerceAtLeast(0L)
                        val duration = exoPlayer.duration.takeIf { it > 0 && it != C.TIME_UNSET }
                        val targetPosition = duration?.let { durationMs ->
                            (currentPosition + 85_000L).coerceAtMost((durationMs - 1_000L).coerceAtLeast(0L))
                        } ?: (currentPosition + 85_000L)
                        exoPlayer.seekTo(targetPosition)
                        emitProgressSnapshot()
                    },
                ) {
                    Text("Skip 85s")
                }
            }
        }

        AndroidView(
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(16 / 9f),
            factory = { viewContext ->
                PlayerView(viewContext).apply {
                    player = exoPlayer
                    useController = true
                }
            },
            update = { playerView ->
                playerView.player = exoPlayer
            },
        )
    }
}

@Composable
private fun ExternalPlayerPanel(
    source: PlayerSource,
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
                text = source.title ?: "External player",
                style = MaterialTheme.typography.titleLarge,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Text(
                text = "Open this direct stream with another installed Android player.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.78f),
            )
            Button(
                onClick = {
                    launchError = runCatching {
                        context.startActivity(source.externalPlayerIntent())
                    }.exceptionOrNull()?.let { error ->
                        if (error is ActivityNotFoundException) {
                            "No external video player is available for this stream."
                        } else {
                            error.message ?: "External player launch failed."
                        }
                    }
                },
            ) {
                Text("Open External Player")
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

private fun PlayerSource.externalPlayerIntent(): Intent {
    val streamUri = Uri.parse(uri)
    val openIntent = Intent(Intent.ACTION_VIEW).apply {
        setDataAndType(streamUri, mimeType ?: "video/*")
        putExtra(Intent.EXTRA_TITLE, title)
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

