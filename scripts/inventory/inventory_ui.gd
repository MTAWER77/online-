extends CanvasLayer
## scripts/inventory/inventory_ui.gd
## واجهة المخزن: Tab أو I للفتح والقفل، Esc للقفل. شكلها كله في inventory_ui.tscn.
## بتعرض مخزن اللاعب المحلي بس. سحب وإفلات بين الخانات، وتفاصيل العنصر على اليمين.

const SlotScene: PackedScene = preload("res://scenes/inventory/inventory_slot.tscn")
const InventoryScript = preload("res://scripts/inventory/inventory.gd")
const TOGGLE_ACTION: StringName = &"inventory"

@onready var _root: Control = %Root
@onready var _grid: GridContainer = %Grid
@onready var _item_name: Label = %ItemName
@onready var _item_count: Label = %ItemCount
@onready var _item_description: Label = %ItemDescription
@onready var _empty_hint: Label = %EmptyHint

var _inventory: Node = null
var _slots: Array = []
var _selected: int = -1
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
	if not DisplayServer.is_touchscreen_available():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _bind(inventory: Node) -> void:
	if inventory == _inventory:
		return
	if _inventory != null and _inventory.changed.is_connected(_refresh):
		_inventory.changed.disconnect(_refresh)
	_inventory = inventory
	_inventory.changed.connect(_refresh)

	for slot in _slots:
		slot.queue_free()
	_slots.clear()
	for i in _inventory.slot_count:
		var slot: Variant = SlotScene.instantiate()
		slot.index = i
		slot.clicked.connect(_on_slot_clicked)
		slot.hovered.connect(_on_slot_hovered)
		slot.dropped_on.connect(_on_slot_dropped)
		_grid.add_child(slot)
		_slots.append(slot)


func _refresh() -> void:
	if _inventory == null:
		return
	for i in _slots.size():
		_slots[i].set_item(_inventory.items[i], _inventory.counts[i])
		_slots[i].set_selected(i == _selected)
	_update_details()


func _update_details() -> void:
	var shown: int = _hovered if _hovered >= 0 and _inventory.items[_hovered] != null else _selected
	if shown < 0 or _inventory.items[shown] == null:
		_item_name.text = ""
		_item_count.text = ""
		_item_description.text = ""
		_empty_hint.visible = true
		return
	var item: Resource = _inventory.items[shown]
	_empty_hint.visible = false
	_item_name.text = item.display_name
	_item_count.text = "x%d  (max %d)" % [_inventory.counts[shown], item.max_stack]
	_item_description.text = item.description


func _on_slot_clicked(index: int) -> void:
	_selected = index
	_refresh()


func _on_slot_hovered(index: int) -> void:
	_hovered = index
	_update_details()


func _on_slot_dropped(from_index: int, to_index: int) -> void:
	_selected = to_index
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
