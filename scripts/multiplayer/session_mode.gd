extends RefCounted
## scripts/multiplayer/session_mode.gd
## علم بسيط بيحدد لو اللعبة شغالة أوفلاين (لاعب واحد من غير GD-Sync).
## القائمة الرئيسية بتظبطه، و NetworkManager بيقراه.

static var offline: bool = false
