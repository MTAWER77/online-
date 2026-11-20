const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const U = 'http://localhost:8799';
const st = (b) => fetch(U + '/__state', { method: 'POST', body: JSON.stringify(b || {}) }).then(r => r.json());
let passed = 0;
const test = async (n, f) => { try { await f(); passed++; console.log('PASS', n); } catch (e) { console.log('FAIL', n, '\n  ', e.message.split('\n').slice(0, 16).join('\n   ')); process.exitCode = 1; } };

(async () => {
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 360, height: 640 }, hasTouch: true, isMobile: true });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', e => errors.push('pageerror: ' + e.message));
  page.on('console', m => { if (m.type() === 'error') errors.push('console: ' + m.text()); });
  await st({ log: [], mode: 'ok', failFirst: 0 });
  await page.goto(U);
  const newChatBtn = async () => { await page.click('#menuBtn'); await page.click('#newChat'); };
  const send = async (text) => { await page.fill('#input', text); await page.click('#sendBtn'); };
  const lastLog = async () => { const s = await st(); return s.log[s.log.length - 1]; };
  const aiTexts = () => page.$$eval('.row.ai:not(.streaming) .md', n => n.map(x => x.textContent));
  const chatData = () => page.evaluate(() => JSON.parse(localStorage.getItem('nova_ai_chats_v1') || '[]'));

  await test('page loads without errors; mode chips order DeepThink, Search above composer', async () => {
    const labels = await page.$$eval('#modeBar .mode-chip span', n => n.map(x => x.textContent));
    assert.deepEqual(labels, ['DeepThink', 'Search']);
    const bar = await page.$eval('#modeBar', n => n.getBoundingClientRect().bottom);
    const comp = await page.$eval('#composer', n => n.getBoundingClientRect().top);
    assert.ok(bar <= comp + 1 && comp - bar < 20, `bar ${bar} composer ${comp}`);
    assert.equal(errors.length, 0, errors.join('|'));
  });

  await test('normal message streams and commits exactly one reply', async () => {
    await send('hello AAA');
    await page.waitForSelector('.row.ai:not(.streaming) .md');
    const t = await aiTexts();
    assert.equal(t.length, 1); assert.ok(t[0].includes('رد AAA') && t[0].includes('خاتمة AAA'));
    assert.ok(await page.$('.code'), 'code block rendered');
    const body = (await lastLog()).body; assert.equal(body.intent, 'general'); assert.ok(body.context.includes('turn #1'));
  });

  await test('Think + Search together are both sent and both shown active', async () => {
    await page.click('#thinkToggle'); await page.click('#searchToggle');
    const act = await page.$$eval('#modeBar .mode-chip.active', n => n.map(x => x.textContent.trim()));
    assert.deepEqual(act, ['DeepThink', 'Search']);
    await send('news AAA');
    await page.waitForFunction(() => document.querySelectorAll('.row.ai:not(.streaming)').length >= 2);
    const b = (await lastLog()).body; assert.equal(b.think, true); assert.equal(b.search, true);
    await page.click('#thinkToggle'); await page.click('#searchToggle');
  });

  await test('short follow-up "كمّل" is detected as continue and keeps history', async () => {
    await send('كمّل');
    await page.waitForFunction(() => document.querySelectorAll('.row.ai:not(.streaming)').length >= 3);
    const b = (await lastLog()).body; assert.equal(b.intent, 'continue'); assert.ok(b.messages.length >= 5);
  });

  await test('DeepSeek-style: thinking panel + sources panel shown and saved; dark mode toggles and persists', async () => {
    await newChatBtn();
    await page.click('#thinkToggle'); await page.click('#searchToggle');
    await send('reason AAA');
    await page.waitForFunction(() => document.querySelectorAll('.row.ai:not(.streaming)').length >= 1);
    const info = await page.evaluate(() => ({
      reason: !!document.querySelector('.row.ai details.reason .reason-body')?.textContent.includes('خطوة تفكير'),
      srcs: document.querySelectorAll('.row.ai details.srcs .srcs-list a').length,
      href: document.querySelector('.row.ai details.srcs .srcs-list a')?.href,
    }));
    assert.ok(info.reason, 'reasoning panel with text'); assert.equal(info.srcs, 2); assert.equal(info.href, 'https://docs.godotengine.org/en/stable/');
    await page.click('#thinkToggle'); await page.click('#searchToggle');
    assert.equal(await page.evaluate(() => document.documentElement.dataset.theme), 'light');
    await page.click('#themeBtn');
    assert.equal(await page.evaluate(() => document.documentElement.dataset.theme), 'dark');
    const bg = await page.evaluate(() => getComputedStyle(document.body).backgroundColor);
    assert.equal(bg, 'rgb(23, 23, 26)');
    await page.reload(); await page.waitForSelector('#themeBtn');
    assert.equal(await page.evaluate(() => document.documentElement.dataset.theme), 'dark');
    const chip = await page.evaluate(() => getComputedStyle(document.querySelector('#modeBar .mode-chip')).backgroundColor);
    assert.notEqual(chip, 'rgb(255, 255, 255)');
    await page.click('#themeBtn');
    assert.equal(await page.evaluate(() => document.documentElement.dataset.theme), 'light');
  });

  await test('stop button keeps partial text, marks it stopped, no error row', async () => {
    await newChatBtn();
    await send('slow AAA');
    await page.waitForSelector('.row.streaming .md-tail:not(:empty), .row.streaming .md-stable:not(:empty)');
    assert.ok(await page.$('#sendBtn.is-stop'));
    await page.click('#sendBtn');
    await page.waitForSelector('.cut-flag');
    const flag = await page.textContent('.cut-flag'); assert.ok(flag.includes('إيقاف'));
    assert.equal(await page.$('.errbox'), null);
    assert.ok(await page.$('[data-act="continue"]'));
  });

  await test('old reply cannot land in another chat: switch chats while streaming', async () => {
    await newChatBtn();
    await send('slow AAA question');                       // chat X streams slowly
    await page.waitForSelector('.row.streaming');
    await page.click('#menuBtn'); await page.click('#newChat'); // new chat Y while X is streaming
    await send('BBB question');
    await page.waitForFunction(() => document.querySelectorAll('.row.ai:not(.streaming)').length >= 1);
    await page.waitForTimeout(3600);                        // let X finish in background
    const data = await chatData();
    const x = data.find(c => c.messages[0]?.content === 'slow AAA question');
    const y = data.find(c => c.messages[0]?.content === 'BBB question');
    assert.ok(x && y);
    assert.equal(x.messages.length, 2); assert.equal(y.messages.length, 2);
    assert.ok(x.messages[1].content.includes('AAA') && !x.messages[1].content.includes('BBB'));
    assert.ok(y.messages[1].content.includes('BBB') && !y.messages[1].content.includes('AAA'));
    // returning to X shows its finished reply
    await page.click('#menuBtn'); await page.click('.chat-item:has-text("slow AAA question") .chat-open');
    await page.waitForSelector('.row.ai .md');
    assert.ok((await aiTexts()).join('').includes('رد AAA'));
  });

  await test('transient network failure auto-retries and succeeds', async () => {
    await page.click('#menuBtn'); await page.click('#newChat');
    await st({ failFirst: 2 });
    const before = (await st()).log.length;
    await send('retry me AAA');
    await page.waitForSelector('.row.ai:not(.streaming) .md', { timeout: 15000 });
    const s = await st(); assert.equal(s.log.length - before, 3);
    assert.equal((await aiTexts()).length, 1);
  });

  await test('all attempts fail -> error row with retry; retry works; no duplicate messages', async () => {
    await page.click('#menuBtn'); await page.click('#newChat');
    await st({ failFirst: 9 });
    await send('doomed AAA');
    await page.waitForSelector('.errbox', { timeout: 20000 });
    await st({ failFirst: 0 });
    await page.click('.errbox .btn');
    await page.waitForSelector('.row.ai:not(.streaming) .md');
    await page.waitForTimeout(450); const data = await chatData(); const c = data.find(c => c.messages[0]?.content === 'doomed AAA');
    assert.deepEqual(c.messages.map(m => m.role), ['user', 'assistant']); assert.ok(c.messages[1].content.includes('رد AAA') && !c.messages[1].incomplete);
  });

  await test('stream cut mid-way -> partial kept as INCOMPLETE (never shown as complete)', async () => {
    await page.click('#menuBtn'); await page.click('#newChat');
    await st({ mode: 'cut' });
    await send('cut AAA');
    await page.waitForSelector('.cut-flag', { timeout: 15000 });
    assert.ok((await page.textContent('.cut-flag')).includes('لم يكتمل'));
    assert.ok((await aiTexts()).join('').includes('partial text'));
    await st({ mode: 'ok' });
  });

  await test('Godot ZIP project: chip, findings, only relevant context sent', async () => {
    await page.click('#menuBtn'); await page.click('#newChat');
    await page.setInputFiles('#zipInput', 'gp.zip');
    await page.waitForSelector('.project-chip');
    const chip = await page.textContent('.project-chip'); assert.ok(chip.includes('gp.zip') && chip.includes('7 ملف'), chip);
    await page.click('.project-chip .attachment-remove.info');
    assert.ok((await page.textContent('.project-details')).includes('res://scripts/missing_data.gd'));
    await send('اشرح player.gd');
    await page.waitForSelector('.row.ai:not(.streaming) .md');
    const b = (await lastLog()).body;
    assert.ok(b.project.includes('### FILE scripts/player.gd') && b.project.includes('PROJECT MAP'));
    assert.ok(b.project.length <= 32000);
    assert.ok(!b.messages.some(m => JSON.stringify(m.content).includes('extends CharacterBody2D')), 'project files must not be duplicated in messages');
    // zip behaves like a normal chat attachment: card inside the user bubble, tray cleared after send
    assert.equal(await page.$('.project-chip'), null, 'tray cleared after send');
    const card = await page.textContent('.row.user .user-attachment.is-project');
    assert.ok(card.includes('gp.zip') && card.includes('7 ملف'), card);
  });

  await test('zip alone (no text) can be sent; steps panel lists what was read', async () => {
    await page.click('#menuBtn'); await page.click('#newChat');
    await page.setInputFiles('#zipInput', 'gp.zip');
    await page.waitForSelector('.project-chip');
    await page.click('#sendBtn');
    await page.waitForSelector('.row.ai:not(.streaming) .md');
    const b = (await lastLog()).body;
    const last = b.messages[b.messages.length - 1];
    assert.ok(JSON.stringify(last.content).includes('gp.zip'), 'fallback prompt mentions the zip');
    assert.ok(await page.$('.row.user .user-attachment.is-project'));
    const steps = await page.textContent('.row.ai .steps-sum');
    assert.ok(/خطوات|خطوة/.test(steps), steps);
    await page.click('.row.ai .steps-sum summary');
    const body = await page.textContent('.row.ai .steps-sum .steps');
    assert.ok(body.includes('gp.zip') && body.includes('قراءة') && body.includes('كتابة الرد'), body);
    await page.click('#menuBtn'); await page.click('.chat-item:has-text("اشرح player.gd") .chat-open');
  });

  await test('AI Fix button is gone and stale saved flag cannot enable it', async () => {
    assert.equal(await page.$('#codeFixToggle'), null);
    assert.equal(await page.evaluate(() => localStorage.getItem('nova_ai_code_fix_enabled_v1')), '0');
  });

  await test('attach sheet: 3 tiles (camera, photos, files), opens/closes, no overflow', async () => {
    await page.click('#attachBtn');
    const tiles = await page.$$eval('#attachMenu button:not([hidden])', n => n.map(x => [x.dataset.attach, x.textContent.trim()]));
    assert.deepEqual(tiles, [['camera', 'الكاميرا'], ['image', 'الصور'], ['file', 'الملفات']]);
    const r = await page.$eval('#attachMenu', n => { const b = n.getBoundingClientRect(); return { l: b.left, r: b.right, w: innerWidth, vis: getComputedStyle(n).display }; });
    assert.ok(r.l >= 0 && r.r <= r.w && r.vis === 'grid', JSON.stringify(r));
    const [chooser] = await Promise.all([page.waitForEvent('filechooser'), page.click('#attachMenu [data-attach="file"]')]);
    assert.ok(chooser.isMultiple()); 
    assert.equal(await page.$eval('#attachMenu', n => n.hidden), true);
    await page.click('#attachBtn'); await page.click('#sendBtn', { force: true }).catch(() => {});
    await page.mouse.click(5, 5);
    assert.equal(await page.$eval('#attachMenu', n => n.hidden), true, 'outside click closes');
  });

  await test('draft survives chat switch; composer stays visible on small phone; no horizontal overflow', async () => {
    await page.fill('#input', 'مسودة مهمة');
    await page.click('#menuBtn'); await page.click('#newChat');
    assert.equal(await page.inputValue('#input'), '');
    await page.click('#menuBtn'); await page.click('.chat-item:has-text("اشرح player.gd") .chat-open');
    assert.equal(await page.inputValue('#input'), 'مسودة مهمة');
    const m = await page.evaluate(() => ({ sw: document.documentElement.scrollWidth, cw: document.documentElement.clientWidth, top: document.querySelector('#composer').getBoundingClientRect(), vh: innerHeight }));
    assert.ok(m.sw <= m.cw, `overflow ${m.sw}>${m.cw}`); assert.ok(m.top.bottom <= m.vh + 1 && m.top.top > 300, JSON.stringify(m.top));
  });

  await test('textarea autosizes then caps; persistence after reload', async () => {
    await page.fill('#input', Array(12).fill('سطر').join('\n'));
    const h = await page.$eval('#input', n => n.getBoundingClientRect().height); assert.ok(h > 80 && h <= 170, String(h));
    await page.fill('#input', '');
    await page.reload();
    await page.waitForSelector('.row');
    assert.ok((await chatData()).length >= 6);
    assert.equal(errors.length, 0, errors.join('|'));
  });

  await page.screenshot({ path: 'mobile.png' });
  await browser.close();
  console.log(passed + ' passed');
})();
