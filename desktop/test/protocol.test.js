'use strict';
// Interop vectors produced by the Swift implementation (Tools/TestPeer "vector k3x9testgroup pass1234").
const test = require('node:test');
const assert = require('node:assert');
const p = require('../src/core/protocol');

const SWIFT = {
  key: '1b399077355410f50a6236b085713e78249c1d32634a5615cbb8449470a2af74',
  tag: 'f42b7b9a',
  frame: 'AAAAxgBh8VPQHzbjeScsMqpqc0n364tsqtZR9XRS5HBOlKPbUZ1MxASl9nChaoZohz88xdxgO2aA9F2mOmotcSVvXFnysypSbOiC8u8lAoXZU1f2foi7u+kLs7WnSGDtG6mBuA0OsreOea+fXwc2Q6e8dWEwZS4uWZDt5cdAaFLBf552jAjxbtb8/6jeXI8xCc3JOaXq0ipelbPS/AH6LY5Mh9ZJDQ0x4crpGrVkedWnO3dmuUuhQUutQ0EDEdPnfgBakT3ZW8c1/Q==',
};

test('derives the same key and tag as Swift', async () => {
  const { key, tag } = await p.deriveGroupKey('k3x9testgroup', 'pass1234');
  assert.strictEqual(key.toString('hex'), SWIFT.key);
  assert.strictEqual(tag, SWIFT.tag);
});

test('opens a frame sealed by Swift', async () => {
  const { key } = await p.deriveGroupKey('k3x9testgroup', 'pass1234');
  const frame = Buffer.from(SWIFT.frame, 'base64');
  assert.strictEqual(frame.readUInt32BE(0), frame.length - 4);
  const { header, payload } = p.decodeFrame(key, frame.subarray(4));
  assert.strictEqual(header.type, 'hello');
  assert.strictEqual(header.senderID, 'VECTOR');
  assert.strictEqual(header.listenPort, 47331);
  assert.deepStrictEqual(header.groups, [{ id: 'k3x9testgroup', tag: SWIFT.tag, name: 'G' }]);
  assert.strictEqual(payload.toString('utf8'), 'مرحبا');
});

test('rejects a frame with the wrong password', async () => {
  const { key } = await p.deriveGroupKey('k3x9testgroup', 'wrong-password');
  assert.throws(() => p.decodeFrame(key, Buffer.from(SWIFT.frame, 'base64').subarray(4)));
});

test('own frames round-trip', async () => {
  const { key } = await p.deriveGroupKey('abc', 'secret12');
  const frame = p.encodeFrame(key, { type: 'clip', senderID: 'X', senderName: 'Y', platform: 'linux' }, Buffer.from('hi'));
  const { header, payload } = p.decodeFrame(key, frame.subarray(4));
  assert.strictEqual(header.platform, 'linux');
  assert.strictEqual(payload.toString(), 'hi');
});

test('content hash matches Swift ClipContent.hash', () => {
  // SHA256("text" + "hello")
  assert.strictEqual(p.contentHash('text', Buffer.from('hello')),
    require('crypto').createHash('sha256').update('texthello').digest('hex'));
});

test('TXT forms match Swift', () => {
  assert.strictEqual(p.groupTxt({ id: 'a1', tag: 'ff00', name: 'x|y' }), 'a1|ff00|x/y');
  assert.deepStrictEqual(p.parseGroupTxt('a1|ff00|Ehab’s devices'), { id: 'a1', tag: 'ff00', name: 'Ehab’s devices' });
  assert.strictEqual(p.scheduleTxt({ days: new Set([6, 2, 4]), start: 540, end: 1020 }), '2,4,6|540|1020');
});

test('quiet windows (incl. overnight) match the Swift rules', () => {
  const s = { days: [2], start: 9 * 60, end: 17 * 60 }; // Monday 9–17
  assert.ok(p.quietWindow(s, new Date(2026, 9, 19, 10, 0)));       // Mon 19 Oct 2026, 10:00
  assert.strictEqual(p.quietWindow(s, new Date(2026, 9, 19, 17, 0)), null);
  assert.strictEqual(p.quietWindow(s, new Date(2026, 9, 20, 10, 0)), null); // Tuesday
  const night = { days: [2], start: 22 * 60, end: 6 * 60 }; // Monday 22:00 → Tuesday 06:00
  assert.ok(p.quietWindow(night, new Date(2026, 9, 20, 3, 0)));    // Tue 03:00 belongs to Monday's window
  assert.strictEqual(p.quietWindow(night, new Date(2026, 9, 20, 23, 0)), null);
});

test('extracts verification codes', () => {
  assert.strictEqual(p.firstCode('Your code is 482 913'), '482913');
  assert.strictEqual(p.firstCode('رمز التحقق ٤٨٢٩١٣'), '482913');
  assert.strictEqual(p.firstCode('no code'), null);
});
