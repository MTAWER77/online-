class_name TransportBase
extends RefCounted
## واجهة Transport مستقلة عن وسيلة الاتصال (ENet الآن، Steam مستقبلًا).
## أي Transport جديد يرث هذا الكلاس ويطبق الدوال الافتراضية فقط.

signal peer_connected(peer_id: int)
signal peer_disconnected(peer_id: int)
signal connected_to_server()
signal connection_failed()
signal server_disconnected()

var _api: MultiplayerAPI = null
var _signals_connected: bool = false

## يربط الـ Transport بـ MultiplayerAPI الخاص بالـ SceneTree.
func setup(api: MultiplayerAPI) -> void:
	_api = api

# --- واجهة يجب على الـ Transport الفعلي تطبيقها ---
func get_transport_name() -> String:
	push_error("TransportBase.get_transport_name() not implemented")
	return "base"

func create_host(_port: int, _max_clients: int) -> Error:
	push_error("TransportBase.create_host() not implemented")
	return ERR_UNAVAILABLE

func join(_address: String, _port: int) -> Error:
	push_error("TransportBase.join() not implemented")
	return ERR_UNAVAILABLE

func close() -> void:
	push_error("TransportBase.close() not implemented")

func is_active() -> bool:
	return false

# --- مساعدات مشتركة ---
func get_unique_id() -> int:
	if _api == null or not is_active():
		return 0
	return _api.get_unique_id()

func is_server() -> bool:
	return _api != null and is_active() and _api.is_server()

func _connect_api_signals() -> void:
	if _api == null or _signals_connected:
		return
	_api.peer_connected.connect(_on_peer_connected)
	_api.peer_disconnected.connect(_on_peer_disconnected)
	_api.connected_to_server.connect(_on_connected_to_server)
	_api.connection_failed.connect(_on_connection_failed)
	_api.server_disconnected.connect(_on_server_disconnected)
	_signals_connected = true

func _disconnect_api_signals() -> void:
	if _api == null or not _signals_connected:
		return
	if _api.peer_connected.is_connected(_on_peer_connected):
		_api.peer_connected.disconnect(_on_peer_connected)
	if _api.peer_disconnected.is_connected(_on_peer_disconnected):
		_api.peer_disconnected.disconnect(_on_peer_disconnected)
	if _api.connected_to_server.is_connected(_on_connected_to_server):
		_api.connected_to_server.disconnect(_on_connected_to_server)
	if _api.connection_failed.is_connected(_on_connection_failed):
		_api.connection_failed.disconnect(_on_connection_failed)
	if _api.server_disconnected.is_connected(_on_server_disconnected):
		_api.server_disconnected.disconnect(_on_server_disconnected)
	_signals_connected = false

func _on_peer_connected(id: int) -> void:
	peer_connected.emit(id)

func _on_peer_disconnected(id: int) -> void:
	peer_disconnected.emit(id)

func _on_connected_to_server() -> void:
	connected_to_server.emit()

func _on_connection_failed() -> void:
	connection_failed.emit()

func _on_server_disconnected() -> void:
	server_disconnected.emit()
