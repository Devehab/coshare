package com.ehabk.coshare.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.vector.addPathNodes
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.cos
import kotlin.math.sin

/** Line icons on a 24-unit grid (2-unit strokes, round ends), drawn here so the app needs no icon library. */
object Glyph {
    private fun icon(name: String, vararg paths: String, autoMirror: Boolean = false): ImageVector =
        ImageVector.Builder(name, 24.dp, 24.dp, 24f, 24f, autoMirror = autoMirror).apply {
            for (d in paths) {
                addPath(
                    pathData = addPathNodes(d), fill = null, stroke = SolidColor(Color.Black), strokeLineWidth = 2f,
                    strokeLineCap = StrokeCap.Round, strokeLineJoin = StrokeJoin.Round,
                )
            }
        }.build()

    private fun rect(x: Float, y: Float, w: Float, h: Float, r: Float) =
        "M${x + r} ${y}H${x + w - r}A$r $r 0 0 1 ${x + w} ${y + r}V${y + h - r}A$r $r 0 0 1 ${x + w - r} ${y + h}" +
            "H${x + r}A$r $r 0 0 1 $x ${y + h - r}V${y + r}A$r $r 0 0 1 ${x + r} ${y}Z"

    private fun circle(cx: Float, cy: Float, r: Float) = "M${cx - r} ${cy}A$r $r 0 1 0 ${cx + r} ${cy}A$r $r 0 1 0 ${cx - r} ${cy}Z"

    /** A gear: eight teeth around a ring. */
    private fun gear(): String {
        val sb = StringBuilder()
        val teeth = 8
        for (i in 0 until teeth * 4) {
            val angle = Math.PI * 2 * i / (teeth * 4) - Math.PI / 2
            val r = if (i % 4 == 0 || i % 4 == 1) 10.0 else 7.6
            val x = 12 + r * cos(angle)
            val y = 12 + r * sin(angle)
            sb.append(if (i == 0) "M" else "L").append("%.2f %.2f".format(java.util.Locale.ROOT, x, y))
        }
        return sb.append("Z").toString()
    }

    val Settings = icon("settings", gear(), circle(12f, 12f, 3f))
    val Log = icon("log", "M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01")
    val Phone = icon("phone", rect(6f, 2f, 12f, 20f, 2.5f), "M11 18h2")
    val Tablet = icon("tablet", rect(4f, 2f, 16f, 20f, 2.5f), "M11 18h2")
    val Laptop = icon("laptop", "M20 16V7a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v9", "M2 19.5h20l-1.5-3.5h-17z")
    val Desktop = icon("desktop", rect(2f, 3f, 20f, 13f, 2f), "M8 21h8M12 16v5")
    val Terminal = icon("terminal", rect(2f, 4f, 20f, 16f, 2f), "M6 9l3 3-3 3M12 15h5")
    val Device = icon("device", rect(3f, 4f, 18f, 13f, 2f), "M9 21h6")
    val Users = icon(
        "users", "M16 20v-1.5a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4V20", circle(9f, 7.5f, 3.5f),
        "M22 20v-1.5a4 4 0 0 0-3-3.87", "M16 4.13a3.5 3.5 0 0 1 0 6.75",
    )
    val UserPlus = icon("userPlus", "M15 20v-1.5a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4V20", circle(8.5f, 7.5f, 3.5f), "M19 8v6M16 11h6")
    val Plus = icon("plus", "M12 5v14M5 12h14")
    val PlusCircle = icon("plusCircle", circle(12f, 12f, 10f), "M12 8v8M8 12h8")
    val Qr = icon(
        "qr", rect(3f, 3f, 7f, 7f, 1f), rect(14f, 3f, 7f, 7f, 1f), rect(3f, 14f, 7f, 7f, 1f),
        "M14 14h3v3h-3zM20 14v.01M14 20h.01M17 20h4v-3M6.5 6.5h.01M17.5 6.5h.01M6.5 17.5h.01",
    )
    val Scan = icon("scan", "M3 8V5a2 2 0 0 1 2-2h3M16 3h3a2 2 0 0 1 2 2v3M21 16v3a2 2 0 0 1-2 2h-3M8 21H5a2 2 0 0 1-2-2v-3", "M7 12h10")
    val Radar = icon("radar", circle(12f, 12f, 2f), "M16.24 7.76a6 6 0 0 1 0 8.49M7.76 16.24a6 6 0 0 1 0-8.49M19.07 4.93a10 10 0 0 1 0 14.14M4.93 19.07a10 10 0 0 1 0-14.14")
    val Send = icon("send", "M12 19V5M5 12l7-7 7 7", "M5 21h14")
    val Download = icon("download", "M12 3v12M5 10l7 7 7-7", "M5 21h14")
    val Check = icon("check", "M20 6L9 17l-5-5")
    val CheckCircle = icon("checkCircle", circle(12f, 12f, 10f), "M8 12.5l2.5 2.5L16 9.5")
    val Back = icon("back", "M19 12H5M12 19l-7-7 7-7", autoMirror = true)
    val Chevron = icon("chevron", "M9 18l6-6-6-6", autoMirror = true)
    val Trash = icon("trash", "M3 6h18M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2M10 11v6M14 11v6")
    val Leave = icon("leave", "M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9", autoMirror = true)
    val Eye = icon("eye", "M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12z", circle(12f, 12f, 3f))
    val EyeOff = icon("eyeOff", "M2 12s3.5-7 10-7c2 0 3.7.6 5.1 1.5M22 12s-3.5 7-10 7c-2 0-3.7-.6-5.1-1.5", "M3 3l18 18", "M9.9 9.9a3 3 0 0 0 4.2 4.2")
    val Pause = icon("pause", "M9 5v14M15 5v14")
    val Moon = icon("moon", "M12 3a6 6 0 0 0 9 9 9 9 0 1 1-9-9z")
    val Bolt = icon("bolt", "M13 2L3 14h9l-1 8 10-12h-9z")
    val Info = icon("info", circle(12f, 12f, 10f), "M12 16v-4M12 8h.01")
    val Warning = icon("warning", "M10.3 3.9L1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z", "M12 9v4M12 17h.01")
    val Image = icon("image", rect(3f, 3f, 18f, 18f, 2f), circle(9f, 9f, 2f), "M21 15l-3.1-3.1a2 2 0 0 0-2.8 0L6 21")
    val Text = icon("text", "M17 6H3M21 12H3M15 18H3")
    val Up = icon("up", "M7 17L17 7M8 7h9v9")
    val Down = icon("down", "M17 7L7 17M16 17H7V8")
    val Refresh = icon("refresh", "M21 12a9 9 0 1 1-2.64-6.36L21 8", "M21 3v5h-5")
    val Wifi = icon("wifi", "M12 20h.01M2 8.8a15 15 0 0 1 20 0M5 12.9a10 10 0 0 1 14 0M8.5 16.4a5 5 0 0 1 7 0")
}

/** The icon for a device's platform, as the Apple and desktop apps show it. */
fun platformGlyph(platform: String): ImageVector = when (platform) {
    "mac" -> Glyph.Laptop
    "iphone", "android" -> Glyph.Phone
    "ipad" -> Glyph.Tablet
    "windows" -> Glyph.Desktop
    "linux" -> Glyph.Terminal
    else -> Glyph.Device
}

fun platformName(platform: String): String = when (platform) {
    "mac" -> "ماك"
    "iphone" -> "آيفون"
    "ipad" -> "آيباد"
    "windows" -> "ويندوز"
    "linux" -> "لينكس"
    "android" -> "أندرويد"
    else -> "جهاز"
}

/** The CoShare mark (website/assets/logo.svg): two paper documents on the signal square. */
@Composable
fun BrandMark(modifier: Modifier = Modifier, size: Dp = 28.dp) {
    Canvas(modifier.size(size)) {
        val s = this.size.width / 64f
        val vermilion = Color(0xFFD24A22)
        val paper = Color(0xFFF5F0E8)
        fun p(x: Float, y: Float) = Offset(x * s, y * s)
        drawRoundRect(vermilion, size = Size(64 * s, 64 * s), cornerRadius = CornerRadius(16 * s))
        drawRoundRect(paper.copy(alpha = 0.5f), topLeft = p(25f, 12f), size = Size(24 * s, 31 * s), cornerRadius = CornerRadius(5 * s))
        val front = Path().apply {
            moveTo(19.5f * s, 21f * s)
            lineTo(32f * s, 21f * s)
            lineTo(40f * s, 29f * s)
            lineTo(40f * s, 48f * s)
            quadraticTo(40f * s, 52f * s, 36f * s, 52f * s)
            lineTo(19.5f * s, 52f * s)
            quadraticTo(15.5f * s, 52f * s, 15.5f * s, 48f * s)
            lineTo(15.5f * s, 25f * s)
            quadraticTo(15.5f * s, 21f * s, 19.5f * s, 21f * s)
            close()
        }
        drawPath(front, paper)
        val fold = Path().apply {
            moveTo(32f * s, 21f * s)
            lineTo(32f * s, 26.5f * s)
            quadraticTo(32f * s, 29f * s, 34.5f * s, 29f * s)
            lineTo(40f * s, 29f * s)
        }
        drawPath(fold, vermilion, style = Stroke(2.4f * s, join = StrokeJoin.Round))
        drawLine(vermilion, p(22f, 38.5f), p(33f, 38.5f), 2.6f * s, StrokeCap.Round)
        drawLine(vermilion, p(22f, 44f), p(29f, 44f), 2.6f * s, StrokeCap.Round)
    }
}
