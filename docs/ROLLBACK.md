# Rollback فوق GDSync + Rapier

**ليه مش Netfox؟** Netfox بيشتغل على `multiplayer` بتاع Godot، و GDSync مش بيسجّل peer فيه، فالـ NetworkTime/RollbackSynchronizer مش هيشتغلوا.
اللي اتاخد من Netfox: الفكرة (state + input history + resim) وطريقة Rapier (`space_step` / `space_flush_queries` يدوي). الكود في `scripts/vehicles/unicycle.gd` (قسم Rollback).

## التشغيل
Project Settings → Physics → 3D → Physics Engine = **Rapier3D**. أونلاين بس. لو الـ engine تاني (Jolt) الكود القديم (snapshot + prediction) هو اللي بيشتغل زي ما هو.

## بيشتغل إزاي
- الاتنين بيحاكوا نفس الـ tick (120Hz) ونفس المحاكاة. كل واحد بيطبّق مدخلاته فورًا.
- المدخلات بتتبعت 30 مرة/ث، كل رسالة فيها آخر 24 tick (تكرار ضد ضياع الحزم). مفيش Transform بيتبعت كل frame.
- مدخلات الطرف التاني بتتوقّع (آخر قيمة، القفز مش بيتتوقّع). لما الحقيقية توصل وتختلف: رجوع لحالة الـ tick وإعادة المحاكاة (أقصى 90 tick).
- الـ host مرجع: كل 30 tick بيبعت حالته المؤكدة، والـ client لو الفرق > 3سم بيعدّل ويعيد المحاكاة. قرارات respawn/recover من الـ host بس وبتتبعت كـ event بـ tick.
- قفزة التصحيح بتتخفي على الشاشة (`rb_correction_decay`).
- الـ host بيبعت `go` والاتنين يبدأوا من tick 0 مع بعض (الـ host بيتأخر نص الـ ping).

## تحذير
نسخة Rapier المضافة `simd-parallel` مش cross-platform deterministic، يعني النتيجة ممكن تتفاوت شوية بين الأجهزة. ده بالظبط سبب تصحيح الـ host الدوري.

## اللوج (DebugLog tag RB)
كل 5 ثواني: rollbacks/ث، عمق متوسط، تصحيحات الـ host، خطأ متوسط (متر)، فرق المدخلات (tick)، مرفوض.
