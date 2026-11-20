(function (root) {
'use strict';

/* NOVA PDF reader: pdf.js (self-hosted in /vendor, loaded lazily only when a PDF is attached).
 * - text per page with "=== صفحة N ===" markers (so answers can cite pages)
 * - pages that are scanned / contain images are rendered to JPEG so a vision model can see them (text alone is not trusted)
 * - selectPages() picks the pages relevant to a question so a big PDF never floods the request. */

const MAX_PAGES = 80, MAX_CHARS = 120000, MIN_TEXT = 40;
const MARK = (n) => `=== صفحة ${n} ===`;
const MARK_RE = /^=== صفحة (\d+) ===$/m;
let mod = null;

async function lib() {
  if (mod) return mod;
  mod = await import('/vendor/pdf.min.mjs');
  mod.GlobalWorkerOptions.workerSrc = '/vendor/pdf.worker.min.mjs';
  return mod;
}

function pagesToText(pages) { return pages.map((p) => MARK(p.n) + '\n' + (p.text || '[لا يوجد نص قابل للاستخراج في هذه الصفحة]')).join('\n\n'); }

function parsePages(content) {
  const parts = String(content || '').split(/^(=== صفحة \d+ ===)$/m);
  const out = [];
  for (let i = 1; i < parts.length; i += 2) out.push({ n: Number(/\d+/.exec(parts[i])[0]), text: (parts[i + 1] || '').trim() });
  return out;
}

const words = (s) => new Set((String(s || '').toLowerCase().replace(/[\u064B-\u0652]/g, '').match(/[\p{L}\p{N}_.]{3,}/gu)) || []);

// Chooses pages for this question: first pages always (title/TOC), then best keyword matches, within `budget` chars. Keeps page order.
function selectPages(content, query, budget = 24000) {
  const pages = parsePages(content);
  if (!pages.length) return content;
  const total = pages.reduce((n, p) => n + p.text.length + 20, 0);
  if (total <= budget) return content;
  const q = words(query);
  const scored = pages.map((p, i) => { let s = i === 0 ? 3 : 0; const w = words(p.text); q.forEach((x) => { if (w.has(x)) s += 2; }); const m = /(?:صفحة|page|p\.?)\s*(\d+)/i.exec(query || ''); if (m && Number(m[1]) === p.n) s += 100; return { p, s, i }; });
  scored.sort((a, b) => b.s - a.s || a.i - b.i);
  const chosen = []; let used = 0;
  for (const c of scored) {
    const len = c.p.text.length + 20;
    if (used + len > budget) { if (!chosen.length) chosen.push({ ...c, p: { n: c.p.n, text: c.p.text.slice(0, budget - 40) + '\n…[اختُصرت الصفحة]' } }); continue; }
    chosen.push(c); used += len;
  }
  chosen.sort((a, b) => a.p.n - b.p.n);
  const sent = chosen.map((c) => c.p.n);
  return `[مقتطفات من PDF: أُرسلت الصفحات ${sent.join(', ')} من ${pages.length} صفحة مقروءة. اسأل عن صفحة أو موضوع محدد لعرض صفحات أخرى.]\n\n` + pagesToText(chosen.map((c) => c.p));
}

async function renderPage(page, maxSide = 1400) {
  const vp0 = page.getViewport({ scale: 1 });
  const scale = Math.min(2, maxSide / Math.max(vp0.width, vp0.height));
  const vp = page.getViewport({ scale });
  const canvas = document.createElement('canvas');
  canvas.width = Math.ceil(vp.width); canvas.height = Math.ceil(vp.height);
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, canvas.width, canvas.height);
  await page.render({ canvasContext: ctx, canvas, viewport: vp }).promise;
  const url = canvas.toDataURL('image/jpeg', 0.8);
  canvas.width = canvas.height = 0;
  return url;
}

// -> { pageCount, readPages, text, truncated, scanned:[n], visual:[n], images:[{page,dataUrl}], notes:[] }
async function extract(file, { maxImages = 3 } = {}) {
  const pdfjs = await lib();
  const data = new Uint8Array(await file.arrayBuffer());
  const doc = await pdfjs.getDocument({ data, isEvalSupported: false, useSystemFonts: false }).promise;
  const pages = [], scanned = [], visual = [], notes = [];
  const read = Math.min(doc.numPages, MAX_PAGES);
  let chars = 0, truncated = false;
  const pageObjs = new Map();
  try {
    for (let n = 1; n <= read; n++) {
      const page = await doc.getPage(n);
      const tc = await page.getTextContent();
      let text = tc.items.map((i) => (i.str || '') + (i.hasEOL ? '\n' : '')).join('').replace(/[ \t]+\n/g, '\n').trim();
      let hasImg = false;
      try { const ops = await page.getOperatorList(); hasImg = ops.fnArray.some((f) => f === pdfjs.OPS.paintImageXObject || f === pdfjs.OPS.paintInlineImageXObject || f === pdfjs.OPS.paintImageMaskXObject); } catch { /* optional signal */ }
      if (text.length < MIN_TEXT) scanned.push(n); else if (hasImg) visual.push(n);
      if (chars + text.length > MAX_CHARS) { truncated = true; text = text.slice(0, Math.max(0, MAX_CHARS - chars)); }
      chars += text.length; pages.push({ n, text });
      pageObjs.set(n, page);
      if (truncated) break;
    }
    if (doc.numPages > read) { truncated = true; notes.push(`قُرئت أول ${read} صفحة فقط من ${doc.numPages}.`); }
    if (truncated && !notes.length) notes.push(`تم اقتطاع النص عند صفحة ${pages[pages.length - 1].n} من ${doc.numPages}.`);
    const wanted = scanned.concat(visual).filter((n) => pageObjs.has(n)).slice(0, maxImages);
    const images = [];
    for (const n of wanted) { try { images.push({ page: n, dataUrl: await renderPage(pageObjs.get(n)) }); } catch { notes.push(`تعذر تحويل صفحة ${n} إلى صورة.`); } }
    const skipped = scanned.concat(visual).length - images.length;
    if (skipped > 0) notes.push(`${skipped} صفحة فيها صور/جداول/نص ممسوح لم تُرفق كصور (الحد ${maxImages}). اسأل عن صفحة محددة.`);
    return { pageCount: doc.numPages, readPages: pages.length, text: pagesToText(pages), truncated, scanned, visual, images, notes };
  } finally { try { await doc.destroy(); } catch { /* ignore */ } }
}

const api = { extract, selectPages, parsePages, pagesToText, MARK_RE };
if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.NovaPdf = api;
})(typeof self !== 'undefined' ? self : this);
