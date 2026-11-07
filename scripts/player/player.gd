extends CharacterBody3D
## scripts/player/player.gd
## حركة لاعب Third Person. كل لاعب بيتحكم في لاعبه هو بس (owner)،
## واللاعبين التانيين بيتحركوا بالـ PropertySynchronizer (position بس).

@export_group("Movement")
@export var move_speed: float = 5.0
@export var acceleration: float = 14.0
@export var deceleration: float = 18.0
@export var jump_velocity: float = 4.8
@export var turn_speed: float = 12.0

@export_group("Camera")
@export var mouse_sensitivity: float = 0.003
@export var min_pitch_deg: float = -60.0 # الكاميرا فوق، بتبص لتحت
@export var max_pitch_deg: float = 30.0  # الكاميرا تحت، بتبص لفوق

@onready var camera_pivot: Node3D = $CameraPivot
@onready var spring_arm: SpringArm3D = $CameraPivot/SpringArm3D
@onready var camera: Camera3D = $CameraPivot/SpringArm3D/Camera3D
@onready var visual: Node3D = $Visual

var gravity: float = float(ProjectSettings.get_setting("physics/3d/default_gravity"))
var yaw: float = 0.0
var pitch: float = deg_to_rad(-15.0)

# -1 مش معروف لسه، 0 لاعب بعيد، 1 لاعبي أنا
var _locality: int = -1
var _last_position: Vector3 = Vector3.ZERO


func _ready() -> void:
	_ensure_input_actions()
	# الكاميرا ما تصطدمش بجسم اللاعب نفسه
	spring_arm.add_excluded_object(get_rid())
	spring_arm.rotation.x = pitch
	_last_position = global_position
	_refresh_locality()


# لو مفيش اتصال (تشغيل مشهد اللاعب لوحده) اللاعب دايمًا محلي
func _is_local() -> bool:
	return not GDSync.is_active() or GDSync.is_gdsync_owner(self)


# الـ owner بيتحدد بعد ما اللاعب يتعمل، فبنتأكد كل فريم
func _refresh_locality() -> void:
	var new_locality: int = 1 if _is_local() else 0
	if new_locality == _locality:
		return
	_locality = new_locality
	if _locality == 1:
		camera.make_current()
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		camera.clear_current(false) # كاميرا اللاعب البعيد ما تتفعلش عندي


func _unhandled_input(event: InputEvent) -> void:
	if _locality != 1:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var motion := event as InputEventMouseMotion
		yaw -= motion.relative.x * mouse_sensitivity
		pitch -= motion.relative.y * mouse_sensitivity
		pitch = clampf(pitch, deg_to_rad(min_pitch_deg), deg_to_rad(max_pitch_deg))
		camera_pivot.rotation.y = yaw
		spring_arm.rotation.x = pitch
	elif event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE # Esc يحرر الماوس
	elif event is InputEventMouseButton and event.pressed:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED # كليك يرجّع الماوس


func _physics_process(delta: float) -> void:
	_refresh_locality()
	if _locality != 1:
		_update_remote_facing(delta)
		return

	# جاذبية
	if not is_on_floor():
		velocity.y -= gravity * delta

	# قفز
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = jump_velocity

	# اتجاه الحركة نسبةً لاتجاه الكاميرا (yaw بس)
	var input_dir: Vector2 = Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var cam_basis := Basis(Vector3.UP, yaw)
	var direction: Vector3 = cam_basis * Vector3(input_dir.x, 0.0, input_dir.y)

	# تسارع وتباطؤ ناعم على المحور الأفقي
	var horizontal := Vector3(velocity.x, 0.0, velocity.z)
	if direction.length() > 0.01:
		horizontal = horizontal.move_toward(direction.normalized() * move_speed, acceleration * delta)
		_face_direction(direction, delta)
	else:
		horizontal = horizontal.move_toward(Vector3.ZERO, deceleration * delta)

	velocity.x = horizontal.x
	velocity.z = horizontal.z
	move_and_slide()


# اللاعب البعيد: الـ position بيوصل من الشبكة، والاتجاه بنحسبه من فرق الحركة
func _update_remote_facing(delta: float) -> void:
	var moved: Vector3 = global_position - _last_position
	_last_position = global_position
	moved.y = 0.0
	if moved.length() > 0.001:
		_face_direction(moved, delta)


func _face_direction(direction: Vector3, delta: float) -> void:
	var target_yaw: float = atan2(-direction.x, -direction.z)
	visual.rotation.y = lerp_angle(visual.rotation.y, target_yaw, turn_speed * delta)


# تسجيل الأزرار من الكود عشان ما نعدلش project.godot بإيدينا
func _ensure_input_actions() -> void:
	_add_key_action(&"move_forward", KEY_W)
	_add_key_action(&"move_back", KEY_S)
	_add_key_action(&"move_left", KEY_A)
	_add_key_action(&"move_right", KEY_D)
	_add_key_action(&"jump", KEY_SPACE)


func _add_key_action(action: StringName, keycode: Key) -> void:
	if InputMap.has_action(action):
		return
	InputMap.add_action(action)
	var ev := InputEventKey.new()
	ev.physical_keycode = keycode
	InputMap.action_add_event(action, ev)
