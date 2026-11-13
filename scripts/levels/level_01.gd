extends Node3D
## scripts/levels/level_01.gd
## المرحلة 1 "الطريق المكسور": تايمر الفريق + خط النهاية.
## التصميم: المضيف هو السلطة، يحسب الوقت محليًا ويزامن دوريًا إلى العملاء.
## العملاء لا يجمعون delta محليًا، بل يستخدمون lerp لمحاكاة عرض الوقت بسلاسة.

const SessionMode = preload("res://scripts/multiplayer/session_mode.gd")
const DebugLog = preload("res://scripts/systems/debug_log.gd")

@onready var _timer_label: Label = $HUD/TimerLabel
@onready var _result_label: Label = $HUD/ResultLabel

# ========== حالة المضيف ==========
var elapsed: float = 0.0
var running: bool = false
var finished: bool = false

# ========== حالة العميل (للعرض) ==========
var _display_elapsed: float = 0.0          # الوقت المعروض على العميل
var _target_elapsed: float = 0.0           # آخر قيمة وقت مستلمة من المضيف

# ========== ثوابت المزامنة ==========
const SYNC_INTERVAL := 0.25                # المضيف يرسل الفاصل الزمني للمزامنة
const CLIENT_LERP_SPEED := 8.0             # سرعة lerp للعميل

var _sync_accum: float = 0.0               # مؤقت تراكمي لإرسال المزامنة على المضيف


func _ready() -> void:
	add_to_group("level")
	_result_label.visible = false

	# expose دوال RPC
	GDSync.expose_func(_apply_start, ENUMS.EXPOSE_PERMISSION.HOST)
	GDSync.expose_func(_apply_finish, ENUMS.EXPOSE_PERMISSION.HOST)
	GDSync.expose_func(_sync_time, ENUMS.EXPOSE_PERMISSION.HOST)
	GDSync.expose_func(_request_state, ENUMS.EXPOSE_PERMISSION.ANYONE)

	_update_label()

	# العميل: طلب الحالة الحالية من المضيف عند البدء (دعم الانضمام المتأخر)
	if _is_online() and not _is_authority():
		call_deferred("_request_state_from_host")

	DebugLog.say("LEVEL", "جاهزة. online=%s authority=%s" % [_is_online(), _is_authority()])


func _is_online() -> bool:
	return not SessionMode.offline and GDSync.is_active()


func _is_authority() -> bool:
	return (not _is_online()) or GDSync.is_host()


# ========== دورة حياة المضيف ==========

func _physics_process(_delta: float) -> void:
	if not _is_authority():
		return
	if running or finished:
		return

	var unicycle := get_tree().get_first_node_in_group("unicycle") as RigidBody3D
	if unicycle != null and Vector2(unicycle.linear_velocity.x, unicycle.linear_velocity.z).length() > 1.0:
		# إصلاح حالة السباق: التنفيذ المحلي أولاً، ثم إخطار الآخرين
		_apply_start()
		if _is_online():
			GDSync.call_func(_apply_start)


func _process(delta: float) -> void:
	if _is_authority():
		_process_host(delta)
	else:
		_process_client(delta)


func _process_host(delta: float) -> void:
	if not running:
		return

	elapsed += delta
	_update_label()

	# مزامنة دورية إلى العملاء
	if _is_online():
		_sync_accum += delta
		if _sync_accum >= SYNC_INTERVAL:
			_sync_accum = 0.0
			GDSync.call_func(_sync_time, elapsed)


func _process_client(delta: float) -> void:
	if not running and not finished:
		return

	# lerp سلس نحو وقت المضيف، بدون قفزات
	_display_elapsed = lerp(_display_elapsed, _target_elapsed, delta * CLIENT_LERP_SPEED)

	# عندما يكون الفارق صغيرًا جدًا، التصاق مباشر لتجنب الاهتزاز
	if absf(_display_elapsed - _target_elapsed) < 0.02:
		_display_elapsed = _target_elapsed

	_timer_label.text = _format_time(_display_elapsed)


# ========== دوال RPC ==========

func _request_state() -> void:
	# يستدعيها العميل، ويستجيب لها المضيف
	if not _is_authority():
		return
	GDSync.call_func_on(GDSync.get_sender_id(), _sync_time, elapsed)


func _sync_time(host_elapsed: float) -> void:
	if _is_authority():
		return
	_target_elapsed = host_elapsed


func _request_state_from_host() -> void:
	# العميل يطلب الحالة من المضيف
	if _is_authority():
		return
	GDSync.call_func(_request_state)


# ========== البداية والنهاية ==========

func on_finish_touched() -> void:
	if finished or not running or not _is_authority():
		return
	# إصلاح حالة السباق: التنفيذ المحلي أولاً
	_apply_finish(elapsed)
	if _is_online():
		GDSync.call_func(_apply_finish, elapsed)


func _apply_start() -> void:
	if running or finished:
		return
	running = true
	_sync_accum = 0.0
	# العميل يصفّر العرض، وينتظر أول مزامنة من المضيف
	if not _is_authority():
		_display_elapsed = 0.0
		_target_elapsed = 0.0
	DebugLog.say("LEVEL", "التايمر بدأ")


func _apply_finish(final_time: float) -> void:
	if finished:
		return
	finished = true
	running = false

	if _is_authority():
		elapsed = final_time
	else:
		# العميل: عرض الوقت النهائي مباشرة، بدون lerp
		_display_elapsed = final_time
		_target_elapsed = final_time

	_update_label()
	_result_label.text = "FINISH!  %s\nLevel 1 complete - to be continued..." % _format_time(_display_elapsed)
	_result_label.visible = true
	DebugLog.say("LEVEL", "النهاية! الوقت = %s" % _format_time(final_time))


# ========== واجهة المستخدم ==========

func _update_label() -> void:
	if _is_authority():
		_timer_label.text = _format_time(elapsed)


func _format_time(t: float) -> String:
	if is_nan(t) or t < 0.0:
		t = 0.0
	var minutes: int = floori(t / 60.0)
	var seconds: float = t - float(minutes) * 60.0
	return "%02d:%04.1f" % [minutes, seconds]
