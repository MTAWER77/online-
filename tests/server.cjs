const http = require('http'), fs = require('fs'), path = require('path');
const pub = path.join(__dirname, '..', 'public');
const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png', '.webmanifest': 'application/manifest+json' };
const state = { log: [], mode: 'ok', failFirst: 0 };
const srv = http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  if (u.pathname === '/__state') { let b = ''; req.on('data', d => b += d); req.on('end', () => { if (b) Object.assign(state, JSON.parse(b)); res.setHeader('content-type', 'application/json'); res.end(JSON.stringify(state)); }); return; }
  if (u.pathname === '/api/me') { res.setHeader('content-type', 'application/json'); res.end(JSON.stringify({ limited: false, unlimited: true, activated: false, remaining: null, limit: null })); return; }
  if (u.pathname === '/api/chat' || u.pathname === '/api/generate-files') {
    let b = ''; req.on('data', d => b += d); req.on('end', () => {
      const body = JSON.parse(b); state.log.push({ path: u.pathname, body });
      const lastUser = body.messages[body.messages.length - 1];
      const txt = typeof lastUser.content === 'string' ? lastUser.content : lastUser.content.map(p => p.text || '').join('');
      if (u.pathname === '/api/generate-files') {
        res.setHeader('content-type', 'application/json');
        return res.end(JSON.stringify({ ok: true, message: 'تم الفحص', findings: [{ file: 'res://scripts/player.gd', line: 14, severity: 'error', issue: 'خلط مسافات', fix: 'وحّدت الإزاحة' }], files: [{ name: 'res://scripts/player.gd', content: 'extends CharacterBody2D\n\nfunc _ready():\n\tpass\n' }], tested: false }));
      }
      if (state.failFirst > 0) { state.failFirst--; res.writeHead(200, { 'content-type': 'text/event-stream' }); res.write('data: {"status":"start"}\n\n'); res.end(); return; }
      res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
      res.write('data: {"status":"start"}\n\n');
      const slow = /slow/.test(txt);
      const who = /AAA/.test(txt) ? 'AAA' : /BBB/.test(txt) ? 'BBB' : 'X';
      if (body.search) res.write('data: {"status":"searching"}\n\n');
      if (body.think && !body.search) res.write('data: {"status":"thinking"}\n\n');
      if (state.mode === 'cut') { res.write('data: ' + JSON.stringify({ t: 'partial text ' + who }) + '\n\n'); res.end(); return; }
      const parts = ['رد ' + who + ' ', '**جزء** ', 'ثاني\n\n', '```gdscript\nfunc a():\n\tpass\n```\n\n', 'خاتمة ' + who];
      let i = 0;
      const tick = () => {
        if (res.destroyed) return;
        if (i < parts.length) { res.write('data: ' + JSON.stringify({ t: parts[i++] }) + '\n\n'); setTimeout(tick, slow ? 600 : 40); }
        else { res.write('data: ' + JSON.stringify({ done: true, finish: 'stop', model: 'm', provider: 'groq', search: !!body.search, think: !!body.think }) + '\n\n'); res.end(); }
      };
      setTimeout(tick, slow ? 300 : 30);
    });
    return;
  }
  let p = u.pathname === '/' ? '/index.html' : u.pathname;
  const f = path.join(pub, p);
  if (!f.startsWith(pub) || !fs.existsSync(f)) { res.writeHead(404); return res.end('nf'); }
  res.writeHead(200, { 'content-type': types[path.extname(f)] || 'application/octet-stream' });
  fs.createReadStream(f).pipe(res);
});
srv.listen(8799, () => console.log('up'));
