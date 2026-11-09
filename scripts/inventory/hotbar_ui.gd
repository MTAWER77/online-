extends CanvasLayer
## scripts/inventory/hotbar_ui.gd
## شريط سريع من 5 خانات تحت الشاشة: أرقام 1-5 أو عجلة الماوس للاختيار.
## الخانات دي جزء من مخزن اللاعب (Inventory)، فالسحب بينها وبين الشبكة بيشتغل عادي.

const SlotScene: PackedScene = preload("res://scenes/inventory/inventory_slot.tscn")
const InventoryScript = preload("res://scripts/inventory/inventory.gd")

@onready var _root: Control = %Root
@onready var _bar: HBoxContainer = %Bar

var _inventory: Node = null
var _slots: Array = []


func _ready() -> void:
	_ensure_actions()


# اللاعب بيتعمل بعد دخول اللوبي، فنستنى لحد ما نلاقي مخزنه ونربط مرة واحدة
func _process(_delta: float) -> void:
	var inventory: Node = InventoryScript.get_local(get_tree())
	if inventory == null or inventory.slot_count == 0:
		return
	_bind(inventory)
	set_process(false)


func _bind(inventory: Node) -> void:
	_inventory = inventory
	for i in _inventory.hotbar_slots:
		var slot: Variant = SlotScene.instantiate()
		slot.index = _inventory.hotbar_index(i)
		slot.clicked.connect(_on_slot_clicked.bind(i))
		slot.dropped_on.connect(_on_slot_dropped)
		_bar.add_child(slot)
		slot.set_hint(str(i + 1))
		_slots.append(slot)
	_inventory.changed.connect(_refresh)
	_inventory.hotbar_selection_changed.connect(_update_selection)
	_root.visible = true
	_refresh()
	_update_selection(_inventory.selected_hotbar)


func _refresh() -> void:
	for i in _slots.size():
		var index: int = _inventory.hotbar_index(i)
		_slots[i].set_item(_inventory.items[index], _inventory.counts[index])


func _update_selection(selected: int) -> void:
	for i in _slots.size():
		_slots[i].set_selected(i == selected)


func _on_slot_clicked(_slot_index: int, hotbar_i: int) -> void:
	_inventory.select_hotbar(hotbar_i)


func _on_slot_dropped(from_index: int, to_index: int) -> void:
	_inventory.move_slot(from_index, to_index)


func _unhandled_input(event: InputEvent) -> void:
	if _inventory == null or _inventory.get_parent().ui_open:
		return
	for i in _inventory.hotbar_slots:
		if event.is_action_pressed("hotbar_%d" % (i + 1)):
			_inventory.select_hotbar(i)
			return
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		var button: int = (event as InputEventMouseButton).button_index
		if button == MOUSE_BUTTON_WHEEL_UP:
			_inventory.select_hotbar(_inventory.selected_hotbar - 1)
		elif button == MOUSE_BUTTON_WHEEL_DOWN:
			_inventory.select_hotbar(_inventory.selected_hotbar + 1)


func _ensure_actions() -> void:
	var keys: Array[Key] = [KEY_1, KEY_2, KEY_3, KEY_4, KEY_5]
	for i in keys.size():
		var action := StringName("hotbar_%d" % (i + 1))
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		var ev := InputEventKey.new()
		ev.physical_keycode = keys[i]
		InputMap.action_add_event(action, ev)
