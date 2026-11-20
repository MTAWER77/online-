import worker from './worker.mjs';
import assert from 'node:assert/strict';

const kv = new Map();
const AUTH = { get: async (k) => kv.get(k) ?? null, put: async (k, v) => { kv.set(k, v); } };
const env = { SESSION_SECRET: 'x'.repeat(32), ADMIN_USERNAME: 'boss', ADMIN_PASSWORD: 'adminpass1', FREE_LIMIT: '3', AUTH, GROQ_API_KEY: 'k' };

globalThis.fetch = async () => new Response(
  new TextEncoder().encode('data: ' + JSON.stringify({ choices: [{ delta: { content: 'ok' } }] }) + '\n\ndata: ' + JSON.stringify({ choices: [{ delta: {}, finish_reason: 'stop' }] }) + '\n\ndata: [DONE]\n\n'),
  { status: 200, headers: { 'content-type': 'text/event-stream' } });

const call = (path, body, cookie) => worker.fetch(new Request('https://x' + path, {
  method: body === undefined ? 'GET' : 'POST', headers: cookie ? { Cookie: cookie } : {}, body: body === undefined ? undefined : JSON.stringify(body),
}), env);
const cookieOf = (res) => (res.headers.get('set-cookie') || '').split(';')[0];
const chat = (cookie) => call('/api/chat', { messages: [{ role: 'user', content: 'hi' }] }, cookie);

// no session -> 401
let r = await chat(); assert.equal(r.status, 401); assert.equal((await r.json()).code, 'auth_required');
// register + validation
r = await call('/api/register', { username: 'a', password: '123456' }); assert.equal(r.status, 400);
r = await call('/api/register', { username: 'ahmed', password: '123' }); assert.equal(r.status, 400);
r = await call('/api/register', { username: 'ahmed', password: '123456' }); assert.equal(r.status, 200);
const ck = cookieOf(r); assert.ok(ck.startsWith('nova_session='));
assert.equal((await r.json()).remaining, 3);
r = await call('/api/register', { username: 'AHMED', password: '123456' }); assert.equal(r.status, 409);
r = await call('/api/register', { username: 'boss', password: '123456' }); assert.equal(r.status, 409);
// 3 messages ok, 4th blocked
for (let i = 0; i < 3; i++) { r = await chat(ck); assert.equal(r.status, 200); await r.text(); }
r = await chat(ck); assert.equal(r.status, 429); assert.equal((await r.json()).code, 'limit_reached');
r = await call('/api/me', undefined, ck); assert.equal((await r.json()).remaining, 0);
// forged / tampered cookie
r = await chat(ck.slice(0, -2) + 'zz'); assert.equal(r.status, 401);
// wrong password, then good login
r = await call('/api/login', { username: 'ahmed', password: 'wrongpw' }); assert.equal(r.status, 401);
r = await call('/api/login', { username: 'ahmed', password: '123456' }); assert.equal(r.status, 200);
// admin unlimited
r = await call('/api/login', { username: 'boss', password: 'adminpass1' }); assert.equal(r.status, 200);
const ad = cookieOf(r);
for (let i = 0; i < 8; i++) { r = await chat(ad); assert.equal(r.status, 200); await r.text(); }
assert.equal((await (await call('/api/me', undefined, ad)).json()).unlimited, true);
// lockout
for (let i = 0; i < 8; i++) await call('/api/login', { username: 'ghost', password: 'wrongpw' });
r = await call('/api/login', { username: 'ghost', password: 'wrongpw' }); assert.equal(r.status, 429);
// auth disabled -> open
const open = { GROQ_API_KEY: 'k' };
r = await worker.fetch(new Request('https://x/api/chat', { method: 'POST', body: JSON.stringify({ messages: [{ role: 'user', content: 'hi' }] }) }), open);
assert.equal(r.status, 200);
console.log('AUTH TESTS PASSED');

// admin must work even when the KV binding is missing, and tolerate stray whitespace in secrets
{
  const e2 = { SESSION_SECRET: 'y'.repeat(32), ADMIN_USERNAME: 'nova_owner ', ADMIN_PASSWORD: 'rv2HRKlCQ8JYsa\n', GROQ_API_KEY: 'k' };
  const go = (path, body, cookie) => worker.fetch(new Request('https://x' + path, { method: body ? 'POST' : 'GET', headers: cookie ? { Cookie: cookie } : {}, body: body ? JSON.stringify(body) : undefined }), e2);
  let r = await go('/api/login', { username: 'nova_owner', password: 'rv2HRKlCQ8JYsa' });
  assert.equal(r.status, 200);
  const c = (r.headers.get('set-cookie') || '').split(';')[0];
  r = await go('/api/chat', { messages: [{ role: 'user', content: 'hi' }] }, c); assert.equal(r.status, 200); await r.text();
  r = await go('/api/health'); const h = await r.json(); assert.equal(h.auth, true); assert.equal(h.authKv, false); assert.equal(h.adminConfigured, true);
  r = await go('/api/register', { username: 'someone', password: '123456' }); assert.equal(r.status, 500);
  console.log('ADMIN-WITHOUT-KV TESTS PASSED');
}
