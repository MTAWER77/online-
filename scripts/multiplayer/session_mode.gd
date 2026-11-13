extends RefCounted
## scripts/multiplayer/session_mode.gd
## علم بسيط بيحدد لو اللعبة شغالة أوفلاين (لاعب واحد من غير GD-Sync).
## القائمة الرئيسية بتظبطه، والدراجة بتقراه.

static var offline: bool = false
# آخر ping اتقاس في اللوبي (ms)، -1 لو مش معروف. بيحدد معدل المزامنة.
static var last_ping_ms: float = -1.0
