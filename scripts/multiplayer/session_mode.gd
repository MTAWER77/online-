extends RefCounted
## scripts/multiplayer/session_mode.gd
## علم بسيط بيحدد لو اللعبة شغالة أوفلاين (لاعب واحد من غير GD-Sync).
## القائمة الرئيسية بتظبطه، والدراجة بتقراه.

static var offline: bool = false
