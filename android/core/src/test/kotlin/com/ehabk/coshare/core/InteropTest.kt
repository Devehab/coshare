package com.ehabk.coshare.core

import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assume.assumeTrue
import java.awt.image.BufferedImage
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.ServerSocket
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import javax.imageio.ImageIO
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import kotlin.test.fail

/** In-memory clipboard: `copy` simulates the person copying, `write` is what the engine pastes. */
class FakeClipboard : ClipboardBridge {
    private var mark = 0L
    private var content: ClipContent? = null
    val written = CopyOnWriteArrayList<ClipContent>()

    @Synchronized override fun currentMark() = mark
    @Synchronized override fun changeMark() = mark
    @Synchronized override fun read(includeImages: Boolean, maxImageBytes: Int) = content?.takeIf { includeImages || it is ClipContent.Text }

    @Synchronized override fun write(content: ClipContent) {
        this.content = content
        mark++
        written += content
    }

    @Synchronized fun copy(content: ClipContent) {
        this.content = content
        mark++
    }
}

fun eventually(what: String, timeoutMs: Long = 30_000, condition: () -> Boolean) {
    val deadline = System.currentTimeMillis() + timeoutMs
    while (System.currentTimeMillis() < deadline) {
        if (condition()) return
        Thread.sleep(100)
    }
    fail("timed out waiting for: $what")
}

fun freePort(): Int = ServerSocket(0).use { it.localPort }

fun testPng(seed: Int): ByteArray {
    val image = BufferedImage(64, 48, BufferedImage.TYPE_INT_RGB)
    for (x in 0 until 64) for (y in 0 until 48) image.setRGB(x, y, (x * 4 + seed) shl 16 or (y * 5) shl 8 or seed)
    return ByteArrayOutputStream().also { ImageIO.write(image, "png", it) }.toByteArray()
}

/**
 * Real sockets on localhost, no mDNS: the devices find each other only by greeting known addresses —
 * exactly the hotspot path (a laptop on a phone's hotspot greets its gateway).
 */
class InteropTest {
    private val tmp: File = Files.createTempDirectory("coshare-interop").toFile()
    private val engines = mutableListOf<SyncEngine>()

    @After
    fun tearDown() {
        processes.forEach { it.destroy() }
        engines.forEach { it.shutdown() }
        tmp.deleteRecursively()
    }

    private fun engine(name: String, port: Int, greet: Int, platform: String = "android"): Pair<SyncEngine, FakeClipboard> {
        val clipboard = FakeClipboard()
        val dir = File(tmp, name).apply { mkdirs() }
        val engine = SyncEngine(
            EngineConfig(
                dataDir = dir, platform = platform, defaultName = name, clipboard = clipboard, port = port,
                extraHosts = listOf("127.0.0.1:$greet"), pollIntervalMs = 200,
                echoLog = if (System.getenv("COSHARE_TEST_VERBOSE") != null) { line -> println("[$name] $line") } else null,
            ),
        )
        engines += engine
        engine.start()
        return engine to clipboard
    }

    private fun SyncEngine.connectedNames() = state.value.connected.map { it.name }

    @Test
    fun twoAndroidDevicesSyncTextAndImagesBothWays() = runBlocking {
        val portA = freePort()
        val portB = freePort()
        val (a, clipA) = engine("Pixel", portA, portB)
        val (b, clipB) = engine("Galaxy Tab", portB, portA)
        val group = a.createGroup("البيت", "pass1234")
        b.joinInvite(a.inviteURL(group))
        eventually("A and B see each other") { a.connectedNames() == listOf("Galaxy Tab") && b.connectedNames() == listOf("Pixel") }

        clipA.copy(ClipContent.Text("مرحبا من البكسل"))
        eventually("B pastes A's text") { (clipB.written.lastOrNull() as? ClipContent.Text)?.text == "مرحبا من البكسل" }
        val png = testPng(7)
        clipB.copy(ClipContent.Image(png))
        eventually("A pastes B's image") { (clipA.written.lastOrNull() as? ClipContent.Image)?.data?.contentEquals(png) == true }
        // No echo: A pasting B's image must not send it back to B.
        Thread.sleep(1500)
        assertEquals(1, clipB.written.size)
        assertEquals(Direction.RECEIVED, a.state.value.history.first().direction)
        assertEquals(1, b.state.value.history.first { it.direction == Direction.SENT }.deliveredTo)
    }

    /** A headless CoShare device in another process (desktop/tools/peer.js or Tools/TestPeer), driven by a commands file. */
    private inner class PeerProcess(name: String, command: List<String>, env: Map<String, String>) {
        val output = CopyOnWriteArrayList<String>()
        private val commands = File(tmp, "$name-commands.txt").apply { writeText("") }
        private val process: Process = ProcessBuilder(command).apply {
            environment().putAll(env + ("COSHARE_CMDS" to commands.absolutePath))
            redirectErrorStream(true)
        }.start()

        init {
            processes += process
            Thread {
                process.inputStream.bufferedReader().forEachLine { line ->
                    output += line
                    if (System.getenv("COSHARE_TEST_VERBOSE") != null) println("[$name] $line")
                }
            }.apply { isDaemon = true }.start()
            awaitLine("ready", 60_000) { it.startsWith("READY") }
        }

        fun send(command: String) = commands.appendText(command + "\n")
        fun awaitLine(what: String, timeoutMs: Long = 30_000, match: (String) -> Boolean) =
            eventually("peer: $what", timeoutMs) { output.any(match) }
    }

    private val processes = mutableListOf<Process>()

    @Test
    fun syncsWithTheDesktopNodePeer() = runBlocking {
        val root = File(System.getenv("COSHARE_REPO_ROOT") ?: "../..")
        val peerScript = File(root, "desktop/tools/peer.js")
        val ready = peerScript.isFile && File(root, "desktop/node_modules/bonjour-service").isDirectory &&
            runCatching { ProcessBuilder("node", "--version").start().waitFor() == 0 }.getOrDefault(false)
        if (System.getenv("COSHARE_REQUIRE_INTEROP") != null) {
            assertTrue(ready, "node and desktop/node_modules are needed for the interop test (npm ci in desktop/)")
        }
        assumeTrue("node or desktop/node_modules missing: skipping the Node interop test", ready)

        val nodePort = freePort()
        val myPort = freePort()
        val nodeDir = File(tmp, "node").apply { mkdirs() }
        val peer = PeerProcess(
            "node", listOf("node", peerScript.absolutePath),
            mapOf(
                "COSHARE_DATA" to nodeDir.absolutePath, "COSHARE_NAME" to "NodePeer", "COSHARE_NO_BONJOUR" to "1",
                "COSHARE_PORT" to "$nodePort", "COSHARE_HOSTS" to "127.0.0.1:$myPort",
            ),
        )
        val (me, clipboard) = engine("AndroidPeer", myPort, nodePort)

        // Join the desktop's group with its invite (no mDNS here, so the QR path).
        peer.send("create Home pass1234")
        peer.awaitLine("group created") { it == "CREATE ok" }
        val settingsFile = File(nodeDir, "settings.json")
        var groupID = ""
        eventually("node saves its group") {
            groupID = Regex(""""groups":\[\{"id":"([^"]+)"""").find(runCatching { settingsFile.readText() }.getOrDefault(""))?.groupValues?.get(1) ?: ""
            groupID.isNotEmpty()
        }
        me.joinInvite("coshare://join?g=$groupID&n=Home&p=pass1234")
        exercise(peer, "NodePeer", me, clipboard)
    }

    /**
     * Tools/TestPeer is the Swift engine of the iPhone and Mac apps. Build it with scripts/test-peer.sh (macOS only)
     * and point COSHARE_SWIFT_PEER at build/tools/TestPeer to run this.
     */
    @Test
    fun syncsWithTheSwiftTestPeer() = runBlocking {
        val binary = System.getenv("COSHARE_SWIFT_PEER")?.let(::File)
        assumeTrue("COSHARE_SWIFT_PEER not set: skipping the Swift interop test", binary?.canExecute() == true)
        val swiftPort = freePort()
        val myPort = freePort()
        val (me, clipboard) = engine("AndroidPeer", myPort, swiftPort)
        // Put the Swift peer in our group before it starts (its settings live in the UserDefaults suite of its profile).
        val group = me.createGroup("Home", "pass1234")
        val profile = "androidinterop${System.currentTimeMillis()}"
        val groupsJson = """[{"id":"${group.id}","name":"Home","password":"pass1234","joinedAt":0}]"""
        val hex = groupsJson.toByteArray().joinToString("") { "%02x".format(it) }
        assertEquals(0, ProcessBuilder("defaults", "write", "CoShare.$profile", "groups", "-data", hex).start().waitFor())
        try {
            val peer = PeerProcess(
                "swift", listOf(binary!!.absolutePath),
                mapOf(
                    "COSHARE_PROFILE" to profile, "COSHARE_NAME" to "SwiftPeer", "COSHARE_NO_BONJOUR" to "1",
                    "COSHARE_PORT" to "$swiftPort", "COSHARE_HOSTS" to "127.0.0.1:$myPort", "COSHARE_VERBOSE" to "1",
                ),
            )
            exercise(peer, "SwiftPeer", me, clipboard)
        } finally {
            processes.forEach { it.destroy(); it.waitFor() }
            ProcessBuilder("defaults", "delete", "CoShare.$profile").start().waitFor()
            File(System.getProperty("user.home"), "Library/Application Support/CoShare-$profile").deleteRecursively()
        }
    }

    /** The same checks against any peer: text and images both ways, joining by password, quiet hours both ways. */
    private suspend fun exercise(peer: PeerProcess, peerName: String, me: SyncEngine, clipboard: FakeClipboard) {
        eventually("connected to $peerName") { me.connectedNames() == listOf(peerName) }

        // Text both ways (Arabic included).
        peer.send("copy hello from the other side")
        eventually("Android pastes the peer's text") { (clipboard.written.lastOrNull() as? ClipContent.Text)?.text == "hello from the other side" }
        clipboard.copy(ClipContent.Text("مرحبا من أندرويد"))
        peer.awaitLine("peer pastes Android's text") { it == "PASTEBOARD <- text \"مرحبا من أندرويد\"" }

        // Images both ways, byte for byte.
        val peerPng = File(tmp, "from-$peerName.png").apply { writeBytes(testPng(3)) }
        peer.send("copyimg ${peerPng.absolutePath}")
        eventually("Android pastes the peer's image") {
            (clipboard.written.lastOrNull() as? ClipContent.Image)?.let { it.data.contentEquals(peerPng.readBytes()) && it.uti == "public.png" } == true
        }
        val androidPng = testPng(9)
        clipboard.copy(ClipContent.Image(androidPng))
        peer.awaitLine("peer pastes Android's image") { it.startsWith("PASTEBOARD <- image public.png ${androidPng.size} bytes") }

        // Joining a group the peer created, by its password (its hello lists its groups, like mDNS would).
        peer.output.clear()
        peer.send("create Work secret99")
        peer.awaitLine("second group created") { it == "CREATE ok" }
        eventually("Work shows up nearby") { me.state.value.nearby.any { it.group.name == "Work" } }
        val work = me.state.value.nearby.first { it.group.name == "Work" }
        assertEquals(listOf(peerName), work.memberNames)
        val refused = assertFailsWith<GroupException> { me.join(work.key, "wrongpass") }
        assertEquals("كلمة السر غير صحيحة", refused.message)
        me.join(work.key, "secret99")
        eventually("Work shows the peer as a member") {
            me.state.value.groups.firstOrNull { it.name == "Work" }?.members?.map { it.name } == listOf(peerName)
        }
        clipboard.copy(ClipContent.Text("after joining Work"))
        peer.awaitLine("sync still works after joining") { it == "PASTEBOARD <- text \"after joining Work\"" }
        peer.send("history")
        peer.awaitLine("peer history shows the Android text") { it.startsWith("HISTORY received text from=AndroidPeer after joining Work") }

        // The peer's quiet hours: it says bye and drops out; "resume" brings it back.
        peer.send("quietnow 5")
        eventually("peer silenced after its bye") { me.connectedNames().isEmpty() }
        peer.send("resume")
        eventually("peer back after resume", 40_000) { me.connectedNames() == listOf(peerName) }

        // This side's quiet hours: a bye, then nothing until "resume today".
        val now = java.time.LocalTime.now()
        val start = now.hour * 60 + now.minute
        me.update { quietEnabled = true; quietSchedule = QuietSchedule((1..7).toSet(), start, (start + 5) % 1440) }
        eventually("Android quiet") { me.state.value.presence is Presence.Quiet }
        Thread.sleep(1500)
        peer.output.clear()
        peer.send("peers")
        peer.awaitLine("peer no longer lists Android") { it.startsWith("PEERS") && "AndroidPeer" !in it }
        me.resumeToday()
        eventually("Android back online and connected", 40_000) { me.state.value.presence == Presence.Online && me.connectedNames() == listOf(peerName) }
        peer.send("copy back again")
        eventually("sync works after resuming") { (clipboard.written.lastOrNull() as? ClipContent.Text)?.text == "back again" }
        peer.send("quit")
    }
}
