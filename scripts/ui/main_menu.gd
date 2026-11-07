extends Control
## scripts/ui/main_menu.gd
## القائمة الرئيسية: Host يعمل كود، واللاعب التاني يكتب الكود ويدخل.
## اللاعب التاني يدوس Ready، والـ host يدوس Start فيدخلوا اللعبة مع بعض.
## الواجهة بتتبني من الكود عشان نبدّل شكلها بعدين بسهولة.

@export_file("*.tscn") var game_scene: String = "res://scenes/worlds/test_room.tscn"

const CODE_CHARS: String = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" # من غير حروف بتتلخبط (O/0, I/1)
const CODE_LENGTH: int = 5
const MAX_PLAYERS: int = 2
const READY_KEY: String = "ready"

var _status_label: Label
var _menu_box: VBoxContainer
var _code_input: LineEdit
var _host_button: Button
var _join_button: Button

var _lobby_box: VBoxContainer
var _code_label: Label
var _players_label: Label
var _ready_button: Button
var _start_button: Button
var _leave_button: Button

var _connected: bool = false
var _busy: bool = false # في عملية جارية (إنشاء أو دخول)
var _starting: bool = false


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_build_ui()

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


# ------------------------------------------------------------------ Host

func _on_host_pressed() -> void:
	if _busy or not _connected:
		return
	_busy = true
	_set_status("بنعمل اللوبي...")
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
		_set_status("مقدرناش نعمل اللوبي (%d)" % error)


func _generate_code() -> String:
	var code: String = ""
	for i in CODE_LENGTH:
		code += CODE_CHARS[randi() % CODE_CHARS.length()]
	return code


# ------------------------------------------------------------------ Join

func _on_join_pressed() -> void:
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
	_busy = false
	match error:
		ENUMS.LOBBY_JOIN_ERROR.LOBBY_DOES_NOT_EXIST:
			_set_status("الكود غلط أو اللوبي مش موجود")
		ENUMS.LOBBY_JOIN_ERROR.LOBBY_IS_FULL:
			_set_status("اللوبي ممتلي")
		ENUMS.LOBBY_JOIN_ERROR.LOBBY_IS_CLOSED:
			_set_status("اللوبي اتقفل")
		_:
			_set_status("مقدرناش ندخل (%d)" % error)


func _on_lobby_joined(lobby_name: String) -> void:
	_busy = false
	_set_status("")
	_code_label.text = "الكود: %s" % lobby_name
	GDSync.player_set_data(READY_KEY, false)
	_ready_button.set_pressed_no_signal(false)
	_show_screen("lobby")
	_refresh_lobby()


# ------------------------------------------------------------------ اللوبي

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
	_show_screen("menu")
	_set_status("")


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
	if _lobby_box == null or not _lobby_box.visible:
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


# ------------------------------------------------------------------ الواجهة

func _show_screen(screen: String) -> void:
	_menu_box.visible = (screen == "menu")
	_lobby_box.visible = (screen == "lobby")
	if screen == "connecting":
		_set_status("بنتصل...")


func _set_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text


func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var root_box := VBoxContainer.new()
	root_box.custom_minimum_size = Vector2(320.0, 0.0)
	root_box.add_theme_constant_override("separation", 12)
	center.add_child(root_box)

	var title := Label.new()
	title.text = "Online Co-op"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root_box.add_child(title)

	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root_box.add_child(_status_label)

	# شاشة القائمة
	_menu_box = VBoxContainer.new()
	_menu_box.add_theme_constant_override("separation", 10)
	root_box.add_child(_menu_box)

	_host_button = Button.new()
	_host_button.text = "Host"
	_host_button.pressed.connect(_on_host_pressed)
	_menu_box.add_child(_host_button)

	_code_input = LineEdit.new()
	_code_input.placeholder_text = "اكتب الكود"
	_code_input.max_length = CODE_LENGTH
	_code_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_code_input.text_submitted.connect(func(_text: String) -> void: _on_join_pressed())
	_menu_box.add_child(_code_input)

	_join_button = Button.new()
	_join_button.text = "Join"
	_join_button.pressed.connect(_on_join_pressed)
	_menu_box.add_child(_join_button)

	# شاشة اللوبي
	_lobby_box = VBoxContainer.new()
	_lobby_box.add_theme_constant_override("separation", 10)
	root_box.add_child(_lobby_box)

	_code_label = Label.new()
	_code_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lobby_box.add_child(_code_label)

	_players_label = Label.new()
	_players_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lobby_box.add_child(_players_label)

	_ready_button = Button.new()
	_ready_button.text = "Ready"
	_ready_button.toggle_mode = true
	_ready_button.toggled.connect(_on_ready_toggled)
	_lobby_box.add_child(_ready_button)

	_start_button = Button.new()
	_start_button.text = "Start"
	_start_button.pressed.connect(_on_start_pressed)
	_lobby_box.add_child(_start_button)

	_leave_button = Button.new()
	_leave_button.text = "Leave"
	_leave_button.pressed.connect(_on_leave_pressed)
	_lobby_box.add_child(_leave_button)

	_menu_box.visible = false
	_lobby_box.visible = false
