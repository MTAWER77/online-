(function (root) {
'use strict';
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

/* ---------- syntax highlighting (tiny, no dependencies) ---------- */
const KW = new Set(('abstract and as async await break case catch class const continue def default defer del do elif else enum except export extends final finally fn for from func function go if implements import in interface is lambda let match mod new not of or package pass private protected pub public raise return self static struct super switch this throw try type typeof use var void while with yield echo fi then done elseif select where using namespace readonly override').split(' '));
const LIT = new Set(['true', 'false', 'null', 'nil', 'None', 'True', 'False', 'undefined', 'NULL', 'NaN']);

function highlight(code, lang) {
  lang = (lang || '').toLowerCase();
  if (/^(html|xml|svg|vue)$/.test(lang)) return hlMarkup(code);
  const hash = /^(py|python|sh|bash|shell|zsh|yaml|yml|rb|ruby|toml|ini|r|perl|pl|dockerfile|makefile)$/.test(lang);
  const slash = !hash && lang !== 'json' && lang !== 'css' && lang !== 'sql';
  const block = hash ? '(?!)' : '\\/\\*[\\s\\S]*?(?:\\*\\/|$)';
  const line = hash ? '#[^\\n]*' : (lang === 'sql' ? '--[^\\n]*' : (slash ? '\\/\\/[^\\n]*' : '(?!)'));
  const re = new RegExp('(' + block + ')|(' + line + ')|("(?:\\\\.|[^"\\\\\\n])*"?|\'(?:\\\\.|[^\'\\\\\\n])*\'?|`(?:\\\\.|[^`\\\\])*`?)|(\\b\\d+(?:\\.\\d+)?\\b)|([A-Za-z_$][\\w$]*)', 'g');
  let out = '', last = 0, m;
  while ((m = re.exec(code))) {
    out += esc(code.slice(last, m.index));
    last = re.lastIndex;
    const t = m[0];
    if (m[1] || m[2]) out += '<span class="tc">' + esc(t) + '</span>';
    else if (m[3]) {
      const isKey = lang === 'json' && /^\s*:/.test(code.slice(last, last + 8));
      out += '<span class="' + (isKey ? 'tp' : 'ts') + '">' + esc(t) + '</span>';
    } else if (m[4]) out += '<span class="tn">' + esc(t) + '</span>';
    else if (m[5]) {
      if (KW.has(t) && lang !== 'json') out += '<span class="tk">' + esc(t) + '</span>';
      else if (LIT.has(t)) out += '<span class="tn">' + esc(t) + '</span>';
      else if (code[last] === '(') out += '<span class="tf">' + esc(t) + '</span>';
      else out += esc(t);
    }
    if (t.length === 0) re.lastIndex++;
  }
  return out + esc(code.slice(last));
}
function hlMarkup(code) {
  const re = /(<!--[\s\S]*?(?:-->|$))|(<\/?[A-Za-z][\w:-]*)|("[^"\n]*"|'[^'\n]*')|(\s[\w:@.-]+(?==))|(\/?>)/g;
  let out = '', last = 0, m;
  while ((m = re.exec(code))) {
    out += esc(code.slice(last, m.index)); last = re.lastIndex;
    const cls = m[1] ? 'tc' : m[2] ? 'tk' : m[3] ? 'ts' : m[4] ? 'tf' : 'tk';
    out += '<span class="' + cls + '">' + esc(m[0]) + '</span>';
  }
  return out + esc(code.slice(last));
}

/* ---------- markdown ---------- */
function inline(s) {
  const codes = [];
  s = s.replace(/`([^`\n]+)`/g, (_, c) => { codes.push(c); return '\u0000' + (codes.length - 1) + '\u0000'; });
  s = esc(s)
    .replace(/\*\*([^\n]+?)\*\*/g, '<strong>$1</strong>')
    .replace(/~~([^\n]+?)~~/g, '<del>$1</del>')
    .replace(/(^|[\s(>])\*([^*\s][^*\n]*?)\*(?=[\s).,!?:;<]|$)/g, '$1<em>$2</em>')
    .replace(/\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)/g, '<a href="$2" target="_blank" rel="noopener noreferrer">$1</a>');
  return s.replace(/\u0000(\d+)\u0000/g, (_, i) => '<code class="ic">' + esc(codes[i]) + '</code>');
}
const isBlockStart = (l) => /^(#{1,6}\s|>|\s*[-*+]\s+|\s*\d+[.)]\s+|\s*([-*_])\s*\2\s*\2)/.test(l);
function blocks(t) {
  const L = t.replace(/\r/g, '').split('\n');
  let h = '', i = 0, m;
  while (i < L.length) {
    const l = L[i];
    if (!l.trim()) { i++; continue; }
    if ((m = l.match(/^(#{1,6})\s+(.*)$/))) { const n = Math.min(m[1].length + 2, 6); h += '<h' + n + ' dir="auto">' + inline(m[2]) + '</h' + n + '>'; i++; continue; }
    if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(l)) { h += '<hr>'; i++; continue; }
    if (l.includes('|') && i + 1 < L.length && L[i + 1].includes('-') && /^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/.test(L[i + 1])) {
      const cells = (r) => r.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map((c) => inline(c.trim()));
      const head = cells(l); i += 2; const rows = [];
      while (i < L.length && L[i].trim() && L[i].includes('|')) { rows.push(cells(L[i])); i++; }
      h += '<div class="tbl" dir="auto"><table><thead><tr>' + head.map((c) => '<th>' + c + '</th>').join('') + '</tr></thead><tbody>' +
        rows.map((r) => '<tr>' + r.map((c) => '<td>' + c + '</td>').join('') + '</tr>').join('') + '</tbody></table></div>';
      continue;
    }
    if (l[0] === '>') {
      const q = [];
      while (i < L.length && L[i][0] === '>') { q.push(L[i].replace(/^>\s?/, '')); i++; }
      h += '<blockquote dir="auto">' + q.map(inline).join('<br>') + '</blockquote>'; continue;
    }
    if ((m = l.match(/^\s*([-*+]|\d+[.)])\s+/))) {
      const ord = /\d/.test(m[1]);
      const re = ord ? /^\s*\d+[.)]\s+/ : /^\s*[-*+]\s+/;
      const items = [];
      while (i < L.length && re.test(L[i])) { items.push(L[i].replace(re, '')); i++; }
      const tag = ord ? 'ol' : 'ul';
      h += '<' + tag + ' dir="auto">' + items.map((x) => '<li>' + inline(x) + '</li>').join('') + '</' + tag + '>'; continue;
    }
    const p = [l]; i++;
    while (i < L.length && L[i].trim() && !isBlockStart(L[i])) { p.push(L[i]); i++; }
    h += '<p dir="auto">' + p.map(inline).join('<br>') + '</p>';
  }
  return h;
}
function codeBlock(lang, code, copyLabel) {
  code = code.replace(/\n$/, '');
  return '<div class="code"><div class="code-head"><span>' + esc(lang || 'code') +
    '</span><button type="button" class="copy" data-copy>' + (copyLabel || 'Copy') + '</button></div><pre><code>' + highlight(code, lang) + '</code></pre></div>';
}
function md(src, copyLabel) {
  const re = /```([\w+#.-]*)[^\n]*\n?([\s\S]*?)(?:```|$)/g;
  let out = '', last = 0, m;
  while ((m = re.exec(src))) {
    out += blocks(src.slice(last, m.index)) + codeBlock(m[1], m[2], copyLabel);
    last = re.lastIndex;
  }
  return out + blocks(src.slice(last));
}

/* ---------- SSE parser (line based, tolerant of split chunks and CRLF) ---------- */
function sseParser(onData) {
  let buf = '';
  return {
    feed(chunk) {
      buf += chunk;
      let i;
      while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i).replace(/\r$/, '');
        buf = buf.slice(i + 1);
        if (line.startsWith('data:')) { try { onData(JSON.parse(line.slice(5).trim())); } catch (e) { /* ignore malformed */ } }
      }
    },
  };
}

const api = { md, highlight, esc, sseParser };
if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.NovaRender = api;
})(typeof self !== 'undefined' ? self : this);
