package com.ehabk.coshare.ui

import android.app.StatusBarManager
import android.app.TimePickerDialog
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon as AndroidIcon
import android.os.Build
import android.os.PowerManager
import android.provider.Settings as AndroidSettings
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.net.toUri
import com.ehabk.coshare.R
import com.ehabk.coshare.SendTileService
import com.ehabk.coshare.SyncService
import com.ehabk.coshare.app
import com.ehabk.coshare.core.EngineState
import com.ehabk.coshare.core.LogEntry
import com.ehabk.coshare.core.QuietSchedule
import com.ehabk.coshare.core.Retention
import com.ehabk.coshare.core.SyncEngine
import com.ehabk.coshare.core.TimeFormat
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
private fun Toggle(checked: Boolean, onChange: (Boolean) -> Unit) {
    val c = CoShareTheme.colors
    Switch(checked, onChange, colors = SwitchDefaults.colors(checkedTrackColor = c.teal, checkedThumbColor = c.surface))
}

@Composable
fun SettingsScreen(engine: SyncEngine, state: EngineState, onBack: () -> Unit) {
    val c = CoShareTheme.colors
    val context = LocalContext.current
    val s = state.settings
    val ui = rememberCoroutineScope()
    Screen("الإعدادات", onBack = onBack) {
        // Device name: saved a moment after typing stops (renaming restarts the network).
        var name by remember { mutableStateOf(s.deviceName) }
        LaunchedEffect(name) {
            delay(800)
            if (name.trim().isNotEmpty() && name != engine.settings.deviceName) engine.update { deviceName = name.trim() }
        }
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            SectionTitle("اسم هذا الجهاز")
            Field(name, { name = it }, "بيظهر بهالاسم على أجهزتك التانية", "مثلاً: موبايل إيهاب")
        }

        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            SectionTitle("أوقات الإيقاف")
            Panel(padding = 14.dp) { QuietScheduleEditor(engine, state) }
        }

        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            SectionTitle("السجل والوقت")
            Panel(padding = 14.dp) {
                RetentionPicker(engine, s.historyRetentionHours)
                Divider()
                SettingRow("صيغة الوقت") {
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Chip("١٢ ساعة (AM/PM)", !s.use24Hour) { engine.update { use24Hour = false } }
                        Chip("٢٤ ساعة", s.use24Hour) { engine.update { use24Hour = true } }
                    }
                }
            }
            Hint("الحافظة والسجل، مع الصور ولقطات الشاشة المنسوخة، بينحذفوا تلقائياً بعد هالمدة (الحد الأقصى أسبوع).")
        }

        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            SectionTitle("التشغيل")
            Panel(padding = 14.dp) {
                SettingRow("العمل الدائم بالخلفية", "يبقي CoShare شغّالاً مع إشعار ثابت، فيستقبل من أجهزتك فوراً حتى والشاشة مطفية.") {
                    Toggle(s.keepRunning) { on ->
                        ui.launch {
                            engine.update { keepRunning = on }.join()
                            SyncService.sync(context)
                        }
                    }
                }
                Divider()
                SettingRow("التشغيل مع بدء الجهاز", "بعد إعادة تشغيل الموبايل بيرجع CoShare لحاله.") {
                    Toggle(s.startOnBoot) { on -> engine.update { startOnBoot = on } }
                }
                Divider()
                SettingRow("مزامنة الصور ولقطات الشاشة") { Toggle(s.syncImages) { on -> engine.update { syncImages = on } } }
            }
            if (!ignoringBatteryOptimizations(context)) {
                Panel(padding = 14.dp) {
                    SettingRow(
                        "استثناء CoShare من توفير البطارية",
                        "بعض الأجهزة بتوقف التطبيقات بالخلفية لتوفير البطارية. اختر CoShare ← «غير مقيّد» أو «عدم التحسين».",
                        onClick = { openBatterySettings(context) },
                    ) { Icon(Glyph.Chevron, null, Modifier.size(18.dp), tint = c.muted) }
                }
            }
        }

        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            SectionTitle("طرق الإرسال من هالجهاز")
            Panel(padding = 14.dp) {
                Text(
                    "أندرويد ما بيسمح لأي تطبيق يقرأ الحافظة وهو بالخلفية. لهيك، بعد ما تنسخ شي:",
                    fontSize = 14.sp, lineHeight = 20.sp, color = c.ink,
                )
                Column(Modifier.padding(top = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Bullet("افتح CoShare: بيبعت اللي نسخته لحاله.")
                    Bullet("أو اضغط «إرسال الحافظة» بالإشعار، أو بمربع الإعدادات السريعة (اسحب الشريط العلوي لتحت).")
                    Bullet("أو من أي تطبيق: «مشاركة» ← «إرسال لأجهزتي»، أو حدّد نص ← «إرسال لأجهزتي».")
                    Bullet("اللي بيوصلك من أجهزتك التانية بينلصق هون فوراً، بدون أي خطوة.")
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    Box(Modifier.padding(top = 10.dp)) {
                        SecondaryButton("إضافة «إرسال الحافظة» للإعدادات السريعة", { requestTile(context) }, Modifier.fillMaxWidth(), Glyph.Plus)
                    }
                }
            }
        }

        Panel(padding = 4.dp) {
            Column(Modifier.padding(horizontal = 10.dp)) {
                SettingRow("إعادة الاتصال", onClick = { engine.restartNetwork() }) { Icon(Glyph.Refresh, null, Modifier.size(18.dp), tint = c.signal) }
                Divider()
                var confirm by remember { mutableStateOf(false) }
                SettingRow(if (confirm) "اضغط مرة تانية للتأكيد" else "مسح السجل والحافظة", onClick = {
                    if (confirm) {
                        engine.clearHistory()
                        confirm = false
                    } else {
                        confirm = true
                    }
                }) { Icon(Glyph.Trash, null, Modifier.size(18.dp), tint = c.danger) }
            }
        }

        val version = remember { runCatching { context.packageManager.getPackageInfo(context.packageName, 0).versionName }.getOrNull() ?: "" }
        Hint("CoShare لأندرويد $version · بدون خوادم وبدون حسابات: كل شي بيضل على شبكتك ومشفّر بكلمة سر المجموعة.", Modifier.fillMaxWidth(), center = true)
    }
}

@Composable
private fun Bullet(text: String) {
    val c = CoShareTheme.colors
    Row {
        Text("•", fontSize = 14.sp, color = c.signal, modifier = Modifier.padding(end = 8.dp))
        Text(text, fontSize = 14.sp, lineHeight = 20.sp, color = c.muted)
    }
}

@Composable
fun Chip(text: String, selected: Boolean, onClick: () -> Unit) {
    val c = CoShareTheme.colors
    Text(
        text,
        Modifier.clip(RoundedCornerShape(50)).background(if (selected) c.signal else c.muted.copy(alpha = 0.14f)).clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 7.dp),
        color = if (selected) c.onSignal else c.ink, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, maxLines = 1,
    )
}

@Composable
private fun RetentionPicker(engine: SyncEngine, hours: Int) {
    val c = CoShareTheme.colors
    var open by remember { mutableStateOf(false) }
    Box {
        SettingRow("الاحتفاظ بالسجل", onClick = { open = true }) {
            Text(Retention.label(hours), fontSize = 14.sp, color = c.signal, fontWeight = FontWeight.Medium)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            Retention.OPTIONS.forEach { (value, label) ->
                DropdownMenuItem(
                    text = { Text(if (value == Retention.DEFAULT_HOURS) "$label (افتراضي)" else label) },
                    onClick = {
                        open = false
                        engine.update { historyRetentionHours = value }
                    },
                )
            }
        }
    }
}

/** Days + from/to for the quiet hours. */
@Composable
private fun QuietScheduleEditor(engine: SyncEngine, state: EngineState) {
    val c = CoShareTheme.colors
    val context = LocalContext.current
    val s = state.settings
    val schedule = s.quietSchedule
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SettingRow("إيقاف تلقائي بأوقات محددة") { Toggle(s.quietEnabled) { on -> engine.update { quietEnabled = on } } }
        if (s.quietEnabled) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                (1..7).forEach { day ->
                    val on = day in schedule.days
                    Text(
                        QuietSchedule.DAY_NAMES[day] ?: "",
                        Modifier.weight(1f).clip(RoundedCornerShape(50)).background(if (on) c.signal else c.muted.copy(alpha = 0.14f))
                            .clickable {
                                engine.update { quietSchedule = quietSchedule.copy(days = if (on) quietSchedule.days - day else quietSchedule.days + day) }
                            }.padding(vertical = 8.dp),
                        color = if (on) c.onSignal else c.ink, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center, maxLines = 1,
                    )
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("من", fontSize = 14.sp, color = c.ink)
                TimeButton(context, schedule.start, s.use24Hour) { minutes -> engine.update { quietSchedule = quietSchedule.copy(start = minutes) } }
                Text("إلى", fontSize = 14.sp, color = c.ink)
                TimeButton(context, schedule.end, s.use24Hour) { minutes -> engine.update { quietSchedule = quietSchedule.copy(end = minutes) } }
            }
            Hint("بهالأوقات CoShare بيوقف كلياً على هالجهاز: ما بيقرأ الحافظة، ولا بيبعت ولا بيستقبل، ولا بيظهر على الشبكة. وأجهزتك التانية بتعرف جدوله، فما بتحاول تتصل فيه.")
        }
    }
}

@Composable
private fun TimeButton(context: Context, minutes: Int, h24: Boolean, onPick: (Int) -> Unit) {
    val c = CoShareTheme.colors
    val ms = java.time.LocalDate.now().atStartOfDay(java.time.ZoneId.systemDefault()).plusMinutes(minutes.toLong()).toInstant().toEpochMilli()
    Text(
        TimeFormat.clock(ms, h24),
        Modifier.clip(RoundedCornerShape(10.dp)).background(c.muted.copy(alpha = 0.12f))
            .clickable { TimePickerDialog(context, { _, h, m -> onPick(h * 60 + m) }, minutes / 60, minutes % 60, h24).show() }
            .padding(horizontal = 14.dp, vertical = 8.dp),
        fontSize = 15.sp, color = c.ink, fontWeight = FontWeight.Medium,
    )
}

private fun ignoringBatteryOptimizations(context: Context): Boolean =
    context.getSystemService(PowerManager::class.java)?.isIgnoringBatteryOptimizations(context.packageName) != false

private fun openBatterySettings(context: Context) {
    val intents = listOf(
        Intent(AndroidSettings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS),
        Intent(AndroidSettings.ACTION_APPLICATION_DETAILS_SETTINGS, "package:${context.packageName}".toUri()),
    )
    for (intent in intents) {
        if (runCatching { context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }.isSuccess) return
    }
}

private fun requestTile(context: Context) {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return
    val manager = context.getSystemService(StatusBarManager::class.java) ?: return
    manager.requestAddTileService(
        ComponentName(context, SendTileService::class.java),
        context.getString(R.string.tile_label),
        AndroidIcon.createWithResource(context, R.drawable.ic_stat_coshare),
        context.mainExecutor,
    ) { result ->
        val text = when (result) {
            StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED, StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED ->
                "صار «إرسال الحافظة» بالإعدادات السريعة"
            else -> null
        }
        text?.let { context.app.toast(it) }
    }
}

@Composable
fun LogScreen(state: EngineState, onBack: () -> Unit) {
    val c = CoShareTheme.colors
    Screen("سجل النشاط", onBack = onBack) {
        if (state.log.isEmpty()) Text("السجل فارغ", color = c.muted, fontSize = 14.sp)
        Panel(padding = 10.dp) {
            state.log.forEach { LogRow(it, state.settings.use24Hour) }
        }
    }
}

@Composable
private fun LogRow(entry: LogEntry, h24: Boolean) {
    val c = CoShareTheme.colors
    Row(Modifier.padding(vertical = 4.dp)) {
        Text(TimeFormat.time((entry.date * 1000).toLong(), h24), fontSize = 12.sp, color = c.muted)
        Text(entry.text, Modifier.padding(start = 8.dp), fontSize = 13.sp, color = if (entry.isError) c.danger else c.ink)
    }
}
