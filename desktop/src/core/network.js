'use strict';
// Finds devices and talks to them — the Node twin of Shared/PeerNetwork.swift.
// Every device listens on a (preferably fixed) TCP port and is found by Bonjour (_coshare._tcp)
// or by greeting the gateway / addresses seen before with a "hello" (hotspots, filtered networks).
const net = require('net');
const fs = require('fs');
const { execFile } = require('child_process');
const { EventEmitter } = require('events');
const { Bonjour } = require('bonjour-service');
const P = require('./protocol');

const PREFERRED_PORT = 47331;
/** A device of our groups that hasn't been heard from for this long is gone, even if Bonjour still
 *  lists it (a vanished device stays in its cache for a long time when Wi-Fi drops or it sleeps). */
const LIVENESS = 60000;

/** Reads exactly one length-prefixed frame body from a socket. */
function readFrame(socket, timeoutMs) {
  return new Promise((resolve, reject) => {
    let buffer = Buffer.alloc(0);
    let needed = null;
    const timer = setTimeout(() => finish(new Error('timeout')), timeoutMs);
    function finish(error, body) {
      clearTimeout(timer);
      socket.off('data', onData);
      socket.off('error', onError);
      socket.off('close', onClose);
      error ? reject(error) : resolve(body);
    }
    function onData(chunk) {
      buffer = Buffer.concat([buffer, chunk]);
      if (needed === null && buffer.length >= 4) {
        needed = buffer.readUInt32BE(0);
        if (needed <= 0 || needed > P.MAX_FRAME) return finish(new Error('frame too large'));
      }
      if (needed !== null && buffer.length >= 4 + needed) finish(null, buffer.subarray(4, 4 + needed));
    }
    const onError = (e) => finish(e);
    const onClose = () => finish(new Error('connection closed'));
    socket.on('data', onData);
    socket.on('error', onError);
    socket.on('close', onClose);
  });
}

const cleanAddress = (address) => String(address || '').replace(/^::ffff:/, '').split('%')[0];
const isLoopback = (host) => host.startsWith('127.') || host === '::1';
/** fe80:: means nothing without the interface it belongs to (which cleanAddress drops). */
const isLinkLocal = (host) => /^fe80:/i.test(host);

/** Default IPv4 gateways — on a phone's hotspot that is the phone itself. */
function readGateways() {
  return new Promise((resolve) => {
    if (process.platform === 'linux') {
      try {
        const rows = fs.readFileSync('/proc/net/route', 'utf8').trim().split('\n').slice(1);
        const gateways = rows.map((row) => row.trim().split(/\s+/))
          .filter((cols) => cols[1] === '00000000' && cols[2] !== '00000000')
          .map((cols) => cols[2].match(/../g).reverse().map((h) => parseInt(h, 16)).join('.'));
        return resolve([...new Set(gateways)]);
      } catch { return resolve([]); }
    }
    const [cmd, args, pattern] = process.platform === 'win32'
      ? ['route', ['print', '-4', '0.0.0.0'], /^\s*0\.0\.0\.0\s+0\.0\.0\.0\s+(\d+\.\d+\.\d+\.\d+)/gm]
      : ['route', ['-n', 'get', 'default'], /gateway:\s*(\d+\.\d+\.\d+\.\d+)/g];
    execFile(cmd, args, { timeout: 3000, windowsHide: true }, (error, stdout) => {
      if (error) return resolve([]);
      resolve([...new Set([...String(stdout).matchAll(pattern)].map((m) => m[1]))]);
    });
  });
}

class PeerNetwork extends EventEmitter {
  /** @param store persistent key/value store ({ get, set }) for remembered addresses and schedules. */
  constructor({ store, env = {} }) {
    super();
    this.store = store;
    this.preferredPort = env.port || PREFERRED_PORT;
    this.noBonjour = !!env.noBonjour;
    this.extraHosts = env.extraHosts || [];
    this.onRequest = null; // async (message, group) => reply message or null
    this.identity = null;
    this.server = null;
    this.listenPort = 0;
    this.bonjour = null;
    this.browser = null;
    this.service = null;
    this.timers = [];
    this.gateways = [];
    this.browsed = new Map();   // id → peer
    this.direct = new Map();    // id → { peer, seen }
    this.silenced = new Map();  // id → until (ms)
    this.silencedAddresses = new Map(); // "host" / "host:port" → { id, until }
    // When each device said bye. Its goodbye takes a moment to reach Bonjour, so an advertisement seen
    // right after is the old one, not the device coming back (a hello still is).
    this.byeAt = new Map();
    this.lastContact = new Map(); // id → last time it answered us or called us (ms)
    this.firstSeen = new Map();   // id → when Bonjour first listed it (ms)
    this.generation = 0;
  }

  start(identity) {
    this.stop(false);
    this.identity = identity;
    const gen = ++this.generation;
    this.startServer(gen, this.preferredPort, 0);
    this.timers.push(setInterval(() => this.runDirectProbe(), 15000));
    this.timers.push(setInterval(() => this.refreshGateways(), 60000));
    this.refreshGateways();
  }

  stop(publishEmpty = true) {
    this.generation++;
    this.timers.forEach((t) => { clearInterval(t); clearTimeout(t); });
    this.timers = [];
    if (this.browser) { try { this.browser.stop(); } catch {} this.browser = null; }
    if (this.bonjour) {
      const bonjour = this.bonjour;
      this.bonjour = null;
      try { bonjour.unpublishAll(() => bonjour.destroy()); } catch {}
    }
    if (this.server) { try { this.server.close(); } catch {} this.server = null; }
    this.browsed.clear();
    this.direct.clear();
    this.lastContact.clear();
    this.firstSeen.clear();
    if (publishEmpty) this.emit('peers', []);
  }

  refreshDiscovery() {
    if (this.browser) { try { this.browser.update(); } catch {} }
    this.runDirectProbe();
  }

  // ---------------------------------------------------------------- server

  startServer(gen, port, attempt) {
    const server = net.createServer((socket) => this.serve(socket));
    server.on('error', (error) => {
      if (gen !== this.generation) return;
      try { server.close(); } catch {}
      if (port && attempt < 12) {
        // Right after a restart the old listener may still hold the fixed port.
        setTimeout(() => gen === this.generation && this.startServer(gen, port, attempt + 1), 500);
      } else if (port) {
        this.emit('event', `المنفذ ${port} مشغول — الاتصال المباشر (Hotspot) قد لا يعمل`, true);
        this.startServer(gen, 0, 0);
      } else {
        this.emit('event', `تعذّر فتح منفذ الاستقبال: ${error.message}`, true);
      }
    });
    server.listen({ port, host: '::', ipv6Only: false }, () => {
      if (gen !== this.generation) return server.close();
      this.server = server;
      this.listenPort = server.address().port;
      this.emit('event', `جاهز للاستقبال على المنفذ ${this.listenPort}`, false);
      if (!this.noBonjour) this.startBonjour(gen);
      this.runDirectProbe();
    });
  }

  async serve(socket) {
    socket.setNoDelay(true);
    socket.setTimeout(120000, () => socket.destroy());
    const me = this.identity;
    let body;
    try { body = await readFrame(socket, 120000); } catch { return socket.destroy(); }
    // Anything we can't decrypt (another group, a stranger, a port scan) is dropped silently.
    const opened = me && this.openAny(me, body);
    if (!opened) return socket.destroy();
    const { message, group } = opened;
    const { header } = message;
    if (header.type !== 'bye') this.lastContact.set(header.senderID, Date.now());
    try {
      let reply = null;
      if (header.type === 'hello') {
        this.learnDirectPeer(header, cleanAddress(socket.remoteAddress), group);
        reply = this.helloMessage(me);
      } else if (header.type === 'bye') {
        this.silence(header.senderID, header.quietUntil, header.senderName, cleanAddress(socket.remoteAddress), header.listenPort);
        reply = { header: { type: 'ack', senderID: me.id, senderName: me.name, platform: me.platform } };
      } else if (this.onRequest) {
        reply = await this.onRequest(message, group);
      }
      if (!reply) return socket.destroy();
      socket.write(P.encodeFrame(group.key, reply.header, reply.payload));
      // Let the client read the reply before the socket goes away.
      const done = () => socket.destroy();
      socket.once('end', done);
      socket.once('close', done);
      setTimeout(done, 5000);
    } catch (error) {
      this.emit('event', `خطأ أثناء الرد على «${header.senderName}»: ${error.message}`, true);
      socket.destroy();
    }
  }

  openAny(me, body) {
    for (const group of me.groups) {
      try { return { message: P.decodeFrame(group.key, body), group }; } catch {}
    }
    return null;
  }

  // ---------------------------------------------------------------- client

  /** Connects, sends one frame sealed with `key` and resolves with the decoded reply. */
  exchange(frame, key, peer, timeoutMs) {
    return new Promise((resolve, reject) => {
      const socket = net.connect({ host: peer.host, port: peer.port });
      socket.setNoDelay(true);
      const timer = setTimeout(() => { socket.destroy(); reject(new Error('انتهت المهلة')); }, timeoutMs);
      socket.once('error', (error) => { clearTimeout(timer); reject(error); });
      socket.once('connect', async () => {
        if (!peer.isDirect) this.saveKnownHost(cleanAddress(socket.remoteAddress), peer.id);
        socket.write(frame);
        try {
          const body = await readFrame(socket, timeoutMs);
          clearTimeout(timer);
          socket.end();
          const reply = P.decodeFrame(key, body);
          if (peer.id) this.lastContact.set(peer.id, Date.now());
          resolve(reply);
        } catch (error) {
          clearTimeout(timer);
          socket.destroy();
          reject(error);
        }
      });
    });
  }

  // ---------------------------------------------------------------- Bonjour

  startBonjour(gen) {
    const me = this.identity;
    try {
      this.bonjour = new Bonjour({}, (error) => this.emit('event', `Bonjour: ${error.message}`, true));
      const txt = { n: me.name, p: me.platform, i: me.id, v: '2' };
      me.groups.slice(0, 8).forEach((g, i) => { txt['g' + i] = P.groupTxt({ id: g.id, tag: g.tag, name: g.name }); });
      if (me.quiet) txt.q = P.scheduleTxt(me.quiet);
      this.service = this.bonjour.publish({ name: me.id, type: 'coshare', protocol: 'tcp', port: this.listenPort, txt, probe: false });
      this.browser = this.bonjour.find({ type: 'coshare', protocol: 'tcp' });
      const onChange = () => gen === this.generation && this.syncBrowsed(me);
      this.browser.on('up', onChange);
      this.browser.on('down', onChange);
      this.browser.on('txt-update', onChange);
      this.browser.on('srv-update', onChange);
      // Repeat the first query (responders ignore a repeat within a second — RFC 6762 §6), then keep
      // asking regularly (a long-running browse otherwise goes quiet) and drop records that expired.
      for (const delay of [1200, 4000, 10000]) {
        const t = setTimeout(() => { if (gen === this.generation && this.browser) try { this.browser.update(); } catch {} }, delay);
        this.timers.push(t);
      }
      this.timers.push(setInterval(() => { try { this.browser.update(); } catch {} }, 30000));
      this.timers.push(setInterval(() => { try { this.browser.expire(); onChange(); } catch {} }, 15000));
    } catch (error) {
      this.emit('event', `تعذّر تشغيل Bonjour: ${error.message}`, true);
    }
  }

  syncBrowsed(me) {
    const next = new Map();
    for (const service of this.browser ? this.browser.services : []) {
      const txt = service.txt || {};
      if (String(txt.v) !== '2') continue;
      const id = String(txt.i || service.name);
      if (id === me.id || String(service.name).startsWith(me.id)) continue;
      if (Date.now() - (this.byeAt.get(id) || 0) < 10000) continue;
      const addresses = (service.addresses || []).map(cleanAddress);
      const host = addresses.find((a) => net.isIPv4(a)) || addresses[0] || cleanAddress(service.referer && service.referer.address);
      if (!host) continue;
      const groups = [];
      for (let i = 0; i < 8; i++) { const g = txt['g' + i] && P.parseGroupTxt(txt['g' + i]); if (g) groups.push(g); }
      const quiet = txt.q ? P.parseScheduleTxt(txt.q) : null;
      next.set(id, { id, name: String(txt.n || service.name), platform: String(txt.p || 'other'), groups, host,
        port: service.port, isDirect: false, quiet });
      // Advertising again means it is back (e.g. "resume today").
      this.unsilence(id);
      this.saveSchedule(id, quiet);
    }
    this.browsed = next;
    this.publishMerged();
  }

  // ---------------------------------------------------------------- direct contact

  helloMessage(me) {
    return { header: { type: 'hello', senderID: me.id, senderName: me.name, platform: me.platform,
      listenPort: this.listenPort, groups: me.groups.map((g) => ({ id: g.id, tag: g.tag, name: g.name })),
      ...(me.quiet ? { quiet: me.quiet } : {}) } };
  }

  async refreshGateways() {
    this.gateways = await readGateways();
    this.runDirectProbe();
  }

  /** Greets the gateway and every address a group member had before; whoever answers becomes a peer. */
  runDirectProbe() {
    const me = this.identity;
    if (!me || !me.groups.length || !this.listenPort) return;
    const gen = this.generation;
    const known = Object.fromEntries(Object.entries(this.store.get('knownHosts') || {}).filter(([, host]) => !isLinkLocal(host)));
    const now = Date.now();
    // Never call a device during its quiet hours (or after it said bye).
    const quietHosts = new Set(Object.entries(known).filter(([id]) => this.isQuiet(id)).map(([, host]) => host));
    for (const [address, info] of this.silencedAddresses) if (info.until > now) quietHosts.add(address);
    const hosts = new Set([...this.gateways, ...Object.values(known), ...this.extraHosts]);
    for (const host of hosts) if (!quietHosts.has(host)) this.sayHello(host, me, gen);
    // Group devices Bonjour lists but we haven't heard from lately: greet them where Bonjour says they
    // are. An answer keeps them listed (see isAlive) and teaches us their address.
    for (const peer of this.browsed.values()) {
      if (this.isQuiet(peer.id) || now - (this.lastContact.get(peer.id) || 0) < 20000) continue;
      const keys = me.groups.filter((g) => peer.groups.some((x) => x.id === g.id && x.tag === g.tag));
      if (keys.length) this.greet(peer, keys, me, gen);
    }
    for (const [id, entry] of this.direct) if (now - entry.seen > 50000) this.direct.delete(id);
    this.publishMerged();
  }

  /** Says hello to a device found by Bonjour, with each shared key in turn until one is understood. */
  async greet(peer, keys, me, gen) {
    for (const group of keys) {
      try {
        const reply = await this.exchange(P.encodeFrame(group.key, this.helloMessage(me).header), group.key, peer, 4000);
        if (reply.header.type !== 'hello' || gen !== this.generation) return;
        this.unsilence(peer.id);
        this.saveSchedule(peer.id, reply.header.quiet || null);
        this.publishMerged();
        return;
      } catch (error) {
        if (error.code) return;
      }
    }
  }

  async sayHello(address, me, gen) {
    // "host:port" or "[v6]:port" (tests); a bare host uses the standard port.
    const match = address.match(/^\[(.+)\]:(\d+)$/) || address.match(/^([^:]+):(\d+)$/);
    const host = match ? match[1] : address;
    const port = match ? Number(match[2]) : this.preferredPort;
    for (const group of me.groups) {
      const frame = P.encodeFrame(group.key, this.helloMessage(me).header);
      let reply;
      try {
        reply = await this.exchange(frame, group.key, { id: '', host, port, isDirect: true }, 4000);
      } catch (error) {
        // Nothing listening (a normal router): stop. Connected but not our group: next key.
        if (error.code) return;
        continue;
      }
      const h = reply.header;
      if (h.type !== 'hello' || h.senderID === me.id || gen !== this.generation) return;
      const isNew = !this.direct.has(h.senderID);
      this.lastContact.set(h.senderID, Date.now());
      this.unsilence(h.senderID);
      this.saveSchedule(h.senderID, h.quiet || null);
      this.direct.set(h.senderID, { peer: { id: h.senderID, name: h.senderName, platform: h.platform, groups: h.groups || [],
        host, port, isDirect: true, quiet: h.quiet || null }, seen: Date.now() });
      this.saveKnownHost(address, h.senderID);
      if (isNew) this.publishMerged();
      return;
    }
  }

  learnDirectPeer(header, host, group) {
    if (!this.identity || header.senderID === this.identity.id || !header.listenPort || !host) return;
    const isNew = !this.direct.has(header.senderID);
    this.lastContact.set(header.senderID, Date.now());
    this.unsilence(header.senderID);
    this.saveSchedule(header.senderID, header.quiet || null);
    this.direct.set(header.senderID, { peer: { id: header.senderID, name: header.senderName, platform: header.platform,
      groups: header.groups || [{ id: group.id, tag: group.tag, name: group.name }], host, port: header.listenPort,
      isDirect: true, quiet: header.quiet || null }, seen: Date.now() });
    this.saveKnownHost(host, header.senderID);
    if (isNew) this.publishMerged();
  }

  silence(id, until, name, host, listenPort) {
    const untilMs = until ? until * 1000 : Date.now() + 12 * 3600 * 1000;
    this.byeAt.set(id, Date.now());
    this.silenced.set(id, untilMs);
    if (host) {
      this.silencedAddresses.set(host, { id, until: untilMs });
      if (listenPort) this.silencedAddresses.set(`${host}:${listenPort}`, { id, until: untilMs });
    }
    this.direct.delete(id);
    this.browsed.delete(id);
    // Reported before the device drops out of the list, so its "out" can say why.
    this.emit('bye', id, until ? until * 1000 : null);
    this.publishMerged();
    this.emit('event', `«${name}» دخل وقت الإيقاف — لن نتصل به حتى يعود`, false);
  }

  unsilence(id) {
    this.byeAt.delete(id);
    this.silenced.delete(id);
    for (const [address, info] of this.silencedAddresses) if (info.id === id) this.silencedAddresses.delete(address);
  }

  isQuiet(id) {
    const until = this.silenced.get(id);
    if (until && until > Date.now()) return true;
    const schedule = (this.store.get('peerSchedules') || {})[id];
    return !!(schedule && P.quietWindow(P.parseScheduleTxt(schedule)));
  }

  saveSchedule(id, quiet) {
    const schedules = this.store.get('peerSchedules') || {};
    const value = quiet ? P.scheduleTxt(quiet) : undefined;
    if (schedules[id] === value) return;
    if (value) schedules[id] = value; else delete schedules[id];
    this.store.set('peerSchedules', schedules);
  }

  saveKnownHost(host, id) {
    if (!host || !id || (isLoopback(host) && !this.extraHosts.length) || isLinkLocal(host)) return;
    const hosts = this.store.get('knownHosts') || {};
    if (hosts[id] === host) return;
    hosts[id] = host;
    const keys = Object.keys(hosts);
    if (keys.length > 20) delete hosts[keys[0]];
    this.store.set('knownHosts', hosts);
  }

  /** A device of one of our groups is listed only while it answers: a minute from when it showed up or
   *  was last heard from. Devices of other groups are only shown as "nearby", so Bonjour is enough. */
  isAlive(peer, now) {
    const me = this.identity;
    if (!me || !peer.groups.some((g) => me.groups.some((x) => x.id === g.id && x.tag === g.tag))) return true;
    return now - Math.max(this.lastContact.get(peer.id) || 0, this.firstSeen.get(peer.id) || 0) < LIVENESS;
  }

  publishMerged() {
    const now = Date.now();
    for (const id of this.browsed.keys()) if (!this.firstSeen.has(id)) this.firstSeen.set(id, now);
    for (const id of [...this.firstSeen.keys()]) if (!this.browsed.has(id)) this.firstSeen.delete(id);
    const merged = new Map();
    for (const [id, { peer }] of this.direct) if (!((this.silenced.get(id) || 0) > now)) merged.set(id, peer);
    for (const [id, peer] of this.browsed) if (this.isAlive(peer, now)) merged.set(id, peer);
    if (this.identity) merged.delete(this.identity.id);
    this.emit('peers', [...merged.values()].sort((a, b) => a.name.localeCompare(b.name)));
  }
}

module.exports = { PeerNetwork, PREFERRED_PORT, LIVENESS, readGateways };
