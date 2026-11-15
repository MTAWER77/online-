extends Node3D
## scripts/vehicles/unicycle_spawner.gd
## بيعمل العربية (أو الدراجة القديمة) في مكانه. الاتنين (host و client) بيعملوا نفس الشيء بنفس الاسم والمكان.
## المزامنة جوه shopping_cart.gd (snapshots بتتبعت بـ RPC).

const SessionMode = preload("res://scripts/multiplayer/session_mode.gd")
const DebugLog = preload("res://scripts/systems/debug_log.gd")
const CART_SCENE: PackedScene = preload("res://scenes/vehicles/shopping_cart.tscn")

@export var unicycle_scene: PackedScene # الدراجة القديمة (متبقية للتوافق مع المشاهد الحالية)
@export var use_shopping_cart: bool = true # شيلها لو عايز ترجع للدراجة


func _ready() -> void:
	var scene: PackedScene = CART_SCENE if use_shopping_cart else unicycle_scene
	if scene == null:
		push_error("UnicycleSpawner: مفيش مشهد للعربية")
		return

	var vehicle := scene.instantiate() as Node3D
	vehicle.name = "Unicycle" # نفس الاسم القديم عشان مسارات الشبكة تفضل ثابتة
	vehicle.transform = Transform3D.IDENTITY
	add_child(vehicle) # مكانها = مكان الـ spawner
	DebugLog.say("SPAWN", "المركبة اتعملت (cart=%s online=%s)" % [use_shopping_cart, not SessionMode.offline and GDSync.is_active()])
