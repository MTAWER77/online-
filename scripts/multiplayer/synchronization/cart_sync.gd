class_name CartSync
extends Node
## scripts/multiplayer/synchronization/cart_sync.gd — مزامنة عربية التسوق (المرحلة 5).
##
## يُوضع كابن اسمه "CartSync" تحت جسم العربية (CharacterBody3D) ليبقى مسار الـ RPC
## متطابقًا على الجهازين:
##     /root/<المشهد>/<مسار العربية>/CartSync
##
## النموذج: Host-Authoritative (مصدر حالة واحد)
##  - الـ Host هو الوحيد الذي يحسب فيزياء العربية (Position / Rotation / Velocity)،
##    وهو الوحيد الذي يبث الحالة. لذلك لا يمكن أن تختلف العربية بين الجهازين:
##    الـ Client لا يحاكي الفيزياء ولا يكتب الـ transform إلا من اللقطات المستلمة.
##  - لقطة واحدة كل SEND_INTERVAL_SEC عبر unreliable_ordered (لا تراكم عند التأخر).
##  - العرض عند الـ Client: SnapshotBuffer (من المرحلة 4) + NetworkClock.get_network_time()
##    بتأخير ثابت (interpolation delay) لاستيفاء ناعم بين لقطتين، مع استيفاء محدود
##    (MAX_EXTRAPOLATION_SEC) لو الحزم تأخرت لحظة واحدة.
##  - المدخلات (بنزين/فرامل) تسير بالاتجاه المعاكس: Client -> Host عبر
##    unreliable_ordered، ويتحقق الـ Host من المصدر (peer مسجّل وليس هو نفسه)
##    ومن القيم ومن معدل الإرسال قبل قبولها.
##  - انضمام/مغادرة: handshake (hello/ack) ثم لقطة catch-up فورية للاعب الجديد،
##    ومغادرة اللاعب تلغي مدخلاته (يتوقف البنزين) وتُزال من قائمة الإرسال.
##
## التوافق: Godot 4.x — لا يعتمد على أي سكربت شبكة جديد. يستخدم فقط:
##   NetworkManager / NetworkConfig / NetworkClock / SnapshotBuffer / PlayerRegistry.

signal respawn_received(pos: Vector3, yaw: float)
signal peer_lost(peer_id: int)
signal state_rejected(reason: String)

# =====================================================================
# ثوابت
# =====================================================================

const SEND_INTERVAL_SEC: float = 0.05          ## معدل الإرسال الافتراضي (20 لقطة/ثانية)
const BUFFER_CAPACITY: int = 64                ## سعة SnapshotBuffer
const DEFAULT_INTERPOLATION_DELAY_SEC: float = 0.10
const MAX_EXTRAPOLATION_SEC: float = 0.15      ## أقصى استيفاء عند تأخر الحزم
const BUFFER_PRUNE_SEC: float = 0.5            ## نحذف اللقطات الأقدم من RenderTime - هذا

const MAX_PLAUSIBLE_SPEED: float = 30.0        ## أقصى سرعة مقبولة بين لقطتين (م/ث)
const PLAUSIBILITY_MARGIN: float = 1.5         ## هامش تسامح لحركة غير مثالية
const MAX_VELOCITY: float = 40.0               ## أقصى طول للـ velocity المسموح
const WORLD_LIMIT: float = 1000.0              ## حدود العالم المعقولة
const MAX_CRASH_SEC: float = 5.0               ## أقصى مدة انهيار مقبولة

const MAX_TS_PAST_SEC: float = 1.0
const MAX_TS_FUTURE_SEC: float = 0.25
const MIN_PACKET_INTERVAL_MSEC: int = 10       ## حد أدنى بين لقطتين (حماية من الإغراق)
const INPUT_MIN_INTERVAL_MSEC: int = 5         ## حد أدنى بين حزم المدخلات

const HELLO_FIRST_DELAY_SEC: float = 0.2
const HELLO_INTERVAL_SEC: float = 0.25
const PEER_LOST_TIMEOUT_SEC: float = 3.0
const PEER_WATCH_INTERVAL_SEC: float = 0.5
# =====================================================================
# حالة داخلية
# =====================================================================

var _body: Node3D = null
var _buffer: SnapshotBuffer = null

var _is_online: bool = false
var _is_host: bool = false
var _is_client: bool = false

var _send_interval: float = SEND_INTERVAL_SEC
var _interp_delay: float = DEFAULT_INTERPOLATION_DELAY_SEC
var _max_extrapolation: float = MAX_EXTRAPOLATION_SEC
var _peer_lost_timeout: float = PEER_LOST_TIMEOUT_SEC
var _send_accum: float = 0.0
var _watch_accum: float = 0.0

var _hello_timer: float = HELLO_FIRST_DELAY_SEC
var _host_acked: bool = false
var _ready_peers: Dictionary = {}            ## peer_id -> true (بعد handshake)
var _remote_inputs: Dictionary = {}          ## peer_id -> {gas, brake, msec}
var _missing_since: Dictionary = {}          ## peer_id -> msec (لماذا غاب)

var _epoch: int = 0                          ## يزيد مع كل respawn (يلغي اللقطات القديمة)
var _snap_seq: int = 0
var _in_seq: int = 0
var _latest_state: Dictionary = {}           ## آخر حالة نشرها الـ Host

var _has_last: bool = false
var _last_accept_pos: Vector3 = Vector3.ZERO
var _last_accept_msec: int = 0
var _last_packet_msec: int = 0
var _last_input_packet_msec: int = 0

var _remote_state: Dictionary = {}           ## آخر حالة تم استيفاؤها (للتشخيص)

var _sent: int = 0
var _received: int = 0
var _rejected: int = 0
var _inputs_rx: int = 0
var _extrapolations: int = 0

# =====================================================================
# التحقق (static — قابل للاختبار بدون شبكة)
# =====================================================================

## تتحقق من معقولية لقطة واردة قبل قبولها.
static func is_state_valid(pos: Vector3, yaw: float, vel: Vector3, steer: float, gas: float, brake: float, crash: float) -> bool:
	if not pos.is_finite() or not vel.is_finite() or not is_finite(yaw):
		return false
	if absf(pos.x) > WORLD_LIMIT or absf(pos.y) > WORLD_LIMIT or absf(pos.z) > WORLD_LIMIT:
		return false
	if vel.length() > MAX_VELOCITY:
		return false
	if not is_finite(steer) or not is_finite(gas) or not is_finite(brake) or not is_finite(crash):
		return false
	if absf(steer) > 1.5:
		return false
	if gas < -0.01 or gas > 1.01:
		return false
	if brake < -0.01 or brake > 1.01:
		return false
	if crash < -0.01 or crash > MAX_CRASH_SEC:
		return false
	return true


## حركة معقولة بين لقطتين؟ (يمنع قفزات مستحيلة مثل 80 متر في لقطة).
static func is_move_plausible(from_pos: Vector3, to_pos: Vector3, dt_sec: float) -> bool:
	var dt: float = maxf(dt_sec, SEND_INTERVAL_SEC)
	return from_pos.distance_to(to_pos) <= MAX_PLAUSIBLE_SPEED * dt + PLAUSIBILITY_MARGIN


## توقيت غير منطقي يُستبدل بوقت الجهاز الحالي.
static func resolve_timestamp(t: float, now_t: float) -> float:
	if is_finite(t) and t >= now_t - MAX_TS_PAST_SEC and t <= now_t + MAX_TS_FUTURE_SEC:
		return t
	return now_t


## مدخلات (بنزين/فرامل) صالحة؟
static func is_input_valid(gas: float, brake: float) -> bool:
	if not is_finite(gas) or not is_finite(brake):
		return false
	if gas < -0.01 or gas > 1.01:
		return false
	if brake < -0.01 or brake > 1.01:
		return false
	return true


static func clamp_input(value: float) -> float:
	if not is_finite(value):
		return 0.0
	return clampf(value, 0.0, 1.0)

# =====================================================================
# الإعداد
# =====================================================================

## يُستدعى من سكربت العربية (shopping_cart.gd) قبل بدء التشغيل.
func configure(send_hz: float, interpolation_delay_sec: float, max_extrapolation_sec: float = MAX_EXTRAPOLATION_SEC, peer_lost_timeout_sec: float = PEER_LOST_TIMEOUT_SEC) -> void:
	_send_interval = 1.0 / maxf(send_hz, 1.0)
	_interp_delay = maxf(interpolation_delay_sec, 0.0)
	_max_extrapolation = maxf(max_extrapolation_sec, 0.0)
	_peer_lost_timeout = maxf(peer_lost_timeout_sec, 0.1)


func _ready() -> void:
	_body = get_parent() as Node3D
	_buffer = SnapshotBuffer.new(BUFFER_CAPACITY)
	var angle_keys: Array[StringName] = [&"yaw"]
	_buffer.set_angle_keys(angle_keys)
	_refresh_role()
	# تغيّر قاعدة الزمن (من وقت الجهاز المحلي إلى وقت الـ Host) يجعل الطوابع القديمة عديمة القيمة.
	var clock: NetworkClock = NetworkManager.get_clock()
	if clock != null:
		clock.sync_state_changed.connect(_on_clock_sync_changed)


## لما الساعة تتزامن (أو توقفت) نمسح اللقطات: الطوابع القديمة كانت على قاعدة زمنية مختلفة.
func _on_clock_sync_changed(_synced: bool) -> void:
	if _buffer != null:
		_buffer.clear()
	_has_last = false


func _process(delta: float) -> void:
	_update_role()
	if _is_client:
		_update_hello(delta)
	_update_peer_watch(delta)

# =====================================================================
# الدور (Host / Client / Offline)
# =====================================================================

func _refresh_role() -> void:
	_is_online = NetworkManager.is_network_ready()
	_is_host = _is_online and NetworkManager.is_host()
	_is_client = _is_online and not _is_host


func _update_role() -> void:
	var online: bool = NetworkManager.is_network_ready()
	if online == _is_online:
		return
	_refresh_role()
	if _is_client:
		_hello_timer = 0.0
		_host_acked = false


func is_host_side() -> bool:
	return _is_host


func is_client_side() -> bool:
	return _is_client


func is_online() -> bool:
	return _is_online

# =====================================================================
# Host: نشر الحالة
# =====================================================================

## تستدعيها العربية كل خطوة فيزياء (Host فقط يرسل).
func publish_state(pos: Vector3, yaw: float, vel: Vector3, steer: float, gas: float, brake: float, crash: float, delta: float) -> void:
	_latest_state = {
		"pos": pos, "yaw": yaw, "vel": vel,
		"steer": steer, "gas": gas, "brake": brake, "crash": crash,
	}
	if not _is_host:
		return
	_send_accum += delta
	if _send_accum < _send_interval:
		return
	_send_accum = 0.0
	_broadcast_snapshot()


func _broadcast_snapshot() -> void:
	if _latest_state.is_empty():
		return
	for peer: Variant in _ready_peers.keys():
		_send_snapshot_to(int(peer))


func _send_snapshot_to(peer: int) -> void:
	if _latest_state.is_empty():
		return
	_snap_seq += 1
	_sent += 1
	var s: Dictionary = _latest_state
	_rpc_snapshot.rpc_id(peer, _epoch, _snap_seq, _now_time(),
		s["pos"], s["yaw"], s["vel"], s["steer"], s["gas"], s["brake"], s["crash"])


## الـ Host يعلن إعادة ظهور (انتقال مفاجئ) => العميل يطبقها فورًا.
func notify_respawn(pos: Vector3, yaw: float) -> void:
	if not _is_host:
		return
	_epoch += 1
	for peer: Variant in _ready_peers.keys():
		_rpc_respawn.rpc_id(int(peer), _epoch, pos, yaw)

# =====================================================================
# Client: إرسال المدخلات + استقبال اللقطات
# =====================================================================

## ترسلها العربية كل فترة إدخال محددة (Client فقط).
func send_input(gas: float, brake: float) -> void:
	if not _is_client or not _host_acked:
		return
	if not is_input_valid(gas, brake):
		return
	_in_seq += 1
	_rpc_input.rpc_id(NetworkConfig.SERVER_PEER_ID, _in_seq, clamp_input(gas), clamp_input(brake))


## آخر مدخلات (بنزين/فرامل) وصلت من أي peer + عمرها بالثواني.
func get_remote_input() -> Vector2:
	var out: Vector2 = Vector2.ZERO
	var best_age: int = 1 << 30
	var now: int = Time.get_ticks_msec()
	for peer: Variant in _remote_inputs.keys():
		var d: Dictionary = _remote_inputs[peer]
		var age: int = now - int(d["msec"])
		if age < best_age:
			best_age = age
			out = Vector2(float(d["gas"]), float(d["brake"]))
	return out


func get_remote_input_age() -> float:
	var best_age: int = 1 << 30
	var now: int = Time.get_ticks_msec()
	for peer: Variant in _remote_inputs.keys():
		var d: Dictionary = _remote_inputs[peer]
		best_age = mini(best_age, now - int(d["msec"]))
	if best_age == (1 << 30):
		return 999.0
	return float(best_age) / 1000.0

# =====================================================================
# Client: الاستيفاء والعرض
# =====================================================================

## يقرأ الحالة المستوفاة عند زمن العرض. يرجع {valid, state, extrapolated}.
func sample_state() -> Dictionary:
	if _buffer == null or _buffer.is_empty():
		return {"valid": false, "state": {}, "extrapolated": false}
	var clock: NetworkClock = NetworkManager.get_clock()
	if clock == null:
		return {"valid": false, "state": {}, "extrapolated": false}
	var render_t: float = clock.get_network_time() - _interp_delay
	if not clock.is_synced():
		render_t = _buffer.get_latest_time()
	var res: Dictionary = _buffer.sample(render_t)
	if not bool(res.get("valid", false)):
		return {"valid": false, "state": {}, "extrapolated": false}
	var st: Dictionary = (res["state"] as Dictionary).duplicate(true)
	var latest: float = _buffer.get_latest_time()
	var extra: float = 0.0
	if render_t > latest:
		extra = minf(render_t - latest, _max_extrapolation)
		if extra > 0.0:
			_extrapolations += 1
			var vel: Vector3 = st.get("vel", Vector3.ZERO) as Vector3
			var pos: Vector3 = st.get("pos", Vector3.ZERO) as Vector3
			st["pos"] = pos + vel * extra
	_buffer.prune_older_than(render_t - BUFFER_PRUNE_SEC)
	return {"valid": true, "state": st, "extrapolated": extra > 0.0}


## نفس sample_state لكن بزمن محدد (للاختبارات المنطقية).
func render_at(render_time: float) -> bool:
	if _buffer == null or _buffer.is_empty():
		return false
	var res: Dictionary = _buffer.sample(render_time)
	if not bool(res.get("valid", false)):
		return false
	_remote_state = (res["state"] as Dictionary).duplicate(true)
	return true


func get_remote_state() -> Dictionary:
	return _remote_state


func has_data() -> bool:
	return _buffer != null and not _buffer.is_empty()


func get_buffer_size() -> int:
	if _buffer == null:
		return 0
	return _buffer.size()


## يخزّن لقطة في الـ SnapshotBuffer (نفس دالة PlayerSync).
func ingest_snapshot(ts: float, pos: Vector3, yaw: float, vel: Vector3, steer: float, gas: float, brake: float, crash: float) -> Error:
	if not is_state_valid(pos, yaw, vel, steer, gas, brake, crash) or not is_finite(ts):
		return ERR_INVALID_DATA
	var state: Dictionary = {
		"pos": pos, "yaw": yaw, "vel": vel,
		"steer": steer, "gas": gas, "brake": brake, "crash": crash,
	}
	return _buffer.add(ts, state)

# =====================================================================
# انضمام / مغادرة
# =====================================================================

func _update_hello(delta: float) -> void:
	if _host_acked:
		return
	_hello_timer -= delta
	if _hello_timer > 0.0:
		return
	_hello_timer = HELLO_INTERVAL_SEC
	_rpc_hello.rpc_id(NetworkConfig.SERVER_PEER_ID)


## يراقب قائمة اللاعبين: من غاب يُزال من الإرسال بعد مهلة، ومن يعود يُضاف.
func _update_peer_watch(delta: float) -> void:
	if not _is_host:
		return
	_watch_accum += delta
	if _watch_accum < PEER_WATCH_INTERVAL_SEC:
		return
	_watch_accum = 0.0
	var peers: Array = _current_peer_ids()
	var now: int = Time.get_ticks_msec()
	var known: Array = _ready_peers.keys()
	for peer: Variant in known:
		var pid: int = int(peer)
		if peers.has(pid):
			_missing_since.erase(pid)
			continue
		var since: int = int(_missing_since.get(pid, 0))
		if since == 0:
			_missing_since[pid] = now
			continue
		if now - since > int(_peer_lost_timeout * 1000.0):
			_missing_since.erase(pid)
			_ready_peers.erase(pid)
			_remote_inputs.erase(pid)
			peer_lost.emit(pid)


func _current_peer_ids() -> Array:
	var out: Array = []
	var registry: PlayerRegistry = NetworkManager.get_registry()
	if registry == null:
		return out
	var ids: Array = registry.get_peer_ids()
	var me: int = NetworkManager.get_local_peer_id()
	for v: Variant in ids:
		var pid: int = int(v)
		if pid != me:
			out.append(pid)
	return out


## هل هذا المرسل موثوق (peer مسجّل وليس الـ host)؟
func is_trusted_sender(peer_id: int) -> bool:
	if peer_id <= NetworkConfig.SERVER_PEER_ID:
		return false
	if peer_id == NetworkManager.get_local_peer_id():
		return false
	var registry: PlayerRegistry = NetworkManager.get_registry()
	if registry == null:
		return false
	return registry.has_player(peer_id)

# =====================================================================
# إحصائيات
# =====================================================================

func get_stats() -> Dictionary:
	return {
		"sent": _sent,
		"received": _received,
		"rejected": _rejected,
		"inputs": _inputs_rx,
		"buffered": get_buffer_size(),
		"peers": _ready_peers.size(),
		"extrapolations": _extrapolations,
		"acked": _host_acked,
	}


func _reject(reason: String) -> void:
	_rejected += 1
	state_rejected.emit(reason)


func _now_time() -> float:
	var clock: NetworkClock = NetworkManager.get_clock()
	if clock == null:
		return float(Time.get_ticks_msec()) / 1000.0
	return clock.get_network_time()

# =====================================================================
# RPC: Handshake
# =====================================================================

@rpc("any_peer", "call_remote", "reliable")
func _rpc_hello() -> void:
	if not NetworkManager.is_network_ready() or not NetworkManager.is_host():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if not is_trusted_sender(sender):
		return
	_ready_peers[sender] = true
	_missing_since.erase(sender)
	_rpc_hello_ack.rpc_id(sender)
	# لقطة catch-up فورية: اللاعب الجديد ما يستنش دورة كاملة قبل أول لقطة.
	_send_snapshot_to(sender)


@rpc("authority", "call_remote", "reliable")
func _rpc_hello_ack() -> void:
	if NetworkManager.is_host():
		return
	if multiplayer.get_remote_sender_id() != NetworkConfig.SERVER_PEER_ID:
		return
	_host_acked = true

# =====================================================================
# RPC: Host -> Client (لقطة)
# =====================================================================

@rpc("authority", "call_remote", "unreliable_ordered")
func _rpc_snapshot(epoch: int, seq: int, t: float, pos: Vector3, yaw: float, vel: Vector3, steer: float, gas: float, brake: float, crash: float) -> void:
	if not NetworkManager.is_network_ready() or NetworkManager.is_host():
		return
	if multiplayer.get_remote_sender_id() != NetworkConfig.SERVER_PEER_ID:
		_reject("untrusted source")
		return
	var now_msec: int = Time.get_ticks_msec()
	if now_msec - _last_packet_msec < MIN_PACKET_INTERVAL_MSEC:
		return
	_last_packet_msec = now_msec
	if not is_state_valid(pos, yaw, vel, steer, gas, brake, crash):
		_reject("invalid data")
		return
	if epoch < _epoch:
		return
	if epoch > _epoch:
		_epoch = epoch
		_has_last = false
		# clear() مش prune: الـ prune بيقّي لقطتين قديمتين، وده بيعمل مزج غلط بعد الـ respawn.
		_buffer.clear()
	if _has_last:
		var dt: float = float(now_msec - _last_accept_msec) / 1000.0
		if not is_move_plausible(_last_accept_pos, pos, dt):
			_reject("implausible movement")
			return
	_has_last = true
	_last_accept_pos = pos
	_last_accept_msec = now_msec
	var ts: float = resolve_timestamp(t, _now_time())
	if ingest_snapshot(ts, pos, yaw, vel, steer, gas, brake, crash) == OK:
		_received += 1


@rpc("authority", "call_remote", "reliable")
func _rpc_respawn(epoch: int, pos: Vector3, yaw: float) -> void:
	if not NetworkManager.is_network_ready() or NetworkManager.is_host():
		return
	if multiplayer.get_remote_sender_id() != NetworkConfig.SERVER_PEER_ID:
		_reject("untrusted source")
		return
	if not pos.is_finite() or not is_finite(yaw):
		_reject("invalid respawn")
		return
	apply_respawn(epoch, pos, yaw)


## يطبّق إعادة الظهور (يستدعى من الـ RPC أو من الاختبارات).
func apply_respawn(epoch: int, pos: Vector3, yaw: float) -> bool:
	if epoch < _epoch:
		return false
	_epoch = epoch
	_has_last = false
	if _buffer != null:
		_buffer.clear()
	respawn_received.emit(pos, yaw)
	return true

# =====================================================================
# RPC: Client -> Host (مدخلات)
# =====================================================================

@rpc("any_peer", "call_remote", "unreliable_ordered")
func _rpc_input(seq: int, gas: float, brake: float) -> void:
	if not NetworkManager.is_network_ready() or not NetworkManager.is_host():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if not is_trusted_sender(sender):
		_reject("untrusted input")
		return
	var now_msec: int = Time.get_ticks_msec()
	if now_msec - _last_input_packet_msec < INPUT_MIN_INTERVAL_MSEC:
		return
	_last_input_packet_msec = now_msec
	if not is_input_valid(gas, brake):
		_reject("invalid input")
		return
	_remote_inputs[sender] = {
		"gas": clamp_input(gas),
		"brake": clamp_input(brake),
		"msec": now_msec,
	}
	_inputs_rx += 1
