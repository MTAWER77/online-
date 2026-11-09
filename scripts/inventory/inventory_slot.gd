extends PanelContainer
## scripts/inventory/inventory_slot.gd
## خانة واحدة في واجهة المخزن: أيقونة، عدد، تظليل، وسحب وإفلات.

signal clicked(index: int)
signal hovered(index: int) # -1 لما الماوس يخرج
signal dropped_on(from_index: int, to_index: int)

@export var normal_style: StyleBox
@export var hover_style: StyleBox
@export var selected_style: StyleBox

@onready var _placeholder: Panel = $Margin/Placeholder
@onready var _letter: Label = $Margin/Placeholder/Letter
@onready var _icon: TextureRect = $Margin/Icon
@onready var _count: Label = $Count
@onready var _hint: Label = $KeyHint

var index: int = 0
var item: Resource = null
var _is_selected: bool = false
var _is_hovered: bool = false


func _ready() -> void:
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	set_item(null, 0)


func set_item(new_item: Resource, count: int) -> void:
	item = new_item
	if item == null:
		_placeholder.visible = false
		_icon.visible = false
		_count.visible = false
		return
	var has_icon: bool = item.icon != null
	_icon.texture = item.icon
	_icon.visible = has_icon
	_placeholder.visible = not has_icon
	if not has_icon:
		var style := StyleBoxFlat.new()
		style.bg_color = item.color
		style.set_corner_radius_all(8)
		_placeholder.add_theme_stylebox_override("panel", style)
		_letter.text = item.display_name.substr(0, 1).to_upper()
	_count.text = str(count)
	_count.visible = count > 1


# رقم صغير في الركن (رقم زرار الـ hotbar)
func set_hint(text: String) -> void:
	_hint.text = text


func set_selected(value: bool) -> void:
	_is_selected = value
	_update_style()
	# حركة خفيفة: الخانة المختارة بتكبر شوية
	pivot_offset = size * 0.5
	var tween: Tween = create_tween()
	tween.tween_property(self, "scale", Vector2(1.08, 1.08) if value else Vector2.ONE, 0.08)


func _update_style() -> void:
	var style: StyleBox = normal_style
	if _is_selected:
		style = selected_style
	elif _is_hovered:
		style = hover_style
	add_theme_stylebox_override("panel", style)


func _on_mouse_entered() -> void:
	_is_hovered = true
	_update_style()
	hovered.emit(index)


func _on_mouse_exited() -> void:
	_is_hovered = false
	_update_style()
	hovered.emit(-1)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		if mouse.pressed and mouse.button_index == MOUSE_BUTTON_LEFT:
			clicked.emit(index)


# ---- السحب والإفلات ----
func _get_drag_data(_at_position: Vector2) -> Variant:
	if item == null:
		return null
	var preview := Panel.new()
	preview.size = Vector2(64.0, 64.0)
	preview.position = -preview.size * 0.5
	var style := StyleBoxFlat.new()
	style.bg_color = item.color
	style.set_corner_radius_all(10)
	preview.add_theme_stylebox_override("panel", style)
	var holder := Control.new()
	holder.add_child(preview)
	set_drag_preview(holder)
	return {"inventory_from": index}


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return data is Dictionary and (data as Dictionary).has("inventory_from")


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	dropped_on.emit((data as Dictionary)["inventory_from"], index)
