package com.ehabk.coshare.core

// Finds devices and talks to them — the Kotlin twin of Shared/PeerNetwork.swift and desktop/src/core/network.js.
// Every device listens on a (preferably fixed) TCP port and is found by mDNS (_coshare._tcp) or by greeting
// the gateway / addresses seen before with a "hello" (hotspots, networks that filter mDNS).
// All state lives on the engine's single thread; sockets and crypto run on the IO / Default pools.

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

data class Peer(
    val id: String,
    val name: String,
    val platform: String,
    /** Groups the device advertises (or told us about in a hello). */
    val groups: List<AdvertisedGroup>,
    val host: String,
    val port: Int,
    /** Found by contacting its address directly rather than through mDNS (hotspots, filtered networks). */
    val isDirect: Boolean,
    val quiet: QuietSchedule? = null,
)

/** A joined group with its derived key, ready for the network layer. */
class GroupSecret(val membership: GroupMembership, val key: GroupKey) {
    val id: String get() = membership.id
    val advertised: AdvertisedGroup get() = AdvertisedGroup(membership.id, key.tag, membership.name)
}

class LocalIdentity(
    val id: String,
    val name: String,
    val platform: String,
    val groups: List<GroupSecret>,
    /** Shared with other devices so they don't call during these hours. */
    val quiet: QuietSchedule?,
) {
    /** Opens a frame with whichever of our group keys fits; null if it belongs to no group of ours. */
    fun open(sealed: ByteArray): Pair<WireMessage, GroupSecret>? {
        for (group in groups) {
            try {
                return WireMessage.open(sealed, group.key) to group
            } catch (_: Exception) {
            }
        }
        return null
    }

    /** The mDNS TXT record: n, p, i, v="2", g0…g7 = "id|tag|name", q = "days|start|end". */
    fun txtRecord(): Map<String, String> = buildMap {
        put("n", name)
        put("p", platform)
        put("i", id)
        put("v", "2")
        groups.take(8).forEachIndexed { index, group -> put("g$index", group.advertised.txtValue) }
        quiet?.let { put("q", it.txtValue) }
    }
}

/** One mDNS result: service name, TXT values, and where it listens. */
data class DiscoveredService(val name: String, val txt: Map<String, String>, val host: String, val port: Int)

/** The platform's mDNS (Android NSD). Callbacks may arrive on any thread. */
interface ServiceDiscovery {
    fun start(me: LocalIdentity, port: Int, onServices: (List<DiscoveredService>) -> Unit, onEvent: (String, Boolean) -> Unit)
    /** Looks again now (results can go stale, TXT records change). */
    fun refresh()
    fun stop()
}

/** Thrown when nothing answers at an address at all (a normal router), as opposed to a failed exchange. */
class ConnectFailed(cause: Exception) : IOException(cause.message, cause)

class PeerNetwork(
    private val scope: CoroutineScope,
    private val settings: Settings,
    private val discovery: ServiceDiscovery?,
    private val gatewaySource: () -> List<String>,
    private val preferredPort: Int = Wire.PREFERRED_PORT,
    private val extraHosts: List<String> = emptyList(),
    private val prepareSocket: (Socket, String) -> Unit = { _, _ -> },
) {
    var onPeers: (List<Peer>) -> Unit = {}
    var onEvent: (String, Boolean) -> Unit = { _, _ -> }
    var onRequest: suspend (WireMessage, GroupSecret) -> WireMessage? = { _, _ -> null }
    /** A device said bye: quiet until the time (ms), or paused when null. Called before it drops out of the list. */
    var onBye: (String, Long?) -> Unit = { _, _ -> }

    /** The port we listen on, sent along in hello and bye messages. */
    var listenPort = 0
        private set

    internal var identity: LocalIdentity? = null
    private var generation = 0
    private var server: ServerSocket? = null
    private val jobs = mutableListOf<Job>()
    private var gateways: List<String> = emptyList()
    internal var browsed: Map<String, Peer> = emptyMap()
    private val direct = HashMap<String, Pair<Peer, Long>>()
    private val silenced = HashMap<String, Long>()
    private val silencedAddresses = HashMap<String, Pair<String, Long>>()
    private val lastGreeted = HashMap<String, Long>()
    /** Last time each device answered us or called us (hello either way, anything we could decrypt). */
    internal val lastContact = ConcurrentHashMap<String, Long>()
    /** When each device listed by mDNS first showed up (this session). */
    internal val firstSeen = HashMap<String, Long>()
    /**
     * When each device said bye. Its goodbye takes a moment to reach mDNS, so an advertisement seen right after
     * is the old one, not the device coming back (a hello still is).
     */
    internal val byeAt = HashMap<String, Long>()

    fun start(me: LocalIdentity) {
        tearDown()
        identity = me
        val gen = ++generation
        startServer(me, gen, preferredPort, 0)
        jobs += scope.launch {
            while (true) {
                refreshGateways()
                delay(60_000)
            }
        }
        jobs += scope.launch {
            while (true) {
                delay(15_000)
                runDirectProbe()
            }
        }
        if (discovery != null) {
            jobs += scope.launch {
                while (true) {
                    delay(30_000)
                    discovery.refresh()
                }
            }
        }
    }

    fun stop() {
        tearDown()
        generation++
        identity = null
        listenPort = 0
        onPeers(emptyList())
    }

    /** Looks for devices again without dropping the current connections. */
    fun refreshDiscovery() {
        discovery?.refresh()
        scope.launch { refreshGateways() }
    }

    // ------------------------------------------------------------------------------------------ server

    /** `attempt` counts retries of the fixed port: right after a restart the old listener may still hold it. */
    private fun startServer(me: LocalIdentity, gen: Int, port: Int, attempt: Int) {
        if (gen != generation) return
        val socket = try {
            ServerSocket().apply {
                reuseAddress = true
                bind(InetSocketAddress(port), 50)
            }
        } catch (e: IOException) {
            when {
                port != 0 && attempt < 12 -> jobs += scope.launch { delay(500); startServer(me, gen, port, attempt + 1) }
                port != 0 -> {
                    // Something else really owns the port: mDNS still works on any free port.
                    onEvent("المنفذ $port مشغول — الاتصال المباشر (Hotspot) قد لا يعمل", true)
                    startServer(me, gen, 0, 0)
                }
                else -> {
                    onEvent("تعذّر فتح منفذ الاستقبال: ${describe(e)}", true)
                    jobs += scope.launch { delay(3000); startServer(me, gen, preferredPort, 0) }
                }
            }
            return
        }
        server = socket
        listenPort = socket.localPort
        onEvent("جاهز للاستقبال على المنفذ $listenPort", false)
        discovery?.start(me, listenPort, { services -> scope.launch { if (gen == generation) syncBrowsed(services, me) } }) { text, isError ->
            scope.launch { if (gen == generation) onEvent(text, isError) }
        }
        runDirectProbe()
        jobs += scope.launch(Dispatchers.IO) {
            while (true) {
                val client = try {
                    socket.accept()
                } catch (e: IOException) {
                    // Closed by tearDown, or the network went away under us: listen again.
                    scope.launch {
                        if (gen == generation && server === socket) {
                            onEvent("توقف الاستقبال (${describe(e)}) — إعادة المحاولة", true)
                            server = null
                            delay(2000)
                            startServer(me, gen, preferredPort, 0)
                        }
                    }
                    break
                }
                scope.launch { serve(client, me) }
            }
        }
    }

    private suspend fun serve(socket: Socket, me: LocalIdentity) {
        var senderName: String? = null
        try {
            val body = withContext(Dispatchers.IO) {
                socket.tcpNoDelay = true
                socket.soTimeout = 120_000
                readFrame(socket.getInputStream())
            }
            // Anything we can't decrypt (another group, a stranger, a port scan) is dropped silently.
            val (request, group) = withContext(Dispatchers.Default) { me.open(body) } ?: return
            senderName = request.header.senderName
            if (request.header.type != MessageType.BYE) lastContact[request.header.senderID] = System.currentTimeMillis()
            val remote = cleanAddress(socket.inetAddress?.hostAddress)
            val header = request.header
            val reply = when (header.type) {
                MessageType.HELLO -> {
                    learnDirectPeer(header, remote, group, me)
                    helloMessage(me)
                }
                MessageType.BYE -> {
                    silence(header.senderID, header.quietUntil, header.senderName, remote, header.listenPort)
                    WireMessage(WireHeader(MessageType.ACK, me.id, me.name, me.platform))
                }
                else -> {
                    greetIfUnknown(header.senderID, remote, me)
                    onRequest(request, group)
                }
            } ?: return
            withContext(Dispatchers.IO) {
                socket.getOutputStream().apply {
                    write(reply.frame(group.key))
                    flush()
                }
                // Let the client read the reply before the socket goes away.
                socket.soTimeout = 5000
                try {
                    socket.getInputStream().read()
                } catch (_: IOException) {
                }
            }
        } catch (e: Exception) {
            if (senderName != null) onEvent("خطأ أثناء الرد على «$senderName»: ${describe(e)}", true)
        } finally {
            closeQuietly(socket)
        }
    }

    // ------------------------------------------------------------------------------------------ client

    /** Connects, sends one frame sealed with `key` and returns the decoded reply. */
    suspend fun exchange(frame: ByteArray, key: GroupKey, peer: Peer, timeoutMs: Long): WireMessage {
        val body = withContext(Dispatchers.IO) {
            val socket = Socket()
            val watchdog = closeAfter(socket, timeoutMs)
            try {
                socket.tcpNoDelay = true
                try {
                    prepareSocket(socket, peer.host)
                    socket.connect(InetSocketAddress(peer.host, peer.port), timeoutMs.coerceAtMost(5000).toInt())
                } catch (e: IOException) {
                    throw ConnectFailed(e)
                }
                if (!peer.isDirect) {
                    val address = cleanAddress(socket.inetAddress?.hostAddress)
                    scope.launch { saveKnownHost(address, peer.id) }
                }
                socket.soTimeout = timeoutMs.toInt()
                socket.getOutputStream().apply {
                    write(frame)
                    flush()
                }
                readFrame(socket.getInputStream())
            } finally {
                watchdog.cancel(false)
                closeQuietly(socket)
            }
        }
        val reply = withContext(Dispatchers.Default) { WireMessage.open(body, key) }
        if (peer.id.isNotEmpty()) lastContact[peer.id] = System.currentTimeMillis()
        return reply
    }

    // ------------------------------------------------------------------------------------------ mDNS

    internal fun syncBrowsed(services: List<DiscoveredService>, me: LocalIdentity) {
        val next = HashMap<String, Peer>()
        for (service in services) {
            val txt = service.txt
            if (txt["v"] != "2") continue
            val id = txt["i"] ?: service.name
            // Skip ourselves — including a second copy of this app, which mDNS renames "<id> (2)".
            if (id == me.id || service.name == me.id || service.name.startsWith(me.id + " (")) continue
            if (service.host.isEmpty() || service.port <= 0) continue
            if (System.currentTimeMillis() - (byeAt[id] ?: 0) < 10_000) continue
            val groups = (0 until 8).mapNotNull { AdvertisedGroup.parse(txt["g$it"]) }
            val quiet = QuietSchedule.parse(txt["q"])
            // Keep an IPv6 link-local address's "%wlan0" scope: without it the address can't be reached.
            next[id] = Peer(id, txt["n"] ?: service.name, txt["p"] ?: "other", groups, service.host.removePrefix("::ffff:"), service.port, false, quiet)
            // Advertising again means it is back (e.g. "resume today").
            unsilence(id)
            saveSchedule(id, quiet)
        }
        browsed = next
        publishMerged()
    }

    // ------------------------------------------------------------------------------------------ direct contact

    private fun helloMessage(me: LocalIdentity) = WireMessage(
        WireHeader(
            type = MessageType.HELLO, senderID = me.id, senderName = me.name, platform = me.platform,
            listenPort = listenPort, groups = me.groups.map { it.advertised }, quiet = me.quiet,
        ),
    )

    private suspend fun refreshGateways() {
        gateways = withContext(Dispatchers.IO) { runCatching(gatewaySource).getOrDefault(emptyList()) }
        runDirectProbe()
    }

    /** Greets the gateway and every address a group member had before; whoever answers becomes a peer. */
    fun runDirectProbe() {
        val me = identity ?: return
        if (me.groups.isEmpty() || listenPort == 0) return
        val gen = generation
        val now = System.currentTimeMillis()
        // Never call a device during its quiet hours (or after it said bye): even a refused connection
        // would show up as traffic on a monitored work computer.
        // An fe80:: address saved without its interface can never be called again: skip it.
        val known = settings.knownHosts.filterValues { !isUnscopedLinkLocal(it) }
        val quietHosts = known.filterKeys { isQuiet(it) }.values.toMutableSet()
        for ((address, info) in silencedAddresses) if (info.second > now) quietHosts += address
        val hosts = (gateways + known.values + extraHosts).toSet() - quietHosts
        for (host in hosts) scope.launch { sayHello(host, me, gen) }
        // Group devices mDNS lists but we haven't heard from lately: greet them where mDNS says they are.
        // An answer keeps them listed (see isAlive) and teaches us their address.
        for (peer in browsed.values) {
            if (isQuiet(peer.id) || now - (lastContact[peer.id] ?: 0) < 20_000) continue
            val keys = me.groups.filter { g -> peer.groups.any { it.id == g.id && it.tag == g.key.tag } }
            if (keys.isNotEmpty()) scope.launch { greet(peer, keys, me, gen) }
        }
        // Forget direct peers that stopped answering.
        direct.entries.removeAll { now - it.value.second > 50_000 }
        publishMerged()
    }

    /** Says hello to a device found by mDNS, with each shared key in turn until one is understood. */
    private suspend fun greet(peer: Peer, keys: List<GroupSecret>, me: LocalIdentity, gen: Int) {
        for (group in keys) {
            val frame = withContext(Dispatchers.Default) { helloMessage(me).frame(group.key) }
            val reply = try {
                exchange(frame, group.key, peer, 4000)
            } catch (_: ConnectFailed) {
                return
            } catch (_: Exception) {
                continue
            }
            if (reply.header.type != MessageType.HELLO || gen != generation) return
            unsilence(peer.id)
            saveSchedule(peer.id, reply.header.quiet)
            publishMerged()
            return
        }
    }

    private suspend fun sayHello(address: String, me: LocalIdentity, gen: Int) {
        val (host, port) = splitAddress(address)
        for (group in me.groups) {
            val frame = withContext(Dispatchers.Default) { helloMessage(me).frame(group.key) }
            val reply = try {
                exchange(frame, group.key, Peer("", "", "", emptyList(), host, port, true), 4000)
            } catch (_: ConnectFailed) {
                return // nothing listening there (a normal router)
            } catch (_: Exception) {
                continue // connected but not our group: try the next key
            }
            val h = reply.header
            if (h.type != MessageType.HELLO || h.senderID == me.id || gen != generation) return
            lastContact[h.senderID] = System.currentTimeMillis()
            unsilence(h.senderID)
            saveSchedule(h.senderID, h.quiet)
            rememberDirect(Peer(h.senderID, h.senderName, h.platform, h.groups ?: emptyList(), host, port, true, h.quiet))
            saveKnownHost(address, h.senderID)
            return
        }
    }

    /** The other side of a hello: remember where the sender can be reached. */
    private fun learnDirectPeer(header: WireHeader, host: String, group: GroupSecret, me: LocalIdentity) {
        // Our own hello coming back (an address that turned out to be this device).
        if (header.senderID == me.id) return
        val port = header.listenPort ?: return
        if (port <= 0 || host.isEmpty()) return
        lastContact[header.senderID] = System.currentTimeMillis()
        unsilence(header.senderID)
        saveSchedule(header.senderID, header.quiet)
        rememberDirect(
            Peer(header.senderID, header.senderName, header.platform, header.groups ?: listOf(group.advertised), host, port, true, header.quiet),
        )
        saveKnownHost(host, header.senderID)
    }

    /** Publishes when the device is new or changed (renamed, joined or left a group, new quiet hours). */
    private fun rememberDirect(peer: Peer) {
        val before = direct[peer.id]?.first
        direct[peer.id] = peer to System.currentTimeMillis()
        if (before != peer) publishMerged()
    }

    /**
     * A group member reached us but we can't see it (its mDNS record never arrived here): greet it back on
     * the standard port, so sending works both ways.
     */
    private fun greetIfUnknown(senderID: String, host: String, me: LocalIdentity) {
        if (host.isEmpty() || senderID == me.id || senderID in direct || senderID in browsed) return
        val now = System.currentTimeMillis()
        if (now - (lastGreeted[host] ?: 0) < 30_000) return
        lastGreeted[host] = now
        val gen = generation
        scope.launch { sayHello(host, me, gen) }
    }

    internal fun silence(deviceID: String, untilSeconds: Double?, name: String, host: String, listenPort: Int?) {
        val said = untilSeconds?.let { (it * 1000).toLong() }
        val until = said ?: (System.currentTimeMillis() + 12 * 3600 * 1000L)
        byeAt[deviceID] = System.currentTimeMillis()
        silenced[deviceID] = until
        // Also its address, in case we only know it as an address (gateway, not yet greeted).
        if (host.isNotEmpty()) {
            silencedAddresses[host] = deviceID to until
            if (listenPort != null) silencedAddresses[joinAddress(host, listenPort)] = deviceID to until
        }
        direct.remove(deviceID)
        browsed = browsed - deviceID
        // Reported before the device drops out of the list, so its "out" can say why.
        onBye(deviceID, said)
        publishMerged()
        onEvent("«$name» دخل وقت الإيقاف — لن نتصل به حتى يعود", false)
    }

    private fun unsilence(deviceID: String) {
        byeAt.remove(deviceID)
        silenced.remove(deviceID)
        silencedAddresses.entries.removeAll { it.value.first == deviceID }
    }

    /** Said bye recently, or inside the quiet hours it told us about. */
    private fun isQuiet(deviceID: String): Boolean {
        silenced[deviceID]?.let { if (it > System.currentTimeMillis()) return true }
        return QuietSchedule.parse(settings.peerSchedules[deviceID])?.window(System.currentTimeMillis()) != null
    }

    private fun saveSchedule(deviceID: String, quiet: QuietSchedule?) {
        val value = quiet?.txtValue
        if (settings.peerSchedules[deviceID] == value) return
        if (value != null) settings.peerSchedules[deviceID] = value else settings.peerSchedules.remove(deviceID)
        settings.save()
    }

    internal fun saveKnownHost(host: String, deviceID: String) {
        if (host.isEmpty() || deviceID.isEmpty()) return
        val isLoopback = host.startsWith("127.") || host == "::1"
        if (isLoopback && extraHosts.isEmpty()) return
        // fe80:: means nothing without the interface it belongs to: calling it later always fails.
        if (isUnscopedLinkLocal(host)) return
        if (settings.knownHosts[deviceID] == host) return
        settings.knownHosts[deviceID] = host
        while (settings.knownHosts.size > 20) settings.knownHosts.remove(settings.knownHosts.keys.first())
        settings.save()
    }

    /**
     * A device of one of our groups is listed only while it answers: a minute from when it showed up or was last
     * heard from. Devices of other groups are only shown as "nearby", so mDNS is enough for them.
     */
    private fun isAlive(peer: Peer, now: Long): Boolean {
        val me = identity ?: return true
        if (peer.groups.none { g -> me.groups.any { it.id == g.id && it.key.tag == g.tag } }) return true
        return now - maxOf(lastContact[peer.id] ?: 0, firstSeen[peer.id] ?: 0) < LIVENESS_MS
    }

    internal fun publishMerged() {
        val now = System.currentTimeMillis()
        for (id in browsed.keys) firstSeen.putIfAbsent(id, now)
        firstSeen.keys.retainAll(browsed.keys)
        val merged = LinkedHashMap<String, Peer>()
        for ((id, entry) in direct) if ((silenced[id] ?: 0) <= now) merged[id] = entry.first
        for ((id, peer) in browsed) if (isAlive(peer, now)) merged[id] = peer
        identity?.let { merged.remove(it.id) }
        onPeers(merged.values.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.name }))
    }

    private fun tearDown() {
        server?.let { closeQuietly(it) }
        server = null
        jobs.forEach { it.cancel() }
        jobs.clear()
        discovery?.stop()
        browsed = emptyMap()
        direct.clear()
        lastContact.clear()
        firstSeen.clear()
    }

    companion object {
        /** A device of our groups that hasn't been heard from for this long is gone, even if mDNS still lists it. */
        const val LIVENESS_MS = 60_000L

        fun isUnscopedLinkLocal(host: String) = host.lowercase().startsWith("fe80:") && '%' !in host

        private val watchdogs = Executors.newSingleThreadScheduledExecutor { r ->
            Thread(r, "coshare-timeouts").apply { isDaemon = true }
        }

        /** One deadline for the whole exchange: a peer trickling bytes can't hold a socket forever. */
        private fun closeAfter(socket: Socket, ms: Long): ScheduledFuture<*> =
            watchdogs.schedule({ closeQuietly(socket) }, ms, TimeUnit.MILLISECONDS)

        /** Reads exactly one length-prefixed frame body. */
        fun readFrame(input: InputStream): ByteArray {
            val head = readFully(input, 4)
            val length = head.readUInt32(0)
            if (length <= 0 || length > Wire.MAX_FRAME) throw WireException("الملف أكبر من الحد المسموح")
            return readFully(input, length.toInt())
        }

        private fun readFully(input: InputStream, count: Int): ByteArray {
            val buffer = ByteArray(count)
            var offset = 0
            while (offset < count) {
                val n = input.read(buffer, offset, count - offset)
                if (n < 0) throw EOFException("انقطع الاتصال")
                offset += n
            }
            return buffer
        }

        fun cleanAddress(address: String?): String =
            (address ?: "").removePrefix("/").removePrefix("::ffff:").substringBefore('%')

        /** "host:port" or "[v6]:port" (tests); a bare host uses the standard port. */
        fun splitAddress(address: String, defaultPort: Int = Wire.PREFERRED_PORT): Pair<String, Int> {
            Regex("""^\[(.+)]:(\d+)$""").find(address)?.let { return it.groupValues[1] to it.groupValues[2].toInt() }
            Regex("""^([^:]+):(\d+)$""").find(address)?.let { return it.groupValues[1] to it.groupValues[2].toInt() }
            return address to defaultPort
        }

        fun joinAddress(host: String, port: Int) = if (host.contains(':')) "[$host]:$port" else "$host:$port"

        /** Short Arabic reason for a failed exchange, for the activity log. */
        fun describe(error: Throwable): String = when (error) {
            is ConnectFailed -> "تعذّر الاتصال"
            is SocketTimeoutException -> "انتهت المهلة"
            is EOFException -> "انقطع الاتصال"
            is WireException -> error.message ?: "رسالة غير صالحة"
            is java.net.SocketException -> if (error.message?.contains("closed", true) == true) "انتهت المهلة" else "انقطع الاتصال"
            is org.bouncycastle.crypto.InvalidCipherTextException -> "رسالة غير صالحة"
            else -> error.message ?: error.javaClass.simpleName
        }

        private fun closeQuietly(closeable: java.io.Closeable) {
            try {
                closeable.close()
            } catch (_: Exception) {
            }
        }
    }
}
