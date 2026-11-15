extends "res://scripts/vehicles/shopping_cart.gd"
## scripts/vehicles/shopping_cart_custom.gd
## 1) الموديلات الحقيقية بأسماء ملفاتك (كلهم في assets/models/):
##    العربية = shopping_cart.glb أو model.glb | علبة البيض = egg_carton.glb | البطيخ = watermelon.glb أو watermelon_lowpoly_free.glb
## 2) تزامن زي الدراجة القديمة (client_prediction): الـ client بيحاكي الفيزيكس محليًا بنزينه/فرامله فورًا،
##    ودركسيون الـ host بيجيله من الـ snapshots، وبيتصحّح ناحية حالة الـ host بالتدريج.
##    الـ host يفضل هو المرجع الوحيد (respawn / قلب / قفز). قفز الـ host بيتبعت للـ client كحدث.
## 3) استفزاز فيزيائي (Chaos): سحب لوحده، اهتزاز العجل مع السرعة، وتمايل الضهر عند الفرملة.
##    كله دوال في الوقت المشترك (NetClock) فبتطلع نفس الشكل عند الاتنين.

const CART_FILES: Array = ["res://assets/models/shopping_cart.glb", "res://assets/models/model.glb"]
const CARTON_FILES: Array = ["res://assets/models/egg_carton.glb"]
const MELON_FILES: Array = ["res://assets/models/watermelon.glb", "res://assets/models/watermelon_lowpoly_free.glb"]

@export var cart_yaw_degrees: float = 180.0 # الهاندل في موديلك ناحية -Z، فبنلفه 180 (لو طلعت بضهرها غيّرها لـ 0)
@export var basket_floor_y: float = 0.52 # ارتفاع أرضية السلة في الموديل

@export_group("Prediction")
@export var client_prediction: bool = true # false = يرجع لعرض الـ snapshots بس (interpolation)
@export var pred_pos_speed: float = 4.0 # سرعة تصحيح المكان ناحية الـ host (أعلى = أحدّ، أقل = أنعم)
@export var pred_rot_speed: float = 4.0
@export var pred_vel_speed: float = 3.0
@export var pred_snap_distance: float = 3.0 # فرق أكبر من كده = نقل فوري

@export_group("Chaos")
@export var pull_strength: float = 2.0 # العربية بتسحب يمين وشمال لوحدها (عجلة معوّجة)
@export var shimmy_strength: float = 6.0 # اهتزاز العجل الأمامي مع السرعة
@export var skid_strength: float = 5.0 # الفرملة على سرعة بتخلّي الضهر يتمايل


func _ready() -> void:
	cart_model_path = _first_existing(CART_FILES, cart_model_path)
	watermelon_model_path = _first_existing(MELON_FILES, watermelon_model_path)
	model_yaw_degrees = cart_yaw_degrees
	super()
	if _online:
		GDSync.expose_func(_receive_jump_event, ENUMS.EXPOSE_PERMISSION.HOST)
		if not _authoritative and client_prediction:
			freeze = false # الـ client بيحاكي محليًا زي الدراجة القديمة
			_delay_smooth = 0.0


func _first_existing(paths: Array, fallback: String) -> String:
	for p in paths:
		if ResourceLoader.exists(p as String):
			return p as String
	return fallback


# ---------------------------------------------------------------- تزامن (prediction + reconcile)

## الـ host: قفزته بتتبعت للـ client كحدث عشان العربية عنده تنط في نفس اللحظة تقريبًا
func _host_step(delta: float) -> void:
	if _online and Input.is_action_just_pressed(&"jump"):
		var peer: int = _find_peer()
		if peer >= 0:
			GDSync.call_func_on(peer, _receive_jump_event)
	super(delta)


func _receive_jump_event() -> void:
	if GDSync.is_host():
		return
	_jump_buffer = JUMP_BUFFER


## الـ client ما بيبعتش snapshots أبدًا (الـ host بس)
func _send_snapshot(delta: float, force: bool = false) -> void:
	if not _authoritative:
		return
	super(delta, force)


## respawn / قلب = قرار الـ host بس. الـ client بيستنى snapshot النقل.
func _respawn() -> void:
	if _authoritative:
		super()


func _recover() -> void:
	if _authoritative:
		super()


func _client_step(delta: float) -> void:
	if not client_prediction:
		super(delta)
		return
	if _role == ControlRole.GAS_BRAKE:
		_send_drive_input(delta)
	_predict_step(delta)
	_client_diag(delta)


func _predict_step(delta: float) -> void:
	if _buf.is_empty():
		return
	var s = _buf[_buf.size() - 1]
	if _teleport_pending:
		_teleport_pending = false
		global_transform = Transform3D(Basis(s.rot as Quaternion), s.pos as Vector3)
		linear_velocity = s.vel as Vector3
		angular_velocity = Vector3.ZERO
		_gas_smooth = 0.0
		_brake_smooth = 0.0
		reset_physics_interpolation()
		return
	var age: float = float(Time.get_ticks_msec() - _last_snap_ms) / 1000.0
	var gas: float = 0.0
	var brake: float = 0.0
	if _role == ControlRole.GAS_BRAKE:
		gas = Input.get_action_strength(&"move_forward")
		brake = Input.get_action_strength(&"move_back")
	var steer: float = float(s.steer) if age < 0.5 else 0.0 # دركسيون الـ host من آخر snapshot
	_control_step(delta, steer, brake, gas)
	_reconcile_to(s, age, delta)


func _reconcile_to(s, age: float, delta: float) -> void:
	var one_way: float = clampf(SessionMode.last_ping_ms, 0.0, 300.0) / 2000.0
	var lead: float = minf(age + one_way, max_extrapolation)
	var target: Vector3 = (s.pos as Vector3) + (s.vel as Vector3) * lead
	var err: Vector3 = target - global_position
	if err.length() > pred_snap_distance:
		global_transform = Transform3D(Basis(s.rot as Quaternion), target)
		linear_velocity = s.vel as Vector3
		angular_velocity = Vector3.ZERO
		reset_physics_interpolation()
		return
	var new_pos: Vector3 = global_position + err * (1.0 - exp(-pred_pos_speed * delta))
	var cur: Quaternion = global_transform.basis.get_rotation_quaternion()
	var new_rot: Quaternion = cur.slerp(s.rot as Quaternion, 1.0 - exp(-pred_rot_speed * delta))
	global_transform = Transform3D(Basis(new_rot), new_pos)
	linear_velocity = linear_velocity.lerp(s.vel as Vector3, 1.0 - exp(-pred_vel_speed * delta))


# ---------------------------------------------------------------- استفزاز فيزيائي

func _control_step(delta: float, steer: float, brake: float, gas: float) -> void:
	super(delta, steer, brake, gas)
	_apply_chaos(delta)


func _apply_chaos(delta: float) -> void:
	if _is_fallen or _coyote < coyote_time * 0.95:
		return # مقلوبة أو في الهوا
	var vf: float = linear_velocity.dot(-global_transform.basis.z)
	var sf: float = clampf(absf(vf) / max_speed, 0.0, 1.0)
	if sf < 0.05:
		return
	var t: float = NetClock.world_time()
	var pull: float = 0.7 * sin(t * 0.45) + 0.5 * sin(t * 1.13 + 1.7)
	var shimmy: float = sin(t * 14.0) * sf * sf
	var skid: float = sin(t * 6.0) * _brake_smooth * sf
	var av: Vector3 = angular_velocity
	av.y += (pull * pull_strength * sf + shimmy * shimmy_strength + skid * skid_strength) * delta
	angular_velocity = av


# ---------------------------------------------------------------- الموديلات

func _build_items() -> void:
	var carton: PackedScene = _try_load(_first_existing(CARTON_FILES, ""))
	if carton == null:
		super()
		return
	var root := Node3D.new()
	root.name = "Items"
	_model.add_child(root)
	# علبة البيض: ورا جنب الهاندل
	_make_item(root, Vector3(0.0, basket_floor_y + 0.11, 0.12), carton, 0.28, null, Vector3.ONE, null,
		200.0, 10.0, 0.0035, 0.03)
	# بطيختين جنب بعض قدام (الموديل لو موجود، غير كده كورة مخططة)
	var melon: PackedScene = _try_load(watermelon_model_path)
	var melon_mesh: SphereMesh = null
	var melon_mat: ShaderMaterial = null
	if melon == null:
		melon_mesh = SphereMesh.new()
		melon_mesh.radius = 0.18
		melon_mesh.height = 0.36
		melon_mat = _melon_material()
	for sx in [-0.135, 0.135]:
		_make_item(root, Vector3(float(sx), basket_floor_y + 0.13, -0.28), melon, 0.34, melon_mesh,
			Vector3(0.75, 0.7, 1.0), melon_mat, 140.0, 12.0, 0.002, 0.02)
