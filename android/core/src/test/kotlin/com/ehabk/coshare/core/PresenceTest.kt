package com.ehabk.coshare.core

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.After
import java.io.File
import java.nio.file.Files
import java.time.LocalDateTime
import java.time.ZoneId
import java.util.concurrent.Executors
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * "Device in / out" notifications: the rules (the same cases as desktop/test/presence.test.js and TestPeer's
 * presencetest), the words, the settings, and the network's liveness checks that feed them.
 */
class PresenceTest {
    private val tmp: File = Files.createTempDirectory("coshare-presence").toFile()
    private val executor = Executors.newSingleThreadExecutor()
    private val scope = CoroutineScope(SupervisorJob() + executor.asCoroutineDispatcher())
    private var engine: SyncEngine? = null

    @After
    fun tearDown() {
        engine?.shutdown()
        scope.cancel()
        executor.shutdown()
        tmp.deleteRecursively()
    }

    private val home = GroupRef("G1", "البيت")
    private val work = GroupRef("G2", "الشغل")
    private val a = PresenceMember("A", "iPhone", listOf(home))
    private val b = PresenceMember("B", "Windows", listOf(home))

    private class Watcher(saved: Map<String, List<String>> = emptyMap()) {
        var store: Map<String, List<String>> = saved
        val watch = PresenceWatch(saved.mapValues { it.value.toSet() }, { store = it })
        private val events = mutableListOf<PresenceEvent>()

        init {
            watch.onEvent = { events += it }
        }

        fun take(): List<PresenceEvent> = events.toList().also { events.clear() }
    }

    @Test
    fun theRules() {
        val w = Watcher()
        val watch = w.watch
        val t0 = 1_000_000L
        fun at(s: Int) = t0 + s * 1000L

        watch.settle(t0)
        watch.update(listOf(a), at(1))
        assertEquals(emptyList(), w.take(), "quiet while connecting")

        watch.update(listOf(a, b), at(25))
        assertEquals(listOf(PresenceEvent(PresenceKind.JOINED, b)), w.take(), "new device → joined")

        watch.update(listOf(b), at(30))
        watch.tick(at(40))
        watch.update(listOf(a, b), at(45))
        watch.tick(at(90))
        assertEquals(emptyList(), w.take(), "short drop → nothing")

        watch.update(listOf(b), at(50))
        watch.tick(at(50) + PresenceWatch.LEAVE_GRACE_MS - 1000)
        assertEquals(emptyList(), w.take(), "no 'out' before the grace time")
        watch.tick(at(50) + PresenceWatch.LEAVE_GRACE_MS + 1000)
        assertEquals(listOf(PresenceEvent(PresenceKind.LEFT, a, LeaveReason.Lost)), w.take(), "gone → out (lost)")

        watch.update(listOf(a, b), at(100))
        assertEquals(listOf(PresenceEvent(PresenceKind.BACK, a)), w.take(), "returning device → back")

        val until = at(3600)
        watch.bye("A", until)
        watch.update(listOf(b), at(110))
        assertEquals(listOf(PresenceEvent(PresenceKind.LEFT, a, LeaveReason.Quiet(until))), w.take(), "bye (quiet) → out at once")

        watch.update(emptyList(), at(120))
        watch.bye("B", null)
        watch.tick(at(200))
        assertEquals(listOf(PresenceEvent(PresenceKind.LEFT, b, LeaveReason.Paused)), w.take(), "drop then bye → one out (paused)")

        watch.update(listOf(a), at(300))
        w.take()
        watch.update(emptyList(), at(310))
        watch.settle(at(311))
        watch.tick(at(400))
        assertEquals(emptyList(), w.take(), "own reconnect cancels a pending out")

        watch.update(listOf(a, b), at(500))
        w.take()
        watch.reset()
        watch.settle(at(600))
        watch.update(listOf(a, b), at(601))
        watch.tick(at(700))
        assertEquals(emptyList(), w.take(), "own quiet hours → nothing")

        // Who was ever in a group survives a restart; a new group for a known device is "joined" for that group.
        val again = Watcher(w.store)
        again.watch.update(listOf(a), at(800))
        assertEquals(listOf(PresenceEvent(PresenceKind.BACK, a)), again.take(), "remembered after restart → back")
        again.watch.update(emptyList(), at(810))
        again.watch.update(listOf(a.copy(groups = listOf(home, work))), at(815))
        assertEquals(listOf(PresenceEvent(PresenceKind.JOINED, a.copy(groups = listOf(work)))), again.take(), "known device in a new group → joined it")
        assertEquals(mapOf("G1" to listOf("A", "B"), "G2" to listOf("A")), again.store)
    }

    @Test
    fun theWordsMatchTheAppleApps() {
        val c = PresenceMember("C", "Linux", listOf(home, work))
        assertEquals("جهاز جديد انضم: Linux" to "صار بمجموعات «البيت» و«الشغل»", PresenceWatch.text(PresenceEvent(PresenceKind.JOINED, c), false))
        assertEquals("iPhone رجع متصل" to "بمجموعة «البيت»", PresenceWatch.text(PresenceEvent(PresenceKind.BACK, a), false))
        val (outTitle, outBody) = PresenceWatch.text(PresenceEvent(PresenceKind.LEFT, a, LeaveReason.Lost), false)
        assertEquals("iPhone طلع", outTitle)
        assertEquals("انقطع: طلع من الشبكة، أو نام، أو انسكّر CoShare عليه · بمجموعة «البيت»", outBody)
        assertEquals("وقّف المشاركة · بمجموعة «البيت»", PresenceWatch.text(PresenceEvent(PresenceKind.LEFT, a, LeaveReason.Paused), false).second)
        val at1545 = LocalDateTime.of(2026, 1, 1, 15, 45).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
        val quiet12 = PresenceWatch.text(PresenceEvent(PresenceKind.LEFT, a, LeaveReason.Quiet(at1545)), false).second
        val quiet24 = PresenceWatch.text(PresenceEvent(PresenceKind.LEFT, a, LeaveReason.Quiet(at1545)), true).second
        assertTrue(quiet12.startsWith("دخل وقت الإيقاف لحد ") && "3:45 PM" in quiet12 && quiet12.endsWith(" · بمجموعة «البيت»"), quiet12)
        assertTrue("15:45" in quiet24 && "PM" !in quiet24, quiet24)
    }

    @Test
    fun settingsDecideWhatIsShownAllOnByDefault() = runBlocking {
        val shown = mutableListOf<PresenceKind>()
        val e = SyncEngine(EngineConfig(File(tmp, "e"), "android", "T", FakeClipboard(), showPresence = { event, _, _ -> shown += event.kind }))
        engine = e
        val s = e.state.value.settings
        assertTrue(s.notifyDevices && s.notifyJoins && s.notifyLeaves)
        val out = PresenceEvent(PresenceKind.LEFT, a, LeaveReason.Lost)
        val back = PresenceEvent(PresenceKind.BACK, a)
        fun both() {
            e.notifyPresence(out)
            e.notifyPresence(back)
        }
        both()
        e.update { notifyLeaves = false }.join()
        both()
        e.update { notifyLeaves = true; notifyJoins = false }.join()
        both()
        e.update { notifyDevices = false }.join()
        both()
        assertEquals(listOf(PresenceKind.LEFT, PresenceKind.BACK, PresenceKind.BACK, PresenceKind.LEFT), shown)
        assertTrue(e.log.entries.any { it.text == "🔔 iPhone طلع — انقطع: طلع من الشبكة، أو نام، أو انسكّر CoShare عليه · بمجموعة «البيت»" })
        // Saved: a restart keeps the switches.
        val reloaded = Settings(File(tmp, "e/settings.json"), "T")
        assertTrue(!reloaded.notifyDevices && !reloaded.notifyJoins && reloaded.notifyLeaves)
    }

    // ---------------------------------------------------------------------------------------------- network

    private val groupKey by lazy { GroupKey.derive("G1", "pass1234") }

    private fun network(): Pair<PeerNetwork, MutableList<List<String>>> {
        val settings = Settings(File(tmp, "net-settings.json"), "T")
        val net = PeerNetwork(scope, settings, null, { emptyList() })
        net.identity = LocalIdentity("ME", "Me", "android", listOf(GroupSecret(GroupMembership("G1", "البيت", "pass1234", 0.0), groupKey)), null)
        val published = mutableListOf<List<String>>()
        net.onPeers = { peers -> published += peers.map { it.id }.sorted() }
        return net to published
    }

    @Test
    fun aGroupDeviceMdnsStillListsButThatStoppedAnsweringDropsOut() {
        val (net, published) = network()
        val mine = Peer("P1", "iPhone", "iphone", listOf(AdvertisedGroup("G1", groupKey.tag, "البيت")), "192.168.0.21", 47331, false)
        val other = Peer("P2", "Other", "windows", listOf(AdvertisedGroup("G9", "bbbb2222", "x")), "192.168.0.30", 47331, false)
        net.browsed = mapOf("P1" to mine, "P2" to other)
        net.publishMerged()
        assertEquals(listOf("P1", "P2"), published.last(), "just showed up: listed")
        val old = System.currentTimeMillis() - PeerNetwork.LIVENESS_MS - 1000
        net.firstSeen["P1"] = old
        net.firstSeen["P2"] = old
        net.publishMerged()
        assertEquals(listOf("P2"), published.last(), "silent for a minute: only the other group (nearby list) stays")
        net.lastContact["P1"] = System.currentTimeMillis()
        net.publishMerged()
        assertEquals(listOf("P1", "P2"), published.last(), "answered again: back")
    }

    @Test
    fun neverRemembersAnFe80AddressWithoutItsInterface() {
        val (net, _) = network()
        net.saveKnownHost("fe80::10eb:98e:c749:8a66", "P1")
        assertEquals(null, Settings(File(tmp, "net-settings.json"), "T").knownHosts["P1"])
        net.saveKnownHost("192.168.0.21", "P1")
        assertEquals("192.168.0.21", Settings(File(tmp, "net-settings.json"), "T").knownHosts["P1"])
        assertTrue(PeerNetwork.isUnscopedLinkLocal("FE80::1") && !PeerNetwork.isUnscopedLinkLocal("fe80::1%wlan0"))
    }

    @Test
    fun rightAfterAByeTheOldMdnsRecordDoesNotBringTheDeviceBack() {
        val (net, published) = network()
        val byes = mutableListOf<Pair<String, Long?>>()
        net.onBye = { id, until -> byes += id to until; byes += "published-so-far:${published.size}" to null }
        val me = net.identity!!
        val service = DiscoveredService(
            "P1", mapOf("v" to "2", "i" to "P1", "n" to "iPhone", "p" to "iphone", "g0" to "G1|${groupKey.tag}|البيت"), "192.168.0.21", 47331,
        )
        net.syncBrowsed(listOf(service), me)
        assertEquals(listOf("P1"), published.last())
        val countBefore = published.size
        net.silence("P1", null, "iPhone", "192.168.0.21", 47331)
        assertEquals(listOf<Pair<String, Long?>>("P1" to null, "published-so-far:$countBefore" to null), byes, "onBye (paused) comes before the device drops out")
        net.syncBrowsed(listOf(service), me)
        assertEquals(emptyList<String>(), published.last(), "still advertised a moment after its bye: stays out")
        net.byeAt["P1"] = System.currentTimeMillis() - 11_000
        net.syncBrowsed(listOf(service), me)
        assertEquals(listOf("P1"), published.last(), "advertised 10 s later: it is back")
    }
}
