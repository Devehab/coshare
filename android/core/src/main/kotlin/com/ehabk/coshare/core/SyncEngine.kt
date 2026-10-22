package com.ehabk.coshare.core

// Watches the clipboard, sends every new copy to all devices in this device's groups and applies clips that
// arrive from them — the Kotlin twin of Shared/SyncEngine.swift and desktop/src/core/engine.js (same behaviour,
// same protocol). Everything here runs on one thread ("coshare-engine"); public calls hop onto it.

import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.concurrent.Executors

/** Platform clipboard access. */
interface ClipboardBridge {
    /** A mark for "now": anything copied at or before it is old news. */
    fun currentMark(): Long

    /** The mark of what is on the clipboard now, or null when it can't be read right now (Android 10+ in the background). */
    fun changeMark(): Long?

    fun read(includeImages: Boolean, maxImageBytes: Int): ClipContent?
    fun write(content: ClipContent)

    /** Why the last read came back empty although something was copied. */
    val lastReadProblem: String? get() = null

    /** Deletes anything kept for the clipboard (received images) older than this, with the history retention. */
    fun forget(beforeMs: Long) {}
}

sealed class Presence {
    data object Online : Presence()
    /** The person pressed pause. */
    data object Paused : Presence()
    /** Inside a scheduled quiet window. */
    data class Quiet(val untilMs: Long) : Presence()

    val isOnline: Boolean get() = this == Online
}

data class DeviceInfo(val id: String, val name: String, val platform: String, val isDirect: Boolean)
data class GroupInfo(val membership: GroupMembership, val members: List<DeviceInfo>) {
    val id: String get() = membership.id
    val name: String get() = membership.name
}
/** A group seen on the network that this device hasn't joined yet. */
data class NearbyGroup(val key: String, val group: AdvertisedGroup, val memberNames: List<String>)

data class SettingsSnapshot(
    val deviceName: String,
    val syncImages: Boolean,
    val quietEnabled: Boolean,
    val quietSchedule: QuietSchedule,
    val startOnBoot: Boolean,
    val keepRunning: Boolean,
    val use24Hour: Boolean,
    val historyRetentionHours: Int,
    val introSeen: Boolean,
    val notifyDevices: Boolean,
    val notifyJoins: Boolean,
    val notifyLeaves: Boolean,
)

/** Everything the screens need to draw themselves. */
data class EngineState(
    val presence: Presence,
    val peers: List<DeviceInfo>,
    val connected: List<DeviceInfo>,
    val groups: List<GroupInfo>,
    val nearby: List<NearbyGroup>,
    val history: List<HistoryItem>,
    val log: List<LogEntry>,
    val settings: SettingsSnapshot,
    val blobDir: File,
    val listenPort: Int,
)

class EngineConfig(
    val dataDir: File,
    val platform: String,
    val defaultName: String,
    val clipboard: ClipboardBridge,
    val discovery: ServiceDiscovery? = null,
    val gateways: () -> List<String> = { emptyList() },
    val port: Int = Wire.PREFERRED_PORT,
    val extraHosts: List<String> = emptyList(),
    /** Checks the clipboard on a timer (tests, platforms that allow background reads); null = only when asked. */
    val pollIntervalMs: Long? = null,
    /** Called with every outgoing socket before it connects (Android: use the Wi-Fi network that has that address). */
    val prepareSocket: (java.net.Socket, String) -> Unit = { _, _ -> },
    val echoLog: ((String) -> Unit)? = null,
    /** Shows a "device in / out" notification (title, body); only called for the kinds the person wants. */
    val showPresence: (PresenceEvent, String, String) -> Unit = { _, _, _ -> },
    /** Quiet time after this device (re)connects; the apps use PresenceWatch.SETTLE_TIME_MS, tests a shorter one. */
    val presenceSettleMs: Long = PresenceWatch.SETTLE_TIME_MS,
)

class GroupException(message: String) : Exception(message)

class SyncEngine(private val config: EngineConfig) {
    private val executor = Executors.newSingleThreadExecutor { r -> Thread(r, "coshare-engine").apply { isDaemon = true } }
    val dispatcher = executor.asCoroutineDispatcher()
    val scope = CoroutineScope(SupervisorJob() + dispatcher + CoroutineExceptionHandler { _, e ->
        log.add("خطأ داخلي: ${e.message ?: e.javaClass.simpleName}", true)
    })

    val settings = Settings(File(config.dataDir, "settings.json"), config.defaultName)
    val history = History(config.dataDir, settings.historyRetentionHours)
    val log = ActivityLog(config.dataDir, settings.historyRetentionHours, config.echoLog)
    private val clipboard = config.clipboard
    val network = PeerNetwork(scope, settings, config.discovery, config.gateways, config.port, config.extraHosts, config.prepareSocket)
    /** Decides when a device of my groups came in or went out (see notifyPresence). */
    val presenceWatch = PresenceWatch(
        settings.knownMembers.mapValues { it.value.toSet() },
        { known -> settings.knownMembers = known; settings.save() },
        config.presenceSettleMs,
    )
    /** False while this device has no network at all: others vanishing then is our doing, not theirs. */
    private var lanUp = true

    private var started = false
    private var presence: Presence = Presence.Online
    private var peers: List<Peer> = emptyList()
    private var identity: LocalIdentity? = null
    private val keyCache = HashMap<String, GroupKey>()
    private var networkGeneration = 0
    private var lastMark = 0L
    private var lastReportedProblemMark = -1L
    /** Hash/date of what is on this device's clipboard now, whichever side it came from. */
    private var currentHash: String? = null
    private var currentDate = 0.0
    private val seenClipIDs = ArrayDeque<String>()
    private var changeJob: Job? = null
    private var lastNetworkSignature: String? = null

    private val _state = MutableStateFlow(snapshot())
    val state: StateFlow<EngineState> = _state

    init {
        history.items.firstOrNull()?.let {
            currentHash = it.hash
            currentDate = it.date
        }
        network.onPeers = { updatePeers(it) }
        network.onEvent = { text, isError -> log.add(text, isError); changed() }
        network.onRequest = { message, group -> handle(message, group) }
        network.onBye = { deviceID, untilMs -> presenceWatch.bye(deviceID, untilMs) }
        presenceWatch.onEvent = { notifyPresence(it) }
    }

    private val isOnline get() = presence.isOnline

    // ------------------------------------------------------------------------------------------ lifecycle

    fun start() = scope.launch {
        if (started) return@launch
        started = true
        log.add("بدأ CoShare على «${settings.deviceName}»")
        // Whatever was copied before the first launch is old news; only new copies are shared.
        if (settings.clipMark == 0L) {
            settings.clipMark = clipboard.currentMark()
            settings.save()
        }
        lastMark = settings.clipMark
        // During quiet hours the app starts without touching the network at all.
        presence = computePresence()
        if (isOnline) startNetwork() else log.add(offlineMessage(presence))
        launch { while (true) { delay(15_000); updatePresence() } }
        launch { while (true) { delay(5000); presenceWatch.tick() } }
        // Every minute, so even a one-hour retention is kept to the minute.
        launch {
            while (true) {
                if (history.purge()) changed()
                log.purge()
                runCatching { clipboard.forget(System.currentTimeMillis() - settings.historyRetentionHours * 3_600_000L) }
                delay(60_000)
            }
        }
        launch { while (true) { delay(1000); log.flush() } }
        config.pollIntervalMs?.let { interval -> launch { while (true) { delay(interval); pollNow() } } }
        changed()
    }

    /** Stops everything (tests). */
    fun shutdown() {
        scope.launch {
            network.stop()
            log.flush()
        }
        Thread.sleep(100)
        executor.shutdown()
    }

    private fun startNetwork() {
        if (!isOnline) return
        // Devices are about to drop out and come back because of us: don't report any of it.
        presenceWatch.settle()
        val gen = ++networkGeneration
        val memberships = settings.groups
        scope.launch {
            val secrets = memberships.map { GroupSecret(it, deriveKey(it.id, it.password)) }
            if (gen != networkGeneration || !isOnline) return@launch
            val name = settings.deviceName.trim().ifEmpty { config.defaultName }
            val me = LocalIdentity(settings.deviceID, name, config.platform, secrets, if (settings.quietEnabled) settings.quietSchedule else null)
            identity = me
            network.start(me)
            changed()
        }
    }

    fun restartNetwork() = scope.launch { if (started && isOnline) startNetwork() }

    /** Looks for devices again without dropping the current connections. */
    fun refreshDiscovery() = scope.launch { if (isOnline) network.refreshDiscovery() }

    /**
     * This device's own connection was interrupted (the background service restarted, the phone woke up):
     * devices drop out and come back because of us, so look again quietly.
     */
    fun systemDidWake() = scope.launch {
        if (!started || !isOnline) return@launch
        presenceWatch.settle()
        network.refreshDiscovery()
    }

    /** Wi-Fi joined/left or the gateway changed: start over on the new network. */
    fun networkChanged(signature: String) = scope.launch {
        val last = lastNetworkSignature
        lastNetworkSignature = signature
        lanUp = signature != "offline"
        if (!lanUp) presenceWatch.reset()
        if (!started || !isOnline || last == null || last == signature || signature == "offline") return@launch
        log.add("تغيّرت الشبكة — إعادة الاتصال")
        startNetwork()
    }

    private suspend fun deriveKey(groupID: String, password: String): GroupKey {
        val cacheKey = groupID + "\u0000" + password
        keyCache[cacheKey]?.let { return it }
        // PBKDF2 is deliberately slow; keep it off the engine thread.
        val key = withContext(Dispatchers.Default) { GroupKey.derive(groupID, password) }
        keyCache[cacheKey] = key
        return key
    }

    // ------------------------------------------------------------------------------------------ quiet hours / pause

    private fun computePresence(nowMs: Long = System.currentTimeMillis()): Presence {
        if (settings.paused) return Presence.Paused
        if (!settings.quietEnabled) return Presence.Online
        val window = settings.quietSchedule.window(nowMs) ?: return Presence.Online
        if (settings.resumedWindowStart == window.startMs) return Presence.Online
        return Presence.Quiet(window.endMs)
    }

    private fun offlineMessage(p: Presence): String = when (p) {
        Presence.Paused -> "متوقف — CoShare منفصل تماماً عن الشبكة"
        is Presence.Quiet -> "وقت الإيقاف — CoShare منفصل تماماً عن الشبكة حتى ${TimeFormat.clock(p.untilMs, settings.use24Hour)}"
        Presence.Online -> "CoShare متصل بالشبكة"
    }

    private fun updatePresence() {
        val next = computePresence()
        if (next == presence) return
        val wasOnline = isOnline
        presence = next
        when {
            wasOnline && !next.isOnline -> goOffline(next)
            !wasOnline && next.isOnline -> comeBack()
            else -> log.add(offlineMessage(next))
        }
        changed()
    }

    /** Tells the group "quiet until …" once, then closes every socket: no listening, no mDNS, no probes. */
    private fun goOffline(next: Presence) {
        log.add(offlineMessage(next))
        presenceWatch.reset()
        networkGeneration++
        val targets = connectedPeers()
        val me = identity
        scope.launch {
            if (me != null && targets.isNotEmpty()) {
                val bye = header(MessageType.BYE, me).copy(
                    listenPort = network.listenPort,
                    quietUntil = (next as? Presence.Quiet)?.let { it.untilMs / 1000.0 },
                )
                exchange(WireMessage(bye), targets, 3000)
            }
            if (isOnline) return@launch
            network.stop()
            identity = null
            changed()
        }
    }

    private fun comeBack() {
        // Copies made while away stay on this device, and nothing from that time is pulled in.
        markClipboardSeen()
        currentDate = maxOf(currentDate, System.currentTimeMillis() / 1000.0)
        log.add("رجع CoShare للشبكة")
        startNetwork()
    }

    /** Back online for the rest of the current quiet window (the schedule applies again next time). */
    fun resumeToday() = scope.launch {
        if (settings.paused) settings.paused = false
        if (settings.quietEnabled) settings.quietSchedule.window(System.currentTimeMillis())?.let { settings.resumedWindowStart = it.startMs }
        settings.save()
        updatePresence()
        changed()
    }

    fun setPaused(paused: Boolean) = scope.launch {
        settings.paused = paused
        settings.save()
        updatePresence()
        changed()
    }

    private fun scheduleChanged() {
        val before = isOnline
        updatePresence()
        // Still online: advertise again so other devices learn the new schedule.
        if (before && isOnline) startNetwork()
    }

    // ------------------------------------------------------------------------------------------ settings

    fun update(block: Settings.() -> Unit) = scope.launch {
        val before = settings.snapshotKey()
        settings.block()
        settings.historyRetentionHours = Retention.clamp(settings.historyRetentionHours)
        settings.save()
        val after = settings.snapshotKey()
        if (before.retention != after.retention) {
            history.setRetention(after.retention)
            log.setRetention(after.retention)
        }
        if (before.quiet != after.quiet) scheduleChanged()
        else if (before.name != after.name) restartNetwork()
        changed()
    }

    private data class SettingsKey(val retention: Int, val quiet: Pair<Boolean, QuietSchedule>, val name: String)

    private fun Settings.snapshotKey() = SettingsKey(historyRetentionHours, quietEnabled to quietSchedule, deviceName.trim())

    // ------------------------------------------------------------------------------------------ groups

    private fun sharedGroup(peer: Peer): GroupSecret? =
        identity?.groups?.firstOrNull { g -> peer.groups.any { it.id == g.id && it.tag == g.key.tag } }

    /** Devices that share at least one group with this one — they get every copy. */
    private fun connectedPeers() = peers.filter { sharedGroup(it) != null }

    private fun membersOf(groupID: String): List<Peer> {
        val g = identity?.groups?.firstOrNull { it.id == groupID } ?: return emptyList()
        return peers.filter { p -> p.groups.any { it.id == g.id && it.tag == g.key.tag } }
    }

    /** Groups advertised on the network that this device hasn't joined, with who is in them. */
    private fun nearbyGroups(): List<NearbyGroup> {
        val mine = settings.groups.map { it.id }.toSet()
        val byKey = LinkedHashMap<String, Pair<AdvertisedGroup, MutableList<String>>>()
        for (peer in peers) for (g in peer.groups) {
            if (g.id in mine) continue
            byKey.getOrPut(g.id + g.tag) { g to mutableListOf() }.second += peer.name
        }
        return byKey.map { (key, value) -> NearbyGroup(key, value.first, value.second) }
            .sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.group.name })
    }

    suspend fun createGroup(name: String, password: String): GroupMembership = withContext(dispatcher) {
        val trimmed = name.trim()
        if (trimmed.isEmpty()) throw GroupException("اكتب اسم للمجموعة")
        if (password.length < Wire.MIN_PASSWORD) throw GroupException("كلمة السر لازم تكون ${Wire.MIN_PASSWORD} أحرف على الأقل")
        val group = GroupMembership(GroupMembership.newID(), trimmed, password, System.currentTimeMillis() / 1000.0)
        saveGroups(settings.groups + group)
        log.add("أنشأت مجموعة «$trimmed»")
        group
    }

    /** Checks the password against the tag the group advertises, then joins for good. */
    suspend fun join(nearbyKey: String, password: String): GroupMembership = withContext(dispatcher) {
        val nearby = nearbyGroups().firstOrNull { it.key == nearbyKey } ?: throw GroupException("المجموعة ما عادت ظاهرة على الشبكة")
        val key = deriveKey(nearby.group.id, password)
        if (key.tag != nearby.group.tag) {
            log.add("كلمة سر خاطئة لمجموعة «${nearby.group.name}»", true)
            changed()
            throw GroupException("كلمة السر غير صحيحة")
        }
        val membership = GroupMembership(nearby.group.id, nearby.group.name, password, System.currentTimeMillis() / 1000.0)
        saveGroups(settings.groups.filter { it.id != membership.id } + membership)
        log.add("انضممت لمجموعة «${membership.name}»")
        membership
    }

    /** Joins from an invite link (QR code). The link carries the password, so no check is needed. */
    suspend fun joinInvite(text: String): GroupMembership = withContext(dispatcher) {
        val invite = GroupInvite.parse(text) ?: throw GroupException("هاد الرمز مش دعوة CoShare")
        var password = invite.passwords.first()
        if (invite.passwords.size > 1) {
            // "+" in the link: pick the reading that matches the tag the group advertises, if it is in sight.
            peers.flatMap { it.groups }.firstOrNull { it.id == invite.id }?.let { advertised ->
                invite.passwords.firstOrNull { deriveKey(invite.id, it).tag == advertised.tag }?.let { password = it }
            }
        }
        val membership = GroupMembership(invite.id, invite.name, password, System.currentTimeMillis() / 1000.0)
        saveGroups(settings.groups.filter { it.id != membership.id } + membership)
        log.add("انضممت لمجموعة «${membership.name}» عن طريق الدعوة")
        membership
    }

    fun leave(groupID: String) = scope.launch {
        val group = settings.groups.firstOrNull { it.id == groupID }
        saveGroups(settings.groups.filter { it.id != groupID })
        if (group != null) log.add("غادرت مجموعة «${group.name}»")
    }

    fun inviteURL(group: GroupMembership) = GroupInvite.url(group)

    private fun saveGroups(groups: List<GroupMembership>) {
        settings.groups = groups
        settings.save()
        if (started && isOnline) startNetwork()
        changed()
    }

    private fun updatePeers(newPeers: List<Peer>) {
        val before = connectedPeers()
        val oldIDs = before.map { it.id }.toSet()
        peers = newPeers
        val now = connectedPeers()
        val newIDs = now.map { it.id }.toSet()
        for (p in now) if (p.id !in oldIDs) log.add("متصل: ${p.name}${if (p.isDirect) " (اتصال مباشر)" else ""}")
        for (p in before) if (p.id !in newIDs) log.add("انقطع: ${p.name}")
        // A device that just (re)joined may hold something copied while we couldn't see each other.
        val joined = now.filter { it.id !in oldIDs }
        if (joined.isNotEmpty()) scope.launch { pullLatest(joined) }
        if (lanUp) {
            val mine = identity?.groups ?: emptyList()
            presenceWatch.update(now.map { peer ->
                PresenceMember(
                    peer.id, peer.name,
                    mine.filter { g -> peer.groups.any { it.id == g.id && it.tag == g.key.tag } }.map { GroupRef(it.id, it.membership.name) },
                )
            })
        }
        changed()
    }

    /** Shows a "came in" / "went out" notification if the person wants that kind (and logs it). */
    fun notifyPresence(event: PresenceEvent) {
        if (!settings.notifyDevices) return
        if (if (event.kind == PresenceKind.LEFT) !settings.notifyLeaves else !settings.notifyJoins) return
        val (title, body) = PresenceWatch.text(event, settings.use24Hour)
        log.add("🔔 $title — $body")
        changed()
        try {
            config.showPresence(event, title, body)
        } catch (e: Exception) {
            log.add("تعذّر إظهار الإشعار: ${e.message ?: e.javaClass.simpleName}", true)
        }
    }

    // ------------------------------------------------------------------------------------------ this clipboard → devices

    private fun markClipboardSeen() {
        lastMark = maxOf(lastMark, clipboard.changeMark() ?: clipboard.currentMark())
        settings.clipMark = lastMark
        settings.save()
    }

    /** Checks the clipboard for a new copy (Android: when the app gets focus, or the clipboard changes while it can read). */
    fun pollNow() = scope.launch { pollClipboard() }

    private fun pollClipboard(): Boolean {
        if (!started) return false
        val mark = clipboard.changeMark() ?: return false
        if (mark <= lastMark) return false
        lastMark = mark
        settings.clipMark = mark
        settings.save()
        if (!isOnline) return false
        val content = clipboard.read(settings.syncImages, Wire.MAX_IMAGE_BYTES)
        if (content == null) {
            val problem = clipboard.lastReadProblem
            if (problem != null && lastReportedProblemMark != mark) {
                lastReportedProblemMark = mark
                log.add(problem, true)
                changed()
            }
            return false
        }
        val hash = content.hash()
        if (hash == currentHash) return false
        currentHash = hash
        currentDate = System.currentTimeMillis() / 1000.0
        scope.launch { broadcast(content, hash) }
        return true
    }

    /** Sends whatever is on the clipboard right now, even if it was already sent. Returns how many devices got it. */
    suspend fun sendCurrentClipboard(): SendResult {
        val content = readClipboard() ?: return SendResult.Empty
        return send(content, copyLocally = false)
    }

    /**
     * Reads the clipboard for an explicit send (button, tile, notification). On Android 10+ the caller must have
     * window focus while this runs; the send itself can finish after it closes.
     */
    suspend fun readClipboard(): ClipContent? = withContext(dispatcher) {
        val content = clipboard.read(settings.syncImages, Wire.MAX_IMAGE_BYTES)
        if (content == null) {
            log.add(clipboard.lastReadProblem ?: "الحافظة فارغة أو محتواها غير مدعوم", true)
            changed()
            return@withContext null
        }
        clipboard.changeMark()?.let {
            lastMark = maxOf(lastMark, it)
            settings.clipMark = lastMark
            settings.save()
        }
        content
    }

    /** Sends some content (share sheet), optionally putting it on this clipboard too. */
    suspend fun send(content: ClipContent, copyLocally: Boolean): SendResult = withContext(dispatcher) {
        if (!isOnline) {
            log.add("ما انبعت شي — ${offlineMessage(presence)}")
            changed()
            return@withContext SendResult.Offline(offlineMessage(presence))
        }
        if (copyLocally) {
            runCatching { clipboard.write(content) }
            clipboard.changeMark()?.let { lastMark = maxOf(lastMark, it) }
        }
        val hash = content.hash()
        currentHash = hash
        currentDate = System.currentTimeMillis() / 1000.0
        waitForPeers(3000)
        broadcast(content, hash)
    }

    sealed class SendResult {
        data object Empty : SendResult()
        data class Offline(val reason: String) : SendResult()
        data object NoGroup : SendResult()
        data object NoDevices : SendResult()
        data class Sent(val delivered: Int, val targets: Int) : SendResult()
    }

    /** Re-copies an item from history; the clipboard watcher then shares it. */
    fun copyItem(id: String) = scope.launch {
        val item = history.items.firstOrNull { it.id == id } ?: return@launch
        val content = history.content(item) ?: return@launch
        try {
            clipboard.write(content)
        } catch (e: Exception) {
            log.add("تعذّرت الكتابة على الحافظة: ${e.message}", true)
        }
        changed()
    }

    fun deleteItem(id: String) = scope.launch {
        history.remove(id)
        changed()
    }

    fun clearHistory() = scope.launch {
        history.clear()
        log.clear()
        changed()
    }

    private suspend fun broadcast(content: ClipContent, hash: String): SendResult {
        val item = history.add(content, hash, settings.deviceName, Direction.SENT, currentDate)
        changed()
        val me = readyIdentity() ?: return SendResult.Offline(offlineMessage(presence))
        if (me.groups.isEmpty()) {
            log.add("نُسخ ${content.label} — هذا الجهاز ليس في أي مجموعة بعد")
            changed()
            return SendResult.NoGroup
        }
        val targets = connectedPeers()
        if (targets.isEmpty()) {
            log.add("نُسخ ${content.label} — لا توجد أجهزة متصلة حالياً")
            changed()
            return SendResult.NoDevices
        }
        val meta = ClipMeta(randomID(), content.kind, content.uti, hash, currentDate, me.name)
        val message = WireMessage(header(MessageType.CLIP, me, meta), content.payload)
        val results = exchange(message, targets, timeoutFor(content.payload.size))
        val delivered = results.count { it.reply?.header?.type == MessageType.ACK }
        history.setDelivered(item.id, delivered)
        log.add("أُرسل ${content.label} إلى $delivered من ${targets.size} أجهزة")
        for (r in results) if (r.reply == null) log.add("تعذّر الإرسال إلى ${r.peer.name}: ${r.error?.let { PeerNetwork.describe(it) } ?: ""}", true)
        changed()
        return SendResult.Sent(delivered, targets.size)
    }

    // ------------------------------------------------------------------------------------------ devices → this clipboard

    private fun handle(message: WireMessage, @Suppress("UNUSED_PARAMETER") group: GroupSecret): WireMessage? {
        val me = identity ?: return null
        return when (message.header.type) {
            MessageType.CLIP -> {
                message.header.clip?.let { meta ->
                    ClipContent.from(meta.kind, meta.uti, message.payload)?.let { apply(it, meta, meta.origin ?: message.header.senderName) }
                }
                WireMessage(header(MessageType.ACK, me))
            }
            MessageType.PULL_LATEST -> {
                val item = history.items.firstOrNull()
                val content = item?.let { history.content(it) } ?: return WireMessage(header(MessageType.NOTHING, me))
                val meta = ClipMeta(item.id, item.kind, item.uti, item.hash, item.date, item.deviceName)
                WireMessage(header(MessageType.LATEST, me, meta), content.payload)
            }
            else -> WireMessage(header(MessageType.ACK, me))
        }
    }

    private fun apply(content: ClipContent, meta: ClipMeta, sender: String): Boolean {
        if (meta.id in seenClipIDs) return false
        seenClipIDs.addLast(meta.id)
        if (seenClipIDs.size > 200) repeat(50) { seenClipIDs.removeFirst() }
        if (!isOnline || meta.hash == currentHash) return false
        if (content is ClipContent.Image && !settings.syncImages) return false
        try {
            clipboard.write(content)
        } catch (e: Exception) {
            log.add("تعذّرت الكتابة على الحافظة: ${e.message}", true)
            changed()
            return false
        }
        clipboard.changeMark()?.let { lastMark = maxOf(lastMark, it) }
        currentHash = meta.hash
        currentDate = meta.createdAt
        history.add(content, meta.hash, sender, Direction.RECEIVED, meta.createdAt)
        log.add("استُلم ${content.label} من $sender — جاهز للصق")
        changed()
        return true
    }

    /** Asks devices for their newest clip and applies it if it is newer than ours. */
    suspend fun pullLatest(specific: List<Peer>? = null): Boolean = withContext(dispatcher) {
        if (!isOnline) return@withContext false
        val me = readyIdentity() ?: return@withContext false
        if (specific == null) waitForPeers(3000)
        val targets = specific ?: connectedPeers()
        if (targets.isEmpty()) return@withContext false
        val results = exchange(WireMessage(header(MessageType.PULL_LATEST, me)), targets, 20_000)
        val newest = results.mapNotNull { it.reply }
            .filter { it.header.type == MessageType.LATEST && it.header.clip != null }
            .maxByOrNull { it.header.clip!!.createdAt } ?: return@withContext false
        val meta = newest.header.clip!!
        if (meta.createdAt <= currentDate) return@withContext false
        val content = ClipContent.from(meta.kind, meta.uti, newest.payload) ?: return@withContext false
        apply(content, meta, meta.origin ?: newest.header.senderName)
    }

    // ------------------------------------------------------------------------------------------ helpers

    private suspend fun waitForPeers(timeoutMs: Long) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (connectedPeers().isEmpty() && System.currentTimeMillis() < deadline) delay(150)
    }

    private suspend fun readyIdentity(): LocalIdentity? {
        val deadline = System.currentTimeMillis() + 5000
        while (identity == null && isOnline && System.currentTimeMillis() < deadline) delay(100)
        return identity
    }

    private fun header(type: MessageType, me: LocalIdentity, clip: ClipMeta? = null) =
        WireHeader(type, me.id, me.name, me.platform, clip)

    private class ExchangeResult(val peer: Peer, val reply: WireMessage?, val error: Throwable?)

    /** Sends `message` to every target, sealed once per shared group (not once per device). */
    private suspend fun exchange(message: WireMessage, targets: List<Peer>, timeoutMs: Long): List<ExchangeResult> {
        val frames = HashMap<String, ByteArray>()
        val jobs = targets.mapNotNull { peer ->
            val group = sharedGroup(peer) ?: return@mapNotNull null
            val frame = frames[group.id] ?: try {
                withContext(Dispatchers.Default) { message.frame(group.key) }.also { frames[group.id] = it }
            } catch (e: Exception) {
                return@mapNotNull scope.async { ExchangeResult(peer, null, e) }
            }
            scope.async {
                try {
                    ExchangeResult(peer, network.exchange(frame, group.key, peer, timeoutMs), null)
                } catch (e: Exception) {
                    ExchangeResult(peer, null, e)
                }
            }
        }
        return jobs.awaitAll()
    }

    /** Generous timeout for big screenshots on slow Wi-Fi. */
    private fun timeoutFor(bytes: Int): Long = minOf(120_000L, 8000L + bytes / 1000L)

    private fun changed() {
        changeJob?.cancel()
        changeJob = scope.launch {
            delay(50)
            _state.value = snapshot()
        }
    }

    private fun snapshot(): EngineState {
        fun info(p: Peer) = DeviceInfo(p.id, p.name, p.platform, p.isDirect)
        val connected = connectedPeers()
        return EngineState(
            presence = presence,
            peers = peers.map(::info),
            connected = connected.map(::info),
            groups = settings.groups.map { g ->
                GroupInfo(g, membersOf(g.id).map(::info).sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.name }))
            },
            nearby = nearbyGroups(),
            history = history.items,
            log = log.entries.take(300),
            settings = SettingsSnapshot(
                deviceName = settings.deviceName,
                syncImages = settings.syncImages,
                quietEnabled = settings.quietEnabled,
                quietSchedule = settings.quietSchedule,
                startOnBoot = settings.startOnBoot,
                keepRunning = settings.keepRunning,
                use24Hour = settings.use24Hour,
                historyRetentionHours = settings.historyRetentionHours,
                introSeen = settings.introSeen,
                notifyDevices = settings.notifyDevices,
                notifyJoins = settings.notifyJoins,
                notifyLeaves = settings.notifyLeaves,
            ),
            blobDir = history.blobs,
            listenPort = network.listenPort,
        )
    }
}

/** "3:45 PM" or "15:45", kept in that order inside Arabic text. */
object TimeFormat {
    // Left-to-right isolate: keeps "3:45 PM" or "125 KB" in that order inside Arabic text.
    private val LRI = String(Character.toChars(0x2066))
    private val PDI = String(Character.toChars(0x2069))

    fun isolate(text: String) = LRI + text + PDI

    fun clock(ms: Long, h24: Boolean): String = isolate(pattern(if (h24) "HH:mm" else "h:mm a").format(java.util.Date(ms)))
    fun time(ms: Long, h24: Boolean): String = isolate(pattern(if (h24) "HH:mm:ss" else "h:mm:ss a").format(java.util.Date(ms)))

    private fun pattern(p: String) = java.text.SimpleDateFormat(p, java.util.Locale.US).apply {
        dateFormatSymbols = dateFormatSymbols.apply { amPmStrings = arrayOf("AM", "PM") }
    }
}
