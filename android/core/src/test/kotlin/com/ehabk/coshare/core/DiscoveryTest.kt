package com.ehabk.coshare.core

import org.junit.After
import java.io.File
import java.nio.file.Files
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/** What the Android mDNS layer advertises and how the engine reads other devices' TXT records. */
class DiscoveryTest {
    private val tmp: File = Files.createTempDirectory("coshare-discovery").toFile()
    private var engine: SyncEngine? = null

    @After
    fun tearDown() {
        engine?.shutdown()
        tmp.deleteRecursively()
    }

    private class FakeDiscovery : ServiceDiscovery {
        @Volatile var advertised: Map<String, String>? = null
        @Volatile var port = 0
        @Volatile var deliver: ((List<DiscoveredService>) -> Unit)? = null

        override fun start(me: LocalIdentity, port: Int, onServices: (List<DiscoveredService>) -> Unit, onEvent: (String, Boolean) -> Unit) {
            advertised = me.txtRecord()
            this.port = port
            deliver = onServices
        }

        override fun refresh() {}
        override fun stop() {}
    }

    @Test
    fun advertisesTheSameTxtRecordAsTheOtherAppsAndReadsTheirs() = kotlinx.coroutines.runBlocking {
        val discovery = FakeDiscovery()
        val port = freePort()
        val e = SyncEngine(EngineConfig(File(tmp, "me"), "android", "Pixel 9", FakeClipboard(), discovery = discovery, port = port))
        engine = e
        e.start()
        val group = e.createGroup("أجهزتي|البيت", "pass1234")
        e.update { quietEnabled = true; quietSchedule = QuietSchedule(setOf(6, 2), 540, 1020) }
        eventually("advertised with the group and quiet hours") { discovery.advertised?.containsKey("q") == true }
        val txt = discovery.advertised!!
        val tag = GroupKey.derive(group.id, "pass1234").tag
        assertEquals(
            mapOf("n" to "Pixel 9", "p" to "android", "i" to e.settings.deviceID, "v" to "2", "g0" to "${group.id}|$tag|أجهزتي/البيت", "q" to "2,6|540|1020"),
            txt,
        )
        assertEquals(port, discovery.port)

        // A Mac as NWListener advertises it, an older protocol version, and this device itself (also renamed "(2)").
        val me = e.settings.deviceID
        discovery.deliver!!(
            listOf(
                DiscoveredService("6F9619FF-MAC", mapOf("n" to "MacBook", "p" to "mac", "i" to "6F9619FF-MAC", "v" to "2", "g0" to "k3x9|f42b7b9a|Ehab’s devices", "q" to "2,3|540|1020"), "192.168.1.5", 47331),
                DiscoveredService("OLD", mapOf("n" to "Old", "v" to "1"), "192.168.1.6", 47331),
                DiscoveredService(me, txt, "192.168.1.7", port),
                DiscoveredService("$me (2)", txt - "i", "192.168.1.8", port),
            ),
        )
        eventually("the Mac shows up") { e.state.value.peers.isNotEmpty() }
        Thread.sleep(300)
        val peers = e.state.value.peers
        assertEquals(listOf("MacBook"), peers.map { it.name })
        assertEquals("mac", peers[0].platform)
        val nearby = e.state.value.nearby.single()
        assertEquals(AdvertisedGroup("k3x9", "f42b7b9a", "Ehab’s devices"), nearby.group)
        assertEquals(listOf("MacBook"), nearby.memberNames)
        assertTrue(e.state.value.connected.isEmpty(), "not in a shared group yet")
        assertEquals("2,3|540|1020", e.settings.peerSchedules["6F9619FF-MAC"])
    }
}
