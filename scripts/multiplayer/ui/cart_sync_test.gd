extends Node3D
## مشهد اختبار مزامنة العربية (المرحلة 5): عالم بسيط + عربية التسوق + HUD للاتصال.
## اسم الجذر "CartSyncTest" والعربية اسمها "ShoppingCart" => نفس مسار الـ RPC على
## الجهازين: /root/CartSyncTest/ShoppingCart/CartSync
##
## التحكّم (نفس تقسيم المرحلة 5):
##   HOST   : A/D للتوجيه + SPACE للقفز
##   CLIENT : W بنزين + S فرامل (المدخلات بتروح للـ host)

const CART_SCENE_PATHS: Array = [
	"res://scenes/vehicles/shopping_cart.tscn",
	"res://scenes/shopping_cart.tscn",
	"res://vehicles/shopping_cart.tscn",
]
const INFO_INTERVAL_SEC: float = 0.2
const ARENA_HALF: float = 25.0
const _CS = NetworkConfig.ConnectionState

@onready var _camera: Camera3D = %Camera
@onready var _sun: DirectionalLight3D = %Sun
@onready var _ip_edit: LineEdit = %IpEdit
@onready var _port_edit: LineEdit = %PortEdit
@onready var _host_button: Button = %HostButton
@onready var _join_button: Button = %JoinButton
@onready var _disconnect_button: Button = %DisconnectButton
@onready var _status_label: Label = %StatusLabel
@onready var _info_label: Label = %InfoLabel

var _note: String = ""
var _info_accum: float = 0.0


func _ready() -> void:
	_sun.rotation_degrees = Vector3(-55.0, 30.0, 0.0)
	_build_decor()
	_ip_edit.text = "127.0.0.1"
	_port_edit.text = str(NetworkConfig.DEFAULT_PORT)
	_host_button.pressed.connect(_on_host_pressed)
	_join_button.pressed.connect(_on_join_pressed)
	_disconnect_button.pressed.connect(_on_disconnect_pressed)
	NetworkEvents.connection_state_changed.connect(_on_any_state_event.unbind(2))
	NetworkEvents.host_started.connect(_on_host_started)
	NetworkEvents.join_started.connect(_on_join_started)
	NetworkEvents.connected_to_host.connect(_on_connected_to_host)
	NetworkEvents.connection_failed.connect(_on_connection_failed)
	NetworkEvents.server_disconnected.connect(_on_server_disconnected)
	NetworkEvents.player_connected.connect(_on_player_event)
	NetworkEvents.player_disconnected.connect(_on_player_event)
	NetworkEvents.session_ended.connect(_on_session_ended)
	_load_cart()
	_refresh_ui()


func _process(delta: float) -> void:
	_info_accum += delta
	if _info_accum >= INFO_INTERVAL_SEC:
		_info_accum = 0.0
		_refresh_info()


# ---------------- العربية ----------------

func _load_cart() -> void:
	for candidate: String in CART_SCENE_PATHS:
		if not ResourceLoader.exists(candidate):
			continue
		var scene: PackedScene = load(candidate) as PackedScene
		if scene == null:
			continue
		var cart: Node3D = scene.instantiate() as Node3D
		if cart == null:
			continue
		cart.name = "ShoppingCart"
		add_child(cart)
		print("CartSyncTest: cart loaded from ", candidate)
		return
	push_warning("CartSyncTest: cart scene not found (looked in %s) — no cart in the test world." % str(CART_SCENE_PATHS))


func _get_cart() -> Node3D:
	for child: Node in get_children():
		if child is Node3D and child.is_in_group("cart"):
			return child as Node3D
	return null


func _get_cart_sync() -> CartSync:
	var cart: Node3D = _get_cart()
	if cart == null:
		return null
	return cart.get_node_or_null("CartSync") as CartSync

# ---------------- أزرار الاتصال ----------------

func _on_host_pressed() -> void:
	var port: int = _read_port()
	if port < 0:
		return
	var err: Error = NetworkManager.host_game(port)
	if err != OK:
		_set_note("Host failed: %s" % error_string(err))


func _on_join_pressed() -> void:
	var port: int = _read_port()
	if port < 0:
		return
	var err: Error = NetworkManager.join_game(_ip_edit.text, port)
	if err != OK:
		_set_note("Join failed: %s" % error_string(err))


func _on_disconnect_pressed() -> void:
	NetworkManager.disconnect_session()


func _read_port() -> int:
	var text: String = _port_edit.text.strip_edges()
	if not text.is_valid_int() or not NetworkConfig.is_valid_port(text.to_int()):
		_set_note("Invalid port")
		return -1
	return text.to_int()

# ---------------- إشارات الشبكة ----------------

func _on_any_state_event() -> void:
	_refresh_ui()


func _on_host_started(port: int) -> void:
	_set_note("Hosting on port %d" % port)


func _on_join_started(address: String, port: int) -> void:
	_set_note("Connecting to %s:%d ..." % [address, port])


func _on_connected_to_host() -> void:
	_set_note("Connected")


func _on_connection_failed(reason: String) -> void:
	_set_note("Connection failed: %s" % reason)


func _on_server_disconnected() -> void:
	_set_note("Host disconnected")


func _on_player_event(_peer_id: int) -> void:
	_refresh_ui()


func _on_session_ended() -> void:
	_set_note("Session ended")

# ---------------- الواجهة ----------------

func _set_note(text: String) -> void:
	_note = text
	_refresh_ui()


func _refresh_ui() -> void:
	var state: int = NetworkManager.get_state()
	var idle: bool = state == _CS.DISCONNECTED
	_host_button.disabled = not idle
	_join_button.disabled = not idle
	_disconnect_button.disabled = idle
	_ip_edit.editable = idle
	_port_edit.editable = idle
	var status: String = "Status: %s" % NetworkConfig.state_name(state)
	if not _note.is_empty():
		status += " - " + _note
	_status_label.text = status
	_refresh_info()


func _refresh_info() -> void:
	var clock: NetworkClock = NetworkManager.get_clock()
	var text: String = ""
	if clock != null:
		text += "Clock: %s | RTT %.1f ms\n" % [clock.get_state_text(), clock.get_rtt_ms()]
	text += "Local Peer: %d\n" % NetworkManager.get_local_peer_id()
	var cart: Node3D = _get_cart()
	if cart == null:
		text += "NO CART IN SCENE"
	else:
		var pos: Vector3 = cart.global_position
		text += "Cart pos(%.2f, %.2f, %.2f)\n" % [pos.x, pos.y, pos.z]
		var sync: CartSync = _get_cart_sync()
		if sync != null:
			var s: Dictionary = sync.get_stats()
			text += "sent %d | recv %d | rej %d | in %d | buf %d | peers %d | ext %d\n" % [
				int(s["sent"]), int(s["received"]), int(s["rejected"]), int(s["inputs"]),
				int(s["buffered"]), int(s["peers"]), int(s["extrapolations"])]
	_info_label.text = text

# ---------------- ديكور العالم (محلي بالكامل، بدون شبكة) ----------------

func _build_decor() -> void:
	var decor: Node3D = Node3D.new()
	decor.name = "Decor"
	add_child(decor)
	var wall_len: float = ARENA_HALF * 2.0 + 2.0
	var wall_color: Color = Color(0.5, 0.5, 0.55)
	_add_box(decor, Vector3(ARENA_HALF + 0.5, 1.5, 0.0), Vector3(1.0, 3.0, wall_len), wall_color)
	_add_box(decor, Vector3(-ARENA_HALF - 0.5, 1.5, 0.0), Vector3(1.0, 3.0, wall_len), wall_color)
	_add_box(decor, Vector3(0.0, 1.5, ARENA_HALF + 0.5), Vector3(wall_len, 3.0, 1.0), wall_color)
	_add_box(decor, Vector3(0.0, 1.5, -ARENA_HALF - 0.5), Vector3(wall_len, 3.0, 1.0), wall_color)
	for i: int in 8:
		var angle: float = TAU * float(i) / 8.0
		var pos: Vector3 = Vector3(cos(angle) * 12.0, 1.5, sin(angle) * 12.0)
		_add_box(decor, pos, Vector3(1.5, 3.0, 1.5), Color.from_hsv(float(i) / 8.0, 0.7, 0.9))


func _add_box(parent: Node3D, pos: Vector3, size: Vector3, color: Color) -> void:
	var body: StaticBody3D = StaticBody3D.new()
	body.position = pos
	var shape: CollisionShape3D = CollisionShape3D.new()
	var box_shape: BoxShape3D = BoxShape3D.new()
	box_shape.size = size
	shape.shape = box_shape
	var mesh: MeshInstance3D = MeshInstance3D.new()
	var box_mesh: BoxMesh = BoxMesh.new()
	box_mesh.size = size
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = color
	box_mesh.material = mat
	mesh.mesh = box_mesh
	body.add_child(shape)
	body.add_child(mesh)
	parent.add_child(body)
