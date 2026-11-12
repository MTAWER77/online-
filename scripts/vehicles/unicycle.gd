extends CharacterBody3D
## scripts/vehicles/unicycle.gd
## دراجة بعجلة واحدة، لاعبين بيتشاركوا في التحكم فيها:
##   الـ host   = دركسيون (A/D) + فرامل (S)
##   الـ client = بنزين (W) + قفز (Space)
## أوفلاين: لاعب واحد بيتحكم في كله.
## الـ host هو اللي بيحرّك الدراجة (authoritative). الـ client بيبعت البنزين والقفز بس،
## والـ host بيتحقق منهم (clamp + timeout) وبعدين بيحركها. المكان والدوران بيتزامنوا بـ PropertySynchronizer.
## الميلان (lean) مجرد شكل بيتحسب محليًا عند كل جهاز، مش متزامن.

const SessionMode = preload("res://scripts/multiplayer/session_mode.gd")

enum ControlRole { ALL, STEER_BRAKE, GAS_JUMP }

@export_group("Driving")
@export var max_speed: float = 14.0
@export var acceleration: float = 9.0
@export var brake_decel: float = 18.0
@export var coast_drag: float = 2.5
@export var turn_rate: float = 2.2 # راديان/ثانية
@export var jump_velocity: float = 5.0
@export var fall_limit: float = -20.0 # تحت الرقم ده نرجّع الدراجة لمكان البداية

@export_group("Network")
@export var input_timeout: float = 0.6 # لو البنزين ماوصلش أحدث من كده نصفّره (عشان ما يعلقش)
@export var heartbeat: float = 0.2 # الـ client بيكرر البنزين كل كام ثانية طول ما هو ضاغط

@export_group("Visual")
@export var model_yaw_degrees: float = 0.0 # لو الدراجة ماشية بضهرها غيّرها لـ 180
@export var lean_amount: float = 0.25
@export var lean_max: float = 0.45
@export var camera_follow_speed: float = 30.0
@export var camera_yaw_speed: float = 4.0

@onready var _visual: Node3D = $Visual
@onready var _model: Node3D = $Visual/Model
@onready var _camera_rig: Node3D = $CameraRig
@onready var _camera: Camera3D = $CameraRig/Camera3D
@onready var _hud_label: Label = $HUD/Label

var _online: bool = false
var _simulates: bool = true # الجهاز ده هو اللي بيحرّك الدراجة (الـ host أو أوفلاين)
var _role: int = ControlRole.ALL

var _speed: float = 0.0
var _jump_buffer: float = 0.0
var _spawn_transform: Transform3D

# مدخلات الـ client عند الـ host
var _remote_gas: float = 0.0
var _remote_gas_time: float = -100.0

# إرسال الـ client
var _last_sent_gas: float = -1.0
var _heartbeat_timer: float = 0.0

# للشكل
var _last_pos: Vector3
var _last_yaw: float
var _vis_speed: float = 0.0
var _vis_yaw_rate: float = 0.0
var _vis_accel: float = 0.0
var _cam_yaw: float = 0.0


func _ready() -> void:
	# الـ spawner بيشيل الـ PropertySynchronizer قبل ما يضيفنا لو أوفلاين
	_online = not SessionMode.offline and GDSync.is_active()
	_simulates = (not _online) or GDSync.is_host()
	if not _online:
		_role = ControlRole.ALL
	else:
		_role = ControlRole.STEER_BRAKE if GDSync.is_host() else ControlRole.GAS_JUMP
		GDSync.expose_func(_receive_gas)
		GDSync.expose_func(_receive_jump)

	_ensure_input_actions()
	_spawn_transform = global_transform
	_last_pos = global_position
	_last_yaw = global_rotation.y
	_cam_yaw = global_rotation.y
	_model.rotation_degrees.y = model_yaw_degrees

	_camera_rig.top_level = true
	_camera_rig.global_position = global_position + Vector3.UP
	_camera_rig.rotation = Vector3(0.0, _cam_yaw, 0.0)
	_camera.make_current()


func _ensure_input_actions() -> void:
	# بنسجّل الأكشنز هنا لأن مفيش مكان تاني بيعملها
	var keys: Dictionary = {
		&"move_forward": KEY_W, &"move_back": KEY_S,
		&"move_left": KEY_A, &"move_right": KEY_D, &"jump": KEY_SPACE,
	}
	for action: StringName in keys:
		if not InputMap.has_action(action):
			InputMap.add_action(action)
			var ev := InputEventKey.new()
			ev.physical_keycode = keys[action] as Key
			InputMap.action_add_event(action, ev)


# Esc (أو زرار Menu في الموبايل) يرجّعنا للقائمة
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		_leave_to_menu()


func _leave_to_menu() -> void:
	if _online:
		GDSync.lobby_leave()
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")


# ---------------------------------------------------------------- الفيزيكس
func _physics_process(delta: float) -> void:
	if not _simulates:
		_send_client_input(delta)
		return

	var steer: float = 0.0
	var brake: bool = false
	var gas: float = 0.0

	match _role:
		ControlRole.ALL:
			steer = Input.get_axis(&"move_right", &"move_left")
			brake = Input.is_action_pressed(&"move_back")
			gas = Input.get_action_strength(&"move_forward")
			if Input.is_action_just_pressed(&"jump"):
				_jump_buffer = 0.15
		ControlRole.STEER_BRAKE:
			steer = Input.get_axis(&"move_right", &"move_left")
			brake = Input.is_action_pressed(&"move_back")
			var now: float = Time.get_ticks_msec() / 1000.0
			if now - _remote_gas_time <= input_timeout:
				gas = _remote_gas
		_:
			pass

	_jump_buffer = maxf(_jump_buffer - delta, 0.0)

	var on_floor: bool = is_on_floor()

	# سرعة (بنزين / فرامل / احتكاك) بتشتغل بس والعجلة على الأرض
	if on_floor:
		if brake:
			_speed = move_toward(_speed, 0.0, brake_decel * delta)
		elif gas > 0.0:
			_speed = minf(_speed + acceleration * gas * delta, max_speed)
		else:
			_speed = move_toward(_speed, 0.0, coast_drag * delta)

	# دركسيون: بطيء جدًا وهي واقفة، وأقل في الهوا
	var speed_factor: float = lerpf(0.4, 1.0, clampf(_speed / 6.0, 0.0, 1.0))
	var air_factor: float = 1.0 if on_floor else 0.3
	rotation.y += steer * turn_rate * speed_factor * air_factor * delta

	var forward: Vector3 = -global_transform.basis.z
	velocity.x = forward.x * _speed
	velocity.z = forward.z * _speed
	if not on_floor:
		velocity.y -= float(ProjectSettings.get_setting("physics/3d/default_gravity")) * delta
	elif _jump_buffer > 0.0:
		velocity.y = jump_velocity
		_jump_buffer = 0.0

	move_and_slide()

	# لو خبطنا في حاجة السرعة الفعلية بتقل
	var flat := Vector3(velocity.x, 0.0, velocity.z)
	_speed = maxf(flat.dot(-global_transform.basis.z), 0.0)

	if global_position.y < fall_limit:
		_respawn()


func _respawn() -> void:
	global_transform = _spawn_transform
	velocity = Vector3.ZERO
	_speed = 0.0
	_last_pos = global_position
	_cam_yaw = global_rotation.y
	var sync: Node = get_node_or_null("PropertySynchronizer")
	if sync != null:
		sync.call("pause_interpolation", 0.3) # عشان الـ client ما يشوفهاش بتنزلق


# ---------------------------------------------------------------- الـ client
func _send_client_input(delta: float) -> void:
	if _role != ControlRole.GAS_JUMP:
		return
	var gas: float = snappedf(Input.get_action_strength(&"move_forward"), 0.1)
	_heartbeat_timer += delta
	var changed: bool = not is_equal_approx(gas, _last_sent_gas)
	if changed or (gas > 0.0 and _heartbeat_timer >= heartbeat):
		_last_sent_gas = gas
		_heartbeat_timer = 0.0
		GDSync.call_func_on(GDSync.get_host(), _receive_gas, gas)
	if Input.is_action_just_pressed(&"jump"):
		GDSync.call_func_on(GDSync.get_host(), _receive_jump)


# بتتنفذ عند الـ host بس. الـ host بيتحقق من القيم قبل ما يستخدمها.
func _receive_gas(value: float) -> void:
	if not GDSync.is_host():
		return
	_remote_gas = clampf(value, 0.0, 1.0)
	_remote_gas_time = Time.get_ticks_msec() / 1000.0


func _receive_jump() -> void:
	if not GDSync.is_host():
		return
	_jump_buffer = 0.15


# ---------------------------------------------------------------- الشكل والكاميرا
func _process(delta: float) -> void:
	if delta <= 0.0:
		return

	# سرعة وتدوير ظاهرين، بيتحسبوا من الحركة الفعلية فبيشتغلوا نفس الشكل عند الاتنين
	var forward: Vector3 = -global_transform.basis.z
	var yaw: float = global_rotation.y
	var raw_speed: float = (global_position - _last_pos).dot(forward) / delta
	var raw_yaw_rate: float = angle_difference(_last_yaw, yaw) / delta
	_last_pos = global_position
	_last_yaw = yaw
	if absf(raw_speed) > 60.0: # قفزة (respawn)
		raw_speed = 0.0
		raw_yaw_rate = 0.0

	var smooth: float = 1.0 - exp(-10.0 * delta)
	var prev_speed: float = _vis_speed
	_vis_speed = lerpf(_vis_speed, raw_speed, smooth)
	_vis_yaw_rate = lerpf(_vis_yaw_rate, raw_yaw_rate, smooth)
	_vis_accel = lerpf(_vis_accel, (_vis_speed - prev_speed) / delta, smooth)

	# ميلان للجنب مع الدوران (يسار = roll موجب) وللأمام مع التسارع
	var speed_frac: float = clampf(_vis_speed / max_speed, 0.0, 1.0)
	var roll: float = clampf(_vis_yaw_rate * lean_amount * (0.3 + speed_frac), -lean_max, lean_max)
	var tilt: float = -clampf(_vis_accel / 20.0, -1.0, 1.0) * 0.15
	_visual.rotation = Vector3(tilt, 0.0, roll)

	# كاميرا ناعمة بتتبع الدراجة من ورا
	_cam_yaw = lerp_angle(_cam_yaw, yaw, 1.0 - exp(-camera_yaw_speed * delta))
	_camera_rig.rotation.y = _cam_yaw
	var target: Vector3 = global_position + Vector3.UP
	_camera_rig.global_position = _camera_rig.global_position.lerp(
		target, 1.0 - exp(-camera_follow_speed * delta))

	_update_hud()


func _update_hud() -> void:
	var role_text: String
	match _role:
		ControlRole.STEER_BRAKE:
			role_text = "YOU: STEER (A/D) + BRAKE (S)"
		ControlRole.GAS_JUMP:
			role_text = "YOU: GAS (W) + JUMP (Space)"
		_:
			role_text = "OFFLINE: A/D steer, S brake, W gas, Space jump"
	_hud_label.text = "%s\n%d km/h" % [role_text, int(absf(_vis_speed) * 3.6)]
