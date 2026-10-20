package com.ehabk.coshare

import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import androidx.activity.ComponentActivity
import androidx.core.content.IntentCompat
import com.ehabk.coshare.core.ClipContent
import com.ehabk.coshare.core.SyncEngine.SendResult
import com.ehabk.coshare.core.Wire
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** What a send did, in one line for a toast. */
fun describe(result: SendResult, content: ClipContent): String = when (result) {
    is SendResult.Sent ->
        if (result.delivered == result.targets) "أُرسل ${content.label} إلى ${result.delivered} ${if (result.delivered == 1) "جهاز" else "أجهزة"}"
        else "أُرسل ${content.label} إلى ${result.delivered} من ${result.targets} أجهزة"
    SendResult.NoDevices -> "انحفظ ${content.label} بالسجل — ما في أجهزة متصلة هلق"
    SendResult.NoGroup -> "هالجهاز مش بأي مجموعة لهلق — افتح CoShare وأنشئ مجموعة أو انضم لوحدة"
    is SendResult.Offline -> result.reason
    SendResult.Empty -> "الحافظة فارغة أو محتواها غير مدعوم"
}

/**
 * Invisible for a moment: Android 10+ lets an app read the clipboard only while it has focus, so the tile and
 * the notification button open this, it reads the clipboard once, closes, and the send finishes in the background.
 */
class SendClipboardActivity : ComponentActivity() {
    private var done = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        app.ensureRunning()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (!hasFocus || done) return
        done = true
        val app = app
        app.scope.launch {
            val content = app.engine.readClipboard()
            finish()
            if (content == null) {
                app.toast(app.clipboard.lastReadProblem ?: describe(SendResult.Empty, ClipContent.Text("")))
                return@launch
            }
            app.toast(describe(app.engine.send(content, copyLocally = false), content))
        }
    }

    companion object {
        fun intent(context: Context) = Intent(context, SendClipboardActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
    }
}

/** "Share → CoShare" and the text-selection menu: sends that text or image to the group's devices. */
class ShareActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = app
        app.ensureRunning()
        val intent = intent
        app.scope.launch {
            // Read while this activity holds the permission to the shared file, then get out of the way.
            val content = withContext(Dispatchers.IO) { runCatching { extract(intent) }.getOrNull() }
            finish()
            if (content == null) {
                app.toast("ما في نص أو صورة نقدر نبعتها من هون")
                return@launch
            }
            if (content is ClipContent.Image) app.toast("عم نبعت الصورة…")
            app.toast(describe(app.engine.send(content, copyLocally = false), content))
        }
    }

    private fun extract(intent: Intent): ClipContent? {
        if (intent.action == Intent.ACTION_PROCESS_TEXT) {
            return intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()?.takeIf { it.isNotEmpty() }?.let { ClipContent.Text(it) }
        }
        val type = intent.type ?: ""
        if (type.startsWith("image/")) {
            val uri = IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java) ?: return null
            return AndroidClipboard.readImage(this, uri, type, Wire.MAX_IMAGE_BYTES)
        }
        return intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.takeIf { it.isNotEmpty() }?.let { ClipContent.Text(it) }
    }
}

/** Quick Settings tile "إرسال الحافظة": one tap from anywhere sends what was just copied. */
class SendTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        qsTile?.apply {
            state = Tile.STATE_ACTIVE
            label = getString(R.string.tile_label)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) subtitle = "CoShare"
            updateTile()
        }
    }

    override fun onClick() {
        super.onClick()
        val launch = Runnable {
            val intent = SendClipboardActivity.intent(this)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startActivityAndCollapse(PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
            } else {
                startActivityAndCollapseBefore14(intent)
            }
        }
        if (isLocked) unlockAndRun(launch) else launch.run()
    }

    /** Android 8–13 only take an Intent here (14+ take a PendingIntent, and refuse an Intent). */
    @SuppressLint("StartActivityAndCollapseDeprecated")
    @Suppress("DEPRECATION")
    private fun startActivityAndCollapseBefore14(intent: Intent) = startActivityAndCollapse(intent)
}
