class_name TestPlayer
extends CharacterBody3D
## لاعب اختبار بسيط (كبسولة). المالك فقط يحاكي الحركة؛ اللاعب البعيد يتحرك عبر PlayerSync.
## التحكم: W/A/S/D أو الأسهم للحركة، Space للقفز، T = "غش" تجريبي (يختبر رفض Host).
## يستخدم قراءة مفاتيح مباشرة، فلا يحتاج Input Map.

const MOVE_SPEED: float = 6.0
const ACCEL: float = 30.0
const JUMP_VELOCITY: float = 6.0
const GRAVITY: float = 18.0
const TURN_SPEED: float = 12.0
const CHEAT_DISTANCE: float = 80.0
const STATE_NAMES: Array[String] = ["idle", "moving", "air"]

var peer_id: int = 0
var is_local: bool = false
var _t_was_down: bool = false

@onready var _sync: PlayerSync = $PlayerSync
@onready var _name_tag: Label3D = $NameTag
@onready var _mesh: MeshInstance3D = $MeshInstance3D

## قبل add_child.
func setup(id: int, local: bool) -> void:
	peer_id = id
	is_local = local

func _ready() -> void:
	_sync.setup(peer_id)
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = Color(0.2, 0.5, 1.0) if is_local else Color(1.0, 0.55, 0.1)
	_mesh.material_override = mat
	if not is_local:
		set_physics_process(false)  # اللاعب البعيد لا يحاكي فيزياء ولا يقرأ Input
	_update_tag()

func _process(_delta: float) -> void:
	_update_tag()

func _update_tag() -> void:
	var state: int = get_sync_state() if is_local else _sync.remote_state
	var who: String = "Peer %d (You)" % peer_id if is_local else "Peer %d" % peer_id
	_name_tag.text = "%s [%s]" % [who, STATE_NAMES[clampi(state, 0, STATE_NAMES.size() - 1)]]

func get_sync_state() -> int:
	if not is_on_floor():
		return PlayerSync.STATE_AIRBORNE
	if Vector2(velocity.x, velocity.z).length() > 0.2:
		return PlayerSync.STATE_MOVING
	return PlayerSync.STATE_IDLE

func _physics_process(delta: float) -> void:
	var input: Vector2 = _read_input()
	var dir: Vector3 = Vector3(input.x, 0.0, input.y)
	if dir.length() > 0.0:
		dir = dir.normalized()
	velocity.x = move_toward(velocity.x, dir.x * MOVE_SPEED, ACCEL * delta)
	velocity.z = move_toward(velocity.z, dir.z * MOVE_SPEED, ACCEL * delta)
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	elif _has_focus() and Input.is_physical_key_pressed(KEY_SPACE):
		velocity.y = JUMP_VELOCITY
	move_and_slide()
	if dir.length() > 0.0:
		var target_yaw: float = atan2(-dir.x, -dir.z)
		rotation.y = lerp_angle(rotation.y, target_yaw, clampf(TURN_SPEED * delta, 0.0, 1.0))
	_handle_debug_cheat()

func _has_focus() -> bool:
	return get_window().has_focus()

func _read_input() -> Vector2:
	var v: Vector2 = Vector2.ZERO
	if not _has_focus():
		return v
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP):
		v.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN):
		v.y += 1.0
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
		v.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
		v.x += 1.0
	return v

## اختبار يدوي: T يقفز بصاحبه 80م فجأة. على Client يجب أن يرفضها Host ثم يصحّحه.
func _handle_debug_cheat() -> void:
	var down: bool = _has_focus() and Input.is_physical_key_pressed(KEY_T)
	if down and not _t_was_down:
		global_position += Vector3(CHEAT_DISTANCE, 0.0, 0.0)
	_t_was_down = down
