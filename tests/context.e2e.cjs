const { chromium } = require('playwright'); const assert = require('node:assert/strict');
(async () => {
  const b = await chromium.launch(); const page = await (await b.newContext({ viewport: { width: 390, height: 780 } })).newPage();
  const errs = []; page.on('pageerror', (e) => errs.push(e.message)); const bodies = [];
  await page.route('**/api/chat', async (route) => { bodies.push(JSON.parse(route.request().postData()));
    route.fulfill({ status: 200, contentType: 'text/event-stream', body: 'data: {"status":"start"}\n\ndata: {"t":"رد"}\n\ndata: {"done":true,"finish":"stop","model":"m","provider":"groq"}\n\n' }); });
  await page.goto('http://localhost:8799');
  const send = async (t, n) => { await page.fill('#input', t); await page.click('#sendBtn'); await page.waitForFunction((k) => document.querySelectorAll('.row.ai').length >= k && !document.querySelector('.row.ai.streaming'), n, { timeout: 15000 }); };
  await send('لازم الواجهة تفضل أبيض وأسود ومفيش مكتبات كبيرة وعدّل ملف player.gd', 1);
  for (let i = 2; i <= 16; i++) await send('سؤال عام رقم ' + i + ' عن الطقس والرياضة والأكل ' + 'كلام '.repeat(10), i);
  await send('عدّل ده', 17);
  const last = bodies[bodies.length - 1];
  assert.ok(last.messages.length < 33, 'not every message is resent: ' + last.messages.length);
  assert.ok(/أبيض وأسود/.test(JSON.stringify(last.messages)) || /أبيض وأسود/.test(last.context), 'old requirement still reaches the model');
  assert.ok(/refers back/.test(last.context), 'back-reference hint sent');
  assert.equal(errs.length, 0, errs.join('|'));
  console.log('PASS context e2e: ' + last.messages.length + ' msgs sent of 33, requirement kept, hint sent'); await b.close();
})().catch((e) => { console.log('FAIL', e.message); process.exit(1); });
