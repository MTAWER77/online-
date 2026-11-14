extends Node3D
## Spike: هل Rapier بيدّي نفس النتيجة بعد snapshot/restore (شرط الـ rollback)؟
## شغّل المشهد بعد ما تخلي Physics Engine = Rapier3D. مفيش تأثير على باقي اللعبة.

const DT: float = 1.0 / 120.0
const TICKS_A: int = 120      # قبل الـ snapshot
const TICKS_B: int = 240      # بعد الـ snapshot (فيها "input" عند tick 60)
const INPUT_TICK: int = 60

var _space: RID
var _ball: RID
var _label: Label
var _out: Array[String] = []


func _ready() -> void:
	_label = Label.new()
	_label.position = Vector2(20, 20)
	add_child(_label)
	await get_tree().process_frame
	_run()


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


func _log(msg: String) -> void:
	print("[RapierSpike] ", msg)
	_out.append(msg)
	_label.text = "\n".join(_out)


func _run() -> void:
	var engine_name: String = str(ProjectSettings.get_setting("physics/3d/physics_engine", "?"))
	_log("physics_engine setting = %s" % engine_name)
	var names: Array[String] = []
	for n: String in Engine.get_singleton_list():
		if n.to_lower().contains("rapier") or n.contains("Physics"):
			names.append(n)
	_log("singletons: %s" % str(names))
	_log("ClassDB RapierPhysicsServer3D: %s | PhysicsServer3D.has space_step: %s" % [
		ClassDB.class_exists("RapierPhysicsServer3D"), PhysicsServer3D.has_method("space_step")])
	var rapier: Object = find_rapier()
	if rapier == null:
		_log("FAIL: مش لاقي سيرفر Rapier بأي طريقة (شوف السطرين اللي فوق وابعتهم)")
		return
	_log("rapier object = %s" % rapier)
	_space = get_viewport().world_3d.space
	PhysicsServer3D.space_set_active(_space, false)
	_build_world()

	var t0: int = Time.get_ticks_usec()
	for i in TICKS_A:
		_step(rapier, i, false)
	var step_us: float = float(Time.get_ticks_usec() - t0) / TICKS_A
	_log("متوسط وقت tick واحد: %.0f µs" % step_us)

	var snap: Variant = rapier.export_binary(_space)
	if snap == null:
		_log("FAIL: export_binary رجّع null")
		return
	_log("حجم snapshot: %d bytes" % (snap as PackedByteArray).size())

	# تشغيل A
	var hash_a: int = _run_b(rapier)
	# رجوع للـ snapshot وإعادة نفس الـ ticks بنفس الـ input
	rapier.import_binary(_space, snap)
	var t1: int = Time.get_ticks_usec()
	var hash_b: int = _run_b(rapier)
	var replay_ms: float = float(Time.get_ticks_usec() - t1) / 1000.0
	_log("إعادة %d tick (rollback كامل): %.1f ms" % [TICKS_B, replay_ms])
	_log("hash الأولى  = %d" % hash_a)
	_log("hash الإعادة = %d" % hash_b)
	_log("النتيجة: %s" % ("PASS - deterministic بعد restore" if hash_a == hash_b else "FAIL - مختلفة"))


func _run_b(rapier: Object) -> int:
	for i in TICKS_B:
		_step(rapier, i, i == INPUT_TICK)
	var xf: Transform3D = PhysicsServer3D.body_get_state(_ball, PhysicsServer3D.BODY_STATE_TRANSFORM)
	var vel: Vector3 = PhysicsServer3D.body_get_state(_ball, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
	return hash(var_to_bytes([xf.origin, xf.basis, vel]))


func _step(rapier: Object, _i: int, apply_input: bool) -> void:
	if apply_input:
		PhysicsServer3D.body_apply_central_impulse(_ball, Vector3(3, 6, 1))
	rapier.space_step(_space, DT)
	rapier.space_flush_queries(_space)


func _build_world() -> void:
	var floor_shape: RID = PhysicsServer3D.box_shape_create()
	PhysicsServer3D.shape_set_data(floor_shape, Vector3(20, 0.5, 20))
	var floor_body: RID = PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(floor_body, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_space(floor_body, _space)
	PhysicsServer3D.body_add_shape(floor_body, floor_shape)
	PhysicsServer3D.body_set_state(floor_body, PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), Vector3(0, -0.5, 0)))

	var ball_shape: RID = PhysicsServer3D.sphere_shape_create()
	PhysicsServer3D.shape_set_data(ball_shape, 0.45)
	_ball = PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(_ball, PhysicsServer3D.BODY_MODE_RIGID)
	PhysicsServer3D.body_set_space(_ball, _space)
	PhysicsServer3D.body_add_shape(_ball, ball_shape)
	PhysicsServer3D.body_set_state(_ball, PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis(), Vector3(0, 3, 0)))
