package com.ehabk.coshare.ui

import androidx.activity.compose.BackHandler
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.font.FontWeight
import com.ehabk.coshare.core.GroupInvite
import com.ehabk.coshare.core.SyncEngine
import kotlinx.coroutines.launch

/** Screens; the home screen is the root and the others open on top of it. */
sealed interface Route {
    data object Home : Route
    data object Groups : Route
    data object Create : Route
    data object Join : Route
    data class Group(val id: String, val showInvite: Boolean = false) : Route
    data object Settings : Route
    data object Log : Route
}

/** Permissions that are missing right now (re-checked whenever CoShare comes back on screen). */
data class PermissionState(val localNetworkMissing: Boolean, val notificationsMissing: Boolean)

@Composable
fun CoShareRoot(
    engine: SyncEngine,
    permissions: PermissionState,
    pendingInvite: MutableState<String?>,
    actions: HomeActions,
    stack: MutableList<Route> = remember { mutableStateListOf(Route.Home) },
) {
    val state by engine.state.collectAsState()
    val scope = rememberCoroutineScope()
    fun push(route: Route) = stack.add(route)
    fun pop() {
        if (stack.size > 1) stack.removeAt(stack.lastIndex)
    }
    /** After creating or joining: the groups list with that group's page on top. */
    fun showGroup(id: String, invite: Boolean) {
        while (stack.size > 1) stack.removeAt(stack.lastIndex)
        stack.add(Route.Groups)
        stack.add(Route.Group(id, invite))
    }
    BackHandler(enabled = stack.size > 1) { pop() }

    val homeActions = HomeActions(
        sendClipboard = actions.sendClipboard,
        pickImage = actions.pickImage,
        openGroups = { start ->
            push(Route.Groups)
            if (start != null) push(start)
        },
        openSettings = { push(Route.Settings) },
        openLog = { push(Route.Log) },
        fixLocalNetwork = actions.fixLocalNetwork,
        fixNotifications = actions.fixNotifications,
    )

    when (val route = stack.last()) {
        Route.Home -> HomeScreen(engine, state, permissions, homeActions)
        Route.Groups -> GroupsHome(state, ::push, ::pop)
        Route.Create -> CreateGroupScreen(engine, { showGroup(it.id, invite = true) }, ::pop)
        Route.Join -> JoinGroupScreen(engine, state, onInvite = { pendingInvite.value = it }, onJoined = { showGroup(it.id, invite = false) }, onBack = ::pop)
        is Route.Group -> {
            val group = state.groups.firstOrNull { it.id == route.id }
            if (group == null) GroupsHome(state, ::push, ::pop)
            else GroupDetailScreen(engine, state, group, route.showInvite, onLeft = ::pop, onBack = ::pop)
        }
        Route.Settings -> SettingsScreen(engine, state, ::pop)
        Route.Log -> LogScreen(state, ::pop)
    }

    // An invite (QR scanned here, or a coshare:// link opened from the camera app): confirm, then join.
    val link = pendingInvite.value
    val invite = link?.let { GroupInvite.parse(it) }
    if (link != null) {
        var error by remember(link) { mutableStateOf<String?>(null) }
        val c = CoShareTheme.colors
        AlertDialog(
            onDismissRequest = { pendingInvite.value = null },
            title = { Text(if (invite != null) "الانضمام لمجموعة «${invite.name}»؟" else "رمز غير صالح", fontWeight = FontWeight.Bold) },
            text = {
                Text(
                    error ?: if (invite != null) "بعد الانضمام، كل اللي بتنسخه هون بيوصل لأجهزة هالمجموعة، واللي بينسخ عليها بيوصلك."
                    else "هاد الرمز مش دعوة CoShare",
                )
            },
            confirmButton = {
                if (invite != null) {
                    TextButton(onClick = {
                        scope.launch {
                            try {
                                val group = engine.joinInvite(link)
                                pendingInvite.value = null
                                showGroup(group.id, invite = false)
                            } catch (e: Exception) {
                                error = e.message
                            }
                        }
                    }) { Text("انضمام", color = c.signal, fontWeight = FontWeight.SemiBold) }
                }
            },
            dismissButton = { TextButton(onClick = { pendingInvite.value = null }) { Text("إلغاء", color = c.ink) } },
            containerColor = c.surface,
        )
    }
}
