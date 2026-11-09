extends HBoxContainer
## scripts/inventory/ingredient_row.gd
## سطر مادة مطلوبة: نقطة حالة (أخضر موجودة / أحمر ناقصة)، لون المادة، الاسم، والكمية (معاك / مطلوب).

const READY_COLOR: Color = Color(0.5, 0.88, 0.62)
const MISSING_COLOR: Color = Color(0.95, 0.5, 0.45)

@onready var _dot: Panel = %Dot
@onready var _tile: Panel = %Tile
@onready var _name: Label = %Name
@onready var _amount: Label = %Amount


func setup(item: Resource, have: int, need: int) -> void:
	var enough: bool = have >= need
	var color: Color = READY_COLOR if enough else MISSING_COLOR
	var dot_style := StyleBoxFlat.new()
	dot_style.bg_color = color
	dot_style.set_corner_radius_all(4)
	_dot.add_theme_stylebox_override("panel", dot_style)
	var tile_style := StyleBoxFlat.new()
	tile_style.bg_color = item.color
	tile_style.set_corner_radius_all(2)
	_tile.add_theme_stylebox_override("panel", tile_style)
	_name.text = item.display_name
	_amount.text = "%d / %d" % [have, need]
	_amount.add_theme_color_override("font_color", color)
