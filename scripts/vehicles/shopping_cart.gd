extends CharacterBody3D
## scripts/vehicles/shopping_cart.gd  —  v4 (Funny Air Control Edition / المرحلة 5)
##
## التصميم (زي v3):
##  - الـ HOST هو الوحيد اللي بيحسب فيزياء العربية (دراكسيون + قفز + بنزين/فرامل
##    القادم من الـ Client). مصدر حالة واحد = مستحيل العربية تختلف بين الجهازين.
##  - الـ CLIENT بيبعت مدخلاته بس (بنزين + فرامل)، وبيعرض العربية من snapshots.
##  - مفيش rollback ولا prediction على العربية => مفيش desync بالتصميم.
##
## تعديلات v4:
##  - تقليل السرعة القصوى والقفز.
##  - تحكّم محدود في الهوا (يحرّك شوية بس ما يطيرش) + جاذبية أعلى في الهوا.
##  - اهتزاز عشوائي في التوجيه بيزيد مع السرعة (تحكم مستفز بيضحك).
##  - ارتفاع قفزة عشوائي (85% - 120%).
##  - دعم جيم باد: ذراع شمال = توجيه، ذراع يمين / تريجرز = بنزين/فرامل، A = قفز.

enum ControlRole { ALL, STEER_JUMP, GAS_BRAKE }

const CART_FILES: Array = ["res://assets/models/shopping_cart.glb", "res://assets/models/model.glb"]
const CARTON_FILES: Array = ["res://assets/models/egg_carton.glb"]
const MELON_FILES: Array = ["res://assets/models/watermelon.glb", "res://assets/models/watermelon_lowpoly_free.glb"]

@export_group("Speed")
@export var max_speed: float = 11.0
@export var acceleration: float = 7.5
@export var brake_decel: float = 22.0
@export var coast_drag: float = 2.2
@export var gravity: float = 15.0
@export var gas_response: float = 8.0
@export var brake_response: float = 12.0

@export_group("Steering")
@export var turn_rate: float = 2.6
@export var steer_response: float = 10.0

@export_group("Jump")
@export var jump_velocity: float = 7.0
@export var coyote_time: float = 0.12
@export var jump_buffer_time: float = 0.15
@export var fall_limit: float = -12.0

@export_group("Air Control")
@export var air_steer_factor: float = 0.3
@export var air_accel_factor: float = 0.15
@export var air_gravity_mult: float = 1.35

@export_group("Funny Chaos")
@export var steer_wobble: float = 0.08
@export var jump_random_min: float = 0.85
@export var jump_random_max: float = 1.20

@export_group("Crash")
@export var crash_speed: float = 12.0
@export var crash_duration: float = 1.5

@export_group("Body & Visuals")
@export var max_lean: float = 0.4
@export var pitch_lean: float = 0.1
@export var crash_lift: float = 0.32
@export var crash_visual_speed: float = 10.0
@export var camera_follow_speed: float = 30.0
@export var camera_yaw_speed: float = 4.0

@export_group("Visual Models")
@export var cart_model_path: String = "res://assets/models/shopping_cart.glb"
@export var watermelon_model_path: String = "res://assets/models/watermelon.glb"
@export var cart_yaw_degrees: float = 180.0
@export var basket_floor_y: float = 0.52

@export_group("Chaos (Visual Only)")
@export var pull_strength: float = 0.15
@export var shimmy_strength: float = 0.2
@export var skid_strength: float = 0.3
@export var chaos_gain: float = 0.25

@export_group("Hurt")
@export var hurt_cooldown_time: float = 0.4

@export_group("Network")
@export var snapshot_hz: float = 30.0
@export var input_hz: float = 30.0
@export var render_delay_base: float = 0.09
@export var max_extrapolation: float = 0.12
@export var input_timeout: float = 0.35
@export var peer_lost_timeout: float = 3.0
@export var log_net_stats: bool = true
@export var log_interval_sec: float = 5.0

@onready var _visual: Node3D = $Visual
@onready var _camera_rig: Node3D = $CameraRig
@onready var _camera: Camera3D = $CameraRig/Camera3D
@onready var _hud_label: Label = $HUD/Label
@onready var _sync: CartSync = get_node_or_null("CartSync") as CartSync

# ---- Simulation state ----
var _online: bool = false
var _is_host: bool = false
var _is_client: bool = false
var _role: int = ControlRole.ALL
var _authoritative: bool = true
var _yaw: float = 0.0
var _speed: float = 0.0
var _jump_buffer: float = 0.0
var _coyote: float = 0.0
var _grounded: bool = false
var _crash_left: float = 0.0
var _is_fallen: bool = false
var _gas_smooth: float = 0.0
var _brake_smooth: float = 0.0
var _steer_smooth: float = 0.0
var _spawn_transform: Transform3D

# ---- Hurt / respawn ----
var _hurt_cooldown: float = 0.0
var _pending_respawn: bool = false
var _last_hurt_reason: String = ""

# ---- Visual ----
var _vis_lean: float = 0.0
var _vis_pitch: float = 0.0
var _crash_vis: float = 0.0
var _crash_side: float = 1.0
var _model: Node3D
var _wheel_spins: Array = []
var _items: Array = []
var _prev_vis_origin: Vector3
var _prev_vis_vel: Vector3 = Vector3.ZERO
var _acc_smooth: Vector3 = Vector3.ZERO

# ---- Network state ----
var _tick: int = 0
var _snapshot_every: int = 4
var _input_every: int = 4
var _last_sent_gas: float = -1.0
var _last_sent_brake: float = -1.0
var _last_input_tick: int = -100
var _client_placed: bool = false

# stats
var _stats_timer: float = 0.0
var _st_frames: int = 0


func _ready() -> void:
	add_to_group("unicycle")
	add_to_group("cart")
	cart_model_path = _first_existing(CART_FILES, cart_model_path)
	watermelon_model_path = _first_existing(MELON_FILES, watermelon_model_path)
	_update_net_role()

	floor_snap_length = 0.3
	_ensure_input_actions()
	_build_visual()
	_spawn_transform = global_transform
	_yaw = rotation.y
	_prev_vis_origin = global_position

	_camera_rig.top_level = true
	_camera_rig.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_camera_rig.global_position = global_position + Vector3.UP
	_camera_rig.rotation = Vector3(0.0, _yaw, 0.0)
	_camera.make_current()

	if _is_client:
		physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF

	var hz: float = float(Engine.physics_ticks_per_second)
	_snapshot_every = maxi(1, roundi(hz / maxf(snapshot_hz, 1.0)))
	_input_every = maxi(1, roundi(hz / maxf(input_hz, 1.0)))

	_net_setup()
	_log_startup()


func _log_startup() -> void:
	var role_str: String = "ALL (offline)"
	if _role == ControlRole.STEER_JUMP: role_str = "HOST (steer+jump, authoritative)"
	elif _role == ControlRole.GAS_BRAKE: role_str = "CLIENT (gas+brake, input only)"
	print("INIT: Cart v4 online=%s role=%s snap=%dticks input=%dticks" % [_online, role_str, _snapshot_every, _input_every])


func _ensure_input_actions() -> void:
	# ---- Keyboard ----
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

	# ---- Gamepad (تصميم "ذراع وذراع") ----
	# ذراع شمال أفقي = توجيه (A/D)
	_add_joy_axis(&"move_left",  JOY_AXIS_LEFT_X, -1.0)
	_add_joy_axis(&"move_right", JOY_AXIS_LEFT_X,  1.0)
	# ذراع شمال عمودي = بنزين/فرامل (بديل للكيبورد)
	_add_joy_axis(&"move_forward", JOY_AXIS_LEFT_Y, -1.0)
	_add_joy_axis(&"move_back",    JOY_AXIS_LEFT_Y,  1.0)
	# ذراع يمين عمودي = بنزين/فرامل (اللاعب اللي بيسوق)
	_add_joy_axis(&"move_forward", JOY_AXIS_RIGHT_Y, -1.0)
	_add_joy_axis(&"move_back",    JOY_AXIS_RIGHT_Y,  1.0)
	# تريجرز (RT = بنزين، LT = فرامل) زي ألعاب السيارات
	_add_joy_axis(&"move_forward", JOY_AXIS_TRIGGER_RIGHT, 1.0)
	_add_joy_axis(&"move_back",    JOY_AXIS_TRIGGER_LEFT,  1.0)
	# زر A = قفز
	_add_joy_button(&"jump", JOY_BUTTON_A)


func _add_joy_axis(action: StringName, axis: JoyAxis, value: float) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var ev := InputEventJoypadMotion.new()
	ev.axis = axis
	ev.axis_value = value
	InputMap.action_add_event(action, ev)


func _add_joy_button(action: StringName, button: JoyButton) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	var ev := InputEventJoypadButton.new()
	ev.button_index = button
	InputMap.action_add_event(action, ev)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		_leave_to_menu()
		return
	if not _is_client and event.is_action_pressed(&"jump"):
		_jump_buffer = jump_buffer_time


func _leave_to_menu() -> void:
	if _online and NetworkManager.is_network_ready():
		NetworkManager.disconnect_session()
	var menu_path: String = "res://scenes/ui/main_menu.tscn"
	if ResourceLoader.exists(menu_path):
		get_tree().change_scene_to_file(menu_path)


# =====================================================================
# PUBLIC API
# =====================================================================
func set_checkpoint(target: Transform3D) -> void:
	_spawn_transform = target


func is_authoritative() -> bool:
	return _authoritative


func _hurt(reason: String = "generic", _damage: float = 1.0) -> void:
	if _is_client: return
	if _hurt_cooldown > 0.0: return
	_hurt_cooldown = hurt_cooldown_time
	_last_hurt_reason = reason
	_pending_respawn = true


func _respawn(_reason: String = "respawn") -> void:
	_reset_to(_spawn_transform)
	if _is_host and _sync != null:
		_sync.notify_respawn(_spawn_transform.origin, _spawn_transform.basis.get_euler().y)


func _reset_to(target: Transform3D) -> void:
	_apply_reset_state(target)
	_snap_camera()


func _apply_reset_state(target: Transform3D) -> void:
	global_position = target.origin
	_yaw = target.basis.get_euler().y
	rotation = Vector3(0.0, _yaw, 0.0)
	velocity = Vector3.ZERO
	_speed = 0.0
	_crash_left = 0.0
	_is_fallen = false
	_jump_buffer = 0.0
	_coyote = 0.0
	_gas_smooth = 0.0
	_brake_smooth = 0.0
	_steer_smooth = 0.0


func _snap_camera() -> void:
	_camera_rig.global_position = global_position + Vector3.UP
	_camera_rig.rotation = Vector3(0.0, _yaw, 0.0)
	_prev_vis_origin = global_position
	_prev_vis_vel = Vector3.ZERO
	reset_physics_interpolation()


# =====================================================================
# PHYSICS
# =====================================================================
func _physics_process(delta: float) -> void:
	if _is_client:
		_client_tick()
	else:
		_host_tick(delta)


func _host_tick(delta: float) -> void:
	_tick += 1
	var steer: float
	var gas: float
	var brake: float
	if _online:
		steer = Input.get_axis(&"move_right", &"move_left")
		gas = 0.0
		brake = 0.0
		if _sync != null:
			var remote: Vector2 = _sync.get_remote_input()
			if _sync.get_remote_input_age() <= input_timeout:
				gas = remote.x
				brake = remote.y
	else:
		steer = Input.get_axis(&"move_right", &"move_left")
		gas = Input.get_action_strength(&"move_forward")
		brake = Input.get_action_strength(&"move_back")

	if _pending_respawn:
		_pending_respawn = false
		_respawn(_last_hurt_reason)
	elif _control_step(delta, steer, brake, gas):
		_respawn("fall")

	if _sync != null:
		_sync.publish_state(global_position, _yaw, velocity, _steer_smooth, _gas_smooth, _brake_smooth, _crash_left, delta)


func _client_tick() -> void:
	_tick += 1
	var gas: float = Input.get_action_strength(&"move_forward")
	var brake: float = Input.get_action_strength(&"move_back")
	var changed: bool = absf(gas - _last_sent_gas) > 0.02 or absf(brake - _last_sent_brake) > 0.02
	var since: int = _tick - _last_input_tick
	if since >= _input_every or (changed and since >= 2):
		_last_input_tick = _tick
		_last_sent_gas = gas
		_last_sent_brake = brake
		if _sync != null:
			_sync.send_input(gas, brake)


func _control_step(delta: float, steer: float, brake: float, gas: float) -> bool:
	_hurt_cooldown = maxf(_hurt_cooldown - delta, 0.0)

	if _crash_left > 0.0:
		_crash_left = maxf(_crash_left - delta, 0.0)
		steer = 0.0
		brake = 0.0
		gas = 0.0
		_jump_buffer = 0.0
		_is_fallen = _crash_left > 0.0

	_gas_smooth = move_toward(_gas_smooth, gas, gas_response * delta)
	_brake_smooth = move_toward(_brake_smooth, brake, brake_response * delta)
	_steer_smooth = move_toward(_steer_smooth, steer, steer_response * delta)
	_jump_buffer = maxf(_jump_buffer - delta, 0.0)

	if _grounded: _coyote = coyote_time
	else: _coyote = maxf(_coyote - delta, 0.0)

	# --- جاذبية أقوى في الهوا عشان القفزة تبقى قصيرة وما تطيرش ---
	var grav_eff: float = gravity if _grounded else gravity * air_gravity_mult
	velocity.y -= grav_eff * delta

	# --- معاملات التحكم في الهوا (محدود جدًا) ---
	var air_steer_mul: float = 1.0 if _grounded else air_steer_factor
	var air_gas_mul: float = 1.0 if _grounded else air_accel_factor

	var speed_frac: float = clampf(absf(_speed) / max_speed, 0.0, 1.0)
	if _is_fallen:
		_speed = 0.0
	elif _brake_smooth > 0.05:
		_speed = move_toward(_speed, 0.0, brake_decel * _brake_smooth * air_gas_mul * delta)
	elif _gas_smooth > 0.02:
		_speed = move_toward(_speed, max_speed * _gas_smooth, acceleration * air_gas_mul * delta)
	else:
		_speed = move_toward(_speed, 0.0, coast_drag * delta)

	# --- فوضى: اهتزاز بسيط في التوجيه كل ما سرعتك تزيد ---
	var wobble: float = 0.0
	if speed_frac > 0.05 and not _is_fallen:
		var t_now: float = Time.get_ticks_msec() * 0.001
		wobble = (sin(t_now * 7.3) * 0.5 + sin(t_now * 3.1) * 0.5) * steer_wobble * speed_frac

	var turn_factor: float = lerpf(0.5, 1.0, speed_frac) * air_steer_mul
	_yaw += (_steer_smooth + wobble) * turn_rate * turn_factor * delta
	rotation = Vector3(0.0, _yaw, 0.0)

	var forward: Vector3 = Vector3(-sin(_yaw), 0.0, -cos(_yaw))
	velocity.x = forward.x * _speed
	velocity.z = forward.z * _speed

	if _jump_buffer > 0.0 and _coyote > 0.0 and not _is_fallen:
		# --- ارتفاع القفزة عشوائي شوية = مستفز وبيضحك ---
		var jump_mult: float = randf_range(jump_random_min, jump_random_max)
		velocity.y = jump_velocity * jump_mult
		_jump_buffer = 0.0
		_coyote = 0.0

	var pre_move: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
	move_and_slide()
	_grounded = is_on_floor()

	if is_on_wall():
		var impact: float = 0.0
		for i in get_slide_collision_count():
			var n: Vector3 = get_slide_collision(i).get_normal()
			if absf(n.y) < 0.5: impact = maxf(impact, -pre_move.dot(n))
		if not _is_fallen and impact >= crash_speed:
			_crash_left = crash_duration
			_is_fallen = true
			_speed = 0.0
			velocity.x = 0.0
			velocity.z = 0.0
		else:
			_speed = clampf(velocity.dot(forward), 0.0, _speed)

	return global_position.y < fall_limit


# =====================================================================
# CLIENT: عرض الـ snapshots
# =====================================================================
func _client_apply_snapshots() -> void:
	_st_frames += 1
	if _sync == null:
		return
	var res: Dictionary = _sync.sample_state()
	if not bool(res.get("valid", false)):
		return
	var st: Dictionary = res["state"]

	var pos: Vector3 = st.get("pos", global_position) as Vector3
	var yaw: float = float(st.get("yaw", _yaw))
	var vel: Vector3 = st.get("vel", Vector3.ZERO) as Vector3
	var forward: Vector3 = Vector3(-sin(yaw), 0.0, -cos(yaw))

	_speed = vel.dot(forward)
	_steer_smooth = float(st.get("steer", 0.0))
	_gas_smooth = float(st.get("gas", 0.0))
	_brake_smooth = float(st.get("brake", 0.0))
	_crash_left = float(st.get("crash", 0.0))
	_is_fallen = _crash_left > 0.0

	_yaw = yaw
	velocity = vel
	global_transform = Transform3D(Basis(Vector3.UP, yaw), pos)

	if not _client_placed:
		_client_placed = true
		_snap_camera()


# =====================================================================
# VISUALS
# =====================================================================
func _process(delta: float) -> void:
	if delta <= 0.0: return
	_update_net_role()
	var visual_xf: Transform3D
	if _is_client:
		_client_apply_snapshots()
		visual_xf = global_transform
	else:
		visual_xf = get_global_transform_interpolated()

	_update_visual_pose(delta)
	_apply_chaos()
	_update_camera(delta, visual_xf)
	_update_wheels(delta)
	_update_items(visual_xf, delta)
	_update_hud()
	_log_stats(delta)


func _update_visual_pose(delta: float) -> void:
	var speed_frac: float = clampf(absf(_speed) / max_speed, 0.0, 1.0)
	var lean_k: float = 1.0 - exp(-12.0 * delta)
	_vis_lean = lerpf(_vis_lean, _steer_smooth * max_lean * speed_frac, lean_k)
	_vis_pitch = lerpf(_vis_pitch, (_gas_smooth - _brake_smooth) * pitch_lean, lean_k)
	if _crash_left <= 0.0: _crash_side = 1.0 if _vis_lean >= 0.0 else -1.0
	var crash_target: float = 1.0 if _crash_left > 0.0 else 0.0
	_crash_vis = lerpf(_crash_vis, crash_target, 1.0 - exp(-crash_visual_speed * delta))

	var roll: float = lerpf(_vis_lean, _crash_side * PI * 0.5, _crash_vis)
	var pitch: float = lerpf(_vis_pitch, 0.0, _crash_vis)
	_visual.basis = Basis.from_euler(Vector3(pitch, 0.0, roll))
	_visual.position = Vector3(0.0, crash_lift * _crash_vis, 0.0)


func _update_camera(delta: float, visual_xf: Transform3D) -> void:
	var flat_forward: Vector3 = -visual_xf.basis.z
	flat_forward.y = 0.0
	if flat_forward.length() > 0.4:
		var target_yaw: float = atan2(-flat_forward.x, -flat_forward.z)
		_camera_rig.rotation.y = lerp_angle(_camera_rig.rotation.y, target_yaw, 1.0 - exp(-camera_yaw_speed * delta))
	var target_pos: Vector3 = visual_xf.origin + Vector3.UP
	_camera_rig.global_position = _camera_rig.global_position.lerp(target_pos, 1.0 - exp(-camera_follow_speed * delta))


func _update_wheels(delta: float) -> void:
	for s in _wheel_spins:
		(s as Node3D).rotation.x -= (_speed * delta) / 0.11


func _update_items(visual_xf: Transform3D, delta: float) -> void:
	var vis_pos: Vector3 = visual_xf.origin
	var vel: Vector3 = (vis_pos - _prev_vis_origin) / delta
	var acc: Vector3 = ((vel - _prev_vis_vel) / delta).limit_length(60.0)
	_prev_vis_origin = vis_pos
	_prev_vis_vel = vel
	var acc_local: Vector3 = visual_xf.basis.transposed() * acc
	_acc_smooth = _acc_smooth.lerp(acc_local, 1.0 - exp(-25.0 * delta))
	for it in _items:
		var d: Dictionary = it
		var lim: float = d["lim"]
		var target: Vector3 = (-_acc_smooth * float(d["k"])).clamp(Vector3(-lim, -lim * 1.6, -lim), Vector3(lim, lim * 1.6, lim))
		var off: Vector3 = d["off"]
		var v: Vector3 = d["vel"]
		v += ((target - off) * float(d["stiff"]) - v * float(d["damp"])) * delta
		off += v * delta
		d["off"] = off
		d["vel"] = v
		(d["node"] as Node3D).position = (d["rest"] as Vector3) + off


func _update_hud() -> void:
	var role_text: String
	match _role:
		ControlRole.STEER_JUMP: role_text = "HOST: STEER (A/D) + JUMP"
		ControlRole.GAS_BRAKE: role_text = "CLIENT: GAS (W) + BRAKE (S)"
		_: role_text = "OFFLINE"
	var txt: String = "%s\nSPEED: %d km/h" % [role_text, int(absf(_speed) * 3.6)]
	if _is_client and (_sync == null or not _sync.has_data()):
		txt += "\nNET: connecting..."
	elif _online:
		txt += "\nNET: %d ms" % _get_ping_ms()
	if _crash_left > 0.0: txt += "\nCRASHED!"
	_hud_label.text = txt


func _build_visual() -> void:
	var aux: Node3D = _visual.get_node_or_null("AuxScene") as Node3D
	if aux != null:
		_model = aux
		for child in aux.find_children("*wheel*", "MeshInstance3D", true, false):
			_wheel_spins.append(child as Node3D)
		for child in aux.find_children("*Wheel*", "MeshInstance3D", true, false):
			if not _wheel_spins.has(child):
				_wheel_spins.append(child as Node3D)
		if _wheel_spins.is_empty():
			var dummy_wheel := MeshInstance3D.new()
			dummy_wheel.visible = false
			aux.add_child(dummy_wheel)
			_wheel_spins.append(dummy_wheel)
	else:
		_model = Node3D.new()
		_model.name = "Model"
		_visual.add_child(_model)
		var cart_scene: PackedScene = _try_load(cart_model_path)
		if cart_scene != null:
			var holder: Node3D = Node3D.new()
			_model.add_child(holder)
			var fitted: Node3D = cart_scene.instantiate() as Node3D
			holder.add_child(fitted)
			var size: Vector3 = _fit_into(fitted, 1.05, true, true)
			var auto_yaw: float = 90.0 if size.x > size.z * 1.15 else 0.0
			holder.rotation_degrees.y = cart_yaw_degrees + auto_yaw
		else:
			_build_fallback_box()
	_build_items()


func _build_fallback_box() -> void:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(1.0, 0.5, 1.5)
	mesh.mesh = box
	_model.add_child(mesh)
	var wheel := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.11
	cyl.bottom_radius = 0.11
	cyl.height = 0.05
	wheel.mesh = cyl
	wheel.rotation_degrees.z = 90
	wheel.position = Vector3(-0.25, 0.11, -0.38)
	_model.add_child(wheel)
	_wheel_spins.append(wheel)


func _build_items() -> void:
	var root: Node3D = Node3D.new()
	root.name = "Items"
	_visual.add_child(root)

	var carton: PackedScene = _try_load(_first_existing(CARTON_FILES, ""))
	if carton == null:
		var egg_mesh := SphereMesh.new()
		egg_mesh.radius = 0.05
		egg_mesh.height = 0.1
		var egg_mat := StandardMaterial3D.new()
		egg_mat.albedo_color = Color(0.9, 0.9, 0.8)
		var egg: MeshInstance3D = MeshInstance3D.new()
		egg.mesh = egg_mesh
		egg.material_override = egg_mat
		egg.position = Vector3(0, 0.3, 0)
		root.add_child(egg)
		_items.append({"node": egg, "rest": Vector3(0, 0.3, 0), "off": Vector3.ZERO, "vel": Vector3.ZERO, "stiff": 200.0, "damp": 10.0, "k": 0.0035, "lim": 0.03})
		return

	_make_item(root, Vector3(0.0, basket_floor_y + 0.11, 0.12), carton, 0.28, null, Vector3.ONE, null, 200.0, 10.0, 0.0035, 0.03)

	var melon: PackedScene = _try_load(watermelon_model_path)
	var melon_mesh: SphereMesh = null
	var melon_mat: ShaderMaterial = null
	if melon == null:
		melon_mesh = SphereMesh.new()
		melon_mesh.radius = 0.18
		melon_mesh.height = 0.36
		melon_mat = _melon_material()
	for sx in [-0.135, 0.135]:
		_make_item(root, Vector3(float(sx), basket_floor_y + 0.13, -0.28), melon, 0.34, melon_mesh, Vector3(0.75, 0.7, 1.0), melon_mat, 140.0, 12.0, 0.002, 0.02)


func _melon_material() -> ShaderMaterial:
	var sh: Shader = Shader.new()
	sh.code = "shader_type spatial;\nvoid fragment() {\n\tfloat s = step(0.5, fract(UV.x * 10.0));\n\tALBEDO = mix(vec3(0.06, 0.32, 0.10), vec3(0.18, 0.60, 0.22), s);\n\tROUGHNESS = 0.45;\n}\n"
	var m: ShaderMaterial = ShaderMaterial.new()
	m.shader = sh
	return m


func _first_existing(paths: Array, fallback: String) -> String:
	for p in paths:
		if ResourceLoader.exists(p as String):
			return p as String
	return fallback


func _apply_chaos() -> void:
	if _crash_left > 0.0 or _crash_vis > 0.02:
		return
	var speed_frac: float = clampf(absf(_speed) / max_speed, 0.0, 1.0)
	var gate: float = smoothstep(0.0, 0.15, speed_frac)
	if gate <= 0.0:
		return
	var t: float = Time.get_ticks_msec() / 1000.0
	var pull: float = (0.7 * sin(t * 0.45) + 0.5 * sin(t * 1.13)) * pull_strength
	var shimmy: float = sin(t * 14.0) * speed_frac * shimmy_strength
	var skid: float = sin(t * 6.0) * _brake_smooth * skid_strength
	var chaos_z: float = (pull * speed_frac + shimmy + skid) * gate * chaos_gain
	var chaos_x: float = cos(t * 12.0) * speed_frac * shimmy_strength * 0.5 * gate * chaos_gain
	_visual.rotation.z += chaos_z
	_visual.rotation.x += chaos_x


# ---- Helpers الموديلات ----
func _try_load(path: String) -> PackedScene:
	if path.is_empty() or not ResourceLoader.exists(path): return null
	return load(path) as PackedScene


func _fit_into(node: Node3D, target: float, horizontal: bool, ground_align: bool) -> Vector3:
	var a: AABB = _aabb_of(node)
	if a.size.length() < 0.0001: return Vector3.ZERO
	var dim: float = maxf(a.size.x, a.size.z) if horizontal else maxf(a.size.x, maxf(a.size.y, a.size.z))
	var s: float = target / maxf(dim, 0.0001)
	var c: Vector3 = a.get_center()
	node.scale = Vector3.ONE * s
	var y: float = -a.position.y * s if ground_align else -c.y * s
	node.position = Vector3(-c.x * s, y, -c.z * s)
	return a.size


func _aabb_of(node: Node3D) -> AABB:
	var inv: Transform3D = node.global_transform.affine_inverse()
	var out: AABB = AABB()
	var first: bool = true
	for m in node.find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = m as MeshInstance3D
		var a: AABB = (inv * mi.global_transform) * mi.get_aabb()
		if first:
			out = a
			first = false
		else:
			out = out.merge(a)
	return out


func _make_item(parent: Node3D, pos: Vector3, scene: PackedScene, size: float, mesh: Mesh, mesh_scale: Vector3, mat: Material, stiff: float, damp: float, k: float, lim: float) -> void:
	var holder: Node3D = Node3D.new()
	holder.position = pos
	parent.add_child(holder)
	if scene != null:
		var n: Node3D = scene.instantiate() as Node3D
		holder.add_child(n)
		_fit_into(n, size, false, false)
	else:
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = mat
		mi.scale = mesh_scale
		holder.add_child(mi)
	_items.append({"node": holder, "rest": pos, "off": Vector3.ZERO, "vel": Vector3.ZERO, "stiff": stiff, "damp": damp, "k": k, "lim": lim})


# =====================================================================
# NETWORK LAYER
# =====================================================================
func _net_setup() -> void:
	if _sync == null:
		push_warning("CartSync node not found under ShoppingCart — running local-only.")
		_online = false
		_is_client = false
		_is_host = false
		_authoritative = true
		_role = ControlRole.ALL
		return
	_sync.configure(snapshot_hz, render_delay_base, max_extrapolation, peer_lost_timeout)
	_sync.respawn_received.connect(_on_remote_respawn)
	_sync.peer_lost.connect(_on_peer_lost)


func _update_net_role() -> void:
	var online: bool = NetworkManager.is_network_ready()
	if online == _online:
		return
	_online = online
	_is_host = _online and NetworkManager.is_host()
	_is_client = _online and not _is_host
	_authoritative = not _is_client
	if not _online:
		_role = ControlRole.ALL
	elif _is_host:
		_role = ControlRole.STEER_JUMP
	else:
		_role = ControlRole.GAS_BRAKE
	if _is_client:
		physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	else:
		physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_INHERIT


func _on_remote_respawn(pos: Vector3, yaw: float) -> void:
	if not _is_client:
		return
	_apply_reset_state(Transform3D(Basis(Vector3.UP, yaw), pos))
	_snap_camera()
	_client_placed = false


func _on_peer_lost(_peer_id: int) -> void:
	if _online:
		print("NET: peer lost — leaving to menu.")
		_leave_to_menu()


func _get_ping_ms() -> int:
	var clock: NetworkClock = NetworkManager.get_clock()
	if clock == null:
		return 0
	return int(clock.get_rtt_ms())


# =====================================================================
# STATS
# =====================================================================
func _log_stats(delta: float) -> void:
	if not _online or not log_net_stats or _sync == null: return
	_stats_timer += delta
	if _stats_timer < log_interval_sec: return
	var t: float = _stats_timer
	var s: Dictionary = _sync.get_stats()
	var ping: int = _get_ping_ms()
	if _is_client:
		var rate: float = float(s["received"]) / t
		var status: String = "OK"
		if rate < float(snapshot_hz) * 0.5: status = "LOSS"
		print("NET [%s] CLIENT snaps: %.1f/s | buf: %d | rejected: %d | extrap: %d | ping: %dms" % [
			status, rate, int(s["buffered"]), int(s["rejected"]), int(s["extrapolations"]), ping])
	else:
		var age: int = int(_sync.get_remote_input_age() * 1000.0)
		var status_h: String = "OK"
		if age > 500: status_h = "NO INPUT"
		print("NET [%s] HOST snaps_out: %d | inputs_in: %d | peers: %d | rejected: %d | input_age: %dms | ping: %dms" % [
			status_h, int(s["sent"]), int(s["inputs"]), int(s["peers"]), int(s["rejected"]), age, ping])
	_stats_timer = 0.0
	_st_frames = 0
