const G = require('./godot.cjs');
const assert = require('node:assert/strict');
const fs = require('fs');
let ok = 0; const test = async (n, f) => { try { await f(); ok++; console.log('PASS', n); } catch (e) { console.log('FAIL', n, '\n', e.stack); process.exitCode = 1; } };
(async () => {
  const buf = fs.readFileSync('gp.zip');
  const file = { name: 'gp.zip', arrayBuffer: async () => buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength) };
  let p;
  await test('zip read + root stripped + ignored dirs', async () => {
    p = await G.readZipProject(file);
    assert.ok(p.files.has('project.godot')); assert.ok(p.files.has('scripts/player.gd'));
    assert.ok(![...p.files.keys()].some(k => k.startsWith('MyGame/')));
    assert.equal(p.name, 'Cart Game'); assert.equal(p.assetCount, 1); // icon.png not read
  });
  await test('parses scenes / scripts / project info', async () => {
    assert.equal(p.info.mainScene, 'res://scenes/main.tscn'); assert.equal(p.info.autoloads.GameState, 'res://scripts/game_state.gd');
    const sc = p.scenes.get('scenes/main.tscn'); assert.equal(sc.connections.length, 2);
    assert.equal(sc.nodes.find(n => n.name === 'Player').scriptPath, 'scripts/player.gd');
    assert.equal(sc.nodes.find(n => n.name === 'UI').instancePath, 'scenes/ui.tscn');
    const s = p.scripts.get('scripts/player.gd'); assert.equal(s.className, 'Player'); assert.ok(s.signals.includes('died'));
  });
  const kinds = () => p.findings.map(f => f.kind + '|' + f.file + '|' + f.msg);
  await test('detects missing resources (autoload + preload)', async () => {
    assert.ok(p.findings.some(f => f.kind === 'missing-resource' && /nope\.gd/.test(f.msg)), kinds().join('\n'));
    assert.ok(p.findings.some(f => f.kind === 'missing-resource' && /missing_data\.gd/.test(f.msg)));
  });
  await test('detects signal connection to missing handler', async () => {
    assert.ok(p.findings.some(f => f.kind === 'missing-handler' && /_on_missing/.test(f.msg)));
    assert.ok(!p.findings.some(f => /_on_button_pressed/.test(f.msg)));
  });
  await test('node path check: $Gun missing flagged; $Sprite ok; $UI/Label (instanced) not flagged', async () => {
    const np = p.findings.filter(f => f.kind === 'bad-node-path').map(f => f.msg).join('\n');
    assert.ok(/\$Gun/.test(np), np); assert.ok(!/\$Sprite/.test(np)); assert.ok(/Player/.test(np) === false); assert.ok(!p.findings.some(f => f.kind === 'bad-node-path' && f.file === 'scripts/main.gd'), 'instanced UI path must not be flagged'); assert.ok(p.findings.some(f => f.kind === 'bad-node-path' && f.file === 'scripts/player.gd' && /UI\/Label/.test(f.msg)), 'sibling path from Player is a real bug');
  });
  await test('lint: mixed indent + godot3 api flagged', async () => {
    assert.ok(p.findings.some(f => f.kind === 'mixed-indent' && f.file === 'scripts/player.gd'));
    assert.ok(p.findings.some(f => f.kind === 'godot3-api' && /yield/.test(f.msg)));
  });
  await test('selectContext: query naming a file selects it + linked scene, within budget', async () => {
    const r = G.selectContext(p, { query: 'مشكلة في player.gd السطر 12 مع Gun', budget: 9000 });
    assert.ok(r.included[0].path === 'scripts/player.gd', JSON.stringify(r.included));
    assert.ok(r.included.some(i => i.path === 'scenes/main.tscn'));
    assert.ok(r.chars <= 9500, String(r.chars));
    assert.ok(/PROJECT MAP/.test(r.text) && /STATIC FINDINGS/.test(r.text));
  });
  await test('error line focus keeps the right function of a big file, omits others', async () => {
    const big = p.files.get('scripts/big.gd'); assert.ok(big.text.length > 15000);
    const r = G.selectContext(p, { query: 'Error at res://scripts/big.gd:1605 invalid get index', budget: 12000 });
    const entry = r.included.find(i => i.path === 'scripts/big.gd'); assert.ok(entry && entry.partial);
    assert.ok(/target_bug/.test(r.text) && /omitted functions/.test(r.text));
  });
  await test('unread files are reported', async () => {
    const r = G.selectContext(p, { query: 'explain' });
    assert.ok(Array.isArray(p.skipped));
  });
  await test('diff / merge / serialize round trip', async () => {
    const m = G.mergeFiles(p, [{ name: 'player.gd', content: 'extends Node\n' }, { name: 'brand_new.gd', content: 'extends Node\n' }]);
    assert.deepEqual(m.changed, ['scripts/player.gd']); assert.deepEqual(m.added, ['brand_new.gd']);
    assert.ok(!p.findings.some(f => f.kind === 'bad-node-path'));
    const d = G.serialize(p); const q = G.deserialize(JSON.parse(JSON.stringify(d)));
    assert.equal(q.files.size, p.files.size);
    const df = G.diffProjects(q, p); assert.equal(df.changed.length + df.added.length + df.removed.length, 0);
  });
  await test('sanityCheck on AI output', async () => {
    assert.ok(G.sanityCheck('a.gd', 'func a():\n\tprint((1)\n').some(x => x.msg.includes('أقواس')));
    assert.ok(G.sanityCheck('a.tscn', 'junk').some(x => x.sev === 'error'));
    assert.equal(G.sanityCheck('a.gd', 'extends Node\nfunc a():\n\tpass\n').length, 0);
  });
  console.log(ok + ' passed');
})();
