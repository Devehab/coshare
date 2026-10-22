'use strict';
// "Device in / device out" — the Node twin of Shared/PresenceWatch.swift (same rules, same words):
//  - a device that drops for a few seconds and comes back makes no noise at all,
//  - nothing is reported while this device itself is (re)connecting (launch, wake),
//  - a device that said bye (quiet hours, paused) is reported at once, with why,
//  - the first time a device is ever seen in a group it reads as "joined", afterwards as "back".

/** How long a device may be gone before it counts as out. */
const LEAVE_GRACE = 30000;
/** How long after this device (re)connects nothing is reported. */
const SETTLE_TIME = 20000;

class PresenceWatch {
  /** @param store { get, set } — keeps who was ever seen in each group under "knownMembers". */
  constructor(store) {
    this.store = store;
    this.onEvent = null;
    this.online = new Map();        // id → member
    this.pendingLeaves = new Map(); // id → { member, since }
    this.byes = new Map();          // id → reason
    this.quietUntil = 0;
    const saved = store.get('knownMembers') || {};
    this.known = new Map(Object.entries(saved).map(([group, ids]) => [group, new Set(ids)]));
  }

  /** This device is (re)connecting: whatever comes and goes in the next moments is its own doing. */
  settle(now = Date.now()) {
    this.quietUntil = now + SETTLE_TIME;
    this.pendingLeaves.clear();
  }

  /** This device went off the network on purpose (quiet hours, paused): forget who was there. */
  reset() {
    this.online.clear();
    this.pendingLeaves.clear();
    this.byes.clear();
  }

  /** @param members [{ id, name, groups: [{ id, name }] }] — the devices sharing a group with us now. */
  update(members, now = Date.now()) {
    const settling = now < this.quietUntil;
    let knownChanged = false;
    const present = new Set(members.map((m) => m.id));

    for (const member of members) {
      const firstTimeIn = [];
      for (const group of member.groups) {
        if (!this.known.has(group.id)) this.known.set(group.id, new Set());
        if (this.known.get(group.id).has(member.id)) continue;
        this.known.get(group.id).add(member.id);
        firstTimeIn.push(group);
        knownChanged = true;
      }
      const wasOnline = this.online.has(member.id);
      this.online.set(member.id, member);
      let backWithinGrace = false;
      if (!wasOnline) {
        this.byes.delete(member.id);
        backWithinGrace = this.pendingLeaves.delete(member.id);
      }
      if (settling) continue;
      // Joining one of my groups is news even for a device that never left.
      if (firstTimeIn.length) this.emit('joined', { ...member, groups: firstTimeIn });
      else if (!wasOnline && !backWithinGrace) this.emit('back', member);
    }

    for (const [id, member] of [...this.online]) {
      if (present.has(id)) continue;
      this.online.delete(id);
      const reason = this.byes.get(id);
      if (reason) {
        this.byes.delete(id);
        if (!settling) this.emit('left', member, reason);
      } else if (!settling) {
        this.pendingLeaves.set(id, { member, since: now });
      }
    }

    if (knownChanged) {
      this.store.set('knownMembers', Object.fromEntries([...this.known].map(([g, ids]) => [g, [...ids].sort()])));
    }
  }

  /** A device told us it is leaving: quiet until `until` (ms), or paused when null. */
  bye(id, until) {
    const reason = until ? { type: 'quiet', until } : { type: 'paused' };
    const pending = this.pendingLeaves.get(id);
    if (pending) {
      this.pendingLeaves.delete(id);
      this.emit('left', pending.member, reason);
    } else {
      this.byes.set(id, reason);
    }
  }

  /** Reports devices that have now been gone longer than the grace time. Call every few seconds. */
  tick(now = Date.now()) {
    for (const [id, pending] of [...this.pendingLeaves]) {
      if (now - pending.since < LEAVE_GRACE) continue;
      this.pendingLeaves.delete(id);
      this.emit('left', pending.member, { type: 'lost' });
    }
  }

  emit(kind, member, reason) {
    if (this.onEvent) this.onEvent(reason ? { kind, member, reason } : { kind, member });
  }
}

/** Title and body in the apps' own words. */
function presenceText(event, use24Hour) {
  const { name } = event.member;
  const groups = event.member.groups.map((g) => `«${g.name}»`).join(' و');
  const inGroups = event.member.groups.length > 1 ? `بمجموعات ${groups}` : `بمجموعة ${groups}`;
  if (event.kind === 'joined') return { title: `جهاز جديد انضم: ${name}`, body: `صار ${inGroups}` };
  if (event.kind === 'back') return { title: `${name} رجع متصل`, body: inGroups };
  let why = 'انقطع: طلع من الشبكة، أو نام، أو انسكّر CoShare عليه';
  if (event.reason.type === 'quiet') {
    const time = new Date(event.reason.until).toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', hour12: !use24Hour });
    why = `دخل وقت الإيقاف لحد ${time}`;
  } else if (event.reason.type === 'paused') {
    why = 'وقّف المشاركة';
  }
  return { title: `${name} طلع`, body: `${why} · ${inGroups}` };
}

module.exports = { PresenceWatch, presenceText, LEAVE_GRACE, SETTLE_TIME };
