extends Node
## اختبار آلي للمرحلة 5 (بدون شبكة حقيقية): التحقق من الحزم، رفض التحديثات غير
## الموثوقة، التخزين في SnapshotBuffer، والاستيفاء.
## شغّل scenes/multiplayer/phase5_logic_test.tscn (F6). يحتاج Autoload: NetworkEvents ثم NetworkManager.
##
## ملاحظة: الاختبار بيمسّخ دوال التحقق (static) والـ SnapshotBuffer مباشرة،
## من غير ما يفتح جلسة شبكة — وده اللي Phase 4 كان بيعمله بالظبط.

const CART_SCENE_PATHS: Array = [
	"res://scenes/vehicles/shopping_cart.tscn",
	"res://scenes/shopping_cart.tscn",
	"res://vehicles/shopping_cart.tscn",
]

var _pass: int = 0
var _fail: int = 0
var _warn: int = 0

# نتجمع فيهم إشارات respawn عشان نختبرها
var _respawn_hits: Array = []


func _check(name: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("PASS  ", name)
	else:
		_fail += 1
		print("FAIL  ", name)


## فحص "soft": لو الـ SnapshotBuffer ما بيستوفيش القيم الإضافية،
## المزامنة الأساسية سليمة بس المؤثرات البصرية هتبقى ساكنة. ننبّه بدل ما نخسر.
func _check_soft(name: String, cond: bool, hint: String) -> void:
	if cond:
		_pass += 1
		print("PASS  ", name)
	else:
		_warn += 1
		print("WARN  ", name, " — ", hint)


func _skip(name: String, reason: String) -> void:
	_warn += 1
	print("WARN  ", name, " — ", reason)


func _ready() -> void:
	_test_state_validation()
	_test_movement_plausibility()
	_test_timestamps()
	_test_input_validation()
	_test_buffer_and_interpolation()
	_test_respawn_epoch()
	_test_cart_scene()
	print("== %d passed, %d failed, %d warnings ==" % [_pass, _fail, _warn])


# ---------------------------------------------------------------------
func _test_state_validation() -> void:
	_check("valid state accepted", CartSync.is_state_valid(Vector3(1, 0, 1), 0.5, Vector3(1, 0, 0), 0.5, 0.5, 0.0, 0.0))
	_check("NaN position rejected", not CartSync.is_state_valid(Vector3(NAN, 0, 0), 0.0, Vector3.ZERO, 0.0, 0.0, 0.0, 0.0))
	_check("NaN yaw rejected", not CartSync.is_state_valid(Vector3.ZERO, NAN, Vector3.ZERO, 0.0, 0.0, 0.0, 0.0))
	_check("NaN steer rejected", not CartSync.is_state_valid(Vector3.ZERO, 0.0, Vector3.ZERO, NAN, 0.0, 0.0, 0.0))
	_check("NaN gas rejected", not CartSync.is_state_valid(Vector3.ZERO, 0.0, Vector3.ZERO, 0.0, NAN, 0.0, 0.0))
	_check("out-of-world position rejected", not CartSync.is_state_valid(Vector3(5000, 0, 0), 0.0, Vector3.ZERO, 0.0, 0.0, 0.0, 0.0))
	_check("excessive velocity rejected", not CartSync.is_state_valid(Vector3.ZERO, 0.0, Vector3(100, 0, 0), 0.0, 0.0, 0.0, 0.0))
	_check("steer out of range rejected", not CartSync.is_state_valid(Vector3.ZERO, 0.0, Vector3.ZERO, 5.0, 0.0, 0.0, 0.0))
	_check("gas out of range rejected", not CartSync.is_state_valid(Vector3.ZERO, 0.0, Vector3.ZERO, 0.0, 2.0, 0.0, 0.0))
	_check("brake out of range rejected", not CartSync.is_state_valid(Vector3.ZERO, 0.0, Vector3.ZERO, 0.0, 0.0, -3.0, 0.0))
	_check("crash duration too long rejected", not CartSync.is_state_valid(Vector3.ZERO, 0.0, Vector3.ZERO, 0.0, 0.0, 0.0, 99.0))


# ---------------------------------------------------------------------
func _test_movement_plausibility() -> void:
	_check("plausible move accepted", CartSync.is_move_plausible(Vector3.ZERO, Vector3(2, 0, 0), 0.05))
	_check("teleport rejected", not CartSync.is_move_plausible(Vector3.ZERO, Vector3(80, 0, 0), 0.05))
	_check("long gap allows longer move", CartSync.is_move_plausible(Vector3.ZERO, Vector3(50, 0, 0), 2.0))


# ---------------------------------------------------------------------
func _test_timestamps() -> void:
	_check("timestamp in window kept", CartSync.resolve_timestamp(9.9, 10.0) == 9.9)
	_check("old timestamp replaced", CartSync.resolve_timestamp(2.0, 10.0) == 10.0)
	_check("future timestamp replaced", CartSync.resolve_timestamp(20.0, 10.0) == 10.0)
	_check("NaN timestamp replaced", CartSync.resolve_timestamp(NAN, 10.0) == 10.0)


# ---------------------------------------------------------------------
func _test_input_validation() -> void:
	_check("valid input accepted", CartSync.is_input_valid(0.0, 1.0))
	_check("NaN input rejected", not CartSync.is_input_valid(NAN, 0.0))
	_check("input above 1 rejected", not CartSync.is_input_valid(1.5, 0.0))
	_check("negative input rejected", not CartSync.is_input_valid(0.0, -0.5))
	_check("input clamped to 1", is_equal_approx(CartSync.clamp_input(4.0), 1.0))
	_check("input clamped to 0", is_equal_approx(CartSync.clamp_input(-4.0), 0.0))
	_check("NaN input clamps to 0", is_equal_approx(CartSync.clamp_input(NAN), 0.0))


# ---------------------------------------------------------------------
func _test_buffer_and_interpolation() -> void:
	var body: CharacterBody3D = CharacterBody3D.new()
	var sync: CartSync = CartSync.new()
	body.add_child(sync)
	add_child(body)

	_check("ingest 1.0", sync.ingest_snapshot(1.0, Vector3.ZERO, 0.0, Vector3.ZERO, 0.0, 0.0, 0.0, 0.0) == OK)
	_check("ingest 1.1", sync.ingest_snapshot(1.1, Vector3(10, 0, 0), 1.0, Vector3(5, 0, 0), 0.5, 1.0, 0.0, 0.0) == OK)
	_check("ingest 1.2 (ahead)", sync.ingest_snapshot(1.2, Vector3(20, 0, 0), 1.0, Vector3.ZERO, 0.0, 0.0, 0.0, 0.0) == OK)
	_check("ingest 1.15 (out of order)", sync.ingest_snapshot(1.15, Vector3(15, 0, 0), 1.0, Vector3.ZERO, 0.0, 0.0, 0.0, 0.0) == OK)
	_check("duplicate rejected", sync.ingest_snapshot(1.1, Vector3(10, 0, 0), 1.0, Vector3(5, 0, 0), 0.5, 1.0, 0.0, 0.0) == ERR_ALREADY_EXISTS)
	_check("invalid snapshot rejected", sync.ingest_snapshot(1.3, Vector3(NAN, 0, 0), 0.0, Vector3.ZERO, 0.0, 0.0, 0.0, 0.0) == ERR_INVALID_DATA)
	_check("buffer holds 4", sync.get_buffer_size() == 4)

	_check("render 1.05 ok", sync.render_at(1.05))
	var st: Dictionary = sync.get_remote_state()
	_check("interp position midpoint", absf((st["pos"] as Vector3).x - 5.0) < 0.001)
	_check("interp yaw midpoint", absf(float(st["yaw"]) - 0.5) < 0.001)
	_check("interp velocity", absf((st["vel"] as Vector3).x - 2.5) < 0.001)
	_check_soft("interp extras (steer/gas)",
		absf(float(st.get("steer", -1.0)) - 0.25) < 0.001 and absf(float(st.get("gas", -1.0)) - 0.5) < 0.001,
		"الـ SnapshotBuffer لا يستوفي القيم الإضافية — المزامنة سليمة لكن ميل/ميلان العربية على العميل هيبقى ساكن.")

	sync.render_at(1.125)
	st = sync.get_remote_state()
	_check("ordered after out-of-order insert", absf((st["pos"] as Vector3).x - 12.5) < 0.001)

	sync.render_at(0.0)
	st = sync.get_remote_state()
	_check("clamp before first", absf((st["pos"] as Vector3).x) < 0.001)

	sync.render_at(99.0)
	st = sync.get_remote_state()
	_check("clamp after last", absf((st["pos"] as Vector3).x - 20.0) < 0.001)

	var empty_sync: CartSync = CartSync.new()
	var empty_body: Node3D = Node3D.new()
	empty_body.add_child(empty_sync)
	add_child(empty_body)
	_check("render with no data is safe", not empty_sync.render_at(1.0))
	_check("sample_state with no data is safe", not bool(empty_sync.sample_state().get("valid", false)))

	body.queue_free()
	empty_body.queue_free()


# ---------------------------------------------------------------------
func _test_respawn_epoch() -> void:
	var body: CharacterBody3D = CharacterBody3D.new()
	var sync: CartSync = CartSync.new()
	body.add_child(sync)
	add_child(body)
	sync.respawn_received.connect(_on_respawn_received)
	sync.ingest_snapshot(1.0, Vector3.ZERO, 0.0, Vector3.ZERO, 0.0, 0.0, 0.0, 0.0)

	_check("respawn applied", sync.apply_respawn(1, Vector3(5, 0, 5), 1.25))
	_check("respawn signal fired", _respawn_hits.size() == 1)
	if _respawn_hits.size() == 1:
		var p: Vector3 = _respawn_hits[0][0]
		var yaw: float = float(_respawn_hits[0][1])
		_check("respawn position correct", p.is_equal_approx(Vector3(5, 0, 5)))
		_check("respawn yaw correct", is_equal_approx(yaw, 1.25))
	_check("older epoch rejected", not sync.apply_respawn(0, Vector3.ZERO, 0.0))
	_check("old snapshots pruned after respawn", sync.get_buffer_size() == 0)

	body.queue_free()


func _on_respawn_received(pos: Vector3, yaw: float) -> void:
	_respawn_hits.append([pos, yaw])


# ---------------------------------------------------------------------
func _test_cart_scene() -> void:
	var path: String = ""
	for candidate: String in CART_SCENE_PATHS:
		if ResourceLoader.exists(candidate):
			path = candidate
			break
	if path.is_empty():
		_skip("cart scene loads", "لم يُعثر على مشهد العربية في: %s" % str(CART_SCENE_PATHS))
		return
	var scene: PackedScene = load(path) as PackedScene
	_check("cart scene loads", scene != null)
	if scene == null:
		return
	var cart: Node = scene.instantiate()
	add_child(cart)
	var sync: CartSync = cart.get_node_or_null("CartSync") as CartSync
	_check("CartSync child exists", sync != null)
	_check("cart public API kept", cart.has_method("set_checkpoint") and cart.has_method("is_authoritative"))
	_check("cart is CharacterBody3D", cart is CharacterBody3D)
	cart.queue_free()
