package com.ehabk.coshare.ui

import android.icu.text.RelativeDateTimeFormatter
import android.icu.util.ULocale
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ehabk.coshare.core.EngineState
import com.ehabk.coshare.core.GroupInfo
import com.ehabk.coshare.core.Presence
import com.ehabk.coshare.core.TimeFormat
import kotlin.math.abs

// ---------------------------------------------------------------------------------------------- formatting

object Format {
    private val relative: RelativeDateTimeFormatter by lazy {
        RelativeDateTimeFormatter.getInstance(ULocale("ar"), null, RelativeDateTimeFormatter.Style.SHORT, android.icu.text.DisplayContext.CAPITALIZATION_NONE)
    }

    /** "الآن", "قبل ٥ د", … like the iPhone app. */
    fun ago(dateSeconds: Double): String {
        val seconds = System.currentTimeMillis() / 1000.0 - dateSeconds
        if (seconds < 10) return "الآن"
        val (value, unit) = when {
            seconds < 60 -> seconds to RelativeDateTimeFormatter.RelativeUnit.SECONDS
            seconds < 3600 -> seconds / 60 to RelativeDateTimeFormatter.RelativeUnit.MINUTES
            seconds < 86400 -> seconds / 3600 to RelativeDateTimeFormatter.RelativeUnit.HOURS
            else -> seconds / 86400 to RelativeDateTimeFormatter.RelativeUnit.DAYS
        }
        return relative.format(abs(value).toInt().toDouble(), RelativeDateTimeFormatter.Direction.LAST, unit)
    }

    /** "125 KB", kept left to right inside Arabic text. */
    fun bytes(count: Int): String {
        val text = when {
            count < 1000 -> "$count B"
            count < 1_000_000 -> "${count / 1000} KB"
            else -> String.format(java.util.Locale.ROOT, "%.1f MB", count / 1_000_000.0)
        }
        return TimeFormat.isolate(text)
    }
}

// ---------------------------------------------------------------------------------------------- layout

/** A screen: top bar with title (and back), then scrolling content limited to a readable width on tablets. */
@Composable
fun Screen(
    title: String,
    onBack: (() -> Unit)? = null,
    actions: @Composable RowScope.() -> Unit = {},
    leading: @Composable (() -> Unit)? = null,
    scroll: Boolean = true,
    content: @Composable ColumnScope.() -> Unit,
) {
    val c = CoShareTheme.colors
    Column(Modifier.fillMaxSize().background(c.paper).statusBarsPadding()) {
        Row(
            Modifier.fillMaxWidth().heightIn(min = 56.dp).padding(horizontal = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (onBack != null) {
                IconButton(onClick = onBack) { Icon(Glyph.Back, "رجوع", tint = c.ink) }
            } else {
                Spacer(Modifier.width(10.dp))
            }
            leading?.invoke()
            Text(
                title, Modifier.weight(1f).padding(horizontal = 6.dp), fontSize = 20.sp, fontWeight = FontWeight.Bold,
                color = c.ink, maxLines = 1, overflow = TextOverflow.Ellipsis,
            )
            actions()
        }
        Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.TopCenter) {
            val inner = Modifier.widthIn(max = 640.dp).fillMaxWidth()
            if (scroll) {
                Column(
                    inner.verticalScroll(rememberScrollState()).imePadding().navigationBarsPadding().padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                    content = content,
                )
            } else {
                Column(inner, content = content)
            }
        }
    }
}

/** Rounded panel on the paper background. */
@Composable
fun Panel(modifier: Modifier = Modifier, padding: Dp = 12.dp, content: @Composable ColumnScope.() -> Unit) {
    val c = CoShareTheme.colors
    Column(
        modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(c.surface)
            .border(1.dp, c.line, RoundedCornerShape(14.dp)).padding(padding),
        content = content,
    )
}

@Composable
fun SectionTitle(text: String) {
    Text(text, Modifier.padding(horizontal = 4.dp), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = CoShareTheme.colors.muted)
}

@Composable
fun Hint(text: String, modifier: Modifier = Modifier, center: Boolean = false) {
    Text(
        text, modifier.padding(horizontal = 4.dp), fontSize = 13.sp, lineHeight = 19.sp, color = CoShareTheme.colors.muted,
        textAlign = if (center) TextAlign.Center else TextAlign.Start,
    )
}

@Composable
fun Dot(color: Color, size: Dp = 9.dp) {
    Box(Modifier.size(size).clip(CircleShape).background(color))
}

@Composable
fun Divider() = HorizontalDivider(color = CoShareTheme.colors.line, thickness = 1.dp)

@Composable
fun PrimaryButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, icon: ImageVector? = null, enabled: Boolean = true, color: Color? = null) {
    val c = CoShareTheme.colors
    Button(
        onClick = onClick, modifier = modifier.heightIn(min = 48.dp), enabled = enabled, shape = RoundedCornerShape(12.dp),
        colors = ButtonDefaults.buttonColors(containerColor = color ?: c.signal, contentColor = c.onSignal),
        contentPadding = PaddingValues(horizontal = 14.dp, vertical = 10.dp),
    ) {
        if (icon != null) {
            Icon(icon, null, Modifier.size(19.dp))
            Spacer(Modifier.width(8.dp))
        }
        Text(text, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
fun SecondaryButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, icon: ImageVector? = null, enabled: Boolean = true, color: Color? = null) {
    val c = CoShareTheme.colors
    OutlinedButton(
        onClick = onClick, modifier = modifier.heightIn(min = 48.dp), enabled = enabled, shape = RoundedCornerShape(12.dp),
        border = BorderStroke(1.dp, (color ?: c.signal).copy(alpha = 0.45f)),
        colors = ButtonDefaults.outlinedButtonColors(contentColor = color ?: c.ink, containerColor = c.surface),
        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 10.dp),
    ) {
        if (icon != null) {
            Icon(icon, null, Modifier.size(19.dp), tint = color ?: c.signal)
            Spacer(Modifier.width(8.dp))
        }
        Text(text, fontWeight = FontWeight.Medium, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
fun LinkButton(text: String, onClick: () -> Unit, color: Color? = null) {
    TextButton(onClick = onClick) { Text(text, color = color ?: CoShareTheme.colors.signal, fontWeight = FontWeight.Medium) }
}

/** Big button with an icon and a one-line explanation (create / join, nearby / scan). */
@Composable
fun ActionTile(icon: ImageVector, title: String, subtitle: String, modifier: Modifier = Modifier, selected: Boolean = false, onClick: () -> Unit) {
    val c = CoShareTheme.colors
    val shape = RoundedCornerShape(14.dp)
    Column(
        modifier.heightIn(min = 104.dp).clip(shape).background(if (selected) c.signal else c.surface)
            .border(1.dp, if (selected) c.signal else c.signal.copy(alpha = 0.35f), shape)
            .clickable(onClick = onClick).padding(horizontal = 8.dp, vertical = 14.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Icon(icon, null, Modifier.size(26.dp), tint = if (selected) c.onSignal else c.signal)
        Text(title, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = if (selected) c.onSignal else c.ink, textAlign = TextAlign.Center)
        Text(subtitle, fontSize = 12.sp, color = if (selected) c.onSignal.copy(alpha = 0.85f) else c.muted, textAlign = TextAlign.Center)
    }
}

@Composable
fun GroupBadge(size: Dp = 36.dp) {
    val c = CoShareTheme.colors
    Box(Modifier.size(size).clip(RoundedCornerShape(size * 0.28f)).background(c.signal), contentAlignment = Alignment.Center) {
        Icon(Glyph.Users, null, Modifier.size(size * 0.55f), tint = c.onSignal)
    }
}

/** A device: icon, name, what it is and how it's connected. */
@Composable
fun DeviceRow(icon: ImageVector, name: String, detail: String, dot: Color = CoShareTheme.colors.teal) {
    val c = CoShareTheme.colors
    Row(Modifier.fillMaxWidth().padding(vertical = 9.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, Modifier.size(26.dp), tint = c.signal)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f)) {
            Text(name, fontSize = 15.sp, color = c.ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text(detail, fontSize = 12.sp, color = c.muted)
        }
        Dot(dot, 8.dp)
    }
}

/** A coloured notice with an action (paused, quiet hours, a missing permission). */
@Composable
fun Banner(icon: ImageVector, text: String, button: String?, onClick: () -> Unit, tone: Color = CoShareTheme.colors.signal) {
    val c = CoShareTheme.colors
    Row(
        Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(tone.copy(alpha = 0.1f)).padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, Modifier.size(22.dp), tint = tone)
        Spacer(Modifier.width(10.dp))
        Text(text, Modifier.weight(1f), fontSize = 14.sp, lineHeight = 20.sp, color = c.ink)
        if (button != null) {
            Spacer(Modifier.width(8.dp))
            Button(
                onClick = onClick, shape = RoundedCornerShape(10.dp), contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp),
                colors = ButtonDefaults.buttonColors(containerColor = tone, contentColor = if (tone == c.signal) c.onSignal else Color.White),
            ) { Text(button, fontSize = 13.sp, fontWeight = FontWeight.SemiBold) }
        }
    }
}

/** A settings row: title (and detail) with something on the end. */
@Composable
fun SettingRow(title: String, detail: String? = null, onClick: (() -> Unit)? = null, end: @Composable () -> Unit = {}) {
    val c = CoShareTheme.colors
    Row(
        Modifier.fillMaxWidth().let { if (onClick != null) it.clickable(onClick = onClick) else it }.padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 15.sp, color = c.ink)
            if (detail != null) Text(detail, fontSize = 12.sp, lineHeight = 17.sp, color = c.muted)
        }
        Spacer(Modifier.width(10.dp))
        end()
    }
}

// ---------------------------------------------------------------------------------------------- status

/** "Active · 2 devices connected", "Active · waiting for devices", or paused — for one group. */
@Composable
fun GroupStatus(state: EngineState, group: GroupInfo) {
    val c = CoShareTheme.colors
    val (text, color) = when (state.presence) {
        Presence.Paused -> "متوقفة — CoShare موقوف على هالجهاز" to c.paused
        is Presence.Quiet -> "متوقفة — وقت الإيقاف" to c.paused
        Presence.Online -> when (val n = group.members.size) {
            0 -> "فعّالة · بانتظار أجهزة" to c.waiting
            1 -> "فعّالة · جهاز متصل" to c.teal
            else -> "فعّالة · $n أجهزة متصلة" to c.teal
        }
    }
    Row(verticalAlignment = Alignment.CenterVertically) {
        Dot(color, 7.dp)
        Spacer(Modifier.width(5.dp))
        Text(text, fontSize = 12.sp, color = c.muted, maxLines = 1)
    }
}
