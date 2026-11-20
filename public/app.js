(() => {
'use strict';

const $ = (s) => document.querySelector(s);
const R = window.NovaRender;

const el = {
  sidebar: $('#sidebar'), scrim: $('#scrim'), list: $('#chatList'), msgs: $('#messages'),
  input: $('#input'), form: $('#composer'), send: $('#sendBtn'), title: $('#title'),
  toast: $('#toast'), install: $('#installBtn'), menu: $('#menuBtn'), newChat: $('#newChat'),
  settings: $('#settings'), settingsBtn: $('#settingsBtn'),
  attachBtn: $('#attachBtn'), attachMenu: $('#attachMenu'),
  fileInput: $('#fileInput'), imageInput: $('#imageInput'),
  attachmentTray: $('#attachmentTray'), searchToggle: $('#searchToggle'), thinkToggle: $('#thinkToggle'),
  codeFixToggle: $('#codeFixToggle'),
};

const KEY = 'nova_ai_chats_v1';
const ACTIVE_KEY = 'nova_ai_active_v1';
const SET_KEY = 'nova_ai_settings_v1';
const MAX_CONTEXT = 12;
const MAX_FILES = 5;
const MAX_FILE_SIZE = 1024 * 1024;
const MAX_FILE_CHARS = 20000;
const MAX_IMAGES = 3;
const MAX_IMAGE_EDGE = 1280;
const MAX_IMAGE_QUALITY = 0.82;
const MODEL_STATE_KEY = 'nova_ai_model_state_v1';
const SEARCH_KEY = 'nova_ai_search_enabled_v1';
const THINK_KEY = 'nova_ai_think_enabled_v1';
const CODE_FIX_KEY = 'nova_ai_code_fix_enabled_v1';
const MAX_GENERATED_FILES = 20;

const SUPPORTED_EXTENSIONS = [
  'gd', 'tscn', 'tres', 'gdshader', 'shader',
  'json', 'txt', 'md', 'csv', 'xml',
  'html', 'css', 'js', 'py', 'ini', 'cfg', 'log'
];

let pendingFiles = [];
// Image data is deliberately kept only in memory, never in chat storage/export.
const imageDataStore = new Map();
let searchMode = localStorage.getItem(SEARCH_KEY) === '1';
let thinkMode = localStorage.getItem(THINK_KEY) === '1';
let codeFixMode = localStorage.getItem(CODE_FIX_KEY) === '1';
if (el.codeFixToggle) {
  el.codeFixToggle.classList.toggle('active', codeFixMode);
  el.codeFixToggle.setAttribute('aria-pressed', String(codeFixMode));
  el.codeFixToggle.addEventListener('click', () => {
    codeFixMode = !codeFixMode;
    localStorage.setItem(CODE_FIX_KEY, codeFixMode ? '1' : '0');
    el.codeFixToggle.classList.toggle('active', codeFixMode);
    el.codeFixToggle.setAttribute('aria-pressed', String(codeFixMode));
    if (codeFixMode && el.searchToggle?.classList.contains('active')) el.searchToggle.click();
    toast(codeFixMode ? 'تم تفعيل AI Code Fixer. ارفع ملف الكود واكتب المطلوب.' : 'تم إيقاف AI Code Fixer.');
  });
}
if (el.searchToggle) {
  el.searchToggle.classList.toggle('active', searchMode);
  el.searchToggle.setAttribute('aria-pressed', String(searchMode));
  el.searchToggle.addEventListener('click', () => {
    searchMode = !searchMode;
    if (searchMode) { thinkMode = false; localStorage.setItem(THINK_KEY, '0'); }
    if (el.thinkToggle) { el.thinkToggle.classList.toggle('active', thinkMode); el.thinkToggle.setAttribute('aria-pressed', String(thinkMode)); }
    localStorage.setItem(SEARCH_KEY, searchMode ? '1' : '0');
    el.searchToggle.classList.toggle('active', searchMode);
    el.searchToggle.setAttribute('aria-pressed', String(searchMode));
    toast(searchMode ? 'تم تفعيل البحث على الويب.' : 'تم إيقاف البحث على الويب.');
  });
}
if (el.thinkToggle) {
  el.thinkToggle.classList.toggle('active', thinkMode);
  el.thinkToggle.setAttribute('aria-pressed', String(thinkMode));
  el.thinkToggle.addEventListener('click', () => {
    thinkMode = !thinkMode;
    if (thinkMode) { searchMode = false; localStorage.setItem(SEARCH_KEY, '0'); }
    if (el.searchToggle) { el.searchToggle.classList.toggle('active', searchMode); el.searchToggle.setAttribute('aria-pressed', String(searchMode)); }
    localStorage.setItem(THINK_KEY, thinkMode ? '1' : '0');
    el.thinkToggle.classList.toggle('active', thinkMode);
    el.thinkToggle.setAttribute('aria-pressed', String(thinkMode));
    toast(thinkMode ? 'تم تفعيل وضع التفكير الأعمق.' : 'تم إيقاف وضع التفكير.');
  });
}

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
};

const COPY_HTML = svg(IC.copy, 14) + '<span>نسخ</span>';

const SUGGESTIONS = [
  { h: 'اشرح لي', s: 'الـ closures في JavaScript بمثال بسيط', q: 'اشرح لي الـ closures في JavaScript بمثال بسيط' },
  { h: 'Write code', s: 'A Python function to merge two sorted lists', q: 'Write a Python function to merge two sorted lists, with a short explanation.' },
  { h: 'قارن', s: 'REST مقابل GraphQL في جدول مختصر', q: 'قارن بين REST و GraphQL في جدول مختصر' },
  { h: 'Brainstorm', s: 'Name ideas for a productivity app', q: 'Give me 10 creative name ideas for a productivity app, with a short reason for each.' },
];

const FS = { s: '14.5px', m: '16px', l: '18px' };

let chats = readChats();
let activeId = readStore(ACTIVE_KEY) || null;
let settings = readSettings();
let busy = false, deferredPrompt = null, toastTimer = null;

function readStore(k) {
  try { return localStorage.getItem(k); }
  catch { return null; }
}

function readChats() {
  try {
    const v = JSON.parse(readStore(KEY));
    return Array.isArray(v)
      ? v.filter((c) => c && c.id && Array.isArray(c.messages))
      : [];
  } catch {
    return [];
  }
}

function readSettings() {
  try {
    return Object.assign({ fs: 'm' }, JSON.parse(readStore(SET_KEY)) || {});
  } catch {
    return { fs: 'm' };
  }
}

function save() {
  try {
    localStorage.setItem(KEY, JSON.stringify(chats));
    localStorage.setItem(ACTIVE_KEY, activeId || '');
  } catch {
    toast('تعذر حفظ المحادثات محليًا (الذاكرة ممتلئة أو التخزين معطّل).');
  }
}

function saveSettings() {
  try { localStorage.setItem(SET_KEY, JSON.stringify(settings)); }
  catch { /* ignore */ }
}

const uid = () => Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
const current = () => chats.find((c) => c.id === activeId) || null;

function toast(msg) {
  if (!el.toast) return;
  el.toast.textContent = msg;
  el.toast.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.toast.hidden = true; }, 2800);
}

function mk(tag, cls, html) {
  const d = document.createElement(tag);
  if (cls) d.className = cls;
  if (html != null) d.innerHTML = html;
  return d;
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

function downloadZip(files) {
  if (!Array.isArray(files) || !files.length) return;
  downloadBlob(makeZip(files), 'nova-generated-project.zip');
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

  if (files.length > 1) {
    const zip = mk('button', 'generated-zip', svg(IC.archive, 15) + '<span>تحميل الكل ZIP</span>');
    zip.type = 'button';
    zip.addEventListener('click', () => downloadZip(files));
    wrap.append(zip);
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

function renderAttachments() {
  if (!el.attachmentTray) return;
  el.attachmentTray.innerHTML = '';
  el.attachmentTray.hidden = pendingFiles.length === 0;

  pendingFiles.forEach((file, index) => {
    const item = mk('div', 'attachment-item');
    if (file.kind === 'image' && file.id && imageDataStore.has(file.id)) {
      const thumb = mk('img', 'attachment-thumb');
      thumb.src = imageDataStore.get(file.id);
      thumb.alt = file.name;
      item.append(thumb);
    } else {
      const icon = mk('span', 'attachment-icon', svg(IC.file, 18));
      item.append(icon);
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

function closeAttachMenu() {
  if (el.attachMenu) el.attachMenu.hidden = true;
}

function toggleAttachMenu() {
  if (!el.attachMenu) return;
  el.attachMenu.hidden = !el.attachMenu.hidden;
}

function imageToDataUrl(file) {
  return new Promise((resolve, reject) => {
    if (typeof createImageBitmap !== 'function') {
      const reader = new FileReader();
      reader.onload = () => resolve(reader.result);
      reader.onerror = reject;
      reader.readAsDataURL(file);
      return;
    }
    createImageBitmap(file).then(bitmap => {
      const scale = Math.min(1, MAX_IMAGE_EDGE / Math.max(bitmap.width, bitmap.height));
      const canvas = document.createElement('canvas');
      canvas.width = Math.max(1, Math.round(bitmap.width * scale));
      canvas.height = Math.max(1, Math.round(bitmap.height * scale));
      const ctx = canvas.getContext('2d');
      ctx.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
      bitmap.close?.();
      resolve(canvas.toDataURL('image/jpeg', MAX_IMAGE_QUALITY));
    }).catch(reject);
  });
}

async function handleFiles(fileList, kind) {
  const files = Array.from(fileList || []);
  for (const file of files) {
    if (pendingFiles.length >= MAX_FILES) { toast('يمكنك رفع 5 مرفقات كحد أقصى.'); break; }
    const isImage = file.type.startsWith('image/');
    if (kind === 'image' && !isImage) { toast('اختر صورة صالحة.'); continue; }
    if (kind === 'file' && isImage) { toast('ارفع الصور من خيار رفع الصور.'); continue; }
    if (isImage) {
      if (!['image/jpeg','image/png','image/webp','image/gif'].includes(file.type)) { toast('الصيغ المدعومة: JPG وPNG وWEBP وGIF.'); continue; }
      if (pendingFiles.filter(x => x.kind === 'image').length >= MAX_IMAGES) { toast('يمكنك رفع 3 صور كحد أقصى في الرسالة.'); break; }
      if (file.size > 8 * 1024 * 1024) { toast('حجم الصورة الأصلي يجب ألا يتجاوز 8MB.'); continue; }
      try {
        const id = 'img_' + uid();
        const dataUrl = await imageToDataUrl(file);
        imageDataStore.set(id, dataUrl);
        pendingFiles.push({ id, name:file.name, size:file.size, type:file.type, kind:'image' });
      } catch { toast('تعذر تجهيز الصورة: ' + file.name); }
      continue;
    }
    if (file.size > MAX_FILE_SIZE) { toast('حجم الملف أكبر من 1MB: ' + file.name); continue; }
    const ext = getExtension(file.name);
    if (ext === 'pdf') { toast('قراءة PDF غير مفعّلة حاليًا.'); continue; }
    if (!SUPPORTED_EXTENSIONS.includes(ext)) { toast('نوع الملف غير مدعوم: ' + file.name); continue; }
    try {
      const content = await file.text();
      pendingFiles.push({ id:'txt_' + uid(), name:file.name, size:file.size, type:file.type || 'text/plain', kind:'text', content:content.slice(0,MAX_FILE_CHARS) });
    } catch { toast('تعذر قراءة الملف: ' + file.name); }
  }
  renderAttachments();
}

if (el.attachBtn && el.attachMenu) {
  el.attachBtn.addEventListener('click', (e) => {
    e.preventDefault();
    e.stopPropagation();
    toggleAttachMenu();
  });
  el.attachMenu.addEventListener('click', (e) => {
    const option = e.target.closest('[data-attach]');
    if (!option) return;
    closeAttachMenu();
    if (option.dataset.attach === 'file' && el.fileInput) el.fileInput.click();
    if (option.dataset.attach === 'image' && el.imageInput) el.imageInput.click();
  });
  document.addEventListener('click', (e) => {
    if (!el.attachMenu.contains(e.target) && !el.attachBtn.contains(e.target)) closeAttachMenu();
  });
}

if (el.fileInput) {
  el.fileInput.addEventListener('change', async () => {
    await handleFiles(el.fileInput.files, 'file');
    el.fileInput.value = '';
  });
}
if (el.imageInput) {
  el.imageInput.addEventListener('change', async () => {
    await handleFiles(el.imageInput.files, 'image');
    el.imageInput.value = '';
  });
}

/* ---------- rendering ---------- */

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

  if (message && Array.isArray(message.attachments)) {
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
  r.append(b);
  return r;
}

function rowAI(content, idx, isLast, files, sourceFiles = []) {
  const r = mk('div', 'row ai');
  r.dataset.idx = idx;
  r.innerHTML =
    '<div class="ai-body"><div class="md">' +
    R.md(content, COPY_HTML) +
    '</div><div class="acts">' +
    '<button type="button" class="act" data-act="copy">' +
    svg(IC.copy, 15) + '<span>نسخ الرد</span></button>' +
    (isLast
      ? '<button type="button" class="act" data-act="regen">' +
        svg(IC.refresh, 15) + '<span>إعادة التوليد</span></button>'
      : '') +
    '</div></div>';

  const generated = renderGeneratedFiles(files, sourceFiles);
  if (generated) r.querySelector('.ai-body').append(generated);
  return r;
}

function renderList() {
  el.list.innerHTML = '';
  chats.slice().sort((a, b) => b.updated - a.updated).forEach((c) => {
    const row = mk('div', 'chat-item' + (c.id === activeId ? ' active' : ''));
    const open = mk('button', 'chat-open');
    open.type = 'button';
    open.dir = 'auto';
    open.textContent = c.title;
    open.onclick = () => { select(c.id); closeSide(); };

    const ren = mk('button', 'chat-act', svg(IC.pen));
    ren.type = 'button';
    ren.setAttribute('aria-label', 'إعادة تسمية');
    ren.onclick = () => rename(c.id);

    const del = mk('button', 'chat-act del', svg(IC.trash));
    del.type = 'button';
    del.setAttribute('aria-label', 'حذف المحادثة');
    del.onclick = () => removeChat(c.id);

    row.append(open, ren, del);
    el.list.append(row);
  });
}

function renderMessages() {
  const chat = current();
  el.title.textContent = chat ? chat.title : 'NOVA AI';
  el.msgs.innerHTML = '';

  if (!chat || !chat.messages.length) {
    const w = mk('div', 'welcome',
      '<h2>مرحبًا في <b>NOVA AI</b></h2>' +
      '<p>كيف أقدر أساعدك اليوم؟ · How can I help you today?</p>' +
      '<div class="cards"></div>');
    SUGGESTIONS.forEach((s) => {
      const b = mk('button', 'card', '<b></b><span></span>');
      b.type = 'button';
      b.dir = 'auto';
      b.firstChild.textContent = s.h;
      b.lastChild.textContent = s.s;
      b.onclick = () => submit(s.q);
      w.querySelector('.cards').append(b);
    });
    el.msgs.append(w);
    return;
  }

  const last = chat.messages.length - 1;
  chat.messages.forEach((m, i) => {
    if (m.role === 'user') {
      el.msgs.append(rowUser(m));
    } else {
      const sourceMessage = chat.messages.slice(0, i).reverse().find(x => x.role === 'user' && Array.isArray(x.attachments));
      el.msgs.append(rowAI(m.content, i, i === last, m.files, sourceMessage?.attachments || []));
    }
  });
  scrollDown();
}

function scrollDown() {
  el.msgs.scrollTop = el.msgs.scrollHeight;
}

function addTyping(fileCount, generating = false) {
  const label = generating
    ? 'NOVA يجهّز الملفات…'
    : fileCount > 0
      ? 'NOVA يقرأ ' + fileCount + (fileCount === 1 ? ' ملف' : ' ملفات') + ' ويحللها…'
      : 'NOVA يفكر…';

  const r = mk('div', 'row ai',
    '<div class="ai-body"><div class="think">' +
    '<i></i><i></i><i></i><span>' + label + '</span>' +
    '</div></div>');
  r.dataset.transient = '1';
  el.msgs.append(r);
  scrollDown();
  return r;
}

function showError(text) {
  const r = mk('div', 'row ai');
  r.dataset.transient = '1';
  const body = mk('div', 'ai-body');
  const box = mk('div', 'errbox');
  const t = mk('div');
  t.textContent = '⚠ ' + text;
  const b = mk('button', 'btn small', svg(IC.refresh, 15) + '<span>إعادة المحاولة</span>');
  b.type = 'button';
  b.onclick = () => {
    const c = current();
    if (c) ask(c);
  };
  box.append(t, b);
  body.append(box);
  r.append(body);
  el.msgs.append(r);
  scrollDown();
}

function clearTransient() {
  el.msgs.querySelectorAll('[data-transient]').forEach((n) => n.remove());
}

/* ---------- chats ---------- */

function newChat() {
  const c = { id: uid(), title: 'محادثة جديدة', messages: [], updated: Date.now() };
  chats.push(c);
  activeId = c.id;
  save();
  renderList();
  renderMessages();
  return c;
}

function select(id) {
  if (busy) return toast('انتظر انتهاء الرد الحالي.');
  activeId = id;
  save();
  renderList();
  renderMessages();
}

function rename(id) {
  const c = chats.find((x) => x.id === id);
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
  if (busy) return toast('انتظر انتهاء الرد الحالي.');
  if (!confirm('حذف هذه المحادثة نهائيًا؟')) return;
  chats = chats.filter((c) => c.id !== id);
  if (activeId === id) activeId = null;
  save();
  renderList();
  renderMessages();
}

/* ---------- sending ---------- */

const SEND_ICON = el.send.innerHTML;
const STOP_ICON =
  '<svg viewBox="0 0 24 24" width="18" height="18" fill="currentColor" aria-hidden="true">' +
  '<rect x="6" y="6" width="12" height="12" rx="2.5"/>' +
  '</svg>';

let ctrl = null;
let stopped = false;

function setBusy(v) {
  busy = v;
  el.send.innerHTML = v ? STOP_ICON : SEND_ICON;
  el.send.setAttribute('aria-label', v ? 'إيقاف' : 'إرسال');
}

async function submit(text) {
  text = (text || '').trim();
  if (busy) return;
  if (!text && pendingFiles.length === 0) return;

  const attachments = pendingFiles.map((f) => ({ ...f }));
  if (codeFixMode) {
    const codeFiles = attachments.filter(f => f.kind === 'text');
    if (!codeFiles.length) { toast('ارفع ملف كود نصي أولًا لتشغيل AI Code Fixer.'); return; }
    text = (text ? text + '\n\n' : '') +
      'مهمة AI Code Fixer: حلّل ملفات الكود المرفقة، وحدد الأخطاء والمشاكل الفعلية، واشرح باختصار سببها وما الذي أصلحته. أنشئ ملفًا مصححًا كاملًا لكل ملف يحتاج تعديلًا، مع الحفاظ على أسماء الملفات وواجهات الدوال والسلوك الحالي قدر الإمكان. لا تخترع أخطاء ولا تغيّر أجزاء سليمة بلا داعٍ. إذا لم تجد مشكلة، وضّح ذلك وأعد الملف كما هو دون تغييرات حتى أستطيع تنزيل النسخة التي راجعتها. أعد الملفات الناتجة بصيغة ملفات قابلة للتنزيل.';
  }

  const chat = current() || newChat();
  pendingFiles = [];
  renderAttachments();

  chat.messages.push({ role: 'user', content: text, attachments });
  if (chat.messages.length === 1 && !chat.renamed) {
    chat.title = (text || attachments[0]?.name || 'ملفات مرفقة').slice(0, 40);
  }
  chat.updated = Date.now();
  save();
  renderList();
  renderMessages();
  await ask(chat);
}

function startLive() {
  const row = mk('div', 'row ai streaming',
    '<div class="ai-body"><div class="md"></div></div>');
  el.msgs.append(row);
  return { row, md: row.querySelector('.md') };
}

function buildApiMessages(messages) {
  let imageBudget = MAX_IMAGES;
  return messages.slice(-MAX_CONTEXT).map((m) => {
    let text = m.content || '';
    const parts = [];
    if (m.role === 'user' && Array.isArray(m.attachments)) {
      for (const file of m.attachments) {
        if (file.kind === 'text' && file.content) {
          text += '\n\n--- بداية الملف: ' + file.name + ' ---\n```text\n' + file.content + '\n```\n--- نهاية الملف: ' + file.name + ' ---';
        }
      }
      if (text.trim()) parts.push({type:'text', text});
      for (const file of m.attachments) {
        if (file.kind === 'image' && imageBudget > 0) {
          const data = imageDataStore.get(file.id);
          if (data) { parts.push({type:'image_url', image_url:{url:data}}); imageBudget--; }
          else parts.push({type:'text', text:'[الصورة المرفقة ' + file.name + ' لم تعد متاحة بعد إعادة تحميل الصفحة. أعد رفعها للتحليل.]'});
        }
      }
      return {role:m.role, content:parts.length ? parts : text};
    }
    return {role:m.role, content:text};
  });
}

function readModelState() {
  try { const value = JSON.parse(localStorage.getItem(MODEL_STATE_KEY) || '{}'); return value && typeof value === 'object' ? value : {}; }
  catch { return {}; }
}
function getAvoidModels() {
  const state = readModelState(), now = Date.now();
  return Object.keys(state).filter(model => Number(state[model]?.until || 0) > now);
}
function parseResetSeconds(value) {
  if (!value) return 60;
  const match = String(value).match(/([0-9.]+)\s*(ms|s|m|h)?/i);
  if (!match) return 60;
  const amount = Number(match[1]), unit = (match[2] || 's').toLowerCase();
  return Math.max(30, Math.ceil(amount * (unit === 'ms' ? 0.001 : unit === 'm' ? 60 : unit === 'h' ? 3600 : 1)));
}
function rememberModelLimits(res) {
  const model = res.headers.get('X-NOVA-Model');
  if (!model) return;
  let limits = {}; try { limits = JSON.parse(res.headers.get('X-NOVA-Rate-Limits') || '{}'); } catch {}
  const remainingReq = Number(limits['x-ratelimit-remaining-requests']);
  const remainingTokens = Number(limits['x-ratelimit-remaining-tokens']);
  if ((Number.isFinite(remainingReq) && remainingReq <= 1) || (Number.isFinite(remainingTokens) && remainingTokens <= 1000)) {
    const reset = limits['x-ratelimit-reset-requests'] || limits['x-ratelimit-reset-tokens'] || limits['retry-after'];
    const state = readModelState();
    state[model] = {until:Date.now() + parseResetSeconds(reset) * 1000};
    localStorage.setItem(MODEL_STATE_KEY, JSON.stringify(state));
  }
  console.info('[NOVA] model:', model, limits);
}

function wantsFiles(text) {
  const s = String(text || '').toLowerCase();
  return /(?:اعمل|أنشئ|انشئ|ولّد|ولد|جهّز|جهز|اصنع|ابن(?:ي|اء)?|صدّر|صدر).{0,45}(?:ملف|ملفات|مشروع|zip)|(?:ملف|ملفات|مشروع).{0,35}(?:جاهز|لتحميل|تحميل|zip)|(?:create|generate|make|build|export).{0,50}(?:file|files|project|zip)|(?:file|files|project).{0,35}(?:download|ready|zip)/i.test(s);
}

async function ask(chat) {
  if (busy) return;
  const lastMsg = chat.messages[chat.messages.length - 1];
  if (lastMsg && lastMsg.role === 'user' && (wantsFiles(lastMsg.content) || (codeFixMode && lastMsg.attachments?.some(a => a.kind === 'text')))) {
    return askGenerateFiles(chat);
  }

  setBusy(true);
  clearTransient();

  const fileCount = lastMsg && Array.isArray(lastMsg.attachments)
    ? lastMsg.attachments.length : 0;
  const typing = addTyping(fileCount);

  ctrl = new AbortController();
  stopped = false;
  let idle = 0, live = null, text = '', raf = 0;
  let streamErr = null, finished = false, finish = null, timedOut = false;

  const arm = () => {
    clearTimeout(idle);
    idle = setTimeout(() => { timedOut = true; ctrl.abort(); }, 60000);
  };
  const nearBottom = () =>
    el.msgs.scrollHeight - el.msgs.scrollTop - el.msgs.clientHeight < 140;

  const paint = () => {
    raf = 0;
    if (!live) return;
    const stick = nearBottom();
    live.md.innerHTML = R.md(text, COPY_HTML);
    if (stick) scrollDown();
  };

  const commit = () => {
    if (!text.trim()) {
      typing.remove();
      if (live) live.row.remove();
      return;
    }
    chat.messages.push({ role: 'assistant', content: text });
    chat.updated = Date.now();
    save();
    if (chat.id === activeId) renderMessages();
    renderList();
    if (finish === 'MAX_TOKENS') toast('وصل الرد للحد الأقصى للطول.');
  };

  try {
    arm();
    const res = await fetch('/api/chat', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      signal: ctrl.signal,
      body: JSON.stringify({ messages: buildApiMessages(chat.messages), search: searchMode, think: thinkMode, avoidModels: getAvoidModels() })
    });
    rememberModelLimits(res);
    if (searchMode && lastMsg?.attachments?.some(a => a.kind === 'image')) throw new Error('أوقف البحث على الويب لتحليل الصور.');
    const ct = res.headers.get('content-type') || '';
    if (!res.ok || !ct.includes('text/event-stream') || !res.body) {
      let data = null;
      try { data = await res.json(); } catch {}
      throw new Error((data && data.error) || 'خطأ من الخادم (' + res.status + ').');
    }

    const reader = res.body.getReader();
    const dec = new TextDecoder();
    const parser = R.sseParser((ev) => {
      if (ev.error) streamErr = ev.error;
      else if (typeof ev.t === 'string') {
        if (!live) { typing.remove(); live = startLive(); }
        text += ev.t;
        if (!raf) raf = requestAnimationFrame(paint);
      } else if (ev.done) {
        finished = true;
        finish = ev.finish || null;
      }
    });

    for (;;) {
      arm();
      const { done, value } = await reader.read();
      if (done) break;
      parser.feed(dec.decode(value, { stream: true }));
    }
    parser.feed(dec.decode() + '\n');
    if (streamErr) throw new Error(streamErr);
    if (!finished) throw new Error('انقطع الاتصال أثناء استقبال الرد.');
    if (raf) { cancelAnimationFrame(raf); raf = 0; }
    commit();

  } catch (e) {
    if (raf) { cancelAnimationFrame(raf); raf = 0; }
    if (stopped) {
      commit();
    } else {
      typing.remove();
      let msg = e.message;
      if (timedOut || e.name === 'AbortError') msg = 'تأخر الرد أو انقطع الاتصال. حاول مرة أخرى.';
      else if (!navigator.onLine) msg = 'لا يوجد اتصال بالإنترنت.';
      else if (e instanceof TypeError) msg = 'انقطع الاتصال بالخادم.';
      if (live) {
        live.row.dataset.transient = '1';
        live.row.classList.remove('streaming');
      }
      if (chat.id === activeId) showError(msg);
    }
  } finally {
    clearTimeout(idle);
    if (raf) cancelAnimationFrame(raf);
    ctrl = null;
    setBusy(false);
  }
}

async function askGenerateFiles(chat) {
  setBusy(true);
  clearTransient();
  const typing = addTyping(0, true);
  ctrl = new AbortController();
  stopped = false;
  let timedOut = false;
  let timeout = setTimeout(() => {
    timedOut = true;
    if (ctrl) ctrl.abort();
  }, 90000);

  try {
    const res = await fetch('/api/generate-files', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      signal: ctrl.signal,
      body: JSON.stringify({ messages: buildApiMessages(chat.messages), avoidModels: getAvoidModels() })
    });

    rememberModelLimits(res);
    let data;
    try { data = await res.json(); }
    catch { throw new Error('الخادم أرجع استجابة غير مفهومة.'); }

    if (!res.ok || !data || !Array.isArray(data.files)) {
      throw new Error((data && data.error) || 'تعذر توليد الملفات.');
    }

    const files = data.files
      .filter((f) => f && typeof f.name === 'string' && typeof f.content === 'string')
      .slice(0, MAX_GENERATED_FILES)
      .map((f) => ({ name: safeFileName(f.name), content: f.content }));

    if (!files.length) throw new Error('لم يتم إنشاء أي ملفات صالحة.');

    typing.remove();
    chat.messages.push({
      role: 'assistant',
      content: data.message || 'تم إنشاء الملفات المطلوبة. يمكنك تحميلها من الأسفل.',
      files
    });
    chat.updated = Date.now();
    save();
    renderList();
    if (chat.id === activeId) renderMessages();

  } catch (e) {
    typing.remove();
    let msg = e.message;
    if (timedOut || e.name === 'AbortError') msg = 'استغرق توليد الملفات وقتًا طويلًا أو انقطع الاتصال.';
    else if (!navigator.onLine) msg = 'لا يوجد اتصال بالإنترنت.';
    if (chat.id === activeId) showError(msg);
  } finally {
    clearTimeout(timeout);
    ctrl = null;
    setBusy(false);
  }
}

/* ---------- copy ---------- */

async function copyText(t) {
  try {
    await navigator.clipboard.writeText(t);
    return true;
  } catch {
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
    cb.innerHTML = svg(ok ? IC.check : IC.copy, 14) +
      '<span>' + (ok ? 'تم النسخ' : 'فشل النسخ') + '</span>';
    setTimeout(() => { cb.innerHTML = COPY_HTML; }, 1500);
    return;
  }

  const ab = e.target.closest('[data-act]');
  if (!ab) return;
  const chat = current();
  if (!chat) return;

  if (ab.dataset.act === 'copy') {
    const m = chat.messages[+ab.closest('.row').dataset.idx];
    const ok = m ? await copyText(m.content) : false;
    ab.innerHTML = svg(ok ? IC.check : IC.copy, 15) +
      '<span>' + (ok ? 'تم النسخ' : 'فشل النسخ') + '</span>';
    setTimeout(() => {
      ab.innerHTML = svg(IC.copy, 15) + '<span>نسخ الرد</span>';
    }, 1500);
  } else if (ab.dataset.act === 'regen') {
    if (busy) return;
    if (chat.messages.length && chat.messages[chat.messages.length - 1].role === 'assistant') {
      chat.messages.pop();
    }
    save();
    renderMessages();
    ask(chat);
  }
});

/* ---------- UI events ---------- */

el.form.addEventListener('submit', (e) => {
  e.preventDefault();
  if (busy) {
    if (ctrl) { stopped = true; ctrl.abort(); }
    return;
  }
  const v = el.input.value;
  if (!v.trim() && pendingFiles.length === 0) return;
  el.input.value = '';
  autosize();
  submit(v);
});

el.input.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey && !e.isComposing &&
      window.matchMedia('(pointer:fine)').matches) {
    e.preventDefault();
    if (!busy) el.form.requestSubmit();
  }
});

function autosize() {
  el.input.style.height = 'auto';
  el.input.style.height = Math.min(el.input.scrollHeight, 180) + 'px';
}
el.input.addEventListener('input', autosize);

el.newChat.onclick = () => {
  if (busy) return toast('انتظر انتهاء الرد الحالي.');
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
  if (mq.matches) {
    el.sidebar.classList.add('open');
    el.scrim.classList.add('show');
  } else {
    document.body.classList.toggle('side-collapsed');
  }
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
  if (busy) return toast('انتظر انتهاء الرد الحالي.');
  if (!confirm('حذف كل المحادثات نهائيًا؟')) return;
  chats = [];
  activeId = null;
  save();
  renderList();
  renderMessages();
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

if (!current()) activeId = null;
applyFs();
renderList();
renderMessages();
renderAttachments();

})();