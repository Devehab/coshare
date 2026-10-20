package com.ehabk.coshare

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.core.content.edit
import androidx.core.net.toUri
import com.ehabk.coshare.core.Wire
import com.ehabk.coshare.ui.CoShareRoot
import com.ehabk.coshare.ui.CoShareTheme
import com.ehabk.coshare.ui.HomeActions
import com.ehabk.coshare.ui.PermissionState
import com.ehabk.coshare.ui.Route
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    private val pendingInvite = mutableStateOf<String?>(null)
    private val permissions = mutableStateOf(PermissionState(localNetworkMissing = false, notificationsMissing = false))
    private val stack = mutableStateListOf<Route>(Route.Home)

    private val requestPermissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        refreshPermissions()
        if (result[CoShareApp.LOCAL_NETWORK_PERMISSION] == true) app.engine.restartNetwork()
        if (result[Manifest.permission.POST_NOTIFICATIONS] == true) SyncService.sync(this)
    }

    private val pickImage = registerForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri -> uri?.let(::sendImage) }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        app.ensureRunning()
        handle(intent)
        refreshPermissions()
        askForMissingPermissions()
        setContent {
            CoShareTheme {
                CoShareRoot(
                    engine = app.engine,
                    permissions = permissions.value,
                    pendingInvite = pendingInvite,
                    stack = stack,
                    actions = HomeActions(
                        sendClipboard = ::sendClipboard,
                        pickImage = { pickImage.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) },
                        openGroups = {},
                        openSettings = {},
                        openLog = {},
                        fixLocalNetwork = { fixPermission(CoShareApp.LOCAL_NETWORK_PERMISSION) },
                        fixNotifications = { if (Build.VERSION.SDK_INT >= 33) fixPermission(Manifest.permission.POST_NOTIFICATIONS) },
                    ),
                )
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    override fun onResume() {
        super.onResume()
        refreshPermissions()
        // Like the iPhone app coming to the front: look around and fetch anything newer.
        app.engine.refreshDiscovery()
        app.scope.launch { app.engine.pullLatest() }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // The one moment Android 10+ lets CoShare read the clipboard: send whatever was copied meanwhile.
        if (hasFocus) app.engine.pollNow()
    }

    private fun handle(intent: Intent?) {
        val data = intent?.data?.toString() ?: return
        if (data.startsWith("coshare://", ignoreCase = true)) pendingInvite.value = data
    }

    private fun refreshPermissions() {
        permissions.value = PermissionState(
            localNetworkMissing = CoShareApp.needsLocalNetworkPermission(this),
            notificationsMissing = CoShareApp.needsNotificationPermission(this),
        )
    }

    private fun askForMissingPermissions() {
        val wanted = buildList {
            if (CoShareApp.needsLocalNetworkPermission(this@MainActivity)) add(CoShareApp.LOCAL_NETWORK_PERMISSION)
            if (CoShareApp.needsNotificationPermission(this@MainActivity)) add(Manifest.permission.POST_NOTIFICATIONS)
        }
        if (wanted.isNotEmpty()) requestPermissions.launch(wanted.toTypedArray())
    }

    /** Ask again; once Android stops asking ("don't ask again"), open CoShare's page in the system settings. */
    private fun fixPermission(permission: String) {
        if (shouldShowRequestPermissionRationale(permission)) {
            requestPermissions.launch(arrayOf(permission))
        } else {
            val asked = getSharedPreferences("permissions", MODE_PRIVATE)
            if (!asked.getBoolean(permission, false)) {
                asked.edit { putBoolean(permission, true) }
                requestPermissions.launch(arrayOf(permission))
            } else {
                startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, "package:$packageName".toUri()))
            }
        }
    }

    /** The window has focus here, so the clipboard can be read directly. */
    private fun sendClipboard() {
        val app = app
        app.scope.launch {
            val content = app.engine.readClipboard()
            if (content == null) {
                app.toast(app.clipboard.lastReadProblem ?: "الحافظة فارغة أو محتواها غير مدعوم")
                return@launch
            }
            app.toast(describe(app.engine.send(content, copyLocally = false), content))
        }
    }

    private fun sendImage(uri: Uri) {
        val app = app
        app.scope.launch {
            val content = withContext(Dispatchers.IO) {
                runCatching { AndroidClipboard.readImage(this@MainActivity, uri, contentResolver.getType(uri), Wire.MAX_IMAGE_BYTES) }.getOrNull()
            }
            if (content == null) {
                app.toast("تعذّرت قراءة الصورة")
                return@launch
            }
            app.toast(describe(app.engine.send(content, copyLocally = false), content))
        }
    }
}
