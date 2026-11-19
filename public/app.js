(() => {
'use strict';
const $ = (s) => document.querySelector(s);
const el = {
  sidebar: $('#sidebar'), scrim: $('#scrim'), list: $('#chatList'), msgs: $('#messages'),
  input: $('#input'), form: $('#composer'), send: $('#sendBtn'), title: $('#title'),
  toast: $('#toast'), install: $('#installBtn'), menu: $('#menuBtn'), newChat: $('#newChat'),
};
const KEY = 'nova_ai_chats_v1', ACTIVE_KEY = 'nova_ai_active_v1', MAX_CONTEXT = 30;
const SUGGESTIONS = ['اشرح لي الـ closures في JavaScript', 'Write a Python function to reverse a string', 'لخّص لي فكرة الـ REST API'];

let chats = readChats();
let activeId = readStore(ACTIVE_KEY) || null;
let busy = false, deferredPrompt = null, toastTimer = null;

function readStore(k) { try { return localStorage.getItem(k); } catch { return null; } }
function readChats() {
  try {
    const v = JSON.parse(readStore(KEY));
    return Array.isArray(v) ? v.filter((c) => c && c.id && Array.isArray(c.messages)) : [];
  } catch { return []; }
}
function save() {
  try { localStorage.setItem(KEY, JSON.stringify(chats)); localStorage.setItem(ACTIVE_KEY, activeId || ''); }
  catch { toast('تعذر حفظ المحادثات محليًا (الذاكرة ممتلئة أو التخزين معطّل).'); }
}
const uid = () => Date.now().toString(36) + Math.random().toString(36).slice(2, 7);
const esc = (s) => s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const current = () => chats.find((c) => c.id === activeId) || null;

function toast(msg) {
  el.toast.textContent = msg; el.toast.hidden = false;
  clearTimeout(toastTimer); toastTimer = setTimeout(() => { el.toast.hidden = true; }, 2800);
}

/* ---------- rendering ---------- */
function inline(s) {
  if (!s.trim()) return '';
  const h = esc(s.trim()).replace(/`([^`\n]+)`/g, '<code class="ic">$1</code>').replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>');
  return '<div class="txt" dir="auto">' + h + '</div>';
}
function renderRich(text) {
  const re = /```([\w+#.-]*)[^\n]*\n?([\s\S]*?)(?:```|$)/g;
  let out = '', last = 0, m;
  while ((m = re.exec(text))) {
    out += inline(text.slice(last, m.index));
    const code = m[2].replace(/\n$/, '');
    out += '<div class="code"><div class="code-head"><span>' + esc(m[1] || 'code') +
      '</span><button type="button" class="copy" data-copy>نسخ</button></div><pre><code>' + esc(code) + '</code></pre></div>';
    last = re.lastIndex;
  }
  return out + inline(text.slice(last));
}
function bubble(role, content) {
  const d = document.createElement('div');
  d.className = 'msg ' + role;
  if (role === 'user') { const t = document.createElement('div'); t.className = 'txt'; t.dir = 'auto'; t.textContent = content; d.append(t); }
  else d.innerHTML = renderRich(content);
  return d;
}
function renderList() {
  el.list.innerHTML = '';
  chats.slice().sort((a, b) => b.updated - a.updated).forEach((c) => {
    const row = document.createElement('div');
    row.className = 'chat-item' + (c.id === activeId ? ' active' : '');
    const open = document.createElement('button');
    open.type = 'button'; open.className = 'chat-open'; open.dir = 'auto'; open.textContent = c.title;
    open.onclick = () => { select(c.id); closeSide(); };
    const del = document.createElement('button');
    del.type = 'button'; del.className = 'chat-del'; del.textContent = '🗑'; del.setAttribute('aria-label', 'حذف المحادثة');
    del.onclick = () => removeChat(c.id);
    row.append(open, del); el.list.append(row);
  });
}
function renderMessages() {
  const chat = current();
  el.title.textContent = chat ? chat.title : 'NOVA AI';
  el.msgs.innerHTML = '';
  if (!chat || !chat.messages.length) {
    const w = document.createElement('div');
    w.className = 'welcome';
    w.innerHTML = '<img src="/icon.svg" alt=""><h2>NOVA AI</h2><p>اسألني أي شيء بالعربية أو English</p><div class="chips"></div>';
    SUGGESTIONS.forEach((s) => {
      const b = document.createElement('button'); b.type = 'button'; b.className = 'chip'; b.textContent = s; b.dir = 'auto';
      b.onclick = () => submit(s); w.querySelector('.chips').append(b);
    });
    el.msgs.append(w); return;
  }
  chat.messages.forEach((m) => el.msgs.append(bubble(m.role, m.content)));
  scrollDown();
}
function scrollDown() { el.msgs.scrollTop = el.msgs.scrollHeight; }
function addTyping() {
  const d = document.createElement('div'); d.className = 'msg assistant typing'; d.dataset.transient = '1';
  d.innerHTML = '<i></i><i></i><i></i>'; el.msgs.append(d); scrollDown(); return d;
}
function showError(text, canRetry) {
  const d = document.createElement('div'); d.className = 'msg error'; d.dataset.transient = '1';
  const t = document.createElement('div'); t.textContent = '⚠ ' + text; d.append(t);
  if (canRetry) {
    const b = document.createElement('button'); b.type = 'button'; b.className = 'btn small retry'; b.textContent = 'إعادة المحاولة';
    b.onclick = () => { const c = current(); if (c) ask(c); }; d.append(b);
  }
  el.msgs.append(d); scrollDown();
}
function clearTransient() { el.msgs.querySelectorAll('[data-transient]').forEach((n) => n.remove()); }

/* ---------- chats ---------- */
function newChat() {
  const c = { id: uid(), title: 'محادثة جديدة', messages: [], updated: Date.now() };
  chats.push(c); activeId = c.id; save(); renderList(); renderMessages(); return c;
}
function select(id) { if (busy) return toast('انتظر انتهاء الرد الحالي.'); activeId = id; save(); renderList(); renderMessages(); }
function removeChat(id) {
  if (busy) return toast('انتظر انتهاء الرد الحالي.');
  if (!confirm('حذف هذه المحادثة نهائيًا؟')) return;
  chats = chats.filter((c) => c.id !== id);
  if (activeId === id) activeId = null;
  save(); renderList(); renderMessages();
}

/* ---------- sending ---------- */
function setBusy(v) { busy = v; el.send.disabled = v; }
async function submit(text) {
  text = (text || '').trim();
  if (busy || !text) return;
  let chat = current() || newChat();
  chat.messages.push({ role: 'user', content: text });
  if (chat.messages.length === 1) chat.title = text.slice(0, 40);
  chat.updated = Date.now(); save(); renderList(); renderMessages();
  await ask(chat);
}
async function ask(chat) {
  if (busy) return;
  setBusy(true); clearTransient();
  const typing = addTyping();
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), 60000);
  try {
    const res = await fetch('/api/chat', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, signal: ctrl.signal,
      body: JSON.stringify({ messages: chat.messages.slice(-MAX_CONTEXT).map(({ role, content }) => ({ role, content })) }),
    });
    let data = null;
    try { data = await res.json(); } catch { /* not json */ }
    if (!res.ok || !data || typeof data.reply !== 'string') throw new Error((data && data.error) || 'خطأ من الخادم (' + res.status + ').');
    chat.messages.push({ role: 'assistant', content: data.reply });
    chat.updated = Date.now(); save();
    if (chat.id === activeId) { renderMessages(); } renderList();
  } catch (e) {
    typing.remove();
    let msg = e.message;
    if (e.name === 'AbortError') msg = 'انتهت مهلة الطلب. حاول مرة أخرى.';
    else if (!navigator.onLine) msg = 'لا يوجد اتصال بالإنترنت.';
    else if (e instanceof TypeError) msg = 'تعذر الاتصال بالخادم.';
    if (chat.id === activeId) showError(msg, true);
  } finally {
    clearTimeout(timer); setBusy(false);
  }
}

/* ---------- events ---------- */
el.form.addEventListener('submit', (e) => {
  e.preventDefault();
  const v = el.input.value; if (!v.trim() || busy) return;
  el.input.value = ''; autosize(); submit(v);
});
el.input.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !e.shiftKey && window.matchMedia('(pointer:fine)').matches) { e.preventDefault(); el.form.requestSubmit(); }
});
function autosize() { el.input.style.height = 'auto'; el.input.style.height = Math.min(el.input.scrollHeight, 160) + 'px'; }
el.input.addEventListener('input', autosize);
el.newChat.onclick = () => { if (busy) return toast('انتظر انتهاء الرد الحالي.'); newChat(); closeSide(); el.input.focus(); };
function closeSide() { el.sidebar.classList.remove('open'); el.scrim.classList.remove('show'); }
el.menu.onclick = () => { el.sidebar.classList.add('open'); el.scrim.classList.add('show'); };
el.scrim.onclick = closeSide;

el.msgs.addEventListener('click', async (e) => {
  const btn = e.target.closest('[data-copy]'); if (!btn) return;
  const code = btn.closest('.code').querySelector('code').textContent;
  let ok = false;
  try { await navigator.clipboard.writeText(code); ok = true; } catch {
    const t = document.createElement('textarea'); t.value = code; t.style.position = 'fixed'; t.style.opacity = '0';
    document.body.append(t); t.select();
    try { ok = document.execCommand('copy'); } catch { ok = false; }
    t.remove();
  }
  btn.textContent = ok ? 'تم النسخ ✓' : 'فشل النسخ';
  setTimeout(() => { btn.textContent = 'نسخ'; }, 1500);
});

window.addEventListener('beforeinstallprompt', (e) => { e.preventDefault(); deferredPrompt = e; el.install.hidden = false; });
el.install.onclick = async () => {
  if (!deferredPrompt) return;
  deferredPrompt.prompt(); await deferredPrompt.userChoice.catch(() => {});
  deferredPrompt = null; el.install.hidden = true;
};
window.addEventListener('appinstalled', () => { el.install.hidden = true; });

if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => { navigator.serviceWorker.register('/sw.js').catch(() => {}); });
}

if (!current()) activeId = null;
renderList(); renderMessages();
})();
