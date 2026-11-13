extends Node3D
## scripts/levels/level_01.gd
## مرحلة 1 "الطريق المكسور": تايمر الفريق + خط النهاية.
## الـ host (أو أوفلاين) هو اللي بيقرر البداية والنهاية، والاتنين بيشوفوا نفس الوقت.
## بداية التايمر: أول ما الدراجة تتحرك. نهاية: أول ما الدراجة تلمس خط النهاية.

const SessionMode = preload("res://scripts/multiplayer/session_mode.gd")
const DebugLog = preload("res://scripts/systems/debug_log.gd")

@onready var _timer_label: Label = $HUD/TimerLabel
@onready var _result_label: Label = $HUD/ResultLabel

var elapsed: float = 0.0
var running: bool = false
var finished: bool = false


func _ready() -> void:
	add_to_group("level")
	_result_label.visible = false
	GDSync.expose_func(_apply_start, ENUMS.EXPOSE_PERMISSION.HOST)
	GDSync.expose_func(_apply_finish, ENUMS.EXPOSE_PERMISSION.HOST)
	_update_label()
	DebugLog.say("LEVEL", "جاهزة. online=%s authority=%s" % [_is_online(), _is_authority()])


func _is_online() -> bool:
	return not SessionMode.offline and GDSync.is_active()


# true عند اللي بيقرر: الـ host أو اللعب أوفلاين
func _is_authority() -> bool:
	return (not _is_online()) or GDSync.is_host()


func _physics_process(_delta: float) -> void:
	if running or finished or not _is_authority():
		return
	var unicycle := get_tree().get_first_node_in_group("unicycle") as RigidBody3D
	# السرعة الأفقية بس، عشان نزول الدراجة على الأرض في البداية ما يبدأش التايمر
	if unicycle != null and Vector2(unicycle.linear_velocity.x, unicycle.linear_velocity.z).length() > 1.0:
		if _is_online():
			GDSync.call_func_all(_apply_start)
		else:
			_apply_start()


func _process(delta: float) -> void:
	if running:
		elapsed += delta
		_update_label()


# بيتنادى من finish_line.gd
func on_finish_touched() -> void:
	if finished or not running or not _is_authority():
		return
	if _is_online():
		GDSync.call_func_all(_apply_finish, elapsed)
	else:
		_apply_finish(elapsed)


func _apply_start() -> void:
	if running or finished:
		return
	running = true
	DebugLog.say("LEVEL", "التايمر بدأ")


func _apply_finish(final_time: float) -> void:
	finished = true
	running = false
	elapsed = final_time
	DebugLog.say("LEVEL", "النهاية! الوقت = %s" % _format_time(elapsed))
	_update_label()
	_result_label.text = "FINISH!  %s\nLevel 1 complete - to be continued..." % _format_time(elapsed)
	_result_label.visible = true


func _update_label() -> void:
	_timer_label.text = _format_time(elapsed)


func _format_time(t: float) -> String:
	var minutes: int = floori(t / 60.0)
	var seconds: float = t - float(minutes) * 60.0
	return "%02d:%04.1f" % [minutes, seconds]
