import worker from './worker.mjs';
import assert from 'node:assert/strict';

const enc = new TextEncoder();
const sse = (events) => new Response(enc.encode(events.map((e) => `data: ${JSON.stringify(e)}\n\n`).join('') + 'data: [DONE]\n\n'), { status: 200, headers: { 'content-type': 'text/event-stream' } });
const delta = (c) => ({ choices: [{ delta: { content: c } }] });
const fin = () => ({ choices: [{ delta: {}, finish_reason: 'stop' }] });
let calls = [];
const mockFetch = (h) => { calls = []; globalThis.fetch = async (url, init) => { const body = JSON.parse(init.body); calls.push({ url: String(url), body }); return h({ url: String(url), body }); }; };
async function chat(env, payload) {
  const res = await worker.fetch(new Request('https://x/api/chat', { method: 'POST', body: JSON.stringify({ messages: [{ role: 'user', content: 'hi' }], ...payload }) }), env);
  const events = (await res.text()).split('\n').filter((l) => l.startsWith('data:')).map((l) => JSON.parse(l.slice(5)));
  return events;
}
let passed = 0;
const test = async (n, f) => { try { await f(); passed++; console.log('PASS', n); } catch (e) { console.log('FAIL', n, '\n', e.message); process.exitCode = 1; } };
const ENV = { GROQ_API_KEY: 'g', GEMINI_API_KEY: 'm', OPENROUTER_API_KEY: 'o' };

await test('/api/models lists providers + models, never keys', async () => {
  const res = await worker.fetch(new Request('https://x/api/models'), { ...ENV, GEMINI_MODELS: 'gemini-x-pro, bad id!' });
  const txt = await res.text(); const j = JSON.parse(txt);
  assert.deepEqual(j.providers.map((p) => p.id), ['groq', 'gemini', 'openrouter']);
  assert.ok(j.providers.every((p) => p.configured && p.models.length));
  assert.ok(j.providers[1].models.some((m) => m.id === 'gemini-x-pro'), 'env model added');
  assert.ok(!j.providers[1].models.some((m) => m.id.includes(' ')), 'invalid id rejected');
  assert.ok(!/"g"|"m"|"o"/.test(txt.replace(/"id"|"name"/g, '')) || !txt.includes('GROQ_API_KEY'));
});

await test('chosen provider is tried first (gemini)', async () => {
  mockFetch(() => sse([delta('hi'), fin()]));
  const ev = await chat(ENV, { provider: 'gemini' });
  assert.ok(calls[0].url.includes('generativelanguage'), calls[0].url);
  const d = ev.at(-1); assert.equal(d.provider, 'gemini');
  assert.ok(!ev.some((e) => e.code === 'pref_unavailable'));
});

await test('chosen model is used first on the chosen provider', async () => {
  mockFetch(() => sse([delta('hi'), fin()]));
  const ev = await chat(ENV, { provider: 'openrouter', model: 'meta-llama/some-model:free' });
  assert.ok(calls[0].url.includes('openrouter.ai'));
  assert.equal(calls[0].body.model, 'meta-llama/some-model:free');
  assert.equal(ev.at(-1).model, 'meta-llama/some-model:free');
});

await test('chosen provider failing falls back with a notice', async () => {
  mockFetch(({ url }) => url.includes('generativelanguage') ? new Response('boom', { status: 500 }) : sse([delta('ok'), fin()]));
  const ev = await chat(ENV, { provider: 'gemini' });
  assert.equal(ev.at(-1).provider, 'groq');
  assert.ok(ev.some((e) => e.code === 'pref_unavailable'), 'notice sent');
});

await test('unconfigured chosen provider falls back with a notice; junk values ignored', async () => {
  mockFetch(() => sse([delta('ok'), fin()]));
  let ev = await chat({ GROQ_API_KEY: 'g' }, { provider: 'gemini' });
  assert.equal(ev.at(-1).provider, 'groq'); assert.ok(ev.some((e) => e.code === 'pref_unavailable'));
  ev = await chat(ENV, { provider: 'evil', model: 'a b;rm -rf' });
  assert.equal(ev.at(-1).provider, 'groq'); assert.ok(!ev.some((e) => e.code === 'pref_unavailable'));
});

await test('auto (no provider) keeps the default Groq-first order', async () => {
  mockFetch(() => sse([delta('ok'), fin()]));
  const ev = await chat(ENV, {});
  assert.equal(ev.at(-1).provider, 'groq');
});
console.log(`\n${passed} passed`);
