extends PanelContainer
## scripts/inventory/recipe_row.gd
## سطر وصفة واحدة في قايمة التصنيع: مربع ملوّن بلون الناتج، الاسم، والحالة (Ready أو 1/3).

signal chosen(recipe: Resource)

const READY_COLOR: Color = Color(0.5, 0.88, 0.62)
const PARTIAL_COLOR: Color = Color(1, 1, 1, 0.5)

@export var normal_style: StyleBox
@export var hover_style: StyleBox
@export var selected_style: StyleBox

@onready var _tile: Panel = %Tile
@onready var _letter: Label = %Letter
@onready var _name: Label = %Name
@onready var _status: Label = %Status

var recipe: Resource = null
var _is_selected: bool = false
var _is_hovered: bool = false


func _ready() -> void:
	mouse_entered.connect(func() -> void: _set_hover(true))
	mouse_exited.connect(func() -> void: _set_hover(false))


# ready: كل المواد موجودة، met: عدد المواد اللي مكتملة من الإجمالي
func setup(new_recipe: Resource, ready_to_craft: bool, met: int) -> void:
	recipe = new_recipe
	var result: Resource = recipe.result
	var style := StyleBoxFlat.new()
	style.bg_color = result.color
	style.set_corner_radius_all(3)
	_tile.add_theme_stylebox_override("panel", style)
	_letter.text = result.display_name.substr(0, 1).to_upper()
	var suffix: String = "  x%d" % recipe.result_amount if recipe.result_amount > 1 else ""
	_name.text = recipe.display_name + suffix
	_status.text = "Ready" if ready_to_craft else "%d/%d" % [met, recipe.ingredient_items.size()]
	_status.add_theme_color_override("font_color", READY_COLOR if ready_to_craft else PARTIAL_COLOR)
	# الوصفة اللي لسه ناقصها مواد باهتة شوية
	modulate.a = 1.0 if ready_to_craft else 0.6
	_update_style()


func set_selected(value: bool) -> void:
	_is_selected = value
	_update_style()


func _set_hover(value: bool) -> void:
	_is_hovered = value
	_update_style()


func _update_style() -> void:
	var style: StyleBox = normal_style
	if _is_selected:
		style = selected_style
	elif _is_hovered:
		style = hover_style
	add_theme_stylebox_override("panel", style)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		if mouse.pressed and mouse.button_index == MOUSE_BUTTON_LEFT:
			chosen.emit(recipe)
