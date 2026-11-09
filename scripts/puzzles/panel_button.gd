extends "res://scripts/systems/interactable.gd"
## scripts/puzzles/panel_button.gd
## زرار في لوحة التحكم. اللاعب التاني (الـ client) بس هو اللي يقدر يدوسه.
## الضغطة بتروح للـ host، والـ host يقرر ويطبع النتيجة، والكل يشوف الزرار بيومض.
## (اللغز نفسه، ترتيب الضغطات، هييجي في اليوم 4.)

const SymbolItem = preload("res://scripts/puzzles/symbol_item.gd")
const PerspectiveView = preload("res://scripts/systems/perspective_view.gd")

@export var symbol_id: int = 0 # نفس شكل ولون الرمز (0 أحمر، 1 أخضر، 2 أزرق)
@export var flash_time: float = 0.4

@onready var _mesh: MeshInstance3D = $MeshInstance3D

var _material: StandardMaterial3D = StandardMaterial3D.new()


func _ready() -> void:
	super()
	prompt_text = "Press"
	var visual: Dictionary = SymbolItem.make_visual(symbol_id)
	var color: Color = visual["color"]
	_material.albedo_color = color.darkened(0.3)
	_material.emission_enabled = true
	_material.emission = color
	_material.emission_energy_multiplier = 0.0
	_mesh.material_override = _material
	# الـ host بس هو اللي يأمر الكل بالوميض
	GDSync.expose_func(_apply_press, ENUMS.EXPOSE_PERMISSION.HOST)


func get_prompt(_client_id: int) -> String:
	return "E: Press"


# اللاعب التاني بس يقدر يدوس (اللاعب الأول مش شايف اللوحة أصلًا)
func can_interact(client_id: int) -> bool:
	return PerspectiveView.client_sees(PerspectiveView.Who.CLIENT_ONLY, client_id)


# التنفيذ عند الـ host
func _on_host_interact(client_id: int) -> void:
	print("PanelButton: symbol %d pressed by client %d" % [symbol_id, client_id])
	if GDSync.is_active():
		GDSync.call_func_all(_apply_press)
	else:
		_apply_press()


# بتتنفذ عند الكل
func _apply_press() -> void:
	var tween: Tween = create_tween()
	tween.tween_property(_material, "emission_energy_multiplier", 0.0, flash_time).from(3.0)
