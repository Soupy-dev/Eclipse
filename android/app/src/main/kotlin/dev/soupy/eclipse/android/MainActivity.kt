package dev.soupy.eclipse.android

import android.app.PictureInPictureParams
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.util.Rational
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.mutableStateOf
import dev.soupy.eclipse.android.core.player.EclipsePictureInPictureState

class MainActivity : ComponentActivity() {
    private val trackerCallbackUri = mutableStateOf<String?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        trackerCallbackUri.value = intent?.dataString
        enableEdgeToEdge()
        setContent {
            EclipseAndroidApp(
                trackerCallbackUri = trackerCallbackUri.value,
                onTrackerCallbackConsumed = {
                    trackerCallbackUri.value = null
                },
            )
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        trackerCallbackUri.value = intent.dataString
    }

    override fun onUserLeaveHint() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && EclipsePictureInPictureState.enabled) {
            enterPictureInPictureMode(
                PictureInPictureParams.Builder()
                    .setAspectRatio(Rational(16, 9))
                    .build(),
            )
        }
        super.onUserLeaveHint()
    }
}


