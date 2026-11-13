extends Node3D
## scripts/vehicles/unicycle_spawner.gd
## بيعمل الدراجة في مكانه. أوفلاين بنشيل الـ PropertySynchronizer قبل ما الدراجة تدخل الشجرة
## (لأنه بيحتاج GD-Sync شغال). الاتنين (host و client) بيعملوا نفس الدراجة بنفس الاسم والمكان.

const SessionMode = preload("res://scripts/multiplayer/session_mode.gd")
const DebugLog = preload("res://scripts/systems/debug_log.gd")

@export var unicycle_scene: PackedScene

## فاصل المزامنة بالثواني (بديل replication_interval في MultiplayerSynchronizer).
## GD-Sync بيستخدم refresh_rate (مرات/ثانية) = 1 / الفاصل، يعني 0.05s = 20Hz.
## الـ client بيعمل lerp ناحية آخر هدف، فالحركة ناعمة رغم التردد المنخفض.
const SYNC_INTERVAL := 0.05
const SYNC_REFRESH_RATE := 20 # = 1 / SYNC_INTERVAL


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


## بيظبط تردد PropertySynchronizer (ثابت ومنخفض). مفيش interpolation جوه الـ synchronizer:
## التنعيم بيحصل في unicycle.gd (_follow_server_state).
func _tune_sync_rate(sync: Node) -> void:
	sync.set("refresh_rate", SYNC_REFRESH_RATE)
	DebugLog.say("SPAWN", "sync interval=%.2fs (%d Hz)" % [SYNC_INTERVAL, SYNC_REFRESH_RATE])
