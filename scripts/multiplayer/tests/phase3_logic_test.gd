extends Node
## اختبار آلي للمرحلة 3 (Clock + SnapshotBuffer + دورة الحياة مع NetworkManager).
## شغّل المشهد phase3_logic_test.tscn. يحتاج Autoload: NetworkEvents ثم NetworkManager.

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
	_test_clock_math()
	_test_clock_samples()
	_test_clock_time_and_slew()
	_test_buffer_basic()
	_test_buffer_interpolation()
	_test_clock_lifecycle()
	print("== %d passed, %d failed ==" % [_pass, _fail])

func _make_clock() -> NetworkClock:
	var c: NetworkClock = NetworkClock.new()
	add_child(c)
	return c

func _test_clock_math() -> void:
	var s: Dictionary = NetworkClock.compute_sample(1_000_000, 1_100_000, 5_000_000)
	_check("rtt: 100ms", int(s["rtt_usec"]) == 100_000)
	_check("offset: 3.95s", absf(float(s["offset"]) - 3.95) < 0.000001)
	_check("sample: negative rtt rejected", NetworkClock.compute_sample(2_000_000, 1_000_000, 5).is_empty())
	_check("sample: huge rtt rejected", NetworkClock.compute_sample(0, 3_000_000, 5).is_empty())
	_check("sample: negative host time rejected", NetworkClock.compute_sample(0, 10, -1).is_empty())
	var arr: Array[Dictionary] = [
		{"rtt_usec": 100_000, "offset": 1.0},
		{"rtt_usec": 100_000, "offset": 1.0},
		{"rtt_usec": 100_000, "offset": 1.0},
		{"rtt_usec": 900_000, "offset": 5.0}]
	_check("offset: outlier (high RTT) ignored", absf(NetworkClock.estimate_offset(arr) - 1.0) < 0.000001)
	_check("rtt: median", NetworkClock.estimate_rtt_usec(arr) == 100_000)
	_check("offset: empty = 0", NetworkClock.estimate_offset([] as Array[Dictionary]) == 0.0)

func _test_clock_samples() -> void:
	var c: NetworkClock = _make_clock()
	c.set_debug_time_usec(2_000_000)
	_check("clock: submit ignored when stopped", not c.submit_sample(1000, 1.0))
	c.start_as_client()
	_check("clock: not synced at start", not c.is_synced())
	c.submit_sample(100_000, 3.95)
	c.submit_sample(110_000, 3.95)
	_check("clock: not synced with 2 samples", not c.is_synced())
	c.submit_sample(90_000, 3.95)
	_check("clock: synced with 3 samples", c.is_synced())
	_check("clock: rtt median 100ms", c.get_rtt_usec() == 100_000)
	_check("clock: bad sample rejected", not c.submit_sample(-5, 1.0) and not c.submit_sample(10, INF))
	_check("clock: sample count", c.get_sample_count() == 3)
	for i: int in 20:
		c.submit_sample(100_000, 3.95)
	_check("clock: samples capped", c.get_sample_count() == NetworkClock.MAX_SAMPLES)
	c.stop()
	_check("clock: stop resets", not c.is_running() and not c.is_synced() and c.get_sample_count() == 0 and c.get_offset() == 0.0)
	c.queue_free()

func _test_clock_time_and_slew() -> void:
	var h: NetworkClock = _make_clock()
	h.set_debug_time_usec(10_000_000)
	h.start_as_host()
	h.set_debug_time_usec(12_500_000)
	_check("host: network time since start = 2.5s", absf(h.get_network_time() - 2.5) < 0.000001)
	_check("host: local time", absf(h.get_local_time() - 12.5) < 0.000001)
	_check("host: synced immediately", h.is_synced())
	h.start_as_host()
	_check("host: restart resets epoch", absf(h.get_network_time()) < 0.000001)
	h.stop()
	h.queue_free()
	var c: NetworkClock = _make_clock()
	c.set_debug_time_usec(2_000_000)
	c.start_as_client()
	for i: int in 3:
		c.submit_sample(100_000, 3.95)
	_check("client: network time = local + offset", absf(c.get_network_time() - 5.95) < 0.000001)
	for i: int in NetworkClock.MAX_SAMPLES:
		c.submit_sample(100_000, 4.05)
	var before: float = c.get_offset()
	c._process(0.1)
	var step: float = c.get_offset() - before
	_check("client: small change is slewed (no jump)", step > 0.0 and step <= NetworkClock.MAX_SLEW_PER_SEC * 0.1 + 0.000001)
	for i: int in NetworkClock.MAX_SAMPLES:
		c.submit_sample(100_000, 10.0)
	_check("client: large step snaps", absf(c.get_offset() - 10.0) < 0.000001)
	c.stop()
	c.queue_free()

func _test_buffer_basic() -> void:
	var b: SnapshotBuffer = SnapshotBuffer.new()
	_check("buffer: empty sample invalid", not bool(b.sample(1.0).get("valid", true)))
	_check("buffer: empty latest NAN", is_nan(b.get_latest_time()))
	_check("buffer: add 1.0", b.add(1.0, {"x": 1.0}) == OK)
	_check("buffer: add 3.0", b.add(3.0, {"x": 3.0}) == OK)
	_check("buffer: out-of-order 2.0", b.add(2.0, {"x": 2.0}) == OK)
	_check("buffer: size 3", b.size() == 3)
	_check("buffer: order oldest/latest", b.get_oldest_time() == 1.0 and b.get_latest_time() == 3.0)
	_check("buffer: sample exact middle", float(b.sample(2.0)["state"]["x"]) == 2.0)
	_check("buffer: duplicate rejected", b.add(2.0, {"x": 9.0}) == ERR_ALREADY_EXISTS and b.size() == 3)
	_check("buffer: NAN rejected", b.add(NAN, {}) == ERR_INVALID_PARAMETER)
	_check("buffer: at_or_before", float(b.get_snapshot_at_or_before(2.5)["time"]) == 2.0)
	_check("buffer: at_or_before none", b.get_snapshot_at_or_before(0.5).is_empty())
	var small: SnapshotBuffer = SnapshotBuffer.new(3)
	for i: int in range(1, 6):
		small.add(float(i), {"i": i})
	_check("buffer: max size enforced", small.size() == 3 and small.get_oldest_time() == 3.0)
	_check("buffer: too-old rejected when full", small.add(1.5, {}) == ERR_INVALID_DATA)
	_check("buffer: prune keeps 2", small.prune_older_than(100.0) == 1 and small.size() == 2)
	small.clear()
	_check("buffer: clear", small.is_empty())

func _test_buffer_interpolation() -> void:
	var b: SnapshotBuffer = SnapshotBuffer.new()
	b.set_angle_keys([&"yaw"])
	b.add(1.0, {"x": 0.0, "pos": Vector3.ZERO, "yaw": deg_to_rad(170.0), "mode": 0})
	b.add(2.0, {"x": 10.0, "pos": Vector3(10, 20, 30), "yaw": deg_to_rad(-170.0), "mode": 1})
	var r: Dictionary = b.sample(1.5)
	var st: Dictionary = r["state"]
	_check("interp: valid + alpha 0.5", bool(r["valid"]) and absf(float(r["alpha"]) - 0.5) < 0.000001)
	_check("interp: float", absf(float(st["x"]) - 5.0) < 0.000001)
	_check("interp: Vector3", (st["pos"] as Vector3).is_equal_approx(Vector3(5, 10, 15)))
	_check("interp: angle wraps shortest way", absf(absf(float(st["yaw"])) - PI) < 0.01)
	_check("interp: discrete value", int(st["mode"]) == 1)
	var lo: Dictionary = b.sample(0.0)
	var hi: Dictionary = b.sample(99.0)
	_check("interp: clamp low", bool(lo["clamped"]) and float(lo["state"]["x"]) == 0.0)
	_check("interp: clamp high", bool(hi["clamped"]) and float(hi["state"]["x"]) == 10.0)

func _test_clock_lifecycle() -> void:
	var clock: NetworkClock = NetworkManager.get_clock()
	_check("lifecycle: clock exists", clock != null)
	_check("lifecycle: stopped before session", not clock.is_running())
	_check("lifecycle: host ok", NetworkManager.host_game(7792) == OK)
	_check("lifecycle: host clock running + synced", clock.get_role() == NetworkClock.Role.HOST and clock.is_synced())
	NetworkManager.disconnect_session()
	_check("lifecycle: clock stopped after disconnect", not clock.is_running() and not clock.is_synced())
	_check("lifecycle: host again", NetworkManager.host_game(7792) == OK)
	_check("lifecycle: clock restarted fresh", clock.is_running() and clock.get_network_time() < 1.0)
	NetworkManager.disconnect_session()
	_check("lifecycle: stopped again", not clock.is_running())
