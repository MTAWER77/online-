(function (root) {
'use strict';

/* NOVA Context Manager: instead of "last N messages", pick the messages that matter for the CURRENT request
 * (recent turns + relevant older turns + pinned requirements), and turn everything dropped into a compact
 * extractive summary that keeps requirements, earlier requests and every file / function / class name.
 * Pure logic (no DOM, no network): deterministic, unit-testable, never rewrites code. */

const STOP = new Set('the and for that this with from have are was but not you your على في من الى إلى عن هذا هذه ده دي دا ذلك التي الذي كان يكون انا انت هو هي مع او أو لو ان إن ما مش لا ايه إيه'.split(' '));
const norm = (s) => String(s || '').toLowerCase().replace(/[\u064B-\u0652\u0640]/g, '').replace(/[أإآ]/g, 'ا').replace(/ى/g, 'ي').replace(/ة/g, 'ه');
function tokens(text) {
  const out = new Set();
  for (const w of norm(text).match(/[\p{L}\p{N}_.]{3,}/gu) || []) { if (!STOP.has(w)) out.add(w.replace(/^\.+|\.+$/g, '')); }
  return out;
}

const BACK_REF = /(كمل|كمّل|تابع|استمر|continue|نفس (?:ال)?(?:نظام|طريقه|طريقة|الشكل|الكود|الملف)|(?:عدّل|عدل|غير|غيّر|اصلح|أصلح|صلح) (?:ده|دا|دي|ده كمان|هذا|هذه|الاخير|الأخير)|الخطا السابق|الخطأ السابق|اللي فات|اللي قبل|السابق|اللي فوق|زي ما|زى ما|as before|same (?:as|way|system)|previous|the above|that one|الكود ده|الملف ده|الدالة دي|الدالة دى)/i;
const PIN = /(لازم|ممنوع|يجب|مطلوب|متطلب|قرار|قررت|دايما|دائما|ابدا|أبدا|مفيش|لا تغير|لا تحذف|لا تستخدم|must|never|always|requirement|do not|don't|should not|decid|rule)/i;
const FILE_RE = /[\w\-./]+\.(?:gd|tscn|tres|gdshader|shader|godot|js|mjs|cjs|ts|py|html|css|json|md|jsonc|cfg|xml|csv)\b/gi;
const FN_RE = /\b(?:func|function|def|class|class_name)\s+([A-Za-z_]\w*)/g;

// 'continue' (short resume), 'back' (refers to earlier work), 'new' (unrelated topic), 'followup' (default)
function classify(text, recent) {
  const t = String(text || '').trim();
  if (!t) return 'followup';
  if (t.length <= 40 && /^(كمل|كمّل|تابع|استمر|continue|go on|وبعدين|طيب|طب)/i.test(t)) return 'continue';
  if (BACK_REF.test(t)) return 'back';
  const q = tokens(t);
  if (recent && recent.length && t.length > 25) {
    const r = tokens(recent.map((m) => m.content || '').join('\n'));
    let hit = 0; q.forEach((w) => { if (r.has(w)) hit++; });
    if (q.size >= 4 && hit === 0 && !/```/.test(t)) return 'new';
  }
  return 'followup';
}

const clip = (s, n) => { s = String(s || '').replace(/\s+/g, ' ').trim(); return s.length > n ? s.slice(0, n - 1) + '…' : s; };
const hasCode = (m) => /```/.test(m.content || '') || (m.files && m.files.length > 0);

function shrink(m, cap) { // keeps head + tail so function signatures at both ends survive
  const c = m.content || '';
  if (c.length <= cap) return m;
  return { ...m, content: c.slice(0, Math.floor(cap * 0.6)) + '\n…[جزء من الرسالة القديمة اختُصر لتوفير المساحة]…\n' + c.slice(-Math.floor(cap * 0.35)), shrunk: true };
}

function summarize(dropped, cap = 3500) {
  if (!dropped.length) return '';
  const pins = [], asks = [], files = new Set(), names = new Set(), delivered = new Set();
  for (const m of dropped) {
    const c = m.content || '';
    (c.match(FILE_RE) || []).forEach((f) => files.add(f));
    for (const x of c.matchAll(FN_RE)) names.add(x[1]);
    (m.files || []).forEach((f) => delivered.add(f));
    if (m.role === 'user') {
      asks.push(clip(c, 150));
      for (const s of c.split(/(?<=[.!؟?\n])\s*/)) if (s.length > 8 && PIN.test(s)) pins.push(clip(s, 220));
    }
  }
  const parts = [`ملخص ${dropped.length} رسالة أقدم (آلي، استخراجي — لم تُرسل نصوصها):`];
  if (pins.length) parts.push('متطلبات وقرارات يجب احترامها:\n' + [...new Set(pins)].slice(-12).map((x) => '- ' + x).join('\n'));
  if (asks.length) parts.push('طلبات المستخدم السابقة:\n' + asks.slice(-10).map((x) => '- ' + x).join('\n'));
  if (files.size) parts.push('ملفات ذُكرت: ' + [...files].slice(-40).join(', '));
  if (delivered.size) parts.push('ملفات سلّمها NOVA سابقًا: ' + [...delivered].slice(-30).join(', '));
  if (names.size) parts.push('دوال/كلاسات ذُكرت: ' + [...names].slice(-60).join(', '));
  return parts.join('\n').slice(0, cap);
}

// messages: [{ id, role:'user'|'assistant', content, files?:[names] }] in chronological order; the last one is the current request.
function select(messages, opts = {}) {
  const budget = opts.budget || 30000, maxMessages = opts.maxMessages || 22, perMsgCap = opts.perMsgCap || 7000;
  const n = messages.length;
  if (n === 0) return { messages: [], summary: '', dropped: 0, mode: 'followup' };
  const last = messages[n - 1];
  const mode = classify(last.content, messages.slice(Math.max(0, n - 5), n - 1));
  const keepTail = mode === 'new' ? 2 : mode === 'back' || mode === 'continue' ? 6 : 4;
  const keep = new Set();
  for (let i = Math.max(0, n - keepTail); i < n; i++) keep.add(i);
  let used = 0; keep.forEach((i) => { used += Math.min(messages[i].content.length, perMsgCap); });

  const q = tokens(last.content);
  const cands = [];
  for (let i = 0; i < n; i++) {
    if (keep.has(i)) continue;
    const m = messages[i];
    let s = (i / n) * 3;
    if (q.size) { const t = tokens(m.content); let hit = 0; q.forEach((w) => { if (t.has(w)) hit++; }); s += Math.min(8, (hit / Math.sqrt(q.size + 1)) * 5); }
    if (m.role === 'user' && PIN.test(m.content || '')) s += 5;
    if (hasCode(m) && (mode === 'back' || mode === 'continue' || /```|\.(gd|js|py|html|css)\b/i.test(last.content))) s += 3;
    if (mode === 'new') s -= 4;
    if (s > 2.5) cands.push({ i, s });
  }
  cands.sort((a, b) => b.s - a.s);
  for (const c of cands) {
    const add = [c.i]; // keep question/answer pairs together
    const pair = messages[c.i].role === 'assistant' ? c.i - 1 : c.i + 1;
    if (pair >= 0 && pair < n && !keep.has(pair) && messages[pair].role !== messages[c.i].role) add.push(pair);
    const cost = add.reduce((x, i) => x + Math.min(messages[i].content.length, perMsgCap), 0);
    if (used + cost > budget || keep.size + add.length > maxMessages) continue;
    add.forEach((i) => keep.add(i)); used += cost;
  }
  let order = [...keep].sort((a, b) => a - b);
  while (order.length > 1 && messages[order[0]].role !== 'user') { keep.delete(order[0]); order = order.slice(1); } // providers expect a user turn first
  const droppedMsgs = messages.filter((_, i) => !keep.has(i));
  return { messages: order.map((i) => shrink(messages[i], perMsgCap)), summary: summarize(droppedMsgs), dropped: droppedMsgs.length, mode };
}

const api = { select, summarize, classify, tokens };
if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.NovaContext = api;
})(typeof self !== 'undefined' ? self : this);
