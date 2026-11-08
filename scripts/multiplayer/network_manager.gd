extends Node
## scripts/multiplayer/network_manager.gd
## الاتصال + إنشاء/دخول اللوبي + عمل لاعب لكل واحد.
## القاعدة: أول واحد يدخل اللوبي هو الـ host (GD-Sync بتحدده).
## كل لاعب هو owner للاعبه (حركته منه)، والـ host هو صاحب القرار في الحالة المشتركة.

signal lobby_entered(is_host: bool)

@export var lobby_name: String = "coop-test-room"
@export var use_local_multiplayer: bool = false # للتجربة من غير مفاتيح (GDSync local)
@export var player_scene: PackedScene
@export var players_root: Node3D
@export var spawn_points_root: Node3D # فيه Marker3D لكل مكان ظهور (الأول للـ host)
@export var spawn_origin: Vector3 = Vector3(0.0, 0.1, 0.0) # احتياطي لو مفيش Markers
@export var spawn_spacing: float = 2.0

var _player_spawned: bool = false
var _status_label: Label


func _ready() -> void:
	_build_status_label()

	GDSync.connected.connect(_on_connected)
	GDSync.connection_failed.connect(_on_connection_failed)
	GDSync.lobby_created.connect(_on_lobby_created)
	GDSync.lobby_creation_failed.connect(_on_lobby_creation_failed)
	GDSync.lobby_joined.connect(_on_lobby_joined)
	GDSync.lobby_join_failed.connect(_on_lobby_join_failed)
	GDSync.client_left.connect(_on_client_left)
	GDSync.host_changed.connect(_on_host_changed)

	# جاي من القائمة الرئيسية وإحنا أصلًا جوه لوبي: نعمل اللاعب على طول
	if GDSync.is_active() and GDSync.lobby_get_all_clients().has(GDSync.get_client_id()):
		_refresh_status()
		_spawn_local_player()
		lobby_entered.emit(GDSync.is_host())
		return

	_set_status("Connecting...")
	if use_local_multiplayer:
		GDSync.start_local_multiplayer()
	else:
		GDSync.start_multiplayer()


func _on_connected() -> void:
	_set_status("Connected, joining lobby...")
	# نحاول ندخل الأول، لو مش موجود نعمله
	GDSync.lobby_join(lobby_name)


func _on_connection_failed(error: int) -> void:
	match error:
		ENUMS.CONNECTION_FAILED.INVALID_PUBLIC_KEY:
			_set_status("Connection failed: invalid keys")
		ENUMS.CONNECTION_FAILED.TIMEOUT:
			_set_status("Connection failed: timeout")
		_:
			_set_status("Connection failed (%d)" % error)
	push_error("GDSync connection failed: %d" % error)


func _on_lobby_join_failed(failed_lobby: String, error: int) -> void:
	if error == ENUMS.LOBBY_JOIN_ERROR.LOBBY_DOES_NOT_EXIST:
		# اللوبي مش موجود، يبقى أنا اللي هعمله (2 لاعبين، مش public)
		GDSync.lobby_create(failed_lobby, "", false, 2)
	else:
		_set_status("Join failed (%d)" % error)
		push_error("Lobby join failed: %d" % error)


func _on_lobby_created(created_lobby: String) -> void:
	GDSync.lobby_join(created_lobby) # لازم ندخل خلال 5 ثواني


func _on_lobby_creation_failed(failed_lobby: String, error: int) -> void:
	if error == ENUMS.LOBBY_CREATION_ERROR.LOBBY_ALREADY_EXISTS:
		# واحد تاني سبقني وعمله، أدخل بس
		GDSync.lobby_join(failed_lobby)
	else:
		_set_status("Create failed (%d)" % error)
		push_error("Lobby creation failed: %d" % error)


func _on_lobby_joined(_joined_lobby: String) -> void:
	_refresh_status()
	_spawn_local_player()
	lobby_entered.emit(GDSync.is_host())


func _on_host_changed(_is_host: bool, _new_host_id: int) -> void:
	_refresh_status()


func _on_client_left(client_id: int) -> void:
	# الـ host بس هو اللي يمسح لاعب اللي خرج (عشان ما يتمسحش مرتين)
	if not GDSync.is_host() or players_root == null:
		return
	for child in players_root.get_children():
		if GDSync.get_gdsync_owner(child) == client_id:
			GDSync.multiplayer_queue_free(child)
	_refresh_status()


func _spawn_local_player() -> void:
	if _player_spawned or player_scene == null or players_root == null:
		return
	_player_spawned = true

	# الـ host ياخد المكان الأول والتاني ياخد التاني (مش بنعتمد على قايمة اللاعبين لأنها بتتأخر)
	var slot: int = 0 if GDSync.is_host() else 1
	var spawn_position: Vector3 = spawn_origin + Vector3(slot * spawn_spacing, 0.0, 0.0)
	if spawn_points_root != null and slot < spawn_points_root.get_child_count():
		var point := spawn_points_root.get_child(slot) as Node3D
		if point != null:
			spawn_position = point.global_position

	var player := GDSync.multiplayer_instantiate(player_scene, players_root) as Node3D
	player.global_position = spawn_position
	GDSync.set_gdsync_owner(player, GDSync.get_client_id())


# ---- شاشة حالة صغيرة للتجربة (Debug) ----
func _build_status_label() -> void:
	var layer := CanvasLayer.new()
	_status_label = Label.new()
	_status_label.position = Vector2(12.0, 8.0)
	layer.add_child(_status_label)
	add_child(layer)


func _refresh_status() -> void:
	var role: String = "HOST" if GDSync.is_host() else "CLIENT"
	_set_status("%s | id %d | players %d | F = test sync" % [
		role, GDSync.get_client_id(), GDSync.lobby_get_player_count()])


func _set_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text
