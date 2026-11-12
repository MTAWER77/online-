extends CanvasLayer
## scripts/ui/mobile_controls.gd
## تحكم الموبايل: جويستيك يسار (حركة)، سحب على اليمين (كاميرا)، زرار Jump وزرار E وزرار Bag (المخزن)، وأزرار < > لتغيير خانة الـ hotbar.
## الشكل كله في mobile_controls.tscn (تعدّله من المحرر). السكريبت بس بيترجم اللمس لـ Input actions.
## بيتعامل مع اللمس مباشرة، فتقدر تحرك الجويستيك وتضغط الأزرار في نفس الوقت (multi-touch).

# بيظهر على أجهزة اللمس بس. شغّله true لو عايز تشوفه على الكمبيوتر وتجرّب بالماوس.
@export var show_on_desktop: bool = false
@export var look_sensitivity: float = 1.0
@export var deadzone: float = 0.15
@export_range(0.0, 1.0) var look_area_start: float = 0.35 # السحب بيشتغل من الجزء ده من عرض الشاشة لليمين

@onready var _joystick: Control = %Joystick
@onready var _knob: Control = %Knob
@onready var _jump_button: Control = %JumpButton
@onready var _interact_button: Control = %InteractButton
@onready var _inventory_button: Control = %InventoryButton
@onready var _hotbar_prev_button: Control = %HotbarPrev
@onready var _hotbar_next_button: Control = %HotbarNext

var _joystick_touch: int = -1
var _look_touch: int = -1
var _jump_touch: int = -1
var _interact_touch: int = -1
var _inventory_touch: int = -1
var _hotbar_touches: Dictionary = {} # رقم اللمسة -> اسم الأكشن
var _joystick_vector: Vector2 = Vector2.ZERO
var _active: bool = false


func _ready() -> void:
	_active = show_on_desktop or DisplayServer.is_touchscreen_available()
	visible = _active
	set_process_input(_active)
	if not _active:
		return
	# من غير ما اللمس يتحول لحركة ماوس (كان هيحرّك الكاميرا مرتين)
	Input.emulate_mouse_from_touch = false
	Input.emulate_touch_from_mouse = show_on_desktop
	_reset_joystick()


func _exit_tree() -> void:
	if _active:
		_release_all()
		# نرجّع الوضع الطبيعي عشان القوائم تشتغل باللمس
		Input.emulate_mouse_from_touch = true
		Input.emulate_touch_from_mouse = false


func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_touch_down(touch.index, touch.position)
		else:
			_touch_up(touch.index)
	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		if drag.index == _joystick_touch:
			_update_joystick(drag.position)
		elif drag.index == _look_touch:
			# أي لاعب محلي ياخد الحركة (apply_look بتتجاهل اللاعب البعيد)
			get_tree().call_group("players", "apply_look", drag.relative * look_sensitivity)


func _touch_down(index: int, pos: Vector2) -> void:
	if _joystick_touch == -1 and _joystick.get_global_rect().has_point(pos):
		_joystick_touch = index
		_update_joystick(pos)
	elif _jump_touch == -1 and _jump_button.get_global_rect().has_point(pos):
		_jump_touch = index
		_send_action(&"jump", true)
	elif _interact_touch == -1 and _interact_button.get_global_rect().has_point(pos):
		_interact_touch = index
		_send_action(&"interact", true)
	elif _inventory_touch == -1 and _inventory_button.get_global_rect().has_point(pos):
		_inventory_touch = index
		_send_action(&"inventory", true) # بيفتح ويقفل المخزن (InventoryUI)
	elif _hotbar_action_at(pos) != &"":
		var hotbar_action: StringName = _hotbar_action_at(pos)
		_hotbar_touches[index] = hotbar_action
		_send_action(hotbar_action, true) # تغيير خانة الـ hotbar
	elif _look_touch == -1 and pos.x > get_viewport().get_visible_rect().size.x * look_area_start:
		_look_touch = index


func _touch_up(index: int) -> void:
	if index == _joystick_touch:
		_joystick_touch = -1
		_reset_joystick()
	elif index == _jump_touch:
		_jump_touch = -1
		_send_action(&"jump", false)
	elif index == _interact_touch:
		_interact_touch = -1
		_send_action(&"interact", false)
	elif index == _inventory_touch:
		_inventory_touch = -1
		_send_action(&"inventory", false)
	elif _hotbar_touches.has(index):
		_send_action(_hotbar_touches[index], false)
		_hotbar_touches.erase(index)
	elif index == _look_touch:
		_look_touch = -1


func _hotbar_action_at(pos: Vector2) -> StringName:
	if _hotbar_prev_button.get_global_rect().has_point(pos):
		return &"hotbar_prev"
	if _hotbar_next_button.get_global_rect().has_point(pos):
		return &"hotbar_next"
	return &""


# ---- الجويستيك ----
func _update_joystick(pos: Vector2) -> void:
	var rect: Rect2 = _joystick.get_global_rect()
	var radius: float = rect.size.x * 0.5
	var offset: Vector2 = (pos - rect.get_center()).limit_length(radius)

	_knob.position = _joystick.size * 0.5 + offset - _knob.size * 0.5

	var vector: Vector2 = offset / radius
	_joystick_vector = vector if vector.length() > deadzone else Vector2.ZERO
	_apply_movement()


func _reset_joystick() -> void:
	_joystick_vector = Vector2.ZERO
	_knob.position = _joystick.size * 0.5 - _knob.size * 0.5
	_apply_movement()


func _apply_movement() -> void:
	_set_strength(&"move_right", maxf(_joystick_vector.x, 0.0))
	_set_strength(&"move_left", maxf(-_joystick_vector.x, 0.0))
	_set_strength(&"move_back", maxf(_joystick_vector.y, 0.0))
	_set_strength(&"move_forward", maxf(-_joystick_vector.y, 0.0))


# ---- ترجمة اللمس لـ Input actions ----
func _set_strength(action: StringName, strength: float) -> void:
	if not InputMap.has_action(action):
		return
	if strength > 0.0:
		Input.action_press(action, strength)
	else:
		Input.action_release(action)


# بنبعت event حقيقي عشان _unhandled_input (زي زرار E) يستقبله
func _send_action(action: StringName, pressed: bool) -> void:
	if not InputMap.has_action(action):
		return
	var event := InputEventAction.new()
	event.action = action
	event.pressed = pressed
	Input.parse_input_event(event)


func _release_all() -> void:
	_joystick_vector = Vector2.ZERO
	_apply_movement()
	_send_action(&"jump", false)
	_send_action(&"interact", false)
