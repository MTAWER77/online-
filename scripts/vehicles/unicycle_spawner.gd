extends Node3D
## scripts/vehicles/unicycle_spawner.gd
## بيعمل الدراجة في مكانه. الاتنين (host و client) بيعملوا نفس الدراجة بنفس الاسم والمكان.
## المزامنة جوه unicycle.gd (snapshots بتتبعت بـ RPC).

const SessionMode = preload("res://scripts/multiplayer/session_mode.gd")
const DebugLog = preload("res://scripts/systems/debug_log.gd")

@export var unicycle_scene: PackedScene


func _ready() -> void:
	if unicycle_scene == null:
		push_error("UnicycleSpawner: مفيش unicycle_scene")
		return

	var unicycle := unicycle_scene.instantiate() as Node3D
	unicycle.name = "Unicycle"
	unicycle.transform = Transform3D.IDENTITY
	add_child(unicycle) # مكانه = مكان الـ spawner
	DebugLog.say("SPAWN", "الدراجة اتعملت (online=%s)" % (not SessionMode.offline and GDSync.is_active()))
