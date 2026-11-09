extends "res://scripts/systems/interactable.gd"
## scripts/puzzles/door.gd
## باب بخانة للرمز. P1 (الـ host) شايف خانة فاضية ومعاه الرموز، و P2 شايف الرمز المطلوب متنور على الباب.
## الاتنين شايفين نفس الباب، لكن كل واحد بشكل مختلف (ViewHost / ViewClient).
## P1 يدوس E قدام الباب وفي إيده رمز: الـ host يقرر. صح = الباب يفتح عند الاتنين، غلط = الرمز يرجع مكانه.
## الـ Door نفسه هو منطقة التفاعل (Area3D)، والـ Body هو الباب الفعلي اللي بيتحرك.

signal opened
signal wrong_symbol

const SymbolItem = preload("res://scripts/puzzles/symbol_item.gd")
const PerspectiveView = preload("res://scripts/systems/perspective_view.gd")
const SOCKET_COLOR: Color = Color(0.08, 0.08, 0.1)
const WRONG_COLOR: Color = Color(0.9, 0.15, 0.15)

@export var required_symbol_id: int = 1 # الرمز اللي P2 بيشوفه ولازم P1 يحطه
@export var open_height: float = 3.3
@export var open_time: float = 1.0

var is_open: bool = false

@onready var _body: StaticBody3D = $Body
@onready var _body_shape: CollisionShape3D = $Body/CollisionShape3D
@onready var _socket: MeshInstance3D = $ViewHost/Socket
@onready var _hint: MeshInstance3D = $ViewClient/Hint

var _closed_position: Vector3
var _socket_material: StandardMaterial3D
var _hint_material: StandardMaterial3D
var _hint_color: Color


func _ready() -> void:
	super()
	prompt_text = "Insert symbol"
	interact_priority = 1 # قدام الباب وفي إيدك رمز: "Insert" قبل "Drop"
	_closed_position = _body.position
	_build_views()
	# الـ host بس هو اللي يفرض الحالة على الباقي
	GDSync.expose_func(_apply_open, ENUMS.EXPOSE_PERMISSION.HOST)
	GDSync.expose_func(_apply_wrong, ENUMS.EXPOSE_PERMISSION.HOST)


func get_prompt(_client_id: int) -> String:
	return "E: Insert symbol"


# اللي بيحط الرمز هو P1 بس، وبشرط يكون شايل رمز والباب لسه مقفول
func can_interact(client_id: int) -> bool:
	if is_open or client_id < 0:
		return false
	if not PerspectiveView.client_sees(PerspectiveView.Who.HOST_ONLY, client_id):
		return false
	return _find_held_symbol(client_id) != null


# التنفيذ عند الـ host
func _on_host_interact(client_id: int) -> void:
	var symbol: Variant = _find_held_symbol(client_id)
	if symbol == null:
		return
	if symbol.symbol_id == required_symbol_id:
		symbol.host_consume(_socket.global_position + Vector3(0.0, 0.0, 0.15))
		_broadcast(_apply_open)
	else:
		symbol.host_return_home()
		_broadcast(_apply_wrong)


# بتتنادى من SequencePuzzle عند الـ host
func host_open() -> void:
	if not is_open:
		_broadcast(_apply_open)


func host_wrong() -> void:
	if not is_open:
		_broadcast(_apply_wrong)


func _broadcast(action: Callable) -> void:
	if GDSync.is_active():
		GDSync.call_func_all(action) # بتشتغل عندي وعند التاني
	else:
		action.call()


# بتتنفذ عند الكل بعد قرار الـ host
func _apply_open() -> void:
	if is_open:
		return
	is_open = true
	_body_shape.set_deferred("disabled", true)
	var tween: Tween = create_tween()
	tween.tween_property(_body, "position:y", _closed_position.y + open_height, open_time) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	opened.emit()


func _apply_wrong() -> void:
	wrong_symbol.emit()
	_socket_material.albedo_color = WRONG_COLOR
	_hint_material.emission = WRONG_COLOR
	var tween: Tween = create_tween()
	tween.tween_property(_socket_material, "albedo_color", SOCKET_COLOR, 0.7)
	tween.parallel().tween_property(_hint_material, "emission", _hint_color, 0.7)


func _find_held_symbol(client_id: int) -> Variant:
	for raw in get_tree().get_nodes_in_group("pickups"):
		var symbol: Variant = raw
		if symbol.holder_id == client_id and not symbol.consumed:
			return symbol
	return null


# شكل كل لاعب للباب: P1 خانة سودا، P2 الرمز المطلوب متنور
func _build_views() -> void:
	_socket_material = StandardMaterial3D.new()
	_socket_material.albedo_color = SOCKET_COLOR
	_socket.material_override = _socket_material

	var visual: Dictionary = SymbolItem.make_visual(required_symbol_id)
	_hint_color = visual["color"]
	_hint_material = StandardMaterial3D.new()
	_hint_material.albedo_color = _hint_color
	_hint_material.emission_enabled = true
	_hint_material.emission = _hint_color
	_hint_material.emission_energy_multiplier = 1.6
	_hint.mesh = visual["mesh"]
	_hint.material_override = _hint_material
