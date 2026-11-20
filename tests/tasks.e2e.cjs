const { chromium } = require('playwright'); const assert = require('node:assert/strict');
(async () => {
  const b = await chromium.launch(); const page = await (await b.newContext({ viewport: { width: 390, height: 780 } })).newPage();
  const errs = []; page.on('pageerror', (e) => errs.push(e.message));
  const calls = []; let failSecond = true;
  await page.route('**/api/generate-files', async (route) => {
    const body = JSON.parse(route.request().postData()); calls.push(body);
    const n = calls.length;
    if (n === 2 && failSecond) { failSecond = false; return route.fulfill({ status: 500, contentType: 'application/json', body: JSON.stringify({ error: 'boom' }) }); }
    const step = calls.filter((c, i) => i + 1 !== 2 || !failSecond).length;
    return route.fulfill({ contentType: 'application/json', body: JSON.stringify({ ok: true, message: 'تم', findings: [], files: [{ name: 'a.js', content: 'const x = 1; // EDITED ' + n + '\n' }] }) });
  });
  await page.goto('http://localhost:8799');
  await page.setInputFiles('#fileInput', { name: 'a.js', mimeType: 'text/javascript', buffer: Buffer.from('const x = 0;\n') });
  await page.fill('#input', '1. اعمل ملف HTML وأضف زر\n2. أضف دالة JavaScript للزر\n3. حسّن ستايل CSS للزر');
  await page.click('#sendBtn');
  await page.waitForSelector('[data-act="resume"]', { timeout: 15000 });
  assert.equal(calls.length, 2, 'stopped at the failed task, did not run the rest');
  const txt = await page.textContent('.row.ai:last-child');
  assert.ok(/لم تكتمل المهام/.test(txt) && /boom/.test(txt), 'incomplete is reported, not "done"');
  await page.click('[data-act="resume"]');
  await page.waitForFunction(() => /اكتملت كل المهام/.test(document.body.textContent), null, { timeout: 15000 });
  assert.equal(calls.length, 4, 'resume re-ran failed task + remaining one only');
  assert.ok(JSON.stringify(calls[3]).includes('EDITED'), 'later task sees files edited by earlier tasks');
  assert.equal(errs.length, 0, errs.join('|'));
  console.log('PASS task flow e2e: fail -> resume -> done, overlay carried'); await b.close();
})().catch((e) => { console.log('FAIL', e.message); process.exit(1); });
