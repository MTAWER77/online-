# التحديث التلقائي (PCK patch)

اللعبة بتفتح على شاشة `updater.tscn`: بتفحص `version.json`، ولو فيه build أحدث بتنزّل `patch.pck` وتحمّله وتكمل للقائمة. لو مفيش نت بتكمل عادي.

## كل مرة عايز تنزّل تحديث
1. في `scripts/updater/game_version.gd` زوّد `BUILD` (و `VERSION` للعرض).
2. صدّر **PCK كامل**: Godot → Project → Export → (أي preset) → *Export PCK/Zip* → `build/patch.pck`
   (أو من الطرفية: `godot --headless --export-pack "Windows Desktop" build/patch.pck`).
3. اعمل version.json:
   `python3 tools/make_patch.py build/patch.pck --build 2 --version 0.2.0 --url https://github.com/MTAWER77/online-/releases/download/v0.2.0/patch.pck`
4. ارفع `patch.pck` و `version.json` على GitHub Release جديد (اسم الـ tag `v0.2.0`):
   `gh release create v0.2.0 build/patch.pck build/version.json --title v0.2.0`

الرابط الافتراضي لـ `version_url` هو `releases/latest/download/version.json`، فلازم الـ repo يكون **public** وآخر release يكون فيه `version.json`.

## ملاحظات
- بيشتغل بس على نسخة متصدّرة (مش في المحرر، ولا على الويب).
- بيحدّث السكربتات والمشاهد والموديلات. مش بيحدّث المحرك (Godot) نفسه، ولو غيّرت إضافة native لازم تصدّر نسخة كاملة.
- الـ PCK لازم يتصدّر بنفس نسخة Godot (4.7) اللي اتصدّرت بيها اللعبة.
- الأونلاين: الـ host مش بيقدر يبدأ لو نسخة اللاعب التاني مختلفة، ورقم الـ build ظاهر جنب كل لاعب في الروم.
- أي حد يتحكم في الرابط بيتحكم في اللعبة (الـ patch فيه كود). استخدم رابطك أنت فقط، والـ sha256 بيأكد إن الملف وصل سليم.
