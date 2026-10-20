package com.ehabk.coshare.ui

import android.graphics.BitmapFactory
import android.os.Build
import android.util.LruCache
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ehabk.coshare.core.ClipKind
import com.ehabk.coshare.core.Direction
import com.ehabk.coshare.core.EngineState
import com.ehabk.coshare.core.HistoryItem
import com.ehabk.coshare.core.Presence
import com.ehabk.coshare.core.Retention
import com.ehabk.coshare.core.SyncEngine
import com.ehabk.coshare.core.TimeFormat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/** What the main screen can ask the activity for. */
class HomeActions(
    val sendClipboard: () -> Unit,
    val pickImage: () -> Unit,
    val openGroups: (Route?) -> Unit,
    val openSettings: () -> Unit,
    val openLog: () -> Unit,
    val fixLocalNetwork: () -> Unit,
    val fixNotifications: () -> Unit,
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(engine: SyncEngine, state: EngineState, permissions: PermissionState, actions: HomeActions) {
    val c = CoShareTheme.colors
    val scope = rememberCoroutineScope()
    var refreshing by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    Screen(
        title = "CoShare",
        leading = { BrandMark(size = 28.dp) },
        actions = {
            IconButton(onClick = actions.openLog) { Icon(Glyph.Log, "سجل النشاط", tint = c.ink) }
            IconButton(onClick = actions.openSettings) { Icon(Glyph.Settings, "الإعدادات", tint = c.ink) }
        },
        scroll = false,
    ) {
        PullToRefreshBox(
            modifier = Modifier.fillMaxSize(),
            isRefreshing = refreshing,
            onRefresh = {
                refreshing = true
                scope.launch {
                    engine.refreshDiscovery()
                    engine.pullLatest()
                    refreshing = false
                }
            },
        ) {
            Column(
                Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).navigationBarsPadding().padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                StatusPanel(engine, state)
                if (permissions.localNetworkMissing) {
                    Banner(
                        Glyph.Warning, "CoShare بحاجة لإذن «الأجهزة القريبة» ليوصل لأجهزتك على نفس الشبكة. بدونه ما في مزامنة.",
                        "السماح", actions.fixLocalNetwork, tone = c.danger,
                    )
                }
                when (val p = state.presence) {
                    Presence.Paused -> Banner(Glyph.Pause, "متوقف — CoShare منفصل تماماً عن الشبكة", "استئناف", { engine.resumeToday() })
                    is Presence.Quiet -> Banner(
                        Glyph.Moon, "وقت الإيقاف حتى ${TimeFormat.clock(p.untilMs, state.settings.use24Hour)} — منفصل تماماً عن الشبكة",
                        "استئناف اليوم", { engine.resumeToday() },
                    )
                    Presence.Online -> {}
                }
                BackgroundPanel(state, permissions, actions)
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    SecondaryButton("إرسال الحافظة", actions.sendClipboard, Modifier.weight(1f), Glyph.Send, enabled = !busy)
                    SecondaryButton("جلب آخر نسخ", {
                        busy = true
                        scope.launch {
                            engine.pullLatest()
                            busy = false
                        }
                    }, Modifier.weight(1f), Glyph.Download, enabled = !busy)
                }
                DevicesSection(state, actions)
                HistorySection(engine, state, actions)
            }
        }
    }
}

@Composable
private fun StatusPanel(engine: SyncEngine, state: EngineState) {
    val c = CoShareTheme.colors
    val online = state.presence == Presence.Online
    val title = when (val p = state.presence) {
        Presence.Paused -> "متوقف — منفصل عن الشبكة"
        is Presence.Quiet -> "وقت الإيقاف حتى ${TimeFormat.clock(p.untilMs, state.settings.use24Hour)}"
        Presence.Online -> when (val n = state.connected.size) {
            0 -> "بانتظار أجهزة على نفس الشبكة…"
            else -> "متصل بـ $n ${if (n == 1) "جهاز" else "أجهزة"}"
        }
    }
    Panel {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Dot(if (!online) c.paused else if (state.connected.isEmpty()) c.waiting else c.teal, 11.dp)
            Spacer(Modifier.width(12.dp))
            Column(Modifier.weight(1f)) {
                Text(title, fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = c.ink)
                if (state.peers.isNotEmpty()) {
                    Text(state.peers.joinToString("، ") { it.name }, fontSize = 12.sp, color = c.muted, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
            }
            Switch(
                checked = state.presence != Presence.Paused,
                onCheckedChange = { engine.setPaused(!it) },
                colors = SwitchDefaults.colors(checkedTrackColor = c.teal, checkedThumbColor = c.surface),
            )
        }
    }
}

/** Whether CoShare keeps running, and the plain truth about Android's clipboard rule. */
@Composable
private fun BackgroundPanel(state: EngineState, permissions: PermissionState, actions: HomeActions) {
    val c = CoShareTheme.colors
    val keep = state.settings.keepRunning
    Panel {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(if (keep) Glyph.Bolt else Glyph.Moon, null, Modifier.size(22.dp), tint = if (keep) c.teal else c.waiting)
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(if (keep) "يعمل بالخلفية باستمرار" else "يعمل فقط والتطبيق مفتوح", fontSize = 14.sp, color = c.ink)
                if (!keep) Text("فعّل «العمل الدائم بالخلفية» من الإعدادات", fontSize = 12.sp, color = c.muted)
                else if (permissions.notificationsMissing) Text("الإشعار مخفي — اسمح بالإشعارات ليظهر زر «إرسال الحافظة»", fontSize = 12.sp, color = c.muted)
            }
            if (keep && permissions.notificationsMissing) LinkButton("السماح", actions.fixNotifications)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            Spacer(Modifier.size(10.dp))
            Divider()
            Spacer(Modifier.size(10.dp))
            Row(verticalAlignment = Alignment.Top) {
                Icon(Glyph.Info, null, Modifier.size(20.dp), tint = c.signal)
                Spacer(Modifier.width(10.dp))
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("اللي بتنسخه على أجهزتك التانية بيوصل هون وبينلصق فوراً.", fontSize = 13.sp, lineHeight = 19.sp, color = c.ink)
                    Text(
                        "بس أندرويد ما بيسمح لأي تطبيق يقرأ الحافظة وهو بالخلفية، فاللي بتنسخه على هالجهاز بينبعت لما تفتح CoShare، " +
                            "أو لما تضغط «إرسال الحافظة» من الإشعار أو من لوحة الإعدادات السريعة، أو لما تختار «مشاركة ← إرسال لأجهزتي».",
                        fontSize = 13.sp, lineHeight = 19.sp, color = c.muted,
                    )
                }
            }
        }
    }
}

@Composable
private fun DevicesSection(state: EngineState, actions: HomeActions) {
    val c = CoShareTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SectionTitle("أجهزتي")
        if (state.groups.isEmpty()) {
            Panel(padding = 14.dp) {
                Text("هالجهاز مش بأي مجموعة لهلق", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = c.ink)
                Spacer(Modifier.size(6.dp))
                Text("أنشئ مجموعة لأجهزتك، أو انضم لمجموعة موجودة على نفس الشبكة أو برمز QR.", fontSize = 14.sp, color = c.muted)
                Spacer(Modifier.size(12.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    PrimaryButton("إنشاء مجموعة", { actions.openGroups(Route.Create) }, Modifier.weight(1f), Glyph.PlusCircle)
                    SecondaryButton("انضمام", { actions.openGroups(Route.Join) }, Modifier.weight(1f), Glyph.UserPlus)
                }
            }
            if (state.nearby.isNotEmpty()) Hint("في ${state.nearby.size} مجموعة على نفس الشبكة — اضغط «انضمام».")
        } else {
            Panel(padding = 4.dp) {
                Column(Modifier.padding(horizontal = 10.dp)) {
                    state.connected.forEach { peer ->
                        DeviceRow(platformGlyph(peer.platform), peer.name, platformName(peer.platform) + " · " + if (peer.isDirect) "اتصال مباشر" else "على نفس الشبكة")
                        Divider()
                    }
                    SettingRow("المجموعات", state.groups.joinToString("، ") { it.name }, onClick = { actions.openGroups(null) }) {
                        Icon(Glyph.Chevron, null, Modifier.size(18.dp), tint = c.muted)
                    }
                }
            }
        }
    }
}

@Composable
private fun HistorySection(engine: SyncEngine, state: EngineState, actions: HomeActions) {
    val c = CoShareTheme.colors
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.weight(1f)) { SectionTitle("الحافظة") }
            LinkButton("إرسال صورة", actions.pickImage)
        }
        Panel(padding = 4.dp) {
            if (state.history.isEmpty()) {
                Text("لا شيء بعد — انسخ أي نص أو صورة على أي جهاز وسيظهر هنا.", Modifier.padding(12.dp), fontSize = 14.sp, color = c.muted)
            } else {
                Column(Modifier.padding(horizontal = 10.dp)) {
                    state.history.take(200).forEachIndexed { index, item ->
                        if (index > 0) Divider()
                        HistoryRow(engine, item, state.blobDir, state.settings.use24Hour)
                    }
                }
            }
        }
        Hint("اضغط على أي عنصر لنسخه من جديد، وضغطة مطوّلة لحذفه.")
        Hint("يُحفظ آخر ${Retention.label(state.settings.historyRetentionHours)} فقط، والأقدم يُحذف تلقائياً مع صوره.")
    }
}

private val thumbnails = LruCache<String, ImageBitmap>(80)

@Composable
private fun HistoryRow(engine: SyncEngine, item: HistoryItem, blobDir: File, h24: Boolean) {
    val c = CoShareTheme.colors
    var copied by remember { mutableStateOf(false) }
    var menu by remember { mutableStateOf(false) }
    LaunchedEffect(copied) {
        if (copied) {
            delay(1200)
            copied = false
        }
    }
    Box {
        Row(
            Modifier.fillMaxWidth().combinedClickable(
                onClick = {
                    engine.copyItem(item.id)
                    copied = true
                },
                onLongClick = { menu = true },
            ).padding(vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Thumbnail(item, blobDir)
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                val title = when (item.kind) {
                    ClipKind.TEXT -> item.text?.trim()?.ifEmpty { "(مسافات فارغة)" } ?: ""
                    ClipKind.IMAGE -> "صورة · ${Format.bytes(item.byteCount)}"
                }
                Text(title, fontSize = 14.sp, color = c.ink, maxLines = 3, overflow = TextOverflow.Ellipsis)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(if (item.direction == Direction.SENT) Glyph.Up else Glyph.Down, null, Modifier.size(13.dp), tint = c.muted)
                    Spacer(Modifier.width(4.dp))
                    val source = when (item.direction) {
                        Direction.SENT -> when (val n = item.deliveredTo) {
                            null -> "من هذا الجهاز"
                            0 -> "من هذا الجهاز (لم يصل لأحد)"
                            else -> "من هذا الجهاز ← $n أجهزة"
                        }
                        Direction.RECEIVED -> "من ${item.deviceName}"
                    }
                    Text(
                        "$source · ${TimeFormat.clock((item.date * 1000).toLong(), h24)} · ${Format.ago(item.date)}",
                        fontSize = 12.sp, color = c.muted, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            if (copied) {
                Spacer(Modifier.width(8.dp))
                Icon(Glyph.CheckCircle, "تم النسخ", Modifier.size(22.dp), tint = c.teal)
            }
        }
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            DropdownMenuItem(text = { Text("نسخ") }, onClick = {
                menu = false
                engine.copyItem(item.id)
                copied = true
            })
            DropdownMenuItem(text = { Text("حذف", color = c.danger) }, onClick = {
                menu = false
                engine.deleteItem(item.id)
            })
        }
    }
}

/** Small, cached thumbnails decoded at reduced size, so big screenshots never load in full. */
@Composable
private fun Thumbnail(item: HistoryItem, blobDir: File) {
    val c = CoShareTheme.colors
    val file = item.blobName?.let { File(blobDir, it) }
    val image by produceState<ImageBitmap?>(file?.path?.let { thumbnails.get(it) }, file?.path) {
        if (value == null && file != null && item.kind == ClipKind.IMAGE) {
            value = withContext(Dispatchers.IO) {
                runCatching {
                    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                    BitmapFactory.decodeFile(file.path, bounds)
                    var sample = 1
                    while (bounds.outWidth / (sample * 2) >= 128 && bounds.outHeight / (sample * 2) >= 128) sample *= 2
                    BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample })?.asImageBitmap()
                }.getOrNull()
            }?.also { thumbnails.put(file.path, it) }
        }
    }
    val shape = RoundedCornerShape(8.dp)
    Box(Modifier.size(44.dp).clip(shape).background(c.muted.copy(alpha = 0.12f)), contentAlignment = Alignment.Center) {
        val bitmap = image
        if (bitmap != null) {
            Image(bitmap, null, Modifier.size(44.dp), contentScale = ContentScale.Crop)
        } else {
            Icon(if (item.kind == ClipKind.IMAGE) Glyph.Image else Glyph.Text, null, Modifier.size(20.dp), tint = c.muted)
        }
    }
}
