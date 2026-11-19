(() => {
'use strict';
const $ = (s) => document.querySelector(s);
const R = window.NovaRender;
const el = {
  sidebar: $('#sidebar'), scrim: $('#scrim'), list: $('#chatList'), msgs: $('#messages'),
  input: $('#input'), form: $('#composer'), send: $('#sendBtn'), title: $('#title'),
  toast: $('#toast'), install: $('#installBtn'), menu: $('#menuBtn'), newChat: $('#newChat'),
  settings: $('#settings'), settingsBtn: $('#settingsBtn'),
};
const KEY = 'nova_ai_chats_v1', ACTIVE_KEY = 'nova_ai_active_v1', SET_KEY = 'nova_ai_settings_v1', MAX_CONTEXT = 12;
const svg = (d, s = 16) => `<svg viewBox="0 0 24 24" width="${s}" height="${s}" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${d}</svg>`;
const IC = {
  pen: '<path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L7 19l-4 1 1-4Z"/>',
  trash: '<path d="M3 6h18"/><path d="M8 6V4h8v2"/><path d="M19 6l-1 14H6L5 6"/>',
  copy: '<rect x="9" y="9" width="12" height="12" rx="2"/><path d="M5 15V5a2 2 0 0 1 2-2h10"/>',
  check: '<path d="M20 6 9 17l-5-5"/>',
  refresh: '<path d="M21 12a9 9 0 1 1-3-6.7"/><path d="M21 4v5h-5"/>',
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

function readStore(k) { try { return localStorage.getItem(k); } catch { return null; } }
function readChats() {
  try {
    const v = JSON.parse(readStore(KEY));
    return Array.isArray(v) ? v.filter((c) => c && c.id && Array.isArray(c.messages)) : [];
  } catch { return []; }
}
function readSettings() { try { return Object.assign({ fs: 'm' }, JSON.parse(readStore(SET_KEY)) || {}); } catch { return { fs: 'm' }; } }
function save() {
  try { localStorage.setItem(KEY, JSON.stringify(chats)); localStorage.setItem(ACTIVE_KEY, activeId || ''); }
  catch { toast('تعذر حفظ المحادثات محليًا (الذاكرة ممتلئة أو التخزين معطّل).'); }
}
function saveSettings() { try { localStorage.setItem(SET_KEY, JSON.stringify(settings)); } catch { /* ignore */ } }
const uid = () => Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
const current = () => chats.find((c) => c.id === activeId) || null;
function toast(msg) {
  el.toast.textContent = msg; el.toast.hidden = false;
  clearTimeout(toastTimer); toastTimer = setTimeout(() => { el.toast.hidden = true; }, 2800);
}
function mk(tag, cls, html) { const d = document.createElement(tag); if (cls) d.className = cls; if (html != null) d.innerHTML = html; return d; }

/* ---------- rendering ---------- */
function rowUser(text) {
  const r = mk('div', 'row user'), b = mk('div', 'bubble'); b.dir = 'auto'; b.textContent = text; r.append(b); return r;
}
function rowAI(content, idx, isLast) {
  const r = mk('div', 'row ai'); r.dataset.idx = idx;
  r.innerHTML = '<div class="ai-body"><div class="md">' + R.md(content, COPY_HTML) + '</div><div class="acts">' +
    '<button type="button" class="act" data-act="copy">' + svg(IC.copy, 15) + '<span>نسخ الرد</span></button>' +
    (isLast ? '<button type="button" class="act" data-act="regen">' + svg(IC.refresh, 15) + '<span>إعادة التوليد</span></button>' : '') + '</div></div>';
  return r;
}
function renderList() {
  el.list.innerHTML = '';
  chats.slice().sort((a, b) => b.updated - a.updated).forEach((c) => {
    const row = mk('div', 'chat-item' + (c.id === activeId ? ' active' : ''));
    const open = mk('button', 'chat-open'); open.type = 'button'; open.dir = 'auto'; open.textContent = c.title;
    open.onclick = () => { select(c.id); closeSide(); };
    const ren = mk('button', 'chat-act', svg(IC.pen)); ren.type = 'button'; ren.setAttribute('aria-label', 'إعادة تسمية'); ren.onclick = () => rename(c.id);
    const del = mk('button', 'chat-act del', svg(IC.trash)); del.type = 'button'; del.setAttribute('aria-label', 'حذف المحادثة'); del.onclick = () => removeChat(c.id);
    row.append(open, ren, del); el.list.append(row);
  });
}
function renderMessages() {
  const chat = current();
  el.title.textContent = chat ? chat.title : 'NOVA AI';
  el.msgs.innerHTML = '';
  if (!chat || !chat.messages.length) {
    const w = mk('div', 'welcome', '<h2>مرحبًا في <b>NOVA AI</b></h2><p>كيف أقدر أساعدك اليوم؟ · How can I help you today?</p><div class="cards"></div>');
    SUGGESTIONS.forEach((s) => {
      const b = mk('button', 'card', '<b></b><span></span>'); b.type = 'button'; b.dir = 'auto';
      b.firstChild.textContent = s.h; b.lastChild.textContent = s.s; b.onclick = () => submit(s.q);
      w.querySelector('.cards').append(b);
    });
    el.msgs.append(w); return;
  }
  const last = chat.messages.length - 1;
  chat.messages.forEach((m, i) => el.msgs.append(m.role === 'user' ? rowUser(m.content) : rowAI(m.content, i, i === last)));
  scrollDown();
}
function scrollDown() { el.msgs.scrollTop = el.msgs.scrollHeight; }
function addTyping() {
  const r = mk('div', 'row ai', '<div class="ai-body"><div class="think"><i></i><i></i><i></i><span>NOVA يفكر…</span></div></div>');
  r.dataset.transient = '1'; el.msgs.append(r); scrollDown(); return r;
}
function showError(text) {
  const r = mk('div', 'row ai'); r.dataset.transient = '1';
  const body = mk('div', 'ai-body'), box = mk('div', 'errbox'), t = mk('div'); t.textContent = '⚠ ' + text;
  const b = mk('button', 'btn small', svg(IC.refresh, 15) + '<span>إعادة المحاولة</span>'); b.type = 'button';
  b.onclick = () => { const c = current(); if (c) ask(c); };
  box.append(t, b); body.append(box); r.append(body); el.msgs.append(r); scrollDown();
}
function clearTransient() { el.msgs.querySelectorAll('[data-transient]').forEach((n) => n.remove()); }

/* ---------- chats ---------- */
function newChat() {
  const c = { id: uid(), title: 'محادثة جديدة', messages: [], updated: Date.now() };
  chats.push(c); activeId = c.id; save(); renderList(); renderMessages(); return c;
}
function select(id) { if (busy) return toast('انتظر انتهاء الرد الحالي.'); activeId = id; save(); renderList(); renderMessages(); }
function rename(id) {
  const c = chats.find((x) => x.id === id); if (!c) return;
  const n = prompt('اسم المحادثة:', c.title);
  if (n && n.trim()) { c.title = n.trim().slice(0, 60); c.renamed = true; save(); renderList(); if (id === activeId) el.title.textContent = c.title; }
}
function removeChat(id) {
  if (busy) return toast('انتظر انتهاء الرد الحالي.');
  if (!confirm('حذف هذه المحادثة نهائيًا؟')) return;
  chats = chats.filter((c) => c.id !== id);
  if (activeId === id) activeId = null;
  save(); renderList(); renderMessages();
}

/* ---------- sending ---------- */
const SEND_ICON = el.send.innerHTML;
const STOP_ICON = '<svg viewBox="0 0 24 24" width="18" height="18" fill="currentColor" aria-hidden="true"><rect x="6" y="6" width="12" height="12" rx="2.5"/></svg>';
let ctrl = null, stopped = false;
function setBusy(v) { busy = v; el.send.innerHTML = v ? STOP_ICON : SEND_ICON; el.send.setAttribute('aria-label', v ? 'إيقاف' : 'إرسال'); }
async function submit(text) {
  text = (text || '').trim();
  if (busy || !text) return;
  const chat = current() || newChat();
  chat.messages.push({ role: 'user', content: text });
  if (chat.messages.length === 1 && !chat.renamed) chat.title = text.slice(0, 40);
  chat.updated = Date.now(); save(); renderList(); renderMessages();
  await ask(chat);
}
function startLive() {
  const row = mk('div', 'row ai streaming', '<div class="ai-body"><div class="md"></div></div>');
  el.msgs.append(row); return { row, md: row.querySelector('.md') };
}
async function ask(chat) {
  if (busy) return;
  setBusy(true); clearTransient();
  const typing = addTyping();
  ctrl = new AbortController(); stopped = false;
  let idle = 0, live = null, text = '', raf = 0, streamErr = null, finished = false, finish = null, timedOut = false;
  const arm = () => { clearTimeout(idle); idle = setTimeout(() => { timedOut = true; ctrl.abort(); }, 60000); };
  const nearBottom = () => el.msgs.scrollHeight - el.msgs.scrollTop - el.msgs.clientHeight < 140;
  const paint = () => { raf = 0; if (!live) return; const stick = nearBottom(); live.md.innerHTML = R.md(text, COPY_HTML); if (stick) scrollDown(); };
  const commit = () => {
    if (!text.trim()) { typing.remove(); if (live) live.row.remove(); return; }
    chat.messages.push({ role: 'assistant', content: text });
    chat.updated = Date.now(); save();
    if (chat.id === activeId) renderMessages();
    renderList();
    if (finish === 'MAX_TOKENS') toast('وصل الرد للحد الأقصى للطول.');
  };
  try {
    arm();
    const res = await fetch('/api/chat', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, signal: ctrl.signal,
      body: JSON.stringify({ messages: chat.messages.slice(-MAX_CONTEXT).map(({ role, content }) => ({ role, content })) }),
    });
    const ct = res.headers.get('content-type') || '';
    if (!res.ok || !ct.includes('text/event-stream') || !res.body) {
      let data = null;
      try { data = await res.json(); } catch { /* not json */ }
      throw new Error((data && data.error) || 'خطأ من الخادم (' + res.status + ').');
    }
    const reader = res.body.getReader(), dec = new TextDecoder();
    const parser = R.sseParser((ev) => {
      if (ev.error) streamErr = ev.error;
      else if (typeof ev.t === 'string') {
        if (!live) { typing.remove(); live = startLive(); }
        text += ev.t;
        if (!raf) raf = requestAnimationFrame(paint);
      } else if (ev.done) { finished = true; finish = ev.finish || null; }
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
    commit();
  } catch (e) {
    if (raf) { cancelAnimationFrame(raf); raf = 0; }
    if (stopped) commit();
    else {
      typing.remove();
      let msg = e.message;
      if (timedOut || e.name === 'AbortError') msg = 'تأخر الرد أو انقطع الاتصال. حاول مرة أخرى.';
      else if (!navigator.onLine) msg = 'لا يوجد اتصال بالإنترنت.';
      else if (e instanceof TypeError) msg = 'انقطع الاتصال بالخادم.';
      if (live) { live.row.dataset.transient = '1'; live.row.classList.remove('streaming'); }
      if (chat.id === activeId) showError(msg);
    }
  } finally {
    clearTimeout(idle); if (raf) cancelAnimationFrame(raf);
    ctrl = null; setBusy(false);
  }
}

/* ---------- copy ---------- */
async function copyText(t) {
  try { await navigator.clipboard.writeText(t); return true; } catch {
    const a = document.createElement('textarea'); a.value = t; a.style.cssText = 'position:fixed;opacity:0';
    document.body.append(a); a.select();
    let ok = false; try { ok = document.execCommand('copy'); } catch { ok = false; }
    a.remove(); return ok;
  }
}
el.msgs.addEventListener('click', async (e) => {
  const cb = e.target.closest('[data-copy]');
  if (cb) {
    const ok = await copyText(cb.closest('.code').querySelector('code').textContent);
    cb.innerHTML = svg(ok ? IC.check : IC.copy, 14) + '<span>' + (ok ? 'تم النسخ' : 'فشل النسخ') + '</span>';
    setTimeout(() => { cb.innerHTML = COPY_HTML; }, 1500); return;
  }
  const ab = e.target.closest('[data-act]'); if (!ab) return;
  const chat = current(); if (!chat) return;
  if (ab.dataset.act === 'copy') {
    const m = chat.messages[+ab.closest('.row').dataset.idx];
    const ok = m ? await copyText(m.content) : false;
    ab.innerHTML = svg(ok ? IC.check : IC.copy, 15) + '<span>' + (ok ? 'تم النسخ' : 'فشل النسخ') + '</span>';
    setTimeout(() => { ab.innerHTML = svg(IC.copy, 15) + '<span>نسخ الرد</span>'; }, 1500);
  } else if (ab.dataset.act === 'regen') {
    if (busy) return;
    if (chat.messages.length && chat.messages[chat.messages.length - 1].role === 'assistant') chat.messages.pop();
    save(); renderMessages(); ask(chat);
  }
});

/* ---------- UI events ---------- */
el.form.addEventListener('submit', (e) => {
  e.preventDefault();
  if (busy) { if (ctrl) { stopped = true; ctrl.abort(); } return; }
  const v = el.input.value; if (!v.trim()) return;
  el.input.value = ''; autosize(); submit(v);
});
el.input.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey && !e.isComposing && window.matchMedia('(pointer:fine)').matches) { e.preventDefault(); if (!busy) el.form.requestSubmit(); }
});
function autosize() { el.input.style.height = 'auto'; el.input.style.height = Math.min(el.input.scrollHeight, 180) + 'px'; }
el.input.addEventListener('input', autosize);
el.newChat.onclick = () => { if (busy) return toast('انتظر انتهاء الرد الحالي.'); newChat(); closeSide(); el.input.focus(); };
const mq = window.matchMedia('(max-width:760px)');
function closeSide() { el.sidebar.classList.remove('open'); el.scrim.classList.remove('show'); }
el.menu.onclick = () => {
  if (mq.matches) { el.sidebar.classList.add('open'); el.scrim.classList.add('show'); }
  else document.body.classList.toggle('side-collapsed');
};
el.scrim.onclick = closeSide;

/* settings */
function applyFs() {
  document.documentElement.style.setProperty('--fs', FS[settings.fs] || FS.m);
  document.querySelectorAll('#fontSeg button').forEach((b) => b.classList.toggle('on', b.dataset.fs === settings.fs));
}
el.settingsBtn.onclick = () => { closeSide(); applyFs(); el.settings.showModal(); };
$('#closeSettings').onclick = () => el.settings.close();
el.settings.addEventListener('click', (e) => { if (e.target === el.settings) el.settings.close(); });
$('#fontSeg').addEventListener('click', (e) => { const b = e.target.closest('[data-fs]'); if (b) { settings.fs = b.dataset.fs; saveSettings(); applyFs(); } });
$('#exportBtn').onclick = () => {
  const blob = new Blob([JSON.stringify(chats, null, 2)], { type: 'application/json' });
  const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = 'nova-ai-chats.json';
  document.body.append(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(a.href), 1000);
};
$('#clearBtn').onclick = () => {
  if (busy) return toast('انتظر انتهاء الرد الحالي.');
  if (!confirm('حذف كل المحادثات نهائيًا؟')) return;
  chats = []; activeId = null; save(); renderList(); renderMessages(); el.settings.close();
};

/* PWA */
window.addEventListener('beforeinstallprompt', (e) => { e.preventDefault(); deferredPrompt = e; el.install.hidden = false; });
el.install.onclick = async () => {
  if (!deferredPrompt) return;
  deferredPrompt.prompt(); await deferredPrompt.userChoice.catch(() => {});
  deferredPrompt = null; el.install.hidden = true;
};
window.addEventListener('appinstalled', () => { el.install.hidden = true; });
if ('serviceWorker' in navigator) window.addEventListener('load', () => { navigator.serviceWorker.register('/sw.js').catch(() => {}); });

if (!current()) activeId = null;
applyFs(); renderList(); renderMessages();
})();
