extends Control
## scripts/ui/main_menu.gd
## الواجهة موجودة في main_menu.tscn (تقدر تعدّل شكلها من المحرر).
## Host: يعمل روم وكود. Join: تكتب الكود وتدخل الروم.
## التاني يدوس Ready، والـ host يدوس Start فيدخلوا اللعبة.

@export_file("*.tscn") var game_scene: String = "res://scenes/worlds/test_room.tscn"

const SessionMode = preload("res://scripts/multiplayer/session_mode.gd")

const CODE_CHARS: String = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" # من غير حروف بتتلخبط (O/0, I/1)
const CODE_LENGTH: int = 5
const MAX_PLAYERS: int = 2
const READY_KEY: String = "ready"

@onready var _status_label: Label = %StatusLabel

@onready var _menu_screen: VBoxContainer = %MenuScreen
@onready var _offline_button: Button = %OfflineButton
@onready var _host_button: Button = %HostButton
@onready var _join_button: Button = %JoinButton

@onready var _join_screen: VBoxContainer = %JoinScreen
@onready var _code_input: LineEdit = %CodeInput
@onready var _confirm_join_button: Button = %ConfirmJoinButton
@onready var _back_button: Button = %BackButton

@onready var _room_screen: VBoxContainer = %RoomScreen
@onready var _code_label: Label = %CodeLabel
@onready var _players_label: Label = %PlayersLabel
@onready var _ready_button: Button = %ReadyButton
@onready var _start_button: Button = %StartButton
@onready var _leave_button: Button = %LeaveButton

var _connected: bool = false
var _busy: bool = false: set = _set_busy # في عملية جارية (إنشاء أو دخول)
var _starting: bool = false
var _busy_timer: SceneTreeTimer


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	SessionMode.offline = false
	_offline_button.pressed.connect(_on_offline_pressed)
	_host_button.pressed.connect(_on_host_pressed)
	_join_button.pressed.connect(_on_join_screen_pressed)
	_confirm_join_button.pressed.connect(_on_confirm_join_pressed)
	_code_input.text_submitted.connect(func(_text: String) -> void: _on_confirm_join_pressed())
	_back_button.pressed.connect(_on_back_pressed)
	_ready_button.toggled.connect(_on_ready_toggled)
	_start_button.pressed.connect(_on_start_pressed)
	_leave_button.pressed.connect(_on_leave_pressed)

	GDSync.connected.connect(_on_connected)
	GDSync.connection_failed.connect(_on_connection_failed)
	GDSync.lobby_created.connect(_on_lobby_created)
	GDSync.lobby_creation_failed.connect(_on_lobby_creation_failed)
	GDSync.lobby_joined.connect(_on_lobby_joined)
	GDSync.lobby_join_failed.connect(_on_lobby_join_failed)
	GDSync.client_joined.connect(_refresh_lobby_signal)
	GDSync.client_left.connect(_refresh_lobby_signal)
	GDSync.player_data_changed.connect(_on_player_data_changed)
	GDSync.host_changed.connect(_on_host_changed)
	GDSync.change_scene_failed.connect(_on_change_scene_failed)

	_show_screen("connecting")
	if GDSync.is_active():
		_on_connected()
	else:
		GDSync.start_multiplayer()


func _set_busy(value: bool) -> void:
	_busy = value
	# نقفل الأزرار أثناء العملية عشان ما يتبعتش طلبات كتير ورا بعض
	for b in [_host_button, _join_button, _confirm_join_button, _back_button]:
		if b != null:
			b.disabled = value
	if value:
		# لو السيرفر ما ردّش خلال 10 ثواني نفك القفل
		_busy_timer = get_tree().create_timer(10.0)
		var t: SceneTreeTimer = _busy_timer
		t.timeout.connect(func() -> void:
			if _busy and _busy_timer == t:
				_busy = false
				_set_status("السيرفر مردّش، جرّب تاني"))


# ------------------------------------------------------------------ الاتصال

func _on_connected() -> void:
	_connected = true
	_set_status("")
	_show_screen("menu")


func _on_connection_failed(error: int) -> void:
	match error:
		ENUMS.CONNECTION_FAILED.INVALID_PUBLIC_KEY:
			_set_status("الاتصال فشل: مفاتيح GD-Sync غلط")
		ENUMS.CONNECTION_FAILED.TIMEOUT:
			_set_status("الاتصال فشل: تأكد من النت")
		_:
			_set_status("الاتصال فشل (%d)" % error)


# ------------------------------------------------------------------ أوفلاين

# لاعب واحد من غير GD-Sync: نقفل الاتصال ونفتح اللعبة على طول
func _on_offline_pressed() -> void:
	if GDSync.is_active():
		GDSync.stop_multiplayer()
	SessionMode.offline = true
	get_tree().change_scene_to_file(game_scene)


# ------------------------------------------------------------------ Host

func _on_host_pressed() -> void:
	if _busy or not _connected:
		return
	_busy = true
	_set_status("بنعمل الروم...")
	GDSync.lobby_create(_generate_code(), "", false, MAX_PLAYERS)


func _on_lobby_created(lobby_name: String) -> void:
	GDSync.lobby_join(lobby_name) # لازم ندخل خلال 5 ثواني


func _on_lobby_creation_failed(_lobby_name: String, error: int) -> void:
	if error == ENUMS.LOBBY_CREATION_ERROR.LOBBY_ALREADY_EXISTS:
		# الكود اتكرر (نادر)، نجرّب كود تاني
		GDSync.lobby_create(_generate_code(), "", false, MAX_PLAYERS)
		return
	_busy = false
	if error == ENUMS.LOBBY_CREATION_ERROR.ON_COOLDOWN:
		_set_status("استنى كام ثانية وجرّب تاني")
	else:
		_set_status("مقدرناش نعمل الروم (%d)" % error)


func _generate_code() -> String:
	var code: String = ""
	for i in CODE_LENGTH:
		code += CODE_CHARS[randi() % CODE_CHARS.length()]
	return code


# ------------------------------------------------------------------ Join

func _on_join_screen_pressed() -> void:
	_set_status("")
	_code_input.text = ""
	_show_screen("join")
	_code_input.grab_focus()


func _on_back_pressed() -> void:
	_set_status("")
	_show_screen("menu")


func _on_confirm_join_pressed() -> void:
	if _busy or not _connected:
		return
	var code: String = _code_input.text.strip_edges().to_upper()
	if code.is_empty():
		_set_status("اكتب الكود الأول")
		return
	_busy = true
	_set_status("بندخل...")
	GDSync.lobby_join(code)


func _on_lobby_join_failed(_lobby_name: String, error: int) -> void:
	print("lobby_join_failed: ", _lobby_name, " error=", error)
	_busy = false
	match error:
		ENUMS.LOBBY_JOIN_ERROR.LOBBY_DOES_NOT_EXIST:
			_set_status("الكود غلط أو الروم مش موجودة")
		ENUMS.LOBBY_JOIN_ERROR.LOBBY_IS_FULL:
			_set_status("الروم ممتلية")
		ENUMS.LOBBY_JOIN_ERROR.LOBBY_IS_CLOSED:
			_set_status("الروم اتقفلت")
		_:
			_set_status("مقدرناش ندخل (%d)" % error)


func _on_lobby_joined(lobby_name: String) -> void:
	_busy = false
	_set_status("")
	_code_label.text = "كود الروم: %s" % lobby_name
	GDSync.player_set_data(READY_KEY, false)
	_ready_button.set_pressed_no_signal(false)
	_show_screen("room")
	_refresh_lobby()


# ------------------------------------------------------------------ الروم

func _on_ready_toggled(pressed: bool) -> void:
	GDSync.player_set_data(READY_KEY, pressed)
	_refresh_lobby()


func _on_start_pressed() -> void:
	# الـ host بس، ولازم الاتنين يكونوا جاهزين
	if _starting or not GDSync.is_host() or not _can_start():
		return
	_starting = true
	_start_button.disabled = true
	_set_status("بنحمّل اللعبة...")
	GDSync.lobby_close() # محدش يدخل بعد البداية
	GDSync.change_scene(game_scene)


func _on_change_scene_failed(_path: String) -> void:
	_starting = false
	_set_status("تحميل اللعبة فشل")
	GDSync.lobby_open()
	_refresh_lobby()


func _on_leave_pressed() -> void:
	GDSync.lobby_leave()
	_set_status("")
	_show_screen("menu")


func _refresh_lobby_signal(_client_id: int) -> void:
	_refresh_lobby()


func _on_player_data_changed(_client_id: int, key: String, _value) -> void:
	if key == READY_KEY:
		_refresh_lobby()


func _on_host_changed(_is_host: bool, _new_host_id: int) -> void:
	_refresh_lobby()


func _is_client_ready(client_id: int) -> bool:
	# الـ host معتبر جاهز دايمًا
	if client_id == GDSync.get_host():
		return true
	return bool(GDSync.player_get_data(client_id, READY_KEY, false))


func _can_start() -> bool:
	var clients: Array = GDSync.lobby_get_all_clients()
	if clients.size() < MAX_PLAYERS:
		return false
	for id in clients:
		if not _is_client_ready(id):
			return false
	return true


func _refresh_lobby() -> void:
	if not _room_screen.visible:
		return
	var is_host: bool = GDSync.is_host()
	var my_id: int = GDSync.get_client_id()
	var clients: Array = GDSync.lobby_get_all_clients()
	clients.sort()

	var lines: PackedStringArray = []
	for id in clients:
		var role: String = "Host" if id == GDSync.get_host() else "Player"
		var me: String = " (إنت)" if id == my_id else ""
		var state: String = "جاهز ✓" if _is_client_ready(id) else "مش جاهز"
		lines.append("%s%s: %s" % [role, me, state])
	_players_label.text = "اللاعبين %d/%d\n%s" % [clients.size(), MAX_PLAYERS, "\n".join(lines)]

	# الـ host بيشوف Start، والتاني بيشوف Ready
	_start_button.visible = is_host
	_ready_button.visible = not is_host
	_start_button.disabled = _starting or not _can_start()


# ------------------------------------------------------------------ عرض الشاشات

func _show_screen(screen: String) -> void:
	# اللعب أوفلاين متاح من القائمة أو أثناء الاتصال (حتى لو النت واقع)
	_offline_button.visible = (screen == "menu" or screen == "connecting")
	_menu_screen.visible = (screen == "menu")
	_join_screen.visible = (screen == "join")
	_room_screen.visible = (screen == "room")
	if screen == "connecting":
		_set_status("بنتصل...")


func _set_status(text: String) -> void:
	_status_label.text = text
