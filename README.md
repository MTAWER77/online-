# NOVA AI V0.4

شات بوت ويب (PWA) بواجهة فاتحة، يعمل بـ **DeepSeek** عبر Cloudflare Worker مع بث حقيقي للرد (يظهر النص أثناء الكتابة).

## التشغيل محليًا
```bash
cd NOVA-AI
npx wrangler login
echo 'DEEPSEEK_API_KEY=ضع_المفتاح_هنا' > .dev.vars   # مستثنى في .gitignore
npx wrangler dev
```

## النشر
```bash
npx wrangler secret put DEEPSEEK_API_KEY
npx wrangler deploy
```
مفتاح DeepSeek من https://platform.deepseek.com/api_keys

## الإعدادات (اختياري، من Cloudflare: Workers ← Settings ← Variables)
- `DEEPSEEK_MODEL`: الافتراضي `deepseek-v4-flash` (الاسم القديم `deepseek-chat` أُوقف في 24 يوليو 2026 حسب وثائق DeepSeek).
- `MAX_OUTPUT_TOKENS`: الافتراضي 2048 (من 256 إلى 8192).
- آخر 12 رسالة فقط تُرسل للنموذج.

## تغيير اللون
في أول `public/styles.css` غيّر `--accent` و`--accent2` و`--accent-soft`.

## الهيكل
`worker/index.js` (الـ API والبث) · `public/` (الواجهة، `render.js` للـ Markdown وتلوين الأكواد، manifest، service worker) · `wrangler.jsonc`

لا ترفع `.dev.vars` ولا أي مفتاح إلى GitHub.
