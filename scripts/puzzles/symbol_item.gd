extends "res://scripts/systems/interactable.gd"
## scripts/puzzles/symbol_item.gd
## رمز يتشال ويتحط. اللاعب بيطلب، والـ host هو اللي يقرر مين شايله،
## والكل بيشوف الرمز فوق راس اللي شايله. لاعب يشيل رمز واحد بس في المرة.
## (الرؤية المختلفة لكل لاعب هتتضاف بعدين في Perspective System.)

signal state_changed(holder_id: int)

const NO_HOLDER: int = -1
const ROLE_HOST: int = 1 # نفس قيمة Player.Role.HOST
const ROLE_CLIENT: int = 2 # نفس قيمة Player.Role.CLIENT

@export var symbol_id: int = 0 # 0 مربع أحمر، 1 كورة خضرا، 2 أسطوانة زرقا
@export var hold_offset: Vector3 = Vector3(0.0, 2.3, 0.0) # مكان الرمز فوق اللاعب
@export var drop_distance: float = 1.3 # بيتحط قدام اللاعب بالمسافة دي
@export var rest_height: float = 0.45 # ارتفاع مركز الرمز فوق الأرض لما يتحط

var holder_id: int = NO_HOLDER # رقم اللاعب اللي شايله، أو -1 لو متحط

@onready var _mesh: MeshInstance3D = $MeshInstance3D


func _ready() -> void:
	super()
	add_to_group("pickups")
	_build_visual()
	# الـ host بس هو اللي يقدر يفرض الحالة على الباقي
	GDSync.expose_func(_apply_state, ENUMS.EXPOSE_PERMISSION.HOST)


func _process(_delta: float) -> void:
	if holder_id == NO_HOLDER:
		return
	var player: Node3D = _find_player(holder_id)
	if player != null:
		global_position = player.global_position + hold_offset


func get_prompt(client_id: int) -> String:
	return "E: Drop" if holder_id == client_id else "E: Pick up"


func can_interact(client_id: int) -> bool:
	if client_id == NO_HOLDER:
		return false
	if holder_id == client_id:
		return true # أنا شايله، أقدر أحطه
	if holder_id != NO_HOLDER:
		return false # حد تاني شايله
	return not _is_holding_something(client_id) # مفيش في إيدي حاجة تانية


# التنفيذ عند الـ host: يشيل أو يحط
func _on_host_interact(client_id: int) -> void:
	if holder_id == NO_HOLDER:
		_broadcast_state(client_id, global_position)
	else:
		_broadcast_state(NO_HOLDER, _drop_position(client_id))


func _broadcast_state(new_holder: int, pos: Vector3) -> void:
	if GDSync.is_active():
		GDSync.call_func_all(_apply_state, new_holder, pos) # بتشتغل عندي وعند التاني
	else:
		_apply_state(new_holder, pos)


# بتتنفذ عند الكل بعد قرار الـ host
func _apply_state(new_holder: int, pos: Vector3) -> void:
	holder_id = new_holder
	if new_holder == NO_HOLDER:
		global_position = pos
	state_changed.emit(holder_id)


func _is_holding_something(client_id: int) -> bool:
	for raw in get_tree().get_nodes_in_group("pickups"):
		var other: Variant = raw
		if other != self and other.holder_id == client_id:
			return true
	return false


# مكان الحط: قدام اللاعب على الأرض اللي واقف عليها
func _drop_position(client_id: int) -> Vector3:
	var player: Node3D = _find_player(client_id)
	if player == null:
		return global_position
	var visual := player.get_node_or_null("Visual") as Node3D
	var forward: Vector3 = -visual.global_transform.basis.z if visual != null else Vector3.FORWARD
	forward.y = 0.0
	forward = forward.normalized()
	var base: Vector3 = player.global_position + forward * drop_distance
	return Vector3(base.x, player.global_position.y + rest_height, base.z)


# لاعب الـ host هو HostPlayer، والتاني ClientPlayer (من غير شبكة: اللاعب المحلي)
func _find_player(client_id: int) -> Node3D:
	for raw in get_tree().get_nodes_in_group("players"):
		var p: Variant = raw
		if not GDSync.is_active():
			if p.is_local:
				return p
		elif p.role == ROLE_HOST and client_id == GDSync.get_host():
			return p
		elif p.role == ROLE_CLIENT and client_id != GDSync.get_host():
			return p
	return null


func _build_visual() -> void:
	var mesh: Mesh
	var color: Color
	match symbol_id:
		0:
			var box := BoxMesh.new()
			box.size = Vector3(0.7, 0.7, 0.7)
			mesh = box
			color = Color(0.9, 0.25, 0.25)
		1:
			var sphere := SphereMesh.new()
			sphere.radius = 0.4
			sphere.height = 0.8
			mesh = sphere
			color = Color(0.3, 0.8, 0.35)
		_:
			var cylinder := CylinderMesh.new()
			cylinder.top_radius = 0.35
			cylinder.bottom_radius = 0.35
			cylinder.height = 0.8
			mesh = cylinder
			color = Color(0.3, 0.45, 0.95)
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	_mesh.mesh = mesh
	_mesh.material_override = material
