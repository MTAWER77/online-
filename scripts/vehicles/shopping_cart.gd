extends RigidBody3D
## scripts/vehicles/shopping_cart.gd
## عربية تسوق بفيزيكس (RigidBody3D / Jolt) بلاعبين:
##   الـ host   = دركسيون (A/D) + قفز (Space)
##   الـ client = بنزين (W) + فرامل (S)
##   أوفلاين   = لاعب واحد بيتحكم في كله.
##
## المزامنة (سلطة واحدة):
##  - الـ host هو المرجع الوحيد للفيزيكس. الـ client بيبعت بنزين/فرامل بس (رقم تسلسلي + تحقق + مهلة).
##  - الـ host بيبعت snapshots (مكان/دوران/سرعة) ~30/ث، وبيسكت لو العربية واقفة (keep-alive كل نص ثانية).
##  - الـ client ما بيحاكيش فيزيكس: بيحتفظ بـ buffer من الـ snapshots وبيعرض العربية متأخرة شوية (interp_delay)
##    بـ Hermite interpolation، فالحركة ناعمة حتى مع جيتر. الـ delay بيتظبط لوحده حسب جيتر النت (NetClock).
##  - البلاتفورمات المتحركة بتستخدم نفس الساعة (NetClock)، فالعربية ما بتغطسش جواها عند الـ client.
## الفيزيكس: عربية بـ 4 عجلات (rays) + سلة. سرعة أركيد على سطح الأرض (بنزين/فرامل/انزلاق جانبي)
## + جاذبية المنحدر + ميلان في اللفات + قلب وإعادة وقوف + قفز بـ coyote time.

const SessionMode = preload("res://scripts/multiplayer/session_mode.gd")
const DebugLog = preload("res://scripts/systems/debug_log.gd")
const NetClock = preload("res://scripts/multiplayer/net_clock.gd")

enum ControlRole { ALL, STEER_JUMP, GAS_BRAKE }

const WHEEL_R: float = 0.11
const WHEEL_POS: Array = [ # أول اتنين = العجلات الأمامية (الأمام = -Z)
	Vector3(-0.25, 0.11, -0.38), Vector3(0.25, 0.11, -0.38),
	Vector3(-0.25, 0.11, 0.38), Vector3(0.25, 0.11, 0.38)]
const JUMP_BUFFER: float = 0.15

@export_group("Speed")
@export var max_speed: float = 14.0
@export var acceleration: float = 9.0
@export var brake_decel: float = 22.0
@export var coast_drag: float = 0.8 # العربية بتفضل ماشية لوحدها (عجل حقيقي)
@export var slope_gravity: float = 0.9 # العربية بتنزل المنحدر لوحدها (أعلى = أسرع)
@export var allow_reverse: bool = false # لو شغّلتها: الفرامل بعد الوقوف بترجّع لورا ببطء
@export var reverse_speed: float = 2.5
@export var reverse_accel: float = 4.0
@export var gas_response: float = 6.0 # سرعة وصول البنزين للقيمة (بيخبّي تأخر الشبكة كتسارع ناعم)
@export var brake_response: float = 12.0

@export_group("Steering")
@export var turn_rate: float = 2.6 # راديان/ثانية
@export var steer_response: float = 8.0
@export var yaw_response: float = 10.0
@export var grip: float = 5.0 # أقل = العربية بتزحلق على جنبها أكتر (دريفت)

@export_group("Body")
@export var roll_lean: float = 0.012 # ميلان العربية للخارج في اللفات
@export var pitch_lean: float = 0.010 # الدخول لقدام مع الفرامل ولورا مع البنزين
@export var max_lean: float = 0.22
@export var lean_kp: float = 55.0
@export var lean_kd: float = 9.0
@export var air_level_kp: float = 8.0 # تعديل الوضع في الهوا (عشان تنزل على عجلاتها)
@export var fall_tilt_degrees: float = 70.0 # بعد الميل ده العربية اتقلبت
@export var recover_time: float = 1.0 # بترجع واقفة بعد ما تفضل مقلوبة المدة دي على الأرض

@export_group("Jump")
@export var jump_velocity: float = 8.5
@export var coyote_time: float = 0.12
@export var fall_limit: float = -12.0 # تحت الرقم ده نرجّع العربية لآخر checkpoint

@export_group("Network")
@export var snapshot_interval: float = 0.033 # الـ host بيبعت حالة العربية (~30/ث)
@export var interp_delay: float = 0.10 # أقل تأخير عرض عند الـ client (بيزيد تلقائي مع الجيتر)
@export var max_extrapolation: float = 0.15 # أقصى مدة بنتنبأ فيها لو الـ snapshots اتأخرت
@export var teleport_distance: float = 6.0 # فرق أكبر من كده بين snapshotين = نقل فوري (respawn)
@export var heartbeat: float = 0.1 # الـ client بيكرر البنزين/الفرامل كل كام ثانية طول ما ضاغط
@export var min_send_interval: float = 0.04
@export var input_timeout: float = 0.4 # لو مدخلات الـ client وقفت نصفّرها (عشان ما تعلقش)
@export var min_drive_interval: float = 0.015 # الـ host يتجاهل أسرع من كده (حماية)

@export_group("Visual")
@export var cart_model_path: String = "res://assets/models/shopping_cart.glb"
@export var egg_model_path: String = "res://assets/models/egg.glb"
@export var watermelon_model_path: String = "res://assets/models/watermelon.glb"
@export var model_yaw_degrees: float = 0.0 # لو موديل العربية ماشي بضهره غيّرها لـ 180 أو 90
@export var camera_follow_speed: float = 30.0
@export var camera_yaw_speed: float = 4.0

@onready var _visual: Node3D = $Visual
@onready var _camera_rig: Node3D = $CameraRig
@onready var _camera: Camera3D = $CameraRig/Camera3D
@onready var _hud_label: Label = $HUD/Label


class Snap:
	var t: float = 0.0
	var pos: Vector3 = Vector3.ZERO
	var rot: Quaternion = Quaternion.IDENTITY
	var vel: Vector3 = Vector3.ZERO
	var steer: float = 0.0


var _online: bool = false
var _authoritative: bool = true # الجهاز ده بيحاكي الفيزيكس (الـ host أو أوفلاين)
var _role: int = ControlRole.ALL
var _g: float = 9.8

# ---- محاكاة (host) ----
var _jump_buffer: float = 0.0
var _coyote: float = 0.0
var _gas_smooth: float = 0.0
var _brake_smooth: float = 0.0
var _steer_smooth: float = 0.0
var _no_ground_timer: float = 0.0 # بعد القفز/القفازة نتجاهل الأرض لحظة
var _fallen_time: float = 0.0
var _is_fallen: bool = false
var _heading: Vector3 = Vector3.FORWARD
var _spawn_transform: Transform3D
var _last_vf: float = 0.0
var _fwd_acc: float = 0.0

# ---- شبكة: host ----
var _snap_timer: float = 0.0
var _snap_seq_out: int = 0
var _teleport_id: int = 0 # بيزيد مع كل respawn / recover عشان الـ client ينقل فورًا
var _peer_id: int = -1
var _peer_check_ms: int = 0
var _net_steer: float = 0.0
var _last_sent_pos: Vector3 = Vector3(1.0e9, 0.0, 0.0)
var _last_sent_steer: float = 0.0
var _idle_acc: float = 0.0
var _snap_sent: int = 0
var _remote_gas: float = 0.0
var _remote_brake: float = 0.0
var _remote_time: float = -100.0
var _drive_seq_in: int = -1
var _last_drive_ms: int = -1000000
var _dropped_rpc: int = 0
var _input_timed_out: bool = false

# ---- شبكة: client ----
var _buf: Array = []
var _snap_seq_in: int = -1
var _teleport_seen: int = 0
var _teleport_pending: bool = false
var _snap_count: int = 0
var _underruns: int = 0
var _teleports: int = 0
var _last_snap_ms: int = 0
var _delay_smooth: float = 0.1
var _drive_seq: int = 0
var _last_gas_sent: float = -1.0
var _last_brake_sent: float = -1.0
var _hb_timer: float = 0.0
var _send_cd: float = 0.0
var _repeat_time: float = 0.0
var _diag_timer: float = 0.0

# ---- شكل ----
var _model: Node3D
var _wheel_spins: Array = []
var _front_pivots: Array = []
var _items: Array = []
var _last_pos: Vector3
var _vis_speed: float = 0.0
var _cam_yaw: float = 0.0
var _wheel_angle: float = 0.0
var _steer_vis: float = 0.0
var _prev_vis_origin: Vector3
var _prev_vis_vel: Vector3 = Vector3.ZERO
var _acc_smooth: Vector3 = Vector3.ZERO


func _ready() -> void:
	add_to_group("unicycle") # الاسم القديم محفوظ عشان level / checkpoint / finish يفضلوا شغالين
	NetClock.reset()
	_g = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	_online = not SessionMode.offline and GDSync.is_active()
	_authoritative = (not _online) or GDSync.is_host()
	if not _online:
		_role = ControlRole.ALL
	else:
		_role = ControlRole.STEER_JUMP if GDSync.is_host() else ControlRole.GAS_BRAKE
		GDSync.expose_func(_receive_drive, ENUMS.EXPOSE_PERMISSION.CLIENT)
		GDSync.expose_func(_receive_snapshot, ENUMS.EXPOSE_PERMISSION.HOST)

	if not _authoritative:
		# عند الـ client: مفيش فيزيكس، العربية بتتعرض من الـ snapshots
		freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		freeze = true

	_ensure_input_actions()
	_build_visual()
	_spawn_transform = global_transform
	_last_pos = global_position
	_prev_vis_origin = global_position
	_cam_yaw = global_rotation.y
	var flat: Vector3 = -global_transform.basis.z
	flat.y = 0.0
	if flat.length() > 0.1:
		_heading = flat.normalized()

	_camera_rig.top_level = true
	_camera_rig.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_camera_rig.global_position = global_position + Vector3.UP
	_camera_rig.rotation = Vector3(0.0, _cam_yaw, 0.0)
	_camera.make_current()
	DebugLog.say("CART", "online=%s authoritative=%s role=%d pos=%s" % [_online, _authoritative, _role, global_position])


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
	if _online:
		GDSync.lobby_leave()
	get_tree().change_scene_to_file("res://scenes/ui/main_menu.tscn")


# ======================================================================
# الفيزيكس (الـ host / أوفلاين)
# ======================================================================
func _physics_process(delta: float) -> void:
	_update_motion_visuals(delta)
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
			steer = Input.get_axis(&"move_right", &"move_left") # شمال = موجب
			gas = Input.get_action_strength(&"move_forward")
			brake = Input.get_action_strength(&"move_back")
			if Input.is_action_just_pressed(&"jump"):
				_jump_buffer = JUMP_BUFFER
		ControlRole.STEER_JUMP:
			steer = Input.get_axis(&"move_right", &"move_left")
			if Input.is_action_just_pressed(&"jump"):
				_jump_buffer = JUMP_BUFFER
			var now: float = Time.get_ticks_msec() / 1000.0
			var age: float = now - _remote_time
			if age <= input_timeout:
				gas = _remote_gas
				brake = _remote_brake
				_input_timed_out = false
			elif not _input_timed_out and (_remote_gas > 0.0 or _remote_brake > 0.0):
				_input_timed_out = true # مدخلات اللاعب التاني وقفت (النت وقع أو سابها)
				DebugLog.say("NET", "مدخلات الـ client وقفت من %.2fs" % age)
		_:
			pass
	_control_step(delta, steer, brake, gas)
	_send_snapshot(delta)
	_host_diag(delta)


func _control_step(delta: float, steer: float, brake: float, gas: float) -> void:
	_gas_smooth = move_toward(_gas_smooth, gas, gas_response * delta)
	_brake_smooth = move_toward(_brake_smooth, brake, brake_response * delta)
	_steer_smooth = move_toward(_steer_smooth, steer, steer_response * delta)
	_net_steer = _steer_smooth
	_jump_buffer = maxf(_jump_buffer - delta, 0.0)
	_no_ground_timer = maxf(_no_ground_timer - delta, 0.0)

	var xf: Transform3D = global_transform
	var up: Vector3 = xf.basis.y
	var tilt: float = acos(clampf(up.dot(Vector3.UP), -1.0, 1.0))
	var was_fallen: bool = _is_fallen
	_is_fallen = tilt > deg_to_rad(fall_tilt_degrees)
	if _is_fallen and not was_fallen:
		DebugLog.say("CART", "اتقلبت (tilt=%d°)" % roundi(rad_to_deg(tilt)))

	if global_position.y < fall_limit:
		_respawn()
		return
	if _is_fallen:
		if _near_ground():
			_fallen_time += delta
			if _fallen_time >= recover_time:
				_recover()
		return # مقلوبة: الفيزيكس تشتغل لوحدها
	_fallen_time = 0.0

	var gr: Dictionary = _probe_wheels(0.14)
	var count: int = gr["count"]
	var grounded: bool = count >= 2 and _no_ground_timer <= 0.0
	if grounded:
		_coyote = coyote_time
	else:
		_coyote = maxf(_coyote - delta, 0.0)

	var flat: Vector3 = -xf.basis.z
	flat.y = 0.0
	if flat.length() > 0.25:
		_heading = flat.normalized()

	var lv: Vector3 = linear_velocity
	var av: Vector3 = angular_velocity

	if grounded:
		var n: Vector3 = gr["normal"]
		var plat: Vector3 = gr["vel"] # سرعة البلاتفورم اللي واقفين عليها (لو بتتحرك)
		var fwd_g: Vector3 = (_heading - n * _heading.dot(n)).normalized()
		var right_g: Vector3 = fwd_g.cross(n).normalized()
		var rel: Vector3 = lv - plat
		var vf: float = rel.dot(fwd_g)
		var vl: float = rel.dot(right_g)
		var speed_frac: float = clampf(absf(vf) / max_speed, 0.0, 1.0)

		# جاذبية المنحدر: العربية بتنزل لوحدها وبتبطّأ وهي طالعة
		vf += -fwd_g.y * _g * gravity_scale * slope_gravity * delta

		if _brake_smooth > 0.05:
			if vf > 0.4:
				vf = move_toward(vf, 0.0, brake_decel * _brake_smooth * delta)
			elif allow_reverse:
				vf = move_toward(vf, -reverse_speed, reverse_accel * _brake_smooth * delta)
			else:
				vf = move_toward(vf, 0.0, brake_decel * delta)
		elif _gas_smooth > 0.02:
			var acc: float = acceleration * (2.0 if vf < 0.0 else 1.0)
			if vf < max_speed:
				vf = minf(vf + acc * _gas_smooth * delta, max_speed)
		else:
			vf = move_toward(vf, 0.0, coast_drag * delta)
		vf = clampf(vf, -reverse_speed * 2.0, max_speed * 1.6)

		vl *= maxf(0.0, 1.0 - grip * delta) # انزلاق جانبي (دريفت)
		lv = plat + fwd_g * vf + right_g * vl

		if _jump_buffer > 0.0:
			lv += n * jump_velocity
			_jump_buffer = 0.0
			_no_ground_timer = 0.25
			_coyote = 0.0
			DebugLog.say("CART", "jump (speed=%.1f)" % vf)

		# دوران: بطيء وهي واقفة، وبيتعكس لو ماشية لورا
		var dir_sign: float = 1.0 if vf >= -0.2 else -1.0
		var turn_factor: float = lerpf(0.3, 1.0, clampf(absf(vf) / 5.0, 0.0, 1.0)) * (1.0 - 0.3 * speed_frac)
		var target_yaw: float = _steer_smooth * turn_rate * turn_factor * dir_sign
		av.y = lerpf(av.y, target_yaw, 1.0 - exp(-yaw_response * delta))

		# ميلان فيزيائي: بتميل للخارج في اللفة، بتدخل لقدام مع الفرامل وبترجع لورا مع البنزين
		var raw_acc: float = (vf - _last_vf) / delta
		_fwd_acc = lerpf(_fwd_acc, raw_acc, 1.0 - exp(-8.0 * delta))
		_last_vf = vf
		var lat_acc: float = vf * av.y
		var lean_r: float = clampf(lat_acc * roll_lean, -max_lean, max_lean)
		var lean_p: float = clampf(-_fwd_acc * pitch_lean, -max_lean, max_lean)
		var want_up: Vector3 = (n + right_g * lean_r + fwd_g * lean_p).normalized()
		var err: Vector3 = up.cross(want_up)
		var av_flat: Vector3 = av - n * av.dot(n)
		av += (err * lean_kp - av_flat * lean_kd) * delta
	else:
		# في الهوا: تحكم بسيط في الدوران + تعديل خفيف للوضع عشان تنزل على العجلات
		av.y = lerpf(av.y, _steer_smooth * turn_rate * 0.35, 1.0 - exp(-4.0 * delta))
		var err_a: Vector3 = up.cross(Vector3.UP)
		var av_a: Vector3 = av - Vector3.UP * av.dot(Vector3.UP)
		av += (err_a * air_level_kp - av_a * lean_kd * 0.4) * delta
		_last_vf = lv.dot(_heading)
		if _jump_buffer > 0.0 and _coyote > 0.0:
			lv.y = jump_velocity # coyote: لسه لسه سابت الحافة
			_jump_buffer = 0.0
			_coyote = 0.0
			_no_ground_timer = 0.25

	linear_velocity = lv
	angular_velocity = av


## 4 أشعة من العجلات: عدد الملامس + متوسط الـ normal + سرعة البلاتفورم (meta "vel")
func _probe_wheels(reach: float) -> Dictionary:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var xf: Transform3D = global_transform
	var down: Vector3 = -xf.basis.y
	var count: int = 0
	var normal_sum: Vector3 = Vector3.ZERO
	var vel: Vector3 = Vector3.ZERO
	for i in WHEEL_POS.size():
		var wp: Vector3 = xf * (WHEEL_POS[i] as Vector3)
		var from: Vector3 = wp - down * 0.1
		var to: Vector3 = wp + down * (WHEEL_R + reach)
		var query := PhysicsRayQueryParameters3D.create(from, to, 1, [get_rid()])
		var hit: Dictionary = space.intersect_ray(query)
		if hit.is_empty():
			continue
		count += 1
		normal_sum += hit["normal"] as Vector3
		if vel == Vector3.ZERO:
			var col: Object = hit.get("collider") as Object
			if col != null and col.has_meta("vel"):
				vel = col.get_meta("vel") as Vector3
	var normal: Vector3 = Vector3.UP
	if count > 0 and normal_sum.length() > 0.001:
		normal = normal_sum.normalized()
	return {"count": count, "normal": normal, "vel": vel}


func _near_ground() -> bool:
	var query := PhysicsRayQueryParameters3D.create(
		global_position + Vector3.UP * 0.6, global_position + Vector3.DOWN * 0.8, 1, [get_rid()])
	return not get_world_3d().direct_space_state.intersect_ray(query).is_empty()


func _recover() -> void:
	DebugLog.say("CART", "رجعت واقفة")
	var yaw: float = atan2(-_heading.x, -_heading.z)
	_reset_to(Transform3D(Basis(Vector3.UP, yaw), global_position + Vector3.UP * 0.5))


## نقطة الرجوع لما العربية تقع (بتتنادى من checkpoint.gd)
func set_checkpoint(target: Transform3D) -> void:
	_spawn_transform = target


func _respawn() -> void:
	DebugLog.say("CART", "respawn عند %s" % _spawn_transform.origin)
	_reset_to(_spawn_transform)


func _reset_to(target: Transform3D) -> void:
	global_transform = target
	var flat: Vector3 = -target.basis.z
	flat.y = 0.0
	if flat.length() > 0.1:
		_heading = flat.normalized()
	_cam_yaw = target.basis.get_euler().y
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_fallen_time = 0.0
	_is_fallen = false
	_gas_smooth = 0.0
	_brake_smooth = 0.0
	_last_vf = 0.0
	_fwd_acc = 0.0
	_last_pos = global_position
	_prev_vis_origin = global_position
	_prev_vis_vel = Vector3.ZERO
	reset_physics_interpolation()
	_teleport_id += 1
	_send_snapshot(0.0, true)


# ======================================================================
# الشبكة: الـ host -> client (snapshots)
# ======================================================================
func _send_snapshot(delta: float, force: bool = false) -> void:
	if not _online:
		return
	_snap_timer += delta
	if not force and _snap_timer < snapshot_interval:
		return
	var elapsed: float = _snap_timer
	_snap_timer = 0.0
	var pos: Vector3 = global_position
	var still: bool = pos.distance_to(_last_sent_pos) < 0.003 \
		and absf(_net_steer - _last_sent_steer) < 0.02 \
		and linear_velocity.length() < 0.05 and angular_velocity.length() < 0.05
	if still and not force:
		_idle_acc += elapsed
		if _idle_acc < 0.5:
			return # العربية واقفة: keep-alive كل نص ثانية بس
	_idle_acc = 0.0
	var peer: int = _find_peer()
	if peer < 0:
		return
	_last_sent_pos = pos
	_last_sent_steer = _net_steer
	_snap_seq_out += 1
	_snap_sent += 1
	var rot: Quaternion = global_transform.basis.get_rotation_quaternion()
	if force:
		# respawn / recover: reliable عشان العميل ما يعرضش انزلاق عبر الخريطة لو الحزمة ضاعت
		GDSync.call_func_on(peer, _receive_snapshot, _snap_seq_out, Time.get_ticks_msec(), _teleport_id,
			pos, rot, linear_velocity, _net_steer)
	else:
		GDSync.call_func_on_unreliable(peer, _receive_snapshot, _snap_seq_out, Time.get_ticks_msec(), _teleport_id,
			pos, rot, linear_velocity, _net_steer)


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


## بتتنفذ عند الـ client بس
func _receive_snapshot(seq: int, host_ms: int, teleport_id: int, pos: Vector3, rot: Quaternion, vel: Vector3, steer: float) -> void:
	if GDSync.is_host():
		return
	if not pos.is_finite() or not rot.is_finite() or not vel.is_finite() or not is_finite(steer) or rot.length_squared() < 0.5:
		return
	if seq <= _snap_seq_in:
		return # قديمة أو مكررة: عمرنا ما بنرجع لحالة أقدم
	_snap_seq_in = seq
	_snap_count += 1
	_last_snap_ms = Time.get_ticks_msec()
	NetClock.feed(host_ms)
	if teleport_id != _teleport_seen:
		_teleport_seen = teleport_id
		_buf.clear()
		_teleport_pending = true
		_teleports += 1
	var s := Snap.new()
	s.t = float(host_ms) / 1000.0
	s.pos = pos
	s.rot = rot.normalized()
	s.vel = vel
	s.steer = clampf(steer, -1.0, 1.0)
	_buf.append(s)
	if _buf.size() > 64:
		_buf.pop_front()


# ======================================================================
# الشبكة: الـ client
# ======================================================================
func _client_step(delta: float) -> void:
	if _role == ControlRole.GAS_BRAKE:
		_send_drive_input(delta)
	_view_step(delta)
	_client_diag(delta)


## بنزين + فرامل: بتتبعت لما تتغيّر، وبتتكرر طول ما ضاغط (والصفر بيتكرر شوية عشان لو حزمة ضاعت)
func _send_drive_input(delta: float) -> void:
	var gas: float = snappedf(Input.get_action_strength(&"move_forward"), 0.1)
	var brake: float = snappedf(Input.get_action_strength(&"move_back"), 0.1)
	_hb_timer += delta
	_send_cd = maxf(_send_cd - delta, 0.0)
	var changed: bool = not (is_equal_approx(gas, _last_gas_sent) and is_equal_approx(brake, _last_brake_sent))
	if changed:
		_repeat_time = 0.4
	_repeat_time = maxf(_repeat_time - delta, 0.0)
	var active: bool = gas > 0.0 or brake > 0.0 or _repeat_time > 0.0
	if _send_cd <= 0.0 and (changed or (active and _hb_timer >= heartbeat)):
		_last_gas_sent = gas
		_last_brake_sent = brake
		_hb_timer = 0.0
		_send_cd = min_send_interval
		_drive_seq += 1
		GDSync.call_func_on_unreliable(GDSync.get_host(), _receive_drive, _drive_seq, gas, brake)


## بتتنفذ عند الـ host بس. الـ host بيتحقق من كل قيمة قبل ما تأثّر على العربية.
func _receive_drive(seq: int, gas: float, brake: float) -> void:
	if not GDSync.is_host():
		return
	var sender: int = GDSync.get_sender_id()
	if sender >= 0 and sender != GDSync.get_client_id() and not (sender in GDSync.lobby_get_all_clients()):
		return
	if not is_finite(gas) or not is_finite(brake):
		return
	var now_ms: int = Time.get_ticks_msec()
	if now_ms - _last_drive_ms < roundi(min_drive_interval * 1000.0):
		_dropped_rpc += 1
		return
	if seq <= _drive_seq_in and _drive_seq_in - seq < 10000:
		return # حزمة قديمة وصلت متأخرة
	_last_drive_ms = now_ms
	_drive_seq_in = seq
	_remote_gas = clampf(gas, 0.0, 1.0)
	_remote_brake = clampf(brake, 0.0, 1.0)
	_remote_time = float(now_ms) / 1000.0


## عرض العربية عند الـ client: Hermite بين snapshotين عند وقت متأخر (render time)
func _view_step(delta: float) -> void:
	if _buf.is_empty():
		return
	_delay_smooth = lerpf(_delay_smooth, NetClock.suggested_delay(interp_delay), 1.0 - exp(-2.0 * delta))
	NetClock.render_delay = _delay_smooth
	var rt: float = NetClock.world_time()
	while _buf.size() > 2 and (_buf[1] as Snap).t <= rt:
		_buf.pop_front()

	var pos: Vector3
	var rot: Quaternion
	var steer: float
	var last: Snap = _buf[_buf.size() - 1] as Snap
	if _buf.size() < 2 or rt >= last.t:
		# مفيش snapshot أحدث: نتنبأ شوية بالسرعة ونثبت
		var ex: float = clampf(rt - last.t, 0.0, max_extrapolation)
		if rt - last.t > 0.002:
			_underruns += 1
		pos = last.pos + last.vel * ex
		rot = last.rot
		steer = last.steer
	else:
		var a: Snap = _buf[0] as Snap
		var b: Snap = _buf[1] as Snap
		var span: float = maxf(b.t - a.t, 0.0001)
		var u: float = clampf((rt - a.t) / span, 0.0, 1.0)
		if a.pos.distance_to(b.pos) > teleport_distance:
			pos = a.pos # نقل فوري: ما نتحركش بين النقطتين
			rot = a.rot
			steer = a.steer
		else:
			pos = _hermite(a.pos, a.vel, b.pos, b.vel, span, u)
			rot = a.rot.slerp(b.rot, u)
			steer = lerpf(a.steer, b.steer, u)
	global_transform = Transform3D(Basis(rot), pos)
	_net_steer = steer
	if _teleport_pending:
		_teleport_pending = false
		reset_physics_interpolation()


func _hermite(p0: Vector3, v0: Vector3, p1: Vector3, v1: Vector3, h: float, u: float) -> Vector3:
	var u2: float = u * u
	var u3: float = u2 * u
	var res: Vector3 = p0 * (2.0 * u3 - 3.0 * u2 + 1.0) + v0 * (h * (u3 - 2.0 * u2 + u))
	res += p1 * (-2.0 * u3 + 3.0 * u2) + v1 * (h * (u3 - u2))
	return res


# ---- تشخيص الشبكة (بيتطبع كل 5 ثواني في الـ Output) ----
func _client_diag(delta: float) -> void:
	_diag_timer += delta
	if _diag_timer < 5.0:
		return
	DebugLog.say("NET", "client: snapshots %.0f/s | buffer=%d | delay=%dms | jitter=%.0fms | underruns=%d | teleports=%d" % [
		_snap_count / _diag_timer, _buf.size(), roundi(_delay_smooth * 1000.0), NetClock.jitter_ms, _underruns, _teleports])
	_diag_timer = 0.0
	_snap_count = 0
	_underruns = 0
	_teleports = 0


func _host_diag(delta: float) -> void:
	if not _online:
		return
	_diag_timer += delta
	if _diag_timer < 5.0:
		return
	var age: float = Time.get_ticks_msec() / 1000.0 - _remote_time
	DebugLog.say("NET", "host: snapshots %.0f/s | عمر آخر مدخلات client=%.2fs | رفض rate-limit=%d" % [
		_snap_sent / _diag_timer, age, _dropped_rpc])
	_diag_timer = 0.0
	_snap_sent = 0


# ======================================================================
# الشكل
# ======================================================================
func _update_motion_visuals(delta: float) -> void:
	var moved: Vector3 = global_position - _last_pos
	moved.y = 0.0
	var raw_speed: float = moved.length() / delta
	var travel_dir: Vector3 = -global_transform.basis.z
	travel_dir.y = 0.0
	if travel_dir.length() > 0.25 and raw_speed < 80.0:
		_wheel_angle -= moved.dot(travel_dir.normalized()) / WHEEL_R
		for s in _wheel_spins:
			(s as Node3D).rotation.x = fposmod(_wheel_angle, TAU)
	_last_pos = global_position
	if raw_speed > 80.0:
		raw_speed = 0.0
	_vis_speed = lerpf(_vis_speed, raw_speed, 1.0 - exp(-10.0 * delta))


func _process(delta: float) -> void:
	if delta <= 0.0:
		return
	var visual_xf: Transform3D = get_global_transform_interpolated()
	var flat_forward: Vector3 = -visual_xf.basis.z
	flat_forward.y = 0.0
	if flat_forward.length() > 0.4:
		var yaw: float = atan2(-flat_forward.x, -flat_forward.z)
		_cam_yaw = lerp_angle(_cam_yaw, yaw, 1.0 - exp(-camera_yaw_speed * delta))
	_camera_rig.rotation.y = _cam_yaw
	var target: Vector3 = visual_xf.origin + Vector3.UP
	_camera_rig.global_position = _camera_rig.global_position.lerp(
		target, 1.0 - exp(-camera_follow_speed * delta))
	_steer_vis = lerpf(_steer_vis, _net_steer, 1.0 - exp(-14.0 * delta))
	for p in _front_pivots:
		(p as Node3D).rotation.y = _steer_vis * 0.5
	_update_items(visual_xf, delta)
	_update_hud()


## البيض والبطيخ بيتنططوا جوه السلة حسب تسارع العربية (شكل بس، مش متزامن)
func _update_items(visual_xf: Transform3D, delta: float) -> void:
	var vel: Vector3 = (visual_xf.origin - _prev_vis_origin) / delta
	var acc: Vector3 = ((vel - _prev_vis_vel) / delta).limit_length(60.0)
	_prev_vis_origin = visual_xf.origin
	_prev_vis_vel = vel
	var acc_local: Vector3 = visual_xf.basis.transposed() * acc
	_acc_smooth = _acc_smooth.lerp(acc_local, 1.0 - exp(-25.0 * delta))
	for it in _items:
		var d: Dictionary = it
		var lim: float = d["lim"]
		var target: Vector3 = (-_acc_smooth * float(d["k"])).clamp(
			Vector3(-lim, -lim * 1.6, -lim), Vector3(lim, lim * 1.6, lim))
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
			role_text = "OFFLINE: A/D steer, W gas, S brake, Space jump"
	var txt: String = "%s\n%d km/h" % [role_text, int(_vis_speed * 3.6)]
	if _online and not _authoritative:
		txt += "\nview delay %d ms" % roundi(_delay_smooth * 1000.0)
		if _last_snap_ms > 0 and Time.get_ticks_msec() - _last_snap_ms > 2000:
			txt += "\nNO SIGNAL from host..."
	_hud_label.text = txt


# ---- بناء الشكل (موديل لو موجود، غير كده شكل مؤقت) ----
func _build_visual() -> void:
	_model = Node3D.new()
	_model.name = "Model"
	_visual.add_child(_model)
	var cart_scene: PackedScene = _try_load(cart_model_path)
	if cart_scene != null:
		var holder := Node3D.new()
		_model.add_child(holder)
		var fitted := cart_scene.instantiate() as Node3D
		holder.add_child(fitted)
		var size: Vector3 = _fit_into(fitted, 1.05, true, true)
		var auto_yaw: float = 90.0 if size.x > size.z * 1.15 else 0.0
		holder.rotation_degrees.y = model_yaw_degrees + auto_yaw
	else:
		_build_procedural_cart()
	_build_items()


func _try_load(path: String) -> PackedScene:
	if path.is_empty() or not ResourceLoader.exists(path):
		return null
	return load(path) as PackedScene


func _aabb_of(node: Node3D) -> AABB:
	var inv: Transform3D = node.global_transform.affine_inverse()
	var out := AABB()
	var first: bool = true
	for m in node.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var a: AABB = (inv * mi.global_transform) * mi.get_aabb()
		if first:
			out = a
			first = false
		else:
			out = out.merge(a)
	return out


## بيكبّر/بيصغّر الموديل لحجم مناسب وبيوسّطه (والعربية بتتحط على الأرض)
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


func _plain(color: Color, metal: float = 0.0, rough: float = 0.7) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = metal
	m.roughness = rough
	return m


func _add_box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


func _build_procedural_cart() -> void:
	var metal: StandardMaterial3D = _plain(Color(0.80, 0.82, 0.85), 0.85, 0.35)
	var glass: StandardMaterial3D = _plain(Color(0.85, 0.88, 0.92, 0.38), 0.6, 0.3)
	glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass.cull_mode = BaseMaterial3D.CULL_DISABLED
	_add_box(_model, Vector3(0.58, 0.46, 0.9), Vector3(0.0, 0.64, -0.03), glass) # جدران السلة
	_add_box(_model, Vector3(0.52, 0.04, 0.84), Vector3(0.0, 0.41, -0.03), metal) # الأرضية
	# إطار علوي
	_add_box(_model, Vector3(0.6, 0.03, 0.03), Vector3(0.0, 0.87, -0.48), metal)
	_add_box(_model, Vector3(0.6, 0.03, 0.03), Vector3(0.0, 0.87, 0.42), metal)
	_add_box(_model, Vector3(0.03, 0.03, 0.9), Vector3(-0.29, 0.87, -0.03), metal)
	_add_box(_model, Vector3(0.03, 0.03, 0.9), Vector3(0.29, 0.87, -0.03), metal)
	# إيد الدفع
	_add_box(_model, Vector3(0.62, 0.04, 0.04), Vector3(0.0, 1.02, 0.47), _plain(Color(0.15, 0.15, 0.17), 0.1, 0.6))
	_add_box(_model, Vector3(0.03, 0.17, 0.03), Vector3(-0.28, 0.94, 0.45), metal)
	_add_box(_model, Vector3(0.03, 0.17, 0.03), Vector3(0.28, 0.94, 0.45), metal)
	# عجلات (الأمامية بتلف مع الدركسيون)
	var rubber: StandardMaterial3D = _plain(Color(0.08, 0.08, 0.09), 0.0, 0.9)
	for i in WHEEL_POS.size():
		var wp: Vector3 = WHEEL_POS[i] as Vector3
		_add_box(_model, Vector3(0.03, 0.30, 0.03), Vector3(wp.x, 0.26, wp.z), metal) # دعامة
		var pivot := Node3D.new()
		pivot.position = wp
		_model.add_child(pivot)
		var spin := Node3D.new()
		pivot.add_child(spin)
		var cm := CylinderMesh.new()
		cm.top_radius = WHEEL_R
		cm.bottom_radius = WHEEL_R
		cm.height = 0.05
		var wheel := MeshInstance3D.new()
		wheel.mesh = cm
		wheel.material_override = rubber
		wheel.rotation_degrees.z = 90.0
		spin.add_child(wheel)
		_wheel_spins.append(spin)
		if i < 2:
			_front_pivots.append(pivot)


func _build_items() -> void:
	var root := Node3D.new()
	root.name = "Items"
	_model.add_child(root)
	var egg_scene: PackedScene = _try_load(egg_model_path)
	var melon_scene: PackedScene = _try_load(watermelon_model_path)

	# صينية بيض (2 × 3)
	_add_box(root, Vector3(0.32, 0.03, 0.2), Vector3(-0.1, 0.435, 0.22), _plain(Color(0.55, 0.42, 0.3)))
	var egg_mesh := SphereMesh.new()
	egg_mesh.radius = 0.045
	egg_mesh.height = 0.09
	var egg_mat: StandardMaterial3D = _plain(Color(0.96, 0.92, 0.82), 0.0, 0.5)
	for r in 2:
		for c in 3:
			var pos := Vector3(-0.2 + c * 0.1, 0.51, 0.17 + r * 0.1)
			_make_item(root, pos, egg_scene, 0.1, egg_mesh, Vector3(1.0, 1.3, 1.0), egg_mat, 260.0, 10.0, 0.0045, 0.05)

	# بطيختين
	var melon_mesh := SphereMesh.new()
	melon_mesh.radius = 0.18
	melon_mesh.height = 0.36
	melon_mesh.radial_segments = 28
	melon_mesh.rings = 14
	var melon_mat: ShaderMaterial = _melon_material()
	_make_item(root, Vector3(0.10, 0.60, -0.30), melon_scene, 0.36, melon_mesh, Vector3(1.0, 0.88, 1.1), melon_mat, 140.0, 12.0, 0.002, 0.03)
	_make_item(root, Vector3(-0.14, 0.56, -0.07), melon_scene, 0.28, melon_mesh, Vector3(0.78, 0.7, 0.86), melon_mat, 140.0, 12.0, 0.002, 0.03)


func _melon_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = "shader_type spatial;\nvoid fragment() {\n\tfloat s = step(0.5, fract(UV.x * 10.0));\n\tALBEDO = mix(vec3(0.06, 0.32, 0.10), vec3(0.18, 0.60, 0.22), s);\n\tROUGHNESS = 0.45;\n}\n"
	var m := ShaderMaterial.new()
	m.shader = sh
	return m


func _make_item(parent: Node3D, pos: Vector3, scene: PackedScene, size: float, mesh: Mesh,
		mesh_scale: Vector3, mat: Material, stiff: float, damp: float, k: float, lim: float) -> void:
	var holder := Node3D.new()
	holder.position = pos
	parent.add_child(holder)
	if scene != null:
		var n := scene.instantiate() as Node3D
		holder.add_child(n)
		_fit_into(n, size, false, false)
	else:
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = mat
		mi.scale = mesh_scale
		holder.add_child(mi)
	_items.append({"node": holder, "rest": pos, "off": Vector3.ZERO, "vel": Vector3.ZERO,
		"stiff": stiff, "damp": damp, "k": k, "lim": lim})
