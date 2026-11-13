extends RigidBody3D
## scripts/vehicles/unicycle.gd
## دراجة بعجلة واحدة بفيزيكس حقيقي (RigidBody3D / Jolt)، لاعبين بيتشاركوا في التحكم فيها:
##   الـ host   = دركسيون (A/D) + فرامل (S)
##   الـ client = بنزين (W) + قفز (Space)
## أوفلاين: لاعب واحد بيتحكم في كله.
##
## الفكرة: السرعة والإمساك بالأرض "أركيد" عشان التحكم يبقى سريع ومضبوط،
## لكن الدوران والميلان والتشقلب فيزيكس حقيقي: بنزين = بيرجّعك لورا شوية، فرامل = بتنبطح لقدام،
## لف بسرعة عالية = بتميل جامد. لو اتقلبت (أكتر من fall_tilt) وانت على الأرض بتفضل مرمي
## recover_time ثانية وبعدين بترجع واقفة. تصادم بسرعة عالية = تشقلب.
## الـ host هو اللي بيحرّك الدراجة. الـ client بيبعت البنزين والقفز بس (والـ host بيتحقق منهم)،
## وجسمها عنده frozen والمكان والدوران بيجوله بـ PropertySynchronizer.

const SessionMode = preload("res://scripts/multiplayer/session_mode.gd")

enum ControlRole { ALL, STEER_BRAKE, GAS_JUMP }

const WHEEL_RADIUS: float = 0.45

@export_group("Speed")
@export var max_speed: float = 22.0
@export var acceleration: float = 18.0
@export var brake_decel: float = 35.0
@export var coast_drag: float = 2.0
@export var grip: float = 10.0 # بيقتل الانزلاق الجانبي (أعلى = ملزقة أكتر)

@export_group("Steering")
@export var turn_rate: float = 3.2 # راديان/ثانية
@export var lean_accel: float = 22.0 # ميلان الدور مع السرعة (أعلى = أصعب وأخطر)
@export var brake_pitch: float = 12.0 # الفرامل بتنبطح بيها لقدام
@export var gas_pitch: float = 5.0 # البنزين بيرجّعها لورا شوية

@export_group("Balance")
@export var balance_kp: float = 28.0 # قوة رجوعها واقفة
@export var balance_kd: float = 6.0 # تثبيت (بيمنع الاهتزاز)
@export var air_balance: float = 0.2 # التوازن في الهوا (قليل = بتتشقلب)
@export var fall_tilt_degrees: float = 63.0 # بعد الميل ده بتقع
@export var recover_time: float = 1.5

@export_group("Jump")
@export var jump_velocity: float = 7.5
@export var fall_limit: float = -20.0 # تحت الرقم ده نرجّع الدراجة لمكان البداية

@export_group("Network")
@export var input_timeout: float = 0.6 # لو البنزين ماوصلش أحدث من كده نصفّره (عشان ما يعلقش)
@export var heartbeat: float = 0.2 # الـ client بيكرر البنزين كل كام ثانية طول ما هو ضاغط

@export_group("Visual")
@export var model_yaw_degrees: float = 0.0 # لو الدراجة ماشية بضهرها غيّرها لـ 180
@export var camera_follow_speed: float = 30.0
@export var camera_yaw_speed: float = 4.0

@onready var _model: Node3D = $Visual/Model
@onready var _wheel_pivot: Node3D = $Visual/Model/WheelPivot
@onready var _camera_rig: Node3D = $CameraRig
@onready var _camera: Camera3D = $CameraRig/Camera3D
@onready var _hud_label: Label = $HUD/Label

var _online: bool = false
var _simulates: bool = true # الجهاز ده هو اللي بيحرّك الدراجة (الـ host أو أوفلاين)
var _role: int = ControlRole.ALL

var _jump_buffer: float = 0.0
var _no_ground_timer: float = 0.0 # بعد القفز نتجاهل الأرض لحظة
var _fallen_time: float = 0.0
var _is_fallen: bool = false
var _heading: Vector3 = Vector3.FORWARD
var _spawn_transform: Transform3D

# مدخلات الـ client عند الـ host
var _remote_gas: float = 0.0
var _remote_gas_time: float = -100.0

# إرسال الـ client
var _last_sent_gas: float = -1.0
var _heartbeat_timer: float = 0.0

# للشكل
var _last_pos: Vector3
var _vis_speed: float = 0.0
var _cam_yaw: float = 0.0
var _wheel_angle: float = 0.0


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

	if not _simulates:
		# عند الـ client: الفيزيكس مش بتشتغل، والمكان بيجي من الـ host
		freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		freeze = true

	_ensure_input_actions()
	_spawn_transform = global_transform
	_last_pos = global_position
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
			steer = Input.get_axis(&"move_right", &"move_left") # شمال = موجب
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
	_no_ground_timer = maxf(_no_ground_timer - delta, 0.0)

	var basis_up: Vector3 = global_transform.basis.y
	var tilt: float = acos(clampf(basis_up.dot(Vector3.UP), -1.0, 1.0))
	_is_fallen = tilt > deg_to_rad(fall_tilt_degrees)

	# ---- الأرض
	var ground: Dictionary = _probe_ground(0.15)
	var grounded: bool = not ground.is_empty() and _no_ground_timer <= 0.0 and not _is_fallen
	var ground_normal: Vector3 = ground.get("normal", Vector3.UP) as Vector3

	# ---- وقعة / رجوع واقفة
	if _is_fallen and not _probe_ground(0.6, 0.6).is_empty():
		_fallen_time += delta
		if _fallen_time >= recover_time:
			_recover()
			return
	elif not _is_fallen:
		_fallen_time = 0.0

	# ---- اتجاه الدراجة على الأرض
	var flat_forward: Vector3 = -global_transform.basis.z
	flat_forward.y = 0.0
	if flat_forward.length() > 0.25:
		_heading = flat_forward.normalized()
	var right: Vector3 = _heading.cross(Vector3.UP)

	var lv: Vector3 = linear_velocity
	var av: Vector3 = angular_velocity
	var vf: float = lv.dot(_heading)
	var vl: float = lv.dot(right)
	var speed_frac: float = clampf(absf(vf) / max_speed, 0.0, 1.0)

	if grounded:
		# سرعة (أركيد): بنزين / فرامل / احتكاك
		if brake:
			vf = move_toward(vf, 0.0, brake_decel * delta)
		elif gas > 0.0:
			if vf < max_speed:
				vf = minf(vf + acceleration * gas * delta, max_speed)
		else:
			vf = move_toward(vf, 0.0, coast_drag * delta)
		vl *= maxf(0.0, 1.0 - grip * delta) # العجلة مبتتزحلقش على جنبها

		# السرعة بتتوزع على مستوى الأرض (عشان المنحدرات)
		var forward_ground: Vector3 = (_heading - ground_normal * _heading.dot(ground_normal)).normalized()
		lv = forward_ground * vf + right * vl
		if _jump_buffer > 0.0:
			lv.y = jump_velocity
			_jump_buffer = 0.0
			_no_ground_timer = 0.2
			grounded = false

		# دوران (yaw): بطيء وهي واقفة، وأقل شوية في السرعة العالية
		var turn_factor: float = lerpf(0.6, 1.0, clampf(absf(vf) / 6.0, 0.0, 1.0)) * (1.0 - 0.35 * speed_frac)
		var target_yaw: float = steer * turn_rate * turn_factor
		av.y = lerpf(av.y, target_yaw, 1.0 - exp(-12.0 * delta))

		# ميلان فيزيكسي: بتميل في الدور، بتنبطح مع الفرامل، بترجع لورا مع البنزين
		var lean: Vector3 = -right * steer * lean_accel * speed_frac
		if brake:
			lean += _heading * brake_pitch * speed_frac
		lean += -_heading * gas * gas_pitch
		av += basis_up.cross(lean) * delta
	elif not _is_fallen:
		# في الهوا: تحكم بسيط في الدوران بس
		av.y = lerpf(av.y, steer * turn_rate * 0.4, 1.0 - exp(-4.0 * delta))

	# ---- توازن: بترجع واقفة (ضعيف في الهوا، من غير توازن لو وقعت)
	if not _is_fallen:
		var gain: float = 1.0 if grounded else air_balance
		var err: Vector3 = basis_up.cross(Vector3.UP)
		var av_flat: Vector3 = av - Vector3.UP * av.dot(Vector3.UP)
		av += (err * balance_kp * gain - av_flat * balance_kd * lerpf(0.3, 1.0, gain)) * delta

	linear_velocity = lv
	angular_velocity = av

	if global_position.y < fall_limit:
		_respawn()


# شعاع للأسفل من مركز العجلة. بيرجّع {} لو مفيش أرض قريبة.
func _probe_ground(reach: float, start_lift: float = 0.0) -> Dictionary:
	var from: Vector3 = global_position + global_transform.basis.y * WHEEL_RADIUS + Vector3.UP * start_lift
	var to: Vector3 = from + Vector3.DOWN * (WHEEL_RADIUS + reach + start_lift)
	var query := PhysicsRayQueryParameters3D.create(from, to, 1, [get_rid()])
	return get_world_3d().direct_space_state.intersect_ray(query)


# بنرجّعها واقفة في نفس المكان بنفس الاتجاه
func _recover() -> void:
	var yaw: float = atan2(-_heading.x, -_heading.z)
	_reset_to(Transform3D(Basis(Vector3.UP, yaw), global_position + Vector3.UP * 0.4))


func _respawn() -> void:
	_reset_to(_spawn_transform)


func _reset_to(target: Transform3D) -> void:
	global_transform = target
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_fallen_time = 0.0
	_is_fallen = false
	_last_pos = global_position
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


# ---------------------------------------------------------------- الكاميرا والشاشة
func _process(delta: float) -> void:
	if delta <= 0.0:
		return

	# سرعة ظاهرة بتتحسب من الحركة الفعلية فبتشتغل نفس الشكل عند الاتنين
	var moved: Vector3 = global_position - _last_pos
	moved.y = 0.0
	var raw_speed: float = moved.length() / delta
	# العجلة بتلف على قد المسافة اللي اتمشيت (محسوبة من الحركة الفعلية، فبتشتغل عند الاتنين)
	var travel_dir: Vector3 = -global_transform.basis.z
	travel_dir.y = 0.0
	if travel_dir.length() > 0.25 and raw_speed < 80.0:
		_wheel_angle -= moved.dot(travel_dir.normalized()) / WHEEL_RADIUS
		_wheel_pivot.rotation.x = fposmod(_wheel_angle, TAU)
	_last_pos = global_position
	if raw_speed > 80.0: # قفزة (respawn)
		raw_speed = 0.0
	_vis_speed = lerpf(_vis_speed, raw_speed, 1.0 - exp(-10.0 * delta))

	# الكاميرا بتتبع اتجاه الدراجة (من غير ما تتلخبط وهي بتتشقلب)
	var flat_forward: Vector3 = -global_transform.basis.z
	flat_forward.y = 0.0
	if flat_forward.length() > 0.4:
		var yaw: float = atan2(-flat_forward.x, -flat_forward.z)
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
	_hud_label.text = "%s\n%d km/h" % [role_text, int(_vis_speed * 3.6)]
