'use strict';
// CoShare wire protocol — byte-compatible with the Swift apps (Shared/WireProtocol.swift, GroupKey.swift).
//
//   frame   = [UInt32 BE sealedLength][ChaCha20-Poly1305(nonce12 | ciphertext | tag16)]
//   sealed  = [UInt32 BE headerLength][header JSON][payload bytes]
//   key     = PBKDF2-HMAC-SHA256(password, "CoShare.v2.group." + groupID, 120 000, 32 bytes)
//   tag     = hex(SHA256(key | "coshare-tag")[0..4])   — public password check value
const crypto = require('crypto');

const MAX_FRAME = 64 * 1024 * 1024;
const PBKDF2_ROUNDS = 120000;

/** Derives a group's key and tag (async: PBKDF2 is deliberately slow). */
function deriveGroupKey(groupID, password) {
  return new Promise((resolve, reject) => {
    crypto.pbkdf2(Buffer.from(password, 'utf8'), Buffer.from('CoShare.v2.group.' + groupID, 'utf8'),
      PBKDF2_ROUNDS, 32, 'sha256', (error, key) => {
        if (error) return reject(error);
        const tag = crypto.createHash('sha256').update(key).update('coshare-tag').digest().subarray(0, 4).toString('hex');
        resolve({ key, tag });
      });
  });
}

// Node has ChaCha20-Poly1305 built in; Electron's BoringSSL build doesn't, so it uses @noble/ciphers (audited, pure JS).
const NATIVE_CHACHA = !process.env.COSHARE_JS_CRYPTO && crypto.getCiphers().includes('chacha20-poly1305');
const noble = NATIVE_CHACHA ? null : require('@noble/ciphers/chacha');

function seal(key, plaintext) {
  const nonce = crypto.randomBytes(12);
  if (!NATIVE_CHACHA) return Buffer.concat([nonce, Buffer.from(noble.chacha20poly1305(key, nonce).encrypt(plaintext))]);
  const cipher = crypto.createCipheriv('chacha20-poly1305', key, nonce, { authTagLength: 16 });
  const body = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  return Buffer.concat([nonce, body, cipher.getAuthTag()]);
}

function open(key, sealed) {
  if (sealed.length < 28) throw new Error('frame too short');
  const nonce = sealed.subarray(0, 12);
  if (!NATIVE_CHACHA) return Buffer.from(noble.chacha20poly1305(key, nonce).decrypt(sealed.subarray(12)));
  const decipher = crypto.createDecipheriv('chacha20-poly1305', key, nonce, { authTagLength: 16 });
  decipher.setAuthTag(sealed.subarray(sealed.length - 16));
  return Buffer.concat([decipher.update(sealed.subarray(12, sealed.length - 16)), decipher.final()]);
}

function uint32(n) {
  const b = Buffer.alloc(4);
  b.writeUInt32BE(n >>> 0);
  return b;
}

/** Encrypted, length-prefixed frame for {header, payload}. */
function encodeFrame(key, header, payload = Buffer.alloc(0)) {
  const headerData = Buffer.from(JSON.stringify(header), 'utf8');
  const sealed = seal(key, Buffer.concat([uint32(headerData.length), headerData, payload]));
  if (sealed.length > MAX_FRAME) throw new Error('frame too large');
  return Buffer.concat([uint32(sealed.length), sealed]);
}

/** Opens a frame body (without its length prefix). Throws if it isn't for this key. */
function decodeFrame(key, sealed) {
  const plain = open(key, sealed);
  const headerLength = plain.readUInt32BE(0);
  if (headerLength <= 0 || plain.length < 4 + headerLength) throw new Error('bad message');
  const header = JSON.parse(plain.subarray(4, 4 + headerLength).toString('utf8'));
  return { header, payload: plain.subarray(4 + headerLength) };
}

/** Same content hash as ClipContent.hash in Swift: SHA256(kind | payload). */
function contentHash(kind, payload) {
  return crypto.createHash('sha256').update(kind, 'utf8').update(payload).digest('hex');
}

const randomID = () => crypto.randomUUID().toUpperCase();

/** 12-character group IDs from the same alphabet as the Swift apps. */
function newGroupID() {
  const alphabet = '0123456789abcdefghjkmnpqrstvwxyz';
  return Array.from(crypto.randomBytes(12), (b) => alphabet[b % alphabet.length]).join('');
}

// Bonjour TXT forms, identical to AdvertisedGroup.txtValue / QuietSchedule.txtValue in Swift.
const groupTxt = (g) => `${g.id}|${g.tag}|${String(g.name).replace(/\|/g, '/').slice(0, 48)}`;
function parseGroupTxt(value) {
  const parts = String(value).split('|');
  if (parts.length < 3 || !parts[0] || !parts[1]) return null;
  return { id: parts[0], tag: parts[1], name: parts.slice(2).join('|') };
}
const scheduleTxt = (q) => `${[...q.days].sort((a, b) => a - b).join(',')}|${q.start}|${q.end}`;
function parseScheduleTxt(value) {
  const parts = String(value).split('|');
  if (parts.length !== 3) return null;
  const start = Number(parts[1]), end = Number(parts[2]);
  if (!Number.isFinite(start) || !Number.isFinite(end)) return null;
  return { days: parts[0].split(',').filter(Boolean).map(Number), start, end };
}

/**
 * The quiet window containing `date`, or null. Days use Swift's Calendar numbering (1 = Sunday … 7 = Saturday);
 * a window whose end is not after its start runs past midnight and belongs to the day it starts on.
 */
function quietWindow(schedule, date = new Date()) {
  if (!schedule || schedule.start === schedule.end) return null;
  const days = new Set(schedule.days);
  for (const offset of [0, -1]) {
    const day = new Date(date.getFullYear(), date.getMonth(), date.getDate() + offset);
    if (!days.has(day.getDay() + 1)) continue;
    const begins = new Date(day.getFullYear(), day.getMonth(), day.getDate(), 0, schedule.start);
    const endMinutes = schedule.end <= schedule.start ? schedule.end + 24 * 60 : schedule.end;
    const ends = new Date(day.getFullYear(), day.getMonth(), day.getDate(), 0, endMinutes);
    if (date >= begins && date < ends) return { start: begins, end: ends };
  }
  return null;
}

/** Pulls a one-time code out of a message: "Your code is 482 913" → "482913" (also Arabic-Indic digits). */
function firstCode(text) {
  const western = String(text).replace(/[٠-٩]/g, (d) => String('٠١٢٣٤٥٦٧٨٩'.indexOf(d)));
  const match = western.match(/(?<!\d)\d{3}[- ]\d{3}(?!\d)/) || western.match(/(?<!\d)\d{4,8}(?!\d)/);
  return match ? match[0].replace(/\D/g, '') : null;
}

module.exports = {
  MAX_FRAME, deriveGroupKey, seal, open, encodeFrame, decodeFrame, contentHash, randomID, newGroupID,
  groupTxt, parseGroupTxt, scheduleTxt, parseScheduleTxt, quietWindow, firstCode, uint32,
  cipherEngine: NATIVE_CHACHA ? 'node' : 'noble',
};
