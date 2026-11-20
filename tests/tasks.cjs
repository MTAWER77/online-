(function (root) {
'use strict';

/* NOVA Task Manager: splits a long request into small tasks, runs them one by one (each its own API call),
 * verifies every result, keeps progress so a stopped/failed run can be resumed, and never reports "done"
 * unless every task finished. Pure logic (no DOM / fetch) so it can be unit tested in Node. */

const MAX_TASKS = 8;
const LAYERS = [
  ['html', /html|index\.html|واجه|شاشة|قائمة|عنصر/i],
  ['js', /javascript|\bjs\b|app\.js|دالة|منطق|كود|سكربت|script|gd\b|gdscript|لاعب|player/i],
  ['worker', /worker|api|endpoint|سيرفر|خادم|مزود|provider|backend/i],
  ['css', /css|ستايل|تصميم|لون|شكل|دارك|styles/i],
];
const rank = (t) => { for (let i = 0; i < LAYERS.length; i++) if (LAYERS[i][1].test(t)) return i; return LAYERS.length; };

function splitRequest(text) {
  const t = String(text || '').replace(/\r/g, '').trim();
  const lines = t.split('\n').map((x) => x.trim()).filter(Boolean);
  const listed = lines.filter((l) => /^(?:\d+[.)\-–]|[-*•▪●]|[١-٩]+[.)\-])\s*\S/.test(l));
  let parts;
  if (listed.length >= 2) parts = listed.map((l) => l.replace(/^(?:\d+[.)\-–]|[-*•▪●]|[١-٩]+[.)\-])\s*/, ''));
  else if (lines.length >= 3) parts = lines.filter((l) => l.length > 12);
  else parts = t.split(/(?<=[.!؟?؛;])\s+|\s+(?:ثم|وبعدين|وبعد كده|وكمان|و كمان)\s+/).map((x) => x.trim()).filter((x) => x.length > 12);
  return parts;
}

// Returns [] when the request is small enough for a single call.
function plan(text, opts = {}) {
  const t = String(text || '').trim();
  const minChars = opts.minChars || 300;
  const parts = splitRequest(t);
  if (parts.length < 2 || (t.length < minChars && parts.length < 3)) return [];
  let items = parts.map((p, i) => ({ title: p.replace(/\s+/g, ' ').slice(0, 90), prompt: p, i }));
  if (items.length > MAX_TASKS - 1) {
    const head = items.slice(0, MAX_TASKS - 2);
    const tail = items.slice(MAX_TASKS - 2);
    items = head.concat([{ title: 'مهام إضافية (' + tail.length + ')', prompt: tail.map((x) => x.prompt).join('\n'), i: MAX_TASKS - 2 }]);
  }
  items.sort((a, b) => rank(a.prompt) - rank(b.prompt) || a.i - b.i); // stable: HTML -> JS -> Worker -> CSS
  const tasks = items.map((x, n) => ({ id: 't' + (n + 1), title: x.title, prompt: x.prompt, status: 'pending', kind: 'ai' }));
  tasks.push({ id: 't' + (tasks.length + 1), title: 'فحص تكامل التعديلات (آلي)', prompt: '', status: 'pending', kind: 'check' });
  return tasks;
}

const createState = (tasks, original) => ({ tasks: tasks.map((t) => ({ ...t })), status: 'pending', original: String(original || '').slice(0, 3000) });

// exec(task, index, state) -> { files:[{name,content}], findings:[], message } ; check(state) -> [problem strings]
async function run(state, { exec, check, onUpdate, isCancelled }) {
  const emit = () => { try { onUpdate && onUpdate(state); } catch { /* UI errors must not break the run */ } };
  state.status = 'running';
  for (let i = 0; i < state.tasks.length; i++) {
    const t = state.tasks[i];
    if (t.status === 'done') continue;
    if (isCancelled && isCancelled()) { state.status = 'cancelled'; emit(); return state; }
    t.status = 'running'; t.error = ''; emit();
    try {
      if (t.kind === 'check') {
        const problems = (check && (await check(state))) || [];
        if (problems.length) throw new Error(problems.slice(0, 4).join(' | '));
        t.result = { message: 'لا توجد مشاكل Syntax أو مراجع مكسورة ظاهرة (فحص آلي فقط).' };
      } else {
        const r = await exec(t, i, state);
        t.result = r || {}; // a task that finished stays done even if cancel arrived meanwhile
      }
      t.status = 'done';
    } catch (e) {
      if (isCancelled && isCancelled()) { t.status = 'pending'; state.status = 'cancelled'; emit(); return state; }
      t.status = 'failed'; t.error = String((e && e.message) || e).slice(0, 300);
      state.status = 'failed'; emit(); return state; // later tasks may depend on this one: stop, resume continues here
    }
    emit();
  }
  state.status = state.tasks.every((t) => t.status === 'done') ? 'done' : 'failed';
  emit();
  return state;
}

const counts = (s) => ({ total: s.tasks.length, done: s.tasks.filter((t) => t.status === 'done').length, failed: s.tasks.filter((t) => t.status === 'failed').length });
const resumable = (s) => !!s && s.status !== 'done' && s.tasks.some((t) => t.status !== 'done');
const resetForResume = (s) => { s.tasks.forEach((t) => { if (t.status !== 'done') { t.status = 'pending'; t.error = ''; } }); s.status = 'pending'; return s; };

function summary(s) {
  const c = counts(s);
  const icon = { done: '✅', failed: '❌', running: '⏳', pending: '⏸' };
  const head = s.status === 'done' ? `اكتملت كل المهام (${c.done}/${c.total}).`
    : s.status === 'cancelled' ? `تم إلغاء التنفيذ: اكتمل ${c.done} من ${c.total}.`
    : `لم تكتمل المهام: اكتمل ${c.done} من ${c.total}${c.failed ? '، وفشلت ' + c.failed : ''}. استخدم زر «استكمال المهام».`;
  return head + '\n\n' + s.tasks.map((t, i) => `${icon[t.status] || '•'} ${i + 1}. ${t.title}${t.error ? ' — ' + t.error : ''}`).join('\n');
}

const api = { plan, splitRequest, createState, run, counts, resumable, resetForResume, summary, MAX_TASKS };
if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.NovaTasks = api;
})(typeof self !== 'undefined' ? self : this);
