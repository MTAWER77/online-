# NOVA AI V0.3

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
- `worker/index.js`: واجهة `/api/chat` تكلّم Gemini (النموذج الافتراضي `gemini-3.6-flash` مع احتياطي `gemini-3.5-flash`؛ لتغييره أضف متغير `GEMINI_MODEL` من لوحة Cloudflare: Workers ← Settings ← Variables، دون تعديل الكود).
- `public/`: الواجهة (`index.html`, `styles.css`, `app.js`) + `render.js` (Markdown وتلوين الأكواد) + manifest + service worker + الأيقونات.
- `wrangler.jsonc`: إعدادات Cloudflare.

## ملاحظات
- المحادثات تُحفظ في localStorage على الجهاز فقط.
- الـ Service Worker يخزّن ملفات الواجهة فقط، والمحادثة نفسها تحتاج إنترنت.
- خارج النطاق في V0.1: البحث، رفع الملفات، موصلات GitHub.
- لا ترفع `.dev.vars` ولا أي مفتاح إلى GitHub.

## جديد في V0.2
- واجهة جديدة (Sidebar، شاشة ترحيب باقتراحات، إعادة تسمية المحادثات، إعدادات: حجم الخط/تصدير/حذف الكل).
- شعار وهوية NOVA AI الأصلية (نجمة نوفا بمدار) في الموقع وأيقونة التطبيق.
- Markdown كامل (عناوين، قوائم، جداول، اقتباسات، روابط) وتلوين أكواد وزر نسخ لكل كود وللرد كاملًا وإعادة توليد.
- تحديث نموذج Gemini لأن `gemini-2.5-flash` له موعد إيقاف 16 أكتوبر 2026 حسب وثائق Google.

## جديد في V0.3 (بث حقيقي)
- الاتصال بـ Gemini صار عبر `streamGenerateContent?alt=sse`، والـ Worker يمرّر الأجزاء فور وصولها (SSE)، والواجهة تعرضها تدريجيًا مع مؤشر كتابة وزر إيقاف.
- سجل الرسائل المرسل إلى Gemini: آخر 12 رسالة فقط.
- حد طول الرد 2048 توكن. لزيادته أضف متغير `MAX_OUTPUT_TOKENS` (من 256 إلى 8192) في لوحة Cloudflare.
- عند انقطاع البث يظهر خطأ واضح مع "إعادة المحاولة" دون تكرار رسالتك.
