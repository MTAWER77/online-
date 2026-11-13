extends CanvasLayer
## scripts/ui/stats_overlay.gd
## بيعرض الـ FPS والـ ping (بالـ ms) فوق على اليمين. الـ ping بيتقاس مع اللاعب التاني كل كام ثانية.
## القيمة اللي بترجع من GDSync.get_client_ping بالثواني وبتمثل رحلة ذهاب وإياب (RTT).

const SessionMode = preload("res://scripts/multiplayer/session_mode.gd")

@export var fps_interval: float = 0.5
@export var ping_interval: float = 2.0

@onready var _label: Label = $Label

var _fps_timer: float = 0.0
var _ping_timer: float = 0.0
var _pinging: bool = false
var _ping_text: String = "-"


func _process(delta: float) -> void:
	_fps_timer += delta
	_ping_timer += delta
	if _fps_timer >= fps_interval:
		_fps_timer = 0.0
		_refresh_label()
	if _ping_timer >= ping_interval and not _pinging:
		_ping_timer = 0.0
		_measure_ping()


func _refresh_label() -> void:
	_label.text = "FPS %d\nPing %s" % [Engine.get_frames_per_second(), _ping_text]


func _measure_ping() -> void:
	if SessionMode.offline or not GDSync.is_active():
		_ping_text = "offline"
		return
	var my_id: int = GDSync.get_client_id()
	var other_id: int = -1
	for id: int in GDSync.lobby_get_all_clients():
		if id != my_id:
			other_id = id
			break
	if other_id == -1:
		_ping_text = "-"
		return
	_pinging = true
	var seconds: float = await GDSync.get_client_ping(other_id)
	_pinging = false
	_ping_text = "-" if seconds < 0.0 else "%d ms" % roundi(seconds * 1000.0)
