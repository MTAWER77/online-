const C = require('./context.cjs'); const assert = require('node:assert/strict');
let ok = 0; const test = async (n, f) => { try { await f(); ok++; console.log('PASS', n); } catch (e) { console.log('FAIL', n, '\n', e.stack.split('\n').slice(0, 5).join('\n')); process.exitCode = 1; } };
const mk = (n) => { const m = [];
  m.push({ id: 'u0', role: 'user', content: 'لازم الواجهة تفضل أبيض وأسود ومفيش مكتبات كبيرة. وعايز تعدل ملف player.gd' });
  m.push({ id: 'a0', role: 'assistant', content: 'تمام.\n```gdscript\nfunc take_damage(amount):\n\thealth -= amount\nfunc respawn_player():\n\tpass\n```', files: ['player.gd'] });
  for (let i = 1; i < n; i++) { m.push({ id: 'u' + i, role: 'user', content: 'سؤال عام رقم ' + i + ' عن الطقس والرياضة والأكل' }); m.push({ id: 'a' + i, role: 'assistant', content: 'رد رقم ' + i + ' ' + 'كلام '.repeat(40) }); }
  return m; };
(async () => {
  await test('classify: continue / back-reference / new topic / followup', () => {
    assert.equal(C.classify('كمل'), 'continue'); assert.equal(C.classify('عدّل ده وخليه زي ما كان'), 'back');
    assert.equal(C.classify('اصلح الخطأ السابق'), 'back');
    assert.equal(C.classify('اشرحلي الفرق بين الذرة والجزيئات في الكيمياء النووية', [{ content: 'كود الـ player.gd بتاع اللعبة' }]), 'new');
    assert.equal(C.classify('خلي اللاعب يتحرك أسرع في player.gd', [{ content: 'عدّلنا player.gd' }]), 'followup');
  });
  await test('long chat: old requirement + file referenced by the new request are selected, not lost', () => {
    const msgs = mk(40); msgs.push({ id: 'last', role: 'user', content: 'عدّل take_damage في player.gd' });
    const r = C.select(msgs, { budget: 12000 });
    assert.ok(r.messages.some((m) => m.id === 'a0'), 'old code answer kept because relevant');
    assert.ok(r.messages.length < msgs.length && r.dropped > 0);
    assert.equal(r.messages[r.messages.length - 1].id, 'last'); assert.equal(r.messages[0].role, 'user');
  });
  await test('dropped part is summarized: requirements, files and function names survive', () => {
    const msgs = mk(40); msgs.push({ id: 'last', role: 'user', content: 'ايه اخبار الطقس النهارده في القاهرة؟' });
    const r = C.select(msgs, { budget: 3000 });
    assert.ok(/أبيض وأسود/.test(r.summary) || r.messages.some((m) => /أبيض وأسود/.test(m.content)), 'requirement kept or summarized'); assert.ok(/player\.gd/.test(r.summary) || r.messages.some((m) => /player\.gd/.test(m.content)));
    if (!r.messages.some((m) => m.id === 'a0')) { assert.match(r.summary, /take_damage/); assert.match(r.summary, /respawn_player/); }
  });
  await test('back-reference keeps more recent turns; new topic keeps fewer', () => {
    const base = mk(12);
    const back = C.select([...base, { id: 'x', role: 'user', content: 'عدّل ده' }], { budget: 100000 });
    const fresh = C.select([...base, { id: 'x', role: 'user', content: 'اشرحلي تاريخ الدولة العثمانية وأسباب سقوطها بالتفصيل' }], { budget: 100000 });
    assert.equal(back.mode, 'back'); assert.equal(fresh.mode, 'new');
    assert.ok(fresh.messages.length < back.messages.length + 20 && fresh.dropped > back.dropped);
  });
  await test('huge old message is shrunk but both ends (signatures) survive', () => {
    const big = 'func first_fn():\n' + 'x = 1\n'.repeat(4000) + 'func last_fn():\n\tpass';
    const r = C.select([{ id: 'u', role: 'user', content: 'اصلح الكود ده ' + big }, { id: 'a', role: 'assistant', content: 'تمام' }, { id: 'l', role: 'user', content: 'كمل' }], { perMsgCap: 3000 });
    const m = r.messages.find((x) => x.id === 'u'); assert.ok(m.shrunk && m.content.includes('first_fn') && m.content.includes('last_fn'));
  });
  await test('budget is respected and 500 messages run fast', () => {
    const msgs = mk(250); msgs.push({ id: 'last', role: 'user', content: 'سؤال عن player.gd' });
    const t0 = Date.now(); const r = C.select(msgs, { budget: 8000, maxMessages: 12 });
    assert.ok(Date.now() - t0 < 500); assert.ok(r.messages.length <= 12);
    assert.ok(r.messages.reduce((n, m) => n + m.content.length, 0) < 8000 + 4 * 400);
  });
  console.log(ok + ' passed');
})();
