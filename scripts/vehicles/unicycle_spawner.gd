extends Node3D
## scripts/vehicles/unicycle_spawner.gd
## بيعمل الدراجة في مكانه. أوفلاين بنشيل الـ PropertySynchronizer قبل ما الدراجة تدخل الشجرة
## (لأنه بيحتاج GD-Sync شغال). الاتنين (host و client) بيعملوا نفس الدراجة بنفس الاسم والمكان.

const SessionMode = preload("res://scripts/multiplayer/session_mode.gd")

@export var unicycle_scene: PackedScene


func _ready() -> void:
	if unicycle_scene == null:
		push_error("UnicycleSpawner: مفيش unicycle_scene")
		return
	var unicycle := unicycle_scene.instantiate() as Node3D
	unicycle.name = "Unicycle"
	if SessionMode.offline or not GDSync.is_active():
		unicycle.get_node("PropertySynchronizer").free()
	unicycle.transform = Transform3D.IDENTITY
	add_child(unicycle) # مكانه = مكان الـ spawner
