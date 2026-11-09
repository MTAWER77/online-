extends CanvasLayer
## scripts/inventory/inventory_ui.gd
## واجهة الشنطة (المخزن + التصنيع): Tab أو I للفتح والقفل، Esc للقفل. شكلها كله في inventory_ui.tscn.
## بتعرض شبكة 5x4 من مخزن اللاعب المحلي. سحب وإفلات بين الخانات (وبين الـ hotbar كمان)، واسم العنصر ووصفه تحت الشبكة.

const SlotScene: PackedScene = preload("res://scenes/inventory/inventory_slot.tscn")
const InventoryScript = preload("res://scripts/inventory/inventory.gd")
const TOGGLE_ACTION: StringName = &"inventory"

@onready var _root: Control = %Root
@onready var _grid: GridContainer = %Grid
@onready var _info: Label = %Info
@onready var _crafting: Node = %Crafting

var _inventory: Node = null
var _slots: Array = []
var _hovered: int = -1
var _tween: Tween


func _ready() -> void:
	_ensure_action()
	_root.visible = false


func is_open() -> bool:
	return _root.visible


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(TOGGLE_ACTION):
		if is_open():
			close()
		else:
			open()
		get_viewport().set_input_as_handled()
	elif is_open() and event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()


func open() -> void:
	var inventory: Node = InventoryScript.get_local(get_tree())
	if inventory == null:
		return
	_bind(inventory)
	_root.visible = true
	_refresh()
	get_tree().call_group("players", "set_ui_open", true)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# على الموبايل: تحكم اللمس بيوقف تحويل اللمس لماوس، فنشغّله وإحنا مفتوحين عشان الخانات تتلمس وتتسحب
	if DisplayServer.is_touchscreen_available():
		Input.emulate_mouse_from_touch = true
	# ظهور ناعم
	if _tween != null:
		_tween.kill()
	_root.modulate.a = 0.0
	_tween = create_tween()
	_tween.tween_property(_root, "modulate:a", 1.0, 0.12)


func close() -> void:
	_root.visible = false
	_hovered = -1
	get_tree().call_group("players", "set_ui_open", false)
	if DisplayServer.is_touchscreen_available():
		Input.emulate_mouse_from_touch = false # نرجّع وضع تحكم الموبايل
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _bind(inventory: Node) -> void:
	if inventory == _inventory:
		return
	if _inventory != null and _inventory.changed.is_connected(_refresh):
		_inventory.changed.disconnect(_refresh)
	_inventory = inventory
	_inventory.changed.connect(_refresh)
	_crafting.bind(_inventory)

	for slot in _slots:
		slot.queue_free()
	_slots.clear()
	for i in _inventory.grid_slots:
		var slot: Variant = SlotScene.instantiate()
		slot.index = i
		slot.hovered.connect(_on_slot_hovered)
		slot.dropped_on.connect(_on_slot_dropped)
		_grid.add_child(slot)
		_slots.append(slot)


func _refresh() -> void:
	if _inventory == null:
		return
	for i in _slots.size():
		_slots[i].set_item(_inventory.items[i], _inventory.counts[i])
	_update_info()
	_crafting.refresh()


func _update_info() -> void:
	if _inventory == null or _hovered < 0 or _inventory.items[_hovered] == null:
		_info.text = ""
		return
	var item: Resource = _inventory.items[_hovered]
	_info.text = "%s  x%d  -  %s" % [item.display_name, _inventory.counts[_hovered], item.description]


func _on_slot_hovered(index: int) -> void:
	_hovered = index
	_update_info()


func _on_slot_dropped(from_index: int, to_index: int) -> void:
	_inventory.move_slot(from_index, to_index) # بتعمل changed فالواجهة بتتحدث


func _ensure_action() -> void:
	if InputMap.has_action(TOGGLE_ACTION):
		return
	InputMap.add_action(TOGGLE_ACTION)
	var keys: Array[Key] = [KEY_TAB, KEY_I]
	for key in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = key
		InputMap.action_add_event(TOGGLE_ACTION, ev)
