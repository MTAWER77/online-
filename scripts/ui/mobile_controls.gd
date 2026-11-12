extends CanvasLayer
## scripts/ui/mobile_controls.gd
## تحكم الموبايل: جويستيك يسار (دركسيون)، وأزرار Gas و Brake و Jump، وزرار Menu للخروج.
## كل لاعب بيستخدم بس الأزرار بتاعة دوره: الـ host دركسيون + Brake، والـ client Gas + Jump (أوفلاين الكل).
## الشكل كله في mobile_controls.tscn. السكريبت بس بيترجم اللمس لـ Input actions (multi-touch).

# بيظهر على أجهزة اللمس بس. شغّله true لو عايز تشوفه على الكمبيوتر وتجرّب بالماوس.
@export var show_on_desktop: bool = false
@export var deadzone: float = 0.15

@onready var _joystick: Control = %Joystick
@onready var _knob: Control = %Knob

var _buttons: Dictionary = {} # Control -> اسم الأكشن
var _button_touches: Dictionary = {} # رقم اللمسة -> اسم الأكشن
var _joystick_touch: int = -1
var _steer: float = 0.0
var _active: bool = false


func _ready() -> void:
	_active = show_on_desktop or DisplayServer.is_touchscreen_available()
	visible = _active
	set_process_input(_active)
	if not _active:
		return
	_buttons = {
		%GasButton: &"move_forward",
		%BrakeButton: &"move_back",
		%JumpButton: &"jump",
		%MenuButton: &"ui_cancel", # الدراجة بتفهمه كخروج للقائمة
	}
	# من غير ما اللمس يتحول لحركة ماوس
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


func _touch_down(index: int, pos: Vector2) -> void:
	if _joystick_touch == -1 and _joystick.get_global_rect().has_point(pos):
		_joystick_touch = index
		_update_joystick(pos)
		return
	for button: Control in _buttons:
		if button.get_global_rect().has_point(pos):
			var action: StringName = _buttons[button]
			_button_touches[index] = action
			_send_action(action, true)
			return


func _touch_up(index: int) -> void:
	if index == _joystick_touch:
		_joystick_touch = -1
		_reset_joystick()
	elif _button_touches.has(index):
		_send_action(_button_touches[index], false)
		_button_touches.erase(index)


# ---- الجويستيك (يمين / شمال بس = دركسيون) ----
func _update_joystick(pos: Vector2) -> void:
	var rect: Rect2 = _joystick.get_global_rect()
	var radius: float = rect.size.x * 0.5
	var offset: Vector2 = (pos - rect.get_center()).limit_length(radius)
	_knob.position = _joystick.size * 0.5 + offset - _knob.size * 0.5
	var x: float = offset.x / radius
	_steer = x if absf(x) > deadzone else 0.0
	_apply_steer()


func _reset_joystick() -> void:
	_steer = 0.0
	_knob.position = _joystick.size * 0.5 - _knob.size * 0.5
	_apply_steer()


func _apply_steer() -> void:
	_set_strength(&"move_right", maxf(_steer, 0.0))
	_set_strength(&"move_left", maxf(-_steer, 0.0))


func _set_strength(action: StringName, strength: float) -> void:
	if not InputMap.has_action(action):
		return
	if strength > 0.0:
		Input.action_press(action, strength)
	else:
		Input.action_release(action)


func _send_action(action: StringName, pressed: bool) -> void:
	if not InputMap.has_action(action):
		return
	var event := InputEventAction.new()
	event.action = action
	event.pressed = pressed
	Input.parse_input_event(event)


func _release_all() -> void:
	_steer = 0.0
	_apply_steer()
	for action: StringName in _button_touches.values():
		_send_action(action, false)
	_button_touches.clear()
