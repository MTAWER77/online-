extends Node
## اختبار آلي للمرحلة 4 (بدون شبكة حقيقية): التحقق، الملكية، التخزين، الترتيب، Interpolation.
## شغّل scenes/multiplayer/phase4_logic_test.tscn (F6). يحتاج Autoload: NetworkEvents ثم NetworkManager.

var _pass: int = 0
var _fail: int = 0

func _check(name: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("PASS  ", name)
	else:
		_fail += 1
		print("FAIL  ", name)

func _ready() -> void:
	_test_validation()
	_test_ownership_and_interpolation()
	_test_player_scene()
	print("== %d passed, %d failed ==" % [_pass, _fail])

func _test_validation() -> void:
	_check("valid state accepted", PlayerSync.is_state_valid(Vector3(1, 0, 1), 0.5, Vector3(1, 0, 0), 1))
	_check("NaN position rejected", not PlayerSync.is_state_valid(Vector3(NAN, 0, 0), 0.0, Vector3.ZERO, 0))
	_check("NaN yaw rejected", not PlayerSync.is_state_valid(Vector3.ZERO, NAN, Vector3.ZERO, 0))
	_check("out-of-world position rejected", not PlayerSync.is_state_valid(Vector3(5000, 0, 0), 0.0, Vector3.ZERO, 0))
	_check("excessive velocity rejected", not PlayerSync.is_state_valid(Vector3.ZERO, 0.0, Vector3(100, 0, 0), 0))
	_check("bad state id rejected", not PlayerSync.is_state_valid(Vector3.ZERO, 0.0, Vector3.ZERO, 7))
	_check("negative state id rejected", not PlayerSync.is_state_valid(Vector3.ZERO, 0.0, Vector3.ZERO, -1))
	_check("plausible move accepted", PlayerSync.is_move_plausible(Vector3.ZERO, Vector3(2, 0, 0), 0.05))
	_check("teleport rejected", not PlayerSync.is_move_plausible(Vector3.ZERO, Vector3(80, 0, 0), 0.05))
	_check("long gap allows longer move", PlayerSync.is_move_plausible(Vector3.ZERO, Vector3(50, 0, 0), 2.0))
	_check("timestamp in window kept", PlayerSync.resolve_timestamp(9.9, 10.0) == 9.9)
	_check("old timestamp replaced", PlayerSync.resolve_timestamp(2.0, 10.0) == 10.0)
	_check("future timestamp replaced", PlayerSync.resolve_timestamp(20.0, 10.0) == 10.0)
	_check("NaN timestamp replaced", PlayerSync.resolve_timestamp(NAN, 10.0) == 10.0)

func _test_ownership_and_interpolation() -> void:
	var body: CharacterBody3D = CharacterBody3D.new()
	var sync: PlayerSync = PlayerSync.new()
	body.add_child(sync)
	add_child(body)
	sync.setup(7)
	_check("owner id stored", sync.get_owner_peer_id() == 7)
	_check("not local owner when offline", not sync.is_local_owner())
	_check("ingest 1.0", sync.ingest_snapshot(1.0, Vector3.ZERO, 0.0, Vector3.ZERO, 0) == OK)
	_check("ingest 1.1", sync.ingest_snapshot(1.1, Vector3(10, 0, 0), 1.0, Vector3(5, 0, 0), 1) == OK)
	_check("ingest 1.2 (ahead)", sync.ingest_snapshot(1.2, Vector3(20, 0, 0), 1.0, Vector3.ZERO, 0) == OK)
	_check("ingest 1.15 (out of order)", sync.ingest_snapshot(1.15, Vector3(15, 0, 0), 1.0, Vector3.ZERO, 0) == OK)
	_check("duplicate rejected", sync.ingest_snapshot(1.1, Vector3(10, 0, 0), 1.0, Vector3.ZERO, 0) == ERR_ALREADY_EXISTS)
	_check("invalid snapshot rejected", sync.ingest_snapshot(1.3, Vector3(NAN, 0, 0), 0.0, Vector3.ZERO, 0) == ERR_INVALID_DATA)
	_check("buffer holds 4", sync.get_buffer_size() == 4)
	_check("render 1.05 ok", sync.render_at(1.05))
	_check("interp position midpoint", absf(body.global_position.x - 5.0) < 0.001)
	_check("interp yaw midpoint", absf(body.rotation.y - 0.5) < 0.001)
	_check("interp velocity", absf(sync.remote_velocity.x - 2.5) < 0.001)
	sync.render_at(1.125)
	_check("ordered after out-of-order insert", absf(body.global_position.x - 12.5) < 0.001)
	sync.render_at(1.09)
	_check("discrete state follows later snapshot", sync.remote_state == 1)
	sync.render_at(0.0)
	_check("clamp before first", absf(body.global_position.x) < 0.001)
	sync.render_at(99.0)
	_check("clamp after last", absf(body.global_position.x - 20.0) < 0.001)
	var empty_sync: PlayerSync = PlayerSync.new()
	var empty_body: Node3D = Node3D.new()
	empty_body.add_child(empty_sync)
	add_child(empty_body)
	_check("render with no data is safe", not empty_sync.render_at(1.0))
	body.queue_free()
	empty_body.queue_free()

func _test_player_scene() -> void:
	var scene: PackedScene = load("res://scenes/players/test_player.tscn") as PackedScene
	_check("player scene loads", scene != null)
	if scene == null:
		return
	var p: TestPlayer = scene.instantiate() as TestPlayer
	_check("player scene root is TestPlayer", p != null)
	if p == null:
		return
	p.name = "5"
	p.setup(5, false)
	add_child(p)
	var sync: PlayerSync = p.get_node_or_null("PlayerSync") as PlayerSync
	_check("PlayerSync child exists", sync != null)
	_check("remote player owner id = peer id", sync != null and sync.get_owner_peer_id() == 5)
	_check("remote player physics disabled", not p.is_physics_processing())
	p.queue_free()
