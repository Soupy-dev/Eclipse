package dev.soupy.eclipse.android.core.design

import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

private val EclipseDarkColors = darkColorScheme(
    primary = Color(0xFFE7D7FF),
    onPrimary = Color(0xFF151017),
    secondary = Color(0xFFD7C4FF),
    tertiary = Color(0xFFE6D7FF),
    background = Color(0xFF141414),
    surface = Color(0xFF202020),
    onBackground = Color.White,
    onSurface = Color.White,
)

private val EclipseLightColors = lightColorScheme(
    primary = Color(0xFF4965D8),
    onPrimary = Color.White,
    secondary = Color(0xFF006A86),
    tertiary = Color(0xFF006C5D),
    background = Color(0xFFF9F7FF),
    surface = Color(0xFFFFFFFF),
    onBackground = Color(0xFF181820),
    onSurface = Color(0xFF252530),
)

private val EclipseTypography = androidx.compose.material3.Typography(
    displayMedium = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Bold,
        fontSize = 30.sp,
        lineHeight = 34.sp,
    ),
    headlineSmall = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Bold,
        fontSize = 22.sp,
        lineHeight = 26.sp,
    ),
    titleLarge = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.SemiBold,
        fontSize = 20.sp,
        lineHeight = 24.sp,
    ),
    bodyLarge = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Normal,
        fontSize = 16.sp,
        lineHeight = 24.sp,
    ),
    bodyMedium = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Normal,
        fontSize = 14.sp,
        lineHeight = 20.sp,
    ),
    labelLarge = TextStyle(
        fontFamily = FontFamily.SansSerif,
        fontWeight = FontWeight.Medium,
        fontSize = 12.sp,
        lineHeight = 16.sp,
        letterSpacing = 0.sp,
    ),
)

private val EclipseShapes = Shapes(
    extraSmall = RoundedCornerShape(8.dp),
    small = RoundedCornerShape(10.dp),
    medium = RoundedCornerShape(12.dp),
    large = RoundedCornerShape(16.dp),
    extraLarge = RoundedCornerShape(16.dp),
)

@Composable
fun EclipseTheme(
    accentColor: String = "#6D8CFF",
    appearance: String = "system",
    content: @Composable () -> Unit,
) {
    val dark = when (appearance.trim().lowercase()) {
        "light" -> false
        "dark" -> true
        else -> isSystemInDarkTheme()
    }
    val accent = accentColor.toComposeColor(if (dark) Color(0xFFB5B8FF) else Color(0xFF4965D8))
    val baseScheme = if (dark) EclipseDarkColors else EclipseLightColors
    MaterialTheme(
        colorScheme = baseScheme.copy(
            primary = accent,
            tertiary = accent,
        ),
        typography = EclipseTypography,
        shapes = EclipseShapes,
        content = content,
    )
}

@Composable
fun EclipseBackground(
    modifier: Modifier = Modifier,
    appearance: String = "system",
    content: @Composable BoxScope.() -> Unit,
) {
    val dark = when (appearance.trim().lowercase()) {
        "light" -> false
        "dark" -> true
        else -> isSystemInDarkTheme()
    }
    val baseColors = if (dark) {
        listOf(
            Color(0xFF141414),
            Color(0xFF241536),
            Color(0xFF3F1F73),
            Color(0xFF141414),
        )
    } else {
        listOf(
            Color(0xFFF8F4FF),
            Color(0xFFEDE4FF),
            Color(0xFFDCCBFF),
            Color(0xFFFBF8FF),
        )
    }
    Box(
        modifier = modifier
            .fillMaxSize()
            .background(
                brush = Brush.verticalGradient(
                    colors = baseColors,
                ),
            ),
    ) {
        content()
    }
}

private fun String.toComposeColor(fallback: Color): Color {
    val value = trim().removePrefix("#")
    if (value.length != 6 && value.length != 8) return fallback
    if (!value.all { it.isDigit() || it.lowercaseChar() in 'a'..'f' }) return fallback
    val argb = runCatching {
        if (value.length == 6) {
            0xFF000000L or value.toLong(16)
        } else {
            value.toLong(16)
        }
    }.getOrNull() ?: return fallback
    return Color(argb)
}

@Composable
fun GlassPanel(
    modifier: Modifier = Modifier,
    contentPadding: PaddingValues = PaddingValues(20.dp),
    content: @Composable () -> Unit,
) {
    Card(
        modifier = modifier,
        shape = RoundedCornerShape(16.dp),
        colors = CardDefaults.cardColors(
            containerColor = Color.White.copy(alpha = 0.08f),
        ),
    ) {
        Box(modifier = Modifier.padding(contentPadding)) {
            content()
        }
    }
}

@Composable
fun FeaturePlaceholderScreen(
    title: String,
    eyebrow: String,
    description: String,
    highlights: List<String>,
    modifier: Modifier = Modifier,
    content: (@Composable ColumnScope.() -> Unit)? = null,
) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .statusBarsPadding()
            .padding(horizontal = 20.dp, vertical = 16.dp),
        verticalArrangement = Arrangement.spacedBy(18.dp),
    ) {
        Text(
            text = eyebrow.uppercase(),
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.tertiary,
        )
        Text(
            text = title,
            style = MaterialTheme.typography.displayMedium,
            color = MaterialTheme.colorScheme.onBackground,
        )
        Text(
            text = description,
            style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onBackground.copy(alpha = 0.8f),
        )

        content?.let {
            GlassPanel(modifier = Modifier.fillMaxWidth()) {
                Column(verticalArrangement = Arrangement.spacedBy(14.dp), content = it)
            }
        }

        highlights.forEach { highlight ->
            GlassPanel(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(28.dp)),
            ) {
                Text(
                    text = highlight,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                )
            }
        }

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .padding(bottom = 32.dp),
            contentAlignment = Alignment.CenterStart,
        ) {
            Text(
                text = "Eclipse routes are connected to the Luna-style shell, persistence, playback, and backup flow.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onBackground.copy(alpha = 0.7f),
            )
        }
    }
}

