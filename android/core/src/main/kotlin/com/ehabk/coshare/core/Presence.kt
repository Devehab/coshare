package com.ehabk.coshare.core

// "Device in / device out" — the Kotlin twin of Shared/PresenceWatch.swift and desktop/src/core/presence.js
// (same rules, same words):
//  - a device that drops for a few seconds and comes back makes no noise at all,
//  - nothing is reported while this device itself is (re)connecting (launch, network change, service restart),
//  - a device that said bye (quiet hours, paused) is reported at once, with why,
//  - the first time a device is ever seen in a group it reads as "joined", afterwards as "back".
// It only decides what happened; whether to show it is up to the settings (see SyncEngine.notifyPresence).

data class GroupRef(val id: String, val name: String)

data class PresenceMember(
    val id: String,
    val name: String,
    /** The groups it shares with this device: (id, name as this device knows it). */
    val groups: List<GroupRef>,
)

sealed class LeaveReason {
    /** It said bye for its quiet hours. */
    data class Quiet(val untilMs: Long) : LeaveReason()

    /** It said bye without an end time (paused). */
    data object Paused : LeaveReason()

    /** It stopped answering: left the network, went to sleep, or CoShare was closed. */
    data object Lost : LeaveReason()
}

enum class PresenceKind { JOINED, BACK, LEFT }

data class PresenceEvent(val kind: PresenceKind, val member: PresenceMember, val reason: LeaveReason? = null)

class PresenceWatch(
    /** groupID → every device ID ever seen in it, as saved. */
    known: Map<String, Set<String>>,
    /** Called with the whole map whenever someone is seen in a group for the first time. */
    private val saveKnown: (Map<String, List<String>>) -> Unit,
    private val settleTimeMs: Long = SETTLE_TIME_MS,
) {
    var onEvent: (PresenceEvent) -> Unit = {}

    private val known = HashMap<String, MutableSet<String>>().apply { known.forEach { (g, ids) -> put(g, ids.toMutableSet()) } }
    private val online = LinkedHashMap<String, PresenceMember>()
    private val pendingLeaves = LinkedHashMap<String, Pair<PresenceMember, Long>>()
    private val byes = HashMap<String, LeaveReason>()
    private var quietUntil = 0L

    /** This device is (re)connecting: whatever comes and goes in the next moments is its own doing. */
    fun settle(nowMs: Long = System.currentTimeMillis()) {
        quietUntil = nowMs + settleTimeMs
        pendingLeaves.clear()
    }

    /** This device went off the network on purpose (quiet hours, paused): forget who was there. */
    fun reset() {
        online.clear()
        pendingLeaves.clear()
        byes.clear()
    }

    /** `members`: the devices sharing a group with us now. */
    fun update(members: List<PresenceMember>, nowMs: Long = System.currentTimeMillis()) {
        val settling = nowMs < quietUntil
        var knownChanged = false
        val present = members.map { it.id }.toSet()

        for (member in members) {
            val firstTimeIn = mutableListOf<GroupRef>()
            for (group in member.groups) {
                if (known.getOrPut(group.id) { mutableSetOf() }.add(member.id)) {
                    firstTimeIn += group
                    knownChanged = true
                }
            }
            val wasOnline = member.id in online
            online[member.id] = member
            var backWithinGrace = false
            if (!wasOnline) {
                byes.remove(member.id)
                backWithinGrace = pendingLeaves.remove(member.id) != null
            }
            if (settling) continue
            // Joining one of my groups is news even for a device that never left.
            if (firstTimeIn.isNotEmpty()) emit(PresenceKind.JOINED, member.copy(groups = firstTimeIn))
            else if (!wasOnline && !backWithinGrace) emit(PresenceKind.BACK, member)
        }

        for ((id, member) in online.entries.toList()) {
            if (id in present) continue
            online.remove(id)
            val reason = byes.remove(id)
            if (reason != null) {
                if (!settling) emit(PresenceKind.LEFT, member, reason)
            } else if (!settling) {
                pendingLeaves[id] = member to nowMs
            }
        }

        if (knownChanged) saveKnown(known.mapValues { it.value.sorted() })
    }

    /** A device told us it is leaving: quiet until `untilMs`, or paused when null. */
    fun bye(deviceID: String, untilMs: Long?) {
        val reason = if (untilMs != null) LeaveReason.Quiet(untilMs) else LeaveReason.Paused
        val pending = pendingLeaves.remove(deviceID)
        if (pending != null) emit(PresenceKind.LEFT, pending.first, reason) else byes[deviceID] = reason
    }

    /** Reports devices that have now been gone longer than the grace time. Call every few seconds. */
    fun tick(nowMs: Long = System.currentTimeMillis()) {
        for ((id, pending) in pendingLeaves.entries.toList()) {
            if (nowMs - pending.second < LEAVE_GRACE_MS) continue
            pendingLeaves.remove(id)
            emit(PresenceKind.LEFT, pending.first, LeaveReason.Lost)
        }
    }

    private fun emit(kind: PresenceKind, member: PresenceMember, reason: LeaveReason? = null) =
        onEvent(PresenceEvent(kind, member, reason))

    companion object {
        /** How long a device may be gone before it counts as out. */
        const val LEAVE_GRACE_MS = 30_000L

        /** How long after this device (re)connects nothing is reported. */
        const val SETTLE_TIME_MS = 20_000L

        /** Title and body in the apps' own words (Shared/PresenceNotifier.swift `text(for:)`). */
        fun text(event: PresenceEvent, use24Hour: Boolean): Pair<String, String> {
            val name = event.member.name
            val groups = event.member.groups.joinToString(" و") { "«${it.name}»" }
            val inGroups = if (event.member.groups.size > 1) "بمجموعات $groups" else "بمجموعة $groups"
            return when (event.kind) {
                PresenceKind.JOINED -> "جهاز جديد انضم: $name" to "صار $inGroups"
                PresenceKind.BACK -> "$name رجع متصل" to inGroups
                PresenceKind.LEFT -> {
                    val why = when (val reason = event.reason) {
                        is LeaveReason.Quiet -> "دخل وقت الإيقاف لحد ${TimeFormat.clock(reason.untilMs, use24Hour)}"
                        LeaveReason.Paused -> "وقّف المشاركة"
                        else -> "انقطع: طلع من الشبكة، أو نام، أو انسكّر CoShare عليه"
                    }
                    "$name طلع" to "$why · $inGroups"
                }
            }
        }
    }
}
