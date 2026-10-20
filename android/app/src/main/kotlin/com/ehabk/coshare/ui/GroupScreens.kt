package com.ehabk.coshare.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.ehabk.coshare.core.EngineState
import com.ehabk.coshare.core.GroupInfo
import com.ehabk.coshare.core.GroupMembership
import com.ehabk.coshare.core.NearbyGroup
import com.ehabk.coshare.core.Presence
import com.ehabk.coshare.core.SyncEngine
import com.ehabk.coshare.core.Wire
import kotlinx.coroutines.launch

/** Root of "Groups": create / join at the top, then this device's groups. */
@Composable
fun GroupsHome(state: EngineState, open: (Route) -> Unit, onBack: () -> Unit) {
    val c = CoShareTheme.colors
    Screen("المجموعات", onBack = onBack) {
        if (state.groups.isEmpty()) {
            Panel(padding = 14.dp) {
                Text("ابدأ من هون", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = c.ink)
                Spacer(Modifier.size(6.dp))
                Text("هالجهاز مش بأي مجموعة لهلق. أنشئ مجموعة جديدة لأجهزتك، أو انضم لمجموعة موجودة.", fontSize = 14.sp, color = c.muted)
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            ActionTile(Glyph.PlusCircle, "إنشاء مجموعة", "مجموعة جديدة بكلمة سر", Modifier.weight(1f)) { open(Route.Create) }
            ActionTile(Glyph.UserPlus, "انضمام لمجموعة", "من الشبكة أو برمز QR", Modifier.weight(1f)) { open(Route.Join) }
        }
        if (state.groups.isEmpty() && state.nearby.isNotEmpty()) {
            Hint("في ${state.nearby.size} مجموعة ظاهرة على هالشبكة — اضغط «انضمام لمجموعة».")
        }
        if (state.groups.isNotEmpty()) {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                SectionTitle("مجموعاتي (${state.groups.size})")
                Panel(padding = 4.dp) {
                    state.groups.forEachIndexed { index, group ->
                        if (index > 0) Divider()
                        Row(
                            Modifier.fillMaxWidth().clickable { open(Route.Group(group.id)) }.padding(horizontal = 10.dp, vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            GroupBadge(36.dp)
                            Spacer(Modifier.width(12.dp))
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                                Text(group.name, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = c.ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                GroupStatus(state, group)
                            }
                            Icon(Glyph.Chevron, null, Modifier.size(18.dp), tint = c.muted)
                        }
                    }
                }
                Hint("اضغط على المجموعة لتشوف أجهزتها، أو لتضيف جهاز جديد برمز QR. الجهاز ممكن يكون بأكتر من مجموعة، وكل نسخ بيوصل لكل مجموعاته.")
            }
        }
    }
}

@Composable
fun Field(value: String, onChange: (String) -> Unit, label: String, placeholder: String, password: Boolean = false, onDone: () -> Unit = {}) {
    val c = CoShareTheme.colors
    var visible by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
        Text(label, fontSize = 13.sp, color = c.muted)
        OutlinedTextField(
            value = value, onValueChange = onChange, modifier = Modifier.fillMaxWidth(), singleLine = true,
            placeholder = { Text(placeholder, color = c.muted.copy(alpha = 0.7f)) },
            visualTransformation = if (password && !visible) PasswordVisualTransformation() else VisualTransformation.None,
            keyboardOptions = KeyboardOptions(
                keyboardType = if (password) KeyboardType.Password else KeyboardType.Text,
                imeAction = if (password) ImeAction.Done else ImeAction.Next,
            ),
            keyboardActions = KeyboardActions(onDone = { onDone() }),
            trailingIcon = if (password) {
                { IconButton(onClick = { visible = !visible }) { Icon(if (visible) Glyph.EyeOff else Glyph.Eye, "إظهار كلمة السر", tint = c.muted) } }
            } else null,
            shape = RoundedCornerShape(10.dp),
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = c.signal, unfocusedBorderColor = c.line, cursorColor = c.signal,
                focusedContainerColor = c.surface, unfocusedContainerColor = c.surface,
            ),
        )
    }
}

/** Name + password → a new private group, then straight to its QR code. */
@Composable
fun CreateGroupScreen(engine: SyncEngine, onCreated: (GroupMembership) -> Unit, onBack: () -> Unit) {
    val c = CoShareTheme.colors
    val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    val create = {
        scope.launch {
            try {
                onCreated(engine.createGroup(name, password))
            } catch (e: Exception) {
                error = e.message
            }
        }
        Unit
    }
    Screen("إنشاء مجموعة", onBack = onBack) {
        Panel(padding = 14.dp) {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Field(name, { name = it }, "اسم المجموعة", "مثلاً: أجهزة إيهاب")
                Field(password, { password = it }, "كلمة السر", "${Wire.MIN_PASSWORD} أحرف أو أكثر", password = true, onDone = create)
                PrimaryButton("إنشاء المجموعة", create, Modifier.fillMaxWidth(), enabled = name.isNotBlank() && password.isNotEmpty())
                error?.let { Text(it, fontSize = 13.sp, color = c.danger) }
            }
        }
        Hint("بعد الإنشاء بيطلعلك رمز QR: امسحه من أجهزتك التانية لتنضم. كل جهاز بالمجموعة بيضل فيها حتى بعد إعادة التشغيل أو تغيير الشبكة، وكلمة السر بتشفّر كل شي بينكم.")
    }
}

/** Join: pick a group seen on the network (with its password), or scan an invite QR code. */
@Composable
fun JoinGroupScreen(engine: SyncEngine, state: EngineState, onInvite: (String) -> Unit, onJoined: (GroupMembership) -> Unit, onBack: () -> Unit) {
    var scan by remember { mutableStateOf(false) }
    Screen("انضمام لمجموعة", onBack = onBack) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            ActionTile(Glyph.Radar, "المجموعات القريبة", "على نفس الشبكة", Modifier.weight(1f), selected = !scan) { scan = false }
            ActionTile(Glyph.Scan, "مسح رمز QR", "بالكاميرا، بدون كلمة سر", Modifier.weight(1f), selected = scan) { scan = true }
        }
        if (scan) ScanInvite(onInvite) else NearbyGroups(engine, state, onJoined)
    }
}

@Composable
private fun ScanInvite(onInvite: (String) -> Unit) {
    val context = LocalContext.current
    var problem by remember { mutableStateOf<String?>(null) }
    var handled by remember { mutableStateOf(false) }
    val accept = { text: String ->
        if (text.startsWith("coshare://", ignoreCase = true)) {
            if (!handled) {
                handled = true
                onInvite(text)
            }
        } else {
            problem = "هاد الرمز مش دعوة CoShare"
        }
    }
    val pick = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        if (uri != null) decodeQr(context, uri)?.let(accept) ?: run { problem = "ما لقينا رمز QR بهالصورة" }
    }
    Column(verticalArrangement = Arrangement.spacedBy(10.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        QrScanner({ accept(it) })
        problem?.let { Text(it, fontSize = 13.sp, color = CoShareTheme.colors.danger) }
        Hint("على الجهاز التاني: افتح المجموعة ← «إظهار رمز QR لإضافة جهاز»، ووجّه الكاميرا عليه.", center = true)
        LinkButton("أو اختر صورة فيها الرمز", {
            pick.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
        })
    }
}

@Composable
private fun NearbyGroups(engine: SyncEngine, state: EngineState, onJoined: (GroupMembership) -> Unit) {
    val c = CoShareTheme.colors
    if (state.nearby.isEmpty()) {
        Panel(padding = 18.dp) {
            Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                CircularProgressIndicator(Modifier.size(22.dp), color = c.signal, strokeWidth = 2.dp)
                Text("عم ندوّر على مجموعات على نفس الشبكة…", fontSize = 15.sp, color = c.ink)
                Hint(
                    "لازم يكون CoShare شغّال على جهاز بالمجموعة، وعلى نفس الواي فاي أو الـ Hotspot. إذا ما ظهرت، استعمل «مسح رمز QR».",
                    center = true,
                )
            }
        }
    } else {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            SectionTitle("اختر مجموعة وادخل كلمة سرها")
            Panel(padding = 4.dp) {
                state.nearby.forEachIndexed { index, nearby ->
                    if (index > 0) Divider()
                    NearbyGroupRow(engine, nearby, onJoined)
                }
            }
        }
    }
}

@Composable
private fun NearbyGroupRow(engine: SyncEngine, nearby: NearbyGroup, onJoined: (GroupMembership) -> Unit) {
    val c = CoShareTheme.colors
    val scope = rememberCoroutineScope()
    var expanded by remember { mutableStateOf(false) }
    var password by remember { mutableStateOf("") }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    val join = {
        if (password.isNotEmpty() && !busy) {
            busy = true
            error = null
            scope.launch {
                try {
                    onJoined(engine.join(nearby.key, password))
                } catch (e: Exception) {
                    error = e.message
                }
                busy = false
            }
        }
        Unit
    }
    Column(Modifier.padding(horizontal = 10.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            GroupBadge(32.dp)
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f)) {
                Text(nearby.group.name, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = c.ink)
                Text("فيها: " + nearby.memberNames.joinToString("، "), fontSize = 12.sp, color = c.muted, maxLines = 2, overflow = TextOverflow.Ellipsis)
            }
            if (!expanded) PrimaryButton("انضمام", { expanded = true })
        }
        if (expanded) {
            Field(password, { password = it }, "كلمة سر المجموعة", "", password = true, onDone = join)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                PrimaryButton(if (busy) "…" else "تأكيد", join, Modifier.weight(1f), enabled = password.isNotEmpty() && !busy)
                SecondaryButton("إلغاء", {
                    expanded = false
                    password = ""
                    error = null
                }, Modifier.weight(1f))
            }
            error?.let { Text(it, fontSize = 13.sp, color = c.danger) }
        }
    }
}

/** One group: its connected devices, a QR code to add another device, and leaving. */
@Composable
fun GroupDetailScreen(engine: SyncEngine, state: EngineState, group: GroupInfo, showInviteFirst: Boolean, onLeft: () -> Unit, onBack: () -> Unit) {
    val c = CoShareTheme.colors
    var showInvite by remember { mutableStateOf(showInviteFirst) }
    var showPassword by remember { mutableStateOf(false) }
    var confirmLeave by remember { mutableStateOf(false) }
    Screen(group.name, onBack = onBack) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            GroupBadge(48.dp)
            Spacer(Modifier.width(12.dp))
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(group.name, fontSize = 20.sp, fontWeight = FontWeight.Bold, color = c.ink, maxLines = 2)
                GroupStatus(state, group)
            }
        }

        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            SectionTitle("الأجهزة المتصلة (${group.members.size + 1})")
            Panel(padding = 4.dp) {
                Column(Modifier.padding(horizontal = 10.dp)) {
                    DeviceRow(Glyph.Phone, state.settings.deviceName, "هذا الجهاز", if (state.presence == Presence.Online) c.teal else c.paused)
                    group.members.forEach { peer ->
                        Divider()
                        DeviceRow(platformGlyph(peer.platform), peer.name, platformName(peer.platform) + " · " + if (peer.isDirect) "اتصال مباشر" else "على نفس الشبكة")
                    }
                }
            }
            if (group.members.isEmpty()) {
                Hint("ما في أجهزة تانية متصلة هلق. تأكد إن CoShare شغّال عليها وإنها على نفس الشبكة، أو أضف جهاز جديد من تحت.")
            }
        }

        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            SectionTitle("إضافة جهاز جديد")
            Panel(padding = 14.dp) {
                Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    if (showInvite) {
                        QrImage(engine.inviteURL(group.membership), 210.dp)
                        Text(
                            "على الجهاز الجديد: افتح CoShare ← «انضمام لمجموعة» ← «مسح رمز QR» ووجّه الكاميرا على هالرمز. أو امسحه بكاميرا الآيفون مباشرة.",
                            fontSize = 13.sp, lineHeight = 19.sp, color = c.muted, textAlign = TextAlign.Center,
                        )
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("كلمة السر:", fontSize = 13.sp, color = c.muted)
                            Spacer(Modifier.width(6.dp))
                            Text(
                                if (showPassword) group.membership.password else "•".repeat(maxOf(6, group.membership.password.length)),
                                fontFamily = FontFamily.Monospace, fontSize = 15.sp, color = c.ink,
                            )
                            IconButton(onClick = { showPassword = !showPassword }) {
                                Icon(if (showPassword) Glyph.EyeOff else Glyph.Eye, "إظهار كلمة السر", tint = c.muted)
                            }
                        }
                        LinkButton("إخفاء الرمز", {
                            showInvite = false
                            showPassword = false
                        })
                    } else {
                        PrimaryButton("إظهار رمز QR لإضافة جهاز", { showInvite = true }, Modifier.fillMaxWidth(), Glyph.Qr)
                        Text("الجهاز الجديد بيمسح الرمز وبينضم فوراً، بدون ما تكتب كلمة السر.", fontSize = 13.sp, color = c.muted, textAlign = TextAlign.Center)
                    }
                }
            }
        }

        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            if (confirmLeave) {
                Text(
                    "بعد المغادرة ما رح يوصلك نسخ أجهزة «${group.name}»، ولا رح يوصلها نسخك.",
                    fontSize = 14.sp, color = c.ink, textAlign = TextAlign.Center,
                )
                Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    PrimaryButton("مغادرة المجموعة", {
                        engine.leave(group.id)
                        onLeft()
                    }, Modifier.weight(1f), color = c.danger)
                    SecondaryButton("إلغاء", { confirmLeave = false }, Modifier.weight(1f))
                }
            } else {
                SecondaryButton("مغادرة المجموعة", { confirmLeave = true }, Modifier.fillMaxWidth(), Glyph.Leave, color = c.danger)
            }
        }
    }
}
