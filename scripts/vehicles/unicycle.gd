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
## الـ host هو اللي بيحرّك الدراجة (authoritative). الـ client بيبعت المدخلات بس (البنزين والقفز)
## والـ host بيتحقق منها (نوع/مدى/تردد). عمره ما بيبعت مكان أو حالة.
## الـ host هو المرجع (authoritative) وبيبعت حالته (snapshots) كل 0.016s (~60/ث). الـ client بيشغّل نفس الفيزيكس محليًا
## (توقّع/prediction): بنزينه وقفزته فورًا، ودركسيون وفرامل الـ host من آخر snapshot، ويتصحّح ناحية حالة الـ host بالتدريج.
## والـ client بيحتفظ بيها كهدف وبيقرّب منه بـ lerp في _physics_process (من غير ما يقفز).
## الـ global_transform نفسه مش بيتزامن. و Physics Interpolation شغال في المشروع.

const SessionMode = preload("res://scripts/multiplayer/session_mode.gd")
const DebugLog = preload("res://scripts/systems/debug_log.gd")

enum ControlRole { ALL, STEER_BRAKE, GAS_JUMP }

const WHEEL_RADIUS: float = 0.45

@export_group("Speed")
@export var max_speed: float = 22.0
@export var acceleration: float = 18.0
@export var brake_decel: float = 35.0
@export var coast_drag: float = 2.0
@export var gas_response: float = 8.0 # سرعة وصول البنزين للقيمة (تأخر الشبكة بيبان كتسارع ناعم)
@export var grip: float = 10.0 # بيقتل الانزلاق الجانبي (أعلى = ملزقة أكتر)

@export_group("Steering")
@export var steer_response: float = 7.0 # سرعة وصول الدركسيون للقيمة (بيمنع الحدّة على الكيبورد)
@export var turn_rate: float = 3.2 # راديان/ثانية
@export var lean_accel: float = 22.0 # ميلان الدور مع السرعة (أعلى = أصعب وأخطر)
@export var brake_pitch: float = 12.0 # الفرامل بتنبطح بيها لقدام
@export var gas_pitch: float = 5.0 # البنزين بيرجّعها لورا شوية

@export_group("Balance")
@export var balance_kp: float = 28.0 # قوة رجوعها واقفة
@export var balance_kd: float = 6.0 # تثبيت (بيمنع الاهتزاز)
@export var air_balance: float = 0.2 # التوازن في الهوا (قليل = بتتشقلب)
@export var fall_tilt_degrees: float = 63.0 # بعد الميل ده بتقع
@export var recover_time: float = 0.8

@export_group("Jump")
@export var jump_velocity: float = 7.5
@export var fall_limit: float = -12.0 # تحت الرقم ده نرجّع الدراجة لمكان البداية

@export_group("Network")
@export var input_timeout: float = 0.35 # لو البنزين ماوصلش أحدث من كده نصفّره (عشان ما يعلقش)
@export var heartbeat: float = 0.04 # الـ client بيكرر البنزين كل كام ثانية طول ما هو ضاغط (~25/ث)
@export var min_send_interval: float = 0.04 # أقل فاصل بين إرسالتين بنزين من الـ client (25/ث كحد أقصى)
@export var snapshot_interval: float = 0.016 # الـ host بيبعت حالة الدراجة كل كام ثانية (~60/ث)
@export var max_extrapolation: float = 0.25 # أقصى مدة بنتنبأ فيها بمكان الـ host من آخر حزمة (ثانية)
## [FIX-1] خُفّضت من 6.0 إلى 3.0: التصحيح كان حادًا جدًا عند وصول كل snapshot
## فكان بيخلق قفزة ظاهرة على شاشة الـ client. 3.0 بتعمل تصحيح ناعم خلال ~0.3s بدل ~0.1s
@export var correction_pos_speed: float = 3.0
## [FIX-2] خُفّضت من 5.0 إلى 2.5: نفس السبب للدوران
@export var correction_rot_speed: float = 2.5
## [FIX-3] خُفّضت من 6.0 إلى 3.5: كنا بننتظر 6m فرق قبل ما ننقل فورًا.
## 3.5m أقرب للواقع: لو الـ client بعد 3.5m عن الـ host = فيه خلل، ننقل فورًا ومنكملش التصحيح البطيء
@export var net_snap_distance: float = 3.5
@export_subgroup("Server rate limit")
@export var min_gas_interval: float = 0.02 # الـ host يتجاهل أي بنزين أسرع من كده (الـ client الطبيعي 0.04)
@export var min_jump_interval: float = 0.1 # الـ host يتجاهل أي قفزة أسرع من كده

## Rollback (بيشتغل أونلاين بس لما Physics Engine = Rapier3D، غير كده الـ Network القديم اللي فوق هو اللي بيشتغل)
@export_group("Rollback")
@export var rb_send_every: int = 4 # نبعت المدخلات كل كام tick (120 tick/ث ÷ 4 = 30 رسالة/ث)
@export var rb_send_window: int = 24 # كل رسالة فيها آخر كام tick (تكرار بيعوّض الحزم الضايعة)
@export var rb_max_rollback: int = 90 # أقصى عمق إعادة محاكاة (tick). 90 = 0.75ث
@export var rb_auth_every: int = 30 # الـ host يبعت الحالة المؤكدة كل كام tick (4/ث)
@export var rb_auth_tolerance: float = 0.03 # فرق مكان (متر) أقل منه الـ client يتجاهله
@export var rb_remote_timeout_ticks: int = 42 # لو مدخلات الطرف التاني وقفت، نصفّرها (0.35ث)
@export var rb_correction_decay: float = 5.0 # سرعة اختفاء قفزة التصحيح من الشاشة (أعلى = أسرع، أقل = أنعم)
@export var rb_input_delay: int = 6 # تأخير مدخلاتي المحلية (tick). بيقلل الـ rollbacks والقفزات. 6 = 50ms

@export_group("Visual")
@export var model_yaw_degrees: float = 0.0 # لو الدراجة ماشية بضهرها غيّرها لـ 180
@export var camera_follow_speed: float = 30.0
@export var camera_yaw_speed: float = 4.0

@onready var _model: Node3D = $Visual/Model
@onready var _wheel_pivot: Node3D = $Visual/Model/WheelPivot
@onready var _camera_rig: Node3D = $CameraRig
@onready var _camera: Camera3D = $CameraRig/Camera3D
@onready var _hud_label: Label = $HUD/Label
@onready var _visual: Node3D = $Visual

var _online: bool = false
var _authoritative: bool = true # الجهاز ده هو المرجع (الـ host أو أوفلاين). الـ client بيتوقّع ويتصحّح
var _role: int = ControlRole.ALL

var _jump_buffer: float = 0.0
var _steer_smooth: float = 0.0
var _no_ground_timer: float = 0.0 # بعد القفز نتجاهل الأرض لحظة
var _fallen_time: float = 0.0
var _is_fallen: bool = false
var _heading: Vector3 = Vector3.FORWARD
var _spawn_transform: Transform3D

# snapshots (host -> client)
var _snap_timer: float = 0.0
var _snap_seq_out: int = 0
var _teleport_id: int = 0 # بيزيد مع كل respawn / recover عشان الـ client ينقل فورًا
var _peer_id: int = -1
var _peer_check_ms: int = 0
var _net_steer: float = 0.0 # آخر دركسيون/فرامل للـ host (بيتبعتوا للـ client عشان يتوقعهم)
var _net_brake: bool = false
# عند الـ client
var _have_snapshot: bool = false
var _snap_seq_in: int = -1
var _snap_teleport: int = 0
var _snap_pos: Vector3 = Vector3.ZERO
var _snap_rot: Quaternion = Quaternion.IDENTITY
var _snap_vel: Vector3 = Vector3.ZERO
var _snap_arrival_ms: int = 0
var _remote_steer: float = 0.0
var _remote_brake: bool = false
var _snap_count: int = 0
var _err_sum: float = 0.0
var _err_n: int = 0
var _stats_timer: float = 0.0
var _gas_smooth: float = 0.0

# ---- Rollback (GDSync للنقل + Rapier للمحاكاة) ----
const RB_HIST: int = 256 # تاريخ الحالات/المدخلات (2.1ث عند 120Hz)
const RB_STATE_SIZE: int = 22

var _rb: bool = false # وضع الـ rollback شغال؟
var _rapier: Object
var _ds: PhysicsDirectBodyState3D
var _space: RID
var _dt: float = 1.0 / 120.0
var _tick: int = 0 # الـ tick الجاي اللي هنحاكيه
var _rb_started: bool = false
var _rb_wait_start_ms: int = 0
var _rb_hello_ms: int = 0
var _rb_peer_hello: bool = false
var _rb_got_go: bool = false
var _rb_go_sent: bool = false
var _rb_start_at_ms: int = 0
var _rb_states: Array = [] # حالة الدراجة "قبل" محاكاة الـ tick (PackedFloat64Array)
var _rb_state_tag: PackedInt32Array = PackedInt32Array()
var _rb_local: Array[Vector4] = [] # مدخلاتي الحقيقية لكل tick
var _rb_local_tag: PackedInt32Array = PackedInt32Array()
var _rb_used: Array[Vector4] = [] # المدخلات (الاتنين) اللي اتحاكى بيها الـ tick
var _rb_remote: Array[Vector4] = [] # مدخلات الطرف التاني الحقيقية
var _rb_remote_tag: PackedInt32Array = PackedInt32Array()
var _rb_remote_last: Vector4 = Vector4.ZERO
var _rb_remote_latest: int = -1
var _rb_confirmed: int = -1 # أعلى tick مدخلات الطرف التاني معروفة لحد عنده بدون ثقوب
var _rb_from: int = -1 # أقدم tick محتاج إعادة محاكاة (-1 = مفيش)
var _rb_events: Dictionary = {} # tick -> [origin, yaw] (respawn / recover بقرار الـ host)
var _rb_auth_pending: Dictionary = {} # tick -> PackedFloat64Array (حالة الـ host المؤكدة)
var _rb_corr: Vector3 = Vector3.ZERO # قفزة التصحيح المخفية بتتلاشى على الشاشة
var _rb_corr_rot: Quaternion = Quaternion.IDENTITY
var _rb_resim: bool = false
var _rb_teleported: bool = false
var _rb_had_peer: bool = false
var _rb_peer_lost_ms: int = 0 # 0 = الطرف التاني موجود
var _rb_in_count: int = 0
var _rb_in_window_start_ms: int = 0
var _rb_stat_rollbacks: int = 0
var _rb_stat_resim_ticks: int = 0
var _rb_stat_corrections: int = 0
var _rb_stat_dropped: int = 0

# مدخلات الـ client عند الـ host
var _remote_gas: float = 0.0
var _remote_gas_time: float = -100.0
var _last_gas_recv_ms: int = -1000000
var _last_jump_recv_ms: int = -1000000
var _dropped_rpc: int = 0

# إرسال الـ client
var _last_sent_gas: float = -1.0
var _heartbeat_timer: float = 0.0
var _send_cooldown: float = 0.0
var _zero_repeat_time: float = 0.0
var _gas_timed_out: bool = false

# للشكل
var _last_pos: Vector3
var _vis_speed: float = 0.0
var _cam_yaw: float = 0.0
var _wheel_angle: float = 0.0


func _ready() -> void:
	add_to_group("unicycle")
	_online = not SessionMode.offline and GDSync.is_active()
	_authoritative = (not _online) or GDSync.is_host()
	if not _online:
		_role = ControlRole.ALL
	else:
		_role = ControlRole.STEER_BRAKE if GDSync.is_host() else ControlRole.GAS_JUMP
		GDSync.expose_func(_receive_gas, ENUMS.EXPOSE_PERMISSION.CLIENT)
		GDSync.expose_func(_receive_jump, ENUMS.EXPOSE_PERMISSION.CLIENT)
		GDSync.expose_func(_receive_snapshot, ENUMS.EXPOSE_PERMISSION.HOST)

	_ensure_input_actions()
	_log_setup()
	_spawn_transform = global_transform
	_last_pos = global_position
	_cam_yaw = global_rotation.y
	_model.rotation_degrees.y = model_yaw_degrees

	_camera_rig.top_level = true
	_camera_rig.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_camera_rig.global_position = global_position + Vector3.UP
	_camera_rig.rotation = Vector3(0.0, _cam_yaw, 0.0)
	_camera.make_current()
	_rb_setup()


func _log_setup() -> void:
	var frame_meshes: int = get_node("Visual/Model/Frame").find_children("*", "MeshInstance3D", true, false).size()
	var wheel_meshes: int = _wheel_pivot.find_children("*", "MeshInstance3D", true, false).size()
	DebugLog.say("UNI", "online=%s simulates=%s role=%d pos=%s" % [
		_online, _authoritative, _role, global_position])
	DebugLog.say("UNI", "meshes: frame=%d wheel=%d (0 = الموديل ما اتعملوش import)" % [frame_meshes, wheel_meshes])
	if _online:
		DebugLog.say("UNI", "client_id=%d host=%s host_id=%d" % [GDSync.get_client_id(), GDSync.is_host(), GDSync.get_host()])


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


func _physics_process(delta: float) -> void:
	_update_motion_visuals(delta)
	if _rb:
		_rb_process(delta)
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
				_gas_timed_out = false
			elif _remote_gas > 0.0 and not _gas_timed_out:
				_gas_timed_out = true
				DebugLog.say("NET", "gas timeout: مفيش تحديث من %.2fs" % (now - _remote_gas_time))
		ControlRole.GAS_JUMP:
			gas = Input.get_action_strength(&"move_forward")
			if Input.is_action_just_pressed(&"jump"):
				_jump_buffer = 0.25
			if Time.get_ticks_msec() - _snap_arrival_ms < 500:
				steer = _remote_steer
				brake = _remote_brake
		_:
			pass

	_send_client_input(delta)

	if _authoritative:
		_net_steer = steer
		_net_brake = brake
		_send_snapshot(delta)

	var wants_recover: bool = _control_step(delta, steer, brake, gas, _authoritative)
	if wants_recover:
		_recover()
		return

	if _authoritative:
		if global_position.y < fall_limit:
			_respawn()
	else:
		_reconcile(delta)


## خطوة التحكم الواحدة (مشتركة بين الوضع القديم والـ rollback). بترجّع true لو لازم نعمل recover.
func _control_step(delta: float, steer: float, brake: bool, gas: float, track_fall: bool) -> bool:
	_gas_smooth = move_toward(_gas_smooth, gas, gas_response * delta)
	gas = _gas_smooth
	_steer_smooth = move_toward(_steer_smooth, steer, steer_response * delta)
	steer = _steer_smooth

	_jump_buffer = maxf(_jump_buffer - delta, 0.0)
	_no_ground_timer = maxf(_no_ground_timer - delta, 0.0)

	var xf: Transform3D = _body_xf()
	var basis_up: Vector3 = xf.basis.y
	var tilt: float = acos(clampf(basis_up.dot(Vector3.UP), -1.0, 1.0))
	var was_fallen: bool = _is_fallen
	_is_fallen = tilt > deg_to_rad(fall_tilt_degrees)
	if _is_fallen and not was_fallen:
		if not _rb_resim:
			DebugLog.say("UNI", "وقعت (tilt=%d°)" % roundi(rad_to_deg(tilt)))

	var ground: Dictionary = _probe_ground(0.15)
	var grounded: bool = not ground.is_empty() and _no_ground_timer <= 0.0 and not _is_fallen
	var ground_normal: Vector3 = ground.get("normal", Vector3.UP) as Vector3

	if track_fall:
		if _is_fallen and not _probe_ground(0.6, 0.6).is_empty():
			_fallen_time += delta
			if _fallen_time >= recover_time:
				return true
		elif not _is_fallen:
			_fallen_time = 0.0

	var flat_forward: Vector3 = -xf.basis.z
	flat_forward.y = 0.0
	if flat_forward.length() > 0.25:
		_heading = flat_forward.normalized()
	var right: Vector3 = _heading.cross(Vector3.UP)

	var lv: Vector3 = _body_lv()
	var av: Vector3 = _body_av()
	var vf: float = lv.dot(_heading)
	var vl: float = lv.dot(right)
	var speed_frac: float = clampf(absf(vf) / max_speed, 0.0, 1.0)

	if grounded:
		if brake:
			vf = move_toward(vf, 0.0, brake_decel * delta)
		elif gas > 0.0:
			if vf < max_speed:
				vf = minf(vf + acceleration * gas * delta, max_speed)
		else:
			vf = move_toward(vf, 0.0, coast_drag * delta)
		vl *= maxf(0.0, 1.0 - grip * delta)

		var forward_ground: Vector3 = (_heading - ground_normal * _heading.dot(ground_normal)).normalized()
		lv = forward_ground * vf + right * vl
		if _jump_buffer > 0.0:
			lv.y = jump_velocity
			_jump_buffer = 0.0
			_no_ground_timer = 0.2
			grounded = false
			if not _rb_resim:
				DebugLog.say("UNI", "jump (speed=%.1f)" % vf)

		var turn_factor: float = lerpf(0.6, 1.0, clampf(absf(vf) / 6.0, 0.0, 1.0)) * (1.0 - 0.35 * speed_frac)
		var target_yaw: float = steer * turn_rate * turn_factor
		av.y = lerpf(av.y, target_yaw, 1.0 - exp(-12.0 * delta))

		var lean: Vector3 = -right * steer * lean_accel * speed_frac
		if brake:
			lean += _heading * brake_pitch * speed_frac
		lean += -_heading * gas * gas_pitch
		av += basis_up.cross(lean) * delta
	elif not _is_fallen:
		av.y = lerpf(av.y, steer * turn_rate * 0.4, 1.0 - exp(-4.0 * delta))

	if not _is_fallen:
		var gain: float = 1.0 if grounded else air_balance
		var err: Vector3 = basis_up.cross(Vector3.UP)
		var av_flat: Vector3 = av - Vector3.UP * av.dot(Vector3.UP)
		av += (err * balance_kp * gain - av_flat * balance_kd * lerpf(0.3, 1.0, gain)) * delta

	_set_body_vel(lv, av)
	return false


func _body_xf() -> Transform3D:
	return _ds.transform if _rb else global_transform


func _body_lv() -> Vector3:
	return _ds.linear_velocity if _rb else linear_velocity


func _body_av() -> Vector3:
	return _ds.angular_velocity if _rb else angular_velocity


func _set_body_vel(lv: Vector3, av: Vector3) -> void:
	if _rb:
		_ds.linear_velocity = lv
		_ds.angular_velocity = av
	else:
		linear_velocity = lv
		angular_velocity = av


func _probe_ground(reach: float, start_lift: float = 0.0) -> Dictionary:
	var xf: Transform3D = _body_xf()
	var from: Vector3 = xf.origin + xf.basis.y * WHEEL_RADIUS + Vector3.UP * start_lift
	var to: Vector3 = from + Vector3.DOWN * (WHEEL_RADIUS + reach + start_lift)
	var query := PhysicsRayQueryParameters3D.create(from, to, 1, [get_rid()])
	return get_world_3d().direct_space_state.intersect_ray(query)


func _recover() -> void:
	DebugLog.say("UNI", "رجعت واقفة")
	var yaw: float = atan2(-_heading.x, -_heading.z)
	_reset_to(Transform3D(Basis(Vector3.UP, yaw), global_position + Vector3.UP * 0.4))


func set_checkpoint(target: Transform3D) -> void:
	_spawn_transform = target


func _respawn() -> void:
	DebugLog.say("UNI", "respawn عند نقطة الرجوع %s" % _spawn_transform.origin)
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
	_last_pos = global_position
	reset_physics_interpolation()
	_teleport_id += 1
	_send_snapshot(0.0, true)


func _send_client_input(delta: float) -> void:
	if _role != ControlRole.GAS_JUMP:
		return
	var gas: float = snappedf(Input.get_action_strength(&"move_forward"), 0.1)
	_heartbeat_timer += delta
	_send_cooldown = maxf(_send_cooldown - delta, 0.0)
	var changed: bool = not is_equal_approx(gas, _last_sent_gas)
	if changed:
		_zero_repeat_time = 0.4
	_zero_repeat_time = maxf(_zero_repeat_time - delta, 0.0)
	if _send_cooldown <= 0.0 and (changed or ((gas > 0.0 or _zero_repeat_time > 0.0) and _heartbeat_timer >= heartbeat)):
		_last_sent_gas = gas
		_heartbeat_timer = 0.0
		_send_cooldown = min_send_interval
		if changed:
			DebugLog.say("NET", "gas بعت %.1f" % gas)
		GDSync.call_func_on_unreliable(GDSync.get_host(), _receive_gas, gas)
	if Input.is_action_just_pressed(&"jump"):
		GDSync.call_func_on(GDSync.get_host(), _receive_jump)


func _receive_gas(value: float) -> void:
	if not GDSync.is_host():
		return
	if not _accept_rpc_rate(true):
		return
	if not is_finite(value):
		return
	var clamped: float = clampf(value, 0.0, 1.0)
	if not is_equal_approx(clamped, _remote_gas):
		DebugLog.say("NET", "gas استلمت %.1f" % clamped)
	_remote_gas = clamped
	_remote_gas_time = Time.get_ticks_msec() / 1000.0


func _receive_jump() -> void:
	if not GDSync.is_host():
		return
	if not _accept_rpc_rate(false):
		return
	DebugLog.say("NET", "jump استلمت من الـ client")
	_jump_buffer = 0.25


func _accept_rpc_rate(is_gas: bool) -> bool:
	var now_ms: int = Time.get_ticks_msec()
	var min_ms: int = roundi((min_gas_interval if is_gas else min_jump_interval) * 1000.0)
	var last_ms: int = _last_gas_recv_ms if is_gas else _last_jump_recv_ms
	if now_ms - last_ms < min_ms:
		_dropped_rpc += 1
		if _dropped_rpc == 1 or _dropped_rpc % 100 == 0:
			DebugLog.say("NET", "RPC %s اتجاهل (تردد عالي) المجموع=%d" % ["gas" if is_gas else "jump", _dropped_rpc])
		return false
	if is_gas:
		_last_gas_recv_ms = now_ms
	else:
		_last_jump_recv_ms = now_ms
	return true


func _send_snapshot(delta: float, force: bool = false) -> void:
	if not _online:
		return
	_snap_timer += delta
	if not force and _snap_timer < snapshot_interval:
		return
	_snap_timer = 0.0
	var peer: int = _find_peer()
	if peer < 0:
		return
	_snap_seq_out += 1
	GDSync.call_func_on_unreliable(peer, _receive_snapshot, _snap_seq_out, Time.get_ticks_msec(), _teleport_id,
		global_position, global_transform.basis.get_rotation_quaternion(), linear_velocity, _net_steer, _net_brake)


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


func _receive_snapshot(seq: int, _host_ms: int, teleport_id: int, pos: Vector3, rot: Quaternion, vel: Vector3, steer: float, brake: bool) -> void:
	if GDSync.is_host():
		return
	if not pos.is_finite() or not rot.is_finite() or not vel.is_finite() or not is_finite(steer) or rot.length_squared() < 0.5:
		return
	if seq <= _snap_seq_in:
		return
	_snap_seq_in = seq
	_snap_count += 1
	_snap_pos = pos
	_snap_rot = rot.normalized()
	_snap_vel = vel
	_snap_arrival_ms = Time.get_ticks_msec()
	_remote_steer = clampf(steer, -1.0, 1.0)
	_remote_brake = brake
	if teleport_id != _snap_teleport or not _have_snapshot:
		_snap_teleport = teleport_id
		_have_snapshot = true
		global_transform = Transform3D(Basis(_snap_rot), pos)
		linear_velocity = vel
		angular_velocity = Vector3.ZERO
		reset_physics_interpolation()


# الـ client: الفيزيكس المحلية (توقّع) بتمشي لوحدها، وكل tick بنقرّبها ناعم من مكان الـ host المتوقّع.
# [FIX] correction_pos_speed و correction_rot_speed اتخفّضوا عشان التصحيح يبقى أنعم وما يبانش على الشاشة.
# net_snap_distance اتخفّضت عشان نكتشف التباعد الكبير بكرة ونعمل teleport بدل ما التصحيح البطيء يخلّينا نتباعد أكتر.
func _reconcile(delta: float) -> void:
	_log_net_stats(delta)
	if not _have_snapshot:
		return
	var age: float = float(Time.get_ticks_msec() - _snap_arrival_ms) / 1000.0
	var one_way: float = clampf(SessionMode.last_ping_ms, 0.0, 300.0) / 2000.0
	var lead: float = minf(age + one_way, max_extrapolation)
	var target_pos: Vector3 = _snap_pos + _snap_vel * lead
	var error: Vector3 = target_pos - global_position
	_err_sum += error.length()
	_err_n += 1

	if error.length() > net_snap_distance:
		# بعدنا كتير عن الـ host: ننقل فورًا ومنكملش التصحيح البطيء
		global_transform = Transform3D(Basis(_snap_rot), target_pos)
		linear_velocity = _snap_vel
		reset_physics_interpolation()
		return
	# تصحيح ناعم: exponential decay بدل jump مفاجئ
	var new_pos: Vector3 = global_position + error * (1.0 - exp(-correction_pos_speed * delta))
	var current_rot: Quaternion = global_transform.basis.get_rotation_quaternion()
	var new_rot: Quaternion = current_rot.slerp(_snap_rot, 1.0 - exp(-correction_rot_speed * delta))
	global_transform = Transform3D(Basis(new_rot), new_pos)


func _log_net_stats(delta: float) -> void:
	_stats_timer += delta
	if _stats_timer < 5.0:
		return
	DebugLog.say("NET", "snapshots %.0f/s | خطأ التوقّع المتوسط %.2fm" % [
		_snap_count / _stats_timer, _err_sum / maxf(float(_err_n), 1.0)])
	_stats_timer = 0.0
	_snap_count = 0
	_err_sum = 0.0
	_err_n = 0


func _update_motion_visuals(delta: float) -> void:
	var moved: Vector3 = global_position - _last_pos
	moved.y = 0.0
	var raw_speed: float = moved.length() / delta
	var travel_dir: Vector3 = -global_transform.basis.z
	travel_dir.y = 0.0
	if travel_dir.length() > 0.25 and raw_speed < 80.0:
		_wheel_angle -= moved.dot(travel_dir.normalized()) / WHEEL_RADIUS
		_wheel_pivot.rotation.x = fposmod(_wheel_angle, TAU)
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
	var target: Vector3 = visual_xf.origin + Vector3.UP + _rb_corr
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
	if _rb:
		_hud_label.text += "\nNET: ROLLBACK" + ("" if _rb_started else " (بنتزامن...)")
		if _rb_peer_lost_ms > 0:
			_hud_label.text += "\nاللاعب التاني خرج - رجوع للقائمة..."


# =====================================================================
# Rollback: GDSync بينقل المدخلات والتصحيحات، و Rapier بيحاكي (space_step يدوي).
#  - الاتنين بيشغّلوا نفس المحاكاة بنفس الـ tick. كل واحد بيطبّق مدخلاته فورًا (من غير انتظار).
#  - مدخلات الطرف التاني بتتوقّع (نكرر آخر قيمة). لما الحقيقية توصل وتختلف: نرجع لحالة الـ tick ونعيد المحاكاة.
#  - الـ host هو المرجع: بيبعت حالته المؤكدة، والـ client بيصحّح نفسه منها، وقرارات respawn/recover بتاعة الـ host بس.
#  - مفيش حاجة بتبعت Transform كل frame. الـ client بيبعت مدخلات بس.
# =====================================================================
func _rb_setup() -> void:
	if not _online:
		return
	var engine_name: String = str(ProjectSettings.get_setting("physics/3d/physics_engine", "")).to_lower()
	_rapier = find_rapier()
	if not engine_name.contains("rapier") or _rapier == null:
		DebugLog.say("RB", "Rollback مقفول (physics_engine=%s rapier=%s) - الـ Network القديم شغال" % [engine_name, _rapier])
		return
	_ds = PhysicsServer3D.body_get_direct_state(get_rid())
	if _ds == null:
		DebugLog.say("RB", "مقدرتش أجيب direct state - الـ Network القديم شغال")
		return
	_space = get_world_3d().space
	_dt = 1.0 / float(Engine.physics_ticks_per_second)
	PhysicsServer3D.space_set_active(_space, false) # من هنا إحنا اللي بنحاكي
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
	_rb_wait_start_ms = Time.get_ticks_msec()
	_rb_in_window_start_ms = _rb_wait_start_ms
	_rb = true
	DebugLog.say("RB", "Rollback شغال: tick=%.1fHz role=%d" % [1.0 / _dt, _role])


## بيدوّر على سيرفر Rapier بأكتر من طريقة (اسم الـ singleton ممكن يختلف حسب النسخة)
static func find_rapier() -> Object:
	if Engine.has_singleton("RapierPhysicsServer3D"):
		return Engine.get_singleton("RapierPhysicsServer3D")
	for n: String in Engine.get_singleton_list():
		if n.to_lower().contains("rapier") and n.contains("3D"):
			return Engine.get_singleton(n)
	var ps: Object = PhysicsServer3D
	if ps != null and ps.has_method("space_step") and ps.has_method("export_binary"):
		return ps
	return null


func _exit_tree() -> void:
	if _rb:
		PhysicsServer3D.space_set_active(_space, true) # الـ space بتاع الـ viewport بيفضل بعد تغيير المشهد


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
	var k: float = 1.0 - exp(-rb_correction_decay * delta)
	_rb_corr = _rb_corr.lerp(Vector3.ZERO, k)
	_rb_corr_rot = _rb_corr_rot.slerp(Quaternion.IDENTITY, k)
	var bq: Quaternion = global_transform.basis.get_rotation_quaternion()
	_visual.transform = Transform3D(Basis(bq.inverse() * _rb_corr_rot * bq), global_transform.basis.inverse() * _rb_corr)
	_rb_log_stats(delta)


# ---- البداية: الـ host بيستنى hello من الـ client، يبعت go، وهو يبدأ بعدها بنص الـ ping عشان الاتنين يبدأوا مع بعض ----
func _rb_try_start() -> void:
	var now: int = Time.get_ticks_msec()
	var peer: int = _find_peer()
	if GDSync.is_host():
		if not _rb_go_sent:
			if _rb_peer_hello and peer >= 0:
				GDSync.call_func_on(peer, _rx_go)
				_rb_go_sent = true
				_rb_start_at_ms = now + roundi(clampf(SessionMode.last_ping_ms, 0.0, 600.0) * 0.5)
			elif now - _rb_wait_start_ms > 8000:
				_rb_go_sent = true
				_rb_start_at_ms = now
				DebugLog.say("RB", "مفيش client رد - بدأت لوحدي")
		if _rb_go_sent and now >= _rb_start_at_ms:
			_rb_begin()
	else:
		if peer >= 0 and now - _rb_hello_ms > 250:
			_rb_hello_ms = now
			GDSync.call_func_on_unreliable(peer, _rx_hello)
		if _rb_got_go or now - _rb_wait_start_ms > 15000:
			_rb_begin()


func _rb_begin() -> void:
	_rb_started = true
	_tick = 0
	for k in rb_input_delay: # أول ticks قبل ما المدخلات المتأخرة توصل
		_rb_local[k % RB_HIST] = Vector4.ZERO
		_rb_local_tag[k % RB_HIST] = k
	DebugLog.say("RB", "بدأت المحاكاة (tick 0)")


## أمان: بنقبل الرسائل من لاعب جوه الـ lobby بس (مش من غريب بعت لنفس الـ client id)
func _rb_sender_ok() -> bool:
	var sender: int = GDSync.get_sender_id()
	return sender < 0 or sender == GDSync.get_client_id() or sender in GDSync.lobby_get_all_clients()


## لو الطرف التاني خرج أكتر من 3 ثواني نرجع للقائمة بدل ما اللعبة تفضل متجمّدة
func _rb_check_peer() -> void:
	var now: int = Time.get_ticks_msec()
	if _find_peer() >= 0:
		_rb_had_peer = true
		_rb_peer_lost_ms = 0
		return
	if not _rb_had_peer:
		return
	if _rb_peer_lost_ms == 0:
		_rb_peer_lost_ms = now
		DebugLog.say("RB", "الطرف التاني خرج")
	elif now - _rb_peer_lost_ms > 3000:
		_leave_to_menu()


func _rx_hello() -> void:
	if not _rb_sender_ok():
		return
	if GDSync.is_host():
		_rb_peer_hello = true


func _rx_go() -> void:
	if not GDSync.is_host():
		_rb_got_go = true


# ---- tick واحد ----
func _rb_sample_local() -> Vector4:
	if _role == ControlRole.STEER_BRAKE:
		return Vector4(snappedf(Input.get_axis(&"move_right", &"move_left"), 0.1),
			1.0 if Input.is_action_pressed(&"move_back") else 0.0, 0.0, 0.0)
	return Vector4(0.0, 0.0, snappedf(Input.get_action_strength(&"move_forward"), 0.1),
		1.0 if Input.is_action_just_pressed(&"jump") else 0.0)


func _rb_remote_for(t: int) -> Vector4:
	var idx: int = t % RB_HIST
	if _rb_remote_tag[idx] == t:
		return _rb_remote[idx]
	if _rb_remote_latest < 0 or t - _rb_remote_latest > rb_remote_timeout_ticks:
		return Vector4.ZERO
	var v: Vector4 = _rb_remote_last
	v.w = 0.0 # القفز عمره ما بيتتوقّع
	return v


func _rb_live_tick() -> void:
	var t: int = _tick
	var fut: int = t + rb_input_delay
	_rb_local[fut % RB_HIST] = _rb_sample_local() # بتتطبّق بعد rb_input_delay tick
	_rb_local_tag[fut % RB_HIST] = fut
	_rb_save_state(t)
	_rb_run_tick(t, false)
	_tick += 1
	if _rb_teleported:
		_rb_teleported = false
		reset_physics_interpolation()
	if t % 120 == 0:
		for k: int in _rb_events.keys():
			if k < _tick - RB_HIST:
				_rb_events.erase(k)



func _rb_run_tick(t: int, resim: bool) -> void:
	_rb_resim = resim
	var idx: int = t % RB_HIST
	if _rb_events.has(t):
		var ev: Array = _rb_events[t]
		_rb_apply_event(ev[0] as Vector3, ev[1] as float, resim)
	var inp: Vector4 = _rb_local[idx] + _rb_remote_for(t)
	_rb_used[idx] = inp
	if inp.w > 0.5:
		_jump_buffer = 0.25
	var wants_recover: bool = _control_step(_dt, inp.x, inp.y > 0.5, clampf(inp.z, 0.0, 1.0), true)
	if wants_recover and not resim and GDSync.is_host():
		var yaw: float = atan2(-_heading.x, -_heading.z)
		_rb_post_event(t + 1, _ds.transform.origin + Vector3.UP * 0.4, yaw)
	_rapier.space_step(_space, _dt)
	_rapier.space_flush_queries(_space)
	if not resim and GDSync.is_host() and _ds.transform.origin.y < fall_limit:
		_rb_post_event(t + 1, _spawn_transform.origin, _spawn_transform.basis.get_euler().y)
	_rb_resim = false


func _rb_apply_event(origin: Vector3, yaw: float, resim: bool) -> void:
	var b := Basis(Vector3.UP, yaw)
	_ds.transform = Transform3D(b, origin)
	_ds.linear_velocity = Vector3.ZERO
	_ds.angular_velocity = Vector3.ZERO
	_fallen_time = 0.0
	_is_fallen = false
	_jump_buffer = 0.0
	var flat: Vector3 = -b.z
	flat.y = 0.0
	_heading = flat.normalized()
	if not resim:
		_cam_yaw = yaw
		_rb_corr = Vector3.ZERO
		_rb_corr_rot = Quaternion.IDENTITY
		_rb_teleported = true
		DebugLog.say("RB", "reset event عند %s" % origin)


func _rb_post_event(t: int, origin: Vector3, yaw: float) -> void:
	_rb_events[t] = [origin, yaw]
	var peer: int = _find_peer()
	if peer >= 0:
		GDSync.call_func_on(peer, _rx_event, t, origin, yaw)


func _rx_event(t: int, origin: Vector3, yaw: float) -> void:
	if not _rb or GDSync.is_host() or t < 0 or not origin.is_finite() or not is_finite(yaw):
		return
	if _rb_events.has(t):
		return
	_rb_events[t] = [origin, yaw]
	if _rb_started and t < _tick:
		_rb_mark(t)


# ---- الحالة ----
func _rb_pack() -> PackedFloat64Array:
	var xf: Transform3D = _ds.transform
	var q: Quaternion = xf.basis.get_rotation_quaternion()
	var lv: Vector3 = _ds.linear_velocity
	var av: Vector3 = _ds.angular_velocity
	return PackedFloat64Array([
		xf.origin.x, xf.origin.y, xf.origin.z, q.x, q.y, q.z, q.w,
		lv.x, lv.y, lv.z, av.x, av.y, av.z,
		_gas_smooth, _steer_smooth, _jump_buffer, _no_ground_timer, _fallen_time,
		1.0 if _is_fallen else 0.0, _heading.x, _heading.y, _heading.z])


func _rb_save_state(t: int) -> void:
	_rb_states[t % RB_HIST] = _rb_pack()
	_rb_state_tag[t % RB_HIST] = t


func _rb_load_state(st: PackedFloat64Array) -> void:
	var q := Quaternion(st[3], st[4], st[5], st[6]).normalized()
	_ds.transform = Transform3D(Basis(q), Vector3(st[0], st[1], st[2]))
	_ds.linear_velocity = Vector3(st[7], st[8], st[9])
	_ds.angular_velocity = Vector3(st[10], st[11], st[12])
	_gas_smooth = st[13]
	_steer_smooth = st[14]
	_jump_buffer = st[15]
	_no_ground_timer = st[16]
	_fallen_time = st[17]
	_is_fallen = st[18] > 0.5
	_heading = Vector3(st[19], st[20], st[21])


func _rb_mark(t: int) -> void:
	_rb_from = t if _rb_from < 0 else mini(_rb_from, t)


# ---- rollback + إعادة محاكاة ----
func _rb_do_rollback() -> void:
	if _rb_from < 0:
		return
	var from: int = maxi(_rb_from, _tick - rb_max_rollback)
	_rb_from = -1
	if from >= _tick or from < 0 or _rb_state_tag[from % RB_HIST] != from:
		return
	var before: Vector3 = _ds.transform.origin
	var before_q: Quaternion = _ds.transform.basis.get_rotation_quaternion()
	_rb_load_state(_rb_states[from % RB_HIST] as PackedFloat64Array)
	for t in range(from, _tick):
		_rb_save_state(t)
		_rb_run_tick(t, true)
	var jump_err: Vector3 = before - _ds.transform.origin
	_rb_corr_rot = (_rb_corr_rot * before_q * _ds.transform.basis.get_rotation_quaternion().inverse()).normalized()
	if jump_err.length() > 0.4:
		DebugLog.say("RB", "قفزة تصحيح %.2fm | عمق=%d tick | y قبل=%.2f بعد=%.2f" % [
			jump_err.length(), _tick - from, before.y, _ds.transform.origin.y])
	# الشكل بس: لو القفزة كبيرة نعرضها فورًا (أأمن من الانزلاق جوه الأرض)، وما ننزلش تحت الجسم الحقيقي أكتر من 25سم
	_rb_corr += jump_err
	if _rb_corr.length() > 1.0:
		_rb_corr = Vector3.ZERO
		_rb_corr_rot = Quaternion.IDENTITY
	_rb_corr.y = maxf(_rb_corr.y, -0.25)
	_rb_stat_rollbacks += 1
	_rb_stat_resim_ticks += _tick - from


# ---- نقل المدخلات ----
func _rb_send_inputs() -> void:
	var t: int = _tick - 1 + rb_input_delay
	if t < 0 or (t - rb_input_delay) % rb_send_every != 0:
		return
	var peer: int = _find_peer()
	if peer < 0:
		return
	var first: int = maxi(0, t - rb_send_window + 1)
	var data := PackedFloat32Array()
	var host: bool = GDSync.is_host()
	for k in range(first, t + 1):
		var v: Vector4 = _rb_local[k % RB_HIST]
		data.append(v.x if host else v.z)
		data.append(v.y if host else v.w)
	GDSync.call_func_on_unreliable(peer, _rx_inputs, first, data)


func _rb_rate_ok() -> bool:
	var now: int = Time.get_ticks_msec()
	if now - _rb_in_window_start_ms >= 1000:
		_rb_in_window_start_ms = now
		_rb_in_count = 0
	_rb_in_count += 1
	if _rb_in_count > 80: # الطبيعي 30/ث
		_rb_stat_dropped += 1
		return false
	return true


func _rx_inputs(first: int, data: PackedFloat32Array) -> void:
	if not _rb or not _rb_sender_ok() or not _rb_rate_ok():
		return
	if first < 0 or data.size() < 2 or data.size() > 128 or data.size() % 2 != 0:
		return
	var host: bool = GDSync.is_host()
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
			v = Vector4(0.0, 0.0, clampf(a, 0.0, 1.0), 1.0 if b > 0.5 else 0.0)
		else:
			v = Vector4(clampf(a, -1.0, 1.0), 1.0 if b > 0.5 else 0.0, 0.0, 0.0)
		_rb_remote[idx] = v
		_rb_remote_tag[idx] = k
		if k > _rb_remote_latest:
			_rb_remote_latest = k
			_rb_remote_last = v
		if _rb_started and k < _tick and _rb_local_tag[idx] == k:
			var d: Vector4 = (_rb_local[idx] + v) - _rb_used[idx]
			if absf(d.x) + absf(d.y) + absf(d.z) + absf(d.w) > 0.01:
				_rb_mark(k)
	var guard: int = 0
	while guard < RB_HIST and _rb_remote_tag[(_rb_confirmed + 1) % RB_HIST] == _rb_confirmed + 1:
		_rb_confirmed += 1
		guard += 1


# ---- تصحيح الـ host (authoritative) ----
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
			continue # لسه ما وصلناش للـ tick ده
		if _tick - t > rb_max_rollback:
			_rb_auth_pending.erase(t)
			continue
		if t > _rb_confirmed:
			continue # مدخلات الـ host لحد الـ tick ده لسه ما وصلتش كلها
		var auth: PackedFloat64Array = _rb_auth_pending[t]
		_rb_auth_pending.erase(t)
		if _rb_state_tag[t % RB_HIST] != t:
			continue
		var mine: PackedFloat64Array = _rb_states[t % RB_HIST]
		var dp: float = Vector3(auth[0] - mine[0], auth[1] - mine[1], auth[2] - mine[2]).length()
		var dv: float = Vector3(auth[7] - mine[7], auth[8] - mine[8], auth[9] - mine[9]).length()
		_err_sum += dp
		_err_n += 1
		if dp > 0.3:
			DebugLog.say("RB", "تصحيح كبير من الـ host: %.2fm (tick %d)" % [dp, t])
		if dp > rb_auth_tolerance or dv > 0.5:
			_rb_states[t % RB_HIST] = auth
			_rb_mark(t)
			_rb_stat_corrections += 1


func _rb_log_stats(delta: float) -> void:
	_stats_timer += delta
	if _stats_timer < 5.0:
		return
	DebugLog.say("RB", "tick=%d | rollbacks %.1f/ث (عمق متوسط %.1f tick) | تصحيحات الـ host=%d | خطأ متوسط %.3fm | فرق المدخلات=%d tick | مرفوض=%d" % [
		_tick, _rb_stat_rollbacks / _stats_timer,
		float(_rb_stat_resim_ticks) / maxf(float(_rb_stat_rollbacks), 1.0),
		_rb_stat_corrections, _err_sum / maxf(float(_err_n), 1.0),
		_tick - _rb_remote_latest, _rb_stat_dropped])
	_stats_timer = 0.0
	_rb_stat_rollbacks = 0
	_rb_stat_resim_ticks = 0
	_rb_stat_corrections = 0
	_rb_stat_dropped = 0
	_err_sum = 0.0
	_err_n = 0
