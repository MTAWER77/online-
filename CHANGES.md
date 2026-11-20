# NOVA AI v0.5 - التغييرات
الملفات المعدلة: worker/index.js, public/app.js, public/index.html, public/styles.css, public/sw.js
ملف جديد: public/godot.js (تحليل مشاريع Godot) + tests/
Endpoints كما هي: /api/chat, /api/generate-files, /api/health
المفاتيح في Cloudflare Secrets فقط: GROQ_API_KEYS / GEMINI_API_KEYS / OPENROUTER_API_KEYS
اختبارات: node tests/worker.test.mjs ; node tests/godot.test.cjs ; tests/ui.test.cjs (playwright + server.cjs)

## v0.6 - نظام الحسابات
- تسجيل دخول/حساب جديد بيوزر وكلمة سر (PBKDF2 + كوكي HttpOnly موقّعة).
- الحسابات العادية: FREE_LIMIT رسائل (افتراضي 4) - FREE_PERIOD = total أو daily.
- حساب الأدمن (ADMIN_USERNAME / ADMIN_PASSWORD من Secrets): بدون حدود.
- Endpoints جديدة: /api/register /api/login /api/logout /api/me
- لو SESSION_SECRET مش مضبوط، النظام بيتعطل والموقع يفضل مفتوح زي v0.5.
- اختبار: node tests/auth.test.mjs
- v0.6: مؤشر الكتابة: نقطة بتتنفخ وترجع + نص متحرك + عدّاد ثواني + سطر 'فكّر لمدة N ثانية' فوق الرد.
- إصلاح: دخول الأدمن بيشتغل حتى لو AUTH KV مش مربوط، وبيتجاهل المسافات في الأسرار. /api/health بيوضّح auth و authKv و adminConfigured.

## v0.7 - مجاني بـ4 رسايل + كود تفعيل
- اتشال نظام الحسابات (تسجيل/دخول). أي حد يدخل مجاناً.
- كل جهاز له FREE_LIMIT رسائل (افتراضي 4) - والعدّاد في السيرفر (KV) مع سقف لكل IP.
- الإعدادات فيها "كود التفعيل": الكود الصحيح (ACTIVATION_CODE) بيشيل الحد على الجهاز ده.
- مسح الكود من السيرفر أو تغييره بيلغي التفعيل على كل الأجهزة.
- الطلب اللي بيفشل قبل ما الرد يبدأ مش بيتحسب من الرسايل.
- Endpoints: /api/me /api/activate /api/deactivate (اتشالت login/register/logout)

## v0.8 - إصلاح البحث + دارك مود + Think/Search بشكل DeepSeek
- إصلاح البحث ("تعذر تشغيل البحث الآن"):
  - طلب البحث بقى ياخد 8192 توكن (كان 4096 والتفكير كان بياكلها ويرجع رد فاضي).
  - لو الموديل رفض tool_choice بيتعاد الطلب بدونه، ولو رفض reasoning بيتعاد بدونه.
  - موديلات بحث إضافية: groq/compound و groq/compound-mini (بحث مدمج).
  - لو Groq فشل كله: بحث بديل بدون مفتاح (DuckDuckGo) والنتايج بتتحط للموديل والمصادر بتظهر، مع تنبيه.
  - رسالة الفشل بقت بتوضح كود الخطأ بين قوسين عشان نعرف السبب.
- Think: نص تفكير الموديل بيتبعت للواجهة (event r) ويظهر في لوحة قابلة للطي "فكّر لمدة N ثانية" زي DeepSeek.
- Search: المصادر بتظهر في لوحة "تم البحث في N مصادر" بروابط (event sources) وبتتحفظ مع الرد.
- شكل أزرار DeepThink / Search: أزرق عند التفعيل زي DeepSeek.
- دارك مود: زرار في الشريط العلوي + اختيار (فاتح/داكن/تلقائي) في الإعدادات، بيتحفظ وبيتطبق قبل الرسم بدون وميض.
- اختبارات: tests/worker.test.mjs (22) و tests/ui.test.cjs (14) كلها بتنجح.
