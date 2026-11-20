const { chromium } = require('playwright'); const assert = require('node:assert/strict');
(async () => {
  const b = await chromium.launch(); const page = await (await b.newContext({ viewport: { width: 390, height: 780 } })).newPage();
  const errs = []; page.on('pageerror', (e) => errs.push(e.message)); const bodies = [];
  await page.route('**/api/chat', async (route) => { bodies.push(JSON.parse(route.request().postData()));
    route.fulfill({ status: 200, contentType: 'text/event-stream', body: 'data: {"status":"start"}\n\ndata: {"t":"رد"}\n\ndata: {"done":true,"finish":"stop","model":"m","provider":"groq"}\n\n' }); });
  await page.goto('http://localhost:8799');
  await page.setInputFiles('#fileInput', 'sample.pdf');
  await page.waitForSelector('.attachment-tray .attachment, .attachment-tray > *', { timeout: 30000 });
  await page.waitForFunction(() => /قُرئ sample\.pdf/.test(document.body.textContent), null, { timeout: 30000 });
  const toast = (await page.textContent('body')).match(/قُرئ sample\.pdf[^\n]*/)[0];
  console.log('toast:', toast.slice(0, 160));
  assert.match(toast, /3\/3 صفحة/); assert.match(toast, /2 صفحة كصورة/, 'page 2 (image) + page 3 (scanned) rendered as images');
  await page.fill('#input', 'what is the refund policy?'); await page.click('#sendBtn');
  await page.waitForFunction(() => document.querySelectorAll('.row.ai').length >= 1 && !document.querySelector('.row.ai.streaming'), null, { timeout: 15000 });
  const m = bodies[0].messages[bodies[0].messages.length - 1];
  const parts = Array.isArray(m.content) ? m.content : [{ type: 'text', text: m.content }];
  const text = parts.filter((p) => p.type === 'text').map((p) => p.text).join('\n'); const imgs = parts.filter((p) => p.type === 'image_url');
  assert.ok(text.includes('=== صفحة 2 ===') && /refund policy/.test(text), 'text with page markers sent');
  assert.equal(imgs.length, 2); assert.ok(imgs[0].image_url.url.startsWith('data:image/jpeg'));
  // corrupt file: clear message, nothing attached
  await page.setInputFiles('#fileInput', 'corrupt.pdf');
  await page.waitForFunction(() => /تالف|تعذر قراءة PDF/.test(document.body.textContent), null, { timeout: 20000 });
  assert.equal(errs.length, 0, errs.join('|'));
  console.log('PASS pdf e2e: text+page markers, 2 pages as images, corrupt file handled'); await b.close();
})().catch((e) => { console.log('FAIL', e.message); process.exit(1); });
