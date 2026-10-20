'use strict';
// History retention (clips and their image files), settings and group flows on the Node engine.
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { Settings, History, RETENTION } = require('../src/core/store');
const { SyncEngine } = require('../src/core/engine');

const tempDir = () => fs.mkdtempSync(path.join(os.tmpdir(), 'coshare-test-'));
const PNG = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(2000, 7)]);
const hoursAgo = (h) => Date.now() / 1000 - h * 3600;

function fill(history) {
  history.add({ kind: 'text', text: 'now', hash: 'a', deviceName: 'T', direction: 'received', date: hoursAgo(0) });
  history.add({ kind: 'text', text: 'two hours', hash: 'b', deviceName: 'T', direction: 'received', date: hoursAgo(2) });
  history.add({ kind: 'image', data: PNG, uti: 'public.png', hash: 'c', deviceName: 'T', direction: 'received', date: hoursAgo(2.5) });
  history.add({ kind: 'image', data: PNG, uti: 'public.png', hash: 'd', deviceName: 'T', direction: 'received', date: hoursAgo(50) });
}

test('a week keeps everything, also after a restart', () => {
  const dir = tempDir();
  const history = new History(dir, 168);
  fill(history);
  history.purge();
  assert.strictEqual(history.items.length, 4);
  assert.strictEqual(history.blobFiles().length, 2);
  history.write.flush();
  const reopened = new History(dir, 168);
  assert.strictEqual(reopened.items.length, 4, 'the retention applies before the first purge');
});

test('one day drops older clips and their image files', () => {
  const history = new History(tempDir(), 168);
  fill(history);
  history.setRetention(24);
  assert.deepStrictEqual(history.items.map((i) => i.hash).sort(), ['a', 'b', 'c']);
  assert.strictEqual(history.blobFiles().length, 1);
});

test('one hour keeps only the newest and no image files', () => {
  const history = new History(tempDir(), 168);
  fill(history);
  history.setRetention(1);
  assert.deepStrictEqual(history.items.map((i) => i.text), ['now']);
  assert.strictEqual(history.blobFiles().length, 0);
});

test('stray image files are removed', () => {
  const dir = tempDir();
  const history = new History(dir, 24);
  fs.writeFileSync(path.join(dir, 'blobs', 'orphan.png'), PNG);
  history.add({ kind: 'text', text: 'x', hash: 'x', deviceName: 'T', direction: 'sent', date: hoursAgo(30) });
  history.purge();
  assert.strictEqual(history.blobFiles().length, 0);
});

test('settings: one day and 12-hour clock by default, capped at a week, saved', () => {
  const dir = tempDir();
  const settings = new Settings(dir, 'PC');
  assert.strictEqual(settings.get('historyRetentionHours'), 24);
  assert.strictEqual(settings.get('use24Hour'), false);
  assert.strictEqual(RETENTION.clamp(1000), 168);
  assert.strictEqual(RETENTION.clamp(0), 24);
  settings.set('historyRetentionHours', 72);
  settings.write.flush();
  assert.strictEqual(new Settings(dir, 'PC').get('historyRetentionHours'), 72);
});

test('engine applies the retention setting right away', () => {
  const clipboard = { changeToken: () => 0, read: () => null, write: () => {} };
  const engine = new SyncEngine({ dataDir: tempDir(), clipboard, platform: 'linux', defaultName: 'PC', env: { noBonjour: true } });
  engine.setSetting('historyRetentionHours', 168);
  fill(engine.history);
  engine.setSetting('historyRetentionHours', 24);
  assert.strictEqual(engine.history.items.length, 3);
  engine.setSetting('historyRetentionHours', 99999);
  assert.strictEqual(engine.snapshot().settings.historyRetentionHours, 168);
  engine.setSetting('use24Hour', true);
  assert.strictEqual(engine.snapshot().settings.use24Hour, true);
});

test('create and invite return the group so the window can open it', () => {
  const clipboard = { changeToken: () => 0, read: () => null, write: () => {} };
  const engine = new SyncEngine({ dataDir: tempDir(), clipboard, platform: 'windows', defaultName: 'PC', env: { noBonjour: true } });
  engine.restartNetwork = () => {};
  const created = engine.createGroup('أجهزتي', 'secret12');
  assert.ok(created.id && created.name === 'أجهزتي');
  const invite = engine.inviteURL(created.id);
  engine.leave(created.id);
  const joined = engine.joinInvite(invite);
  assert.deepStrictEqual(joined, { id: created.id, name: 'أجهزتي' });
  assert.throws(() => engine.createGroup('x', '123'), /6/);
});
