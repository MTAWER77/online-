(function (root) {
'use strict';

/* NOVA Godot Project Context
 * - reads a project from a folder FileList or a .zip (no dependencies)
 * - parses project.godot / .gd / .tscn / .tres / .gdshader (lightweight, static)
 * - builds a reference graph, runs static checks, and selects only the relevant files for a request
 * Everything here is static analysis: nothing is ever executed or tested inside Godot.
 */

const TEXT_EXT = new Set(['gd', 'tscn', 'tres', 'gdshader', 'shader', 'godot', 'cfg', 'json', 'md', 'txt', 'csv', 'import', 'gdextension',
  'py', 'js', 'ts', 'jsx', 'tsx', 'html', 'css', 'xml', 'yml', 'yaml', 'toml', 'ini', 'sh', 'c', 'cpp', 'h', 'cs', 'java', 'rs', 'go', 'php', 'sql', 'svg', 'log']);
const SKIP_EXT_IMPORT = new Set(['import']); // generated metadata, never useful as context
const IGNORED_DIRS = ['.git', '.godot', '.import', 'node_modules', '.vscode', '.idea', 'android/build', 'build'];
const LIMITS = { maxFiles: 4000, maxTextFileBytes: 400 * 1024, maxTotalTextBytes: 12 * 1024 * 1024, maxZipEntryBytes: 2 * 1024 * 1024 };

const extOf = (p) => { const m = /\.([A-Za-z0-9]+)$/.exec(p); return m ? m[1].toLowerCase() : ''; };
const base = (p) => p.split('/').pop();
const hash = (s) => { let h = 0x811c9dc5; for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); } return (h >>> 0).toString(36); };

function normPath(p) {
  return String(p || '').replace(/\\/g, '/').replace(/^\.?\//, '').split('/').filter((x) => x && x !== '.' && x !== '..').join('/');
}
const isIgnored = (p) => IGNORED_DIRS.some((d) => p === d || p.startsWith(d + '/') || p.includes('/' + d + '/'));
const isThirdParty = (p) => p.startsWith('addons/');

/* ---------------- zip reader (stored + deflate) ---------------- */

async function inflateRaw(bytes) {
  if (typeof DecompressionStream !== 'function') throw new Error('هذا المتصفح لا يدعم فك ضغط ZIP.');
  const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream('deflate-raw'));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

async function readZip(buffer) {
  const u8 = new Uint8Array(buffer);
  const dv = new DataView(buffer);
  let eocd = -1;
  for (let i = u8.length - 22; i >= Math.max(0, u8.length - 65557); i--) {
    if (dv.getUint32(i, true) === 0x06054b50) { eocd = i; break; }
  }
  if (eocd < 0) throw new Error('ملف ZIP غير صالح.');
  const total = dv.getUint16(eocd + 10, true);
  let ptr = dv.getUint32(eocd + 16, true);
  if (total === 0xffff || ptr === 0xffffffff) throw new Error('ملفات ZIP64 الكبيرة غير مدعومة.');
  const dec = new TextDecoder('utf-8');
  const entries = [];
  for (let i = 0; i < total; i++) {
    if (dv.getUint32(ptr, true) !== 0x02014b50) break;
    const flags = dv.getUint16(ptr + 8, true);
    const method = dv.getUint16(ptr + 10, true);
    const csize = dv.getUint32(ptr + 20, true);
    const usize = dv.getUint32(ptr + 24, true);
    const nlen = dv.getUint16(ptr + 28, true), elen = dv.getUint16(ptr + 30, true), clen = dv.getUint16(ptr + 32, true);
    const lho = dv.getUint32(ptr + 42, true);
    const name = dec.decode(u8.subarray(ptr + 46, ptr + 46 + nlen));
    ptr += 46 + nlen + elen + clen;
    if (name.endsWith('/')) continue;
    entries.push({ name, method, csize, usize, lho, encrypted: !!(flags & 1) });
  }
  return {
    entries,
    async read(entry) {
      const lnlen = dv.getUint16(entry.lho + 26, true), lelen = dv.getUint16(entry.lho + 28, true);
      const start = entry.lho + 30 + lnlen + lelen;
      const raw = u8.subarray(start, start + entry.csize);
      if (entry.method === 0) return raw;
      if (entry.method === 8) return inflateRaw(raw);
      throw new Error('طريقة ضغط غير مدعومة');
    },
  };
}

/* ---------------- ingestion ---------------- */

function stripCommonRoot(paths) {
  // Folder pickers / zips usually wrap the project in one top folder. Prefer the folder holding project.godot.
  const pg = paths.find((p) => /(^|\/)project\.godot$/.test(p));
  if (pg) { const idx = pg.lastIndexOf('/'); return idx < 0 ? '' : pg.slice(0, idx + 1); }
  const first = paths[0] ? paths[0].split('/')[0] : '';
  return first && paths.every((p) => p.startsWith(first + '/')) ? first + '/' : '';
}

/** Turns raw candidates [{path,size,read():Promise<string|null>|text}] into a project. */
async function ingest(candidates, { onProgress } = {}) {
  const all = candidates.map((c) => ({ ...c, path: normPath(c.path) })).filter((c) => c.path && !isIgnored(c.path));
  const prefix = stripCommonRoot(all.map((c) => c.path));
  const files = new Map();
  const skipped = [];
  const allPaths = new Set();
  let totalBytes = 0, assetCount = 0;

  let list = all.map((c) => ({ ...c, path: c.path.slice(prefix.length) })).filter((c) => c.path);
  if (list.length > LIMITS.maxFiles) {
    skipped.push({ path: '(project)', reason: `المشروع فيه ${list.length} ملف؛ تم أخذ أول ${LIMITS.maxFiles} فقط.` });
    list = list.slice(0, LIMITS.maxFiles);
  }

  let done = 0;
  for (const c of list) {
    allPaths.add(c.path);
    const ext = extOf(c.path);
    done++;
    if (onProgress && done % 40 === 0) onProgress(done, list.length);
    if (!TEXT_EXT.has(ext) || SKIP_EXT_IMPORT.has(ext)) { if (!TEXT_EXT.has(ext)) assetCount++; continue; }
    if (isThirdParty(c.path)) { skipped.push({ path: c.path, reason: 'إضافة خارجية (addons) - لم تُقرأ لتوفير الحجم' }); continue; }
    if (c.size > LIMITS.maxTextFileBytes) { skipped.push({ path: c.path, reason: `أكبر من ${Math.round(LIMITS.maxTextFileBytes / 1024)}KB` }); continue; }
    if (totalBytes + c.size > LIMITS.maxTotalTextBytes) { skipped.push({ path: c.path, reason: 'تجاوز الحد الكلي لحجم النصوص' }); continue; }
    let text;
    try { text = typeof c.text === 'string' ? c.text : await c.read(); } catch (e) { skipped.push({ path: c.path, reason: 'تعذرت القراءة: ' + (e.message || 'خطأ') }); continue; }
    if (typeof text !== 'string') { skipped.push({ path: c.path, reason: 'ليس نصًا قابلًا للقراءة' }); continue; }
    if (text.includes('\u0000')) { skipped.push({ path: c.path, reason: 'ملف ثنائي' }); continue; }
    totalBytes += c.size;
    files.set(c.path, { path: c.path, ext, size: c.size, text, hash: hash(text), lines: text.split('\n').length });
  }
  const p = { name: 'project', files, skipped, allPaths, assetCount };
  analyze(p);
  return p;
}

async function readZipProject(file, opts) {
  const zip = await readZip(await file.arrayBuffer());
  const dec = new TextDecoder('utf-8', { fatal: true });
  const candidates = zip.entries.map((e) => ({
    path: e.name, size: e.usize,
    read: async () => {
      if (e.encrypted) throw new Error('ملف مشفّر');
      if (e.usize > LIMITS.maxZipEntryBytes) throw new Error('كبير جدًا');
      try { return dec.decode(await zip.read(e)); } catch (err) { if (err.name === 'TypeError') return null; throw err; }
    },
  }));
  const p = await ingest(candidates, opts);
  if (!p.info.name) p.name = file.name.replace(/\.zip$/i, '');
  return p;
}

async function readFolderProject(fileList, opts) {
  const dec = new TextDecoder('utf-8', { fatal: true });
  const arr = Array.from(fileList || []);
  const candidates = arr.map((f) => ({
    path: f.webkitRelativePath || f.name, size: f.size,
    read: async () => { try { return dec.decode(await f.arrayBuffer()); } catch (e) { if (e.name === 'TypeError') return null; throw e; } },
  }));
  const p = await ingest(candidates, opts);
  const top = arr[0]?.webkitRelativePath?.split('/')[0];
  if (top && !p.info.name) p.name = top;
  return p;
}

/* ---------------- parsers ---------------- */

function attrs(line) {
  const out = {};
  const re = /([A-Za-z_]+)=("(?:[^"\\]|\\.)*"|[^\s\]]+)/g;
  let m;
  while ((m = re.exec(line))) out[m[1]] = m[2].startsWith('"') ? m[2].slice(1, -1) : m[2];
  return out;
}
const extId = (v) => { const m = /ExtResource\(\s*"?([^")]+)"?\s*\)/.exec(v || ''); return m ? m[1] : null; };
const resPaths = (text) => { const out = []; const re = /"(res:\/\/[^"\n]+)"/g; let m; while ((m = re.exec(text))) out.push(m[1]); return out; };
const toRel = (p) => p.replace(/^res:\/\//, '');

function parseScene(text) {
  const lines = text.split('\n');
  const scene = { ext: {}, nodes: [], connections: [], rootType: null };
  let cur = null;
  const finish = () => { if (cur) scene.nodes.push(cur); cur = null; };
  for (const line of lines) {
    if (line.startsWith('[ext_resource')) {
      const a = attrs(line);
      if (a.id) scene.ext[a.id] = { type: a.type || '', path: a.path || '' };
    } else if (line.startsWith('[node')) {
      finish();
      const a = attrs(line);
      let path;
      if (a.parent === undefined) path = '.';
      else if (a.parent === '.') path = a.name;
      else path = a.parent + '/' + a.name;
      cur = { name: a.name, type: a.type || '', parent: a.parent, path, script: null, instance: a.instance ? extId(a.instance) : null, unique: false };
      if (a.parent === undefined) scene.rootType = a.type || (a.instance ? 'instance' : '');
    } else if (line.startsWith('[connection')) {
      finish();
      const a = attrs(line);
      scene.connections.push({ signal: a.signal, from: a.from, to: a.to, method: a.method });
    } else if (line.startsWith('[')) {
      finish();
    } else if (cur) {
      let m;
      if ((m = /^script\s*=\s*(.+)$/.exec(line))) cur.script = extId(m[1]);
      else if (/^unique_name_in_owner\s*=\s*true/.test(line)) cur.unique = true;
    }
  }
  finish();
  for (const n of scene.nodes) {
    n.scriptPath = n.script && scene.ext[n.script] ? toRel(scene.ext[n.script].path) : null;
    n.instancePath = n.instance && scene.ext[n.instance] ? toRel(scene.ext[n.instance].path) : null;
  }
  return scene;
}

function stripComment(line) {
  let q = null;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (q) { if (c === '\\') i++; else if (c === q) q = null; }
    else if (c === '"' || c === "'") q = c;
    else if (c === '#') return line.slice(0, i);
  }
  return line;
}

function parseScript(text) {
  const s = { extends: '', className: '', funcs: [], signals: [], nodeRefs: [], uniqueRefs: [], handlers: [], resRefs: [], legacy: [] };
  const lines = text.split('\n');
  let m;
  lines.forEach((raw, i) => {
    const line = stripComment(raw);
    const n = i + 1;
    if (!s.extends && (m = /^\s*extends\s+("?[^\s"]+"?)/.exec(line))) s.extends = m[1].replace(/"/g, '');
    if (!s.className && (m = /^\s*class_name\s+([A-Za-z_]\w*)/.exec(line))) s.className = m[1];
    if ((m = /^\s*(?:static\s+)?func\s+([A-Za-z_]\w*)/.exec(line))) s.funcs.push({ name: m[1], line: n });
    if ((m = /^\s*signal\s+([A-Za-z_]\w*)/.exec(line))) s.signals.push(m[1]);
    const nodeRe = /\$(?:"([^"]+)"|([A-Za-z0-9_\/]+))|get_node(?:_or_null)?\(\s*"([^"]+)"\s*\)/g;
    while ((m = nodeRe.exec(line))) {
      const p = m[1] || m[2] || m[3];
      if (p && !p.startsWith('/') && !p.includes('..') && !/^(res|user):/.test(p)) s.nodeRefs.push({ path: p, line: n });
    }
    const uRe = /%([A-Za-z_]\w*)/g;
    // "%" is also the modulo/format operator: only treat it as unique-node access right after $, get_node( or whitespace+( )
    const uniq = /(?:^|[\s(=,])%([A-Za-z_]\w*)(?=[.\s)\[,]|$)/g;
    while ((m = uniq.exec(line))) { if (!/"[^"]*%[^"]*"/.test(line)) s.uniqueRefs.push({ name: m[1], line: n }); }
    void uRe;
    const conn = /\.connect\(\s*(?:self\s*,\s*)?(?:"[^"]+"\s*,\s*[^,]+,\s*"([A-Za-z_]\w*)"|(?:self\.)?([A-Za-z_]\w*)(?=\s*[,)\.]))/g;
    while ((m = conn.exec(line))) { const h = m[1] || m[2]; if (h && !/^(func|bind|callv?)$/.test(h)) s.handlers.push({ name: h, line: n, bare: !!m[2] }); }
    for (const p of resPaths(line)) s.resRefs.push({ path: toRel(p), line: n });
    // Godot 3 leftovers in a Godot 4 project
    if (/\byield\s*\(/.test(line)) s.legacy.push({ line: n, what: 'yield() قديم (Godot 3). استخدم await في Godot 4.' });
    if (/^\s*onready\s+var\b/.test(line)) s.legacy.push({ line: n, what: 'onready var قديم. استخدم @onready var.' });
    if (/^\s*export(\s*\(|\s+var)\b/.test(line)) s.legacy.push({ line: n, what: 'export قديمة. استخدم @export.' });
    if (/\.instance\(\)/.test(line)) s.legacy.push({ line: n, what: '.instance() قديم. استخدم .instantiate().' });
    if (/\bconnect\(\s*"[^"]+"\s*,/.test(line)) s.legacy.push({ line: n, what: 'connect("signal", obj, "method") قديم. استخدم signal.connect(callable).' });
    if (/\b(KinematicBody2D|KinematicBody|Spatial|RigidBody\b(?!2D))/.test(line)) s.legacy.push({ line: n, what: 'اسم كلاس من Godot 3 (CharacterBody/Node3D في Godot 4).' });
  });
  return s;
}

function parseProjectGodot(text) {
  const info = { configVersion: null, mainScene: null, autoloads: {}, inputActions: [], name: '', features: '' };
  let section = '';
  for (const raw of text.split('\n')) {
    const line = raw.trim();
    let m;
    if ((m = /^\[(.+)\]$/.exec(line))) { section = m[1]; continue; }
    if (!line || line.startsWith(';')) continue;
    if (!section && (m = /^config_version\s*=\s*(\d+)/.exec(line))) info.configVersion = +m[1];
    else if (section === 'application') {
      if ((m = /^run\/main_scene\s*=\s*"([^"]+)"/.exec(line))) info.mainScene = m[1];
      else if ((m = /^config\/name\s*=\s*"([^"]*)"/.exec(line))) info.name = m[1];
      else if ((m = /^config\/features\s*=\s*(.+)$/.exec(line))) info.features = m[1].trim();
    } else if (section === 'autoload' && (m = /^([A-Za-z_]\w*)\s*=\s*"\*?([^"]+)"/.exec(line))) info.autoloads[m[1]] = m[2];
    else if (section === 'input' && (m = /^([A-Za-z_][\w.]*)\s*=\s*\{/.exec(line))) info.inputActions.push(m[1]);
  }
  info.godot4 = info.configVersion ? info.configVersion >= 5 : null;
  return info;
}

/* ---------------- analysis ---------------- */

function analyze(p) {
  p.info = { configVersion: null, mainScene: null, autoloads: {}, inputActions: [], name: '', godot4: null };
  p.scenes = new Map();
  p.scripts = new Map();
  p.graph = new Map();
  p.findings = [];
  const link = (a, b) => {
    if (!a || !b || a === b) return;
    if (!p.graph.has(a)) p.graph.set(a, new Set());
    if (!p.graph.has(b)) p.graph.set(b, new Set());
    p.graph.get(a).add(b); p.graph.get(b).add(a);
  };
  const pg = p.files.get('project.godot');
  if (pg) { p.info = parseProjectGodot(pg.text); if (p.info.name) p.name = p.info.name; }

  for (const f of p.files.values()) {
    if (f.ext === 'tscn') {
      const sc = parseScene(f.text); p.scenes.set(f.path, sc);
      for (const e of Object.values(sc.ext)) link(f.path, toRel(e.path));
    } else if (f.ext === 'gd') {
      const s = parseScript(f.text); p.scripts.set(f.path, s);
      for (const r of s.resRefs) link(f.path, r.path);
    } else if (f.ext === 'tres' || f.ext === 'gdshader' || f.ext === 'shader') {
      for (const r of resPaths(f.text)) link(f.path, toRel(r));
    }
  }
  if (p.info.mainScene) link('project.godot', toRel(p.info.mainScene));
  for (const a of Object.values(p.info.autoloads)) link('project.godot', toRel(a));
  runChecks(p);
}

function runChecks(p) {
  const F = p.findings;
  const add = (sev, file, line, msg, kind) => F.push({ sev, file, line: line || 0, msg, kind });
  const known = (path) => p.allPaths.has(path);
  const hasBinaries = p.assetCount > 0 || p.skipped.length > 0;

  // 1. missing resources (reported as warnings: the file may simply not have been uploaded)
  const missingSeen = new Set();
  const checkRes = (file, line, rel) => {
    if (!rel || /[%{}*]/.test(rel) || known(rel)) return;
    if (rel.startsWith('.godot/') || rel.endsWith('/')) return;
    const key = file + '>' + rel;
    if (missingSeen.has(key)) return;
    missingSeen.add(key);
    add('error', file, line, `المسار res://${rel} غير موجود في الملفات المرفوعة${hasBinaries ? ' (قد يكون الملف غير مرفوع)' : ''}.`, 'missing-resource');
  };
  for (const [path, s] of p.scripts) for (const r of s.resRefs) checkRes(path, r.line, r.path);
  for (const [path, sc] of p.scenes) for (const e of Object.values(sc.ext)) checkRes(path, 0, toRel(e.path));
  if (p.info.mainScene) checkRes('project.godot', 0, toRel(p.info.mainScene));
  for (const [n, a] of Object.entries(p.info.autoloads)) if (!known(toRel(a))) add('error', 'project.godot', 0, `Autoload ${n} يشير إلى ${a} وهو غير موجود.`, 'missing-resource');

  // scenes using each script
  const scriptUsers = new Map();
  for (const [spath, sc] of p.scenes) for (const n of sc.nodes) if (n.scriptPath) {
    if (!scriptUsers.has(n.scriptPath)) scriptUsers.set(n.scriptPath, []);
    scriptUsers.get(n.scriptPath).push({ scene: spath, node: n, sc });
  }

  // 2. scene connections
  for (const [spath, sc] of p.scenes) {
    const byPath = new Map(sc.nodes.map((n) => [n.path, n]));
    for (const c of sc.connections) {
      const to = byPath.get(c.to || '.');
      if (!byPath.get(c.from || '.')) add('error', spath, 0, `اتصال إشارة "${c.signal}" من عقدة غير موجودة: ${c.from}.`, 'bad-connection');
      if (!to) { add('error', spath, 0, `اتصال إشارة "${c.signal}" إلى عقدة غير موجودة: ${c.to}.`, 'bad-connection'); continue; }
      const script = to.scriptPath && p.scripts.get(to.scriptPath);
      if (script && c.method && !script.funcs.some((f) => f.name === c.method) && !/^(Node|Control|Object)/.test(script.extends)) {
        add('warning', spath, 0, `الإشارة "${c.signal}" متصلة بدالة ${c.method} غير موجودة في ${to.scriptPath}.`, 'missing-handler');
      }
    }
  }

  // 3. node paths used by scripts vs. the scenes that use them
  for (const [spath, s] of p.scripts) {
    const users = scriptUsers.get(spath);
    if (users && users.length) {
      for (const ref of s.nodeRefs) {
        const first = ref.path.split('/')[0];
        const ok = users.some(({ node, sc }) => {
          const full = node.path === '.' ? ref.path : node.path + '/' + ref.path;
          if (sc.nodes.some((n) => n.path === full)) return true;
          // path passes through an instanced scene: cannot be verified statically
          const parts = full.split('/');
          for (let i = 1; i < parts.length; i++) {
            const prefix = i === 0 ? '.' : parts.slice(0, i).join('/');
            const hit = sc.nodes.find((n) => n.path === prefix);
            if (hit && hit.instancePath) return true;
          }
          if (node.path === '.' && sc.nodes.some((n) => n.path === ref.path)) return true;
          return false;
        });
        if (!ok) add('warning', spath, ref.line, `المسار $${ref.path} غير موجود في المشاهد التي تستخدم السكربت (${users.map((u) => u.scene).join(', ')}).`, 'bad-node-path');
        void first;
      }
      for (const u of s.uniqueRefs) {
        if (!users.some(({ sc }) => sc.nodes.some((n) => n.unique && n.name === u.name) || sc.nodes.some((n) => n.instancePath))) {
          add('warning', spath, u.line, `العقدة الفريدة %${u.name} غير معرّفة (unique_name_in_owner) في مشاهد السكربت.`, 'bad-unique-node');
        }
      }
    }
    // 4. handlers connected in code that do not exist in the same script
    for (const h of s.handlers) {
      if (h.bare && !s.funcs.some((f) => f.name === h.name) && !s.signals.includes(h.name) && !/^[A-Z]/.test(h.name)) {
        const isVar = new RegExp('\\b(var|const)\\s+' + h.name + '\\b').test(p.files.get(spath).text);
        if (!isVar && !/^(self|null|true|false)$/.test(h.name)) add('warning', spath, h.line, `connect يشير إلى الدالة ${h.name} وهي غير معرّفة في هذا السكربت.`, 'missing-handler');
      }
    }
    // 5. syntax-level sanity (static only)
    lintScript(p.files.get(spath), add);
    if (p.info.godot4) for (const l of s.legacy.slice(0, 5)) add('warning', spath, l.line, l.what, 'godot3-api');
  }
}

function lintScript(file, add) {
  const lines = file.text.split('\n');
  let depth = 0, inTriple = false, style = null, mixedLine = 0, mixedCount = 0;
  lines.forEach((raw, i) => {
    if ((raw.match(/"""/g) || []).length % 2 === 1) inTriple = !inTriple;
    if (inTriple) return;
    const lead = /^[ \t]*/.exec(raw)[0];
    const code0 = raw.trim();
    if (code0 && !code0.startsWith('#') && depth === 0 && lead) {
      const st = lead.includes('\t') ? 'tab' : 'space';
      if (lead.includes('\t') && lead.includes(' ')) { mixedCount++; if (!mixedLine) mixedLine = i + 1; }
      else if (!style) style = st;
      else if (st !== style) { mixedCount++; if (!mixedLine) mixedLine = i + 1; }
    }
    const code = stripComment(raw).replace(/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/g, '""');
    for (const c of code) { if ('([{'.includes(c)) depth++; else if (')]}'.includes(c)) depth--; }
    if (depth < 0) { add('error', file.path, i + 1, 'قوس إغلاق زائد.', 'brackets'); depth = 0; }
  });
  if (mixedCount) add('error', file.path, mixedLine, `خلط بين Tab والمسافات في المسافة البادئة (${mixedCount} سطر) - GDScript يرفضه.`, 'mixed-indent');
  if (depth > 0) add('error', file.path, lines.length, 'أقواس غير مغلقة في نهاية الملف.', 'brackets');
}

/** Cheap syntax sanity check used on AI output before offering it for download. */
function sanityCheck(path, text) {
  const out = [];
  const add = (sev, file, line, msg) => out.push({ sev, file, line, msg });
  if (extOf(path) === 'gd') lintScript({ path, text }, add);
  else if (extOf(path) === 'tscn' || extOf(path) === 'tres') {
    if (!/^\[(gd_scene|gd_resource)\b/.test(text.trimStart())) out.push({ sev: 'error', file: path, line: 1, msg: 'ملف Godot يجب أن يبدأ بسطر [gd_scene ...] أو [gd_resource ...].' });
  } else if (extOf(path) === 'json') { try { JSON.parse(text); } catch { out.push({ sev: 'error', file: path, line: 0, msg: 'JSON غير صالح.' }); } }
  if (/rest of (the )?code|\.\.\. ?\(?(existing|rest)|TODO: implement/i.test(text)) out.push({ sev: 'warning', file: path, line: 0, msg: 'يبدو أن الملف يحتوي على مقطع ناقص/Placeholder. راجعه قبل الاعتماد.' });
  return out;
}

/* ---------------- updates ---------------- */

function diffProjects(oldP, newP) {
  const added = [], removed = [], changed = [];
  if (!oldP) return { added: [...newP.files.keys()], removed, changed };
  for (const [path, f] of newP.files) { const o = oldP.files.get(path); if (!o) added.push(path); else if (o.hash !== f.hash) changed.push(path); }
  for (const path of oldP.files.keys()) if (!newP.files.has(path)) removed.push(path);
  return { added, removed, changed };
}

/** Re-uploading single text files updates the stored project (matching by path, then by unique basename). */
function mergeFiles(p, updates) {
  const merged = { added: [], changed: [], unchanged: [] };
  for (const u of updates) {
    let path = normPath(u.name);
    if (!p.files.has(path)) {
      const hits = [...p.files.keys()].filter((k) => base(k) === base(path));
      if (hits.length === 1) path = hits[0];
    }
    const prev = p.files.get(path);
    const h = hash(u.content);
    if (prev && prev.hash === h) { merged.unchanged.push(path); continue; }
    p.files.set(path, { path, ext: extOf(path), size: u.content.length, text: u.content, hash: h, lines: u.content.split('\n').length });
    p.allPaths.add(path);
    (prev ? merged.changed : merged.added).push(path);
  }
  if (merged.added.length || merged.changed.length) analyze(p);
  return merged;
}

function serialize(p) {
  return { name: p.name, assetCount: p.assetCount, skipped: p.skipped, allPaths: [...p.allPaths], files: [...p.files.values()].map((f) => ({ path: f.path, size: f.size, text: f.text })) };
}
function deserialize(d) {
  const files = new Map();
  for (const f of d.files || []) files.set(f.path, { path: f.path, ext: extOf(f.path), size: f.size, text: f.text, hash: hash(f.text), lines: f.text.split('\n').length });
  const p = { name: d.name || 'project', files, skipped: d.skipped || [], allPaths: new Set(d.allPaths || []), assetCount: d.assetCount || 0 };
  analyze(p);
  return p;
}

/* ---------------- context selection ---------------- */

function projectMap(p, maxChars = 6000) {
  const L = [];
  L.push(`Project: ${p.name}${p.info.godot4 === true ? ' (Godot 4, config_version ' + p.info.configVersion + ')' : p.info.godot4 === false ? ' (Godot 3 style, config_version ' + p.info.configVersion + ')' : ''}`);
  if (p.info.mainScene) L.push('Main scene: ' + p.info.mainScene);
  const al = Object.entries(p.info.autoloads);
  if (al.length) L.push('Autoloads: ' + al.map(([n, v]) => `${n}=${v}`).join(', '));
  const byExt = {};
  for (const f of p.files.values()) byExt[f.ext] = (byExt[f.ext] || 0) + 1;
  L.push(`Read files: ${p.files.size} (${Object.entries(byExt).map(([e, n]) => `${n} .${e}`).join(', ')}); other assets not read: ${p.assetCount}`);
  L.push('Files (path, lines):');
  const paths = [...p.files.keys()].filter((k) => k !== 'project.godot' && !/\.(md|txt|log|csv)$/.test(k)).sort();
  for (const k of paths.slice(0, 140)) {
    const f = p.files.get(k); let extra = '';
    if (f.ext === 'gd') { const s = p.scripts.get(k); extra = [s.className && 'class ' + s.className, s.extends && 'extends ' + s.extends].filter(Boolean).join(', '); }
    else if (f.ext === 'tscn') { const sc = p.scenes.get(k); const scripts = [...new Set(sc.nodes.map((n) => n.scriptPath).filter(Boolean))]; extra = `root ${sc.rootType || '?'}, ${sc.nodes.length} nodes${scripts.length ? ', scripts: ' + scripts.join(' ') : ''}`; }
    L.push(`- ${k} (${f.lines})${extra ? ' · ' + extra : ''}`);
  }
  if (paths.length > 140) L.push(`- … ${paths.length - 140} more files`);
  let out = L.join('\n');
  if (out.length > maxChars) out = out.slice(0, maxChars) + '\n… (map truncated)';
  return out;
}

function chunkScript(text, focusLines, words, cap) {
  if (text.length <= cap) return { text, partial: false };
  const lines = text.split('\n');
  const first = lines.findIndex((l) => /^\s*(static\s+)?func\s/.test(l));
  const headEnd = first < 0 ? Math.min(lines.length, 60) : first;
  const blocks = [];
  let i = headEnd;
  while (i < lines.length) {
    let j = i + 1;
    while (j < lines.length && !/^\s*(static\s+)?func\s/.test(lines[j])) j++;
    blocks.push({ from: i, to: j, name: (/func\s+([A-Za-z_]\w*)/.exec(lines[i]) || [])[1] || '?' });
    i = j;
  }
  const keep = new Set();
  const budgetCap = Math.floor(cap * 0.9); // leave room for the "omitted functions" marker lines
  let used = lines.slice(0, headEnd).join('\n').length;
  const rank = blocks.map((b, idx) => {
    const body = lines.slice(b.from, b.to).join('\n');
    let score = 0;
    if (focusLines.some((n) => n - 1 >= b.from && n - 1 < b.to)) score += 100;
    for (const w of words) if (body.includes(w)) score += 5;
    const dist = focusLines.length ? Math.min(...focusLines.map((n) => Math.abs(n - 1 - b.from))) : 0;
    return { b, idx, score, dist, size: body.length };
  }).sort((a, b) => b.score - a.score || a.dist - b.dist || a.idx - b.idx);
  for (const r of rank) { if (used + r.size > budgetCap) continue; keep.add(r.idx); used += r.size; }
  const out = lines.slice(0, headEnd);
  let skippedNames = [];
  const flush = () => { if (skippedNames.length) { out.push(`# … (omitted functions: ${skippedNames.join(', ')})`); skippedNames = []; } };
  blocks.forEach((b, idx) => { if (keep.has(idx)) { flush(); out.push(...lines.slice(b.from, b.to)); } else skippedNames.push(b.name); });
  flush();
  return { text: out.join('\n'), partial: true };
}

function tokens(text) {
  return [...new Set(String(text || '').match(/[A-Za-z_][A-Za-z0-9_]{3,}/g) || [])].slice(0, 60);
}

/**
 * Picks the context that matters for a request.
 * opts: { query, budget (chars), mapChars }
 */
function selectContext(p, opts = {}) {
  const query = opts.query || '';
  const budget = opts.budget || 24000;
  const words = tokens(query);
  const score = new Map();
  const bump = (k, v) => score.set(k, Math.max(score.get(k) || 0, 0) + v);
  const focus = new Map();

  const qLower = query.toLowerCase();
  for (const path of p.files.keys()) {
    const b = base(path).toLowerCase();
    if (qLower.includes(path.toLowerCase())) bump(path, 120);
    else if (b.length > 3 && qLower.includes(b)) bump(path, 100);
    else if (b.length > 4 && qLower.includes(b.replace(/\.[^.]+$/, ''))) bump(path, 60);
  }
  const errRe = /(?:res:\/\/)?([\w\/.\-]+\.(?:gd|tscn|tres|gdshader))(?::|\s+line\s+|\s*\()(\d+)/gi;
  let m;
  while ((m = errRe.exec(query))) {
    const rel = normPath(m[1]);
    const target = p.files.has(rel) ? rel : [...p.files.keys()].find((k) => base(k) === base(rel));
    if (target) { bump(target, 150); if (!focus.has(target)) focus.set(target, []); focus.get(target).push(+m[2]); }
  }
  for (const [path, s] of p.scripts) {
    let hits = 0;
    for (const w of words) {
      if (s.className === w || s.funcs.some((f) => f.name === w) || s.signals.includes(w)) hits++;
    }
    if (hits) bump(path, Math.min(60, 25 * hits));
  }
  for (const [path, sc] of p.scenes) {
    let hits = 0;
    for (const w of words) if (sc.nodes.some((n) => n.name === w)) hits++;
    if (hits) bump(path, Math.min(50, 20 * hits));
  }
  for (const f of p.findings) {
    const fp = f.file;
    if (p.files.has(fp)) bump(fp, f.sev === 'error' ? 25 : 12);
  }
  for (const b of opts.boost || []) { const hit = p.files.has(b) ? b : [...p.files.keys()].find((k) => base(k) === base(b)); if (hit) bump(hit, 200); }
  // expand through the reference graph (scene <-> script, preload, autoload)
  const seeds = [...score.entries()].filter(([, v]) => v >= 40).map(([k]) => k);
  for (const s of seeds) for (const n of p.graph.get(s) || []) if (p.files.has(n)) bump(n, 30);
  if (!seeds.length) {
    if (p.info.mainScene) bump(toRel(p.info.mainScene), 20);
    for (const a of Object.values(p.info.autoloads)) bump(toRel(a), 20);
    if (p.files.has('project.godot')) bump('project.godot', 15);
  }

  const ranked = [...score.entries()].filter(([k]) => p.files.has(k) && k !== 'project.godot' || k === 'project.godot' && p.files.has(k)).sort((a, b) => b[1] - a[1]);
  const mapText = projectMap(p, opts.mapChars || 5500);
  let remaining = budget - mapText.length;
  const included = [], omitted = [];
  const perFile = Math.max(3500, Math.floor(budget * 0.4));
  const parts = [];
  for (const [path, sc] of ranked) {
    const f = p.files.get(path);
    if (remaining < 600) { omitted.push(path); continue; }
    let body = f.text, partial = false;
    const cap = Math.min(perFile, remaining - 120);
    if (body.length > cap) {
      if (f.ext === 'gd') ({ text: body, partial } = chunkScript(f.text, focus.get(path) || [], words, cap));
      if (body.length > cap) { body = body.slice(0, Math.floor(cap * 0.7)) + '\n… (truncated) …\n' + body.slice(-Math.floor(cap * 0.25)); partial = true; }
    }
    parts.push(`### FILE ${path}${partial ? ' (partial)' : ''}\n\`\`\`${f.ext === 'gd' ? 'gdscript' : f.ext}\n${body}\n\`\`\``);
    remaining -= body.length + path.length + 30;
    included.push({ path, partial, score: sc });
  }
  const findings = p.findings.slice(0, 25).map((x) => `- [${x.sev}] ${x.file}${x.line ? ':' + x.line : ''} ${x.msg}`);
  const skippedLines = p.skipped.slice(0, 15).map((s) => `- ${s.path}: ${s.reason}`);
  let text = '=== PROJECT MAP ===\n' + mapText;
  if (findings.length) text += '\n\n=== STATIC FINDINGS (heuristic, not verified in Godot) ===\n' + findings.join('\n');
  if (skippedLines.length) text += '\n\n=== FILES NOT READ ===\n' + skippedLines.join('\n');
  if (omitted.length) text += '\n\n=== RELEVANT FILES NOT INCLUDED (size budget; ask the user to paste them if needed) ===\n' + omitted.slice(0, 15).join('\n');
  text += '\n\n=== SELECTED FILES ===\n' + (parts.join('\n\n') || '(no file selected - rely on the map)');
  return { text, included, omitted, chars: text.length };
}

const api = {
  readZip, readZipProject, readFolderProject, ingest, analyze, parseScene, parseScript, parseProjectGodot,
  selectContext, projectMap, diffProjects, mergeFiles, serialize, deserialize, sanityCheck, normPath, LIMITS,
};
if (typeof module !== 'undefined' && module.exports) module.exports = api; else root.NovaGodot = api;
})(typeof self !== 'undefined' ? self : this);
