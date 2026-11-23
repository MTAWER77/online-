extends CanvasLayer
## scripts/vehicles/mobile_controls.gd
## أزرار تحكم لمس على الشاشة للموبايل.
## تُضاف كـ CanvasLayer تحت ShoppingCart وتحقن أحداث Input مباشرة.
## تظهر تلقائياً لما يكون الجهاز touch screen، وتُخفى على الديسكتوب.

var _ACTIONS: Dictionary = {
	"move_forward": false,
	"move_back":    false,
	"move_left":    false,
	"move_right":   false,
	"jump":         false,
}

# تتبّع أصابع الجويستيك
var _stick_touch_idx: int = -1
var _stick_origin: Vector2 = Vector2.ZERO
var _stick_knob: Control
var _stick_base: Control
const STICK_RADIUS: float = 60.0
const STICK_DEAD: float = 0.25

# تتبّع زر القفز
var _jump_touch_idx: int = -1

var _active: bool = false


func _ready() -> void:
	layer = 10
	_active = DisplayServer.is_touchscreen_available()
	if not _active:
		return
	_build_ui()


func _build_ui() -> void:
	# ---- خلفية الجويستيك ----
	_stick_base = ColorRect.new()
	(_stick_base as ColorRect).color = Color(1, 1, 1, 0.12)
	_stick_base.size = Vector2(STICK_RADIUS * 2.2, STICK_RADIUS * 2.2)
	_stick_base.position = Vector2(40, -(_stick_base.size.y + 40))
	_stick_base.anchor_top = 1.0
	_stick_base.anchor_bottom = 1.0
	# تحويله لدائرة بـ StyleBoxFlat
	var style := StyleBoxFlat.new()
	style.bg_color = Color(1, 1, 1, 0.12)
	style.corner_radius_top_left = int(STICK_RADIUS * 1.1)
	style.corner_radius_top_right = int(STICK_RADIUS * 1.1)
	style.corner_radius_bottom_left = int(STICK_RADIUS * 1.1)
	style.corner_radius_bottom_right = int(STICK_RADIUS * 1.1)
	(_stick_base as ColorRect).set_script(null)
	add_child(_stick_base)

	_stick_knob = ColorRect.new()
	(_stick_knob as ColorRect).color = Color(1, 1, 1, 0.45)
	var knob_size: float = STICK_RADIUS * 0.75
	_stick_knob.size = Vector2(knob_size, knob_size)
	var style_k := StyleBoxFlat.new()
	style_k.bg_color = Color(1, 1, 1, 0.45)
	style_k.corner_radius_top_left = int(knob_size * 0.5)
	style_k.corner_radius_top_right = int(knob_size * 0.5)
	style_k.corner_radius_bottom_left = int(knob_size * 0.5)
	style_k.corner_radius_bottom_right = int(knob_size * 0.5)
	_stick_knob.position = _stick_base.position + Vector2(STICK_RADIUS * 1.1 - knob_size * 0.5, STICK_RADIUS * 1.1 - knob_size * 0.5)
	add_child(_stick_knob)

	# ---- زر القفز ----
	var jump_btn: Button = Button.new()
	jump_btn.text = "⬆"
	jump_btn.size = Vector2(90, 90)
	jump_btn.position = Vector2(-(90 + 40), -(90 + 40))
	jump_btn.anchor_right = 1.0
	jump_btn.anchor_top = 1.0
	jump_btn.anchor_bottom = 1.0
	jump_btn.anchor_left = 1.0
	var jump_style := StyleBoxFlat.new()
	jump_style.bg_color = Color(0.2, 0.6, 1.0, 0.55)
	jump_style.corner_radius_top_left = 45
	jump_style.corner_radius_top_right = 45
	jump_style.corner_radius_bottom_left = 45
	jump_style.corner_radius_bottom_right = 45
	jump_btn.add_theme_stylebox_override("normal", jump_style)
	jump_btn.add_theme_color_override("font_color", Color.WHITE)
	jump_btn.add_theme_font_size_override("font_size", 32)
	jump_btn.button_down.connect(_on_jump_pressed)
	jump_btn.button_up.connect(_on_jump_released)
	add_child(jump_btn)


func _input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventScreenTouch:
		_handle_touch(event as InputEventScreenTouch)
	elif event is InputEventScreenDrag:
		_handle_drag(event as InputEventScreenDrag)


func _handle_touch(ev: InputEventScreenTouch) -> void:
	var stick_center: Vector2 = _get_stick_center()
	if ev.pressed:
		# هل الإصبع قريب من الجويستيك؟
		if _stick_touch_idx == -1 and ev.position.distance_to(stick_center) < STICK_RADIUS * 2.0:
			_stick_touch_idx = ev.index
			_stick_origin = ev.position
			_update_stick(ev.position)
	else:
		if ev.index == _stick_touch_idx:
			_stick_touch_idx = -1
			_stick_origin = Vector2.ZERO
			_reset_stick()


func _handle_drag(ev: InputEventScreenDrag) -> void:
	if ev.index == _stick_touch_idx:
		_update_stick(ev.position)


func _get_stick_center() -> Vector2:
	if _stick_base == null:
		return Vector2(STICK_RADIUS * 1.1 + 40, DisplayServer.window_get_size().y - STICK_RADIUS * 1.1 - 40)
	return _stick_base.global_position + _stick_base.size * 0.5


func _update_stick(touch_pos: Vector2) -> void:
	var origin: Vector2 = _get_stick_center()
	var delta: Vector2 = touch_pos - origin
	var clamped: Vector2 = delta.limit_length(STICK_RADIUS)

	# تحديث موضع الكنوب بصرياً
	var knob_size: float = _stick_knob.size.x
	_stick_knob.position = _stick_base.position + Vector2(
		STICK_RADIUS * 1.1 + clamped.x - knob_size * 0.5,
		STICK_RADIUS * 1.1 + clamped.y - knob_size * 0.5
	)

	var normalized: Vector2 = clamped / STICK_RADIUS

	# حقن أحداث الـ Input
	_set_action(&"move_forward", normalized.y < -STICK_DEAD)
	_set_action(&"move_back",    normalized.y >  STICK_DEAD)
	_set_action(&"move_left",    normalized.x < -STICK_DEAD)
	_set_action(&"move_right",   normalized.x >  STICK_DEAD)


func _reset_stick() -> void:
	# إعادة الكنوب للمركز
	var knob_size: float = _stick_knob.size.x
	_stick_knob.position = _stick_base.position + Vector2(
		STICK_RADIUS * 1.1 - knob_size * 0.5,
		STICK_RADIUS * 1.1 - knob_size * 0.5
	)
	_set_action(&"move_forward", false)
	_set_action(&"move_back",    false)
	_set_action(&"move_left",    false)
	_set_action(&"move_right",   false)


func _on_jump_pressed() -> void:
	_set_action(&"jump", true)


func _on_jump_released() -> void:
	_set_action(&"jump", false)


## يحقن أو يلغي حدث action وهمي في الـ InputMap
func _set_action(action: StringName, pressed: bool) -> void:
	if not InputMap.has_action(action):
		return
	if _ACTIONS.get(action, false) == pressed:
		return
	_ACTIONS[action] = pressed
	var ev := InputEventAction.new()
	ev.action = action
	ev.pressed = pressed
	ev.strength = 1.0 if pressed else 0.0
	Input.parse_input_event(ev)
