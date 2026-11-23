class_name PlayerSync
extends Node
## مزامنة لاعب واحد (Position / Rotation / Velocity / State). يوضع كابن اسمه "PlayerSync"
## تحت جسم اللاعب (Node3D) الذي اسمه = Peer ID، ليتطابق مسار RPC على الجهازين.
##
## النموذج:
## - صاحب اللاعب (Owner) يتحكم فيه محليًا ويرسل حالته كل SEND_INTERVAL_SEC.
## - Client -> Host (any_peer): Host يتحقق (المرسل = المالك، مسجل، حدود، سرعة معقولة، توقيت)
##   ثم يخزّن اللقطة ويعيد بثها لباقي الـ Peers. Host يصحّح المالك لو كرر المخالفات.
## - Host -> Clients (authority): تُقبل من Peer 1 فقط ولا تُطبّق على لاعب الجهاز نفسه.
## - غير المالك يعرض الحالة بـ Interpolation من SnapshotBuffer بزمن NetworkClock ناقص تأخير ثابت.
## - Handshake (hello/ack): لا يُرسل أي Peer حالة لعقدة قبل التأكد أنها موجودة عند الطرف الآخر.

signal state_rejected(peer_id: int, reason: String)
signal corrected(new_position: Vector3)

const STATE_IDLE: int = 0
const STATE_MOVING: int = 1
const STATE_AIRBORNE: int = 2
const STATE_MAX: int = 2

const SEND_INTERVAL_SEC: float = 0.05
const INTERPOLATION_DELAY_SEC: float = 0.12
const BUFFER_CAPACITY: int = 64
const MAX_PLAUSIBLE_SPEED: float = 30.0
const PLAUSIBILITY_MARGIN: float = 1.0
const MAX_VELOCITY: float = 40.0
const WORLD_LIMIT: float = 1000.0
const MAX_TS_PAST_SEC: float = 1.0
const MAX_TS_FUTURE_SEC: float = 0.25
const MIN_PACKET_INTERVAL_MSEC: int = 10
const HELLO_FIRST_DELAY_SEC: float = 0.2
const HELLO_INTERVAL_SEC: float = 0.25
const CORRECTION_COOLDOWN_MSEC: int = 500
const VIOLATIONS_BEFORE_CORRECTION: int = 3

## آخر قيم مطبّقة على لاعب بعيد (للعرض/التشخيص).
var remote_velocity: Vector3 = Vector3.ZERO
var remote_state: int = STATE_IDLE

var _owner_peer_id: int = 0
var _body: Node3D = null
var _buffer: SnapshotBuffer = SnapshotBuffer.new(BUFFER_CAPACITY)
var _send_accum: float = 0.0
var _ready_peers: Dictionary = {}     # Host: peer_id -> true (بعد hello)
var _host_acked: bool = false         # Client: Host أكد وجود العقدة
var _hello_timer: float = HELLO_FIRST_DELAY_SEC
var _last_accept_pos: Vector3 = Vector3.ZERO
var _has_last: bool = false
var _last_accept_msec: int = 0
var _last_packet_msec: int = 0
var _violations: int = 0
var _last_correction_msec: int = -100000
var _sent: int = 0
var _received: int = 0
var _rejected: int = 0

# ---------------- دوال static (قابلة للاختبار بدون شبكة) ----------------

static func is_state_valid(pos: Vector3, yaw: float, vel: Vector3, state: int) -> bool:
	if not pos.is_finite() or not vel.is_finite() or not is_finite(yaw):
		return false
	if absf(pos.x) > WORLD_LIMIT or absf(pos.y) > WORLD_LIMIT or absf(pos.z) > WORLD_LIMIT:
		return false
	if vel.length() > MAX_VELOCITY:
		return false
	return state >= 0 and state <= STATE_MAX

static func is_move_plausible(from_pos: Vector3, to_pos: Vector3, dt_sec: float) -> bool:
	var dt: float = maxf(dt_sec, SEND_INTERVAL_SEC)
	return from_pos.distance_to(to_pos) <= MAX_PLAUSIBLE_SPEED * dt + PLAUSIBILITY_MARGIN

## توقيت مرسل غير منطقي يُستبدل بوقت Host الحالي.
static func resolve_timestamp(t: float, now_t: float) -> float:
	if is_finite(t) and t >= now_t - MAX_TS_PAST_SEC and t <= now_t + MAX_TS_FUTURE_SEC:
		return t
	return now_t

# ---------------- الإعداد ----------------

## يُستدعى من TestPlayer._ready قبل أي مزامنة.
func setup(owner_peer_id: int) -> void:
	_owner_peer_id = owner_peer_id

func _ready() -> void:
	_body = get_parent() as Node3D
	if _body == null:
		push_error("PlayerSync must be a child of a Node3D")
		set_process(false)
		set_physics_process(false)
		return
	var keys: Array[StringName] = [&"yaw"]
	_buffer.set_angle_keys(keys)

func get_owner_peer_id() -> int:
	return _owner_peer_id

func is_local_owner() -> bool:
	return _owner_peer_id > 0 and _owner_peer_id == NetworkManager.get_local_peer_id()

func get_buffer_size() -> int:
	return _buffer.size()

func get_stats() -> Dictionary:
	return {"sent": _sent, "received": _received, "rejected": _rejected, "buffered": _buffer.size()}

# ---------------- الحلقة الرئيسية ----------------

func _physics_process(delta: float) -> void:
	if _body == null or not NetworkManager.is_network_ready() or not is_local_owner():
		return
	_send_accum += delta
	if _send_accum < SEND_INTERVAL_SEC:
		return
	_send_accum = 0.0
	if NetworkManager.is_host():
		_broadcast_own_state()
	elif _host_acked and NetworkManager.get_clock().is_synced():
		_submit_own_state()

func _process(delta: float) -> void:
	if _body == null or not NetworkManager.is_network_ready():
		return
	if not NetworkManager.is_host():
		_update_hello(delta)
	if not is_local_owner():
		_render_remote()

func _update_hello(delta: float) -> void:
	if _host_acked:
		return
	_hello_timer -= delta
	if _hello_timer > 0.0:
		return
	_hello_timer = HELLO_INTERVAL_SEC
	_rpc_hello.rpc_id(NetworkConfig.SERVER_PEER_ID)

# ---------------- قراءة/تطبيق الحالة ----------------

func _read_body_state() -> Dictionary:
	var vel: Vector3 = Vector3.ZERO
	if _body is CharacterBody3D:
		vel = (_body as CharacterBody3D).velocity
	var state: int = STATE_IDLE
	if _body.has_method("get_sync_state"):
		state = int(_body.call("get_sync_state"))
	return {"pos": _body.global_position, "yaw": _body.rotation.y, "vel": vel, "state": state}

func _broadcast_own_state() -> void:
	var s: Dictionary = _read_body_state()
	var t: float = NetworkManager.get_clock().get_network_time()
	var registry: PlayerRegistry = NetworkManager.get_registry()
	for peer: Variant in _ready_peers.keys():
		var pid: int = int(peer)
		if registry.has_player(pid):
			_rpc_state_update.rpc_id(pid, t, s["pos"], s["yaw"], s["vel"], s["state"])
			_sent += 1

func _submit_own_state() -> void:
	var s: Dictionary = _read_body_state()
	var t: float = NetworkManager.get_clock().get_network_time()
	_rpc_submit_state.rpc_id(NetworkConfig.SERVER_PEER_ID, t, s["pos"], s["yaw"], s["vel"], s["state"])
	_sent += 1

## يخزّن لقطة (يُستخدم من RPC ومن الاختبارات).
func ingest_snapshot(ts: float, pos: Vector3, yaw: float, vel: Vector3, state: int) -> Error:
	if not is_state_valid(pos, yaw, vel, state) or not is_finite(ts):
		return ERR_INVALID_DATA
	return _buffer.add(ts, {"pos": pos, "yaw": yaw, "vel": vel, "state": state})

## يطبق الحالة المستوفاة عند render_time على الجسم. false لو لا توجد بيانات.
func render_at(render_time: float) -> bool:
	if _body == null:
		return false
	var res: Dictionary = _buffer.sample(render_time)
	if not bool(res.get("valid", false)):
		return false
	var st: Dictionary = res["state"]
	_body.global_position = st["pos"] as Vector3
	_body.rotation.y = float(st["yaw"])
	remote_velocity = st["vel"] as Vector3
	remote_state = int(st["state"])
	return true

func _render_remote() -> void:
	if _buffer.is_empty():
		return
	var clock: NetworkClock = NetworkManager.get_clock()
	if clock.is_synced():
		var render_t: float = clock.get_network_time() - INTERPOLATION_DELAY_SEC
		render_at(render_t)
		_buffer.prune_older_than(render_t - 0.5)
	else:
		render_at(_buffer.get_latest_time())

# ---------------- RPC: Handshake ----------------

@rpc("any_peer", "call_remote", "reliable")
func _rpc_hello() -> void:
	if not NetworkManager.is_network_ready() or not NetworkManager.is_host():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if sender <= NetworkConfig.SERVER_PEER_ID or not NetworkManager.get_registry().has_player(sender):
		return
	_ready_peers[sender] = true
	_rpc_hello_ack.rpc_id(sender)

@rpc("authority", "call_remote", "reliable")
func _rpc_hello_ack() -> void:
	if NetworkManager.is_host():
		return
	if multiplayer.get_remote_sender_id() != NetworkConfig.SERVER_PEER_ID:
		return
	_host_acked = true

# ---------------- RPC: Client -> Host ----------------

@rpc("any_peer", "call_remote", "unreliable_ordered")
func _rpc_submit_state(t: float, pos: Vector3, yaw: float, vel: Vector3, state: int) -> void:
	if not NetworkManager.is_network_ready() or not NetworkManager.is_host():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if sender <= NetworkConfig.SERVER_PEER_ID or sender != _owner_peer_id:
		_reject(sender, "not owner")
		return
	if not NetworkManager.get_registry().has_player(sender) or not _ready_peers.has(sender):
		return
	var now_msec: int = Time.get_ticks_msec()
	if now_msec - _last_packet_msec < MIN_PACKET_INTERVAL_MSEC:
		return
	_last_packet_msec = now_msec
	if not is_state_valid(pos, yaw, vel, state) or not is_finite(t):
		_reject(sender, "invalid data")
		return
	if _has_last:
		var dt: float = float(now_msec - _last_accept_msec) / 1000.0
		if not is_move_plausible(_last_accept_pos, pos, dt):
			_reject(sender, "implausible movement")
			return
	_violations = 0
	_has_last = true
	_last_accept_pos = pos
	_last_accept_msec = now_msec
	var ts: float = resolve_timestamp(t, NetworkManager.get_clock().get_network_time())
	ingest_snapshot(ts, pos, yaw, vel, state)
	_received += 1
	var registry: PlayerRegistry = NetworkManager.get_registry()
	for peer: Variant in _ready_peers.keys():
		var pid: int = int(peer)
		if pid != sender and registry.has_player(pid):
			_rpc_state_update.rpc_id(pid, ts, pos, yaw, vel, state)

func _reject(peer_id: int, reason: String) -> void:
	_rejected += 1
	state_rejected.emit(peer_id, reason)
	_violations += 1
	var now_msec: int = Time.get_ticks_msec()
	if _violations >= VIOLATIONS_BEFORE_CORRECTION \
			and peer_id == _owner_peer_id and peer_id > NetworkConfig.SERVER_PEER_ID \
			and now_msec - _last_correction_msec >= CORRECTION_COOLDOWN_MSEC:
		_violations = 0
		_last_correction_msec = now_msec
		_last_accept_msec = now_msec
		var safe_pos: Vector3 = _last_accept_pos if _has_last else _body.global_position
		_rpc_correct.rpc_id(peer_id, safe_pos)

# ---------------- RPC: Host -> Clients ----------------

@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_state_update(t: float, pos: Vector3, yaw: float, vel: Vector3, state: int) -> void:
	if not NetworkManager.is_network_ready() or NetworkManager.is_host():
		return
	if multiplayer.get_remote_sender_id() != NetworkConfig.SERVER_PEER_ID:
		return
	if is_local_owner():
		return  # لا نقبل حالة لاعبنا المحلي من الشبكة
	if ingest_snapshot(t, pos, yaw, vel, state) == OK:
		_received += 1

## تصحيح من Host لمالك اللاعب بعد مخالفات متكررة.
@rpc("authority", "call_remote", "reliable")
func _rpc_correct(safe_pos: Vector3) -> void:
	if NetworkManager.is_host() or _body == null:
		return
	if multiplayer.get_remote_sender_id() != NetworkConfig.SERVER_PEER_ID or not is_local_owner():
		return
	if not safe_pos.is_finite():
		return
	_body.global_position = safe_pos
	if _body is CharacterBody3D:
		(_body as CharacterBody3D).velocity = Vector3.ZERO
	corrected.emit(safe_pos)
