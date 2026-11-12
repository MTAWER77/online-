extends Node
## scripts/multiplayer/network_manager.gd
## بيعمل اللاعبين الاتنين بالكود (HostPlayer و ClientPlayer) في نفس الأماكن عند الاتنين.
## الـ host بيتحكم في HostPlayer، والتاني في ClientPlayer.
## كل لاعب بيبعت مكان لاعبه بس (PropertySynchronizer: WHEN_HOST / WHEN_CLIENT)،
## ومن غير ownership ومن غير multiplayer_instantiate، فمفيش سباق بين الاتنين.
## الـ host كمان هو صاحب القرار في الحالة المشتركة (الأبواب والألغاز).

signal lobby_entered(is_host: bool)

# مسارات الـ nodes لازم تكون ثابتة ومتطابقة عند الاتنين
const SessionMode = preload("res://scripts/multiplayer/session_mode.gd")
const PLAYER_SCENE: PackedScene = preload("res://scenes/players/player.tscn")
const PLAYERS_ROOT_NAME: String = "SpawnedPlayers"
const HOST_PLAYER_NAME: String = "HostPlayer"
const CLIENT_PLAYER_NAME: String = "ClientPlayer"

# قيم لازم تطابق الـ enums بتاعة player.gd و PropertySynchronizer
const ROLE_HOST: int = 1 # Player.Role.HOST
const ROLE_CLIENT: int = 2 # Player.Role.CLIENT
const BROADCAST_WHEN_HOST: int = 0 # PropertySynchronizer.BROADCAST_MODE.WHEN_HOST
const BROADCAST_WHEN_CLIENT: int = 1 # PropertySynchronizer.BROADCAST_MODE.WHEN_CLIENT

@export var lobby_name: String = "coop-test-room" # بس لما نشغّل المشهد لوحده بـ F6
@export var force_offline: bool = false # لاعب واحد من غير نت (للتجربة بـ F6 كمان)
@export var use_local_multiplayer: bool = false # للتجربة من غير مفاتيح (GDSync local)
@export var host_spawn: Vector3 = Vector3(-1.5, 0.1, 0.0)
@export var client_spawn: Vector3 = Vector3(1.5, 0.1, 0.0)

var _spawned: bool = false
var _players_root: Node3D
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

	# المشهد الأب لسه بيجهّز أولاده، فنأجّل الشغل لنهاية الفريم
	_start.call_deferred()


func _start() -> void:
	# وضع أوفلاين: لاعب واحد، من غير GD-Sync خالص
	if SessionMode.offline or force_offline:
		_spawn_offline()
		return

	# جاي من القائمة الرئيسية وإحنا أصلًا جوه لوبي: نعمل اللاعبين على طول
	if GDSync.is_active() and GDSync.lobby_get_name() != "":
		_spawn_players()
		return

	# تشغيل المشهد لوحده (F6): نتصل وندخل لوبي تجريبي
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
	_spawn_players()


func _on_host_changed(_is_host: bool, _new_host_id: int) -> void:
	_refresh_status()


func _on_client_left(_client_id: int) -> void:
	# لاعبين بس: اللي خرج هو اللاعب التاني، فنخفي لاعبه
	if _players_root != null:
		var other_name: String = CLIENT_PLAYER_NAME if GDSync.is_host() else HOST_PLAYER_NAME
		var other := _players_root.get_node_or_null(other_name) as Node3D
		if other != null:
			other.visible = false
	_refresh_status()


# ---- عمل اللاعبين ----
func _spawn_players() -> void:
	if _spawned:
		return
	_spawned = true

	_players_root = _ensure_players_root()

	# الاتنين بيعملوا نفس اللاعبين بنفس الأسماء والأماكن
	_spawn_one(HOST_PLAYER_NAME, ROLE_HOST, BROADCAST_WHEN_HOST, host_spawn)
	_spawn_one(CLIENT_PLAYER_NAME, ROLE_CLIENT, BROADCAST_WHEN_CLIENT, client_spawn)

	_refresh_status()
	lobby_entered.emit(GDSync.is_host())


func _spawn_offline() -> void:
	if _spawned:
		return
	_spawned = true
	_players_root = _ensure_players_root()
	var player := PLAYER_SCENE.instantiate() as Node3D
	player.name = "OfflinePlayer"
	# من غير دور (role) فاللاعب بيتحكم فيه محليًا، ومن غير مزامنة
	player.get_node("PropertySynchronizer").free()
	player.position = host_spawn
	_players_root.add_child(player)
	_set_status("OFFLINE | single player")


func _ensure_players_root() -> Node3D:
	var scene_root: Node = get_parent()
	var root := scene_root.get_node_or_null(PLAYERS_ROOT_NAME) as Node3D
	if root == null:
		root = Node3D.new()
		root.name = PLAYERS_ROOT_NAME
		scene_root.add_child(root)
	return root


func _spawn_one(node_name: String, role: int, broadcast_mode: int, spawn_position: Vector3) -> void:
	var player := PLAYER_SCENE.instantiate() as Node3D
	player.name = node_name
	# الدور ووضع الإرسال لازم يتحددوا قبل ما اللاعب يدخل الشجرة
	player.set("role", role)
	var sync: Node = player.get_node("PropertySynchronizer")
	sync.set("broadcast", broadcast_mode)
	player.position = spawn_position
	_players_root.add_child(player)


# ---- شاشة حالة صغيرة للتجربة (Debug) ----
func _build_status_label() -> void:
	var layer := CanvasLayer.new()
	_status_label = Label.new()
	_status_label.position = Vector2(12.0, 8.0)
	layer.add_child(_status_label)
	add_child(layer)


func _refresh_status() -> void:
	var role_text: String = "HOST" if GDSync.is_host() else "CLIENT"
	_set_status("%s | id %d | players %d | F = test sync" % [
		role_text, GDSync.get_client_id(), GDSync.lobby_get_player_count()])


func _set_status(text: String) -> void:
	if _status_label != null:
		_status_label.text = text
