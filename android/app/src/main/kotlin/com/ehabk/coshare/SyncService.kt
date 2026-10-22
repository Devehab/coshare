package com.ehabk.coshare

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.annotation.SuppressLint
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import com.ehabk.coshare.core.EngineState
import com.ehabk.coshare.core.Presence
import com.ehabk.coshare.core.PresenceEvent
import com.ehabk.coshare.core.TimeFormat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.launch

object Notifications {
    const val CHANNEL_STATUS = "status"
    const val CHANNEL_DEVICES = "devices"
    const val STATUS_ID = 1
    private const val PRESENCE_ID = 2

    fun createChannels(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(CHANNEL_STATUS, "حالة CoShare", NotificationManager.IMPORTANCE_LOW).apply {
            description = "يبقي CoShare شغّالاً ليستقبل من أجهزتك، مع زر لإرسال الحافظة"
            setShowBadge(false)
        }
        val devices = NotificationChannel(CHANNEL_DEVICES, "الأجهزة", NotificationManager.IMPORTANCE_DEFAULT).apply {
            description = "لما جهاز من مجموعاتك يتصل أو ينقطع"
        }
        manager.createNotificationChannels(listOf(channel, devices))
    }

    /** Whether CoShare may show device notifications (the app's notifications and the "الأجهزة" channel are on). */
    fun devicesAllowed(context: Context): Boolean {
        val compat = NotificationManagerCompat.from(context)
        if (!compat.areNotificationsEnabled()) return false
        return context.getSystemService(NotificationManager::class.java)
            .getNotificationChannel(CHANNEL_DEVICES)?.importance != NotificationManager.IMPORTANCE_NONE
    }

    /** "Device in / out": one slot per device, so its "out" replaces its earlier "in". */
    @SuppressLint("MissingPermission")
    fun presence(context: Context, event: PresenceEvent, title: String, body: String) {
        if (!devicesAllowed(context)) return
        val open = PendingIntent.getActivity(
            context, 0, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_DEVICES)
            .setSmallIcon(R.drawable.ic_stat_coshare)
            .setColor(0xFFD24A22.toInt())
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setContentIntent(open)
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setGroup("presence")
            .build()
        NotificationManagerCompat.from(context).notify("presence.${event.member.id}", PRESENCE_ID, notification)
    }

    fun status(context: Context, state: EngineState?): Notification {
        val open = PendingIntent.getActivity(
            context, 0, Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val send = PendingIntent.getActivity(
            context, 1, SendClipboardActivity.intent(context),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(context, CHANNEL_STATUS)
            .setSmallIcon(R.drawable.ic_stat_coshare)
            .setColor(0xFFD24A22.toInt())
            .setContentTitle(state?.let { title(it) } ?: "CoShare")
            .setContentText(state?.let { detail(it) } ?: "جاري التشغيل…")
            .setContentIntent(open)
            .addAction(0, "إرسال الحافظة", send)
            .setOngoing(true)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            .setSilent(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    fun title(state: EngineState): String = when (val p = state.presence) {
        Presence.Paused -> "متوقف — منفصل عن الشبكة"
        is Presence.Quiet -> "وقت الإيقاف حتى ${TimeFormat.clock(p.untilMs, state.settings.use24Hour)}"
        Presence.Online -> when (val n = state.connected.size) {
            0 -> if (state.groups.isEmpty()) "هالجهاز مش بأي مجموعة لهلق" else "بانتظار أجهزة على نفس الشبكة…"
            1 -> "متصل بـ ${state.connected[0].name}"
            else -> "متصل بـ $n أجهزة"
        }
    }

    private fun detail(state: EngineState): String {
        val latest = state.history.firstOrNull()
        return when {
            latest != null && latest.direction == com.ehabk.coshare.core.Direction.RECEIVED ->
                "آخر شي وصل من ${latest.deviceName} — جاهز للصق"
            else -> "اللي بيوصلك بينلصق فوراً. لتبعت: «إرسال الحافظة»"
        }
    }
}

/**
 * Keeps CoShare running in the background (a "connected device" foreground service) so clips from the other
 * devices land on this clipboard at once, with a notification that also sends the clipboard.
 */
class SyncService : Service() {
    private var scope: CoroutineScope? = null
    private var watcher: Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val notification = Notifications.status(this, null)
        try {
            ServiceCompat.startForeground(
                this, Notifications.STATUS_ID, notification,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE else 0,
            )
        } catch (e: Exception) {
            // Not allowed right now (e.g. started from the background on Android 12+): CoShare still works
            // while it is open, and tries again next time.
            stopSelf()
            return
        }
        val engine = app.engine
        // The service (re)started: devices may drop out and come back because of us, so look again quietly.
        engine.systemDidWake()
        val manager = getSystemService(android.app.NotificationManager::class.java)
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Main).also { scope ->
            watcher = scope.launch {
                engine.state.map { Notifications.title(it) to it.history.firstOrNull()?.id }.distinctUntilChanged().collect {
                    manager.notify(Notifications.STATUS_ID, Notifications.status(this@SyncService, engine.state.value))
                }
            }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!app.engine.settings.keepRunning) {
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    override fun onDestroy() {
        scope?.cancel()
        super.onDestroy()
    }

    companion object {
        /** Starts or stops the service to match "keep running in the background". */
        fun sync(context: Context) {
            val app = context.app
            val intent = Intent(context, SyncService::class.java)
            if (app.engine.settings.keepRunning) {
                try {
                    ContextCompat.startForegroundService(context, intent)
                } catch (_: Exception) {
                    // Android 12+ refuses from the background; the next time CoShare is opened it starts.
                }
            } else {
                context.stopService(intent)
            }
        }
    }
}

/** After a restart (or an app update), CoShare comes back on its own if the person asked for that. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.app
        // Read the saved settings without starting the engine; nothing to do before CoShare was ever opened.
        val settings = app.savedSettings() ?: return
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED -> if (settings.startOnBoot && settings.keepRunning) app.ensureRunning()
            Intent.ACTION_MY_PACKAGE_REPLACED -> if (settings.keepRunning) app.ensureRunning()
        }
    }
}
