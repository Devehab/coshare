package com.ehabk.coshare.core

// CoShare wire protocol — byte-compatible with the Swift apps (Shared/WireProtocol.swift, GroupKey.swift)
// and the desktop app (desktop/src/core/protocol.js).
//
//   frame   = [UInt32 BE sealedLength][ChaCha20-Poly1305(nonce12 | ciphertext | tag16)]
//   sealed  = [UInt32 BE headerLength][header JSON][payload bytes]
//   key     = PBKDF2-HMAC-SHA256(password, "CoShare.v2.group." + groupID, 120 000, 32 bytes)
//   tag     = hex(SHA256(key | "coshare-tag")[0..4])   — public password check value

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.JsonUnquotedLiteral
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import org.bouncycastle.crypto.digests.SHA256Digest
import org.bouncycastle.crypto.generators.PKCS5S2ParametersGenerator
import org.bouncycastle.crypto.modes.ChaCha20Poly1305
import org.bouncycastle.crypto.params.AEADParameters
import org.bouncycastle.crypto.params.KeyParameter
import java.net.URLDecoder
import java.security.MessageDigest
import java.security.SecureRandom
import java.time.Instant
import java.time.ZoneId
import java.util.Locale
import java.util.UUID

object Wire {
    const val MAX_FRAME = 64 * 1024 * 1024
    const val PREFERRED_PORT = 47331
    const val SERVICE_TYPE = "_coshare._tcp"
    const val PBKDF2_ROUNDS = 120_000
    const val MIN_PASSWORD = 6
    const val MAX_IMAGE_BYTES = 40 * 1024 * 1024
}

class WireException(message: String) : Exception(message)

/** A group's symmetric key, derived from its password and salted with the group ID. */
class GroupKey private constructor(val key: ByteArray, val tag: String) {

    fun seal(plaintext: ByteArray): ByteArray {
        val nonce = ByteArray(12).also { random.nextBytes(it) }
        val cipher = ChaCha20Poly1305()
        cipher.init(true, AEADParameters(KeyParameter(key), 128, nonce))
        val out = ByteArray(12 + cipher.getOutputSize(plaintext.size))
        nonce.copyInto(out)
        var written = cipher.processBytes(plaintext, 0, plaintext.size, out, 12)
        written += cipher.doFinal(out, 12 + written)
        return if (12 + written == out.size) out else out.copyOf(12 + written)
    }

    /** Throws if the frame was sealed with another key or changed on the way. */
    fun open(sealed: ByteArray): ByteArray {
        if (sealed.size < 28) throw WireException("frame too short")
        val cipher = ChaCha20Poly1305()
        cipher.init(false, AEADParameters(KeyParameter(key), 128, sealed.copyOfRange(0, 12)))
        val out = ByteArray(cipher.getOutputSize(sealed.size - 12))
        var written = cipher.processBytes(sealed, 12, sealed.size - 12, out, 0)
        written += cipher.doFinal(out, written)
        return if (written == out.size) out else out.copyOf(written)
    }

    companion object {
        private val random = SecureRandom()

        /** Deliberately slow (PBKDF2, 120 000 rounds): call it off the main thread and cache the result. */
        fun derive(groupID: String, password: String): GroupKey {
            val generator = PKCS5S2ParametersGenerator(SHA256Digest())
            generator.init(
                password.toByteArray(Charsets.UTF_8),
                ("CoShare.v2.group.$groupID").toByteArray(Charsets.UTF_8),
                Wire.PBKDF2_ROUNDS,
            )
            val key = (generator.generateDerivedParameters(256) as KeyParameter).key
            val digest = MessageDigest.getInstance("SHA-256")
            digest.update(key)
            digest.update("coshare-tag".toByteArray(Charsets.UTF_8))
            return GroupKey(key, digest.digest().copyOf(4).toHex())
        }
    }
}

enum class ClipKind(val wire: String) {
    TEXT("text"), IMAGE("image");

    companion object {
        fun of(wire: String?) = entries.firstOrNull { it.wire == wire }
    }
}

/** What moves between devices. Images keep their uniform type identifier ("public.png", "public.jpeg"). */
sealed class ClipContent {
    data class Text(val text: String) : ClipContent() {
        override val uti: String? get() = null
    }

    class Image(val data: ByteArray, override val uti: String = UTI_PNG) : ClipContent()

    abstract val uti: String?

    val kind: ClipKind get() = if (this is Text) ClipKind.TEXT else ClipKind.IMAGE
    val payload: ByteArray
        get() = when (this) {
            is Text -> text.toByteArray(Charsets.UTF_8)
            is Image -> data
        }
    val label: String get() = if (this is Text) "نص" else "صورة"

    companion object {
        const val UTI_PNG = "public.png"
        const val UTI_JPEG = "public.jpeg"

        /** Same rules as ClipContent.init in Swift: empty text or images are not clips. */
        fun from(kind: ClipKind, uti: String?, payload: ByteArray): ClipContent? = when (kind) {
            ClipKind.TEXT -> payload.toString(Charsets.UTF_8).takeIf { it.isNotEmpty() }?.let { Text(it) }
            ClipKind.IMAGE -> if (payload.isEmpty()) null else Image(payload, uti ?: UTI_PNG)
        }
    }
}

/** Same content hash as ClipContent.hash in Swift: SHA256(kind | payload), hex. */
fun contentHash(kind: ClipKind, payload: ByteArray): String {
    val digest = MessageDigest.getInstance("SHA-256")
    digest.update(kind.wire.toByteArray(Charsets.UTF_8))
    digest.update(payload)
    return digest.digest().toHex()
}

fun ClipContent.hash(): String = contentHash(kind, payload)

/** A group as another device advertises it: no secrets, the tag only lets a joiner check a password. */
data class AdvertisedGroup(val id: String, val tag: String, val name: String) {
    /** Bonjour TXT value, e.g. "k3x9…|a1b2c3d4|Ehab's devices". */
    val txtValue: String get() = "$id|$tag|${name.replace('|', '/').takeCodePoints(48)}"

    companion object {
        fun parse(txt: String?): AdvertisedGroup? {
            val parts = txt?.split("|", limit = 3) ?: return null
            if (parts.size < 3 || parts[0].isEmpty() || parts[1].isEmpty()) return null
            return AdvertisedGroup(parts[0], parts[1], parts[2])
        }
    }
}

/** Hours when a device stays completely off the network. Days: 1 = Sunday … 7 = Saturday (Swift's Calendar). */
data class QuietSchedule(val days: Set<Int>, val start: Int, val end: Int) {
    data class Window(val startMs: Long, val endMs: Long)

    /** "2,3,4,5,6|540|1020", so other devices know when not to call. */
    val txtValue: String get() = "${days.sorted().joinToString(",")}|$start|$end"

    /** The quiet window containing `nowMs`; a window whose end is not after its start runs past midnight. */
    fun window(nowMs: Long, zone: ZoneId = ZoneId.systemDefault()): Window? {
        if (start == end) return null
        val now = Instant.ofEpochMilli(nowMs).atZone(zone)
        val today = now.toLocalDate()
        for (offset in longArrayOf(0, -1)) {
            val day = today.plusDays(offset)
            val weekday = day.dayOfWeek.value % 7 + 1 // Monday=1 … Sunday=7 → Sunday=1 … Saturday=7
            if (weekday !in days) continue
            val midnight = day.atStartOfDay(zone)
            val begins = midnight.plusMinutes(start.toLong())
            val ends = midnight.plusMinutes((if (end <= start) end + 24 * 60 else end).toLong())
            if (!now.isBefore(begins) && now.isBefore(ends)) {
                return Window(begins.toInstant().toEpochMilli(), ends.toInstant().toEpochMilli())
            }
        }
        return null
    }

    fun toJson(): JsonObject = buildJsonObject {
        put("days", JsonArray(days.sorted().map { JsonPrimitive(it) }))
        put("start", start)
        put("end", end)
    }

    companion object {
        val DEFAULT = QuietSchedule(setOf(2, 3, 4, 5, 6), 9 * 60, 17 * 60)
        val DAY_NAMES = mapOf(1 to "أحد", 2 to "إثنين", 3 to "ثلاثاء", 4 to "أربعاء", 5 to "خميس", 6 to "جمعة", 7 to "سبت")

        fun parse(txt: String?): QuietSchedule? {
            val parts = txt?.split("|") ?: return null
            if (parts.size != 3) return null
            val start = parts[1].toIntOrNull() ?: return null
            val end = parts[2].toIntOrNull() ?: return null
            return QuietSchedule(parts[0].split(",").mapNotNull { it.toIntOrNull() }.toSet(), start, end)
        }

        fun fromJson(element: JsonElement?): QuietSchedule? {
            val o = element as? JsonObject ?: return null
            val start = o.int("start") ?: return null
            val end = o.int("end") ?: return null
            val days = (o["days"] as? JsonArray)?.mapNotNull { (it as? JsonPrimitive)?.intOrNull }?.toSet() ?: return null
            return QuietSchedule(days, start, end)
        }
    }
}

enum class MessageType(val wire: String) {
    CLIP("clip"), ACK("ack"), PULL_LATEST("pullLatest"), LATEST("latest"), NOTHING("nothing"), HELLO("hello"), BYE("bye");

    companion object {
        fun of(wire: String?) = entries.firstOrNull { it.wire == wire }
    }
}

data class ClipMeta(
    val id: String,
    val kind: ClipKind,
    val uti: String?,
    val hash: String,
    /** Seconds since 1970, like Swift's `.secondsSince1970` date strategy. */
    val createdAt: Double,
    /** Device where the clip was originally copied (a pull reply may come from another device). */
    val origin: String?,
)

data class WireHeader(
    val type: MessageType,
    val senderID: String,
    val senderName: String,
    val platform: String,
    val clip: ClipMeta? = null,
    /** hello only: the sender's listening port and its groups. */
    val listenPort: Int? = null,
    val groups: List<AdvertisedGroup>? = null,
    /** hello: the sender's quiet hours; bye: when it will be back (seconds since 1970). */
    val quiet: QuietSchedule? = null,
    val quietUntil: Double? = null,
) {
    /** Optional fields are left out when empty, exactly like Swift's synthesized Codable. */
    fun toJson(): String = buildJsonObject {
        put("type", type.wire)
        put("senderID", senderID)
        put("senderName", senderName)
        put("platform", platform)
        clip?.let { c ->
            put("clip", buildJsonObject {
                put("id", c.id)
                put("kind", c.kind.wire)
                c.uti?.let { put("uti", it) }
                put("hash", c.hash)
                put("createdAt", seconds(c.createdAt))
                c.origin?.let { put("origin", it) }
            })
        }
        listenPort?.let { put("listenPort", it) }
        groups?.let { list ->
            put("groups", JsonArray(list.map { g -> buildJsonObject { put("id", g.id); put("tag", g.tag); put("name", g.name) } }))
        }
        quiet?.let { put("quiet", it.toJson()) }
        quietUntil?.let { put("quietUntil", seconds(it)) }
    }.toString()

    companion object {
        fun parse(json: String): WireHeader {
            val o = Json.parseToJsonElement(json).jsonObject
            val type = MessageType.of(o.str("type")) ?: throw WireException("unknown message type")
            val clip = (o["clip"] as? JsonObject)?.let { c ->
                ClipMeta(
                    id = c.str("id") ?: throw WireException("clip without id"),
                    kind = ClipKind.of(c.str("kind")) ?: throw WireException("unknown clip kind"),
                    uti = c.str("uti"),
                    hash = c.str("hash") ?: "",
                    createdAt = c.double("createdAt") ?: 0.0,
                    origin = c.str("origin"),
                )
            }
            val groups = (o["groups"] as? JsonArray)?.mapNotNull { g ->
                val go = g as? JsonObject ?: return@mapNotNull null
                val id = go.str("id") ?: return@mapNotNull null
                val tag = go.str("tag") ?: return@mapNotNull null
                AdvertisedGroup(id, tag, go.str("name") ?: "")
            }
            return WireHeader(
                type = type,
                senderID = o.str("senderID") ?: "",
                senderName = o.str("senderName") ?: "",
                platform = o.str("platform") ?: "other",
                clip = clip,
                listenPort = o.int("listenPort"),
                groups = groups,
                quiet = QuietSchedule.fromJson(o["quiet"]),
                quietUntil = o.double("quietUntil"),
            )
        }

        /** Plain decimal seconds ("1760987654.123456"): what every JSON parser reads the same way. */
        @OptIn(ExperimentalSerializationApi::class)
        private fun seconds(value: Double): JsonElement =
            if (value.isFinite()) JsonUnquotedLiteral(String.format(Locale.ROOT, "%.6f", value)) else JsonPrimitive(0)
    }
}

/** One request or reply. */
class WireMessage(val header: WireHeader, val payload: ByteArray = EMPTY) {
    /** Encrypted, length-prefixed frame ready to write to a socket. */
    fun frame(key: GroupKey): ByteArray {
        val headerData = header.toJson().toByteArray(Charsets.UTF_8)
        val plain = ByteArray(4 + headerData.size + payload.size)
        plain.putUInt32(0, headerData.size)
        headerData.copyInto(plain, 4)
        payload.copyInto(plain, 4 + headerData.size)
        val sealed = key.seal(plain)
        if (sealed.size > Wire.MAX_FRAME) throw WireException("الملف أكبر من الحد المسموح")
        val frame = ByteArray(4 + sealed.size)
        frame.putUInt32(0, sealed.size)
        sealed.copyInto(frame, 4)
        return frame
    }

    companion object {
        val EMPTY = ByteArray(0)

        /** Opens a frame body (without its length prefix). Throws if it isn't for this key. */
        fun open(sealed: ByteArray, key: GroupKey): WireMessage {
            val plain = key.open(sealed)
            if (plain.size < 4) throw WireException("bad message")
            val headerLength = plain.readUInt32(0)
            if (headerLength <= 0 || plain.size < 4 + headerLength) throw WireException("bad message")
            val header = WireHeader.parse(String(plain, 4, headerLength.toInt(), Charsets.UTF_8))
            return WireMessage(header, plain.copyOfRange(4 + headerLength.toInt(), plain.size))
        }
    }
}

/** A private group this device is in. The password stays on the device (and in invites the person shows). */
data class GroupMembership(val id: String, val name: String, val password: String, val joinedAt: Double) {
    companion object {
        private const val ALPHABET = "0123456789abcdefghjkmnpqrstvwxyz"
        private val random = SecureRandom()

        /** 12-character group IDs from the same alphabet as the Swift and desktop apps. */
        fun newID(): String {
            val bytes = ByteArray(12).also { random.nextBytes(it) }
            return bytes.joinToString("") { ALPHABET[(it.toInt() and 0xff) % ALPHABET.length].toString() }
        }
    }
}

/** `coshare://join?g=<id>&n=<name>&p=<password>` — the QR invite. */
object GroupInvite {
    /** Percent-encodes everything but unreserved characters, so Swift, Node and Android all read it the same. */
    fun url(group: GroupMembership): String =
        "coshare://join?g=${encode(group.id)}&n=${encode(group.name)}&p=${encode(group.password)}"

    /**
     * The invite's group, with every reading of its password: Swift writes a "+" as is, Node's URLSearchParams
     * writes a space as "+". When both are possible the caller checks them against the advertised tag.
     */
    data class Parsed(val id: String, val name: String, val passwords: List<String>)

    fun parse(text: String): Parsed? {
        val trimmed = text.trim()
        val rest = when {
            trimmed.startsWith("coshare://join?", ignoreCase = true) -> trimmed.substring("coshare://join?".length)
            trimmed.startsWith("coshare://join/?", ignoreCase = true) -> trimmed.substring("coshare://join/?".length)
            else -> return null
        }
        val raw = rest.substringBefore('#').split('&').mapNotNull { pair ->
            val index = pair.indexOf('=')
            if (index <= 0) null else pair.substring(0, index) to pair.substring(index + 1)
        }.toMap()
        val id = raw["g"]?.let { decode(it, plusIsSpace = false) }?.takeIf { it.isNotEmpty() } ?: return null
        val rawPassword = raw["p"] ?: return null
        val literal = decode(rawPassword, plusIsSpace = false)
        val spaced = decode(rawPassword, plusIsSpace = true)
        if (literal.isEmpty()) return null
        val name = raw["n"]?.let { decode(it, plusIsSpace = !it.contains("%20")) }?.takeIf { it.isNotBlank() } ?: "CoShare"
        return Parsed(id, name, listOf(literal, spaced).distinct())
    }

    private fun encode(value: String): String {
        val out = StringBuilder()
        for (b in value.toByteArray(Charsets.UTF_8)) {
            val c = b.toInt() and 0xff
            if (c in 'a'.code..'z'.code || c in 'A'.code..'Z'.code || c in '0'.code..'9'.code || c == '-'.code ||
                c == '.'.code || c == '_'.code || c == '~'.code
            ) out.append(c.toChar()) else out.append('%').append(String.format(Locale.ROOT, "%02X", c))
        }
        return out.toString()
    }

    private fun decode(value: String, plusIsSpace: Boolean): String = try {
        URLDecoder.decode(if (plusIsSpace) value else value.replace("+", "%2B"), "UTF-8")
    } catch (_: IllegalArgumentException) {
        value
    }
}

// ---------------------------------------------------------------------------------------------- helpers

fun randomID(): String = UUID.randomUUID().toString().uppercase(Locale.ROOT)

fun ByteArray.toHex(): String {
    val chars = CharArray(size * 2)
    for (i in indices) {
        val v = this[i].toInt() and 0xff
        chars[i * 2] = HEX[v ushr 4]
        chars[i * 2 + 1] = HEX[v and 0x0f]
    }
    return String(chars)
}

private val HEX = "0123456789abcdef".toCharArray()

fun ByteArray.putUInt32(offset: Int, value: Int) {
    this[offset] = (value ushr 24).toByte()
    this[offset + 1] = (value ushr 16).toByte()
    this[offset + 2] = (value ushr 8).toByte()
    this[offset + 3] = value.toByte()
}

fun ByteArray.readUInt32(offset: Int): Long =
    ((this[offset].toLong() and 0xff) shl 24) or ((this[offset + 1].toLong() and 0xff) shl 16) or
        ((this[offset + 2].toLong() and 0xff) shl 8) or (this[offset + 3].toLong() and 0xff)

fun uint32(value: Int): ByteArray = ByteArray(4).also { it.putUInt32(0, value) }

/** At most `count` Unicode code points, never splitting a surrogate pair. */
fun String.takeCodePoints(count: Int): String {
    if (codePointCount(0, length) <= count) return this
    return substring(0, offsetByCodePoints(0, count))
}

internal fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull && it.isString }?.content
internal fun JsonObject.int(key: String): Int? = (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.intOrNull
internal fun JsonObject.double(key: String): Double? = (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.doubleOrNull
internal fun JsonObject.bool(key: String): Boolean? = (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.booleanOrNull
