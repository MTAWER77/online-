const { chromium } = require('playwright'); const assert = require('node:assert/strict');
(async () => {
  const b = await chromium.launch(); const page = await (await b.newContext({ viewport: { width: 390, height: 780 } })).newPage();
  const errs = []; page.on('pageerror', (e) => errs.push(e.message));
  const paras = Array.from({ length: 40 }, (_, i) => `فقرة رقم ${i + 1}: هذا نص تجريبي طويل نسبيًا لاختبار سلاسة الكتابة وعدم سحب الشاشة.`);
  const full = paras.join('\n\n');
  await page.route('**/api/chat', (route) => route.fulfill({
    status: 200, headers: { 'content-type': 'text/event-stream' },
    body: 'data: {"status":"start"}\n\n' + 'data: ' + JSON.stringify({ t: full }) + '\n\n' + 'data: ' + JSON.stringify({ done: true, finish: 'stop', model: 'm' }) + '\n\n',
  }));
  await page.route('**/api/me', (r) => r.fulfill({ contentType: 'application/json', body: JSON.stringify({ limited: false, unlimited: true }) }));
  await page.goto('http://localhost:8799');
  await page.fill('#input', 'اكتب نص طويل'); await page.click('#sendBtn');
  await page.waitForSelector('.row.ai.streaming .md', { timeout: 10000 });

  // 1) paced: never a big jump between samples, and not instant
  const samples = [];
  for (let i = 0; i < 12; i++) { samples.push(await page.$eval('.row.ai.streaming .md', (n) => n.textContent.length)); await page.waitForTimeout(100); }
  const deltas = samples.slice(1).map((v, i) => v - samples[i]);
  assert.ok(samples[11] < full.length / 2, 'not instant: ' + samples.join(','));
  assert.ok(Math.max(...deltas) <= 120, 'smooth (no jumps): ' + deltas.join(','));
  assert.ok(samples[11] > samples[0], 'grows: ' + samples.join(','));

  // 2) reader scrolls up -> view must NOT be dragged down, jump-to-bottom button shows
  await page.waitForFunction(() => { const m = document.querySelector('#messages'); return m.scrollHeight - m.clientHeight > 400 && m.scrollTop > 200; }, null, { timeout: 30000 });
  await page.evaluate(() => { document.querySelector('#messages').scrollTop = 0; });
  await page.waitForTimeout(1200);
  const top = await page.$eval('#messages', (n) => n.scrollTop);
  assert.ok(top < 30, 'not dragged down: ' + top);
  assert.equal(await page.$eval('#toBottom', (n) => n.hidden), false, 'to-bottom button visible');
  await page.click('#toBottom');
  await page.waitForTimeout(900);
  const dist = await page.$eval('#messages', (n) => n.scrollHeight - n.scrollTop - n.clientHeight);
  assert.ok(dist < 80, 'back at bottom: ' + dist);

  // 3) completes with the full text, once
  await page.waitForSelector('.row.ai:not(.streaming) .md', { timeout: 40000 });
  const txt = await page.$eval('.row.ai:not(.streaming) .md', (n) => n.textContent);
  assert.ok(txt.includes('فقرة رقم 40'), 'full text delivered');
  assert.equal((await page.$$('.row.ai')).length, 1);
  assert.equal(errs.length, 0, errs.join('|'));
  console.log('PASS stream e2e: paced reveal, no forced scroll, jump-to-bottom, full text'); await b.close();
})().catch((e) => { console.log('FAIL', e.message); process.exit(1); });
