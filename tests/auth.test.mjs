import worker from './worker.mjs';
import assert from 'node:assert/strict';

globalThis.fetch = async () => new Response(
  new TextEncoder().encode('data: ' + JSON.stringify({ choices: [{ delta: { content: 'ok' } }] }) + '\n\ndata: ' + JSON.stringify({ choices: [{ delta: {}, finish_reason: 'stop' }] }) + '\n\ndata: [DONE]\n\n'),
  { status: 200, headers: { 'content-type': 'text/event-stream' } });

const mkKv = () => { const m = new Map(); return { get: async (k) => m.get(k) ?? null, put: async (k, v) => { m.set(k, v); } }; };

// tiny cookie jar = one "device"
function device(env, ip = '1.1.1.1') {
  const jar = {};
  const call = async (path, body) => {
    const headers = { 'CF-Connecting-IP': ip };
    const ck = Object.entries(jar).map(([k, v]) => `${k}=${v}`).join('; ');
    if (ck) headers.Cookie = ck;
    const res = await worker.fetch(new Request('https://x' + path, { method: body === undefined ? 'GET' : 'POST', headers, body: body === undefined ? undefined : JSON.stringify(body) }), env);
    const sc = res.headers.get('set-cookie');
    if (sc) { const [kv] = sc.split(';'); const i = kv.indexOf('='); const v = kv.slice(i + 1); if (v) jar[kv.slice(0, i)] = v; else delete jar[kv.slice(0, i)]; }
    return res;
  };
  const chat = async (extra) => { const r = await call('/api/chat', { messages: [{ role: 'user', content: 'hi' }], ...extra }); if (r.status === 200) await r.text(); return r; };
  const me = async () => (await call('/api/me')).json();
  return { call, chat, me, jar };
}

const base = { SESSION_SECRET: 's'.repeat(32), ACTIVATION_CODE: 'NOVA-TEST-0001, NOVA-TEST-0002', FREE_LIMIT: '4', GROQ_API_KEY: 'k' };

for (const withKv of [true, false]) {
  const tag = withKv ? '[KV]' : '[cookie-only]';
  const env = { ...base, ...(withKv ? { AUTH: mkKv() } : {}) };
  const d = device(env);

  assert.equal((await d.me()).remaining, 4, tag + ' new visitor has 4');
  for (let i = 0; i < 4; i++) assert.equal((await d.chat()).status, 200, tag + ' msg ' + (i + 1));
  let r = await d.chat(); assert.equal(r.status, 429); assert.equal((await r.json()).code, 'limit_reached');
  assert.equal((await d.me()).remaining, 0);

  // failed request (400) is not charged
  const d2 = device(env, '2.2.2.2');
  r = await d2.call('/api/chat', { messages: [] }); assert.equal(r.status, 400);
  assert.equal((await d2.me()).remaining, 4, tag + ' failed request refunded');

  // tampered cookie is treated as a new device, never as a bigger quota
  const forged = device(env, '3.3.3.3'); forged.jar.nova_dev = d.jar.nova_dev.slice(0, -3) + 'AAA';
  assert.equal((await forged.me()).remaining, 4);

  // activation: wrong code, right code, unlimited, survives
  r = await d.call('/api/activate', { code: 'nope' }); assert.equal(r.status, 401);
  r = await d.call('/api/activate', { code: ' NOVA-TEST-0002 ' }); assert.equal(r.status, 200);
  assert.equal((await d.me()).unlimited, true);
  for (let i = 0; i < 10; i++) assert.equal((await d.chat()).status, 200, tag + ' unlimited');
  // deactivate -> back to the (used up) free quota
  await d.call('/api/deactivate', {});
  assert.equal((await d.chat()).status, 429);
  // reactivate then rotate the code on the server: old activation stops working
  await d.call('/api/activate', { code: 'NOVA-TEST-0001' });
  assert.equal((await d.chat()).status, 200);
  const rotated = { ...env, ACTIVATION_CODE: 'NEW-CODE-9999' };
  const saved = { ...d.jar };
  const d3 = device(rotated, '1.1.1.1'); Object.assign(d3.jar, saved);
  assert.equal((await d3.chat()).status, 429, tag + ' revoked code stops unlocking');
}

// KV only: clearing cookies cannot be abused forever (per-IP cap = limit * 5 = 20)
{
  const env = { ...base, AUTH: mkKv() };
  let ok = 0;
  for (let i = 0; i < 8; i++) { const dv = device(env, '9.9.9.9'); for (let j = 0; j < 4; j++) { if ((await dv.chat()).status === 200) ok++; } }
  assert.equal(ok, 20, 'IP cap');
  assert.equal((await device(env, '8.8.8.8').chat()).status, 200, 'other IP unaffected');
}

// brute-force lockout on activation codes (KV)
{
  const env = { ...base, AUTH: mkKv() };
  const d = device(env, '7.7.7.7');
  for (let i = 0; i < 10; i++) await d.call('/api/activate', { code: 'bad' + i });
  assert.equal((await d.call('/api/activate', { code: 'NOVA-TEST-0001' })).status, 429);
}

// daily mode label
{
  const env = { ...base, FREE_PERIOD: 'daily', AUTH: mkKv() };
  const d = device(env); for (let i = 0; i < 4; i++) await d.chat();
  const r = await d.chat(); assert.equal(r.status, 429); assert.match((await r.json()).error, /النهارده/);
}

// SESSION_SECRET missing -> completely open
{
  const d = device({ GROQ_API_KEY: 'k' });
  for (let i = 0; i < 6; i++) assert.equal((await d.chat()).status, 200);
  const m = await d.me(); assert.equal(m.limited, false);
  assert.equal((await d.call('/api/activate', { code: 'x' })).status, 400);
}

// health reports the setup
{
  const d = device({ ...base, AUTH: mkKv() });
  const h = await (await d.call('/api/health')).json();
  assert.equal(h.quota, true); assert.equal(h.quotaKv, true); assert.equal(h.activationConfigured, true);
}
console.log('QUOTA + ACTIVATION TESTS PASSED');
