package com.ehabk.coshare.core

import java.security.MessageDigest
import java.time.LocalDateTime
import java.time.ZoneId
import java.util.Base64
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Interop vectors produced by the Swift implementation (Tools/TestPeer "vector k3x9testgroup pass1234"), the same ones
 * desktop/test/protocol.test.js and SWIFT_VECTOR_FRAME in desktop/src/main/main.js check.
 */
class ProtocolTest {
    private val swiftKey = "1b399077355410f50a6236b085713e78249c1d32634a5615cbb8449470a2af74"
    private val swiftTag = "f42b7b9a"
    private val swiftFrame =
        "AAAAxgBh8VPQHzbjeScsMqpqc0n364tsqtZR9XRS5HBOlKPbUZ1MxASl9nChaoZohz88xdxgO2aA9F2mOmotcSVvXFnysypSbOiC8u8lAoXZU1f2foi7u+kLs7WnSGDtG6mBuA0OsreOea+fXwc2Q6e8dWEwZS4uWZDt5cdAaFLBf552jAjxbtb8/6jeXI8xCc3JOaXq0ipelbPS/AH6LY5Mh9ZJDQ0x4crpGrVkedWnO3dmuUuhQUutQ0EDEdPnfgBakT3ZW8c1/Q=="

    private val key by lazy { GroupKey.derive("k3x9testgroup", "pass1234") }

    @Test
    fun derivesTheSameKeyAndTagAsSwift() {
        assertEquals(swiftKey, key.key.toHex())
        assertEquals(swiftTag, key.tag)
    }

    @Test
    fun opensAFrameSealedBySwift() {
        val frame = Base64.getDecoder().decode(swiftFrame)
        assertEquals((frame.size - 4).toLong(), frame.readUInt32(0))
        val message = WireMessage.open(frame.copyOfRange(4, frame.size), key)
        val h = message.header
        assertEquals(MessageType.HELLO, h.type)
        assertEquals("VECTOR", h.senderID)
        assertEquals(47331, h.listenPort)
        assertEquals(listOf(AdvertisedGroup("k3x9testgroup", swiftTag, "G")), h.groups)
        assertEquals("مرحبا", message.payload.toString(Charsets.UTF_8))
    }

    @Test
    fun rejectsAFrameWithTheWrongPassword() {
        val wrong = GroupKey.derive("k3x9testgroup", "wrong-password")
        val frame = Base64.getDecoder().decode(swiftFrame)
        assertFailsWith<Exception> { WireMessage.open(frame.copyOfRange(4, frame.size), wrong) }
    }

    @Test
    fun rejectsATamperedFrame() {
        val frame = Base64.getDecoder().decode(swiftFrame)
        frame[40] = (frame[40].toInt() xor 1).toByte()
        assertFailsWith<Exception> { WireMessage.open(frame.copyOfRange(4, frame.size), key) }
    }

    @Test
    fun ownFramesRoundTripWithEveryField() {
        val header = WireHeader(
            type = MessageType.CLIP, senderID = "X", senderName = "جهاز \"Y\"", platform = "android",
            clip = ClipMeta(randomID(), ClipKind.IMAGE, ClipContent.UTI_PNG, "ab".repeat(32), 1760987654.25, "Pixel"),
            listenPort = 47331, groups = listOf(AdvertisedGroup("g1", "00ff00ff", "أجهزتي")),
            quiet = QuietSchedule(setOf(6, 2), 540, 1020), quietUntil = 1760990000.5,
        )
        val payload = ByteArray(100_000) { (it % 251).toByte() }
        val frame = WireMessage(header, payload).frame(key)
        assertEquals((frame.size - 4).toLong(), frame.readUInt32(0))
        val back = WireMessage.open(frame.copyOfRange(4, frame.size), key)
        assertEquals(header, back.header)
        assertTrue(payload.contentEquals(back.payload))
    }

    @Test
    fun headerJsonHasNoEmptyOptionalsAndPlainDates() {
        val json = WireHeader(MessageType.ACK, "A", "B", "android").toJson()
        assertEquals("""{"type":"ack","senderID":"A","senderName":"B","platform":"android"}""", json)
        val clip = WireHeader(MessageType.CLIP, "A", "B", "android",
            ClipMeta("ID", ClipKind.TEXT, null, "h", 1760987654.123456, null)).toJson()
        assertTrue(""""createdAt":1760987654.123456""" in clip, clip)
        assertTrue("uti" !in clip && "origin" !in clip, clip)
    }

    @Test
    fun readsHeadersWrittenBySwiftAndNode() {
        // Swift's JSONEncoder escapes "/" and writes dates as plain numbers; Node may omit optionals or send nulls.
        val h = WireHeader.parse(
            """{"type":"latest","senderID":"S","senderName":"Mac\/Book","platform":"mac","clip":{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF",""" +
                """"kind":"text","hash":"aa","createdAt":1.7609876543E9,"origin":null},"quiet":{"days":[2,4],"start":60,"end":120},"future":1}""",
        )
        assertEquals("Mac/Book", h.senderName)
        assertEquals(1760987654.3, h.clip!!.createdAt, 1e-6)
        assertNull(h.clip.origin)
        assertEquals(QuietSchedule(setOf(2, 4), 60, 120), h.quiet)
        assertFailsWith<WireException> { WireHeader.parse("""{"type":"newThing","senderID":"S","senderName":"N","platform":"x"}""") }
    }

    @Test
    fun contentHashMatchesSwift() {
        val expected = MessageDigest.getInstance("SHA-256").digest("texthello".toByteArray()).toHex()
        assertEquals(expected, contentHash(ClipKind.TEXT, "hello".toByteArray()))
        assertEquals(expected, ClipContent.Text("hello").hash())
    }

    @Test
    fun txtFormsMatchSwift() {
        assertEquals("a1|ff00|x/y", AdvertisedGroup("a1", "ff00", "x|y").txtValue)
        assertEquals(AdvertisedGroup("a1", "ff00", "Ehab’s devices"), AdvertisedGroup.parse("a1|ff00|Ehab’s devices"))
        assertEquals(AdvertisedGroup("a1", "ff00", "a|b"), AdvertisedGroup.parse("a1|ff00|a|b"))
        assertNull(AdvertisedGroup.parse("a1||x"))
        assertEquals("2,4,6|540|1020", QuietSchedule(setOf(6, 2, 4), 540, 1020).txtValue)
        assertEquals(QuietSchedule(setOf(2, 4, 6), 540, 1020), QuietSchedule.parse("2,4,6|540|1020"))
        assertEquals(48, AdvertisedGroup("i", "t", "ب".repeat(60)).txtValue.substringAfterLast('|').length)
    }

    @Test
    fun quietWindowsIncludingOvernightMatchTheSwiftRules() {
        val zone = ZoneId.of("Asia/Amman")
        fun at(day: Int, hour: Int) = LocalDateTime.of(2026, 10, day, hour, 0).atZone(zone).toInstant().toEpochMilli()
        val monday = QuietSchedule(setOf(2), 9 * 60, 17 * 60) // Monday 9–17
        assertNotNull(monday.window(at(19, 10), zone)) // Mon 19 Oct 2026, 10:00
        assertNull(monday.window(at(19, 17), zone))
        assertNull(monday.window(at(20, 10), zone)) // Tuesday
        val night = QuietSchedule(setOf(2), 22 * 60, 6 * 60) // Monday 22:00 → Tuesday 06:00
        val w = assertNotNull(night.window(at(20, 3), zone)) // Tue 03:00 belongs to Monday's window
        assertEquals(at(19, 22), w.startMs)
        assertEquals(at(20, 6), w.endMs)
        assertNull(night.window(at(20, 23), zone))
        assertNull(QuietSchedule(setOf(2), 60, 60).window(at(19, 1), zone))
    }

    @Test
    fun invitesRoundTripAndReadSwiftAndNodeLinks() {
        val group = GroupMembership("k3x9testgroup", "أجهزة إيهاب & co", "p+ss w/rd", 0.0)
        val url = GroupInvite.url(group)
        assertTrue(url.startsWith("coshare://join?g=k3x9testgroup&n="), url)
        val parsed = assertNotNull(GroupInvite.parse(url))
        assertEquals("k3x9testgroup", parsed.id)
        assertEquals("أجهزة إيهاب & co", parsed.name)
        assertEquals(listOf("p+ss w/rd"), parsed.passwords)
        // Swift's URLComponents leaves "+" as is; Node's URLSearchParams writes a space as "+".
        assertEquals(listOf("a+b", "a b"), GroupInvite.parse("coshare://join?g=x&n=N&p=a+b")!!.passwords)
        assertEquals("My devices", GroupInvite.parse("coshare://join?g=x&n=My%20devices&p=secret1")!!.name)
        assertEquals("My devices", GroupInvite.parse("coshare://join?g=x&n=My+devices&p=secret1")!!.name)
        assertEquals("CoShare", GroupInvite.parse("coshare://join?g=x&p=secret1")!!.name)
        assertNull(GroupInvite.parse("https://example.com/?g=x&p=y"))
        assertNull(GroupInvite.parse("coshare://join?g=x"))
    }

    @Test
    fun groupIDsUseTheSharedAlphabet() {
        repeat(50) {
            val id = GroupMembership.newID()
            assertEquals(12, id.length)
            assertTrue(id.all { it in "0123456789abcdefghjkmnpqrstvwxyz" }, id)
        }
    }

    @Test
    fun framesTooLargeAreRefusedBeforeReading() {
        val big = uint32(Wire.MAX_FRAME + 1) + ByteArray(10)
        assertFailsWith<WireException> { PeerNetwork.readFrame(big.inputStream()) }
    }
}
