extends Area3D
## scripts/levels/checkpoint.gd
## نقطة تفتيش: أول ما الدراجة تعدّي عليها بتتفعّل (الـ host هو اللي بيقرر)،
## والدراجة لما تقع بترجع هنا بنفس اتجاه النقطة (لفّها في المشهد عشان تتحكم في الاتجاه).

const SessionMode = preload("res://scripts/multiplayer/session_mode.gd")
const DebugLog = preload("res://scripts/systems/debug_log.gd")

@onready var _banner: MeshInstance3D = $Banner

var activated: bool = false


func _ready() -> void:
	body_entered.connect(_on_body_entered)
	GDSync.expose_func(_apply_activate, ENUMS.EXPOSE_PERMISSION.HOST)
	_refresh_visual()


func _on_body_entered(body: Node3D) -> void:
	if activated or not body.is_in_group("unicycle"):
		return
	var online: bool = not SessionMode.offline and GDSync.is_active()
	if online:
		if GDSync.is_host(): # الـ host بس يقرر
			GDSync.call_func_all(_apply_activate)
	else:
		_apply_activate()


func _apply_activate() -> void:
	if activated:
		return
	activated = true
	DebugLog.say("CP", "%s اتفعّلت" % name)
	_refresh_visual()
	var unicycle := get_tree().get_first_node_in_group("unicycle")
	if unicycle != null:
		unicycle.call("set_checkpoint", Transform3D(Basis(Vector3.UP, global_rotation.y), global_position + Vector3.UP * 0.3))


func _refresh_visual() -> void:
	var material := StandardMaterial3D.new()
	if activated:
		material.albedo_color = Color(0.1, 0.9, 1.0)
		material.emission_enabled = true
		material.emission = Color(0.1, 0.9, 1.0)
		material.emission_energy_multiplier = 1.5
	else:
		material.albedo_color = Color(0.5, 0.5, 0.55)
	_banner.material_override = material
