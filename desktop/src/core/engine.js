'use strict';
// Watches the clipboard, sends every new copy to all devices in this device's groups and applies
// clips that arrive from them — the Node twin of Shared/SyncEngine.swift (same behaviour, same protocol).
const { EventEmitter } = require('events');
const P = require('./protocol');
const { PeerNetwork } = require('./network');
const { Settings, History, ActivityLog, RETENTION } = require('./store');

const MAX_IMAGE_BYTES = 40 * 1024 * 1024;
const MIN_PASSWORD = 6;
const label = (kind) => (kind === 'text' ? 'نص' : 'صورة');

class SyncEngine extends EventEmitter {
  /**
   * @param clipboard { changeToken(), read({includeImages, maxImageBytes}), write(content), lastReadProblem? }
   * @param platform  "windows" | "linux" | "mac"
   */
  constructor({ dataDir, clipboard, platform, defaultName, env = {}, verbose = false }) {
    super();
    this.clipboard = clipboard;
    this.platform = platform;
    this.settings = new Settings(dataDir, defaultName);
    const retention = this.settings.get('historyRetentionHours');
    this.history = new History(dataDir, retention);
    this.log = new ActivityLog(dataDir, verbose, retention);
    this.log.listeners.add(() => this.changed());
    this.network = new PeerNetwork({ store: this.settings, env });
    this.network.on('peers', (peers) => this.updatePeers(peers));
    this.network.on('event', (text, isError) => this.log.add(text, isError));
    this.network.onRequest = (message, group) => this.handle(message, group);
    this.peers = [];
    this.identity = null;
    this.keyCache = new Map();
    this.presence = { state: 'online' };
    this.lastToken = null;
    this.currentHash = null;
    this.currentDate = 0;
    this.seenClipIDs = [];
    this.timers = [];
    this.netGeneration = 0;
    this.started = false;
    const latest = this.history.items[0];
    if (latest) { this.currentHash = latest.hash; this.currentDate = latest.date; }
  }

  // ------------------------------------------------------------------ lifecycle

  start() {
    if (this.started) return;
    this.started = true;
    this.log.add(`بدأ CoShare على «${this.settings.get('deviceName')}»`);
    // Whatever was copied before launch is old news; only new copies are shared.
    this.lastToken = this.safeToken();
    // During quiet hours the app starts without touching the network at all.
    this.presence = this.computePresence();
    if (this.isOnline()) this.startNetwork(); else this.log.add(this.offlineMessage(this.presence));
    this.timers.push(setInterval(() => this.pollNow(), 400));
    this.timers.push(setInterval(() => this.updatePresence(), 15000));
    // Every minute, so even a one-hour retention is kept to the minute.
    this.timers.push(setInterval(() => { if (this.history.purge()) this.changed(); this.log.purge(); }, 60000));
  }

  stop() {
    this.timers.forEach(clearInterval);
    this.timers = [];
    this.network.stop();
    this.started = false;
  }

  isOnline() { return this.presence.state === 'online'; }

  async startNetwork() {
    if (!this.isOnline()) return;
    const gen = ++this.netGeneration;
    const groups = [];
    for (const membership of this.settings.get('groups')) {
      const { key, tag } = await this.deriveKey(membership.id, membership.password);
      groups.push({ id: membership.id, name: membership.name, key, tag, membership });
    }
    if (gen !== this.netGeneration || !this.isOnline()) return;
    const name = (this.settings.get('deviceName') || '').trim() || this.platform;
    this.identity = { id: this.settings.get('deviceID'), name, platform: this.platform, groups,
      quiet: this.settings.get('quietEnabled') ? this.settings.get('quietSchedule') : null };
    this.network.start(this.identity);
    this.changed();
  }

  restartNetwork() { if (this.started && this.isOnline()) this.startNetwork(); }
  refreshDiscovery() { if (this.isOnline()) this.network.refreshDiscovery(); }

  async deriveKey(groupID, password) {
    const cacheKey = groupID + '\u0000' + password;
    if (!this.keyCache.has(cacheKey)) this.keyCache.set(cacheKey, await P.deriveGroupKey(groupID, password));
    return this.keyCache.get(cacheKey);
  }

  // ------------------------------------------------------------------ quiet hours / pause

  computePresence(now = new Date()) {
    if (this.settings.get('paused')) return { state: 'paused' };
    if (!this.settings.get('quietEnabled')) return { state: 'online' };
    const window = P.quietWindow(this.settings.get('quietSchedule'), now);
    if (!window) return { state: 'online' };
    if (this.settings.get('resumedWindowStart') === window.start.getTime()) return { state: 'online' };
    return { state: 'quiet', until: window.end.getTime() };
  }

  offlineMessage(p) {
    if (p.state === 'paused') return 'متوقف — CoShare منفصل تماماً عن الشبكة';
    if (p.state === 'quiet') {
      const t = new Date(p.until).toLocaleTimeString('ar', { hour: 'numeric', minute: '2-digit' });
      return `وقت الإيقاف — CoShare منفصل تماماً عن الشبكة حتى ${t}`;
    }
    return 'CoShare متصل بالشبكة';
  }

  updatePresence() {
    const next = this.computePresence();
    if (next.state === this.presence.state && next.until === this.presence.until) return;
    const wasOnline = this.isOnline();
    this.presence = next;
    if (wasOnline && next.state !== 'online') this.goOffline(next);
    else if (!wasOnline && next.state === 'online') this.comeBack();
    else this.log.add(this.offlineMessage(next));
    this.changed();
  }

  /** Tells the group "quiet until …" once, then closes every socket. */
  async goOffline(next) {
    this.log.add(this.offlineMessage(next));
    this.netGeneration++;
    const targets = this.connectedPeers();
    if (this.identity && targets.length) {
      const header = this.header('bye');
      header.listenPort = this.network.listenPort;
      if (next.until) header.quietUntil = next.until / 1000;
      await this.exchange({ header }, targets, 3000);
    }
    if (this.isOnline()) return;
    this.network.stop();
    this.identity = null;
  }

  comeBack() {
    // Copies made while away stay on this device, and nothing from that time is pulled in.
    this.lastToken = this.safeToken();
    this.currentDate = Math.max(this.currentDate, Date.now() / 1000);
    this.log.add('رجع CoShare للشبكة');
    this.startNetwork();
  }

  resumeToday() {
    if (this.settings.get('paused')) this.settings.set('paused', false);
    if (this.settings.get('quietEnabled')) {
      const window = P.quietWindow(this.settings.get('quietSchedule'));
      if (window) this.settings.set('resumedWindowStart', window.start.getTime());
    }
    this.updatePresence();
  }

  pause() { this.settings.set('paused', true); this.updatePresence(); }

  setSetting(key, value) {
    const allowed = ['deviceName', 'syncImages', 'quietEnabled', 'quietSchedule', 'launchAtLogin', 'use24Hour', 'historyRetentionHours'];
    if (!allowed.includes(key)) return;
    if (key === 'historyRetentionHours') {
      value = RETENTION.clamp(value);
      this.history.setRetention(value);
      this.log.setRetention(value);
    }
    if (key === 'use24Hour') value = !!value;
    this.settings.set(key, value);
    if (key === 'quietEnabled' || key === 'quietSchedule') {
      const before = this.isOnline();
      this.updatePresence();
      if (before && this.isOnline()) this.restartNetwork(); // re-advertise the new schedule
    }
    if (key === 'deviceName') this.restartNetwork();
    this.changed();
  }

  // ------------------------------------------------------------------ groups

  connectedPeers() { return this.peers.filter((p) => this.sharedGroup(p)); }

  sharedGroup(peer) {
    if (!this.identity) return null;
    return this.identity.groups.find((g) => (peer.groups || []).some((pg) => pg.id === g.id && pg.tag === g.tag)) || null;
  }

  membersOf(groupID) {
    const g = this.identity && this.identity.groups.find((x) => x.id === groupID);
    if (!g) return [];
    return this.peers.filter((p) => (p.groups || []).some((pg) => pg.id === g.id && pg.tag === g.tag));
  }

  nearbyGroups() {
    const mine = new Set(this.settings.get('groups').map((g) => g.id));
    const byKey = new Map();
    for (const peer of this.peers) {
      for (const g of peer.groups || []) {
        if (mine.has(g.id)) continue;
        const key = g.id + g.tag;
        if (!byKey.has(key)) byKey.set(key, { key, group: g, memberNames: [] });
        byKey.get(key).memberNames.push(peer.name);
      }
    }
    return [...byKey.values()].sort((a, b) => a.group.name.localeCompare(b.group.name));
  }

  createGroup(name, password) {
    name = String(name || '').trim();
    if (!name) throw new Error('اكتب اسم للمجموعة');
    if (String(password || '').length < MIN_PASSWORD) throw new Error(`كلمة السر لازم تكون ${MIN_PASSWORD} أحرف على الأقل`);
    const group = { id: P.newGroupID(), name, password, joinedAt: Date.now() / 1000 };
    this.saveGroups([...this.settings.get('groups'), group]);
    this.log.add(`أنشأت مجموعة «${name}»`);
    return { id: group.id, name };
  }

  /** Checks the password against the tag the group advertises, then joins for good. */
  async join(key, password) {
    const nearby = this.nearbyGroups().find((n) => n.key === key);
    if (!nearby) throw new Error('المجموعة ما عادت ظاهرة على الشبكة');
    const { tag } = await this.deriveKey(nearby.group.id, password);
    if (tag !== nearby.group.tag) {
      this.log.add(`كلمة سر خاطئة لمجموعة «${nearby.group.name}»`, true);
      throw new Error('كلمة السر غير صحيحة');
    }
    this.saveGroups([...this.settings.get('groups').filter((g) => g.id !== nearby.group.id),
      { id: nearby.group.id, name: nearby.group.name, password, joinedAt: Date.now() / 1000 }]);
    this.log.add(`انضممت لمجموعة «${nearby.group.name}»`);
    return { id: nearby.group.id, name: nearby.group.name };
  }

  /** coshare://join?g=<id>&n=<name>&p=<password> (QR invite). */
  joinInvite(url) {
    let invite;
    try {
      const u = new URL(url);
      if (u.protocol !== 'coshare:' || u.hostname !== 'join') throw new Error();
      invite = { id: u.searchParams.get('g'), name: u.searchParams.get('n') || 'CoShare', password: u.searchParams.get('p') };
    } catch { invite = null; }
    if (!invite || !invite.id || !invite.password) throw new Error('هاد الرمز مش دعوة CoShare');
    this.saveGroups([...this.settings.get('groups').filter((g) => g.id !== invite.id), { ...invite, joinedAt: Date.now() / 1000 }]);
    this.log.add(`انضممت لمجموعة «${invite.name}» عن طريق الدعوة`);
    return { id: invite.id, name: invite.name };
  }

  leave(groupID) {
    const group = this.settings.get('groups').find((g) => g.id === groupID);
    this.saveGroups(this.settings.get('groups').filter((g) => g.id !== groupID));
    if (group) this.log.add(`غادرت مجموعة «${group.name}»`);
  }

  inviteURL(groupID) {
    const g = this.settings.get('groups').find((x) => x.id === groupID);
    if (!g) return null;
    const u = new URL('coshare://join');
    u.searchParams.set('g', g.id); u.searchParams.set('n', g.name); u.searchParams.set('p', g.password);
    return u.toString();
  }

  saveGroups(groups) {
    this.settings.set('groups', groups);
    this.restartNetwork();
    this.changed();
  }

  updatePeers(peers) {
    const before = this.connectedPeers();
    const oldIDs = new Set(before.map((p) => p.id));
    this.peers = peers;
    const now = this.connectedPeers();
    const newIDs = new Set(now.map((p) => p.id));
    for (const p of now) if (!oldIDs.has(p.id)) this.log.add(`متصل: ${p.name}${p.isDirect ? ' (اتصال مباشر)' : ''}`);
    for (const p of before) if (!newIDs.has(p.id)) this.log.add(`انقطع: ${p.name}`);
    // A device that just (re)joined may hold something copied while we couldn't see each other.
    const joined = now.filter((p) => !oldIDs.has(p.id));
    if (joined.length) this.pullLatest(joined);
    this.changed();
  }

  // ------------------------------------------------------------------ local clipboard → devices

  safeToken() { try { return this.clipboard.changeToken(); } catch { return null; } }

  pollNow() {
    if (!this.started) return false;
    const token = this.safeToken();
    if (token === this.lastToken) return false;
    this.lastToken = token;
    if (!this.isOnline()) return false;
    let content;
    try { content = this.clipboard.read({ includeImages: this.settings.get('syncImages'), maxImageBytes: MAX_IMAGE_BYTES }); }
    catch (error) { this.log.add(`تعذّرت قراءة الحافظة: ${error.message}`, true); return false; }
    if (!content) return false;
    const payload = content.kind === 'text' ? Buffer.from(content.text, 'utf8') : content.data;
    const hash = P.contentHash(content.kind, payload);
    if (hash === this.currentHash) return false;
    this.currentHash = hash;
    this.currentDate = Date.now() / 1000;
    this.broadcast(content, payload, hash);
    return true;
  }

  async sendCurrentClipboard() {
    if (!this.isOnline()) { this.log.add(`ما انبعت شي — ${this.offlineMessage(this.presence)}`); return 0; }
    const content = this.clipboard.read({ includeImages: this.settings.get('syncImages'), maxImageBytes: MAX_IMAGE_BYTES });
    if (!content) { this.log.add('الحافظة فارغة أو محتواها غير مدعوم', true); return 0; }
    this.lastToken = this.safeToken();
    const payload = content.kind === 'text' ? Buffer.from(content.text, 'utf8') : content.data;
    const hash = P.contentHash(content.kind, payload);
    this.currentHash = hash;
    this.currentDate = Date.now() / 1000;
    return this.broadcast(content, payload, hash);
  }

  copyItem(id) {
    const item = this.history.items.find((i) => i.id === id);
    const content = item && this.history.content(item);
    if (content) this.clipboard.write(content); // the next poll shares it
  }

  async broadcast(content, payload, hash) {
    const item = this.history.add({ kind: content.kind, text: content.text, data: content.data, uti: content.uti, hash,
      deviceName: this.settings.get('deviceName'), direction: 'sent', date: this.currentDate });
    this.changed();
    if (!this.identity || !this.identity.groups.length) { this.log.add(`نُسخ ${label(content.kind)} — هذا الجهاز ليس في أي مجموعة بعد`); return 0; }
    const targets = this.connectedPeers();
    if (!targets.length) { this.log.add(`نُسخ ${label(content.kind)} — لا توجد أجهزة متصلة حالياً`); return 0; }
    const header = this.header('clip', { id: P.randomID(), kind: content.kind, ...(content.uti ? { uti: content.uti } : {}),
      hash, createdAt: this.currentDate, origin: this.identity.name });
    const results = await this.exchange({ header, payload }, targets, Math.min(120000, 8000 + payload.length / 1000));
    const delivered = results.filter((r) => r.reply && r.reply.header.type === 'ack').length;
    this.history.setDelivered(item.id, delivered);
    this.log.add(`أُرسل ${label(content.kind)} إلى ${delivered} من ${targets.length} أجهزة`);
    for (const r of results) if (!r.reply) this.log.add(`تعذّر الإرسال إلى ${r.peer.name}: ${r.error ? r.error.message : ''}`, true);
    if (delivered) this.flash('sent');
    this.changed();
    return delivered;
  }

  // ------------------------------------------------------------------ devices → local clipboard

  async handle(message, group) {
    const { header, payload } = message;
    if (!this.identity) return null;
    if (header.type === 'clip') {
      const meta = header.clip;
      if (meta) this.apply(meta, payload, meta.origin || header.senderName);
      return { header: this.header('ack') };
    }
    if (header.type === 'pullLatest') {
      const item = this.history.items[0];
      const content = item && this.history.content(item);
      if (!content) return { header: this.header('nothing') };
      const data = content.kind === 'text' ? Buffer.from(content.text, 'utf8') : content.data;
      return { header: this.header('latest', { id: item.id, kind: item.kind, ...(item.uti ? { uti: item.uti } : {}),
        hash: item.hash, createdAt: item.date, origin: item.deviceName }), payload: data };
    }
    return { header: this.header('ack') };
  }

  apply(meta, payload, sender) {
    if (this.seenClipIDs.includes(meta.id)) return false;
    this.seenClipIDs.push(meta.id);
    if (this.seenClipIDs.length > 200) this.seenClipIDs.splice(0, 50);
    if (!this.isOnline() || meta.hash === this.currentHash) return false;
    let content;
    if (meta.kind === 'text') content = { kind: 'text', text: payload.toString('utf8') };
    else if (meta.kind === 'image' && this.settings.get('syncImages')) content = { kind: 'image', data: payload, uti: meta.uti || 'public.png' };
    else return false;
    try { this.clipboard.write(content); } catch (error) { this.log.add(`تعذّرت الكتابة على الحافظة: ${error.message}`, true); return false; }
    this.lastToken = this.safeToken();
    this.currentHash = meta.hash;
    this.currentDate = meta.createdAt;
    this.history.add({ kind: content.kind, text: content.text, data: content.data, uti: content.uti, hash: meta.hash,
      deviceName: sender, direction: 'received', date: meta.createdAt });
    this.log.add(`استُلم ${label(content.kind)} من ${sender} — جاهز للصق`);
    this.flash('received');
    this.changed();
    return true;
  }

  async pullLatest(specific) {
    if (!this.isOnline() || !this.identity) return false;
    const targets = specific || this.connectedPeers();
    if (!targets.length) return false;
    const results = await this.exchange({ header: this.header('pullLatest') }, targets, 20000);
    const newest = results.map((r) => r.reply).filter((m) => m && m.header.type === 'latest' && m.header.clip)
      .sort((a, b) => b.header.clip.createdAt - a.header.clip.createdAt)[0];
    if (!newest || newest.header.clip.createdAt <= this.currentDate) return false;
    return this.apply(newest.header.clip, newest.payload, newest.header.clip.origin || newest.header.senderName);
  }

  // ------------------------------------------------------------------ helpers

  header(type, clip) {
    const h = { type, senderID: this.identity.id, senderName: this.identity.name, platform: this.platform };
    if (clip) h.clip = clip;
    return h;
  }

  /** Sends a message to every target, sealed once per shared group. */
  async exchange(message, targets, timeoutMs) {
    const frames = new Map();
    const jobs = [];
    for (const peer of targets) {
      const group = this.sharedGroup(peer);
      if (!group) continue;
      if (!frames.has(group.id)) frames.set(group.id, P.encodeFrame(group.key, message.header, message.payload));
      jobs.push(this.network.exchange(frames.get(group.id), group.key, peer, timeoutMs)
        .then((reply) => ({ peer, reply }), (error) => ({ peer, reply: null, error })));
    }
    return Promise.all(jobs);
  }

  flash(kind) {
    this.pulse = kind;
    clearTimeout(this.pulseTimer);
    this.pulseTimer = setTimeout(() => { this.pulse = null; this.changed(); }, 1500);
    this.changed();
  }

  changed() {
    clearTimeout(this.changeTimer);
    this.changeTimer = setTimeout(() => this.emit('change'), 50);
  }

  /** Everything the window needs to draw itself. */
  snapshot() {
    const groups = this.settings.get('groups').map((g) => ({
      id: g.id, name: g.name,
      members: this.membersOf(g.id).map((p) => ({ id: p.id, name: p.name, platform: p.platform, isDirect: p.isDirect }))
        .sort((a, b) => a.name.localeCompare(b.name)),
    }));
    return {
      deviceName: this.settings.get('deviceName'),
      presence: this.presence,
      pulse: this.pulse || null,
      connected: this.connectedPeers().map((p) => ({ id: p.id, name: p.name, platform: p.platform, isDirect: p.isDirect })),
      groups,
      nearby: this.nearbyGroups(),
      history: this.history.items.map((i) => ({ ...i, path: this.history.blobPath(i) })),
      log: this.log.entries.slice(0, 300),
      settings: {
        syncImages: this.settings.get('syncImages'),
        quietEnabled: this.settings.get('quietEnabled'),
        quietSchedule: this.settings.get('quietSchedule'),
        launchAtLogin: this.settings.get('launchAtLogin'),
        use24Hour: this.settings.get('use24Hour'),
        historyRetentionHours: this.settings.get('historyRetentionHours'),
      },
      platform: this.platform,
    };
  }
}

module.exports = { SyncEngine };
