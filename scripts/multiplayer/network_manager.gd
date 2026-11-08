extends Node
## scripts/multiplayer/network_manager.gd
## بيربط اللاعبين الاتنين اللي في المشهد (Player1 للـ host، Player2 للتاني).
## كل لاعب بياخد ownership على لاعبه هو بس، فحركته منه والتاني بيستقبلها بالشبكة.
## الـ host هو صاحب القرار في الحالة المشتركة (الأبواب والألغاز).

signal lobby_entered(is_host: bool)

@export var lobby_name: String = "coop-test-room" # بس لما نشغّل المشهد لوحده بـ F6
@export var use_local_multiplayer: bool = false # للتجربة من غير مفاتيح (GDSync local)
@export var host_player: Node3D # لاعب الـ host
@export var client_player: Node3D # لاعب اللاعب التاني

var _claimed: bool = false
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

	# جاي من القائمة الرئيسية وإحنا أصلًا جوه لوبي: ناخد لاعبنا على طول
	if GDSync.is_active() and GDSync.lobby_get_name() != "":
		_claim_player()
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
	_claim_player()


func _on_host_changed(_is_host: bool, _new_host_id: int) -> void:
	_refresh_status()


func _on_client_left(client_id: int) -> void:
	# اللاعب اللي خرج نخفي لاعبه
	for p in [host_player, client_player]:
		if p != null and GDSync.get_gdsync_owner(p) == client_id:
			p.visible = false
	_refresh_status()


# الـ host ياخد Player1 والتاني ياخد Player2، ونعلن ownership للتاني
func _claim_player() -> void:
	if _claimed:
		return
	var mine: Node3D = host_player if GDSync.is_host() else client_player
	if mine == null:
		push_error("NetworkManager: host_player / client_player مش متحددين")
		return
	_claimed = true
	GDSync.set_gdsync_owner(mine, GDSync.get_client_id())
	_refresh_status()
	lobby_entered.emit(GDSync.is_host())


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
