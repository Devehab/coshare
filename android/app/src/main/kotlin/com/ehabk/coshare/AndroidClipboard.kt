package com.ehabk.coshare

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import androidx.core.content.FileProvider
import com.ehabk.coshare.core.ClipContent
import com.ehabk.coshare.core.ClipboardBridge
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream

/**
 * The Android clipboard. From Android 10 only the app on screen (or the keyboard) may read it, so reads return
 * nothing in the background; writing works any time. Received images go on the clipboard as content:// links.
 */
class AndroidClipboard(private val context: Context) : ClipboardBridge {
    private val manager = context.getSystemService(ClipboardManager::class.java)
    private val clipsDir = File(context.cacheDir, "clips")

    @Volatile
    override var lastReadProblem: String? = null
        private set

    /** Calls `onChange` whenever the clipboard changes and this app may see it (always on Android 8–9). */
    fun watch(onChange: () -> Unit) {
        manager.addPrimaryClipChangedListener { onChange() }
    }

    override fun currentMark(): Long = System.currentTimeMillis()

    /**
     * When the current clip was copied (the system stamps every clip), or null when the clipboard is empty or
     * this app may not look at it right now. Reading only the description shows no "pasted" notice.
     */
    override fun changeMark(): Long? {
        val description = try {
            manager.primaryClipDescription
        } catch (_: Exception) {
            null
        } ?: return null
        val stamp = description.timestamp
        if (stamp <= 0L) return System.currentTimeMillis()
        // The stamp is wall-clock time; should a system stamp with uptime instead, convert it.
        val now = System.currentTimeMillis()
        return if (stamp < now - 400L * 24 * 3600 * 1000) now - SystemClock.elapsedRealtime() + stamp else stamp
    }

    override fun read(includeImages: Boolean, maxImageBytes: Int): ClipContent? {
        lastReadProblem = null
        val clip = try {
            manager.primaryClip
        } catch (_: Exception) {
            null
        } ?: return null
        if (clip.itemCount == 0) return null
        val description = clip.description
        // Passwords from password managers are marked sensitive: they never leave this device.
        if (description.extras?.getBoolean(EXTRA_IS_SENSITIVE) == true) return null
        val item = clip.getItemAt(0)
        val uri = item.uri
        if (uri != null && isImage(description, uri)) {
            if (!includeImages) return null
            return readImage(uri, description, maxImageBytes)
        }
        val text = item.text?.toString() ?: item.htmlText?.let { android.text.Html.fromHtml(it, 0).toString() }
        return text?.takeIf { it.isNotEmpty() }?.let { ClipContent.Text(it) }
    }

    override fun write(content: ClipContent) {
        val clip = when (content) {
            is ClipContent.Text -> ClipData.newPlainText("CoShare", content.text)
            is ClipContent.Image -> {
                clipsDir.mkdirs()
                // Only the newest received image stays; history keeps its own copy until the retention ends.
                clipsDir.listFiles()?.forEach { it.delete() }
                val extension = if (content.uti == ClipContent.UTI_JPEG) "jpg" else "png"
                val file = File(clipsDir, "clip-${System.currentTimeMillis()}.$extension")
                file.writeBytes(content.data)
                val uri = FileProvider.getUriForFile(context, "${context.packageName}.files", file)
                ClipData.newUri(context.contentResolver, "CoShare", uri)
            }
        }
        manager.setPrimaryClip(clip)
    }

    override fun forget(beforeMs: Long) {
        clipsDir.listFiles()?.forEach { if (it.lastModified() < beforeMs) it.delete() }
    }

    private fun isImage(description: ClipDescription, uri: Uri): Boolean =
        description.hasMimeType("image/*") || (runCatching { context.contentResolver.getType(uri) }.getOrNull()?.startsWith("image/") == true)

    private fun readImage(uri: Uri, description: ClipDescription, maxBytes: Int): ClipContent? {
        val mime = runCatching { context.contentResolver.getType(uri) }.getOrNull()
            ?: (0 until description.mimeTypeCount).map { description.getMimeType(it) }.firstOrNull { it.startsWith("image/") }
        return try {
            readImage(context, uri, mime, maxBytes)
        } catch (e: TooLarge) {
            lastReadProblem = "الصورة أكبر من ${maxBytes / 1024 / 1024} ميغابايت — ما انبعتت"
            null
        } catch (e: Exception) {
            lastReadProblem = "تعذّرت قراءة الصورة من الحافظة"
            null
        }
    }

    class TooLarge : Exception()

    companion object {
        private const val EXTRA_IS_SENSITIVE = "android.content.extra.IS_SENSITIVE"

        /** PNG and JPEG travel as they are; anything else (WebP, HEIC, GIF…) is converted to PNG. */
        fun readImage(context: Context, uri: Uri, mime: String?, maxBytes: Int): ClipContent.Image? {
            val bytes = context.contentResolver.openInputStream(uri)?.use { readLimited(it, maxBytes) } ?: return null
            if (bytes.isEmpty()) return null
            return when {
                mime == "image/png" || isPng(bytes) -> ClipContent.Image(bytes, ClipContent.UTI_PNG)
                mime == "image/jpeg" || mime == "image/jpg" || isJpeg(bytes) -> ClipContent.Image(bytes, ClipContent.UTI_JPEG)
                else -> {
                    val bitmap = decode(context, uri, bytes) ?: return null
                    val out = ByteArrayOutputStream()
                    bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
                    ClipContent.Image(out.toByteArray(), ClipContent.UTI_PNG)
                }
            }
        }

        private fun decode(context: Context, uri: Uri, bytes: ByteArray): Bitmap? =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                runCatching { ImageDecoder.decodeBitmap(ImageDecoder.createSource(context.contentResolver, uri)) }.getOrNull()
            } else {
                null
            } ?: BitmapFactory.decodeByteArray(bytes, 0, bytes.size)

        private fun readLimited(input: InputStream, maxBytes: Int): ByteArray {
            val out = ByteArrayOutputStream()
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                out.write(buffer, 0, n)
                if (out.size() > maxBytes) throw TooLarge()
            }
            return out.toByteArray()
        }

        private fun isPng(b: ByteArray) = b.size > 8 && b[0] == 0x89.toByte() && b[1] == 'P'.code.toByte() && b[2] == 'N'.code.toByte()
        private fun isJpeg(b: ByteArray) = b.size > 3 && b[0] == 0xFF.toByte() && b[1] == 0xD8.toByte()
    }
}
