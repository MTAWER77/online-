# NOVA AI V0.1

شات بوت ويب (PWA) يعمل بـ Gemini عبر Cloudflare Worker. مفتاح Gemini يبقى في Secrets على الخادم فقط.

## المتطلبات
- Node.js 18+ وحساب Cloudflare مجاني
- مفتاح Gemini API من https://aistudio.google.com/apikey

## التشغيل محليًا
```bash
cd NOVA-AI
npx wrangler login
echo 'GEMINI_API_KEY=ضع_المفتاح_هنا' > .dev.vars   # الملف مستثنى في .gitignore
npx wrangler dev
```
افتح الرابط الذي يظهر (عادة http://localhost:8787).

## النشر على Cloudflare
```bash
npx wrangler secret put GEMINI_API_KEY   # الصق المفتاح عند الطلب
npx wrangler deploy
```
سيعطيك رابط `https://nova-ai.<حسابك>.workers.dev`.

## التثبيت على Android
افتح الرابط في Chrome ← القائمة ⋮ ← "تثبيت التطبيق" (أو زر "تثبيت" داخل الموقع). يلزم HTTPS (متوفر تلقائيًا على workers.dev).

## الهيكل
- `worker/index.js`: واجهة `/api/chat` تكلّم Gemini (النموذج `gemini-2.5-flash`، يمكن تغييره في أول الملف).
- `public/`: الواجهة (HTML/CSS/JS) + manifest + service worker + الأيقونات.
- `wrangler.jsonc`: إعدادات Cloudflare.

## ملاحظات
- المحادثات تُحفظ في localStorage على الجهاز فقط.
- الـ Service Worker يخزّن ملفات الواجهة فقط، والمحادثة نفسها تحتاج إنترنت.
- خارج النطاق في V0.1: البحث، رفع الملفات، موصلات GitHub.
- لا ترفع `.dev.vars` ولا أي مفتاح إلى GitHub.
