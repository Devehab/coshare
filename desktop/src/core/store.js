'use strict';
// Settings, the clip history and the activity log, stored as JSON in the app's data folder.
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const MAX_ITEMS = 500;

/** How long history (and copied images) is kept: 1 hour up to a week, a day by default. */
const RETENTION = {
  defaultHours: 24,
  maxHours: 7 * 24,
  options: [1, 12, 24, 72, 168],
  clamp: (hours) => Math.min(Math.max(Math.round(Number(hours)) || 24, 1), 7 * 24),
};

function readJSON(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
}

/** Writes at most twice a second, atomically (temp file + rename). `.flush()` writes now. */
function debouncedWriter(file) {
  let timer = null;
  let pending = null;
  const save = () => {
    clearTimeout(timer);
    timer = null;
    const tmp = file + '.tmp';
    try {
      fs.writeFileSync(tmp, JSON.stringify(pending));
      fs.renameSync(tmp, file);
    } catch { /* disk full or folder gone: try again on the next change */ }
  };
  const write = (value) => {
    pending = value;
    if (!timer) timer = setTimeout(save, 500);
  };
  write.flush = () => { if (timer) save(); };
  return write;
}

class Settings {
  constructor(dir, defaultName) {
    this.file = path.join(dir, 'settings.json');
    this.write = debouncedWriter(this.file);
    const saved = readJSON(this.file, {});
    this.data = {
      deviceID: crypto.randomUUID().toUpperCase(),
      deviceName: defaultName,
      groups: [],
      syncImages: true,
      paused: false,
      launchAtLogin: true,
      quietEnabled: false,
      quietSchedule: { days: [2, 3, 4, 5, 6], start: 9 * 60, end: 17 * 60 },
      resumedWindowStart: null,
      knownHosts: {},
      peerSchedules: {},
      use24Hour: false,
      historyRetentionHours: RETENTION.defaultHours,
      notifyDevices: true,
      notifyJoins: true,
      notifyLeaves: true,
      knownMembers: {},
      ...saved,
    };
    this.data.historyRetentionHours = RETENTION.clamp(this.data.historyRetentionHours);
    if (!saved.deviceID) this.write(this.data);
  }
  get(key) { return this.data[key]; }
  set(key, value) { this.data[key] = value; this.write(this.data); }
}

class History {
  constructor(dir, retentionHours = RETENTION.defaultHours) {
    this.dir = dir;
    this.retentionHours = RETENTION.clamp(retentionHours);
    this.blobs = path.join(dir, 'blobs');
    fs.mkdirSync(this.blobs, { recursive: true });
    this.file = path.join(dir, 'history.json');
    this.write = debouncedWriter(this.file);
    this.items = readJSON(this.file, []);
    this.purge();
    this.removeOrphans();
  }

  add({ kind, text, data, uti, hash, deviceName, direction, date }) {
    const existing = this.items.findIndex((i) => i.hash === hash);
    if (existing >= 0) this.removeBlob(this.items.splice(existing, 1)[0]);
    const id = crypto.randomUUID().toUpperCase();
    const item = { id, kind, hash, deviceName, direction, date, byteCount: kind === 'text' ? Buffer.byteLength(text) : data.length,
      text: kind === 'text' ? text : undefined, uti, deliveredTo: null };
    if (kind === 'image') {
      item.blobName = `${id}.${uti === 'public.jpeg' ? 'jpg' : 'png'}`;
      fs.writeFileSync(path.join(this.blobs, item.blobName), data);
    }
    this.items.unshift(item);
    while (this.items.length > MAX_ITEMS) this.removeBlob(this.items.pop());
    this.write(this.items);
    return item;
  }

  setDelivered(id, count) {
    const item = this.items.find((i) => i.id === id);
    if (item) { item.deliveredTo = count; this.write(this.items); }
  }

  content(item) {
    if (item.kind === 'text') return { kind: 'text', text: item.text };
    try { return { kind: 'image', data: fs.readFileSync(this.blobPath(item)), uti: item.uti || 'public.png' }; } catch { return null; }
  }

  blobPath(item) { return item.blobName ? path.join(this.blobs, item.blobName) : null; }

  remove(id) {
    const index = this.items.findIndex((i) => i.id === id);
    if (index >= 0) { this.removeBlob(this.items.splice(index, 1)[0]); this.write(this.items); }
  }

  clear() { this.items.forEach((i) => this.removeBlob(i)); this.items = []; this.write(this.items); }

  setRetention(hours) { this.retentionHours = RETENTION.clamp(hours); return this.purge(); }

  /** Drops everything older than the retention period, image files included. Returns true if anything went. */
  purge() {
    const cutoff = Date.now() / 1000 - this.retentionHours * 3600;
    const keep = this.items.filter((i) => i.date >= cutoff);
    if (keep.length === this.items.length) return false;
    this.items.filter((i) => i.date < cutoff).forEach((i) => this.removeBlob(i));
    this.items = keep;
    this.write(this.items);
    this.removeOrphans();
    return true;
  }

  blobFiles() { try { return fs.readdirSync(this.blobs); } catch { return []; } }

  removeBlob(item) {
    if (item && item.blobName) { try { fs.unlinkSync(path.join(this.blobs, item.blobName)); } catch {} }
  }

  removeOrphans() {
    const referenced = new Set(this.items.map((i) => i.blobName).filter(Boolean));
    for (const file of fs.readdirSync(this.blobs)) if (!referenced.has(file)) { try { fs.unlinkSync(path.join(this.blobs, file)); } catch {} }
  }
}

class ActivityLog {
  constructor(dir, verbose = false, retentionHours = RETENTION.defaultHours) {
    this.retentionHours = RETENTION.clamp(retentionHours);
    this.file = path.join(dir, 'activity.json');
    this.write = debouncedWriter(this.file);
    this.entries = readJSON(this.file, []);
    this.verbose = verbose;
    this.listeners = new Set();
    this.purge();
  }
  add(text, isError = false) {
    this.entries.unshift({ id: crypto.randomUUID(), date: Date.now() / 1000, text, isError });
    if (this.entries.length > 1000) this.entries.length = 1000;
    if (this.verbose) console.log(`[CoShare] ${isError ? '⚠️ ' : ''}${text}`);
    this.write(this.entries);
    this.listeners.forEach((fn) => fn());
  }
  setRetention(hours) { this.retentionHours = RETENTION.clamp(hours); this.purge(); }
  purge() {
    const cutoff = Date.now() / 1000 - this.retentionHours * 3600;
    const before = this.entries.length;
    this.entries = this.entries.filter((e) => e.date >= cutoff);
    if (this.entries.length !== before) this.write(this.entries);
  }
  clear() { this.entries = []; this.write(this.entries); this.listeners.forEach((fn) => fn()); }
}

module.exports = { Settings, History, ActivityLog, RETENTION };
