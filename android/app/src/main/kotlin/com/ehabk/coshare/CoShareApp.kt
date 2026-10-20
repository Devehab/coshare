package com.ehabk.coshare

import android.Manifest
import android.app.Application
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import android.widget.Toast
import com.ehabk.coshare.core.EngineConfig
import com.ehabk.coshare.core.SyncEngine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import java.io.File

class CoShareApp : Application() {
    /** Long-lived work that may outlive a screen (finishing a send after the helper activity closed). */
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    val clipboard by lazy { AndroidClipboard(this) }
    val localNetwork by lazy { LocalNetwork(this) }

    /** The sync engine, created and started the first time something needs it (a screen, boot, the tile…). */
    val engine: SyncEngine by lazy {
        SyncEngine(
            EngineConfig(
                dataDir = File(filesDir, "coshare"),
                platform = "android",
                defaultName = defaultDeviceName(),
                clipboard = clipboard,
                discovery = NsdDiscovery(this),
                gateways = { localNetwork.gateways() },
                prepareSocket = { socket, host -> localNetwork.bindToLan(socket, host) },
            ),
        ).also { engine ->
            engine.start()
            // Android 8–9 report every copy; 10+ only while CoShare is on screen (then this sends it right away).
            clipboard.watch { engine.pollNow() }
            localNetwork.watch { signature ->
                engine.networkChanged(signature)
                engine.refreshDiscovery()
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
        Notifications.createChannels(this)
    }

    /** Starts the engine and, if the person wants it, the background service that keeps it alive. */
    fun ensureRunning() {
        engine
        SyncService.sync(this)
    }

    /** The settings as saved, without starting anything; null before the first launch. */
    fun savedSettings(): com.ehabk.coshare.core.Settings? =
        File(filesDir, "coshare/settings.json").takeIf { it.isFile }?.let { com.ehabk.coshare.core.Settings(it, defaultDeviceName()) }

    fun toast(text: String) {
        Toast.makeText(this, text, Toast.LENGTH_LONG).show()
    }

    private fun defaultDeviceName(): String =
        Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() }
            ?: listOf(Build.MANUFACTURER.replaceFirstChar { it.uppercase() }, Build.MODEL).distinct().joinToString(" ")

    companion object {
        lateinit var instance: CoShareApp
            private set

        /** Android 17+: reaching devices on the local network needs the "Nearby devices" permission. */
        fun needsLocalNetworkPermission(context: Context): Boolean =
            Build.VERSION.SDK_INT >= 37 &&
                context.checkSelfPermission(LOCAL_NETWORK_PERMISSION) != PackageManager.PERMISSION_GRANTED

        fun needsNotificationPermission(context: Context): Boolean =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED

        const val LOCAL_NETWORK_PERMISSION = "android.permission.ACCESS_LOCAL_NETWORK"
    }
}

val Context.app: CoShareApp get() = applicationContext as CoShareApp
