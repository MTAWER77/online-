class_name NetworkClock
extends Node
## ساعة شبكية: Host هو المرجع، Client يقدّر Offset عبر عينات RTT متعددة.
## تعتمد على Time.get_ticks_usec() (Monotonic) فقط.
## تُنشأ كابن لـ NetworkManager باسم "NetworkClock" فيكون مسار RPC واحد على الجهازين:
## /root/NetworkManager/NetworkClock

signal sync_state_changed(synced: bool)
signal sample_added(rtt_usec: int, offset_sec: float)

enum Role { NONE, HOST, CLIENT }

const MAX_SAMPLES: int = 8
const MIN_SAMPLES_FOR_SYNC: int = 3
const BURST_PING_COUNT: int = 6
const BURST_INTERVAL_SEC: float = 0.15
const STEADY_INTERVAL_SEC: float = 2.0
const MAX_SLEW_PER_SEC: float = 0.1      # أقصى تغيّر في Offset لكل ثانية (الوقت لا يرجع للخلف)
const SNAP_THRESHOLD_SEC: float = 1.0    # فرق أكبر من كده = قفزة مقصودة
const MAX_ACCEPTED_RTT_USEC: int = 2_000_000
const PENDING_TIMEOUT_USEC: int = 5_000_000
const MIN_REQUEST_INTERVAL_USEC: int = 50_000
const MAX_PENDING: int = 16

var _role: Role = Role.NONE
var _epoch_usec: int = 0
var _offset: float = 0.0
var _target_offset: float = 0.0
var _rtt_usec: int = 0
var _samples: Array[Dictionary] = []
var _synced: bool = false
var _seq: int = 0
var _pending: Dictionary = {}            # seq -> send time (محلي)
var _pings_sent: int = 0
var _ping_timer: float = 0.0
var _last_request_usec: Dictionary = {}  # peer_id -> آخر طلب (Rate limit على Host)
var _debug_time_usec: int = -1           # للاختبارات فقط (-1 = معطّل)
var _peer_validator: Callable = Callable()

func _ready() -> void:
	set_process(false)

# ---------------- دورة الحياة ----------------

func set_peer_validator(validator: Callable) -> void:
	_peer_validator = validator

func start_as_host() -> void:
	stop()
	_role = Role.HOST
	_epoch_usec = _now_usec()
	_synced = true
	sync_state_changed.emit(true)

func start_as_client() -> void:
	stop()
	_role = Role.CLIENT
	_ping_timer = 0.0
	set_process(true)

## يوقف المزامنة ويصفّر كل الحالة (يُستدعى عند Disconnect وقبل أي جلسة جديدة).
func stop() -> void:
	if _role == Role.NONE:
		return
	var was_synced: bool = _synced
	_role = Role.NONE
	_epoch_usec = 0
	_offset = 0.0
	_target_offset = 0.0
	_rtt_usec = 0
	_samples.clear()
	_synced = false
	_seq = 0
	_pending.clear()
	_pings_sent = 0
	_ping_timer = 0.0
	_last_request_usec.clear()
	set_process(false)
	if was_synced:
		sync_state_changed.emit(false)

# ---------------- القراءة ----------------

func get_role() -> Role:
	return _role

func is_running() -> bool:
	return _role != Role.NONE

func is_synced() -> bool:
	return _synced

func get_local_time() -> float:
	return float(_now_usec()) / 1_000_000.0

## وقت Host المقدّر بالثواني (Host: منذ بدء الجلسة). 0.0 لو الساعة متوقفة.
## على Client قبل is_synced() القيمة تقريبية فقط.
func get_network_time() -> float:
	if _role == Role.HOST:
		return float(_now_usec() - _epoch_usec) / 1_000_000.0
	if _role == Role.CLIENT:
		return get_local_time() + _offset
	return 0.0

func get_network_time_usec() -> int:
	if _role == Role.HOST:
		return _now_usec() - _epoch_usec
	if _role == Role.CLIENT:
		return _now_usec() + int(_offset * 1_000_000.0)
	return 0

func get_offset() -> float:
	return _offset

func get_rtt_usec() -> int:
	return _rtt_usec

func get_rtt_ms() -> float:
	return float(_rtt_usec) / 1000.0

func get_sample_count() -> int:
	return _samples.size()

func get_state_text() -> String:
	if _role == Role.NONE:
		return "STOPPED"
	if _role == Role.HOST:
		return "HOST (reference)"
	if _synced:
		return "SYNCED"
	return "SYNCING (%d/%d)" % [_samples.size(), MIN_SAMPLES_FOR_SYNC]

## للاختبارات فقط: تثبيت مصدر الوقت. -1 للرجوع للوقت الحقيقي.
func set_debug_time_usec(value: int) -> void:
	_debug_time_usec = value

# ---------------- الحساب (static لسهولة الاختبار) ----------------

## sent/recv بالتوقيت المحلي للـ Client، host_time بتوقيت Host. يرجع {} لو العينة غير صالحة.
static func compute_sample(sent_usec: int, recv_usec: int, host_time_usec: int) -> Dictionary:
	var rtt: int = recv_usec - sent_usec
	if rtt < 0 or rtt > MAX_ACCEPTED_RTT_USEC or host_time_usec < 0:
		return {}
	var offset_usec: int = host_time_usec + (rtt >> 1) - recv_usec
	return {"rtt_usec": rtt, "offset": float(offset_usec) / 1_000_000.0}

## وسيط Offset لأفضل نصف عينات (الأقل RTT).
static func estimate_offset(samples: Array[Dictionary]) -> float:
	if samples.is_empty():
		return 0.0
	var sorted: Array[Dictionary] = []
	sorted.append_array(samples)
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["rtt_usec"]) < int(b["rtt_usec"]))
	var take: int = maxi(1, (sorted.size() + 1) >> 1)
	var offsets: PackedFloat64Array = PackedFloat64Array()
	for i: int in take:
		offsets.append(float(sorted[i]["offset"]))
	offsets.sort()
	var mid: int = offsets.size() >> 1
	if offsets.size() % 2 == 1:
		return offsets[mid]
	return (offsets[mid - 1] + offsets[mid]) * 0.5

## وسيط RTT لكل العينات.
static func estimate_rtt_usec(samples: Array[Dictionary]) -> int:
	if samples.is_empty():
		return 0
	var rtts: PackedInt64Array = PackedInt64Array()
	for s: Dictionary in samples:
		rtts.append(int(s["rtt_usec"]))
	rtts.sort()
	var mid: int = rtts.size() >> 1
	if rtts.size() % 2 == 1:
		return rtts[mid]
	return (rtts[mid - 1] + rtts[mid]) >> 1

## يضيف عينة (RTT + Offset). يرجع false لو مرفوضة أو الساعة ليست Client.
func submit_sample(rtt_usec: int, offset_sec: float) -> bool:
	if _role != Role.CLIENT:
		return false
	if rtt_usec < 0 or rtt_usec > MAX_ACCEPTED_RTT_USEC or not is_finite(offset_sec):
		return false
	_samples.append({"rtt_usec": rtt_usec, "offset": offset_sec})
	while _samples.size() > MAX_SAMPLES:
		_samples.pop_front()
	_target_offset = estimate_offset(_samples)
	_rtt_usec = estimate_rtt_usec(_samples)
	if not _synced:
		_offset = _target_offset
		if _samples.size() >= MIN_SAMPLES_FOR_SYNC:
			_synced = true
			sync_state_changed.emit(true)
	elif absf(_target_offset - _offset) > SNAP_THRESHOLD_SEC:
		_offset = _target_offset
	sample_added.emit(rtt_usec, offset_sec)
	return true

# ---------------- Client: إرسال الطلبات وتنعيم Offset ----------------

func _process(delta: float) -> void:
	if _role != Role.CLIENT:
		return
	if _synced:
		_offset = move_toward(_offset, _target_offset, MAX_SLEW_PER_SEC * delta)
	_prune_pending()
	_ping_timer -= delta
	if _ping_timer <= 0.0:
		var fast: bool = _pings_sent < BURST_PING_COUNT or not _synced
		_ping_timer = BURST_INTERVAL_SEC if fast else STEADY_INTERVAL_SEC
		_send_ping()

func _send_ping() -> void:
	if not _can_send() or _pending.size() >= MAX_PENDING:
		return
	_seq += 1
	_pending[_seq] = _now_usec()
	_pings_sent += 1
	_rpc_request_sync.rpc_id(NetworkConfig.SERVER_PEER_ID, _seq)

func _prune_pending() -> void:
	var now: int = _now_usec()
	for seq: Variant in _pending.keys():
		if now - int(_pending[seq]) > PENDING_TIMEOUT_USEC:
			_pending.erase(seq)

# ---------------- RPC ----------------

## Client -> Host فقط. Host يتحقق من هوية المرسل ويحدّ معدل الطلبات.
@rpc("any_peer", "call_remote", "unreliable")
func _rpc_request_sync(seq: int) -> void:
	if _role != Role.HOST or not _can_send():
		return
	var sender: int = multiplayer.get_remote_sender_id()
	if sender <= 0 or sender == NetworkConfig.SERVER_PEER_ID:
		return
	if not _peer_validator.is_valid() or not bool(_peer_validator.call(sender)):
		return
	var now: int = _now_usec()
	if now - int(_last_request_usec.get(sender, -MIN_REQUEST_INTERVAL_USEC)) < MIN_REQUEST_INTERVAL_USEC:
		return
	_last_request_usec[sender] = now
	_rpc_sync_response.rpc_id(sender, seq, get_network_time_usec())

## Host -> Client فقط (authority = Host). Client يتجاهل أي رد من غير Host أو بدون طلب معلّق.
@rpc("authority", "call_remote", "unreliable")
func _rpc_sync_response(seq: int, host_time_usec: int) -> void:
	if _role != Role.CLIENT:
		return
	if multiplayer.get_remote_sender_id() != NetworkConfig.SERVER_PEER_ID:
		return
	var recv: int = _now_usec()
	if not _pending.has(seq):
		return
	var sent: int = int(_pending[seq])
	_pending.erase(seq)
	var sample: Dictionary = compute_sample(sent, recv, host_time_usec)
	if sample.is_empty():
		return
	submit_sample(int(sample["rtt_usec"]), float(sample["offset"]))

# ---------------- داخلي ----------------

func _now_usec() -> int:
	return _debug_time_usec if _debug_time_usec >= 0 else Time.get_ticks_usec()

func _can_send() -> bool:
	if not is_inside_tree() or not multiplayer.has_multiplayer_peer():
		return false
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	if peer == null or peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return false
	if _role == Role.HOST:
		return multiplayer.is_server()
	if _role == Role.CLIENT:
		return not multiplayer.is_server()
	return false
