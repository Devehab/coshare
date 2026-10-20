package com.ehabk.coshare.core

// Settings, the clip history and the activity log, stored as JSON in the app's private folder —
// the same shapes as desktop/src/core/store.js. Only the engine thread touches them.

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.File

/** How long history (and copied images) is kept: 1 hour up to a week, a day by default. */
object Retention {
    const val DEFAULT_HOURS = 24
    const val MAX_HOURS = 7 * 24
    val OPTIONS = listOf(1 to "ساعة واحدة", 12 to "١٢ ساعة", 24 to "يوم واحد", 72 to "٣ أيام", 168 to "أسبوع")

    fun clamp(hours: Int) = hours.coerceIn(1, MAX_HOURS)
    fun label(hours: Int) = OPTIONS.firstOrNull { it.first == hours }?.second ?: "$hours ساعة"
}

private val json = Json { ignoreUnknownKeys = true }

private fun readJson(file: File): kotlinx.serialization.json.JsonElement? =
    try { if (file.isFile) json.parseToJsonElement(file.readText()) else null } catch (_: Exception) { null }

/** Temp file + rename, so a crash or a full disk never leaves half a file behind. */
private fun writeAtomically(file: File, text: String) {
    try {
        file.parentFile?.mkdirs()
        val tmp = File(file.path + ".tmp")
        tmp.writeText(text)
        if (!tmp.renameTo(file)) {
            file.delete()
            tmp.renameTo(file)
        }
    } catch (_: Exception) {
        // Disk full or folder gone: the next change tries again.
    }
}

class Settings(private val file: File, defaultName: String) {
    var deviceID: String = randomID()
    var deviceName: String = defaultName
    var groups: List<GroupMembership> = emptyList()
    var syncImages = true
    var paused = false
    /** Start with the device (boot) and keep running in the background (foreground service). */
    var startOnBoot = true
    var keepRunning = true
    var quietEnabled = false
    var quietSchedule = QuietSchedule.DEFAULT
    /** Start (ms) of the quiet window the person chose to resume in ("resume today"). */
    var resumedWindowStart: Long? = null
    /** deviceID → last address it answered on (hotspots, networks without Bonjour). */
    val knownHosts = LinkedHashMap<String, String>()
    /** deviceID → its quiet hours in TXT form, so we never call it during them. */
    val peerSchedules = LinkedHashMap<String, String>()
    var use24Hour = false
    var historyRetentionHours = Retention.DEFAULT_HOURS
    /** Clipboard change mark already handled (copies at or before it are old news). 0 = not set yet. */
    var clipMark = 0L
    /** Whether the person saw the explanation of Android's clipboard limit. */
    var introSeen = false

    init {
        val o = readJson(file) as? JsonObject
        if (o != null) {
            o.str("deviceID")?.let { deviceID = it }
            o.str("deviceName")?.let { deviceName = it }
            groups = (o["groups"] as? JsonArray)?.mapNotNull { g ->
                val go = g as? JsonObject ?: return@mapNotNull null
                GroupMembership(
                    id = go.str("id") ?: return@mapNotNull null,
                    name = go.str("name") ?: "CoShare",
                    password = go.str("password") ?: return@mapNotNull null,
                    joinedAt = go.double("joinedAt") ?: 0.0,
                )
            } ?: emptyList()
            o.bool("syncImages")?.let { syncImages = it }
            o.bool("paused")?.let { paused = it }
            o.bool("startOnBoot")?.let { startOnBoot = it }
            o.bool("keepRunning")?.let { keepRunning = it }
            o.bool("quietEnabled")?.let { quietEnabled = it }
            QuietSchedule.fromJson(o["quietSchedule"])?.let { quietSchedule = it }
            resumedWindowStart = (o["resumedWindowStart"] as? JsonPrimitive)?.content?.toLongOrNull()
            (o["knownHosts"] as? JsonObject)?.forEach { (k, v) -> (v as? JsonPrimitive)?.content?.let { knownHosts[k] = it } }
            (o["peerSchedules"] as? JsonObject)?.forEach { (k, v) -> (v as? JsonPrimitive)?.content?.let { peerSchedules[k] = it } }
            o.bool("use24Hour")?.let { use24Hour = it }
            o.int("historyRetentionHours")?.let { historyRetentionHours = Retention.clamp(it) }
            (o["clipMark"] as? JsonPrimitive)?.content?.toLongOrNull()?.let { clipMark = it }
            o.bool("introSeen")?.let { introSeen = it }
        } else {
            save()
        }
    }

    fun save() {
        writeAtomically(file, buildJsonObject {
            put("deviceID", deviceID)
            put("deviceName", deviceName)
            put("groups", JsonArray(groups.map { g ->
                buildJsonObject { put("id", g.id); put("name", g.name); put("password", g.password); put("joinedAt", g.joinedAt) }
            }))
            put("syncImages", syncImages)
            put("paused", paused)
            put("startOnBoot", startOnBoot)
            put("keepRunning", keepRunning)
            put("quietEnabled", quietEnabled)
            put("quietSchedule", quietSchedule.toJson())
            resumedWindowStart?.let { put("resumedWindowStart", it) }
            put("knownHosts", JsonObject(knownHosts.mapValues { JsonPrimitive(it.value) }))
            put("peerSchedules", JsonObject(peerSchedules.mapValues { JsonPrimitive(it.value) }))
            put("use24Hour", use24Hour)
            put("historyRetentionHours", historyRetentionHours)
            put("clipMark", clipMark)
            put("introSeen", introSeen)
        }.toString())
    }
}

enum class Direction(val wire: String) { SENT("sent"), RECEIVED("received") }

data class HistoryItem(
    val id: String,
    val kind: ClipKind,
    val text: String?,
    val blobName: String?,
    val uti: String?,
    val hash: String,
    val byteCount: Int,
    val deviceName: String,
    val direction: Direction,
    /** Seconds since 1970. */
    val date: Double,
    val deliveredTo: Int?,
)

/** Recent clips, sent and received. Anything older than the retention period is deleted with its image. */
class History(private val dir: File, retentionHours: Int) {
    var retentionHours = Retention.clamp(retentionHours)
        private set
    val blobs = File(dir, "blobs")
    private val file = File(dir, "history.json")
    var items: List<HistoryItem> = emptyList()
        private set

    init {
        blobs.mkdirs()
        items = (readJson(file) as? JsonArray)?.mapNotNull { e ->
            val o = e as? JsonObject ?: return@mapNotNull null
            HistoryItem(
                id = o.str("id") ?: return@mapNotNull null,
                kind = ClipKind.of(o.str("kind")) ?: return@mapNotNull null,
                text = o.str("text"),
                blobName = o.str("blobName"),
                uti = o.str("uti"),
                hash = o.str("hash") ?: "",
                byteCount = o.int("byteCount") ?: 0,
                deviceName = o.str("deviceName") ?: "",
                direction = if (o.str("direction") == "received") Direction.RECEIVED else Direction.SENT,
                date = o.double("date") ?: 0.0,
                deliveredTo = o.int("deliveredTo"),
            )
        } ?: emptyList()
        purge()
        removeOrphans()
    }

    fun add(content: ClipContent, hash: String, deviceName: String, direction: Direction, date: Double): HistoryItem {
        items.firstOrNull { it.hash == hash }?.let { old ->
            removeBlob(old)
            items = items - old
        }
        val id = randomID()
        val blobName = (content as? ClipContent.Image)?.let { "$id.${if (it.uti == ClipContent.UTI_JPEG) "jpg" else "png"}" }
        if (content is ClipContent.Image && blobName != null) File(blobs, blobName).writeBytes(content.data)
        val item = HistoryItem(
            id = id, kind = content.kind, text = (content as? ClipContent.Text)?.text, blobName = blobName, uti = content.uti,
            hash = hash, byteCount = content.payload.size, deviceName = deviceName, direction = direction, date = date,
            deliveredTo = null,
        )
        items = (listOf(item) + items).let { list ->
            if (list.size <= MAX_ITEMS) list else {
                list.drop(MAX_ITEMS).forEach(::removeBlob)
                list.take(MAX_ITEMS)
            }
        }
        save()
        return item
    }

    fun setDelivered(id: String, count: Int) {
        items = items.map { if (it.id == id) it.copy(deliveredTo = count) else it }
        save()
    }

    fun content(item: HistoryItem): ClipContent? = when (item.kind) {
        ClipKind.TEXT -> item.text?.let { ClipContent.Text(it) }
        ClipKind.IMAGE -> blobFile(item)?.takeIf { it.isFile }?.let {
            try { ClipContent.Image(it.readBytes(), item.uti ?: ClipContent.UTI_PNG) } catch (_: Exception) { null }
        }
    }

    fun blobFile(item: HistoryItem): File? = item.blobName?.let { File(blobs, it) }

    fun remove(id: String) {
        val item = items.firstOrNull { it.id == id } ?: return
        removeBlob(item)
        items = items - item
        save()
    }

    fun clear() {
        items.forEach(::removeBlob)
        items = emptyList()
        save()
    }

    fun setRetention(hours: Int): Boolean {
        retentionHours = Retention.clamp(hours)
        return purge()
    }

    /** Drops everything older than the retention period, image files included. True if anything went. */
    fun purge(nowSeconds: Double = System.currentTimeMillis() / 1000.0): Boolean {
        val cutoff = nowSeconds - retentionHours * 3600
        val old = items.filter { it.date < cutoff }
        if (old.isEmpty()) return false
        old.forEach(::removeBlob)
        items = items - old.toSet()
        save()
        removeOrphans()
        return true
    }

    private fun removeBlob(item: HistoryItem) {
        blobFile(item)?.delete()
    }

    private fun removeOrphans() {
        val referenced = items.mapNotNull { it.blobName }.toSet()
        blobs.listFiles()?.forEach { if (it.name !in referenced) it.delete() }
    }

    private fun save() {
        writeAtomically(file, JsonArray(items.map { i ->
            buildJsonObject {
                put("id", i.id)
                put("kind", i.kind.wire)
                i.text?.let { put("text", it) }
                i.blobName?.let { put("blobName", it) }
                i.uti?.let { put("uti", it) }
                put("hash", i.hash)
                put("byteCount", i.byteCount)
                put("deviceName", i.deviceName)
                put("direction", i.direction.wire)
                put("date", i.date)
                i.deliveredTo?.let { put("deliveredTo", it) }
            }
        }).toString())
    }

    companion object {
        const val MAX_ITEMS = 500
    }
}

data class LogEntry(val id: String, val date: Double, val text: String, val isError: Boolean)

class ActivityLog(dir: File, retentionHours: Int, private val echo: ((String) -> Unit)? = null) {
    private val file = File(dir, "activity.json")
    private var retentionHours = Retention.clamp(retentionHours)
    var entries: List<LogEntry> = emptyList()
        private set
    /** Saving is batched: the engine calls flush() shortly after changes. */
    var dirty = false
        private set

    init {
        entries = (readJson(file) as? JsonArray)?.mapNotNull { e ->
            val o = e as? JsonObject ?: return@mapNotNull null
            LogEntry(o.str("id") ?: randomID(), o.double("date") ?: 0.0, o.str("text") ?: "", o.bool("isError") ?: false)
        } ?: emptyList()
        purge()
    }

    fun add(text: String, isError: Boolean = false) {
        entries = (listOf(LogEntry(randomID(), System.currentTimeMillis() / 1000.0, text, isError)) + entries).take(1000)
        echo?.invoke((if (isError) "⚠️ " else "") + text)
        dirty = true
    }

    fun setRetention(hours: Int) {
        retentionHours = Retention.clamp(hours)
        purge()
    }

    fun purge() {
        val cutoff = System.currentTimeMillis() / 1000.0 - retentionHours * 3600
        val keep = entries.filter { it.date >= cutoff }
        if (keep.size != entries.size) {
            entries = keep
            dirty = true
        }
    }

    fun clear() {
        entries = emptyList()
        dirty = true
    }

    fun flush() {
        if (!dirty) return
        dirty = false
        writeAtomically(file, JsonArray(entries.map { e ->
            buildJsonObject { put("id", e.id); put("date", e.date); put("text", e.text); put("isError", e.isError) }
        }).toString())
    }
}
