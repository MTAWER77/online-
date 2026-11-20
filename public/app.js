(() => {
'use strict';

const $ = (s) => document.querySelector(s);
const R = window.NovaRender;
const G = window.NovaGodot;

const el = {
  sidebar: $('#sidebar'), scrim: $('#scrim'), list: $('#chatList'), msgs: $('#messages'),
  input: $('#input'), form: $('#composer'), send: $('#sendBtn'), title: $('#title'),
  toast: $('#toast'), install: $('#installBtn'), menu: $('#menuBtn'), newChat: $('#newChat'),
  settings: $('#settings'), settingsBtn: $('#settingsBtn'),
  attachBtn: $('#attachBtn'), attachMenu: $('#attachMenu'),
  fileInput: $('#fileInput'), imageInput: $('#imageInput'), zipInput: $('#zipInput'), folderInput: $('#folderInput'),
  attachmentTray: $('#attachmentTray'), modeBar: $('#modeBar'),
  thinkToggle: $('#thinkToggle'), searchToggle: $('#searchToggle'), codeFixToggle: $('#codeFixToggle'),
};

const KEY = 'nova_ai_chats_v1';
const ACTIVE_KEY = 'nova_ai_active_v1';
const SET_KEY = 'nova_ai_settings_v1';
const DRAFT_KEY = 'nova_ai_drafts_v1';
const MODEL_STATE_KEY = 'nova_ai_model_state_v1';
const SEARCH_KEY = 'nova_ai_search_enabled_v1';
const THINK_KEY = 'nova_ai_think_enabled_v1';
const CODE_FIX_KEY = 'nova_ai_code_fix_enabled_v1';

const MAX_CONTEXT = 14;          // messages sent per request
const MAX_REQUEST_CHARS = 58000; // must stay under the Worker's MAX_CHARS (70000)
const FRESH_USER_TURNS = 2;      // file contents are re-sent only for the last N user turns
const MAX_FILES = 5;
const MAX_FILE_SIZE = 1024 * 1024;
const MAX_FILE_CHARS = 20000;
const MAX_IMAGES = 3;
const MAX_IMAGE_EDGE = 1280;
const MAX_IMAGE_QUALITY = 0.82;
const MAX_GENERATED_FILES = 20;
const MAX_ACTIVE_RUNS = 2;
const CHAT_PROJECT_BUDGET = 22000;
const FIX_PROJECT_BUDGET = 28000;
const IDLE_ABORT_MS = 45000;     // no bytes at all (the Worker sends a heartbeat every 8s)
const HARD_LIMIT_MS = 6 * 60 * 1000;
const FILES_TIMEOUT_MS = 150000;
const MAX_ATTEMPTS = 3;

const SUPPORTED_EXTENSIONS = [
  'gd', 'tscn', 'tres', 'gdshader', 'shader',
  'json', 'txt', 'md', 'csv', 'xml',
  'html', 'css', 'js', 'py', 'ini', 'cfg', 'log', 'godot', 'zip'
];

let pendingFiles = [];
// Image data is deliberately kept only in memory, never in chat storage/export.
const imageDataStore = new Map();

const readFlag = (k) => { try { return localStorage.getItem(k) === '1'; } catch { return false; } };
const writeFlag = (k, v) => { try { localStorage.setItem(k, v ? '1' : '0'); } catch { /* ignore */ } };
const modes = { think: readFlag(THINK_KEY), search: readFlag(SEARCH_KEY), fix: readFlag(CODE_FIX_KEY) };
const MODE_META = {
  think: { btn: el.thinkToggle, key: THINK_KEY, on: 'Think مفعّل: تفكير أعمق قبل الرد.', off: 'تم إيقاف Think.' },
  search: { btn: el.searchToggle, key: SEARCH_KEY, on: 'Search مفعّل: بحث على الويب مع مصادر.', off: 'تم إيقاف Search.' },
  fix: { btn: el.codeFixToggle, key: CODE_FIX_KEY, on: 'AI Fix مفعّل: ارفع الكود أو مشروع Godot واكتب المشكلة.', off: 'تم إيقاف AI Fix.' },
};

function renderModes() {
  for (const [name, meta] of Object.entries(MODE_META)) {
    if (!meta.btn) continue;
    meta.btn.classList.toggle('active', modes[name]);
    meta.btn.setAttribute('aria-pressed', String(modes[name]));
  }
  const parts = [];
  if (modes.think) parts.push('Think');
  if (modes.search) parts.push('Search');
  if (modes.fix) parts.push('AI Fix');
  el.modeBar?.setAttribute('data-active', parts.join('+'));
  if (el.input) el.input.placeholder = modes.fix ? 'صف المشكلة في الكود…' : 'اكتب رسالتك…';
}

function toggleMode(name) {
  modes[name] = !modes[name];
  // Think and Search are independent and work together. AI Fix uses the file endpoint (no web search).
  let note = modes[name] ? MODE_META[name].on : MODE_META[name].off;
  if (name === 'fix' && modes.fix && modes.search) { modes.search = false; note = 'AI Fix مفعّل (البحث أُوقف لأنه غير مستخدم مع الإصلاح).'; }
  if (name === 'search' && modes.search && modes.fix) { modes.fix = false; note = 'Search مفعّل (AI Fix أُوقف).'; }
  if (name !== 'fix' && modes.think && modes.search) note = 'Think + Search يعملان معًا.';
  for (const [n, meta] of Object.entries(MODE_META)) writeFlag(meta.key, modes[n]);
  renderModes();
  toast(note);
}
for (const [name, meta] of Object.entries(MODE_META)) meta.btn?.addEventListener('click', () => toggleMode(name));

const svg = (d, s = 16) =>
  `<svg viewBox="0 0 24 24" width="${s}" height="${s}" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${d}</svg>`;

const IC = {
  pen: '<path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4Z"/>',
  trash: '<path d="M3 6h18"/><path d="M8 6V4h8v2"/><path d="M19 6l-1 14H6L5 6"/>',
  copy: '<rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15V5a2 2 0 0 1 2-2h10"/>',
  check: '<path d="M20 6 9 17l-5-5"/>',
  refresh: '<path d="M21 12a9 9 0 1 1-3-6.7"/><path d="M21 4v5h-5"/>',
  file: '<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/>',
  close: '<path d="m18 6-12 12M6 6l12 12"/>',
  download: '<path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="m7 10 5 5 5-5"/><path d="M12 15V3"/>',
  archive: '<path d="M21 8v13H3V8"/><path d="M1 3h22v5H1z"/><path d="M10 12h4"/>',
  folder: '<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>',
  play: '<path d="m6 4 14 8-14 8z"/>',
  info: '<circle cx="12" cy="12" r="9"/><path d="M12 8h.01M11 12h1v5h1"/>',
};

const COPY_HTML = svg(IC.copy, 14) + '<span>نسخ</span>';

const SUGGESTIONS = [
  { h: 'أصلح الكود', s: 'ارفع سكربت GDScript واكتب المشكلة', q: 'ازاي أصلح خطأ "Invalid get index" في GDScript؟' },
  { h: 'Godot', s: 'اشرح الفرق بين signals و groups', q: 'اشرح لي الفرق بين الـ signals والـ groups في Godot 4 بمثال بسيط' },
  { h: 'Write code', s: 'Player movement for a 2D platformer', q: 'Write a Godot 4 GDScript for 2D platformer player movement with coyote time.' },
  { h: 'قارن', s: 'REST مقابل GraphQL في جدول مختصر', q: 'قارن بين REST و GraphQL في جدول مختصر' },
];

const FS = { s: '14.5px', m: '16px', l: '18px' };

/* ---------- storage ---------- */

function readStore(k) { try { return localStorage.getItem(k); } catch { return null; } }
const uid = () => Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function readChats() {
  try {
    const v = JSON.parse(readStore(KEY));
    const list = Array.isArray(v) ? v.filter((c) => c && c.id && Array.isArray(c.messages)) : [];
    for (const c of list) { c.lastError = null; for (const m of c.messages) if (!m.id) m.id = uid(); }
    return list;
  } catch { return []; }
}
function readSettings() {
  try { return Object.assign({ fs: 'm' }, JSON.parse(readStore(SET_KEY)) || {}); }
  catch { return { fs: 'm' }; }
}
function readDrafts() {
  try { const v = JSON.parse(readStore(DRAFT_KEY)); return v && typeof v === 'object' ? v : {}; }
  catch { return {}; }
}

let chats = readChats();
let activeId = readStore(ACTIVE_KEY) || null;
let settings = readSettings();
let drafts = readDrafts();
let deferredPrompt = null, toastTimer = null, saveTimer = 0, storageWarned = false;

// Every in-flight request is tracked per chat. A reply can only touch the chat/message it was started for.
const runs = new Map(); // chatId -> run
const isStale = (run) => runs.get(run.chatId) !== run;
const isBusy = (chat) => !!chat && runs.has(chat.id);

const current = () => chats.find((c) => c.id === activeId) || null;
const chatById = (id) => chats.find((c) => c.id === id) || null;

// Keeps storage small: old attachment contents are the first thing dropped when the quota is hit.
function compactStorage(aggressive) {
  const keepRecent = aggressive ? 2 : 8;
  for (const c of chats) {
    const userIdx = c.messages.map((m, i) => (m.role === 'user' ? i : -1)).filter((i) => i >= 0);
    const old = new Set(userIdx.slice(0, Math.max(0, userIdx.length - keepRecent)));
    c.messages.forEach((m, i) => {
      if (old.has(i) && Array.isArray(m.attachments)) m.attachments.forEach((a) => { if (a.content) { a.content = ''; a.trimmed = true; } });
      if (aggressive && m.files && !userIdx.slice(-2).some((u) => u >= i - 1)) m.files.forEach((f) => { if (f.content && f.content.length > 4000) { f.content = f.content.slice(0, 4000); f.trimmed = true; } });
    });
  }
}

function persist() {
  const write = () => {
    localStorage.setItem(KEY, JSON.stringify(chats));
    localStorage.setItem(ACTIVE_KEY, activeId || '');
  };
  try { write(); return; } catch { /* quota or disabled */ }
  try { compactStorage(false); write(); return; } catch { /* still too big */ }
  try { compactStorage(true); write(); if (!storageWarned) { storageWarned = true; toast('المساحة المحلية ضيقة: تم تقليل محتوى المرفقات القديمة.'); } return; } catch { /* give up */ }
  if (!storageWarned) { storageWarned = true; toast('تعذر حفظ المحادثات محليًا (التخزين ممتلئ أو معطّل). صدّر المحادثات من الإعدادات.'); }
}
// Debounced: streaming never writes per token; commits write once shortly after.
function save(now) {
  if (now) { clearTimeout(saveTimer); saveTimer = 0; persist(); return; }
  if (!saveTimer) saveTimer = setTimeout(() => { saveTimer = 0; persist(); }, 300);
}
function flushSave() { if (saveTimer) { clearTimeout(saveTimer); saveTimer = 0; } persist(); saveDraftsNow(); }
window.addEventListener('pagehide', flushSave);
document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'hidden') flushSave(); });

function saveSettings() { try { localStorage.setItem(SET_KEY, JSON.stringify(settings)); } catch { /* ignore */ } }
let draftTimer = 0;
function saveDraftsNow() { clearTimeout(draftTimer); draftTimer = 0; try { localStorage.setItem(DRAFT_KEY, JSON.stringify(drafts)); } catch { /* ignore */ } }
function setDraft(chatId, text) {
  const key = chatId || '_new';
  if (text) drafts[key] = text; else delete drafts[key];
  clearTimeout(draftTimer); draftTimer = setTimeout(saveDraftsNow, 400);
}

function toast(msg) {
  if (!el.toast) return;
  el.toast.textContent = msg;
  el.toast.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.toast.hidden = true; }, 3200);
}

function mk(tag, cls, html) {
  const d = document.createElement(tag);
  if (cls) d.className = cls;
  if (html != null) d.innerHTML = html;
  return d;
}

/* ---------- Godot projects (kept in memory + IndexedDB; only metadata lives in the chat) ---------- */

const idb = (() => {
  let dbp = null;
  const open = () => {
    if (!('indexedDB' in window)) return Promise.reject(new Error('no idb'));
    return dbp || (dbp = new Promise((res, rej) => {
      const r = indexedDB.open('nova-ai', 1);
      r.onupgradeneeded = () => r.result.createObjectStore('projects');
      r.onsuccess = () => res(r.result);
      r.onerror = () => rej(r.error);
    }));
  };
  const run = async (mode, fn) => {
    const db = await open();
    return new Promise((res, rej) => {
      const t = db.transaction('projects', mode);
      const req = fn(t.objectStore('projects'));
      t.oncomplete = () => res(req && req.result);
      t.onerror = () => rej(t.error);
      t.onabort = () => rej(t.error);
    });
  };
  return {
    get: (k) => run('readonly', (s) => s.get(k)),
    put: (k, v) => run('readwrite', (s) => s.put(v, k)),
    del: (k) => run('readwrite', (s) => s.delete(k)),
  };
})();

const projects = new Map(); // chatId -> analysed project
const projectLoading = new Set();

async function loadProjectFor(chat) {
  if (!chat || !chat.project || projects.has(chat.id) || projectLoading.has(chat.id)) return;
  projectLoading.add(chat.id);
  try {
    const data = await idb.get('p:' + chat.id);
    if (data) { projects.set(chat.id, G.deserialize(data)); if (chat.id === activeId) renderAttachments(); }
    else { chat.project = null; save(); if (chat.id === activeId) renderAttachments(); }
  } catch { /* storage unavailable: the project simply has to be uploaded again */ }
  projectLoading.delete(chat.id);
}
function storeProject(chat, project) {
  projects.set(chat.id, project);
  chat.project = { name: project.name, files: project.files.size, findings: project.findings.length, updated: Date.now() };
  idb.put('p:' + chat.id, G.serialize(project)).catch(() => toast('تعذر حفظ المشروع في المتصفح؛ سيبقى متاحًا حتى إغلاق الصفحة فقط.'));
  save();
}
function dropProject(chat) {
  projects.delete(chat.id);
  chat.project = null;
  idb.del('p:' + chat.id).catch(() => {});
  save();
}


/* ---------- file helpers ---------- */

function safeFileName(name) {
  return String(name || 'generated-file.txt')
    .replace(/\\/g, '/')
    .split('/')
    .filter((part) => part && part !== '.' && part !== '..')
    .join('/')
    .replace(/[<>:"|?*\u0000-\u001f]/g, '_')
    .slice(0, 180) || 'generated-file.txt';
}

function downloadBlob(blob, name) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = safeFileName(name).split('/').pop();
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 30000);
}

function downloadOneFile(file) {
  const name = safeFileName(file.name);
  const blob = new Blob([file.content], {
    type: 'text/plain;charset=utf-8'
  });
  downloadBlob(blob, name);
}

function crc32(bytes) {
  let crc = -1;
  for (let i = 0; i < bytes.length; i++) {
    crc = (crc >>> 8) ^ CRC_TABLE[(crc ^ bytes[i]) & 0xff];
  }
  return (crc ^ -1) >>> 0;
}

const CRC_TABLE = (() => {
  const table = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) {
      c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
    }
    table[n] = c >>> 0;
  }
  return table;
})();

function makeZip(files) {
  const encoder = new TextEncoder();
  const localParts = [];
  const centralParts = [];
  let offset = 0;

  const put16 = (view, pos, value) => view.setUint16(pos, value, true);
  const put32 = (view, pos, value) => view.setUint32(pos, value >>> 0, true);

  const now = new Date();
  const dosTime = (now.getHours() << 11) | (now.getMinutes() << 5) | Math.floor(now.getSeconds() / 2);
  const dosDate = ((Math.max(1980, now.getFullYear()) - 1980) << 9) |
    ((now.getMonth() + 1) << 5) | now.getDate();

  for (const file of files) {
    const nameBytes = encoder.encode(safeFileName(file.name));
    const data = encoder.encode(String(file.content ?? ''));
    const crc = crc32(data);

    const local = new Uint8Array(30 + nameBytes.length);
    const lv = new DataView(local.buffer);
    put32(lv, 0, 0x04034b50);
    put16(lv, 4, 20);
    put16(lv, 6, 0x0800);
    put16(lv, 8, 0);
    put16(lv, 10, dosTime);
    put16(lv, 12, dosDate);
    put32(lv, 14, crc);
    put32(lv, 18, data.length);
    put32(lv, 22, data.length);
    put16(lv, 26, nameBytes.length);
    put16(lv, 28, 0);
    local.set(nameBytes, 30);
    localParts.push(local, data);

    const central = new Uint8Array(46 + nameBytes.length);
    const cv = new DataView(central.buffer);
    put32(cv, 0, 0x02014b50);
    put16(cv, 4, 20);
    put16(cv, 6, 20);
    put16(cv, 8, 0x0800);
    put16(cv, 10, 0);
    put16(cv, 12, dosTime);
    put16(cv, 14, dosDate);
    put32(cv, 16, crc);
    put32(cv, 20, data.length);
    put32(cv, 24, data.length);
    put16(cv, 28, nameBytes.length);
    put16(cv, 30, 0);
    put16(cv, 32, 0);
    put16(cv, 34, 0);
    put16(cv, 36, 0);
    put32(cv, 38, 0);
    put32(cv, 42, offset);
    central.set(nameBytes, 46);
    centralParts.push(central);

    offset += local.length + data.length;
  }

  const centralSize = centralParts.reduce((sum, part) => sum + part.length, 0);
  const end = new Uint8Array(22);
  const ev = new DataView(end.buffer);
  put32(ev, 0, 0x06054b50);
  put16(ev, 4, 0);
  put16(ev, 6, 0);
  put16(ev, 8, files.length);
  put16(ev, 10, files.length);
  put32(ev, 12, centralSize);
  put32(ev, 16, offset);
  put16(ev, 20, 0);

  return new Blob([...localParts, ...centralParts, end], {
    type: 'application/zip'
  });
}

function downloadZip(files, name) {
  if (!Array.isArray(files) || !files.length) return;
  downloadBlob(makeZip(files), name || 'nova-generated-project.zip');
}

function splitCodeLines(value) {
  return String(value ?? '').replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n');
}

// Line diff with a bounded LCS matrix; very large files safely fall back to one reviewable hunk.
function buildCodeDiff(original, revised) {
  const a = splitCodeLines(original);
  const b = splitCodeLines(revised);
  const n = a.length, m = b.length;
  if (n === m && a.every((line, i) => line === b[i])) return { originalLines: a, hunks: [] };

  const limit = 1800000;
  let ops = [];
  if ((n + 1) * (m + 1) > limit) {
    return { originalLines: a, hunks: [{ oldStart: 0, oldLines: a.slice(), newLines: b.slice() }] };
  }

  const width = m + 1;
  const dp = new Uint32Array((n + 1) * width);
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      dp[i * width + j] = a[i] === b[j]
        ? dp[(i + 1) * width + j + 1] + 1
        : Math.max(dp[(i + 1) * width + j], dp[i * width + j + 1]);
    }
  }

  let i = 0, j = 0;
  while (i < n || j < m) {
    if (i < n && j < m && a[i] === b[j]) {
      ops.push({ type: 'equal', line: a[i] }); i++; j++;
    } else if (j < m && (i >= n || dp[i * width + j + 1] >= dp[(i + 1) * width + j])) {
      ops.push({ type: 'add', line: b[j] }); j++;
    } else {
      ops.push({ type: 'del', line: a[i] }); i++;
    }
  }

  const hunks = [];
  let oldCursor = 0;
  for (let k = 0; k < ops.length;) {
    if (ops[k].type === 'equal') { oldCursor++; k++; continue; }
    const hunk = { oldStart: oldCursor, oldLines: [], newLines: [] };
    while (k < ops.length && ops[k].type !== 'equal') {
      if (ops[k].type === 'del') { hunk.oldLines.push(ops[k].line); oldCursor++; }
      else hunk.newLines.push(ops[k].line);
      k++;
    }
    hunks.push(hunk);
  }
  return { originalLines: a, hunks };
}

function getReviewedContent(original, revised, hunks, accepted) {
  const originalLines = splitCodeLines(original);
  const out = [];
  let cursor = 0;
  hunks.forEach((hunk, index) => {
    out.push(...originalLines.slice(cursor, hunk.oldStart));
    out.push(...((accepted[index] !== false) ? hunk.newLines : hunk.oldLines));
    cursor = hunk.oldStart + hunk.oldLines.length;
  });
  out.push(...originalLines.slice(cursor));
  return out.join('\n');
}

function findOriginalFile(sourceFiles, generatedName) {
  const target = safeFileName(generatedName).toLowerCase();
  const base = target.split('/').pop();
  const candidates = (sourceFiles || []).filter(f => f && f.kind === 'text' && typeof f.content === 'string');
  return candidates.find(f => safeFileName(f.name).toLowerCase() === target)
    || candidates.find(f => safeFileName(f.name).split('/').pop().toLowerCase() === base)
    || null;
}

function renderDiffReview(file, sourceFiles) {
  const originalFile = findOriginalFile(sourceFiles, file.name);
  const original = originalFile ? originalFile.content : '';
  const revised = String(file.content || '');
  const diff = buildCodeDiff(original, revised);
  const accepted = Array.isArray(file.acceptedHunks)
    ? diff.hunks.map((_, i) => file.acceptedHunks[i] !== false)
    : diff.hunks.map(() => true);
  file.acceptedHunks = accepted;

  const panel = mk('section', 'diff-review');
  const top = mk('div', 'diff-review-top');
  const summary = mk('div', 'diff-summary');
  summary.textContent = originalFile
    ? (diff.hunks.length ? `${diff.hunks.length} مجموعة تغييرات · الأصل محفوظ` : 'لا توجد تغييرات بين الملفين')
    : 'ملف جديد · كل الأسطر إضافات';
  const actions = mk('div', 'diff-toolbar');
  const acceptAll = mk('button', 'diff-tool accept-all', 'اعتماد الكل');
  const rejectAll = mk('button', 'diff-tool', 'رفض الكل');
  acceptAll.type = rejectAll.type = 'button';
  actions.append(acceptAll, rejectAll);
  top.append(summary, actions);
  panel.append(top);

  if (!diff.hunks.length) {
    const unchanged = mk('div', 'diff-empty', 'النسخة المقترحة مطابقة للأصل. يمكنك تنزيلها كما هي.');
    panel.append(unchanged);
  } else {
    diff.hunks.forEach((hunk, index) => {
      const card = mk('article', 'diff-hunk');
      const head = mk('div', 'diff-hunk-head');
      const label = mk('strong', '', `التغيير ${index + 1}`);
      const state = mk('span', 'diff-hunk-state');
      const controls = mk('div', 'diff-hunk-controls');
      const accept = mk('button', 'diff-tool accept-one', 'قبول');
      const reject = mk('button', 'diff-tool reject-one', 'رفض');
      accept.type = reject.type = 'button';
      controls.append(accept, reject);
      head.append(label, state, controls);

      const columns = mk('div', 'diff-columns');
      const oldSide = mk('div', 'diff-side removed');
      const newSide = mk('div', 'diff-side added');
      const oldTitle = mk('div', 'diff-side-title', 'الأصل');
      const newTitle = mk('div', 'diff-side-title', 'المقترح');
      const oldCode = mk('pre', 'diff-code');
      const newCode = mk('pre', 'diff-code');
      oldCode.textContent = hunk.oldLines.length ? hunk.oldLines.join('\n') : '— لا توجد أسطر محذوفة —';
      newCode.textContent = hunk.newLines.length ? hunk.newLines.join('\n') : '— لا توجد أسطر مضافة —';
      oldSide.append(oldTitle, oldCode);
      newSide.append(newTitle, newCode);
      columns.append(oldSide, newSide);
      card.append(head, columns);

      const update = () => {
        const on = file.acceptedHunks[index] !== false;
        state.textContent = on ? 'مقبول في النسخة النهائية' : 'مرفوض · الأصل سيبقى';
        state.classList.toggle('is-accepted', on);
        state.classList.toggle('is-rejected', !on);
        accept.classList.toggle('selected', on);
        reject.classList.toggle('selected', !on);
      };
      accept.addEventListener('click', () => { file.acceptedHunks[index] = true; update(); refreshPreview(); save(); });
      reject.addEventListener('click', () => { file.acceptedHunks[index] = false; update(); refreshPreview(); save(); });
      update();
      panel.append(card);
    });
  }

  const previewWrap = mk('div', 'diff-final-wrap');
  const previewHead = mk('div', 'diff-final-head');
  const previewTitle = mk('strong', '', 'معاينة النسخة النهائية');
  const previewToggle = mk('button', 'diff-tool', 'عرض المعاينة');
  previewToggle.type = 'button';
  previewHead.append(previewTitle, previewToggle);
  const preview = mk('pre', 'diff-final-preview');
  preview.hidden = true;
  const footer = mk('div', 'diff-final-actions');
  const downloadFinal = mk('button', 'diff-download', svg(IC.download, 15) + '<span>تحميل النسخة المعتمدة</span>');
  downloadFinal.type = 'button';
  footer.append(downloadFinal);
  const finalText = () => getReviewedContent(original, revised, diff.hunks, file.acceptedHunks);
  Object.defineProperty(file, '_final', { value: finalText, enumerable: false, configurable: true });
  const refreshPreview = () => { preview.textContent = finalText(); };
  previewToggle.addEventListener('click', () => {
    preview.hidden = !preview.hidden;
    previewToggle.textContent = preview.hidden ? 'عرض المعاينة' : 'إخفاء المعاينة';
    if (!preview.hidden) refreshPreview();
  });
  downloadFinal.addEventListener('click', () => {
    downloadOneFile({ name: file.name, content: finalText() });
    toast('تم تجهيز النسخة التي اعتمدتها.');
  });
  acceptAll.addEventListener('click', () => {
    file.acceptedHunks = diff.hunks.map(() => true);
    panel.querySelectorAll('.diff-hunk').forEach((card, i) => {
      const buttons = card.querySelectorAll('.diff-tool');
      buttons[0]?.classList.add('selected'); buttons[1]?.classList.remove('selected');
      const state = card.querySelector('.diff-hunk-state');
      if (state) { state.textContent = 'مقبول في النسخة النهائية'; state.classList.add('is-accepted'); state.classList.remove('is-rejected'); }
    });
    refreshPreview(); save();
  });
  rejectAll.addEventListener('click', () => {
    file.acceptedHunks = diff.hunks.map(() => false);
    panel.querySelectorAll('.diff-hunk').forEach(card => {
      const buttons = card.querySelectorAll('.diff-tool');
      buttons[0]?.classList.remove('selected'); buttons[1]?.classList.add('selected');
      const state = card.querySelector('.diff-hunk-state');
      if (state) { state.textContent = 'مرفوض · الأصل سيبقى'; state.classList.remove('is-accepted'); state.classList.add('is-rejected'); }
    });
    refreshPreview(); save();
  });
  panel.append(previewWrap, footer);
  previewWrap.append(previewHead, preview);
  refreshPreview();
  return panel;
}

function renderGeneratedFiles(files, sourceFiles = []) {
  if (!Array.isArray(files) || !files.length) return null;

  const wrap = mk('section', 'generated-files');
  const heading = mk('div', 'generated-files-head');
  heading.append(
    mk('strong', '', 'الملفات الجاهزة'),
    mk('span', 'generated-files-count', String(files.length) + ' ملف')
  );
  wrap.append(heading);

  files.slice(0, MAX_GENERATED_FILES).forEach((file) => {
    const item = mk('div', 'generated-file generated-file-reviewable');
    const info = mk('div', 'generated-file-info');
    const name = mk('strong', 'generated-file-name');
    name.textContent = safeFileName(file.name);
    const size = mk('span', 'generated-file-size');
    size.textContent = formatSize(new Blob([String(file.content || '')]).size);
    info.append(name, size);

    const controls = mk('div', 'generated-file-actions');
    const button = mk('button', 'generated-download', svg(IC.download, 14) + '<span>تحميل الناتج</span>');
    button.type = 'button';
    button.addEventListener('click', () => downloadOneFile(file));
    const review = mk('button', 'generated-review', '<span>مراجعة التغييرات</span>');
    review.type = 'button';
    controls.append(button, review);
    item.append(info, controls);

    const existing = findOriginalFile(sourceFiles, file.name);
    const panel = renderDiffReview(file, sourceFiles);
    panel.hidden = true;
    review.addEventListener('click', () => {
      panel.hidden = !panel.hidden;
      review.textContent = panel.hidden ? 'مراجعة التغييرات' : 'إخفاء المراجعة';
      if (!panel.hidden) panel.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
    });
    item.append(panel);
    wrap.append(item);
  });

  const zip = mk('button', 'generated-zip', svg(IC.archive, 15) + '<span>تحميل ZIP' + (files.length > 1 ? ' (كل الملفات)' : '') + '</span>');
  zip.type = 'button';
  zip.addEventListener('click', () => downloadZip(files.map((f) => ({ name: f.name, content: f._final ? f._final() : f.content })), 'nova-generated-files.zip'));
  wrap.append(zip);

  // AI Fix on an uploaded project/archive: the whole project with the accepted changes applied.
  if (sourceFiles.length > 1 && files.some((f) => findOriginalFile(sourceFiles, f.name))) {
    const full = mk('button', 'generated-zip alt', svg(IC.archive, 15) + '<span>تحميل المشروع المعدّل ZIP</span>');
    full.type = 'button';
    full.addEventListener('click', () => {
      const out = new Map(sourceFiles.map((s) => [safeFileName(s.name), { name: safeFileName(s.name), content: s.content }]));
      for (const f of files) {
        const o = findOriginalFile(sourceFiles, f.name);
        const key = o ? safeFileName(o.name) : safeFileName(f.name);
        out.set(key, { name: key, content: f._final ? f._final() : f.content });
      }
      downloadZip([...out.values()], 'nova-project-fixed.zip');
      toast('الملفات الثنائية (صور/صوت/نماذج) غير مضمّنة في الـ ZIP؛ انسخ الملفات المعدّلة فوق مشروعك الأصلي.');
    });
    wrap.append(full);
  }

  return wrap;
}


/* ---------- attachments ---------- */

function formatSize(bytes) {
  if (bytes < 1024) return bytes + ' B';
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + ' KB';
  return (bytes / (1024 * 1024)).toFixed(1) + ' MB';
}

function getExtension(name) {
  return name.split('.').pop().toLowerCase();
}

function renderProjectChip(chat) {
  const project = projects.get(chat.id);
  const meta = chat.project;
  const box = mk('div', 'project-chip');
  const top = mk('div', 'project-chip-top');
  const icon = mk('span', 'attachment-icon', svg(IC.folder, 18));
  const info = mk('div', 'attachment-info');
  const name = mk('span', 'attachment-name');
  name.textContent = (project ? project.name : meta.name) || 'Godot project';
  const sub = mk('span', 'attachment-size');
  const warn = project ? project.findings.length : meta.findings || 0;
  sub.textContent = project
    ? `${project.files.size} ملف مقروء · ${warn} ملاحظة ثابتة${project.skipped.length ? ' · ' + project.skipped.length + ' لم يُقرأ' : ''}`
    : 'جارٍ تحميل المشروع…';
  info.append(name, sub);
  const details = mk('button', 'attachment-remove info', svg(IC.info, 14));
  details.type = 'button';
  details.setAttribute('aria-label', 'تفاصيل المشروع');
  const remove = mk('button', 'attachment-remove', svg(IC.close, 14));
  remove.type = 'button';
  remove.setAttribute('aria-label', 'إزالة المشروع');
  remove.onclick = () => { dropProject(chat); renderAttachments(); toast('تمت إزالة سياق المشروع من هذه المحادثة.'); };
  top.append(icon, info, details, remove);
  box.append(top);

  if (project) {
    const panel = mk('div', 'project-details');
    panel.hidden = true;
    const add = (title, lines) => {
      if (!lines.length) return;
      panel.append(mk('strong', '', title));
      const ul = mk('ul');
      lines.forEach((t) => { const li = mk('li'); li.textContent = t; ul.append(li); });
      panel.append(ul);
    };
    add('ملاحظات ثابتة (قراءة فقط، لم تُختبر داخل Godot)', project.findings.slice(0, 12).map((f) => `${f.sev === 'error' ? '⛔' : '⚠'} ${f.file}${f.line ? ':' + f.line : ''} — ${f.msg}`));
    add('ملفات لم تُقرأ', project.skipped.slice(0, 12).map((s) => `${s.path}: ${s.reason}`));
    if (project.assetCount) panel.append(mk('p', '', `${project.assetCount} ملف أصول (صور/صوت/نماذج) لا تُرسل للنموذج.`));
    panel.append(mk('p', 'muted', 'يُرسل للنموذج الملفات المرتبطة بسؤالك فقط. لتحديث السياق ارفع المشروع أو الملفات المعدّلة مرة أخرى.'));
    box.append(panel);
    details.onclick = () => { panel.hidden = !panel.hidden; };
  } else details.hidden = true;
  return box;
}

function renderAttachments() {
  if (!el.attachmentTray) return;
  el.attachmentTray.innerHTML = '';
  const chat = current();
  const hasProject = !!(chat && chat.project);
  el.attachmentTray.hidden = pendingFiles.length === 0 && !hasProject;
  if (hasProject) el.attachmentTray.append(renderProjectChip(chat));

  pendingFiles.forEach((file, index) => {
    const item = mk('div', 'attachment-item');
    if (file.kind === 'image' && file.id && imageDataStore.has(file.id)) {
      const thumb = mk('img', 'attachment-thumb');
      thumb.src = imageDataStore.get(file.id);
      thumb.alt = file.name;
      item.append(thumb);
    } else {
      item.append(mk('span', 'attachment-icon', svg(IC.file, 18)));
    }
    const info = mk('div', 'attachment-info');
    const name = mk('span', 'attachment-name');
    name.textContent = file.name;
    const size = mk('span', 'attachment-size');
    size.textContent = formatSize(file.size);
    info.append(name, size);

    const remove = mk('button', 'attachment-remove', svg(IC.close, 14));
    remove.type = 'button';
    remove.setAttribute('aria-label', 'إزالة الملف');
    remove.onclick = () => {
      const removed = pendingFiles.splice(index, 1)[0];
      if (removed?.id) imageDataStore.delete(removed.id);
      renderAttachments();
    };
    item.append(info, remove);
    el.attachmentTray.append(item);
  });
}

function closeAttachMenu() { if (el.attachMenu) el.attachMenu.hidden = true; }
function toggleAttachMenu() { if (el.attachMenu) el.attachMenu.hidden = !el.attachMenu.hidden; }

function imageToDataUrl(file) {
  return new Promise((resolve, reject) => {
    if (typeof createImageBitmap !== 'function') {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result);
      reader.onerror = reject;
      reader.readAsDataURL(file);
      return;
    }
    createImageBitmap(file).then((bitmap) => {
      const scale = Math.min(1, MAX_IMAGE_EDGE / Math.max(bitmap.width, bitmap.height));
      const canvas = document.createElement('canvas');
      canvas.width = Math.max(1, Math.round(bitmap.width * scale));
      canvas.height = Math.max(1, Math.round(bitmap.height * scale));
      canvas.getContext('2d').drawImage(bitmap, 0, 0, canvas.width, canvas.height);
      bitmap.close?.();
      resolve(canvas.toDataURL('image/jpeg', MAX_IMAGE_QUALITY));
    }).catch(reject);
  });
}

async function handleFiles(fileList, kind) {
  const files = Array.from(fileList || []);
  const textUpdates = [];
  for (const file of files) {
    if (pendingFiles.length >= MAX_FILES) { toast('يمكنك رفع 5 مرفقات كحد أقصى.'); break; }
    const isImage = file.type.startsWith('image/');
    if (kind === 'image' && !isImage) { toast('اختر صورة صالحة.'); continue; }
    if (kind === 'file' && isImage) { toast('ارفع الصور من خيار رفع الصور.'); continue; }
    if (isImage) {
      if (!['image/jpeg', 'image/png', 'image/webp', 'image/gif'].includes(file.type)) { toast('الصيغ المدعومة: JPG وPNG وWEBP وGIF.'); continue; }
      if (pendingFiles.filter((x) => x.kind === 'image').length >= MAX_IMAGES) { toast('يمكنك رفع 3 صور كحد أقصى في الرسالة.'); break; }
      if (file.size > 8 * 1024 * 1024) { toast('حجم الصورة الأصلي يجب ألا يتجاوز 8MB.'); continue; }
      try {
        const id = 'img_' + uid();
        imageDataStore.set(id, await imageToDataUrl(file));
        pendingFiles.push({ id, name: file.name, size: file.size, type: file.type, kind: 'image' });
      } catch { toast('تعذر تجهيز الصورة: ' + file.name); }
      continue;
    }
    const ext = getExtension(file.name);
    if (ext !== 'zip' && file.size > MAX_FILE_SIZE) { toast('حجم الملف أكبر من 1MB: ' + file.name); continue; }
    if (ext === 'pdf') { toast('قراءة PDF غير مفعّلة حاليًا.'); continue; }
    if (ext === 'zip') { await handleProjectUpload('zip', [file]); continue; }
    if (!SUPPORTED_EXTENSIONS.includes(ext)) { toast('نوع الملف غير مدعوم: ' + file.name); continue; }
    try {
      const full = await file.text();
      const content = full.slice(0, MAX_FILE_CHARS);
      pendingFiles.push({
        id: 'txt_' + uid(), name: file.name, size: file.size, type: file.type || 'text/plain', kind: 'text',
        content, truncated: full.length > MAX_FILE_CHARS,
      });
      if (full.length > MAX_FILE_CHARS) toast(`${file.name}: تم أخذ أول ${MAX_FILE_CHARS} حرف فقط. ارفع المشروع كاملًا لسياق أدق.`);
      textUpdates.push({ name: file.name, content: full });
    } catch { toast('تعذر قراءة الملف: ' + file.name); }
  }
  // Files re-uploaded into a chat that already has a Godot project refresh the project context.
  const chat = current();
  const project = chat && projects.get(chat.id);
  if (project && textUpdates.length) {
    const r = G.mergeFiles(project, textUpdates);
    storeProject(chat, project);
    const bits = [];
    if (r.changed.length) bits.push(`${r.changed.length} ملف تغيّر`);
    if (r.added.length) bits.push(`${r.added.length} ملف جديد`);
    if (r.unchanged.length) bits.push(`${r.unchanged.length} بدون تغيير`);
    toast('تم تحديث سياق المشروع: ' + bits.join('، ') + '.');
    pendingFiles.forEach((f) => { if (f.kind === 'text') f.inProject = true; });
  }
  renderAttachments();
}

async function handleProjectUpload(kind, fileList) {
  const files = Array.from(fileList || []);
  if (!files.length) return;
  const chat = current() || newChat();
  const old = projects.get(chat.id);
  toast('جارٍ قراءة مشروع Godot…');
  try {
    const onProgress = (done, total) => { el.attachmentTray.hidden = false; el.attachmentTray.dataset.progress = `${done}/${total}`; };
    const project = kind === 'zip' ? await G.readZipProject(files[0], { onProgress }) : await G.readFolderProject(files, { onProgress });
    delete el.attachmentTray.dataset.progress;
    if (!project.files.size) { toast('لم أجد ملفات Godot قابلة للقراءة في هذا الاختيار.'); renderAttachments(); return; }
    const d = G.diffProjects(old, project);
    storeProject(chat, project);
    if (old) toast(`تم تحديث المشروع: ${d.changed.length} معدّل، ${d.added.length} جديد، ${d.removed.length} محذوف.`);
    else toast(`تم تحميل المشروع: ${project.files.size} ملف مقروء${project.skipped.length ? '، ' + project.skipped.length + ' لم يُقرأ' : ''}.`);
    if (!project.files.has('project.godot')) setTimeout(() => toast('لم أجد project.godot؛ سيُعامل كمجلد سكربتات فقط.'), 3300);
  } catch (e) {
    delete el.attachmentTray.dataset.progress;
    toast('تعذر قراءة المشروع: ' + (e.message || 'خطأ غير معروف'));
  }
  renderAttachments();
}

if (el.attachBtn && el.attachMenu) {
  el.attachBtn.addEventListener('click', (e) => { e.preventDefault(); e.stopPropagation(); toggleAttachMenu(); });
  el.attachMenu.addEventListener('click', (e) => {
    const option = e.target.closest('[data-attach]');
    if (!option) return;
    closeAttachMenu();
    const kind = option.dataset.attach;
    if (kind === 'file') el.fileInput?.click();
    else if (kind === 'image') el.imageInput?.click();
    else if (kind === 'zip') el.zipInput?.click();
    else if (kind === 'folder') el.folderInput?.click();
  });
  document.addEventListener('click', (e) => {
    if (!el.attachMenu.contains(e.target) && !el.attachBtn.contains(e.target)) closeAttachMenu();
  });
  // Folder pickers do not work on most mobile browsers: hide that option on touch devices.
  if (window.matchMedia('(pointer:coarse)').matches || !('webkitdirectory' in HTMLInputElement.prototype)) {
    el.attachMenu.querySelector('[data-attach="folder"]')?.setAttribute('hidden', '');
  }
}
el.fileInput?.addEventListener('change', async () => { await handleFiles(el.fileInput.files, 'file'); el.fileInput.value = ''; });
el.imageInput?.addEventListener('change', async () => { await handleFiles(el.imageInput.files, 'image'); el.imageInput.value = ''; });
el.zipInput?.addEventListener('change', async () => { await handleProjectUpload('zip', el.zipInput.files); el.zipInput.value = ''; });
el.folderInput?.addEventListener('change', async () => { await handleProjectUpload('folder', el.folderInput.files); el.folderInput.value = ''; });


/* ---------- rendering ---------- */

const MODE_LABEL = { think: 'Think', search: 'Search', fix: 'AI Fix' };

function rowUser(message) {
  const r = mk('div', 'row user');
  const b = mk('div', 'bubble');
  b.dir = 'auto';
  const text = typeof message === 'string' ? message : (message.content || '');
  if (text) {
    const content = mk('div', 'user-text');
    content.textContent = text;
    b.append(content);
  }
  if (message && Array.isArray(message.attachments) && message.attachments.length) {
    const files = mk('div', 'user-attachments');
    message.attachments.forEach((file) => {
      const item = mk('div', 'user-attachment');
      item.innerHTML = svg(IC.file, 14);
      const name = mk('span');
      name.textContent = file.name;
      item.append(name);
      files.append(item);
    });
    b.append(files);
  }
  const used = message && message.modes ? Object.keys(MODE_LABEL).filter((k) => message.modes[k]) : [];
  if (used.length) {
    const tags = mk('div', 'mode-tags');
    used.forEach((k) => tags.append(mk('span', 'mode-tag', MODE_LABEL[k])));
    b.append(tags);
  }
  r.append(b);
  return r;
}

// Files the diff review can compare against: project files first, then explicit attachments (latest wins).
function sourceFilesFor(chat) {
  const map = new Map();
  const project = projects.get(chat.id);
  if (project) for (const f of project.files.values()) map.set(f.path, { name: f.path, kind: 'text', content: f.text });
  for (const m of chat.messages) {
    if (m.role === 'user' && Array.isArray(m.attachments)) {
      for (const a of m.attachments) if (a.kind === 'text' && a.content && !a.trimmed) map.set(a.name, { name: a.name, kind: 'text', content: a.content });
    }
  }
  return [...map.values()];
}

function renderFixReport(m) {
  const box = mk('section', 'fix-report');
  const head = mk('div', 'fix-report-head');
  head.append(mk('strong', '', 'تقرير AI Fix'), mk('span', 'fix-untested', 'قراءة ثابتة · لم يُختبر داخل Godot'));
  box.append(head);
  if (m.findings && m.findings.length) {
    const ul = mk('ul', 'fix-list');
    m.findings.forEach((f) => {
      const li = mk('li', f.severity === 'warning' ? 'warn' : 'err');
      const loc = mk('code', 'ic');
      loc.textContent = (f.file || '') + (f.line ? ':' + f.line : '');
      li.append(loc);
      const t = mk('span');
      t.textContent = ' ' + [f.issue, f.fix && '← ' + f.fix].filter(Boolean).join(' ');
      li.append(t);
      ul.append(li);
    });
    box.append(ul);
  }
  const warns = (m.files || []).flatMap((f) => (f.warnings || []).map((w) => ({ ...w, file: f.name })));
  if (warns.length) {
    box.append(mk('div', 'fix-warn-title', 'تنبيهات فحص الناتج (آلية، قد لا تكون كاملة):'));
    const ul = mk('ul', 'fix-list');
    warns.slice(0, 10).forEach((w) => { const li = mk('li', w.sev === 'warning' ? 'warn' : 'err'); li.textContent = `${w.file}${w.line ? ':' + w.line : ''} — ${w.msg}`; ul.append(li); });
    box.append(ul);
  }
  return box;
}

function rowAI(m, idx, isLast, sourceFiles) {
  const r = mk('div', 'row ai');
  r.dataset.idx = idx;
  const body = mk('div', 'ai-body');
  if (m.notices && m.notices.length) {
    const n = mk('div', 'run-notices');
    m.notices.forEach((x) => { const d = mk('div', 'notice'); d.textContent = 'ℹ ' + x.text; n.append(d); });
    body.append(n);
  }
  const md = mk('div', 'md');
  md.innerHTML = R.md(m.content || '', COPY_HTML);
  body.append(md);

  const cut = m.incomplete || m.finish === 'MAX_TOKENS';
  if (cut) {
    const flag = mk('div', 'cut-flag');
    flag.textContent = m.stopped ? '⏹ تم إيقاف الرد قبل اكتماله.' : m.incomplete ? '⚠ الرد لم يكتمل' + (m.error ? ': ' + m.error : '.') : '⚠ وصل الرد للحد الأقصى للطول.';
    body.append(flag);
  }
  if (m.fixMode) body.append(renderFixReport(m));
  const generated = renderGeneratedFiles(m.files, sourceFiles);
  if (generated) body.append(generated);

  const acts = mk('div', 'acts');
  acts.innerHTML =
    '<button type="button" class="act" data-act="copy">' + svg(IC.copy, 15) + '<span>نسخ الرد</span></button>' +
    (isLast && cut ? '<button type="button" class="act accent" data-act="continue">' + svg(IC.play, 15) + '<span>متابعة</span></button>' : '') +
    (isLast ? '<button type="button" class="act" data-act="regen">' + svg(IC.refresh, 15) + '<span>إعادة التوليد</span></button>' : '');
  body.append(acts);
  r.append(body);
  return r;
}

function renderList() {
  const frag = document.createDocumentFragment();
  chats.slice().sort((a, b) => b.updated - a.updated).forEach((c) => {
    const row = mk('div', 'chat-item' + (c.id === activeId ? ' active' : '') + (runs.has(c.id) ? ' busy' : ''));
    row.dataset.id = c.id;
    const open = mk('button', 'chat-open');
    open.type = 'button';
    open.dir = 'auto';
    open.dataset.do = 'open';
    open.textContent = c.title;
    const ren = mk('button', 'chat-act', svg(IC.pen));
    ren.type = 'button'; ren.dataset.do = 'rename'; ren.setAttribute('aria-label', 'إعادة تسمية');
    const del = mk('button', 'chat-act del', svg(IC.trash));
    del.type = 'button'; del.dataset.do = 'delete'; del.setAttribute('aria-label', 'حذف المحادثة');
    row.append(open, ren, del);
    frag.append(row);
  });
  el.list.replaceChildren(frag);
}

el.list.addEventListener('click', (e) => {
  const btn = e.target.closest('[data-do]');
  const row = e.target.closest('.chat-item');
  if (!btn || !row) return;
  const id = row.dataset.id;
  if (btn.dataset.do === 'open') { select(id); closeSide(); }
  else if (btn.dataset.do === 'rename') rename(id);
  else if (btn.dataset.do === 'delete') removeChat(id);
});

function renderMessages() {
  const chat = current();
  el.title.textContent = chat ? chat.title : 'NOVA AI';
  el.msgs.innerHTML = '';
  const run = chat ? runs.get(chat.id) : null;
  if (run) run.node = null;

  if (!chat || (!chat.messages.length && !run)) {
    const w = mk('div', 'welcome',
      '<h2>مرحبًا في <b>NOVA AI</b></h2>' +
      '<p>مساعدك في البرمجة وGodot · Your coding &amp; Godot assistant</p>' +
      '<div class="cards"></div>');
    SUGGESTIONS.forEach((s) => {
      const b = mk('button', 'card', '<b></b><span></span>');
      b.type = 'button';
      b.dir = 'auto';
      b.firstChild.textContent = s.h;
      b.lastChild.textContent = s.s;
      b.onclick = () => { if (submit(s.q)) { el.input.value = ''; autosize(); } };
      w.querySelector('.cards').append(b);
    });
    el.msgs.append(w);
    updateComposerState();
    return;
  }

  const last = chat.messages.length - 1;
  const sources = sourceFilesFor(chat);
  const frag = document.createDocumentFragment();
  chat.messages.forEach((m, i) => {
    frag.append(m.role === 'user' ? rowUser(m) : rowAI(m, i, i === last && !run, sources));
  });
  el.msgs.append(frag);
  if (run) attachRunNode(run);
  else if (chat.lastError) showErrorRow(chat);
  scrollDown();
  updateComposerState();
}

const nearBottom = () => el.msgs.scrollHeight - el.msgs.scrollTop - el.msgs.clientHeight < 160;
function scrollDown() { el.msgs.scrollTop = el.msgs.scrollHeight; }

function showErrorRow(chat) {
  const r = mk('div', 'row ai');
  r.dataset.transient = '1';
  const body = mk('div', 'ai-body');
  const box = mk('div', 'errbox');
  const t = mk('div');
  t.textContent = '⚠ ' + chat.lastError.msg;
  const b = mk('button', 'btn small', svg(IC.refresh, 15) + '<span>إعادة المحاولة</span>');
  b.type = 'button';
  b.onclick = () => ask(chat);
  box.append(t, b);
  body.append(box);
  r.append(body);
  el.msgs.append(r);
}

/* live run rendering: stable blocks are rendered once, only the unfinished tail is re-rendered per frame */

function fenceCount(s) { return (s.match(/```/g) || []).length; }
function stableBoundary(text) {
  let i = text.lastIndexOf('\n\n');
  while (i > 0) {
    if (fenceCount(text.slice(0, i)) % 2 === 0) return i + 2;
    i = text.lastIndexOf('\n\n', i - 1);
  }
  return 0;
}

function statusLabel(run) {
  switch (run.status) {
    case 'thinking': return 'NOVA يفكر بعمق…';
    case 'searching': return run.modes.think ? 'NOVA يبحث ويحلل المصادر…' : 'NOVA يبحث في الويب…';
    case 'writing': return 'NOVA يكتب…';
    case 'retrying': return `انقطع الاتصال… إعادة المحاولة (${run.attempt}/${MAX_ATTEMPTS})`;
    case 'files': return run.mode === 'fix' ? 'NOVA يحلل الكود ويجهّز الإصلاح…' : 'NOVA يجهّز الملفات…';
    default:
      if (run.projectFiles) return `NOVA يقرأ ${run.projectFiles} ملف من المشروع…`;
      return run.fileCount > 0 ? `NOVA يقرأ ${run.fileCount} ${run.fileCount === 1 ? 'ملف' : 'ملفات'}…` : 'NOVA يتصل…';
  }
}

function attachRunNode(run) {
  const row = mk('div', 'row ai streaming');
  row.innerHTML =
    '<div class="ai-body"><div class="think run-status"><i></i><i></i><i></i><span></span></div>' +
    '<div class="run-notices"></div><div class="md"><div class="md-stable"></div><div class="md-tail"></div></div></div>';
  el.msgs.append(row);
  run.node = {
    row, status: row.querySelector('.run-status'), label: row.querySelector('.run-status span'),
    notices: row.querySelector('.run-notices'), stable: row.querySelector('.md-stable'), tail: row.querySelector('.md-tail'),
  };
  run.stableLen = 0;
  paintNotices(run);
  paintRun(run);
}

function paintNotices(run) {
  if (!run.node) return;
  run.node.notices.replaceChildren(...run.notices.map((x) => { const d = mk('div', 'notice'); d.textContent = 'ℹ ' + x.text; return d; }));
}

function paintRun(run) {
  run.raf = 0;
  const n = run.node;
  if (!n || isStale(run)) return;
  n.label.textContent = statusLabel(run);
  n.status.hidden = !!run.text;
  if (!run.text) return;
  const stick = nearBottom();
  const b = stableBoundary(run.text);
  if (b > run.stableLen) {
    n.stable.insertAdjacentHTML('beforeend', R.md(run.text.slice(run.stableLen, b), COPY_HTML));
    run.stableLen = b;
  }
  n.tail.innerHTML = R.md(run.text.slice(run.stableLen), COPY_HTML);
  if (stick) scrollDown();
}
function schedulePaint(run) { if (!run.raf) run.raf = requestAnimationFrame(() => paintRun(run)); }

const SEND_ICON = el.send.innerHTML;
const STOP_ICON =
  '<svg viewBox="0 0 24 24" width="18" height="18" fill="currentColor" aria-hidden="true"><rect x="6" y="6" width="12" height="12" rx="2.5"/></svg>';

function updateComposerState() {
  const busy = isBusy(current());
  el.send.innerHTML = busy ? STOP_ICON : SEND_ICON;
  el.send.setAttribute('aria-label', busy ? 'إيقاف' : 'إرسال');
  el.send.classList.toggle('is-stop', busy);
}

/* ---------- chats ---------- */

function newChat() {
  stashDraft();
  const c = { id: uid(), title: 'محادثة جديدة', messages: [], updated: Date.now() };
  chats.push(c);
  activeId = c.id;
  save();
  renderList();
  renderMessages();
  renderAttachments();
  restoreDraft();
  return c;
}

function stashDraft() { setDraft(activeId, el.input.value); }
function restoreDraft() {
  el.input.value = drafts[activeId || '_new'] || '';
  autosize();
}

function select(id) {
  if (id === activeId) return;
  stashDraft();
  activeId = id;
  save();
  renderList();
  renderMessages();
  renderAttachments();
  restoreDraft();
  loadProjectFor(current());
}

function rename(id) {
  const c = chatById(id);
  if (!c) return;
  const n = prompt('اسم المحادثة:', c.title);
  if (n && n.trim()) {
    c.title = n.trim().slice(0, 60);
    c.renamed = true;
    save();
    renderList();
    if (id === activeId) el.title.textContent = c.title;
  }
}

function removeChat(id) {
  const c = chatById(id);
  if (!c) return;
  if (!confirm('حذف هذه المحادثة نهائيًا؟')) return;
  const run = runs.get(id);
  if (run) { run.stopped = true; run.ctrl?.abort(); runs.delete(id); }
  dropProject(c);
  chats = chats.filter((x) => x.id !== id);
  delete drafts[id];
  if (activeId === id) activeId = null;
  save();
  renderList();
  renderMessages();
  renderAttachments();
}


/* ---------- conversation context ---------- */

function detectIntent(text, chat) {
  const t = String(text || '').trim().toLowerCase();
  if (!t) return 'general';
  const hasPrev = chat.messages.some((m) => m.role === 'assistant');
  if (hasPrev && (t.length <= 14 || /^(كمل|كمّل|تابع|استمر|continue|go on|and then|وبعدين|وبعد كده|طب\s|طيب\s|اعمل ايه|أعمل إيه|اعمل إيه|ايه الحل|إيه الحل)/i.test(t)) && t.length <= 40) return 'continue';
  if (/(اصلح|أصلح|صلح|صلّح|حل المشكلة|المشكلة|error|bug|fix|خطأ|غلط|مش شغال|بيطلع|crash|لا يعمل|invalid|null instance|nonexistent|not found)/i.test(t)) return 'fix';
  if (/(اكتب|اعمل|أنشئ|انشئ|ابني|write|create|implement|generate|أضف|اضف|add )/i.test(t)) return 'write';
  if (/(اشرح|شرح|يعني ايه|يعني إيه|ما هو|ما الفرق|الفرق بين|explain|what is|why|ليه|لماذا|كيف يعمل)/i.test(t)) return 'explain';
  return 'general';
}

function fileOutline(a) {
  const text = a.content || '';
  if (!text) return '';
  if (/\.gd$/i.test(a.name)) {
    const s = G.parseScript(text);
    return [s.extends && 'extends ' + s.extends, s.className && 'class ' + s.className, s.funcs.length && 'funcs: ' + s.funcs.slice(0, 12).map((f) => f.name).join(', ')].filter(Boolean).join('; ');
  }
  if (/\.tscn$/i.test(a.name)) { const sc = G.parseScene(text); return `scene root ${sc.rootType || '?'}, ${sc.nodes.length} nodes`; }
  return text.split('\n').length + ' lines';
}

function buildContextNote(chat) {
  const lines = [];
  const files = new Map();
  let images = 0;
  for (const m of chat.messages) {
    for (const a of m.attachments || []) { if (a.kind === 'text') files.set(a.name, a); else if (a.kind === 'image') images++; }
  }
  if (files.size) lines.push('Files attached earlier in THIS chat: ' + [...files.values()].slice(-10).map((a) => `${a.name}${fileOutline(a) ? ' (' + fileOutline(a) + ')' : ''}`).join(' | '));
  if (images) lines.push(`${images} image(s) were attached earlier in this chat (only the latest turns carry image data).`);
  const p = projects.get(chat.id);
  if (p) lines.push(`A Godot project "${p.name}" is loaded (${p.files.size} readable files). Relevant files are selected for each request; use only what is provided and say when a file you need was not included.`);
  const lastA = [...chat.messages].reverse().find((m) => m.role === 'assistant');
  if (lastA && (lastA.incomplete || lastA.finish === 'MAX_TOKENS')) lines.push('Your previous answer was cut off before it finished. If the user says continue, resume exactly where it stopped without repeating.');
  const nUser = chat.messages.filter((m) => m.role === 'user').length;
  lines.push(`This is user turn #${nUser} of the conversation.`);
  return lines.join('\n').slice(0, 3800);
}

function fileStub(a) {
  const o = fileOutline(a);
  return `[ملف مرفق سابقًا: ${a.name}${a.size ? ' · ' + formatSize(a.size) : ''}${o ? ' · ' + o : ''} — المحتوى الكامل لم يُرسل هذه المرة؛ اطلب إعادة رفعه إن احتجت تفاصيله.]`;
}

const msgLength = (m) => (typeof m.content === 'string' ? m.content.length : m.content.reduce((n, p) => n + (p.type === 'text' ? p.text.length : 0), 0));

function fitMessages(msgs) {
  let total = msgs.reduce((n, m) => n + msgLength(m), 0);
  while (total > MAX_REQUEST_CHARS && msgs.length > 1) total -= msgLength(msgs.shift());
  if (total > MAX_REQUEST_CHARS && msgs.length === 1) {
    const m = msgs[0];
    const cut = (s) => s.slice(0, Math.floor(MAX_REQUEST_CHARS * 0.55)) + '\n…[اختصره التطبيق ليناسب حد الطلب]…\n' + s.slice(-Math.floor(MAX_REQUEST_CHARS * 0.3));
    if (typeof m.content === 'string') m.content = cut(m.content);
    else m.content = m.content.map((p) => (p.type === 'text' && p.text.length > MAX_REQUEST_CHARS ? { ...p, text: cut(p.text) } : p));
  }
  return msgs;
}

function buildApiMessages(chat) {
  const all = chat.messages.filter((m) => m.role === 'user' || (m.role === 'assistant' && m.content));
  const slice = all.slice(-MAX_CONTEXT);
  const freshIds = new Set(slice.filter((m) => m.role === 'user').slice(-FRESH_USER_TURNS).map((m) => m.id));
  let imageBudget = MAX_IMAGES;
  const out = slice.map((m) => {
    if (m.role !== 'user' || !Array.isArray(m.attachments) || !m.attachments.length) return { role: m.role, content: m.content || '' };
    const fresh = freshIds.has(m.id);
    let text = m.content || '';
    for (const file of m.attachments) {
      if (file.kind !== 'text') continue;
      if (fresh && file.content && !file.inProject) text += '\n\n--- بداية الملف: ' + file.name + ' ---\n```text\n' + file.content + '\n```\n--- نهاية الملف: ' + file.name + ' ---' + (file.truncated ? '\n(الملف مقتطع لأنه طويل)' : '');
      else if (file.inProject) text += `\n\n[الملف ${file.name} أُضيف إلى سياق المشروع]`;
      else text += '\n\n' + fileStub(file);
    }
    const parts = [];
    if (text.trim()) parts.push({ type: 'text', text });
    if (fresh) {
      for (const file of m.attachments) {
        if (file.kind !== 'image' || imageBudget <= 0) continue;
        const data = imageDataStore.get(file.id);
        if (data) { parts.push({ type: 'image_url', image_url: { url: data } }); imageBudget--; }
        else parts.push({ type: 'text', text: '[الصورة المرفقة ' + file.name + ' لم تعد متاحة بعد إعادة تحميل الصفحة. أعد رفعها للتحليل.]' });
      }
    }
    return { role: m.role, content: parts.length ? parts : text };
  });
  return fitMessages(out);
}

function projectPayload(chat, last, budget) {
  const p = projects.get(chat.id);
  if (!p) return { text: '', included: [] };
  const prev = [...chat.messages].reverse().find((m) => m.role === 'assistant');
  const query = [last.content || '', ...(last.attachments || []).map((a) => a.name), prev ? String(prev.content || '').slice(0, 800) : ''].join('\n');
  const boost = (last.attachments || []).filter((a) => a.kind === 'text').map((a) => a.name);
  const r = G.selectContext(p, { query, budget, boost });
  return { text: r.text, included: r.included };
}

/* ---------- model cooldown hints (from the Worker's rate-limit info) ---------- */

function readModelState() {
  try { const v = JSON.parse(localStorage.getItem(MODEL_STATE_KEY) || '{}'); return v && typeof v === 'object' ? v : {}; }
  catch { return {}; }
}
function getAvoidModels() {
  const state = readModelState(), now = Date.now();
  return Object.keys(state).filter((m) => Number(state[m]?.until || 0) > now);
}
function parseResetSeconds(value) {
  if (!value) return 60;
  const match = String(value).match(/([0-9.]+)\s*(ms|s|m|h)?/i);
  if (!match) return 60;
  const amount = Number(match[1]), unit = (match[2] || 's').toLowerCase();
  return Math.max(30, Math.ceil(amount * (unit === 'ms' ? 0.001 : unit === 'm' ? 60 : unit === 'h' ? 3600 : 1)));
}
function rememberLimits(model, limits) {
  if (!model || !limits) return;
  const remReq = Number(limits['x-ratelimit-remaining-requests']);
  const remTok = Number(limits['x-ratelimit-remaining-tokens']);
  if ((Number.isFinite(remReq) && remReq <= 1) || (Number.isFinite(remTok) && remTok <= 1000)) {
    const reset = limits['x-ratelimit-reset-requests'] || limits['x-ratelimit-reset-tokens'] || limits['retry-after'];
    const state = readModelState();
    state[model] = { until: Date.now() + parseResetSeconds(reset) * 1000 };
    try { localStorage.setItem(MODEL_STATE_KEY, JSON.stringify(state)); } catch { /* ignore */ }
  }
}

/* ---------- sending ---------- */

function wantsFiles(text) {
  const s = String(text || '').toLowerCase();
  return /(?:اعمل|أنشئ|انشئ|ولّد|ولد|جهّز|جهز|اصنع|ابن(?:ي|اء)?|صدّر|صدر).{0,45}(?:ملف|ملفات|مشروع|zip)|(?:ملف|ملفات|مشروع).{0,35}(?:جاهز|لتحميل|تحميل|zip)|(?:create|generate|make|build|export).{0,50}(?:file|files|project|zip)|(?:file|files|project).{0,35}(?:download|ready|zip)/i.test(s);
}

function hasCodeContext(chat, attachments, text) {
  return attachments.some((f) => f.kind === 'text') || !!chat.project || /```/.test(text) ||
    chat.messages.some((m) => (m.attachments || []).some((a) => a.kind === 'text'));
}

// Returns true when the message was accepted (the caller then clears the composer).
function submit(text) {
  text = (text || '').trim();
  const existing = current();
  if (existing && isBusy(existing)) { toast('هذه المحادثة لديها رد قيد التنفيذ. أوقفه أو انتظر.'); return false; }
  if (!text && pendingFiles.length === 0) return false;
  if (runs.size >= MAX_ACTIVE_RUNS) { toast('يوجد ردّان قيد التنفيذ في محادثات أخرى. انتظر أحدهما أو أوقفه.'); return false; }
  const attachments = pendingFiles.map((f) => ({ ...f }));
  const chat = existing || newChat();

  if (modes.fix) {
    if (attachments.some((f) => f.kind === 'image')) { toast('AI Fix يعمل مع ملفات الكود فقط. أزل الصور أو أوقف AI Fix.'); return false; }
    if (!hasCodeContext(chat, attachments, text)) { toast('AI Fix يحتاج ملف كود أو مشروع Godot. ارفعه أولًا.'); return false; }
  }

  pendingFiles = [];
  renderAttachments();
  chat.messages.push({ id: uid(), role: 'user', content: text, attachments, modes: { ...modes }, at: Date.now() });
  if (chat.messages.length === 1 && !chat.renamed) chat.title = (text || attachments[0]?.name || 'ملفات مرفقة').slice(0, 40);
  chat.lastError = null;
  chat.updated = Date.now();
  setDraft(chat.id, '');
  save();
  renderList();
  renderMessages();
  ask(chat);
  return true;
}

const RETRYABLE_CODES = new Set(['upstream_down', 'stream_broken', 'stalled', 'internal', 'incomplete']);

function canCommit(chat, run) {
  const last = chat.messages[chat.messages.length - 1];
  return chatById(chat.id) === chat && !isStale(run) && !!last && last.role === 'user' && last.id === run.userMsgId;
}

function commitAssistant(chat, run, extra) {
  if (!canCommit(chat, run)) return false;
  const m = { id: uid(), role: 'assistant', content: run.text, at: Date.now(), ...extra };
  if (run.notices.length) m.notices = run.notices.slice();
  chat.messages.push(m);
  chat.lastError = null;
  chat.updated = Date.now();
  save();
  return true;
}

function endRun(chat, run) {
  if (run.raf) { cancelAnimationFrame(run.raf); run.raf = 0; }
  if (runs.get(chat.id) === run) runs.delete(chat.id);
  renderList();
  if (chat.id === activeId) renderMessages(); else updateComposerState();
}

function failRun(chat, run, msg, { keepPartial = true } = {}) {
  if (isStale(run)) return;
  if (keepPartial && run.text.trim()) commitAssistant(chat, run, { incomplete: true, error: msg });
  else { chat.lastError = { msg }; save(); }
  endRun(chat, run);
}

async function ask(chat) {
  if (isBusy(chat)) return;
  if (runs.size >= MAX_ACTIVE_RUNS) { toast('يوجد ردّان قيد التنفيذ. انتظر أحدهما أو أوقفه.'); return; }
  const last = chat.messages[chat.messages.length - 1];
  if (!last || last.role !== 'user') return;
  chat.lastError = null;
  const runModes = { think: !!last.modes?.think, search: !!last.modes?.search, fix: !!last.modes?.fix };
  const kind = runModes.fix ? 'fix' : (wantsFiles(last.content) ? 'files' : 'chat');
  const run = {
    id: uid(), chatId: chat.id, userMsgId: last.id, kind, mode: kind, modes: runModes, ctrl: null, text: '', status: 'connecting',
    notices: [], stopped: false, attempt: 1, node: null, raf: 0, stableLen: 0,
    fileCount: (last.attachments || []).length, projectFiles: 0,
  };
  runs.set(chat.id, run);
  renderList();
  if (chat.id === activeId) renderMessages(); else updateComposerState();

  if (!navigator.onLine) return failRun(chat, run, 'لا يوجد اتصال بالإنترنت. ستبقى رسالتك محفوظة؛ اضغط إعادة المحاولة عند رجوع الاتصال.');

  try {
    if (kind === 'chat') await runChatRequest(chat, run, last);
    else await runFilesRequest(chat, run, last);
    refreshAccount();
  } catch (e) {
    console.error('[NOVA] unexpected run error', e);
    failRun(chat, run, 'حدث خطأ غير متوقع في التطبيق. حاول مرة أخرى.');
  }
}

function buildPayload(chat, run, last, extra = {}) {
  const proj = projectPayload(chat, last, run.kind === 'fix' ? FIX_PROJECT_BUDGET : CHAT_PROJECT_BUDGET);
  run.projectFiles = proj.included.length;
  return {
    messages: buildApiMessages(chat),
    think: run.modes.think,
    intent: detectIntent(last.content, chat),
    context: buildContextNote(chat),
    project: proj.text,
    avoidModels: getAvoidModels(),
    ...extra,
  };
}

async function runChatRequest(chat, run, last) {
  const payload = buildPayload(chat, run, last, { search: run.modes.search });
  if (run.node) paintRun(run);
  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
    if (isStale(run) || run.stopped) return finishStopped(chat, run);
    run.attempt = attempt;
    if (attempt > 1) {
      run.status = 'retrying'; run.text = ''; run.notices = []; run.stableLen = 0;
      if (run.node) { run.node.stable.innerHTML = ''; run.node.tail.innerHTML = ''; paintRun(run); }
      await sleep(attempt * 800);
      if (isStale(run) || run.stopped) return finishStopped(chat, run);
    }
    const r = await tryStream(chat, run, payload);
    if (isStale(run)) return;
    if (r.stopped) return finishStopped(chat, run);
    if (r.ok) {
      rememberLimits(r.done.model, r.done.rateLimits);
      const ok = commitAssistant(chat, run, {
        finish: r.done.finish || 'stop', meta: { model: r.done.model, provider: r.done.provider, search: !!r.done.search, think: !!r.done.think },
      });
      if (ok && r.done.finish === 'MAX_TOKENS' && chat.id === activeId) toast('وصل الرد للحد الأقصى للطول. اضغط "متابعة".');
      return endRun(chat, run);
    }
    if (r.retry && !run.text && attempt < MAX_ATTEMPTS) continue;
    return failRun(chat, run, r.error);
  }
}

function finishStopped(chat, run) {
  if (isStale(run)) return;
  if (run.text.trim()) commitAssistant(chat, run, { incomplete: true, stopped: true });
  endRun(chat, run);
}

async function tryStream(chat, run, payload) {
  const ctrl = new AbortController();
  run.ctrl = ctrl;
  let idle = 0, timedOut = false, streamErr = null, finished = null;
  const arm = () => { clearTimeout(idle); idle = setTimeout(() => { timedOut = true; ctrl.abort(); }, IDLE_ABORT_MS); };
  const hard = setTimeout(() => { timedOut = true; ctrl.abort(); }, HARD_LIMIT_MS);
  try {
    arm();
    const res = await fetch('/api/chat', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, signal: ctrl.signal, body: JSON.stringify(payload),
    });
    const ct = res.headers.get('content-type') || '';
    if (!res.ok || !ct.includes('text/event-stream') || !res.body) {
      let data = null;
      try { data = await res.json(); } catch { /* not json */ }
      if (res.status === 401) onAuthRequired();
      return { retry: [502, 503, 504, 408].includes(res.status), error: (data && data.error) || `خطأ من الخادم (${res.status}).` };
    }
    const reader = res.body.getReader();
    const dec = new TextDecoder();
    const parser = R.sseParser((ev) => {
      if (isStale(run)) return;
      if (ev.error) streamErr = ev;
      else if (typeof ev.t === 'string') {
        if (!run.text) run.status = 'writing';
        run.text += ev.t;
        schedulePaint(run);
      } else if (ev.status) {
        if (!run.text) { run.status = ev.status; schedulePaint(run); }
      } else if (ev.notice) {
        if (!run.notices.some((n) => n.code === ev.notice)) { run.notices.push({ code: ev.notice, text: ev.text || '' }); paintNotices(run); }
      } else if (ev.done) finished = ev;
    });
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      arm();
      parser.feed(dec.decode(value, { stream: true }));
    }
    parser.feed(dec.decode() + '\n');
    if (run.stopped) return { stopped: true };
    if (streamErr) return { retry: RETRYABLE_CODES.has(streamErr.code) && !run.text, error: streamErr.error };
    if (!finished) return { retry: !run.text, error: 'انقطع الاتصال أثناء استقبال الرد.' };
    return { ok: true, done: finished };
  } catch (e) {
    if (run.stopped) return { stopped: true };
    if (timedOut) return { retry: true, error: 'تأخر الرد أو توقف الاتصال. حاول مرة أخرى.' };
    if (!navigator.onLine) return { retry: false, error: 'لا يوجد اتصال بالإنترنت.' };
    return { retry: true, error: e instanceof TypeError ? 'انقطع الاتصال بالخادم.' : (e.message || 'تعذر إكمال الطلب.') };
  } finally {
    clearTimeout(idle);
    clearTimeout(hard);
  }
}

const normName = (n) => String(n || '').replace(/^res:\/\//, '').replace(/\\/g, '/').replace(/^\.?\//, '');

async function runFilesRequest(chat, run, last) {
  run.status = 'files';
  if (run.node) paintRun(run);
  const payload = buildPayload(chat, run, last, { mode: run.kind === 'fix' ? 'fix' : 'files' });
  let data = null, lastError = 'تعذر توليد الملفات.';
  for (let attempt = 1; attempt <= 2; attempt++) {
    if (isStale(run) || run.stopped) return finishStopped(chat, run);
    const ctrl = new AbortController();
    run.ctrl = ctrl;
    let timedOut = false;
    const timer = setTimeout(() => { timedOut = true; ctrl.abort(); }, FILES_TIMEOUT_MS);
    try {
      const res = await fetch('/api/generate-files', { method: 'POST', headers: { 'Content-Type': 'application/json' }, signal: ctrl.signal, body: JSON.stringify(payload) });
      let body;
      try { body = await res.json(); } catch { body = null; }
      rememberLimits(body && body.model, body && body.rateLimits);
      if (res.ok && body && Array.isArray(body.files)) { data = body; break; }
      if (res.status === 401) onAuthRequired();
      lastError = (body && body.error) || `تعذر توليد الملفات (${res.status}).`;
      if (![502, 503, 504].includes(res.status) || (body && ['truncated', 'bad_json', 'no_keys'].includes(body.code))) break;
    } catch (e) {
      if (run.stopped) return finishStopped(chat, run);
      lastError = timedOut ? 'استغرق توليد الملفات وقتًا طويلًا. جرّب طلبًا أصغر.' : !navigator.onLine ? 'لا يوجد اتصال بالإنترنت.' : 'انقطع الاتصال أثناء توليد الملفات.';
      if (!timedOut && navigator.onLine) { run.status = 'retrying'; run.attempt = attempt + 1; paintRun(run); await sleep(1200); continue; }
      break;
    } finally { clearTimeout(timer); }
  }
  if (isStale(run)) return;
  if (!data) return failRun(chat, run, lastError, { keepPartial: false });

  const fix = run.kind === 'fix';
  const sources = sourceFilesFor(chat);
  let files = data.files
    .filter((f) => f && typeof f.name === 'string' && typeof f.content === 'string')
    .slice(0, MAX_GENERATED_FILES)
    .map((f) => ({ name: safeFileName(normName(f.name)), content: f.content }));
  const unchanged = [];
  if (fix) {
    files = files.filter((f) => { const o = findOriginalFile(sources, f.name); if (o && o.content === f.content) { unchanged.push(f.name); return false; } return true; });
  }
  files.forEach((f) => {
    f.warnings = G.sanityCheck(f.name, f.content);
    if (fix && !findOriginalFile(sources, f.name)) f.warnings.push({ sev: 'warning', file: f.name, line: 0, msg: 'هذا الملف غير موجود بين الملفات المرفوعة، فلن تظهر له مقارنة. راجعه بعناية.' });
  });
  if (!files.length && !fix) return failRun(chat, run, 'لم يتم إنشاء أي ملفات صالحة.', { keepPartial: false });

  let message = data.message || (files.length ? 'تم إنشاء الملفات المطلوبة. يمكنك تحميلها من الأسفل.' : 'لم أجد مشكلة فعلية تحتاج تعديلًا.');
  if (fix && !files.length) message += '\n\nلم يُرجَع أي ملف معدّل' + (unchanged.length ? ' (الملفات التي أعادها النموذج مطابقة للأصل).' : '.');
  run.text = message;
  commitAssistant(chat, run, { files, findings: data.findings || [], fixMode: fix, tested: false, finish: 'stop' });
  endRun(chat, run);
}

function stopRun(chat) {
  const run = chat && runs.get(chat.id);
  if (!run) return;
  run.stopped = true;
  run.ctrl?.abort();
}


/* ---------- copy ---------- */

async function copyText(t) {
  try { await navigator.clipboard.writeText(t); return true; }
  catch {
    const a = document.createElement('textarea');
    a.value = t;
    a.style.cssText = 'position:fixed;opacity:0';
    document.body.append(a);
    a.select();
    let ok = false;
    try { ok = document.execCommand('copy'); } catch { ok = false; }
    a.remove();
    return ok;
  }
}

el.msgs.addEventListener('click', async (e) => {
  const cb = e.target.closest('[data-copy]');
  if (cb) {
    const code = cb.closest('.code')?.querySelector('code');
    if (!code) return;
    const ok = await copyText(code.textContent);
    cb.innerHTML = svg(ok ? IC.check : IC.copy, 14) + '<span>' + (ok ? 'تم النسخ' : 'فشل النسخ') + '</span>';
    setTimeout(() => { cb.innerHTML = COPY_HTML; }, 1500);
    return;
  }
  const ab = e.target.closest('[data-act]');
  const chat = current();
  if (!ab || !chat) return;
  const act = ab.dataset.act;

  if (act === 'copy') {
    const m = chat.messages[+ab.closest('.row').dataset.idx];
    const ok = m ? await copyText(m.content) : false;
    ab.innerHTML = svg(ok ? IC.check : IC.copy, 15) + '<span>' + (ok ? 'تم النسخ' : 'فشل النسخ') + '</span>';
    setTimeout(() => { ab.innerHTML = svg(IC.copy, 15) + '<span>نسخ الرد</span>'; }, 1500);
  } else if (act === 'regen') {
    if (isBusy(chat)) return;
    if (chat.messages.length && chat.messages[chat.messages.length - 1].role === 'assistant') chat.messages.pop();
    chat.lastError = null;
    save();
    renderMessages();
    ask(chat);
  } else if (act === 'continue') {
    if (isBusy(chat)) return;
    const lastUser = [...chat.messages].reverse().find((m) => m.role === 'user');
    chat.messages.push({
      id: uid(), role: 'user', content: 'كمّل من حيث توقفت', attachments: [], at: Date.now(),
      modes: { think: !!lastUser?.modes?.think, search: false, fix: false },
    });
    chat.updated = Date.now();
    save();
    renderList();
    renderMessages();
    ask(chat);
  }
});

/* ---------- UI events ---------- */

el.form.addEventListener('submit', (e) => {
  e.preventDefault();
  const chat = current();
  if (isBusy(chat)) { stopRun(chat); return; }
  if (submit(el.input.value)) { el.input.value = ''; autosize(); }
});

el.input.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey && !e.isComposing && window.matchMedia('(pointer:fine)').matches) {
    e.preventDefault();
    if (!isBusy(current())) el.form.requestSubmit();
  }
});

function autosize() {
  const t = el.input;
  t.style.height = 'auto';
  const h = Math.min(t.scrollHeight, 168);
  t.style.height = h + 'px';
  t.style.overflowY = t.scrollHeight > 168 ? 'auto' : 'hidden';
}
el.input.addEventListener('input', () => { autosize(); setDraft(activeId, el.input.value); });

// Keyboard: the layout follows the visual viewport so the composer stays above the keyboard
// and the latest message stays visible if the user was at the bottom.
let stickBottom = true;
el.msgs.addEventListener('scroll', () => { stickBottom = nearBottom(); }, { passive: true });
if (window.visualViewport) {
  const vv = window.visualViewport;
  const sync = () => {
    document.documentElement.style.setProperty('--vvh', vv.height + 'px');
    window.scrollTo(0, 0);
    if (stickBottom) requestAnimationFrame(scrollDown);
  };
  vv.addEventListener('resize', sync);
  vv.addEventListener('scroll', () => window.scrollTo(0, 0));
  sync();
}
window.addEventListener('online', () => toast('رجع الاتصال. يمكنك الضغط على إعادة المحاولة.'));
window.addEventListener('offline', () => toast('انقطع الإنترنت.'));

el.newChat.onclick = () => {
  const c = current();
  if (c && !c.messages.length) { closeSide(); el.input.focus(); return; }
  newChat();
  closeSide();
  el.input.focus();
};

const mq = window.matchMedia('(max-width:760px)');
function closeSide() {
  el.sidebar.classList.remove('open');
  el.scrim.classList.remove('show');
}
el.menu.onclick = () => {
  if (mq.matches) { el.sidebar.classList.add('open'); el.scrim.classList.add('show'); }
  else document.body.classList.toggle('side-collapsed');
};
el.scrim.onclick = closeSide;


/* ---------- settings ---------- */

function applyFs() {
  document.documentElement.style.setProperty('--fs', FS[settings.fs] || FS.m);
  document.querySelectorAll('#fontSeg button').forEach((b) => {
    b.classList.toggle('on', b.dataset.fs === settings.fs);
  });
}

el.settingsBtn.onclick = () => {
  closeSide();
  applyFs();
  el.settings.showModal();
};
$('#closeSettings').onclick = () => el.settings.close();
el.settings.addEventListener('click', (e) => {
  if (e.target === el.settings) el.settings.close();
});
$('#fontSeg').addEventListener('click', (e) => {
  const b = e.target.closest('[data-fs]');
  if (b) {
    settings.fs = b.dataset.fs;
    saveSettings();
    applyFs();
  }
});

$('#exportBtn').onclick = () => {
  const blob = new Blob([JSON.stringify(chats, null, 2)], { type: 'application/json' });
  downloadBlob(blob, 'nova-ai-chats.json');
};

$('#clearBtn').onclick = () => {
  if (!confirm('حذف كل المحادثات نهائيًا؟')) return;
  for (const run of runs.values()) { run.stopped = true; run.ctrl?.abort(); }
  runs.clear();
  chats.forEach((c) => { idb.del('p:' + c.id).catch(() => {}); });
  projects.clear();
  chats = [];
  drafts = {};
  activeId = null;
  save(true);
  saveDraftsNow();
  renderList();
  renderMessages();
  renderAttachments();
  el.settings.close();
};

/* ---------- PWA ---------- */

window.addEventListener('beforeinstallprompt', (e) => {
  e.preventDefault();
  deferredPrompt = e;
  if (el.install) el.install.hidden = false;
});

if (el.install) {
  el.install.onclick = async () => {
    if (!deferredPrompt) return;
    deferredPrompt.prompt();
    await deferredPrompt.userChoice.catch(() => {});
    deferredPrompt = null;
    el.install.hidden = true;
  };
}

window.addEventListener('appinstalled', () => {
  if (el.install) el.install.hidden = true;
});

if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/sw.js').catch(() => {});
  });
}


/* ---------- accounts (username/password + message quota) ---------- */

const authEl = {
  gate: $('#authGate'), form: $('#authForm'), tabs: $('#authTabs'), user: $('#authUser'), pass: $('#authPass'),
  err: $('#authErr'), submit: $('#authSubmit'), box: $('#userBox'), name: $('#userName'), quota: $('#userQuota'), logout: $('#logoutBtn'),
};
let account = { authRequired: false, user: null, unlimited: true, remaining: null, limit: null };
let authMode = 'login';

function renderAccount() {
  const needLogin = account.authRequired && !account.user;
  authEl.gate.hidden = !needLogin;
  authEl.box.hidden = !(account.authRequired && account.user);
  if (account.user) {
    authEl.name.textContent = account.user;
    authEl.quota.textContent = account.unlimited ? 'بدون حدود ∞' : `متبقي ${account.remaining} من ${account.limit}`;
    authEl.box.classList.toggle('low', !account.unlimited && account.remaining <= 1);
  }
  if (needLogin) setTimeout(() => authEl.user.focus(), 50);
}

async function refreshAccount() {
  try {
    const res = await fetch('/api/me', { cache: 'no-store' });
    if (res.ok) { account = await res.json(); renderAccount(); }
  } catch { /* offline: keep last known state */ }
}

function setAuthMode(mode) {
  authMode = mode;
  authEl.tabs.querySelectorAll('button').forEach((b) => b.classList.toggle('on', b.dataset.mode === mode));
  authEl.submit.textContent = mode === 'login' ? 'دخول' : 'إنشاء حساب';
  authEl.pass.autocomplete = mode === 'login' ? 'current-password' : 'new-password';
  authEl.err.hidden = true;
}
authEl.tabs.addEventListener('click', (e) => { const b = e.target.closest('button[data-mode]'); if (b) setAuthMode(b.dataset.mode); });

authEl.form.addEventListener('submit', async (e) => {
  e.preventDefault();
  authEl.err.hidden = true;
  authEl.submit.disabled = true;
  try {
    const res = await fetch(authMode === 'login' ? '/api/login' : '/api/register', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: authEl.user.value.trim(), password: authEl.pass.value }),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) { authEl.err.textContent = data.error || `تعذر الدخول (${res.status}).`; authEl.err.hidden = false; return; }
    account = data;
    authEl.pass.value = '';
    renderAccount();
  } catch {
    authEl.err.textContent = 'تعذر الاتصال بالخادم.'; authEl.err.hidden = false;
  } finally { authEl.submit.disabled = false; }
});

authEl.logout.onclick = async () => {
  try { await fetch('/api/logout', { method: 'POST' }); } catch { /* ignore */ }
  await refreshAccount();
};

// Called when the server answers 401 (session expired / not logged in).
function onAuthRequired() { account = { ...account, user: null, authRequired: true }; renderAccount(); }

/* ---------- boot ---------- */

if (!current()) activeId = null;
renderModes();
applyFs();
renderList();
renderMessages();
renderAttachments();
restoreDraft();
loadProjectFor(current());
refreshAccount();

})();
