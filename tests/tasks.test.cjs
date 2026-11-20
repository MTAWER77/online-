const T = require('./tasks.cjs'); const assert = require('node:assert/strict');
let ok = 0; const test = async (n, f) => { try { await f(); ok++; console.log('PASS', n); } catch (e) { console.log('FAIL', n, '\n', e.stack.split('\n').slice(0, 5).join('\n')); process.exitCode = 1; } };
const REQ = '1. عدّل ملف HTML وأضف زر الكاميرا\n2. أضف دالة JavaScript لفتح الكاميرا\n3. عدّل الـ Worker ليقبل الصور\n4. حسّن ستايل CSS للزر';
(async () => {
  await test('short request -> no task flow', () => { assert.deepEqual(T.plan('اصلح الخطأ في ملف الكود ده'), []); });
  await test('numbered request split, ordered HTML->JS->Worker->CSS, + auto check task', () => {
    const p = T.plan(REQ); assert.equal(p.length, 5);
    assert.match(p[0].title, /HTML/); assert.match(p[1].title, /JavaScript/); assert.match(p[2].title, /Worker/); assert.match(p[3].title, /CSS/);
    assert.equal(p[4].kind, 'check');
  });
  await test('caps at MAX_TASKS by merging the tail', () => {
    const many = Array.from({ length: 15 }, (_, i) => `${i + 1}. مهمة رقم ${i + 1} طويلة بما يكفي`).join('\n');
    assert.ok(T.plan(many).length <= T.MAX_TASKS);
  });
  await test('runs in order, one exec per task, done only when all done', async () => {
    const s = T.createState(T.plan(REQ), REQ); const order = [];
    await T.run(s, { exec: async (t) => { order.push(t.id); return {}; }, check: () => [] });
    assert.deepEqual(order, ['t1', 't2', 't3', 't4']); assert.equal(s.status, 'done'); assert.equal(T.counts(s).done, 5);
  });
  await test('failure stops the run, never reports done, resume continues from the failed task', async () => {
    const s = T.createState(T.plan(REQ), REQ); let fail = true; const calls = [];
    const exec = async (t) => { calls.push(t.id); if (t.id === 't2' && fail) throw new Error('boom'); return {}; };
    await T.run(s, { exec, check: () => [] });
    assert.equal(s.status, 'failed'); assert.deepEqual(calls, ['t1', 't2']); assert.ok(T.resumable(s)); assert.match(T.summary(s), /لم تكتمل/);
    fail = false; T.resetForResume(s); await T.run(s, { exec, check: () => [] });
    assert.deepEqual(calls, ['t1', 't2', 't2', 't3', 't4']); assert.equal(s.status, 'done');
  });
  await test('cancel keeps progress and marks cancelled', async () => {
    const s = T.createState(T.plan(REQ), REQ); let n = 0;
    await T.run(s, { exec: async () => { n++; return {}; }, check: () => [], isCancelled: () => n >= 2 });
    assert.equal(s.status, 'cancelled'); assert.equal(T.counts(s).done, 2); assert.ok(T.resumable(s));
  });
  await test('integration check failure fails the last task', async () => {
    const s = T.createState(T.plan(REQ), REQ);
    await T.run(s, { exec: async () => ({}), check: () => ['a.json: JSON غير صالح.'] });
    assert.equal(s.status, 'failed'); assert.equal(s.tasks[4].status, 'failed');
  });
  console.log(ok + ' passed');
})();
