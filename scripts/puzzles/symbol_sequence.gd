extends Node3D
## scripts/puzzles/symbol_sequence.gd
## لوحة بترتيب الرموز اللي لازم اللاعب التاني يضغطها. اللاعب الأول (الـ host) بس هو اللي يشوفها.
## الـ host بيختار الترتيب العشوائي ويحتفظ بيه (الـ client ما بيعرفوش أصلًا).
## الترتيب بيتقرا من الشمال لليمين. الضغطات هتتقارن بيه في اليوم 4.

signal sequence_ready(sequence: Array[int])

const SymbolItem = preload("res://scripts/puzzles/symbol_item.gd")
const PerspectiveView = preload("res://scripts/systems/perspective_view.gd")

@onready var _slots: Array[MeshInstance3D] = [$Slot1, $Slot2, $Slot3]

var sequence: Array[int] = [] # فاضي عند الـ client، متعبي عند الـ host


func _ready() -> void:
	# الـ host (أو اللعب من غير شبكة) هو اللي يعمل الترتيب
	if GDSync.is_active() and not GDSync.is_host():
		return
	generate()


# بيعمل ترتيب جديد (بنستخدمه كمان لما نعيد الغرفة)
func generate() -> void:
	sequence.assign([0, 1, 2])
	sequence.shuffle()
	print("SymbolSequence: order = ", sequence)
	for i in _slots.size():
		var visual: Dictionary = SymbolItem.make_visual(sequence[i])
		var material := StandardMaterial3D.new()
		material.albedo_color = visual["color"]
		_slots[i].mesh = visual["mesh"]
		_slots[i].material_override = material
	sequence_ready.emit(sequence)
