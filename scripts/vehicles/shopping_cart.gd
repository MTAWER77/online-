extends CharacterBody3D
## scripts/vehicles/shopping_cart.gd
## تحويل العربية لنظام Kinematic للحصول على تزامن مثالي (0ms lag) بدون تقطيع.

const SessionMode = preload("res://scripts/multiplayer/session_mode.gd")
const DebugLog = preload("res://scripts/systems/debug_log.gd")
const NetClock = preload("res://scripts/multiplayer/net_clock.gd")

enum ControlRole { ALL, STEER_JUMP, GAS_BRAKE }

@export_group("Speed")
@export var max_speed: float = 14.0
@export var acceleration: float = 9.0
@export var brake_decel: float = 22.0
@export var coast_drag: float = 2.0
@export var gravity: float = 9.8

@export_group("Steering")
@export var turn_rate: float = 2.2
@export var steer_response: float = 8.0

@export_group("Body & Visuals")
@export var roll_lean: float = 0.15
@export var pitch_lean: float = 0.1
@export var max_lean: float = 0.4
@export var fall_tilt_degrees: float = 70.0
@export var recover_time: float = 1.2

@export_group("Jump")
@export var jump_velocity: float = 7.0
@export var coyote_time: float = 0.12
@export var fall_limit: float = -12.0

@export_group("Network (Old Mode)")
@export var snapshot_interval: float = 0.033
@export var interp_delay: float = 0.10
@export var max_extrapolation: float = 0.15
@export var teleport_distance: float = 6.0
@export var heartbeat: float = 0.1
@export var min_send_interval: float = 0.04
@export var input_timeout: float = 0.4
@export var min_drive_interval: float = 0.015

@export_group("Visual Models")
@export var cart_model_path: String = "res://assets/models/shopping_cart.glb"
@export var egg_model_path: String = "res://assets/models/egg.glb"
@export var watermelon_model_path: String = "res://assets/models/watermelon.glb"
@export var model_yaw_degrees: float = 0.0
@export var camera_follow_speed: float = 30.0
@export var camera_yaw_speed: float = 4.0

@export_group("Rollback")
@export var rb_send_every: int = 4
@export var rb_send_window: int = 24
@export var rb_max_rollback: int = 60
@export var rb_auth_every: int = 45
@export var rb_auth_tolerance: float = 0.10
@export var rb_remote_timeout_ticks: int = 42
@export var rb_input_delay: int = 4
@export var rb_input_threshold: float = 0.08
@export var rb_rollback_cooldown: int = 4

@onready var _visual: Node3D = $Visual
@onready var _camera_rig: Node3D = $CameraRig
@onready var _camera: Camera3D = $CameraRig/Camera3D
@onready var _hud_label: Label = $HUD/Label

# ---- State ----
var _online: bool = false
var _authoritative: bool = true
var _role: int = ControlRole.ALL

var _yaw: float = 0.0
var _speed: float = 0.0
var _jump_buffer: float = 0.0
var _coyote: float = 0.0
var _is_fallen: bool = false
var _fallen_time: float = 0.0
var _spawn_transform: Transform3D

# ---- Visual State ----
var _vis_lean: float = 0.0
var _vis_pitch: float = 0.0
var _gas_smooth: float = 0.0
var _brake_smooth: float = 0.0
var _steer_smooth: float = 0.0
var _model: Node3D
var _wheel_spins: Array = []
var _items: Array = []
var _prev_vis_origin: Vector3
var _prev_vis_vel: Vector3 = Vector3.ZERO
var _acc_smooth: Vector3 = Vector3.ZERO
var _steer_vis: float = 0.0
var _net_steer: float = 0.0

# ---- Networking Old ----
var _snap_timer: float = 0.0
var _snap_seq_out: int = 0
var _teleport_id: int = 0
var _peer_id: int = -1
var _peer_check_ms: int = 0
var _buf: Array = []
var _snap_seq_in: int = -1
var _teleport_seen: int = 0
var _teleport_pending: bool = false
var _last_snap_ms: int = 0
var _delay_smooth: float = 0.1
var _diag_timer: float = 0.0
var _last_drive_ms: int = -1000000
var _drive_seq_in: int = -1
var _remote_gas: float = 0.0
var _remote_brake: float = 0.0
var _remote_time: float = -100.0
var _input_timed_out: bool = false
var _dropped_rpc: int = 0
var _snap_sent: int = 0
var _snap_count: int = 0
var _underruns: int = 0
var _teleports: int = 0
var _drive_seq: int = 0
var _last_gas_sent: float = -1.0
var _last_brake_sent: float = -1.0
var _hb_timer: float = 0.0
var _send_cd: float = 0.0
var _repeat_time: float = 0.0

# ---- Rollback ----
const RB_HIST: int = 256
const RB_STATE_SIZE: int = 16
var _rb: bool = false
var _rb_resim: bool = false
var _rb_sim_time: float = 0.0
var _dt: float = 1.0 / 120.0
var _tick: int = 0
var _rb_started: bool = false
var _rb_wait_start_ms: int = 0
var _rb_peer_hello: bool = false
var _rb_got_go: bool = false
var _rb_go_sent: bool = false
var _rb_start_at_ms: int = 0
var _rb_states: Array = []
var _rb_state_tag: PackedInt32Array = PackedInt32Array()
var _rb_local: Array[Vector4] = []
var _rb_local_tag: PackedInt32Array = PackedInt32Array()
var _rb_used: Array[Vector4] = []
var _rb_remote: Array[Vector4] = []
var _rb_remote_tag: PackedInt32Array = PackedInt32Array()
var _rb_remote_last: Vector4 = Vector4.ZERO
var _rb_remote_latest: int = -1
var _rb_confirmed: int = -1
var _rb_from: int = -1
var _rb_events: Dictionary = {}
var _rb_auth_pending: Dictionary = {}
var _rb_corr: Vector3 = Vector3.ZERO
var _rb_corr_rot: Quaternion = Quaternion.IDENTITY
var _rb_had_peer: bool = false
var _rb_peer_lost_ms: int = 0
var _rb_in_count: int = 0
var _rb_in_window_start_ms: int = 0
var _rb_stat_rollbacks: int = 0
var _rb_stat_corrections: int = 0
var _err_sum: float = 0.0
var _err_n: int = 0
var _last_rollback_tick: int = -100

func _ready() -> void:
	add_to_group("unicycle")
	NetClock.reset()
	_online = not SessionMode.offline and GDSync.is_active()
	_authoritative = (not _online) or GDSync.is_host()
	if not _online:
		_role = ControlRole.ALL
	else:
		_role = ControlRole.STEER_JUMP if GDSync.is_host() else ControlRole.GAS_BRAKE
		GDSync.expose_func(_receive_drive, ENUMS.EXPOSE_PERMISSION.CLIENT)
		GDSync.expose_func(_receive_snapshot, ENUMS.EXPOSE_PERMISSION.HOST)

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
	
	_rb_setup()

func _ensure_input_actions() -> void:
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

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"ui_cancel"):
		if _online: GDSync.lobby_leave()
		get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")

func _physics_process(delta: float) -> void:
	if _rb:
		_rb_process(delta)
		return
	if _authoritative:
		_host_step(delta)
	else:
		_client_step(delta)

func _host_step(delta: float) -> void:
	var steer: float = 0.0
	var gas: float = 0.0
	var brake: float = 0.0
	match _role:
		ControlRole.ALL:
			steer = Input.get_axis(&"move_right", &"move_left")
			gas = Input.get_action_strength(&"move_forward")
			brake = Input.get_action_strength(&"move_back")
			if Input.is_action_just_pressed(&"jump"): _jump_buffer = 0.15
		ControlRole.STEER_JUMP:
			steer = Input.get_axis(&"move_right", &"move_left")
			if Input.is_action_just_pressed(&"jump"): _jump_buffer = 0.15
			var now: float = Time.get_ticks_msec() / 1000.0
			if now - _remote_time <= input_timeout:
				gas = _remote_gas
				brake = _remote_brake
				_input_timed_out = false

	var wants: bool = _control_step(delta, steer, brake, gas, true)
	if wants: _reset_to(_spawn_transform)
	
	_send_snapshot(delta)
	_host_diag(delta)

func _control_step(delta: float, steer: float, brake: float, gas: float, track_fall: bool) -> bool:
	_gas_smooth = move_toward(_gas_smooth, gas, 8.0 * delta)
	_brake_smooth = move_toward(_brake_smooth, brake, 12.0 * delta)
	_steer_smooth = move_toward(_steer_smooth, steer, 10.0 * delta)
	_jump_buffer = maxf(_jump_buffer - delta, 0.0)

	if is_on_floor():
		_coyote = coyote_time
	else:
		_coyote = maxf(_coyote - delta, 0.0)
		velocity.y -= gravity * delta

	var speed_frac: float = clampf(absf(_speed) / max_speed, 0.0, 1.0)
	
	if _brake_smooth > 0.05:
		_speed = move_toward(_speed, 0.0, brake_decel * _brake_smooth * delta)
	elif _gas_smooth > 0.02:
		_speed = move_toward(_speed, max_speed * _gas_smooth, acceleration * delta)
	else:
		_speed = move_toward(_speed, 0.0, coast_drag * delta)
	
	var turn_factor: float = lerpf(0.5, 1.0, speed_frac)
	_yaw -= _steer_smooth * turn_rate * turn_factor * delta
	rotation.y = _yaw
	
	var forward: Vector3 = -transform.basis.z
	velocity.x = forward.x * _speed
	velocity.z = forward.z * _speed
	
	if _jump_buffer > 0.0 and _coyote > 0.0:
		velocity.y = jump_velocity
		_jump_buffer = 0.0
		_coyote = 0.0
	
	var before_vel: float = velocity.length()
	move_and_slide()
	
	# لو خبط في حيطة بسرعة
	if get_slide_collision_count() > 0 and before_vel > 10.0:
		_speed = 0.0
		_is_fallen = true 
	
	var target_lean: float = -_steer_smooth * max_lean * speed_frac
	var target_pitch: float = _brake_smooth * pitch_lean - _gas_smooth * pitch_lean
	_vis_lean = lerpf(_vis_lean, target_lean, 10.0 * delta)
	_vis_pitch = lerpf(_vis_pitch, target_pitch, 10.0 * delta)
	
	var tilt: float = rad_to_deg(maxf(absf(_vis_lean), absf(_vis_pitch)))
	if tilt > fall_tilt_degrees:
		_is_fallen = true
		
	if _is_fallen:
		_fallen_time += delta
		_speed = 0.0
		if _fallen_time >= recover_time:
			return track_fall
	else:
		_fallen_time = 0.0
		
	if global_position.y < fall_limit:
		return track_fall
		
	return false

func _apply_reset_state(target: Transform3D) -> void:
	global_position = target.origin
	_yaw = target.basis.get_euler().y
	rotation = target.basis.get_euler()
	velocity = Vector3.ZERO
	_speed = 0.0
	_is_fallen = false
	_fallen_time = 0.0
	_vis_lean = 0.0
	_vis_pitch = 0.0

func _reset_to(target: Transform3D) -> void:
	_apply_reset_state(target)
	_camera_rig.global_position = global_position + Vector3.UP
	_prev_vis_origin = global_position
	_prev_vis_vel = Vector3.ZERO
	reset_physics_interpolation()
	_teleport_id += 1
	_send_snapshot(0.0, true)

# [ADDED FIX] الدالة الناقصة
func _sim_time() -> float:
	return _rb_sim_time if _rb else NetClock.world_time()

# --- Visuals & Process ---
func _process(delta: float) -> void:
	if delta <= 0.0: return
	var visual_xf: Transform3D = get_global_transform_interpolated()
	
	if _rb:
		var bq: Quaternion = visual_xf.basis.get_rotation_quaternion()
		_visual.transform = Transform3D(Basis(bq.inverse() * _rb_corr_rot * bq), visual_xf.basis.inverse() * _rb_corr)
	
	var flat_forward: Vector3 = -visual_xf.basis.z
	flat_forward.y = 0.0
	if flat_forward.length() > 0.4:
		var target_yaw: float = atan2(-flat_forward.x, -flat_forward.z)
		_camera_rig.rotation.y = lerp_angle(_camera_rig.rotation.y, target_yaw, 5.0 * delta)
	
	var target_pos: Vector3 = visual_xf.origin + Vector3.UP + _rb_corr
	_camera_rig.global_position = _camera_rig.global_position.lerp(target_pos, camera_follow_speed * delta)
	
	if _is_fallen:
		var spin: float = PI / 2.0
		_visual.rotation.x = lerpf(_visual.rotation.x, spin, 10.0 * delta)
	else:
		_visual.rotation.x = lerpf(_visual.rotation.x, _vis_pitch, 15.0 * delta)
		_visual.rotation.z = lerpf(_visual.rotation.z, _vis_lean, 15.0 * delta)
	
	_update_wheels(delta)
	_update_items(visual_xf, delta)
	_update_hud()

func _update_wheels(delta: float) -> void:
	for s in _wheel_spins:
		(s as Node3D).rotation.x -= (_speed * delta) / 0.11

func _update_items(visual_xf: Transform3D, delta: float) -> void:
	var vis_pos: Vector3 = visual_xf.origin + _rb_corr
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
	var txt: String = "SPEED: %d km/h" % int(_speed * 3.6)
	if _online and _rb: txt += "\nNET: ROLLBACK" + ("" if _rb_started else " (sync...)")
	if _is_fallen: txt += "\nCRASHED! Recovering..."
	_hud_label.text = txt

# --- Visual Builder Base ---
func _build_visual() -> void:
	_model = Node3D.new()
	_visual.add_child(_model)
	var mesh = MeshInstance3D.new()
	var box = BoxMesh.new()
	box.size = Vector3(1.0, 0.5, 1.5)
	mesh.mesh = box
	_model.add_child(mesh)
	
	var wheel = MeshInstance3D.new()
	var cyl = CylinderMesh.new()
	cyl.top_radius = 0.11
	cyl.bottom_radius = 0.11
	cyl.height = 0.05
	wheel.mesh = cyl
	wheel.rotation_degrees.z = 90
	wheel.position = Vector3(-0.25, 0.11, -0.38)
	_model.add_child(wheel)
	_wheel_spins.append(wheel)
	_build_items()

func _build_items() -> void:
	var root: Node3D = Node3D.new()
	_model.add_child(root)
	var egg_mesh: SphereMesh = SphereMesh.new()
	egg_mesh.radius = 0.05
	egg_mesh.height = 0.1
	var egg_mat: StandardMaterial3D = StandardMaterial3D.new()
	egg_mat.albedo_color = Color(0.9, 0.9, 0.8)
	var egg: MeshInstance3D = MeshInstance3D.new()
	egg.mesh = egg_mesh
	egg.material_override = egg_mat
	egg.position = Vector3(0, 0.3, 0)
	root.add_child(egg)
	_items.append({"node": egg, "rest": Vector3(0, 0.3, 0), "off": Vector3.ZERO, "vel": Vector3.ZERO, "stiff": 200.0, "damp": 10.0, "k": 0.0035, "lim": 0.03})

func _try_load(path: String) -> PackedScene:
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	return load(path) as PackedScene

func _fit_into(node: Node3D, target: float, horizontal: bool, ground_align: bool) -> Vector3:
	var a: AABB = _aabb_of(node)
	if a.size.length() < 0.0001:
		return Vector3.ZERO
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

# --- Networking: Old Mode ---
func _send_snapshot(delta: float, force: bool = false) -> void:
	if not _online or _rb: return
	_snap_timer += delta
	if not force and _snap_timer < snapshot_interval: return
	_snap_timer = 0.0
	var peer: int = _find_peer()
	if peer < 0: return
	_snap_seq_out += 1
	_snap_sent += 1
	if force:
		GDSync.call_func_on(peer, _receive_snapshot, _snap_seq_out, Time.get_ticks_msec(), _teleport_id, global_position, global_rotation)
	else:
		GDSync.call_func_on_unreliable(peer, _receive_snapshot, _snap_seq_out, Time.get_ticks_msec(), _teleport_id, global_position, global_rotation)

func _find_peer() -> int:
	var now_ms: int = Time.get_ticks_msec()
	if _peer_id >= 0 and now_ms - _peer_check_ms < 1000: return _peer_id
	_peer_check_ms = now_ms
	_peer_id = -1
	for id in GDSync.lobby_get_all_clients():
		if id != GDSync.get_client_id():
			_peer_id = id
			break
	return _peer_id

func _receive_snapshot(seq: int, host_ms: int, teleport_id: int, pos: Vector3, rot: Vector3) -> void:
	if GDSync.is_host() or _rb: return
	if seq <= _snap_seq_in: return
	_snap_seq_in = seq
	_last_snap_ms = Time.get_ticks_msec()
	if teleport_id != _teleport_seen:
		_teleport_seen = teleport_id
		global_position = pos
		global_rotation = rot
		reset_physics_interpolation()

func _client_step(delta: float) -> void:
	if _role == ControlRole.GAS_BRAKE:
		_send_drive_input(delta)
	_client_diag(delta)

func _send_drive_input(delta: float) -> void:
	if _rb: return
	var gas: float = snappedf(Input.get_action_strength(&"move_forward"), 0.1)
	var brake: float = snappedf(Input.get_action_strength(&"move_back"), 0.1)
	_hb_timer += delta
	_send_cd = maxf(_send_cd - delta, 0.0)
	var changed: bool = not (is_equal_approx(gas, _last_gas_sent) and is_equal_approx(brake, _last_brake_sent))
	if changed: _repeat_time = 0.4
	_repeat_time = maxf(_repeat_time - delta, 0.0)
	var active: bool = gas > 0.0 or brake > 0.0 or _repeat_time > 0.0
	if _send_cd <= 0.0 and (changed or (active and _hb_timer >= heartbeat)):
		_last_gas_sent = gas
		_last_brake_sent = brake
		_hb_timer = 0.0
		_send_cd = min_send_interval
		_drive_seq += 1
		GDSync.call_func_on_unreliable(GDSync.get_host(), _receive_drive, _drive_seq, gas, brake)

func _receive_drive(seq: int, gas: float, brake: float) -> void:
	if not GDSync.is_host() or _rb: return
	var now_ms: int = Time.get_ticks_msec()
	if now_ms - _last_drive_ms < roundi(min_drive_interval * 1000.0): return
	if seq <= _drive_seq_in: return
	_last_drive_ms = now_ms
	_drive_seq_in = seq
	_remote_gas = clampf(gas, 0.0, 1.0)
	_remote_brake = clampf(brake, 0.0, 1.0)
	_remote_time = float(now_ms) / 1000.0

func _client_diag(delta: float) -> void:
	pass
func _host_diag(delta: float) -> void:
	pass

# --- Rollback System ---
func _rb_setup() -> void:
	if not _online: return
	_dt = 1.0 / float(Engine.physics_ticks_per_second)
	_rb_states.resize(RB_HIST)
	_rb_state_tag.resize(RB_HIST); _rb_state_tag.fill(-1)
	_rb_local.resize(RB_HIST)
	_rb_local_tag.resize(RB_HIST); _rb_local_tag.fill(-1)
	_rb_used.resize(RB_HIST)
	_rb_remote.resize(RB_HIST)
	_rb_remote_tag.resize(RB_HIST); _rb_remote_tag.fill(-1)
	GDSync.expose_func(_rx_inputs, ENUMS.EXPOSE_PERMISSION.ANYONE)
	GDSync.expose_func(_rx_hello, ENUMS.EXPOSE_PERMISSION.ANYONE)
	GDSync.expose_func(_rx_go, ENUMS.EXPOSE_PERMISSION.HOST)
	GDSync.expose_func(_rx_auth, ENUMS.EXPOSE_PERMISSION.HOST)
	GDSync.expose_func(_rx_event, ENUMS.EXPOSE_PERMISSION.HOST)
	_rb_wait_start_ms = Time.get_ticks_msec()
	_rb_in_window_start_ms = _rb_wait_start_ms
	_rb = true
	DebugLog.say("RB", "Rollback (CharacterBody3D) شغال: tick=%.0fHz" % (1.0 / _dt))

func _rb_process(delta: float) -> void:
	if not _rb_started:
		_rb_try_start()
		return
	_rb_check_peer()
	_rb_apply_auth()
	_rb_do_rollback()
	_rb_live_tick()
	_rb_send_inputs()
	_rb_send_auth()
	var k: float = 1.0 - exp(-12.0 * delta)
	_rb_corr = _rb_corr.lerp(Vector3.ZERO, k)
	_rb_corr_rot = _rb_corr_rot.slerp(Quaternion.IDENTITY, k)

func _rb_try_start() -> void:
	var now: int = Time.get_ticks_msec()
	var peer: int = _find_peer()
	if GDSync.is_host():
		if not _rb_go_sent:
			if _rb_peer_hello and peer >= 0:
				GDSync.call_func_on(peer, _rx_go)
				_rb_go_sent = true
				_rb_start_at_ms = now + 100
		elif now >= _rb_start_at_ms:
			_rb_begin()
	else:
		if peer >= 0: GDSync.call_func_on_unreliable(peer, _rx_hello)
		if _rb_got_go: _rb_begin()

func _rb_begin() -> void:
	_rb_started = true
	_tick = 0
	for k in rb_input_delay:
		_rb_local[k % RB_HIST] = Vector4.ZERO
		_rb_local_tag[k % RB_HIST] = k

func _rb_check_peer() -> void:
	if _find_peer() < 0:
		_rb_peer_lost_ms += 1
		if _rb_peer_lost_ms > 180: # ~3 sec
			if _online: GDSync.lobby_leave()
			get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")
	else:
		_rb_had_peer = true
		_rb_peer_lost_ms = 0

func _rx_hello() -> void:
	if GDSync.is_host(): _rb_peer_hello = true
func _rx_go() -> void:
	if not GDSync.is_host(): _rb_got_go = true

func _rb_sample_local() -> Vector4:
	if _role == ControlRole.GAS_BRAKE:
		return Vector4(0.0, 0.0, snappedf(Input.get_action_strength(&"move_forward"), 0.1), snappedf(Input.get_action_strength(&"move_back"), 0.1))
	var steer: float = snappedf(Input.get_axis(&"move_right", &"move_left"), 0.1)
	var jump: float = 1.0 if Input.is_action_just_pressed(&"jump") else 0.0
	if _role == ControlRole.ALL:
		return Vector4(steer, jump, snappedf(Input.get_action_strength(&"move_forward"), 0.1), snappedf(Input.get_action_strength(&"move_back"), 0.1))
	return Vector4(steer, jump, 0.0, 0.0)

func _rb_remote_for(t: int) -> Vector4:
	var idx: int = t % RB_HIST
	if _rb_remote_tag[idx] == t: return _rb_remote[idx]
	if _rb_remote_latest < 0 or t - _rb_remote_latest > rb_remote_timeout_ticks: return Vector4.ZERO
	var v: Vector4 = _rb_remote_last
	if not GDSync.is_host(): v.y = 0.0
	return v

func _rb_live_tick() -> void:
	var t: int = _tick
	var fut: int = t + rb_input_delay
	_rb_local[fut % RB_HIST] = _rb_sample_local()
	_rb_local_tag[fut % RB_HIST] = fut
	_rb_save_state(t)
	_rb_run_tick(t, false)
	_tick += 1

func _rb_run_tick(t: int, resim: bool) -> void:
	_rb_resim = resim
	_rb_sim_time = float(t) * _dt
	var idx: int = t % RB_HIST
	if _rb_events.has(t):
		var ev = _rb_events[t]
		_rb_apply_event(ev[0], ev[1], resim)
		
	var my_inp: Vector4 = _rb_local[idx]
	var rem_inp: Vector4 = _rb_remote_for(t)
	
	var steer: float = 0.0
	var jump: float = 0.0
	var gas: float = 0.0
	var brake: float = 0.0
	
	if GDSync.is_host():
		steer = my_inp.x
		jump = my_inp.y
		gas = rem_inp.z
		brake = rem_inp.w
	else:
		steer = rem_inp.x
		jump = rem_inp.y
		gas = my_inp.z
		brake = my_inp.w
		
	if jump > 0.5: _jump_buffer = 0.15
	_rb_used[idx] = my_inp + rem_inp
	var wants: bool = _control_step(_dt, steer, brake, gas, true)
	if not resim and GDSync.is_host():
		if wants or global_position.y < fall_limit:
			_rb_post_event(t + 1, _spawn_transform.origin, _spawn_transform.basis.get_euler().y)
	_rb_resim = false

func _rb_apply_event(origin: Vector3, yaw: float, resim: bool) -> void:
	_apply_reset_state(Transform3D(Basis(Vector3.UP, yaw), origin))
	if not resim:
		_camera_rig.global_position = origin + Vector3.UP
		_rb_corr = Vector3.ZERO
		_rb_corr_rot = Quaternion.IDENTITY
		reset_physics_interpolation()

func _rb_post_event(t: int, origin: Vector3, yaw: float) -> void:
	_rb_events[t] = [origin, yaw]
	var peer: int = _find_peer()
	if peer >= 0: GDSync.call_func_on(peer, _rx_event, t, origin, yaw)

func _rx_event(t: int, origin: Vector3, yaw: float) -> void:
	if not _rb or GDSync.is_host() or _rb_events.has(t): return
	_rb_events[t] = [origin, yaw]
	if _rb_started and t < _tick: _rb_mark(t)

func _rb_pack() -> PackedFloat64Array:
	return PackedFloat64Array([
		global_position.x, global_position.y, global_position.z,
		global_rotation.x, global_rotation.y, global_rotation.z,
		velocity.x, velocity.y, velocity.z,
		_speed, _yaw, _jump_buffer, _coyote, 1.0 if _is_fallen else 0.0, _fallen_time, 0.0])

func _rb_save_state(t: int) -> void:
	_rb_states[t % RB_HIST] = _rb_pack()
	_rb_state_tag[t % RB_HIST] = t

func _rb_load_state(st: PackedFloat64Array) -> void:
	global_position = Vector3(st[0], st[1], st[2])
	global_rotation = Vector3(st[3], st[4], st[5])
	velocity = Vector3(st[6], st[7], st[8])
	_speed = st[9]
	_yaw = st[10]
	_jump_buffer = st[11]
	_coyote = st[12]
	_is_fallen = st[13] > 0.5
	_fallen_time = st[14]

func _rb_mark(t: int) -> void:
	_rb_from = t if _rb_from < 0 else mini(_rb_from, t)

func _rb_do_rollback() -> void:
	if _rb_from < 0: return
	var from: int = maxi(_rb_from, _tick - rb_max_rollback)
	_rb_from = -1
	if from >= _tick or _rb_state_tag[from % RB_HIST] != from: return
	
	var before: Vector3 = global_position
	var before_q: Quaternion = global_transform.basis.get_rotation_quaternion() 
	
	_rb_load_state(_rb_states[from % RB_HIST])
	for t in range(from, _tick):
		_rb_save_state(t)
		_rb_run_tick(t, true)
		
	var jump_err: Vector3 = before - global_position
	_rb_corr_rot = (_rb_corr_rot * before_q * global_transform.basis.get_rotation_quaternion().inverse()).normalized()
	
	_rb_corr += jump_err
	if _rb_corr.length() > 0.25: _rb_corr = Vector3.ZERO
	_rb_corr.y = maxf(_rb_corr.y, -0.25)
	_rb_stat_rollbacks += 1

func _rb_send_inputs() -> void:
	var t: int = _tick - 1 + rb_input_delay
	if t < 0 or (t - rb_input_delay) % rb_send_every != 0: return
	var peer: int = _find_peer()
	if peer < 0: return
	var first: int = maxi(0, t - rb_send_window + 1)
	var data: PackedFloat32Array = PackedFloat32Array()
	var host: bool = GDSync.is_host()
	for k in range(first, t + 1):
		var v: Vector4 = _rb_local[k % RB_HIST]
		if host: 
			data.append(v.x)
			data.append(v.y)
		else: 
			data.append(v.z)
			data.append(v.w)
	GDSync.call_func_on_unreliable(peer, _rx_inputs, first, data)

func _rx_inputs(first: int, data: PackedFloat32Array) -> void:
	if not _rb or first < 0 or data.size() % 2 != 0: return
	var host: bool = GDSync.is_host()
	for i in data.size() / 2:
		var k: int = first + i
		if k < _tick - RB_HIST + 16 or k > _tick + RB_HIST - 16: continue
		var a: float = data[2 * i]
		var b: float = data[2 * i + 1]
		var idx: int = k % RB_HIST
		if _rb_remote_tag[idx] == k: continue
		var v: Vector4
		if host:
			v = Vector4(0.0, 0.0, clampf(a, 0.0, 1.0), clampf(b, 0.0, 1.0))
		else:
			v = Vector4(clampf(a, -1.0, 1.0), 1.0 if b > 0.5 else 0.0, 0.0, 0.0)
		
		_rb_remote[idx] = v
		_rb_remote_tag[idx] = k
		if k > _rb_remote_latest: 
			_rb_remote_latest = k
			_rb_remote_last = v
		if _rb_started and k < _tick and _rb_local_tag[idx] == k:
			var d: Vector4 = (_rb_local[idx] + v) - _rb_used[idx]
			if absf(d.x) + absf(d.y) + absf(d.z) + absf(d.w) > rb_input_threshold:
				if _tick - _last_rollback_tick >= rb_rollback_cooldown:
					_rb_mark(k)
					_last_rollback_tick = _tick
					
	var guard: int = 0
	while guard < RB_HIST and _rb_remote_tag[(_rb_confirmed + 1) % RB_HIST] == _rb_confirmed + 1:
		_rb_confirmed += 1
		guard += 1

func _rb_send_auth() -> void:
	if not GDSync.is_host() or _tick % rb_auth_every != 0 or _rb_confirmed < 0: return
	var c: int = _rb_confirmed
	if _rb_state_tag[c % RB_HIST] != c: return
	var peer: int = _find_peer()
	if peer >= 0: GDSync.call_func_on_unreliable(peer, _rx_auth, c, _rb_states[c % RB_HIST])

func _rx_auth(t: int, state: PackedFloat64Array) -> void:
	if not _rb or GDSync.is_host() or state.size() != RB_STATE_SIZE: return
	_rb_auth_pending[t] = state

func _rb_apply_auth() -> void:
	for t in _rb_auth_pending.keys():
		if t < _tick and t <= _rb_confirmed:
			var auth: PackedFloat64Array = _rb_auth_pending[t]
			_rb_auth_pending.erase(t)
			var mine: PackedFloat64Array = _rb_states[t % RB_HIST]
			var dp: float = Vector3(auth[0]-mine[0], auth[1]-mine[1], auth[2]-mine[2]).length()
			if dp > rb_auth_tolerance:
				_rb_states[t % RB_HIST] = auth
				_rb_mark(t)
				_rb_stat_corrections += 1
