extends Node3D
## scripts/multiplayer/host_sync_test.gd
## اختبار التزامن على الـ host: الضغط على F يبدّل لون المكعب عند الاتنين.
## اللاعب العادي بيطلب من الـ host، والـ host هو اللي يقرر ويطبّق عند الكل.
## ده نفس النمط اللي هنستخدمه لفتح الباب بعد حل اللغز.

@onready var mesh: MeshInstance3D = $MeshInstance3D

var is_on: bool = false
var _material: StandardMaterial3D = StandardMaterial3D.new()


func _ready() -> void:
	mesh.material_override = _material
	_apply_visual()
	# أي لاعب يقدر يطلب من الـ host
	GDSync.expose_func(request_toggle)
	# الـ host بس هو اللي يقدر يفرض الحالة على الباقي
	GDSync.expose_func(_apply_state, ENUMS.EXPOSE_PERMISSION.HOST)
	GDSync.client_joined.connect(_on_client_joined)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key_event := event as InputEventKey
	if not key_event.pressed or key_event.echo or key_event.physical_keycode != KEY_F:
		return
	if not GDSync.is_active():
		return
	if GDSync.is_host():
		request_toggle()
	else:
		GDSync.call_func_on(GDSync.get_host(), request_toggle)


# بتتنفذ عند الـ host بس
func request_toggle() -> void:
	if not GDSync.is_host():
		return
	GDSync.call_func_all(_apply_state, not is_on) # call_func_all بتشغّلها عندي وعند الباقي


func _apply_state(value: bool) -> void:
	is_on = value
	_apply_visual()


# لاعب دخل متأخر: الـ host يبعتله الحالة الحالية
func _on_client_joined(client_id: int) -> void:
	if GDSync.is_host() and client_id != GDSync.get_client_id():
		GDSync.call_func_on(client_id, _apply_state, is_on)


func _apply_visual() -> void:
	_material.albedo_color = Color(0.2, 0.8, 0.3) if is_on else Color(0.8, 0.25, 0.25)
