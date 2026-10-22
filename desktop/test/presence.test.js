'use strict';
// "Device in / out" notifications: the rules (same cases as TestPeer's presencetest on the Swift
// side), the words, the settings, and the network's liveness check that feeds them.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { PresenceWatch, presenceText, LEAVE_GRACE } = require('../src/core/presence');
const { PeerNetwork, LIVENESS } = require('../src/core/network');
const { SyncEngine } = require('../src/core/engine');

const memoryStore = () => { const data = {}; return { get: (k) => data[k], set: (k, v) => { data[k] = v; } }; };
const home = { id: 'G1', name: 'البيت' };
const work = { id: 'G2', name: 'الشغل' };
const A = { id: 'A', name: 'iPhone', groups: [home] };
const B = { id: 'B', name: 'Windows', groups: [home] };

function watcher(store = memoryStore()) {
  const watch = new PresenceWatch(store);
  const events = [];
  watch.onEvent = (e) => events.push(e);
  const take = () => events.splice(0);
  return { watch, take, store };
}

test('presence: the rules', () => {
  const { watch, take, store } = watcher();
  const t0 = 1_000_000;
  const at = (s) => t0 + s * 1000;

  watch.settle(t0);
  watch.update([A], at(1));
  assert.deepStrictEqual(take(), [], 'quiet while connecting');

  watch.update([A, B], at(25));
  assert.deepStrictEqual(take(), [{ kind: 'joined', member: B }], 'new device → joined');

  watch.update([B], at(30));
  watch.tick(at(40));
  watch.update([A, B], at(45));
  watch.tick(at(90));
  assert.deepStrictEqual(take(), [], 'short drop → nothing');

  watch.update([B], at(50));
  watch.tick(at(50) + LEAVE_GRACE - 1000);
  assert.deepStrictEqual(take(), [], "no 'out' before the grace time");
  watch.tick(at(50) + LEAVE_GRACE + 1000);
  assert.deepStrictEqual(take(), [{ kind: 'left', member: A, reason: { type: 'lost' } }], 'gone → out (lost)');

  watch.update([A, B], at(100));
  assert.deepStrictEqual(take(), [{ kind: 'back', member: A }], 'returning device → back');

  const until = at(3600);
  watch.bye('A', until);
  watch.update([B], at(110));
  assert.deepStrictEqual(take(), [{ kind: 'left', member: A, reason: { type: 'quiet', until } }], 'bye (quiet) → out at once');

  watch.update([], at(120));
  watch.bye('B', null);
  watch.tick(at(200));
  assert.deepStrictEqual(take(), [{ kind: 'left', member: B, reason: { type: 'paused' } }], 'drop then bye → one out');

  watch.update([A], at(300));
  take();
  watch.update([], at(310));
  watch.settle(at(311));
  watch.tick(at(400));
  assert.deepStrictEqual(take(), [], 'own reconnect cancels a pending out');

  watch.update([A, B], at(500));
  take();
  watch.reset();
  watch.settle(at(600));
  watch.update([A, B], at(601));
  watch.tick(at(700));
  assert.deepStrictEqual(take(), [], 'own quiet hours → nothing');

  const again = watcher(store);
  again.watch.update([A], at(800));
  assert.deepStrictEqual(again.take(), [{ kind: 'back', member: A }], 'remembered after restart → back');
  again.watch.update([], at(810));
  again.watch.update([{ ...A, groups: [home, work] }], at(815));
  assert.deepStrictEqual(again.take(), [{ kind: 'joined', member: { ...A, groups: [work] } }], 'known device in a new group → joined it');
});

test('presence: the words match the Apple apps', () => {
  const C = { id: 'C', name: 'Linux', groups: [home, work] };
  assert.deepStrictEqual(presenceText({ kind: 'joined', member: C }, false),
    { title: 'جهاز جديد انضم: Linux', body: 'صار بمجموعات «البيت» و«الشغل»' });
  const out = presenceText({ kind: 'left', member: A, reason: { type: 'lost' } }, false);
  assert.strictEqual(out.title, 'iPhone طلع');
  assert.ok(out.body.startsWith('انقطع') && out.body.endsWith('بمجموعة «البيت»'));
  const at1545 = new Date(2026, 0, 1, 15, 45).getTime();
  assert.ok(presenceText({ kind: 'left', member: A, reason: { type: 'quiet', until: at1545 } }, false).body.includes('لحد 3:45 PM'));
  assert.ok(presenceText({ kind: 'left', member: A, reason: { type: 'quiet', until: at1545 } }, true).body.includes('لحد 15:45'));
});

test('presence: settings decide what is shown, all on by default', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'coshare-test-'));
  const engine = new SyncEngine({ dataDir: dir, clipboard: { changeToken: () => 0, read: () => null, write() {} },
    platform: 'linux', defaultName: 'T' });
  const shown = [];
  engine.on('presence', (e) => shown.push(e.kind));
  const s = engine.snapshot().settings;
  assert.ok(s.notifyDevices && s.notifyJoins && s.notifyLeaves);
  const out = { kind: 'left', member: A, reason: { type: 'lost' } };
  const back = { kind: 'back', member: A };
  engine.notifyPresence(out); engine.notifyPresence(back);
  engine.setSetting('notifyLeaves', false);
  engine.notifyPresence(out); engine.notifyPresence(back);
  engine.setSetting('notifyLeaves', true);
  engine.setSetting('notifyJoins', false);
  engine.notifyPresence(out); engine.notifyPresence(back);
  engine.setSetting('notifyDevices', false);
  engine.notifyPresence(out); engine.notifyPresence(back);
  assert.deepStrictEqual(shown, ['left', 'back', 'back', 'left']);
});

test('network: a group device Bonjour still lists but that stopped answering drops out', () => {
  const net = new PeerNetwork({ store: memoryStore() });
  net.identity = { id: 'ME', groups: [{ id: 'G1', tag: 'aaaa1111', name: 'البيت' }] };
  let published = [];
  net.on('peers', (peers) => { published = peers.map((p) => p.id); });
  const mine = { id: 'P1', name: 'iPhone', groups: [{ id: 'G1', tag: 'aaaa1111' }], host: '192.168.0.21', port: 47331 };
  const other = { id: 'P2', name: 'Other', groups: [{ id: 'G9', tag: 'bbbb2222' }], host: '192.168.0.30', port: 47331 };
  net.browsed.set('P1', mine);
  net.browsed.set('P2', other);
  net.publishMerged();
  assert.deepStrictEqual(published.sort(), ['P1', 'P2'], 'just showed up: listed');
  const old = Date.now() - LIVENESS - 1000;
  net.firstSeen.set('P1', old);
  net.firstSeen.set('P2', old);
  net.publishMerged();
  assert.deepStrictEqual(published, ['P2'], 'silent for a minute: only the other group (nearby list) stays');
  net.lastContact.set('P1', Date.now());
  net.publishMerged();
  assert.deepStrictEqual(published.sort(), ['P1', 'P2'], 'answered again: back');
});

test('network: never remembers an fe80:: address without its interface', () => {
  const store = memoryStore();
  const net = new PeerNetwork({ store });
  net.saveKnownHost('fe80::10eb:98e:c749:8a66', 'P1');
  assert.deepStrictEqual(store.get('knownHosts'), undefined);
  net.saveKnownHost('192.168.0.21', 'P1');
  assert.deepStrictEqual(store.get('knownHosts'), { P1: '192.168.0.21' });
});

test('network: right after a bye, the old Bonjour record does not bring the device back', () => {
  const net = new PeerNetwork({ store: memoryStore() });
  net.identity = { id: 'ME', groups: [{ id: 'G1', tag: 'aaaa1111', name: 'البيت' }] };
  let published = [];
  net.on('peers', (peers) => { published = peers.map((p) => p.id); });
  const service = { name: 'P1', port: 47331, addresses: ['192.168.0.21'], txt: { v: '2', i: 'P1', n: 'iPhone', p: 'iphone', g0: 'G1|aaaa1111|البيت' } };
  net.browser = { services: [service] };
  net.syncBrowsed(net.identity);
  assert.deepStrictEqual(published, ['P1']);
  net.silence('P1', null, 'iPhone', '192.168.0.21', 47331);
  net.syncBrowsed(net.identity);
  assert.deepStrictEqual(published, [], 'still advertised a moment after its bye: stays out');
  net.byeAt.set('P1', Date.now() - 11000);
  net.syncBrowsed(net.identity);
  assert.deepStrictEqual(published, ['P1'], 'advertised 10 s later: it is back');
});
