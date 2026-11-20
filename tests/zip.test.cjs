const { chromium } = require('playwright'); const assert = require('node:assert/strict'); const fs = require('fs');
(async () => {
  const b = await chromium.launch(); const page = await (await b.newContext({ viewport: { width: 360, height: 640 }, acceptDownloads: true })).newPage();
  const errs = []; page.on('pageerror', e => errs.push(e.message));
  await page.goto('http://localhost:8799');
  await page.setInputFiles('#fileInput', '/tmp/pz.zip');
  await page.waitForSelector('.project-chip'); console.log('chip:', (await page.textContent('.project-chip')).replace(/\s+/g, ' '));
  await page.click('.project-chip .attachment-remove:not(.info)'); // remove project
  await page.setInputFiles('#fileInput', 'gp.zip');
  await page.waitForSelector('.project-chip');
  await page.click('#codeFixToggle'); await page.fill('#input', 'اصلح player.gd'); await page.click('#sendBtn');
  await page.waitForSelector('.generated-zip.alt', { timeout: 10000 });
  const [d1] = await Promise.all([page.waitForEvent('download'), page.click('.generated-zip:not(.alt)')]);
  await d1.saveAs('/tmp/out1.zip');
  const [d2] = await Promise.all([page.waitForEvent('download'), page.click('.generated-zip.alt')]);
  await d2.saveAs('/tmp/out2.zip');
  assert.equal(errs.length, 0, errs.join('|')); console.log('ok', d1.suggestedFilename(), d2.suggestedFilename());
  await b.close();
})();
