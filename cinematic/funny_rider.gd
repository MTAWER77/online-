extends Node3D
## Procedural funny sit / run / jump / panic for character.glb (no baked animations).

var _skel: Skeleton3D
var _mode: String = "sit"
var _t: float = 0.0
var _speed: float = 1.0
var _base_pose: Dictionary = {}
var _bone: Dictionary = {}

const ROOT := "Bone"
const SPINE := "Bone.001"
const CHEST := "Bone.002"
const NECK := "Bone.003"
const HEAD := "head"
const ARM_L := ["Bone.005.L", "Bone.006.L", "Bone.007.L", "Bone.008.L"]
const ARM_R := ["Bone.005.R", "Bone.006.R", "Bone.007.R", "Bone.008.R"]
const LEG_L := ["Bone.009.L", "Bone.010.L", "Bone.011.L", "Bone.012.L"]
const LEG_R := ["Bone.009.R", "Bone.010.R", "Bone.011.R", "Bone.012.R"]

func _ready() -> void:
	_find_skel()
	if _skel == null:
		return
	for i in range(_skel.get_bone_count()):
		var n := _skel.get_bone_name(i)
		_bone[n] = i
		_base_pose[i] = _skel.get_bone_rest(i)
	_mode = "sit"
	_apply_sit(0.0)

func _find_skel() -> void:
	var found := find_children("*", "Skeleton3D", true, false)
	if found.size() > 0:
		_skel = found[0] as Skeleton3D

func play_clip(clip: String, speed: float = 1.0) -> void:
	_speed = speed
	var c := clip.to_lower()
	if c in ["run", "pushcart", "walk"]:
		_mode = "run"
	elif c in ["jump", "hop", "bounce"]:
		_mode = "jump"
	elif c in ["sit", "idle"]:
		_mode = "sit"
	elif c in ["panic", "wave", "flail"]:
		_mode = "panic"
	else:
		_mode = "run"

func set_speed(speed: float) -> void:
	_speed = speed

func _process(delta: float) -> void:
	if _skel == null:
		return
	_t += delta * _speed
	match _mode:
		"sit":
			_apply_sit(_t)
		"run":
			_apply_run(_t)
		"jump":
			_apply_jump(_t)
		"panic":
			_apply_panic(_t)

func _set_bone_rot(name: String, euler: Vector3) -> void:
	if not _bone.has(name):
		return
	var i: int = _bone[name]
	var rest: Transform3D = _base_pose[i]
	var q := (rest.basis * Basis.from_euler(euler)).get_rotation_quaternion()
	_skel.set_bone_pose_rotation(i, q)

func _set_bone_pos(name: String, offset: Vector3) -> void:
	if not _bone.has(name):
		return
	var i: int = _bone[name]
	var rest: Transform3D = _base_pose[i]
	_skel.set_bone_pose_position(i, rest.origin + offset)

func _apply_sit(t: float) -> void:
	var bob := sin(t * 2.5) * 0.02
	_set_bone_pos(ROOT, Vector3(0.0, bob, 0.0))
	_set_bone_rot(SPINE, Vector3(0.35, 0.0, 0.0))
	_set_bone_rot(CHEST, Vector3(0.15, 0.0, 0.0))
	_set_bone_rot(NECK, Vector3(-0.1, 0.0, 0.0))
	_set_bone_rot(HEAD, Vector3(-0.05 + sin(t * 1.7) * 0.05, sin(t * 0.9) * 0.08, 0.0))
	_set_bone_rot(ARM_L[0], Vector3(0.6, 0.2, 0.4))
	_set_bone_rot(ARM_L[1], Vector3(0.3, 0.0, 0.0))
	_set_bone_rot(ARM_R[0], Vector3(0.6, -0.2, -0.4))
	_set_bone_rot(ARM_R[1], Vector3(0.3, 0.0, 0.0))
	_set_bone_rot(LEG_L[0], Vector3(-1.1, 0.1, 0.15))
	_set_bone_rot(LEG_L[1], Vector3(1.4, 0.0, 0.0))
	_set_bone_rot(LEG_R[0], Vector3(-1.1, -0.1, -0.15))
	_set_bone_rot(LEG_R[1], Vector3(1.4, 0.0, 0.0))

func _apply_run(t: float) -> void:
	var phase := t * 8.0
	var bounce := abs(sin(phase)) * 0.12
	_set_bone_pos(ROOT, Vector3(sin(phase * 0.5) * 0.04, bounce, 0.0))
	_set_bone_rot(ROOT, Vector3(0.05, sin(phase * 0.5) * 0.08, sin(phase) * 0.06))
	_set_bone_rot(SPINE, Vector3(0.25 + sin(phase) * 0.08, 0.0, 0.0))
	_set_bone_rot(CHEST, Vector3(0.1, sin(phase) * 0.12, 0.0))
	_set_bone_rot(NECK, Vector3(-0.15, 0.0, 0.0))
	_set_bone_rot(HEAD, Vector3(-0.1 + sin(phase * 1.3) * 0.12, sin(phase * 0.7) * 0.2, sin(phase) * 0.1))
	var a := sin(phase) * 1.1
	var a2 := sin(phase + PI) * 1.1
	_set_bone_rot(ARM_L[0], Vector3(a, 0.15, 0.35))
	_set_bone_rot(ARM_L[1], Vector3(0.4 + abs(a) * 0.3, 0.0, 0.0))
	_set_bone_rot(ARM_R[0], Vector3(a2, -0.15, -0.35))
	_set_bone_rot(ARM_R[1], Vector3(0.4 + abs(a2) * 0.3, 0.0, 0.0))
	_set_bone_rot(LEG_L[0], Vector3(-0.3 + a2 * 0.9, 0.05, 0.08))
	_set_bone_rot(LEG_L[1], Vector3(0.6 + max(-a2, 0.0) * 0.9, 0.0, 0.0))
	_set_bone_rot(LEG_R[0], Vector3(-0.3 + a * 0.9, -0.05, -0.08))
	_set_bone_rot(LEG_R[1], Vector3(0.6 + max(-a, 0.0) * 0.9, 0.0, 0.0))

func _apply_jump(t: float) -> void:
	var phase := t * 6.0
	var hop := max(sin(phase), 0.0)
	var hop2 := hop * hop
	_set_bone_pos(ROOT, Vector3(sin(phase * 0.5) * 0.05, hop2 * 0.28, 0.0))
	_set_bone_rot(ROOT, Vector3(-0.15 + hop * 0.2, 0.0, sin(phase) * 0.08))
	_set_bone_rot(SPINE, Vector3(0.4 - hop * 0.25, 0.0, 0.0))
	_set_bone_rot(CHEST, Vector3(0.15, sin(phase) * 0.1, 0.0))
	_set_bone_rot(HEAD, Vector3(-0.2 - hop * 0.15, sin(phase * 1.5) * 0.25, 0.0))
	_set_bone_rot(ARM_L[0], Vector3(-0.8 - hop * 0.9, 0.3, 0.5))
	_set_bone_rot(ARM_L[1], Vector3(0.2, 0.0, 0.0))
	_set_bone_rot(ARM_R[0], Vector3(-0.8 - hop * 0.9, -0.3, -0.5))
	_set_bone_rot(ARM_R[1], Vector3(0.2, 0.0, 0.0))
	_set_bone_rot(LEG_L[0], Vector3(-0.8 - hop * 0.6, 0.15, 0.1))
	_set_bone_rot(LEG_L[1], Vector3(1.2 - hop * 0.5, 0.0, 0.0))
	_set_bone_rot(LEG_R[0], Vector3(-0.8 - hop * 0.6, -0.15, -0.1))
	_set_bone_rot(LEG_R[1], Vector3(1.2 - hop * 0.5, 0.0, 0.0))

func _apply_panic(t: float) -> void:
	var phase := t * 12.0
	_set_bone_pos(ROOT, Vector3(sin(phase * 1.3) * 0.08, abs(sin(phase)) * 0.15, cos(phase * 0.9) * 0.04))
	_set_bone_rot(ROOT, Vector3(sin(phase) * 0.2, sin(phase * 0.7) * 0.25, cos(phase) * 0.15))
	_set_bone_rot(SPINE, Vector3(0.3 + sin(phase) * 0.2, 0.0, 0.0))
	_set_bone_rot(HEAD, Vector3(sin(phase * 1.7) * 0.4, sin(phase * 2.1) * 0.5, cos(phase) * 0.3))
	_set_bone_rot(ARM_L[0], Vector3(sin(phase) * 1.5, 0.4, 0.6))
	_set_bone_rot(ARM_L[1], Vector3(0.5 + abs(sin(phase)) * 0.8, 0.0, 0.0))
	_set_bone_rot(ARM_R[0], Vector3(sin(phase + 1.0) * 1.5, -0.4, -0.6))
	_set_bone_rot(ARM_R[1], Vector3(0.5 + abs(sin(phase + 1.0)) * 0.8, 0.0, 0.0))
	_set_bone_rot(LEG_L[0], Vector3(-0.5 + sin(phase + 0.5) * 0.8, 0.2, 0.15))
	_set_bone_rot(LEG_L[1], Vector3(0.8 + abs(sin(phase)) * 0.6, 0.0, 0.0))
	_set_bone_rot(LEG_R[0], Vector3(-0.5 + sin(phase + 2.0) * 0.8, -0.2, -0.15))
	_set_bone_rot(LEG_R[1], Vector3(0.8 + abs(sin(phase + 1.0)) * 0.6, 0.0, 0.0))
