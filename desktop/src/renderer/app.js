'use strict';
// Window logic: draws the state the main process sends and forwards clicks as actions.
const api = window.coshare;
const $ = (id) => document.getElementById(id);
const DAYS = [[1, 'أحد'], [2, 'إثنين'], [3, 'ثلاثاء'], [4, 'أربعاء'], [5, 'خميس'], [6, 'جمعة'], [7, 'سبت']];
const relative = new Intl.RelativeTimeFormat('ar', { numeric: 'auto', style: 'short' });
const PLATFORMS = {
  mac: ['💻', 'ماك'], iphone: ['📱', 'آيفون'], ipad: ['📱', 'آيباد'], windows: ['🖥️', 'ويندوز'], linux: ['🐧', 'لينكس'], android: ['📱', 'أندرويد'],
};
const RETENTION_LABELS = { 1: 'ساعة واحدة', 12: '١٢ ساعة', 24: 'يوم واحد', 72: '٣ أيام', 168: 'أسبوع' };
let state = null;

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
/** "3:45 PM" (default) or "15:45", per the time-format setting. */
function clock(ms, withSeconds = false) {
  const h24 = state && state.settings.use24Hour;
  const text = new Date(ms).toLocaleTimeString('en-US', {
    hour: 'numeric', minute: '2-digit', second: withSeconds ? '2-digit' : undefined, hourCycle: h24 ? 'h23' : 'h12',
  });
  return `<span class="ltr">${text}</span>`;
}
const plain = (html) => html.replace(/<[^>]+>/g, '');
const errorText = (e) => String(e.message || e).replace(/^Error invoking remote method 'action': Error: /, '');

function ago(seconds) {
  const diff = Date.now() / 1000 - seconds;
  if (diff < 10) return 'الآن';
  if (diff < 3600) return relative.format(-Math.round(diff / 60), 'minute');
  return relative.format(-Math.round(diff / 3600), 'hour');
}

function bytes(n) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${Math.round(n / 1024)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}

// ---------------------------------------------------------------- tabs

document.querySelectorAll('.tabs button').forEach((button) => {
  button.addEventListener('click', () => {
    document.querySelectorAll('.tabs button').forEach((b) => b.classList.toggle('active', b === button));
    document.querySelectorAll('.pane').forEach((p) => p.classList.toggle('active', p.id === `tab-${button.dataset.tab}`));
    if (button.dataset.tab !== 'groups' && route.name === 'join') go('home');
  });
});

// ---------------------------------------------------------------- rendering

async function refresh() {
  state = await api.state();
  renderHeader();
  renderHistory();
  renderGroups();
  renderLog();
  renderSettings();
}

function renderHeader() {
  const p = state.presence;
  const n = state.connected.length;
  let text, color;
  if (p.state === 'paused') { text = 'متوقف — منفصل عن الشبكة'; color = 'var(--indigo)'; }
  else if (p.state === 'quiet') { text = `وقت الإيقاف حتى ${plain(clock(p.until))}`; color = 'var(--indigo)'; }
  else if (!n) { text = 'بانتظار أجهزة على نفس الشبكة…'; color = 'var(--orange)'; }
  else { text = `متصل بـ ${n} ${n === 1 ? 'جهاز' : 'أجهزة'}`; color = 'var(--green)'; }
  if (state.pulse === 'sent') text = '↑ ' + text;
  if (state.pulse === 'received') text = '↓ ' + text;
  $('statusText').textContent = text;
  $('statusDot').style.background = color;
  $('pauseBtn').textContent = p.state === 'online' ? '⏸' : '▶';
  $('pauseBtn').title = p.state === 'online' ? 'إيقاف وفصل CoShare عن الشبكة' : 'استئناف';
  $('banner').hidden = p.state === 'online';
  $('bannerText').textContent = p.state === 'quiet'
    ? `🌙 وقت الإيقاف حتى ${plain(clock(p.until))} — منفصل تماماً عن الشبكة`
    : '⏸ متوقف — CoShare منفصل تماماً عن الشبكة';
  $('bannerBtn').textContent = p.state === 'quiet' ? 'استئناف اليوم' : 'استئناف';
}

function renderHistory() {
  const items = state.history;
  const keep = RETENTION_LABELS[state.settings.historyRetentionHours] || `${state.settings.historyRetentionHours} ساعة`;
  $('retentionNote').textContent = `يُحفظ آخر ${keep} فقط، والأقدم يُحذف تلقائياً مع صوره`;
  $('historyEmpty').hidden = items.length > 0;
  $('historyList').innerHTML = items.map((i) => {
    const thumb = i.kind === 'image' && i.blobName
      ? `<img class="thumb" src="coshare-blob://blob/${encodeURIComponent(i.blobName)}" alt="">`
      : `<span class="thumb">¶</span>`;
    const title = i.kind === 'image' ? `صورة · ${bytes(i.byteCount)}` : esc((i.text || '').trim() || '(مسافات فارغة)');
    const source = i.direction === 'sent'
      ? (i.deliveredTo == null ? 'من هذا الجهاز' : i.deliveredTo > 0 ? `من هذا الجهاز ← ${i.deliveredTo} أجهزة` : 'من هذا الجهاز (لم يصل لأحد)')
      : `من ${esc(i.deviceName)}`;
    return `<li class="item" data-id="${i.id}">${thumb}<div class="body"><div class="text">${title}</div>
      <div class="meta">${i.direction === 'sent' ? '↗' : '↙'} ${source} · ${clock(i.date * 1000)} · ${ago(i.date)}</div></div>
      <button class="del" data-del="${i.id}" title="حذف">✕</button></li>`;
  }).join('');
}

$('historyList').addEventListener('click', async (event) => {
  const del = event.target.closest('[data-del]');
  if (del) { event.stopPropagation(); return api.action('deleteItem', del.dataset.del); }
  const item = event.target.closest('.item');
  if (!item) return;
  await api.action('copyItem', item.dataset.id);
  item.classList.add('copied');
  setTimeout(() => item.classList.remove('copied'), 1200);
});

// ---------------------------------------------------------------- groups

// Screens inside the Groups tab: home (create / join + my groups), create, join, and one group.
let route = { name: 'home' };
let joinMethod = 'nearby';
let expandedNearby = null;
let confirmLeave = false;
let inviteShown = false;
const inviteCache = {};

function go(name, extra = {}) {
  if (route.name === 'join' && name !== 'join') stopScanner();
  route = { name, ...extra };
  confirmLeave = false;
  inviteShown = !!extra.showInvite;
  if (name === 'join') { joinMethod = 'nearby'; expandedNearby = null; }
  document.querySelectorAll('#tab-groups .route').forEach((el) => { el.hidden = el.id !== `route-${name}`; });
  document.querySelector('main').scrollTop = 0;
  if (name === 'create') { $('createError').hidden = true; setTimeout(() => $('groupName').focus(), 50); }
  renderGroups();
}

$('tab-groups').addEventListener('click', (event) => {
  const target = event.target.closest('[data-go]');
  if (target) go(target.dataset.go);
});

function groupStatus(group) {
  const p = state.presence.state;
  if (p === 'paused') return ['متوقفة — CoShare موقوف على هالجهاز', 'indigo'];
  if (p === 'quiet') return ['متوقفة — وقت الإيقاف', 'indigo'];
  const n = group.members.length;
  if (!n) return ['فعّالة · بانتظار أجهزة', 'orange'];
  return [`فعّالة · ${n === 1 ? 'جهاز متصل' : `${n} أجهزة متصلة`}`, 'green'];
}

// Colours are classes: the page's CSP doesn't allow inline style attributes.
const statusHTML = (group) => { const [text, color] = groupStatus(group); return `<span class="dot ${color}"></span> ${text}`; };

function renderGroups() {
  const groups = state.groups;
  // Home
  $('onboarding').hidden = groups.length > 0;
  $('myGroupsBox').hidden = groups.length === 0;
  $('myGroupsTitle').textContent = `مجموعاتي (${groups.length})`;
  $('nearbyHint').hidden = !(groups.length === 0 && state.nearby.length > 0);
  $('nearbyHint').textContent = `في ${state.nearby.length} مجموعة ظاهرة على هالشبكة — اضغط «انضمام لمجموعة».`;
  $('myGroups').innerHTML = groups.map((g) => `
    <button class="row-item" data-open="${esc(g.id)}">
      <span class="group-badge"></span>
      <span class="body"><strong>${esc(g.name)}</strong><span class="meta">${statusHTML(g)}</span></span>
      <span class="chev">‹</span>
    </button>`).join('');

  if (route.name === 'join') renderJoin();
  if (route.name === 'group') renderGroupDetail();
}

$('myGroups').addEventListener('click', (event) => {
  const row = event.target.closest('[data-open]');
  if (row) go('group', { id: row.dataset.open });
});

// ---- join: nearby groups (with password) or QR

function renderJoin() {
  document.querySelectorAll('[data-method]').forEach((b) => b.classList.toggle('selected', b.dataset.method === joinMethod));
  $('joinNearby').hidden = joinMethod !== 'nearby';
  $('scanner').hidden = joinMethod !== 'scan';
  if (joinMethod !== 'nearby') return;
  // Keep a half-typed password while the list refreshes.
  const typing = document.querySelector('#nearby input');
  const typed = typing ? typing.value : '';
  const hadFocus = typing && document.activeElement === typing;
  const error = document.querySelector('#nearby .error:not([hidden])');
  const errorMessage = error ? error.textContent : '';
  $('nearbyEmpty').hidden = state.nearby.length > 0;
  $('nearbyBox').hidden = state.nearby.length === 0;
  $('nearby').innerHTML = state.nearby.map((n) => `
    <div class="nearby-row" data-key="${esc(n.key)}">
      <div class="row-item">
        <span class="group-badge"></span>
        <span class="body"><strong>${esc(n.group.name)}</strong><span class="meta">فيها: ${n.memberNames.map(esc).join('، ')}</span></span>
        ${expandedNearby === n.key ? '' : `<button class="primary small" data-expand="${esc(n.key)}">انضمام</button>`}
      </div>
      ${expandedNearby === n.key ? `
        <form class="join-form" data-key="${esc(n.key)}">
          <input type="password" placeholder="كلمة سر المجموعة" value="${esc(typed)}">
          <button class="primary" type="submit">تأكيد</button>
          <button type="button" data-collapse>إلغاء</button>
        </form>
        <p class="error" ${errorMessage ? '' : 'hidden'}>${esc(errorMessage)}</p>` : ''}
    </div>`).join('');
  if (hadFocus || (expandedNearby && !typed)) {
    const input = document.querySelector('#nearby input');
    if (input) input.focus();
  }
}

$('route-join').addEventListener('click', (event) => {
  const method = event.target.closest('[data-method]');
  if (method) {
    joinMethod = method.dataset.method;
    if (joinMethod === 'scan') startScanner(); else stopScanner();
    return renderJoin();
  }
  const expand = event.target.closest('[data-expand]');
  if (expand) { expandedNearby = expand.dataset.expand; return renderJoin(); }
  if (event.target.closest('[data-collapse]')) { expandedNearby = null; return renderJoin(); }
});

$('nearby').addEventListener('submit', async (event) => {
  event.preventDefault();
  const form = event.target;
  const input = form.querySelector('input');
  const error = form.parentElement.querySelector('.error');
  error.hidden = true;
  if (!input.value) return;
  try {
    const joined = await api.action('joinGroup', form.dataset.key, input.value);
    go('group', { id: joined.id });
  } catch (e) {
    error.textContent = errorText(e);
    error.hidden = false;
  }
});

// ---- create

$('createForm').addEventListener('submit', async (event) => {
  event.preventDefault();
  $('createError').hidden = true;
  try {
    const created = await api.action('createGroup', $('groupName').value, $('groupPassword').value);
    $('groupName').value = '';
    $('groupPassword').value = '';
    go('group', { id: created.id, showInvite: true });
  } catch (e) {
    $('createError').textContent = errorText(e);
    $('createError').hidden = false;
  }
});

// ---- one group: its devices, a QR code to add another device, leaving

function renderGroupDetail() {
  const group = state.groups.find((g) => g.id === route.id);
  if (!group) return go('home');
  $('detailName').textContent = group.name;
  $('detailStatus').innerHTML = statusHTML(group);
  $('detailDevicesTitle').textContent = `الأجهزة المتصلة (${group.members.length + 1})`;
  const [icon] = PLATFORMS[state.platform] || ['•'];
  const online = state.presence.state === 'online';
  $('detailDevices').innerHTML = `
    <li class="row-item"><span class="dev-icon">${icon}</span>
      <span class="body"><strong>${esc(state.deviceName)}</strong><span class="meta">هذا الجهاز</span></span>
      <span class="dot ${online ? 'green' : 'indigo'}"></span></li>` +
    group.members.map((p) => {
      const [pIcon, pName] = PLATFORMS[p.platform] || ['•', 'جهاز'];
      return `<li class="row-item"><span class="dev-icon">${pIcon}</span>
        <span class="body"><strong>${esc(p.name)}</strong><span class="meta">${pName} · ${p.isDirect ? 'اتصال مباشر' : 'على نفس الشبكة'}</span></span>
        <span class="dot green"></span></li>`;
    }).join('');
  $('detailNoDevices').hidden = group.members.length > 0;
  renderInvite(group);
  $('leaveBox').innerHTML = confirmLeave
    ? `<p>بعد المغادرة ما رح يوصلك نسخ أجهزة «${esc(group.name)}»، ولا رح يوصلها نسخك.</p>
       <div class="pair"><button class="danger-solid" data-leave-confirm>مغادرة المجموعة</button><button data-leave-cancel>إلغاء</button></div>`
    : `<button class="danger-outline" data-leave>مغادرة المجموعة</button>`;
}

async function renderInvite(group) {
  const box = $('inviteBox');
  if (!inviteShown) {
    box.innerHTML = `<button class="primary wide" data-invite-show>▦ إظهار رمز QR لإضافة جهاز</button>
      <p class="hint">الجهاز الجديد بيمسح الرمز وبينضم فوراً، بدون ما تكتب كلمة السر.</p>`;
    return;
  }
  if (box.dataset.group === group.id && box.querySelector('img')) return; // already showing
  const invite = inviteCache[group.id] || (inviteCache[group.id] = await api.invite(group.id));
  if (!invite || !inviteShown || route.id !== group.id) return;
  box.dataset.group = group.id;
  box.innerHTML = `<img src="${invite.qr}" alt="QR">
    <p class="hint">على الجهاز الجديد: افتح CoShare ← «انضمام لمجموعة» ← «مسح رمز QR» ووجّه الكاميرا على هالرمز. أو امسحه بكاميرا الآيفون مباشرة.</p>
    <div>كلمة السر: <span class="secret" id="invitePassword">••••••••</span> <button class="small" data-reveal>إظهار</button></div>
    <button class="small" data-invite-hide>إخفاء الرمز</button>`;
  box.dataset.password = invite.password;
}

$('route-group').addEventListener('click', async (event) => {
  const group = state.groups.find((g) => g.id === route.id);
  if (!group) return;
  if (event.target.closest('[data-invite-show]')) { inviteShown = true; return renderInvite(group); }
  if (event.target.closest('[data-invite-hide]')) { inviteShown = false; $('inviteBox').dataset.group = ''; return renderInvite(group); }
  const reveal = event.target.closest('[data-reveal]');
  if (reveal) {
    const span = $('invitePassword');
    const shown = span.textContent !== '••••••••';
    span.textContent = shown ? '••••••••' : $('inviteBox').dataset.password;
    reveal.textContent = shown ? 'إظهار' : 'إخفاء';
    return;
  }
  if (event.target.closest('[data-leave]')) { confirmLeave = true; return renderGroupDetail(); }
  if (event.target.closest('[data-leave-cancel]')) { confirmLeave = false; return renderGroupDetail(); }
  if (event.target.closest('[data-leave-confirm]')) {
    delete inviteCache[group.id];
    await api.action('leaveGroup', group.id);
    go('home');
  }
});

// ---- QR scanning with the camera

let stream = null;
let scanTimer = null;

async function startScanner() {
  if (stream) return;
  $('scanMsg').textContent = 'وجّه الكاميرا على رمز الدعوة: من جهاز بالمجموعة افتح المجموعة واضغط «إظهار رمز QR لإضافة جهاز».';
  try {
    stream = await navigator.mediaDevices.getUserMedia({ video: { width: 1280, height: 720 } });
    if (route.name !== 'join' || joinMethod !== 'scan') return stopScanner();
    $('video').srcObject = stream;
    await $('video').play();
    scanTimer = setInterval(scanFrame, 250);
  } catch {
    stream = null;
    $('scanMsg').textContent = 'ما في كاميرا متاحة، أو ما في إذن لاستخدامها.';
  }
}

function stopScanner() {
  clearInterval(scanTimer);
  scanTimer = null;
  if (stream) stream.getTracks().forEach((t) => t.stop());
  stream = null;
}

async function scanFrame() {
  const video = $('video');
  if (!video.videoWidth || typeof jsQR !== 'function') return;
  const canvas = $('canvas');
  canvas.width = video.videoWidth;
  canvas.height = video.videoHeight;
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  ctx.drawImage(video, 0, 0);
  const frame = ctx.getImageData(0, 0, canvas.width, canvas.height);
  const code = jsQR(frame.data, frame.width, frame.height, { inversionAttempts: 'dontInvert' });
  if (!code) return;
  clearInterval(scanTimer);
  try {
    const joined = await api.action('joinInvite', code.data);
    $('scanMsg').textContent = `✓ انضممت لمجموعة «${joined.name}»`;
    stopScanner();
    setTimeout(() => go('group', { id: joined.id }), 1200);
  } catch {
    $('scanMsg').textContent = 'هاد الرمز مش دعوة CoShare.';
    setTimeout(() => { if (stream) scanTimer = setInterval(scanFrame, 250); }, 1500);
  }
}

// ---------------------------------------------------------------- log & settings

function renderLog() {
  $('logList').innerHTML = state.log.map((e) => `<li class="${e.isError ? 'err' : ''}">
    <time>${clock(e.date * 1000, true)}</time><span>${esc(e.text)}</span></li>`).join('');
}

function renderSettings() {
  const s = state.settings;
  if (document.activeElement !== $('deviceName')) $('deviceName').value = state.deviceName;
  $('syncImages').checked = s.syncImages;
  $('launchAtLogin').checked = s.launchAtLogin;
  $('quietEnabled').checked = s.quietEnabled;
  $('quietBox').hidden = !s.quietEnabled;
  $('retention').value = String(s.historyRetentionHours);
  $('timeFormat').value = s.use24Hour ? '24' : '12';
  const days = new Set(s.quietSchedule.days);
  $('days').innerHTML = DAYS.map(([n, name]) => `<button data-day="${n}" class="${days.has(n) ? 'on' : ''}">${name}</button>`).join('');
  const hhmm = (m) => `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;
  if (document.activeElement !== $('quietStart')) $('quietStart').value = hhmm(s.quietSchedule.start);
  if (document.activeElement !== $('quietEnd')) $('quietEnd').value = hhmm(s.quietSchedule.end);
}

const setting = (key, value) => api.action('setSetting', key, value);
$('deviceName').addEventListener('change', (e) => setting('deviceName', e.target.value.trim()));
$('syncImages').addEventListener('change', (e) => setting('syncImages', e.target.checked));
$('launchAtLogin').addEventListener('change', (e) => setting('launchAtLogin', e.target.checked));
$('quietEnabled').addEventListener('change', (e) => setting('quietEnabled', e.target.checked));
$('retention').addEventListener('change', (e) => setting('historyRetentionHours', Number(e.target.value)));
$('timeFormat').addEventListener('change', (e) => setting('use24Hour', e.target.value === '24'));
$('days').addEventListener('click', (e) => {
  const button = e.target.closest('[data-day]');
  if (!button) return;
  const days = new Set(state.settings.quietSchedule.days);
  const n = Number(button.dataset.day);
  days.has(n) ? days.delete(n) : days.add(n);
  setting('quietSchedule', { ...state.settings.quietSchedule, days: [...days].sort() });
});
const minutes = (value) => { const [h, m] = value.split(':').map(Number); return h * 60 + m; };
$('quietStart').addEventListener('change', (e) => setting('quietSchedule', { ...state.settings.quietSchedule, start: minutes(e.target.value) }));
$('quietEnd').addEventListener('change', (e) => setting('quietSchedule', { ...state.settings.quietSchedule, end: minutes(e.target.value) }));
$('clearBtn').addEventListener('click', () => api.action('clearHistory'));
$('folderBtn').addEventListener('click', () => api.action('openDataFolder'));
$('sendBtn').addEventListener('click', () => api.action('sendClipboard'));
$('pauseBtn').addEventListener('click', () => api.action(state.presence.state === 'online' ? 'pause' : 'resume'));
$('bannerBtn').addEventListener('click', () => api.action('resume'));

api.onChange(refresh);
api.action('version').then((v) => { $('version').textContent = `· الإصدار ${v}`; });
refresh();
setInterval(() => state && renderHistory(), 60000); // keep "x minutes ago" fresh
