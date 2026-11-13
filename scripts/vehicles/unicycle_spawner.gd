extends Node3D
## scripts/vehicles/unicycle_spawner.gd
## بيعمل الدراجة في مكانه. أوفلاين بنشيل الـ PropertySynchronizer قبل ما الدراجة تدخل الشجرة
## (لأنه بيحتاج GD-Sync شغال). الاتنين (host و client) بيعملوا نفس الدراجة بنفس الاسم والمكان.

const SessionMode = preload("res://scripts/multiplayer/session_mode.gd")
const DebugLog = preload("res://scripts/systems/debug_log.gd")

@export var unicycle_scene: PackedScene


func _ready() -> void:
	if unicycle_scene == null:
		push_error("UnicycleSpawner: مفيش unicycle_scene")
		return
	var unicycle := unicycle_scene.instantiate() as Node3D
	unicycle.name = "Unicycle"
	if SessionMode.offline or not GDSync.is_active():
		unicycle.get_node("PropertySynchronizer").free()
		DebugLog.say("SPAWN", "أوفلاين: من غير مزامنة")
	else:
		_tune_sync_rate(unicycle.get_node("PropertySynchronizer"))
	unicycle.transform = Transform3D.IDENTITY
	add_child(unicycle) # مكانه = مكان الـ spawner


# معدل المزامنة بيتحدد من آخر ping اتقاس في اللوبي: نت أضعف = مزامنة أقل (حِمل أقل على الشبكة)،
# وتنعيم أبطأ بنفس النسبة. الـ host بس هو اللي بيبعت، فبيتحدد بـ ping الـ host.
func _tune_sync_rate(sync: Node) -> void:
	var ping: float = SessionMode.last_ping_ms
	var rate: int = 60
	if ping >= 150.0:
		rate = 30
	elif ping >= 80.0:
		rate = 45
	sync.set("refresh_rate", rate)
	sync.set("interpolation_speed", maxf(8.0, rate * 0.2))
	DebugLog.say("SPAWN", "ping=%.0fms -> sync rate=%d" % [ping, rate])
