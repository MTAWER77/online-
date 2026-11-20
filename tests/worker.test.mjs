import worker from './worker.mjs';
import assert from 'node:assert/strict';

const enc = new TextEncoder();
const sse = (events, { done = true } = {}) => {
  const body = events.map(e => `data: ${JSON.stringify(e)}\n\n`).join('') + (done ? 'data: [DONE]\n\n' : '');
  return new Response(enc.encode(body), { status: 200, headers: { 'content-type': 'text/event-stream' } });
};
const delta = (content, extra = {}) => ({ choices: [{ delta: { content, ...extra } }] });
const fin = (r = 'stop') => ({ choices: [{ delta: {}, finish_reason: r }] });

let calls = [];
function mockFetch(handler) {
  calls = [];
  globalThis.fetch = async (url, init) => {
    const body = JSON.parse(init.body);
    const key = init.headers.Authorization.replace('Bearer ', '');
    calls.push({ url, key, body });
    return handler({ url, key, body, n: calls.length });
  };
}
async function chat(env, payload) {
  const req = new Request('https://x/api/chat', { method: 'POST', body: JSON.stringify({ messages: [{ role: 'user', content: 'hi' }], ...payload }) });
  const res = await worker.fetch(req, env);
  const ct = res.headers.get('content-type');
  if (!ct.includes('event-stream')) return { json: await res.json(), status: res.status, events: [] };
  const text = await res.text();
  const events = text.split('\n').filter(l => l.startsWith('data:')).map(l => JSON.parse(l.slice(5)));
  return { events, status: res.status, text };
}
const t = (ev) => ev.filter(e => e.t).map(e => e.t).join('');
let passed = 0;
const test = async (name, fn) => { try { await fn(); passed++; console.log('PASS', name); } catch (e) { console.log('FAIL', name, '\n', e.message); process.exitCode = 1; } };

await test('normal stream completes with done', async () => {
  mockFetch(() => sse([delta('مرحبا'), delta(' بك'), fin()]));
  const r = await chat({ GROQ_API_KEY: 'k1' }, {});
  assert.equal(t(r.events), 'مرحبا بك');
  const d = r.events.at(-1); assert.equal(d.done, true); assert.equal(d.provider, 'groq');
  assert.equal(calls[0].body.stream, true);
});

await test('401 rotates to next key, same model', async () => {
  mockFetch(({ key }) => key === 'bad' ? new Response('{"error":"invalid"}', { status: 401 }) : sse([delta('ok'), fin()]));
  const r = await chat({ GROQ_API_KEYS: 'bad,good' }, {});
  assert.equal(t(r.events), 'ok');
  assert.equal(calls[0].body.model, calls[1].body.model);
});

await test('429 rotates key first, then model', async () => {
  mockFetch(({ key, body }) => (key === 'a' ) ? new Response('rate', { status: 429 }) : sse([delta('ok'), fin()]));
  const r = await chat({ GROQ_API_KEYS: 'a,b' }, {});
  assert.equal(t(r.events), 'ok'); assert.equal(calls.length, 2); assert.equal(calls[1].key, 'b');
});

await test('404 model error goes to next model WITHOUT burning other keys', async () => {
  mockFetch(({ body }) => body.model === 'openai/gpt-oss-120b' ? new Response('no model', { status: 404 }) : sse([delta('ok'), fin()]));
  const r = await chat({ GROQ_API_KEYS: 'a,b' }, {});
  assert.equal(t(r.events), 'ok');
  assert.equal(calls.length, 2); assert.equal(calls[1].key, 'a');
});

await test('401 on groq falls to gemini', async () => {
  mockFetch(({ url }) => url.includes('groq') ? new Response('x', { status: 401 }) : sse([delta('from gemini'), fin()]));
  const r = await chat({ GROQ_API_KEY: 'g', GEMINI_API_KEY: 'm' }, {});
  assert.equal(t(r.events), 'from gemini'); assert.equal(r.events.at(-1).provider, 'gemini');
});

await test('all providers fail -> clear error, no done', async () => {
  mockFetch(() => new Response('boom', { status: 503 }));
  const r = await chat({ GROQ_API_KEY: 'g', GEMINI_API_KEY: 'm', OPENROUTER_API_KEY: 'o' }, {});
  const err = r.events.find(e => e.error); assert.ok(err); assert.ok(!r.events.some(e => e.done));
});

await test('all rate limited -> rate_limited code', async () => {
  mockFetch(() => new Response('slow', { status: 429 }));
  const r = await chat({ GROQ_API_KEY: 'g' }, {});
  assert.equal(r.events.find(e => e.error).code, 'rate_limited');
});

await test('stream cut without finish -> error incomplete, never done', async () => {
  mockFetch(() => sse([delta('partial')], { done: false }));
  const r = await chat({ GROQ_API_KEY: 'g' }, {});
  assert.equal(t(r.events), 'partial');
  assert.ok(!r.events.some(e => e.done)); assert.equal(r.events.find(e => e.error).code, 'incomplete');
});

await test('Think on gpt-oss: reasoning_effort high, reasoning hidden, no leak, status thinking', async () => {
  mockFetch(() => sse([{ choices: [{ delta: { reasoning: 'secret thoughts' } }] }, delta('answer'), fin()]));
  const r = await chat({ GROQ_API_KEY: 'g' }, { think: true });
  const b = calls[0].body;
  assert.equal(b.reasoning_effort, 'high'); assert.equal(b.include_reasoning, false);
  assert.ok(r.events.some(e => e.status === 'thinking'));
  assert.ok(!r.text.includes('secret thoughts'));
  assert.equal(t(r.events), 'answer');
});

await test('Think on qwen uses reasoning_format hidden, no include_reasoning', async () => {
  mockFetch(({ body }) => body.model.startsWith('openai/gpt-oss') ? new Response('x', { status: 404 }) : sse([delta('ok'), fin()]));
  await chat({ GROQ_API_KEY: 'g' }, { think: true });
  const q = calls.find(c => /qwen/.test(c.body.model)).body;
  assert.equal(q.reasoning_format, 'hidden'); assert.equal(q.include_reasoning, undefined);
});

await test('Think rejected (400 reasoning) -> retried without params + notice', async () => {
  mockFetch(({ body }) => body.reasoning_effort ? new Response('reasoning_effort not supported', { status: 400 }) : sse([delta('ok'), fin()]));
  const r = await chat({ GROQ_API_KEY: 'g' }, { think: true });
  assert.equal(t(r.events), 'ok'); assert.ok(r.events.some(e => e.notice === 'think_dropped'));
  assert.equal(calls[1].body.reasoning_effort, undefined);
});

await test('Search+Think together: tools + medium effort + sources appended', async () => {
  mockFetch(() => new Response(JSON.stringify({ choices: [{ message: { content: 'نتيجة', annotations: [{ url_citation: { url: 'https://docs.godotengine.org/x', title: 'Docs' } }] }, finish_reason: 'stop' }] }), { status: 200 }));
  const r = await chat({ GROQ_API_KEY: 'g' }, { search: true, think: true });
  const b = calls[0].body;
  assert.equal(b.stream, false); assert.deepEqual(b.tools, [{ type: 'browser_search' }]); assert.equal(b.reasoning_effort, 'medium');
  assert.ok(t(r.events).includes('https://docs.godotengine.org/x'));
  const d = r.events.at(-1); assert.equal(d.search, true); assert.equal(d.think, true); assert.equal(d.sources.length, 1);
  assert.ok(r.events[0].status === 'start' && r.events.some(e => e.status === 'searching'));
});

await test('Search without Groq key -> notice + normal fallback prompt (no fake sources)', async () => {
  mockFetch(() => sse([delta('plain'), fin()]));
  const r = await chat({ GEMINI_API_KEY: 'm' }, { search: true });
  assert.ok(r.events.some(e => e.notice === 'search_unsupported'));
  assert.ok(calls[0].body.messages[0].content.includes('do NOT claim you searched'));
  assert.equal(calls[0].body.tools, undefined);
});

await test('Search failure on groq falls back to normal answer with notice', async () => {
  mockFetch(({ body }) => body.tools ? new Response('tool unsupported', { status: 400 }) : sse([delta('plain'), fin()]));
  const r = await chat({ GROQ_API_KEY: 'g' }, { search: true });
  assert.ok(r.events.some(e => e.notice === 'search_failed')); assert.equal(t(r.events), 'plain');
});

await test('Search + image: search disabled with notice, vision model used', async () => {
  mockFetch(() => sse([delta('img'), fin()]));
  const img = 'data:image/png;base64,iVBORw0KGgo=';
  const r = await chat({ GROQ_API_KEY: 'g' }, { search: true, messages: [{ role: 'user', content: [{ type: 'text', text: 'what' }, { type: 'image_url', image_url: { url: img } }] }] });
  assert.ok(r.events.some(e => e.notice === 'search_images')); assert.ok(/qwen/.test(calls[0].body.model));
});

await test('Empty content + length -> explicit error (reasoning ate the budget)', async () => {
  mockFetch(() => sse([fin('length')]));
  const r = await chat({ GROQ_API_KEY: 'g' }, { think: true });
  assert.equal(r.events.find(e => e.error).code, 'empty');
});

await test('finish=length with content -> done MAX_TOKENS', async () => {
  mockFetch(() => sse([delta('abc'), fin('length')]));
  const r = await chat({ GROQ_API_KEY: 'g' }, {});
  assert.equal(r.events.at(-1).finish, 'MAX_TOKENS');
});

await test('context + project + intent injected into system prompt; avoidModels respected', async () => {
  mockFetch(() => sse([delta('ok'), fin()]));
  await chat({ GROQ_API_KEY: 'g' }, { context: 'files: player.gd', project: 'PROJ-MAP', intent: 'fix', avoidModels: ['openai/gpt-oss-120b'] });
  const sys = calls[0].body.messages[0].content;
  assert.ok(sys.includes('player.gd') && sys.includes('PROJ-MAP') && sys.includes('FIX'));
  assert.notEqual(calls[0].body.model, 'openai/gpt-oss-120b');
});

await test('validation errors are plain JSON 400', async () => {
  const r = await worker.fetch(new Request('https://x/api/chat', { method: 'POST', body: JSON.stringify({ messages: [] }) }), { GROQ_API_KEY: 'g' });
  assert.equal(r.status, 400);
});

await test('generate-files fix mode: findings, tested:false, truncated detected', async () => {
  const good = { message: 'm', findings: [{ file: 'res://a.gd', line: 3, issue: 'x', fix: 'y' }], files: [{ name: 'a.gd', content: 'extends Node' }] };
  mockFetch(() => new Response(JSON.stringify({ choices: [{ message: { content: JSON.stringify(good) }, finish_reason: 'stop' }] }), { status: 200 }));
  let res = await worker.fetch(new Request('https://x/api/generate-files', { method: 'POST', body: JSON.stringify({ mode: 'fix', messages: [{ role: 'user', content: 'fix' }] }) }), { GROQ_API_KEY: 'g' });
  let j = await res.json(); assert.equal(j.tested, false); assert.equal(j.findings.length, 1); assert.equal(j.files[0].name, 'a.gd');
  mockFetch(() => new Response(JSON.stringify({ choices: [{ message: { content: '{"files":[' }, finish_reason: 'length' }] }), { status: 200 }));
  res = await worker.fetch(new Request('https://x/api/generate-files', { method: 'POST', body: JSON.stringify({ messages: [{ role: 'user', content: 'make' }] }) }), { GROQ_API_KEY: 'g' });
  j = await res.json(); assert.equal(j.code, 'truncated');
});

console.log(`\n${passed} passed`);
