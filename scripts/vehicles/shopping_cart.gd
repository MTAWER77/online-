extends CharacterBody3D
## scripts/vehicles/shopping_cart.gd
## عربية تسوق Kinematic + Rollback netcode + Logging شامل.

const SessionMode = preload("res://scripts/multiplayer/session_mode.gd")
const DebugLog = preload("res://scripts/systems/debug_log.gd")
const NetClock = preload("res://scripts/multiplayer/net_clock.gd")

enum ControlRole { ALL, STEER_JUMP, GAS_BRAKE }

@export_group("Speed")
@export var max_speed: float = 14.0
@export var acceleration: float = 9.0
@export var brake_decel: float = 22.0
@export var coast_drag: float = 2.0
@export var gravity: float = 15.0
@export var gas_response: float = 8.0
@export var brake_response: float = 12.0

@export_group("Steering")
@export var turn_rate: float = 3.0
@export var steer_response: float = 10.0

@export_group("Jump")
@export var jump_velocity: float = 10.0
@export var coyote_time: float = 0.12
@export var fall_limit: float = -12.0

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
@export var egg_model_path: String = "res://assets/models/egg.glb"
@export var watermelon_model_path: String = "res://assets/models/watermelon.glb"
@export var model_yaw_degrees: float = 0.0

@export_group("Rollback")
@export var rb_send_every: int = 4
@export var rb_send_window: int = 24
@export var rb_max_rollback: int = 60
@export var rb_auth_every: int = 45
@export var rb_auth_tolerance: float = 0.10
@export var rb_remote_timeout_ticks: int = 42
@export var rb_input_delay: int = 4
@export var rb_input_threshold: float = 0.08
@export var rb_rollback_cooldown: int = 1
@export var rb_correction_decay: float = 10.0
@export var rb_corr_max: float = 1.0

@export_group("Hurt")
@export var hurt_cooldown_time: float = 0.4

@export_group("Logging")
@export var log_speed_change: bool = true
@export var log_jump: bool = true
@export var log_crash: bool = true
@export var log_hurt: bool = true
@export var log_respawn: bool = true
@export var log_rollback_events: bool = true
@export var log_auth_corrections: bool = true
@export var log_smart_send: bool = false
@export var log_interval_sec: float = 5.0

@onready var _visual: Node3D = $Visual
@onready var _camera_rig: Node3D = $CameraRig
@onready var _camera: Camera3D = $CameraRig/Camera3D
@onready var _hud_label: Label = $HUD/Label

# ---- Simulation state ----
var _online: bool = false
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

# ---- Hurt ----
var _hurt_cooldown: float = 0.0
var _pending_hurt: bool = false
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

var _peer_id: int = -1
var _peer_check_ms: int = 0

# ---- Smart Send ----
var _last_sent_input: Vector4 = Vector4(-999, -999, -999, -999)
var _input_change_ms: int = 0
const STABLE_HEARTBEAT_TICKS: int = 8

# ---- Rollback ----
const RB_HIST: int = 256
const RB_STATE_SIZE: int = 18

var _rb: bool = false
var _rb_resim: bool = false
var _rb_sim_time: float = 0.0
var _dt: float = 1.0 / 120.0
var _tick: int = 0
var _rb_started: bool = false
var _rb_wait_start_ms: int = 0
var _rb_hello_ms: int = 0
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
var _last_rollback_tick: int = -100
var _rb_stat_rollbacks: int = 0
var _rb_stat_resim_ticks: int = 0
var _rb_stat_corrections: int = 0
var _rb_stat_dropped: int = 0
var _rb_stat_sent: int = 0
var _rb_stat_skipped: int = 0
var _err_sum: float = 0.0
var _err_n: int = 0
var _stats_timer: float = 0.0
var _max_err_this_window: float = 0.0


# =====================================================================
# READY
# =====================================================================
func _ready() -> void:
	add_to_group("unicycle")
	add_to_group("cart")
	NetClock.reset()
	_online = not SessionMode.offline and GDSync.is_active()
	if _online:
		_role = ControlRole.STEER_JUMP if GDSync.is_host() else ControlRole.GAS_BRAKE
	else:
		_role = ControlRole.ALL

	_authoritative = (not _online) or GDSync.is_host()

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

	# [LOG] Startup
	_log_startup()
	_rb_setup()


func _log_startup() -> void:
	var role_str := "ALL (offline)"
	if _role == ControlRole.STEER_JUMP:
		role_str = "HOST (steer+jump)"
	elif _role == ControlRole.GAS_BRAKE:
		role_str = "CLIENT (gas+brake)"
	
	DebugLog.say("INIT", "═══════════════════════════════════════")
	DebugLog.say("INIT", "Shopping Cart Starting")
	DebugLog.say("INIT", "  online=%s" % _online)
	DebugLog.say("INIT", "  authoritative=%s" % _authoritative)
	DebugLog.say("INIT", "  role=%s" % role_str)
	DebugLog.say("INIT", "  spawn=%s" % global_position)
	DebugLog.say("INIT", "  physics_ticks=%d" % Engine.physics_ticks_per_second)
	DebugLog.say("INIT", "═══════════════════════════════════════")


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
		_leave_to_menu()


func _leave_to_menu() -> void:
	DebugLog.say("EXIT", "Leaving to menu")
	if _online:
		GDSync.lobby_leave()
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")


func set_checkpoint(target: Transform3D) -> void:
	_spawn_transform = target
	DebugLog.say("CP", "checkpoint saved → %s" % target.origin)


# =====================================================================
# HURT / RESPAWN API
# =====================================================================
func _hurt(reason: String = "generic", _damage: float = 1.0) -> void:
	if _hurt_cooldown > 0.0:
		return
	_hurt_cooldown = hurt_cooldown_time
	_last_hurt_reason = reason

	if log_hurt:
		DebugLog.say("HURT", "hurt received: %s | online=%s host=%s" % [reason, _online, GDSync.is_host() if _online else true])

	if not _online:
		_respawn("hurt_offline")
		return

	if GDSync.is_host():
		_pending_hurt = true
		if log_hurt:
			DebugLog.say("HURT", "queued pending_hurt (wait for next tick)")
	else:
		if log_hurt:
			DebugLog.say("HURT", "sending RPC to host")
		GDSync.call_func_on(GDSync.get_host(), _rx_hurt_request, reason)


func _respawn(reason: String = "respawn") -> void:
	if log_respawn:
		DebugLog.say("RESPAWN", "→ checkpoint | reason=%s | from=%s" % [reason, global_position])
	_reset_to(_spawn_transform)


func _rx_hurt_request(reason: String) -> void:
	if not _rb or not GDSync.is_host():
		return
	var sender: int = GDSync.get_sender_id()
	if sender >= 0 and sender not in GDSync.lobby_get_all_clients():
		return
	if log_hurt:
		DebugLog.say("HURT", "RPC received from peer %d | reason=%s" % [sender, reason])
	_hurt(reason)


func is_authoritative() -> bool:
	return _authoritative


# =====================================================================
# PHYSICS
# =====================================================================
func _physics_process(delta: float) -> void:
	if _rb:
		_rb_process()
	else:
		_offline_step(delta)


func _control_step(delta: float, steer: float, brake: float, gas: float) -> bool:
	_hurt_cooldown = maxf(_hurt_cooldown - delta, 0.0)
	if _pending_hurt and not _rb_resim:
		_pending_hurt = false
		if log_hurt:
			DebugLog.say("HURT", "pending_hurt resolved → will respawn")
		return true

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

	if _grounded:
		_coyote = coyote_time
	else:
		_coyote = maxf(_coyote - delta, 0.0)
	velocity.y -= gravity * delta

	var speed_frac: float = clampf(absf(_speed) / max_speed, 0.0, 1.0)
	if _is_fallen:
		_speed = 0.0
	elif _brake_smooth > 0.05:
		_speed = move_toward(_speed, 0.0, brake_decel * _brake_smooth * delta)
	elif _gas_smooth > 0.02:
		_speed = move_toward(_speed, max_speed * _gas_smooth, acceleration * delta)
	else:
		_speed = move_toward(_speed, 0.0, coast_drag * delta)

	var turn_factor: float = lerpf(0.5, 1.0, speed_frac)
	_yaw += _steer_smooth * turn_rate * turn_factor * delta
	rotation = Vector3(0.0, _yaw, 0.0)

	var forward: Vector3 = Vector3(-sin(_yaw), 0.0, -cos(_yaw))
	velocity.x = forward.x * _speed
	velocity.z = forward.z * _speed

	if _jump_buffer > 0.0 and _coyote > 0.0 and not _is_fallen:
		velocity.y = jump_velocity
		_jump_buffer = 0.0
		_coyote = 0.0
		if log_jump and not _rb_resim:
			DebugLog.say("JUMP", "jump! | speed=%.1f | pos=%s" % [_speed, global_position])

	var pre_move: Vector3 = Vector3(velocity.x, 0.0, velocity.z)
	move_and_slide()
	_grounded = is_on_floor()

	if is_on_wall():
		var impact: float = 0.0
		for i in get_slide_collision_count():
			var n: Vector3 = get_slide_collision(i).get_normal()
			if absf(n.y) < 0.5:
				impact = maxf(impact, -pre_move.dot(n))
		if not _is_fallen and impact >= crash_speed:
			_crash_left = crash_duration
			_is_fallen = true
			_speed = 0.0
			velocity.x = 0.0
			velocity.z = 0.0
			if log_crash and not _rb_resim:
				DebugLog.say("CRASH", "impact=%.1f m/s (threshold=%.1f) | pos=%s" % [impact, crash_speed, global_position])
		else:
			_speed = clampf(velocity.dot(forward), 0.0, _speed)

	if global_position.y < fall_limit:
		if log_crash and not _rb_resim:
			DebugLog.say("CRASH", "fell below limit y=%.1f < %.1f" % [global_position.y, fall_limit])
		return true
	return false


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


func _offline_step(delta: float) -> void:
	var steer: float = Input.get_axis(&"move_right", &"move_left")
	var gas: float = Input.get_action_strength(&"move_forward")
	var brake: float = Input.get_action_strength(&"move_back")
	if Input.is_action_just_pressed(&"jump"):
		_jump_buffer = 0.15
	if _control_step(delta, steer, brake, gas):
		_respawn("offline_fell_or_hurt")


func _reset_to(target: Transform3D) -> void:
	_apply_reset_state(target)
	_camera_rig.global_position = global_position + Vector3.UP
	_prev_vis_origin = global_position
	_prev_vis_vel = Vector3.ZERO
	_rb_corr = Vector3.ZERO
	_rb_corr_rot = Quaternion.IDENTITY
	reset_physics_interpolation()


func _sim_time() -> float:
	return _rb_sim_time if _rb else NetClock.world_time()


# =====================================================================
# VISUALS
# =====================================================================
func _process(delta: float) -> void:
	if delta <= 0.0:
		return
	var visual_xf: Transform3D = get_global_transform_interpolated()

	var k: float = 1.0 - exp(-rb_correction_decay * delta)
	_rb_corr = _rb_corr.lerp(Vector3.ZERO, k)
	_rb_corr_rot = _rb_corr_rot.slerp(Quaternion.IDENTITY, k)

	_update_visual_pose(delta, visual_xf)
	_update_camera(delta, visual_xf)
	_update_wheels(delta)
	_update_items(visual_xf, delta)
	_update_hud()


func _update_visual_pose(delta: float, visual_xf: Transform3D) -> void:
	var speed_frac: float = clampf(absf(_speed) / max_speed, 0.0, 1.0)
	var lean_k: float = 1.0 - exp(-12.0 * delta)
	_vis_lean = lerpf(_vis_lean, _steer_smooth * max_lean * speed_frac, lean_k)
	_vis_pitch = lerpf(_vis_pitch, (_gas_smooth - _brake_smooth) * pitch_lean, lean_k)
	if _crash_left <= 0.0:
		_crash_side = 1.0 if _vis_lean >= 0.0 else -1.0
	var crash_target: float = 1.0 if _crash_left > 0.0 else 0.0
	_crash_vis = lerpf(_crash_vis, crash_target, 1.0 - exp(-crash_visual_speed * delta))

	var roll: float = lerpf(_vis_lean, _crash_side * PI * 0.5, _crash_vis)
	var pitch: float = lerpf(_vis_pitch, 0.0, _crash_vis)

	var bq: Quaternion = visual_xf.basis.get_rotation_quaternion()
	var corr_local: Quaternion = bq.inverse() * _rb_corr_rot * bq
	_visual.basis = Basis(corr_local) * Basis.from_euler(Vector3(pitch, 0.0, roll))
	_visual.position = visual_xf.basis.transposed() * _rb_corr + Vector3(0.0, crash_lift * _crash_vis, 0.0)


func _update_camera(delta: float, visual_xf: Transform3D) -> void:
	var flat_forward: Vector3 = -visual_xf.basis.z
	flat_forward.y = 0.0
	if flat_forward.length() > 0.4:
		var target_yaw: float = atan2(-flat_forward.x, -flat_forward.z)
		_camera_rig.rotation.y = lerp_angle(_camera_rig.rotation.y, target_yaw, 1.0 - exp(-camera_yaw_speed * delta))
	var target_pos: Vector3 = visual_xf.origin + Vector3.UP + _rb_corr
	_camera_rig.global_position = _camera_rig.global_position.lerp(target_pos, 1.0 - exp(-camera_follow_speed * delta))


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
	var role_text: String
	match _role:
		ControlRole.STEER_JUMP:
			role_text = "YOU: STEER (A/D) + JUMP (Space)"
		ControlRole.GAS_BRAKE:
			role_text = "YOU: GAS (W) + BRAKE (S)"
		_:
			role_text = "OFFLINE: A/D steer, S brake, W gas, Space jump"
	var txt: String = "%s\nSPEED: %d km/h" % [role_text, int(_speed * 3.6)]
	if _online and _rb:
		txt += "\nNET: ROLLBACK" + ("" if _rb_started else " (sync...)")
		txt += "\nTick: %d" % _tick
		if _rb_peer_lost_ms > 0:
			txt += "\nاللاعب التاني خرج - رجوع للقائمة..."
	if _crash_left > 0.0:
		txt += "\nCRASHED! Recovering..."
	_hud_label.text = txt


# =====================================================================
# VISUAL BUILDER
# =====================================================================
func _build_visual() -> void:
	_model = Node3D.new()
	_visual.add_child(_model)
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


# =====================================================================
# ROLLBACK
# =====================================================================
func _rb_setup() -> void:
	if not _online:
		DebugLog.say("RB", "offline mode — no rollback, using _offline_step")
		return
	_dt = 1.0 / float(Engine.physics_ticks_per_second)
	_rb_states.resize(RB_HIST)
	_rb_state_tag.resize(RB_HIST)
	_rb_state_tag.fill(-1)
	_rb_local.resize(RB_HIST)
	_rb_local_tag.resize(RB_HIST)
	_rb_local_tag.fill(-1)
	_rb_used.resize(RB_HIST)
	_rb_remote.resize(RB_HIST)
	_rb_remote_tag.resize(RB_HIST)
	_rb_remote_tag.fill(-1)
	GDSync.expose_func(_rx_inputs, ENUMS.EXPOSE_PERMISSION.ANYONE)
	GDSync.expose_func(_rx_hello, ENUMS.EXPOSE_PERMISSION.ANYONE)
	GDSync.expose_func(_rx_go, ENUMS.EXPOSE_PERMISSION.HOST)
	GDSync.expose_func(_rx_auth, ENUMS.EXPOSE_PERMISSION.HOST)
	GDSync.expose_func(_rx_event, ENUMS.EXPOSE_PERMISSION.HOST)
	GDSync.expose_func(_rx_hurt_request, ENUMS.EXPOSE_PERMISSION.CLIENT)
	_rb_wait_start_ms = Time.get_ticks_msec()
	_rb_in_window_start_ms = _rb_wait_start_ms
	_rb = true
	DebugLog.say("RB", "setup complete | tick_rate=%.0fHz | role=%d | input_delay=%d | max_rollback=%d" % [
		1.0 / _dt, _role, rb_input_delay, rb_max_rollback])
	DebugLog.say("RB", "config: send_every=%d send_window=%d auth_every=%d auth_tol=%.3f cooldown=%d" % [
		rb_send_every, rb_send_window, rb_auth_every, rb_auth_tolerance, rb_rollback_cooldown])


func _rb_process() -> void:
	if not _rb_started:
		_rb_try_start()
		return
	_rb_check_peer()
	_rb_apply_auth()
	_rb_do_rollback()
	_rb_live_tick()
	_rb_send_inputs()
	_rb_send_auth()
	_rb_log_stats()


func _rb_try_start() -> void:
	var now: int = Time.get_ticks_msec()
	var peer: int = _find_peer()
	if GDSync.is_host():
		if not _rb_go_sent:
			if _rb_peer_hello and peer >= 0:
				GDSync.call_func_on(peer, _rx_go)
				_rb_go_sent = true
				_rb_start_at_ms = now + roundi(clampf(SessionMode.last_ping_ms, 0.0, 600.0) * 0.5)
				DebugLog.say("RB", "sent GO to peer %d | start in %dms (ping=%.0fms)" % [
					peer, _rb_start_at_ms - now, SessionMode.last_ping_ms])
			elif now - _rb_wait_start_ms > 8000:
				_rb_go_sent = true
				_rb_start_at_ms = now
				DebugLog.say("RB", "no peer hello after 8s — starting alone")
		if _rb_go_sent and now >= _rb_start_at_ms:
			_rb_begin()
	else:
		if peer >= 0 and now - _rb_hello_ms > 250:
			_rb_hello_ms = now
			GDSync.call_func_on_unreliable(peer, _rx_hello)
		if _rb_got_go:
			_rb_begin()
		elif now - _rb_wait_start_ms > 15000:
			DebugLog.say("RB", "timeout waiting for GO (15s) — starting anyway")
			_rb_begin()


func _rb_begin() -> void:
	_rb_started = true
	_tick = 0
	for k in rb_input_delay:
		_rb_local[k % RB_HIST] = Vector4.ZERO
		_rb_local_tag[k % RB_HIST] = k
	DebugLog.say("RB", "════ SIMULATION STARTED ════")
	DebugLog.say("RB", "  tick=0 | role=%d | authoritative=%s" % [_role, _authoritative])


func _rb_sender_ok() -> bool:
	var sender: int = GDSync.get_sender_id()
	return sender < 0 or sender == GDSync.get_client_id() or sender in GDSync.lobby_get_all_clients()


func _rb_check_peer() -> void:
	var now: int = Time.get_ticks_msec()
	if _find_peer() >= 0:
		if not _rb_had_peer:
			DebugLog.say("NET", "peer found")
		_rb_had_peer = true
		_rb_peer_lost_ms = 0
		return
	if not _rb_had_peer:
		return
	if _rb_peer_lost_ms == 0:
		_rb_peer_lost_ms = now
		DebugLog.say("NET", "peer LOST — waiting 3s before leaving")
	elif now - _rb_peer_lost_ms > 3000:
		DebugLog.say("NET", "peer lost > 3s — leaving to menu")
		_leave_to_menu()


func _find_peer() -> int:
	var now_ms: int = Time.get_ticks_msec()
	if _peer_id >= 0 and now_ms - _peer_check_ms < 1000:
		return _peer_id
	_peer_check_ms = now_ms
	_peer_id = -1
	var my_id: int = GDSync.get_client_id()
	for id: int in GDSync.lobby_get_all_clients():
		if id != my_id:
			_peer_id = id
			break
	return _peer_id


func _rx_hello() -> void:
	if not _rb_sender_ok():
		return
	if GDSync.is_host():
		_rb_peer_hello = true
		DebugLog.say("NET", "received HELLO from client")


func _rx_go() -> void:
	if not GDSync.is_host():
		_rb_got_go = true
		DebugLog.say("NET", "received GO from host — will begin")


func _q(v: float) -> float:
	return snappedf(v, 0.1)


func _rb_sample_local() -> Vector4:
	if _role == ControlRole.GAS_BRAKE:
		return Vector4(0.0, 0.0, _q(Input.get_action_strength(&"move_forward")), _q(Input.get_action_strength(&"move_back")))
	var steer: float = _q(Input.get_axis(&"move_right", &"move_left"))
	var jump: float = 1.0 if Input.is_action_just_pressed(&"jump") else 0.0
	return Vector4(steer, jump, 0.0, 0.0)


func _rb_remote_for(t: int) -> Vector4:
	var idx: int = t % RB_HIST
	if _rb_remote_tag[idx] == t:
		return _rb_remote[idx]
	if _rb_remote_latest < 0 or t - _rb_remote_latest > rb_remote_timeout_ticks:
		return Vector4.ZERO
	var v: Vector4 = _rb_remote_last
	if not GDSync.is_host():
		v.y = 0.0
	return v


func _rb_live_tick() -> void:
	var t: int = _tick
	var fut: int = t + rb_input_delay
	_rb_local[fut % RB_HIST] = _rb_sample_local()
	_rb_local_tag[fut % RB_HIST] = fut
	_rb_save_state(t)
	_rb_run_tick(t, false)
	_tick += 1
	if t % 120 == 0:
		for k: int in _rb_events.keys():
			if k < _tick - RB_HIST:
				_rb_events.erase(k)


func _rb_run_tick(t: int, resim: bool) -> void:
	_rb_resim = resim
	_rb_sim_time = float(t) * _dt
	var idx: int = t % RB_HIST
	if _rb_events.has(t):
		var ev: Array = _rb_events[t]
		_rb_apply_event(ev[0] as Vector3, ev[1] as float, resim)

	var my_inp: Vector4 = _rb_local[idx] if _rb_local_tag[idx] == t else Vector4.ZERO
	var rem_inp: Vector4 = _rb_remote_for(t)
	_rb_used[idx] = my_inp + rem_inp

	var steer: float
	var jump: float
	var gas: float
	var brake: float
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
	if jump > 0.5:
		_jump_buffer = 0.15

	var fell: bool = _control_step(_dt, steer, brake, gas)
	if fell and not resim and GDSync.is_host():
		_rb_post_event(t + 1, _spawn_transform.origin, _spawn_transform.basis.get_euler().y)
	_rb_resim = false


func _rb_apply_event(origin: Vector3, yaw: float, resim: bool) -> void:
	_apply_reset_state(Transform3D(Basis(Vector3.UP, yaw), origin))
	if not resim:
		_camera_rig.global_position = origin + Vector3.UP
		_rb_corr = Vector3.ZERO
		_rb_corr_rot = Quaternion.IDENTITY
		reset_physics_interpolation()
		if log_respawn:
			DebugLog.say("RESPAWN", "event applied @ tick %d | → %s" % [_tick, origin])


func _rb_post_event(t: int, origin: Vector3, yaw: float) -> void:
	_rb_events[t] = [origin, yaw]
	if log_respawn:
		DebugLog.say("RESPAWN", "event posted @ tick %d | will apply at tick %d | → %s" % [_tick, t, origin])
	var peer: int = _find_peer()
	if peer >= 0:
		GDSync.call_func_on(peer, _rx_event, t, origin, yaw)


func _rx_event(t: int, origin: Vector3, yaw: float) -> void:
	if not _rb or GDSync.is_host() or t < 0 or not origin.is_finite() or not is_finite(yaw):
		return
	if _rb_events.has(t):
		return
	_rb_events[t] = [origin, yaw]
	if log_respawn:
		DebugLog.say("RESPAWN", "event received @ tick %d (current=%d) | → %s" % [t, _tick, origin])
	if _rb_started and t < _tick:
		_rb_mark(t)


func _rb_pack() -> PackedFloat64Array:
	var r: Vector3 = global_rotation
	return PackedFloat64Array([
		global_position.x, global_position.y, global_position.z,
		r.x, r.y, r.z,
		velocity.x, velocity.y, velocity.z,
		_speed, _yaw, _jump_buffer, _coyote, _crash_left,
		_gas_smooth, _brake_smooth, _steer_smooth, 1.0 if _grounded else 0.0])


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
	_crash_left = st[13]
	_gas_smooth = st[14]
	_brake_smooth = st[15]
	_steer_smooth = st[16]
	_grounded = st[17] > 0.5
	_is_fallen = _crash_left > 0.0


func _rb_mark(t: int) -> void:
	_rb_from = t if _rb_from < 0 else mini(_rb_from, t)


func _rb_do_rollback() -> void:
	if _rb_from < 0:
		return
	if _tick - _last_rollback_tick < rb_rollback_cooldown:
		return
	var from: int = maxi(_rb_from, _tick - rb_max_rollback)
	_rb_from = -1
	if from >= _tick or from < 0 or _rb_state_tag[from % RB_HIST] != from:
		return
	_last_rollback_tick = _tick

	var before_pos: Vector3 = global_position
	var before_q: Quaternion = global_transform.basis.get_rotation_quaternion()
	var depth: int = _tick - from
	_rb_load_state(_rb_states[from % RB_HIST] as PackedFloat64Array)
	for t in range(from, _tick):
		_rb_save_state(t)
		_rb_run_tick(t, true)

	reset_physics_interpolation()

	var jump_err: Vector3 = before_pos - global_position
	var after_q: Quaternion = global_transform.basis.get_rotation_quaternion()
	_rb_corr_rot = (_rb_corr_rot * before_q * after_q.inverse()).normalized()
	_rb_corr += jump_err
	if _rb_corr.length() > rb_corr_max:
		_rb_corr = Vector3.ZERO
		_rb_corr_rot = Quaternion.IDENTITY
		reset_physics_interpolation()
	_rb_corr.y = maxf(_rb_corr.y, -0.25)
	_rb_stat_rollbacks += 1
	_rb_stat_resim_ticks += depth

	if log_rollback_events and (jump_err.length() > 0.05 or depth > 15):
		DebugLog.say("ROLLBACK", "depth=%d ticks | err=%.3fm | corr=%.3fm | pos_before=%s pos_after=%s" % [
			depth, jump_err.length(), _rb_corr.length(), before_pos, global_position])


func _rb_send_inputs() -> void:
	var t: int = _tick - 1 + rb_input_delay
	if t < 0:
		return

	var cur: Vector4 = _rb_local[t % RB_HIST]
	var now_ms: int = Time.get_ticks_msec()
	var input_changed: bool = not cur.is_equal_approx(_last_sent_input)

	if input_changed:
		_input_change_ms = now_ms
		_last_sent_input = cur
	else:
		var since_change: int = now_ms - _input_change_ms
		var interval: int = rb_send_every if since_change < 200 else STABLE_HEARTBEAT_TICKS
		if (t - rb_input_delay) % interval != 0:
			_rb_stat_skipped += 1
			if log_smart_send and _rb_stat_skipped % 30 == 0:
				DebugLog.say("SEND", "skipped stable tick | total_skipped=%d" % _rb_stat_skipped)
			return

	var peer: int = _find_peer()
	if peer < 0:
		return
	var first: int = t
	if input_changed or (now_ms - _input_change_ms) < 200:
		first = maxi(0, t - rb_send_window + 1)

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
	_rb_stat_sent += 1
	if log_smart_send and input_changed:
		DebugLog.say("SEND", "input changed → sent range [%d..%d] (%d ticks)" % [first, t, t - first + 1])
	GDSync.call_func_on_unreliable(peer, _rx_inputs, first, data)


func _rb_rate_ok() -> bool:
	var now: int = Time.get_ticks_msec()
	if now - _rb_in_window_start_ms >= 1000:
		_rb_in_window_start_ms = now
		_rb_in_count = 0
	_rb_in_count += 1
	if _rb_in_count > 80:
		_rb_stat_dropped += 1
		if _rb_stat_dropped == 1 or _rb_stat_dropped % 50 == 0:
			DebugLog.say("NET", "WARN rate limit exceeded | dropped=%d" % _rb_stat_dropped)
		return false
	return true


func _rx_inputs(first: int, data: PackedFloat32Array) -> void:
	if not _rb or not _rb_sender_ok() or not _rb_rate_ok():
		return
	if first < 0 or data.size() < 2 or data.size() > 128 or data.size() % 2 != 0:
		return
	var host: bool = GDSync.is_host()
	var marks: int = 0
	for i in data.size() / 2:
		var k: int = first + i
		if k < _tick - RB_HIST + 16 or k > _tick + RB_HIST - 16:
			continue
		var a: float = data[2 * i]
		var b: float = data[2 * i + 1]
		if not is_finite(a) or not is_finite(b):
			continue
		var idx: int = k % RB_HIST
		if _rb_remote_tag[idx] == k:
			continue
		var v: Vector4
		if host:
			v = Vector4(0.0, 0.0, _q(clampf(a, 0.0, 1.0)), _q(clampf(b, 0.0, 1.0)))
		else:
			v = Vector4(_q(clampf(a, -1.0, 1.0)), 1.0 if b > 0.5 else 0.0, 0.0, 0.0)
		_rb_remote[idx] = v
		_rb_remote_tag[idx] = k
		if k > _rb_remote_latest:
			_rb_remote_latest = k
			_rb_remote_last = v
		if _rb_started and k < _tick and _rb_local_tag[idx] == k:
			var d: Vector4 = (_rb_local[idx] + v) - _rb_used[idx]
			if absf(d.x) + absf(d.y) + absf(d.z) + absf(d.w) > rb_input_threshold:
				_rb_mark(k)
				marks += 1
	if marks > 0 and log_rollback_events and marks >= 3:
		DebugLog.say("INPUTS", "received %d ticks | caused %d rollback marks" % [data.size() / 2, marks])
	var guard: int = 0
	while guard < RB_HIST and _rb_remote_tag[(_rb_confirmed + 1) % RB_HIST] == _rb_confirmed + 1:
		_rb_confirmed += 1
		guard += 1


func _rb_send_auth() -> void:
	if not GDSync.is_host() or _tick % rb_auth_every != 0 or _rb_confirmed < 0:
		return
	var c: int = _rb_confirmed
	if _rb_state_tag[c % RB_HIST] != c or _tick - c > RB_HIST - 8:
		return
	var peer: int = _find_peer()
	if peer >= 0:
		GDSync.call_func_on_unreliable(peer, _rx_auth, c, _rb_states[c % RB_HIST])


func _rx_auth(t: int, state: PackedFloat64Array) -> void:
	if not _rb or GDSync.is_host() or t < 0 or state.size() != RB_STATE_SIZE:
		return
	for v in state:
		if not is_finite(v):
			return
	_rb_auth_pending[t] = state


func _rb_apply_auth() -> void:
	if _rb_auth_pending.is_empty():
		return
	var keys: Array = _rb_auth_pending.keys()
	keys.sort()
	for t: int in keys:
		if t >= _tick:
			continue
		if _tick - t > rb_max_rollback or _rb_state_tag[t % RB_HIST] != t:
			_rb_auth_pending.erase(t)
			continue
		if t > _rb_confirmed:
			continue
		var auth: PackedFloat64Array = _rb_auth_pending[t]
		_rb_auth_pending.erase(t)
		var mine: PackedFloat64Array = _rb_states[t % RB_HIST]
		var dp: float = Vector3(auth[0] - mine[0], auth[1] - mine[1], auth[2] - mine[2]).length()
		var dv: float = Vector3(auth[6] - mine[6], auth[7] - mine[7], auth[8] - mine[8]).length()
		var ds: float = absf(auth[9] - mine[9])
		_err_sum += dp
		_err_n += 1
		if dp > _max_err_this_window:
			_max_err_this_window = dp
		if log_auth_corrections and dp > 0.20:
			DebugLog.say("AUTH", "correction @ tick %d | pos_err=%.3fm vel_err=%.2f speed_err=%.2f" % [
				t, dp, dv, ds])
		if dp > rb_auth_tolerance or dv > 0.5 or ds > 0.5 or absf(auth[13] - mine[13]) > 0.2:
			_rb_states[t % RB_HIST] = auth
			_rb_mark(t)
			_rb_stat_corrections += 1


func _rb_log_stats() -> void:
	_stats_timer += _dt
	if _stats_timer < log_interval_sec:
		return
	
	var avg_err: float = _err_sum / maxf(float(_err_n), 1.0)
	var avg_depth: float = float(_rb_stat_resim_ticks) / maxf(float(_rb_stat_rollbacks), 1.0)
	var input_lag: int = _tick - _rb_remote_latest
	var sent_per_sec: float = _rb_stat_sent / _stats_timer
	var skipped_per_sec: float = _rb_stat_skipped / _stats_timer
	
	# تقييم الحالة
	var status: String = "OK"
	if _rb_stat_rollbacks > 10:
		status = "HIGH ROLLBACKS"
	if avg_err > 0.1:
		status = "HIGH ERROR"
	if _max_err_this_window > 0.5:
		status = "LARGE CORRECTION"
	if input_lag > 30:
		status = "INPUT LAG"
	
	DebugLog.say("STATS", "═══ tick=%d [%s] ═══" % [_tick, status])
	DebugLog.say("STATS", "  rollbacks: %.1f/s | depth: %.1f ticks" % [
		_rb_stat_rollbacks / _stats_timer, avg_depth])
	DebugLog.say("STATS", "  corrections: %d | avg_err: %.3fm | max_err: %.3fm" % [
		_rb_stat_corrections, avg_err, _max_err_this_window])
	DebugLog.say("STATS", "  inputs: sent=%.1f/s skipped=%.1f/s | input_lag=%d ticks" % [
		sent_per_sec, skipped_per_sec, input_lag])
	DebugLog.say("STATS", "  pos=%s | speed=%.1f | tick=%d" % [global_position, _speed, _tick])
	
	_stats_timer = 0.0
	_rb_stat_rollbacks = 0
	_rb_stat_resim_ticks = 0
	_rb_stat_corrections = 0
	_rb_stat_dropped = 0
	_rb_stat_sent = 0
	_rb_stat_skipped = 0
	_err_sum = 0.0
	_err_n = 0
	_max_err_this_window = 0.0
