'use strict';
// CoShare for Windows and Linux: tray app + window around the shared sync engine.
const { app, BrowserWindow, Tray, Menu, nativeImage, ipcMain, shell, protocol, net, session } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');
const { pathToFileURL } = require('url');

const isLinux = process.platform === 'linux';
const isWindows = process.platform === 'win32';
const selfTest = process.argv.includes('--self-test');
// --check: the installer's quick version, which leaves the person's clipboard alone.
const quickCheck = process.argv.includes('--check');
const startHidden = process.argv.includes('--hidden');

if (isLinux) {
  // Clipboard change events come from X11 (XWayland on Wayland desktops).
  app.commandLine.appendSwitch('ozone-platform', 'x11');
  // An AppImage can't carry the setuid sandbox helper; the window only ever shows local files.
  if (process.env.APPIMAGE || process.env.COSHARE_NO_SANDBOX) app.commandLine.appendSwitch('no-sandbox');
}

// Own data folder (on a Mac used for development, "CoShare" already belongs to the native app).
if (process.env.COSHARE_DATA) app.setPath('userData', process.env.COSHARE_DATA);
else if (process.platform === 'darwin') app.setPath('userData', path.join(app.getPath('appData'), 'CoShare Desktop'));

protocol.registerSchemesAsPrivileged([{ scheme: 'coshare-blob', privileges: { standard: true, secure: true, supportFetchAPI: true } }]);

const PLATFORM = isWindows ? 'windows' : isLinux ? 'linux' : 'mac';
const ASSETS = path.join(__dirname, '..', 'assets');

let engine = null;
let win = null;
let tray = null;
let quitting = false;

function defaultName() {
  const host = os.hostname().replace(/\.local$/, '');
  return host || (isWindows ? 'Windows PC' : 'Linux PC');
}

// ------------------------------------------------------------------ autostart

function linuxAutostartFile() { return path.join(os.homedir(), '.config', 'autostart', 'coshare.desktop'); }

function applyLaunchAtLogin(enabled) {
  if (isLinux) {
    const file = linuxAutostartFile();
    if (!enabled) { try { fs.unlinkSync(file); } catch {} return; }
    // COSHARE_LAUNCHER: the wrapper install.sh writes for an unpacked AppImage.
    const exe = process.env.COSHARE_LAUNCHER || process.env.APPIMAGE || process.execPath;
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, ['[Desktop Entry]', 'Type=Application', 'Name=CoShare', 'Comment=One clipboard for all your devices',
      `Exec="${exe}" --hidden`, 'Icon=coshare', 'X-GNOME-Autostart-enabled=true', 'Terminal=false', ''].join('\n'));
  } else {
    app.setLoginItemSettings({ openAtLogin: enabled, args: ['--hidden'] });
  }
}

// ------------------------------------------------------------------ window & tray

function createWindow() {
  win = new BrowserWindow({
    width: 440, height: 700, minWidth: 380, minHeight: 520, show: false, title: 'CoShare',
    icon: path.join(ASSETS, 'icon.png'), autoHideMenuBar: true, backgroundColor: '#0b1020',
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, sandbox: true },
  });
  win.setMenuBarVisibility(false);
  win.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'));
  win.once('ready-to-show', () => { if (!startHidden) win.show(); });
  // Development aid: COSHARE_SCREENSHOT=out.png [COSHARE_SCREENSHOT_TAB=groups] saves the window and quits.
  if (process.env.COSHARE_SCREENSHOT) {
    win.webContents.once('did-finish-load', async () => {
      const tab = process.env.COSHARE_SCREENSHOT_TAB;
      if (tab) await win.webContents.executeJavaScript(`document.querySelector('[data-tab="${tab}"]').click()`);
      await new Promise((r) => setTimeout(r, 1500));
      // COSHARE_SCREENSHOT_EVAL: a step to run first, e.g. "go('join')".
      if (process.env.COSHARE_SCREENSHOT_EVAL) await win.webContents.executeJavaScript(process.env.COSHARE_SCREENSHOT_EVAL);
      await new Promise((r) => setTimeout(r, Number(process.env.COSHARE_SCREENSHOT_DELAY || 2500)));
      fs.writeFileSync(process.env.COSHARE_SCREENSHOT, (await win.webContents.capturePage()).toPNG());
      quitting = true;
      app.quit();
    });
  }
  // Closing hides: CoShare keeps working in the background.
  win.on('close', (event) => { if (!quitting) { event.preventDefault(); win.hide(); } });
  win.webContents.setWindowOpenHandler(({ url }) => { shell.openExternal(url); return { action: 'deny' }; });
}

function showWindow() {
  if (!win) return;
  if (win.isMinimized()) win.restore();
  win.show();
  win.focus();
}

function trayIcon() {
  const image = nativeImage.createFromPath(path.join(ASSETS, 'tray.png'));
  return image.resize({ width: isWindows ? 16 : 22, height: isWindows ? 16 : 22 });
}

function updateTrayMenu() {
  if (!tray || !engine) return;
  const online = engine.presence.state === 'online';
  tray.setToolTip(online ? `CoShare — ${engine.connectedPeers().length} متصل` : 'CoShare — متوقف');
  tray.setContextMenu(Menu.buildFromTemplate([
    { label: 'فتح CoShare', click: showWindow },
    { label: 'إرسال الحافظة الآن', enabled: online, click: () => engine.sendCurrentClipboard() },
    { label: online ? 'إيقاف وفصل عن الشبكة' : 'استئناف', click: () => (online ? engine.pause() : engine.resumeToday()) },
    { type: 'separator' },
    { label: 'إنهاء CoShare', click: () => { quitting = true; app.quit(); } },
  ]));
}

// ------------------------------------------------------------------ bridge to the window

function registerIPC() {
  ipcMain.handle('state', () => engine.snapshot());
  ipcMain.handle('invite', async (_e, groupID) => {
    const url = engine.inviteURL(groupID);
    if (!url) return null;
    const group = engine.settings.get('groups').find((g) => g.id === groupID);
    const qr = await require('qrcode').toDataURL(url, { margin: 1, width: 260, errorCorrectionLevel: 'M' });
    return { url, qr, password: group.password };
  });
  ipcMain.handle('action', async (_e, name, ...args) => {
    switch (name) {
      case 'copyItem': return engine.copyItem(args[0]);
      case 'deleteItem': engine.history.remove(args[0]); engine.changed(); return;
      case 'clearHistory': engine.history.clear(); engine.log.clear(); engine.changed(); return;
      case 'createGroup': return engine.createGroup(args[0], args[1]);
      case 'joinGroup': return engine.join(args[0], args[1]);
      case 'joinInvite': return engine.joinInvite(args[0]);
      case 'leaveGroup': return engine.leave(args[0]);
      case 'sendClipboard': return engine.sendCurrentClipboard();
      case 'pause': return engine.pause();
      case 'resume': return engine.resumeToday();
      case 'setSetting':
        engine.setSetting(args[0], args[1]);
        if (args[0] === 'launchAtLogin') applyLaunchAtLogin(!!args[1]);
        return;
      case 'openDataFolder': return shell.openPath(app.getPath('userData'));
      case 'version': return app.getVersion();
      default: throw new Error('unknown action ' + name);
    }
  });
}

// ------------------------------------------------------------------ self-test (used by CI on Windows/Linux)

// Sealed by Tools/TestPeer ("vector k3x9testgroup pass1234"); also in test/protocol.test.js.
const SWIFT_VECTOR_FRAME = 'AAAAxgBh8VPQHzbjeScsMqpqc0n364tsqtZR9XRS5HBOlKPbUZ1MxASl9nChaoZohz88xdxgO2aA9F2mOmotcSVvXFnysypSbOiC8u8lAoXZU1f2foi7u+kLs7WnSGDtG6mBuA0OsreOea+fXwc2Q6e8dWEwZS4uWZDt5cdAaFLBf552jAjxbtb8/6jeXI8xCc3JOaXq0ipelbPS/AH6LY5Mh9ZJDQ0x4crpGrVkedWnO3dmuUuhQUutQ0EDEdPnfgBakT3ZW8c1/Q==';

async function runSelfTest() {
  const checks = {};
  const P = require('../core/protocol');
  try {
    const { key, tag } = await P.deriveGroupKey('k3x9testgroup', 'pass1234');
    checks.crypto = key.toString('hex') === '1b399077355410f50a6236b085713e78249c1d32634a5615cbb8449470a2af74' && tag === 'f42b7b9a';
    // A frame sealed by the Swift apps must open, and our own frames must round-trip.
    const swiftFrame = Buffer.from(SWIFT_VECTOR_FRAME, 'base64');
    const opened = P.decodeFrame(key, swiftFrame.subarray(4));
    const mine = P.decodeFrame(key, P.encodeFrame(key, { type: 'hello' }, Buffer.from('ok')).subarray(4));
    checks.cipher = opened.payload.toString('utf8') === 'مرحبا' && mine.payload.toString() === 'ok';
    checks.cipherEngine = P.cipherEngine;
  } catch (e) { checks.crypto = String(e); }
  try {
    const { SystemClipboard } = require('./clipboard');
    const cb = new SystemClipboard((m) => console.log('clipboard:', m));
    checks.clipboardWatcher = cb.counter.name;
    if (quickCheck) {
      // Reading is enough to know the clipboard is reachable; writing would replace what the person copied.
      cb.read({ includeImages: false, maxImageBytes: 0 });
      cb.changeToken();
      checks.clipboardReadable = true;
    } else {
      const before = cb.changeToken();
      cb.write({ kind: 'text', text: 'CoShare self-test مرحبا' });
      await new Promise((r) => setTimeout(r, 300));
      const read = cb.read({ includeImages: true, maxImageBytes: 1e8 });
      checks.clipboardText = !!read && read.text === 'CoShare self-test مرحبا';
      checks.clipboardChangeDetected = cb.changeToken() !== before;
      const png = fs.readFileSync(path.join(ASSETS, 'tray.png'));
      cb.write({ kind: 'image', data: png, uti: 'public.png' });
      await new Promise((r) => setTimeout(r, 300));
      const img = cb.read({ includeImages: true, maxImageBytes: 1e8 });
      checks.clipboardImage = !!img && img.kind === 'image' && img.data.length > 100;
    }
  } catch (e) { checks.clipboard = String(e && e.stack || e); }
  try {
    const netMod = require('net');
    await new Promise((resolve, reject) => {
      const server = netMod.createServer().listen({ port: 0, host: '::', ipv6Only: false }, () => { server.close(); resolve(); });
      server.on('error', reject);
    });
    checks.tcpListen = true;
  } catch (e) { checks.tcpListen = String(e); }
  try { require('bonjour-service'); require('qrcode'); require('koffi'); checks.modules = true; } catch (e) { checks.modules = String(e); }
  const ok = Object.entries(checks).every(([k, v]) => v === true || (['clipboardWatcher', 'cipherEngine'].includes(k) && typeof v === 'string'));
  const report = JSON.stringify({ ok, platform: PLATFORM, arch: process.arch, electron: process.versions.electron, checks });
  console.log('COSHARE_SELF_TEST ' + report);
  // A Windows GUI process may have no console to print to; CI reads this file instead.
  if (process.env.COSHARE_SELF_TEST_OUT) fs.writeFileSync(process.env.COSHARE_SELF_TEST_OUT, report);
  app.exit(ok ? 0 : 1);
}

// ------------------------------------------------------------------ start

if (!selfTest && !quickCheck && !app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on('second-instance', () => showWindow());
  app.whenReady().then(async () => {
    if (selfTest || quickCheck) return runSelfTest();

    protocol.handle('coshare-blob', (request) => {
      const blobs = path.join(app.getPath('userData'), 'blobs');
      const file = path.join(blobs, path.basename(decodeURIComponent(new URL(request.url).pathname)));
      return net.fetch(pathToFileURL(file).toString());
    });
    // Camera only for scanning group-invite QR codes inside our own window.
    session.defaultSession.setPermissionRequestHandler((_wc, permission, callback) => callback(permission === 'media'));

    const { SyncEngine } = require('../core/engine');
    const { SystemClipboard } = require('./clipboard');
    let log = () => {};
    const clipboard = new SystemClipboard((text, isError) => log(text, isError));
    engine = new SyncEngine({
      dataDir: app.getPath('userData'), clipboard, platform: PLATFORM, defaultName: defaultName(),
      env: {
        port: process.env.COSHARE_PORT ? Number(process.env.COSHARE_PORT) : undefined,
        noBonjour: !!process.env.COSHARE_NO_BONJOUR,
        extraHosts: (process.env.COSHARE_HOSTS || '').split(',').filter(Boolean),
      },
      verbose: !!process.env.COSHARE_VERBOSE,
    });
    log = (text, isError) => engine.log.add(text, isError);
    engine.log.add(`مراقبة الحافظة: ${clipboard.counter.name}`);
    applyLaunchAtLogin(engine.settings.get('launchAtLogin'));
    registerIPC();
    createWindow();
    tray = new Tray(trayIcon());
    tray.on('click', showWindow);
    engine.on('change', () => {
      updateTrayMenu();
      if (win && !win.isDestroyed()) win.webContents.send('state-changed');
    });
    updateTrayMenu();
    engine.start();
  });
  app.on('before-quit', () => { quitting = true; if (engine) engine.stop(); });
  app.on('window-all-closed', (event) => event.preventDefault());
}
