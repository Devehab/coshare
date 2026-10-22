import Foundation

/// Turns the changing list of connected devices into "came in" / "went out" events:
///  - a device that drops for a few seconds and comes back makes no noise at all,
///  - nothing is reported while this device itself is (re)connecting (launch, network change, wake),
///  - a device that said bye (quiet hours, paused) is reported at once, with why,
///  - the first time a device is ever seen in a group it reads as "joined", afterwards as "back".
/// It only decides what happened; whether to show it is up to the settings (see SyncEngine.notify).
@MainActor
final class PresenceWatch {
    struct Member: Equatable {
        let id: String
        let name: String
        /// The groups it shares with this device: (id, name as this device knows it).
        let groups: [GroupRef]
    }

    struct GroupRef: Equatable {
        let id: String
        let name: String
    }

    enum Reason: Equatable {
        /// It said bye for its quiet hours.
        case quiet(until: Date)
        /// It said bye without an end time (paused).
        case paused
        /// It stopped answering: left the network, went to sleep, or CoShare was closed.
        case lost
    }

    enum Kind: Equatable {
        case joined
        case back
        case left(Reason)
    }

    struct Event: Equatable {
        let kind: Kind
        let member: Member
    }

    /// How long a device may be gone before it counts as out.
    static let leaveGrace: TimeInterval = 30
    /// How long after this device (re)connects nothing is reported.
    static let settleTime: TimeInterval = 20
    private static let knownKey = "presence.knownMembers"

    var onEvent: ((Event) -> Void)?

    private let defaults: UserDefaults
    private var online: [String: Member] = [:]
    private var pendingLeaves: [String: (member: Member, since: Date)] = [:]
    private var byes: [String: Reason] = [:]
    private var quietUntil = Date.distantPast
    /// groupID → every device ID ever seen in it (saved).
    private var known: [String: Set<String>]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let saved = defaults.dictionary(forKey: Self.knownKey) as? [String: [String]] ?? [:]
        known = saved.mapValues(Set.init)
    }

    /// This device is (re)connecting: whatever comes and goes in the next moments is its own doing.
    func settle(now: Date = Date()) {
        quietUntil = now.addingTimeInterval(Self.settleTime)
        pendingLeaves.removeAll()
    }

    /// This device went off the network on purpose (quiet hours, paused): forget who was there.
    func reset() {
        online.removeAll()
        pendingLeaves.removeAll()
        byes.removeAll()
    }

    func update(_ members: [Member], now: Date = Date()) {
        let settling = now < quietUntil
        var knownChanged = false
        let present = Set(members.map(\.id))

        for member in members {
            var firstTimeIn: [GroupRef] = []
            for group in member.groups where !(known[group.id]?.contains(member.id) ?? false) {
                known[group.id, default: []].insert(member.id)
                firstTimeIn.append(group)
                knownChanged = true
            }
            let wasOnline = online[member.id] != nil
            online[member.id] = member
            var backWithinGrace = false
            if !wasOnline {
                byes.removeValue(forKey: member.id)
                backWithinGrace = pendingLeaves.removeValue(forKey: member.id) != nil
            }
            guard !settling else { continue }
            // Joining one of my groups is news even for a device that never left.
            if !firstTimeIn.isEmpty {
                emit(.joined, Member(id: member.id, name: member.name, groups: firstTimeIn))
            } else if !wasOnline && !backWithinGrace {
                emit(.back, member)
            }
        }

        for (id, member) in online where !present.contains(id) {
            online.removeValue(forKey: id)
            if let reason = byes.removeValue(forKey: id) {
                if !settling { emit(.left(reason), member) }
            } else if !settling {
                pendingLeaves[id] = (member, now)
            }
        }

        if knownChanged {
            defaults.set(known.mapValues { Array($0).sorted() }, forKey: Self.knownKey)
        }
    }

    /// A device told us it is leaving. Usually arrives just before it drops out of the list.
    func bye(_ deviceID: String, until: Date?, now: Date = Date()) {
        let reason: Reason = until.map { .quiet(until: $0) } ?? .paused
        if let pending = pendingLeaves.removeValue(forKey: deviceID) {
            emit(.left(reason), pending.member)
        } else {
            byes[deviceID] = reason
        }
    }

    /// Reports devices that have now been gone longer than the grace time. Call every few seconds.
    func tick(now: Date = Date()) {
        for (id, pending) in pendingLeaves where now.timeIntervalSince(pending.since) >= Self.leaveGrace {
            pendingLeaves.removeValue(forKey: id)
            emit(.left(.lost), pending.member)
        }
    }

    private func emit(_ kind: Kind, _ member: Member) {
        onEvent?(Event(kind: kind, member: member))
    }
}
