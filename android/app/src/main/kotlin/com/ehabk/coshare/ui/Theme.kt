package com.ehabk.coshare.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.Immutable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.LayoutDirection

/** CoShare's palette, shared with the website (website/styles.css) and the Apple apps (Shared/SharedViews.swift). */
@Immutable
data class Palette(
    val paper: Color,
    val surface: Color,
    val surface2: Color,
    val ink: Color,
    val text: Color,
    val muted: Color,
    val line: Color,
    val signal: Color,
    val onSignal: Color,
    val signalSoft: Color,
    /** Connected / secure. */
    val teal: Color,
    /** Waiting for devices. */
    val waiting: Color,
    /** Paused or quiet hours. */
    val paused: Color,
    val danger: Color,
    val dangerSoft: Color,
)

val LightPalette = Palette(
    paper = Color(0xFFF5F0E8), surface = Color(0xFFFFFDF9), surface2 = Color(0xFFF8F3EA), ink = Color(0xFF18160F),
    text = Color(0xFF2B2720), muted = Color(0xFF5F584C), line = Color(0xFFE2D9CA), signal = Color(0xFFD24A22),
    onSignal = Color.White, signalSoft = Color(0x1AD24A22), teal = Color(0xFF0F7067), waiting = Color(0xFFD9971C),
    paused = Color(0xFF857D6E), danger = Color(0xFFB33C27), dangerSoft = Color(0x14B33C27),
)

val DarkPalette = Palette(
    paper = Color(0xFF13120F), surface = Color(0xFF1E1C18), surface2 = Color(0xFF24211C), ink = Color(0xFFF4EEE3),
    text = Color(0xFFE2DBCD), muted = Color(0xFFACA392), line = Color(0xFF2D2924), signal = Color(0xFFFF6B3D),
    onSignal = Color(0xFF1C0C05), signalSoft = Color(0x21FF6B3D), teal = Color(0xFF3FC3B2), waiting = Color(0xFFF2B23C),
    paused = Color(0xFF9A9182), danger = Color(0xFFFF8C75), dangerSoft = Color(0x17FF8C75),
)

val LocalPalette = staticCompositionLocalOf { LightPalette }

object CoShareTheme {
    val colors: Palette
        @Composable get() = LocalPalette.current
}

/** Arabic, right to left, in the paper / ink / signal / teal colours — light or dark with the system. */
@Composable
fun CoShareTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val p = if (dark) DarkPalette else LightPalette
    val scheme = if (dark) {
        darkColorScheme(
            primary = p.signal, onPrimary = p.onSignal, primaryContainer = p.signalSoft, onPrimaryContainer = p.ink,
            secondary = p.teal, onSecondary = p.paper, background = p.paper, onBackground = p.ink, surface = p.surface,
            onSurface = p.ink, surfaceVariant = p.surface2, onSurfaceVariant = p.muted, surfaceContainer = p.surface,
            surfaceContainerHigh = p.surface2, surfaceContainerHighest = p.surface2, surfaceContainerLow = p.surface,
            outline = p.line, outlineVariant = p.line, error = p.danger, onError = p.paper,
        )
    } else {
        lightColorScheme(
            primary = p.signal, onPrimary = p.onSignal, primaryContainer = p.signalSoft, onPrimaryContainer = p.ink,
            secondary = p.teal, onSecondary = Color.White, background = p.paper, onBackground = p.ink, surface = p.surface,
            onSurface = p.ink, surfaceVariant = p.surface2, onSurfaceVariant = p.muted, surfaceContainer = p.surface,
            surfaceContainerHigh = p.surface2, surfaceContainerHighest = p.surface2, surfaceContainerLow = p.surface,
            outline = p.line, outlineVariant = p.line, error = p.danger, onError = Color.White,
        )
    }
    CompositionLocalProvider(LocalPalette provides p, LocalLayoutDirection provides LayoutDirection.Rtl) {
        MaterialTheme(colorScheme = scheme, content = content)
    }
}
