const P = require('./pdf.cjs'); const assert = require('node:assert/strict');
let ok = 0; const test = async (n, f) => { try { await f(); ok++; console.log('PASS', n); } catch (e) { console.log('FAIL', n, '\n', e.stack.split('\n').slice(0, 4).join('\n')); process.exitCode = 1; } };
const mkText = (n) => P.pagesToText(Array.from({ length: n }, (_, i) => ({ n: i + 1, text: (i === 6 ? 'refund policy within thirty days ' : 'filler paragraph ') + 'x'.repeat(1500) })));
(async () => {
  await test('pages round-trip with markers', () => { const t = mkText(3); const p = P.parsePages(t); assert.equal(p.length, 3); assert.equal(p[2].n, 3); });
  await test('small PDF is sent whole', () => { const t = mkText(3); assert.equal(P.selectPages(t, 'ايه ده', 24000), t); });
  await test('big PDF: only relevant pages + first page, within budget, page numbers kept', () => {
    const t = mkText(60); const s = P.selectPages(t, 'what is the refund policy', 9000);
    assert.ok(s.length < 9600); assert.match(s, /=== صفحة 7 ===/); assert.match(s, /=== صفحة 1 ===/); assert.match(s, /أُرسلت الصفحات/);
  });
  await test('explicit page request wins', () => { const s = P.selectPages(mkText(60), 'اشرح صفحة 42', 5000); assert.match(s, /=== صفحة 42 ===/); });
  console.log(ok + ' passed');
})();
