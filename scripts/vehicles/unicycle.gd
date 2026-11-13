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
## الـ host بيعلن حالته (net_position / net_rotation) عن طريق PropertySynchronizer بتردد منخفض،
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
@export var heartbeat: float = 0.1 # الـ client بيكرر البنزين كل كام ثانية طول ما هو ضاغط
@export var min_send_interval: float = 0.05 # أقل فاصل بين إرسالتين بنزين من الـ client (20/ث كحد أقصى)
@export var net_smooth_speed: float = 18.0 # سرعة اقتراب الـ client من هدف الـ host (أعلى = أحدّ)
@export var net_snap_distance: float = 4.0 # لو الفرق أكبر من كده (respawn / أول اتصال) بننقل فورًا
@export_subgroup("Server rate limit")
@export var min_gas_interval: float = 0.02 # الـ host يتجاهل أي بنزين أسرع من كده (الـ client الطبيعي 0.05)
@export var min_jump_interval: float = 0.1 # الـ host يتجاهل أي قفزة أسرع من كده

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
var _steer_smooth: float = 0.0
var _no_ground_timer: float = 0.0 # بعد القفز نتجاهل الأرض لحظة
var _fallen_time: float = 0.0
var _is_fallen: bool = false
var _heading: Vector3 = Vector3.FORWARD
var _spawn_transform: Transform3D

# حالة الـ host اللي بتتزامن (PropertySynchronizer). الـ client بيعاملها كهدف بس.
# (دول بدل global_position / quaternion اللي كانوا بيتزامنوا قبل كده)
var net_position: Vector3 = Vector3.ZERO
var net_rotation: Quaternion = Quaternion.IDENTITY

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
	# الـ spawner بيشيل الـ PropertySynchronizer قبل ما يضيفنا لو أوفلاين
	_online = not SessionMode.offline and GDSync.is_active()
	_simulates = (not _online) or GDSync.is_host()
	if not _online:
		_role = ControlRole.ALL
	else:
		_role = ControlRole.STEER_BRAKE if GDSync.is_host() else ControlRole.GAS_JUMP
		# المدخلات بس، والمنادي لازم يكون client (الـ host مالوش يبعت لنفسه)
		GDSync.expose_func(_receive_gas, ENUMS.EXPOSE_PERMISSION.CLIENT)
		GDSync.expose_func(_receive_jump, ENUMS.EXPOSE_PERMISSION.CLIENT)

	if not _simulates:
		# عند الـ client: الجسم مش frozen. مفيش قوى بتحرّكه (الجاذبية متعطلة والسرعات بتتصفّر)،
		# والمكان بيتحرك بـ lerp ناحية هدف الـ host في _physics_process.
		freeze = false
		gravity_scale = 0.0
		# شبح: مالوش تصادم، فالـ lerp ناحية الهدف ما يتخانقش مع الأرض أو أي جسم
		collision_layer = 0
		collision_mask = 0

	_ensure_input_actions()
	_log_setup()
	_spawn_transform = global_transform
	_last_pos = global_position
	# الهدف المبدئي عند الـ client = مكان الإنشاء (لحد ما أول حزمة توصل)
	net_position = global_position
	net_rotation = global_transform.basis.get_rotation_quaternion()
	_cam_yaw = global_rotation.y
	_model.rotation_degrees.y = model_yaw_degrees

	_camera_rig.top_level = true
	# الكاميرا بتتحرك في _process وبتاخد الموقع من get_global_transform_interpolated()، فمتتعملش interpolation تاني
	_camera_rig.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_camera_rig.global_position = global_position + Vector3.UP
	_camera_rig.rotation = Vector3(0.0, _cam_yaw, 0.0)
	_camera.make_current()


# طباعة تأكيد إن كل حاجة اتحمّلت صح (مفيدة لو الموديل ما ظهرش أو الشبكة مش شغالة)
func _log_setup() -> void:
	var frame_meshes: int = get_node("Visual/Model/Frame").find_children("*", "MeshInstance3D", true, false).size()
	var wheel_meshes: int = _wheel_pivot.find_children("*", "MeshInstance3D", true, false).size()
	var sync: Node = get_node_or_null("PropertySynchronizer")
	DebugLog.say("UNI", "online=%s simulates=%s role=%d sync=%s pos=%s" % [
		_online, _simulates, _role, sync != null, global_position])
	DebugLog.say("UNI", "meshes: frame=%d wheel=%d (0 = الموديل ما اتعملوش import)" % [frame_meshes, wheel_meshes])
	if _online:
		DebugLog.say("UNI", "client_id=%d host=%s host_id=%d" % [GDSync.get_client_id(), GDSync.is_host(), GDSync.get_host()])


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
	_update_motion_visuals(delta)
	if not _simulates:
		_follow_server_state(delta)
		_send_client_input(delta)
		return
	_publish_state()

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
				_gas_timed_out = false
			elif _remote_gas > 0.0 and not _gas_timed_out:
				_gas_timed_out = true # البنزين وقف يوصل (ضغط الـ client اتأخر أو الشبكة وقعت)
				DebugLog.say("NET", "gas timeout: مفيش تحديث من %.2fs" % (now - _remote_gas_time))
		_:
			pass

	_steer_smooth = move_toward(_steer_smooth, steer, steer_response * delta)
	steer = _steer_smooth

	_jump_buffer = maxf(_jump_buffer - delta, 0.0)
	_no_ground_timer = maxf(_no_ground_timer - delta, 0.0)

	var basis_up: Vector3 = global_transform.basis.y
	var tilt: float = acos(clampf(basis_up.dot(Vector3.UP), -1.0, 1.0))
	var was_fallen: bool = _is_fallen
	_is_fallen = tilt > deg_to_rad(fall_tilt_degrees)
	if _is_fallen and not was_fallen:
		DebugLog.say("UNI", "وقعت (tilt=%d°)" % roundi(rad_to_deg(tilt)))

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
			DebugLog.say("UNI", "jump (speed=%.1f)" % vf)

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
	DebugLog.say("UNI", "رجعت واقفة")
	var yaw: float = atan2(-_heading.x, -_heading.z)
	_reset_to(Transform3D(Basis(Vector3.UP, yaw), global_position + Vector3.UP * 0.4))


# نقطة الرجوع لما الدراجة تقع (بتتنادى من checkpoint.gd)
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
	reset_physics_interpolation() # الشاشة ما تعملش interpolation من المكان القديم
	_publish_state() # الهدف الجديد يتبعت فورًا؛ والـ client بينقل فورًا لو الفرق كبير


# ---------------------------------------------------------------- الـ client
# العميل بيبعت المدخلات بس (بنزين / قفز). مفيش أي إرسال لمكان أو سرعة أو حالة الدراجة.
func _send_client_input(delta: float) -> void:
	if _role != ControlRole.GAS_JUMP:
		return
	var gas: float = snappedf(Input.get_action_strength(&"move_forward"), 0.1)
	_heartbeat_timer += delta
	_send_cooldown = maxf(_send_cooldown - delta, 0.0)
	var changed: bool = not is_equal_approx(gas, _last_sent_gas)
	if changed:
		_zero_repeat_time = 0.4 # لو اتسابت القيمة صفر، نكررها شوية عشان لو ضاعت حزمة
	_zero_repeat_time = maxf(_zero_repeat_time - delta, 0.0)
	# unreliable: لو حزمة ضاعت ما بتتعادش (بتعمل تأخير)، والتكرار بيعوّضها.
	# _send_cooldown بيحدّ التردد (لو التغيير اتأجل، بيتبعت أول ما الفاصل يخلص لأن _last_sent_gas ما اتغيرش)
	if _send_cooldown <= 0.0 and (changed or ((gas > 0.0 or _zero_repeat_time > 0.0) and _heartbeat_timer >= heartbeat)):
		_last_sent_gas = gas
		_heartbeat_timer = 0.0
		_send_cooldown = min_send_interval
		if changed:
			DebugLog.say("NET", "gas بعت %.1f" % gas)
		GDSync.call_func_on_unreliable(GDSync.get_host(), _receive_gas, gas)
	if Input.is_action_just_pressed(&"jump"):
		GDSync.call_func_on(GDSync.get_host(), _receive_jump) # reliable: القفزة مهمة


# بتتنفذ عند الـ host بس. بيتحقق من النوع والمدى والتردد قبل ما يستخدم القيمة.
func _receive_gas(value: float) -> void:
	if not GDSync.is_host():
		return
	if not _accept_rpc_rate(true):
		return
	if not is_finite(value): # NaN / inf
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
	_jump_buffer = 0.25 # أطول شوية من القفز المحلي، عشان القفزة اللي وصلت متأخرة ما تضيعش


# تحقق تردد RPC عند الـ host: أي طلب أسرع من الحد بيتجاهل (بيحمي من الـ spam)
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


# ---------------------------------------------------------------- حالة الشبكة (host -> client)
# الـ host بيكتب حالته في خصائص net_* والـ PropertySynchronizer بيبعتها بتردد منخفض (refresh_rate)
func _publish_state() -> void:
	if not _online:
		return
	net_position = global_position
	net_rotation = global_transform.basis.get_rotation_quaternion()


# الـ client: بيقرّب بسلاسة من الهدف اللي بعته الـ host بدل القفز الفوري
func _follow_server_state(delta: float) -> void:
	if not net_position.is_finite() or not net_rotation.is_finite() or net_rotation.length_squared() < 0.5:
		return # قيمة تالفة من الشبكة: نتجاهلها
	var target_rot: Quaternion = net_rotation.normalized() # الشبكة ممكن تفقد دقة بسيطة
	var current: Transform3D = global_transform
	if current.origin.distance_to(net_position) > net_snap_distance:
		global_transform = Transform3D(Basis(target_rot), net_position) # respawn / أول اتصال
		reset_physics_interpolation()
	else:
		var weight: float = 1.0 - exp(-net_smooth_speed * delta)
		var new_pos: Vector3 = current.origin.lerp(net_position, weight)
		var new_rot: Quaternion = current.basis.get_rotation_quaternion().slerp(target_rot, weight)
		global_transform = Transform3D(Basis(new_rot), new_pos)
	# الـ client مفيش عنده فيزيكس حقيقية للدراجة: نمنع أي سرعة تتراكم
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO


# سرعة العرض ولفّة العجلة. في _physics_process عشان العجلة جزء من الجسم اللي عليه interpolation
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
	if raw_speed > 80.0: # قفزة (respawn / snap)
		raw_speed = 0.0
	_vis_speed = lerpf(_vis_speed, raw_speed, 1.0 - exp(-10.0 * delta))


# ---------------------------------------------------------------- الكاميرا والشاشة
func _process(delta: float) -> void:
	if delta <= 0.0:
		return

	# الكاميرا بتقرا الموقع من الـ transform المتنعّم (Physics Interpolation) مش من global_position
	var visual_xf: Transform3D = get_global_transform_interpolated()

	# الكاميرا بتتبع اتجاه الدراجة (من غير ما تتلخبط وهي بتتشقلب)
	var flat_forward: Vector3 = -visual_xf.basis.z
	flat_forward.y = 0.0
	if flat_forward.length() > 0.4:
		var yaw: float = atan2(-flat_forward.x, -flat_forward.z)
		_cam_yaw = lerp_angle(_cam_yaw, yaw, 1.0 - exp(-camera_yaw_speed * delta))
	_camera_rig.rotation.y = _cam_yaw
	var target: Vector3 = visual_xf.origin + Vector3.UP
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
