extends Node
## Autoload باسم NetworkManager (بدون class_name). مسؤول عن دورة حياة الاتصال فقط.
## الإشارات تُطلق عبر NetworkEvents. الجلسة في NetworkSession، واللاعبين في PlayerRegistry.

const _CS = NetworkConfig.ConnectionState

var _transport: TransportBase = null
var _session: NetworkSession = null
var _state: int = _CS.DISCONNECTED
var _connect_timer: Timer = null
var _tearing_down: bool = false
var _clock: NetworkClock = null

func _ready() -> void:
	_session = NetworkSession.new()
	_transport = ENetTransport.new()
	_clock = NetworkClock.new()
	_clock.name = "NetworkClock"  # نفس المسار على الجهازين: /root/NetworkManager/NetworkClock
	_clock.set_peer_validator(_is_known_peer)
	add_child(_clock)
	_transport.setup(multiplayer)
	_transport.peer_connected.connect(_on_peer_connected)
	_transport.peer_disconnected.connect(_on_peer_disconnected)
	_transport.connected_to_server.connect(_on_connected_to_server)
	_transport.connection_failed.connect(_on_connection_failed)
	_transport.server_disconnected.connect(_on_server_disconnected)
	_connect_timer = Timer.new()
	_connect_timer.one_shot = true
	_connect_timer.wait_time = NetworkConfig.CONNECT_TIMEOUT_SEC
	_connect_timer.timeout.connect(_on_connect_timeout)
	add_child(_connect_timer)

func _exit_tree() -> void:
	if _clock != null:
		_clock.stop()
	# إغلاق صامت عند إنهاء اللعبة (بدون إشارات).
	if _transport != null:
		_transport.close()
	if _session != null:
		_session.end()

# ---------------- الواجهة العامة ----------------

func get_state() -> int:
	return _state

func get_session() -> NetworkSession:
	return _session

func get_registry() -> PlayerRegistry:
	return _session.registry

func get_local_peer_id() -> int:
	return _session.local_peer_id

func is_host() -> bool:
	return _session.is_host()

func get_clock() -> NetworkClock:
	return _clock

func _is_known_peer(peer_id: int) -> bool:
	return _session.registry.has_player(peer_id)

## جاهزية العمليات الشبكية/RPC: العقدة داخل الشجرة + اتصال فعّال.
func is_network_ready() -> bool:
	return is_inside_tree() \
		and _transport.is_active() \
		and (_state == _CS.HOSTING or _state == _CS.CONNECTED)

## يستخدمها أي كود قبل RPC: ترجع false مع تحذير لو الشبكة غير جاهزة.
func require_ready(context: String = "") -> bool:
	if is_network_ready():
		return true
	push_warning("NetworkManager: network not ready (%s)" % context)
	return false

func host_game(port: int = NetworkConfig.DEFAULT_PORT) -> Error:
	if not is_inside_tree():
		return ERR_UNCONFIGURED
	if _state != _CS.DISCONNECTED:
		push_warning("NetworkManager.host_game: already %s" % NetworkConfig.state_name(_state))
		return ERR_ALREADY_IN_USE
	if not NetworkConfig.is_valid_port(port):
		return ERR_INVALID_PARAMETER
	var err: Error = _transport.create_host(port, NetworkConfig.MAX_CLIENTS)
	if err != OK:
		push_error("NetworkManager.host_game failed: %s" % error_string(err))
		return err
	err = _session.start_host()
	if err != OK:
		_transport.close()
		push_error("NetworkManager: session start failed: %s" % error_string(err))
		return err
	_set_state(_CS.HOSTING)
	_clock.start_as_host()
	NetworkEvents.host_started.emit(port)
	return OK

func join_game(address: String, port: int = NetworkConfig.DEFAULT_PORT) -> Error:
	if not is_inside_tree():
		return ERR_UNCONFIGURED
	if _state != _CS.DISCONNECTED:
		push_warning("NetworkManager.join_game: already %s" % NetworkConfig.state_name(_state))
		return ERR_ALREADY_IN_USE
	if not NetworkConfig.is_valid_address(address) or not NetworkConfig.is_valid_port(port):
		return ERR_INVALID_PARAMETER
	var err: Error = _transport.join(address, port)
	if err != OK:
		push_error("NetworkManager.join_game failed: %s" % error_string(err))
		return err
	_set_state(_CS.CONNECTING)
	_connect_timer.start()
	NetworkEvents.join_started.emit(address.strip_edges(), port)
	return OK

func disconnect_session() -> Error:
	if _state == _CS.DISCONNECTED:
		return OK
	_teardown()
	return OK

# ---------------- معالجات الـ Transport ----------------

func _on_peer_connected(peer_id: int) -> void:
	if _state == _CS.CONNECTING:
		if peer_id == NetworkConfig.SERVER_PEER_ID:
			_complete_client_connection()
	elif _state == _CS.HOSTING:
		_handle_host_peer_joined(peer_id)
	elif _state == _CS.CONNECTED:
		_register_remote(peer_id)

func _on_peer_disconnected(peer_id: int) -> void:
	if _state == _CS.CONNECTED and peer_id == NetworkConfig.SERVER_PEER_ID:
		_on_server_disconnected()
		return
	if _session.remove_remote_peer(peer_id):
		NetworkEvents.player_disconnected.emit(peer_id)

func _on_connected_to_server() -> void:
	_complete_client_connection()

func _on_connection_failed() -> void:
	_fail_connection("connection_failed")

func _on_connect_timeout() -> void:
	_fail_connection("timeout")

func _on_server_disconnected() -> void:
	if _state != _CS.CONNECTED:
		return
	_teardown()
	NetworkEvents.server_disconnected.emit()

# ---------------- داخلي ----------------

func _complete_client_connection() -> void:
	if _state != _CS.CONNECTING:
		return  # idempotent: الإشارتان قد تصلان بأي ترتيب
	_connect_timer.stop()
	var err: Error = _session.start_client(_transport.get_unique_id())
	if err == OK:
		err = _session.add_remote_peer(NetworkConfig.SERVER_PEER_ID)
	if err != OK:
		_fail_connection("session_error: %s" % error_string(err))
		return
	_set_state(_CS.CONNECTED)
	_clock.start_as_client()
	NetworkEvents.connected_to_host.emit()
	NetworkEvents.player_connected.emit(NetworkConfig.SERVER_PEER_ID)

func _handle_host_peer_joined(peer_id: int) -> void:
	var check: Error = _session.can_accept_peer(peer_id)
	if check == OK:
		check = _session.add_remote_peer(peer_id)
	if check != OK:
		_reject_peer(peer_id, error_string(check))
		return
	NetworkEvents.player_connected.emit(peer_id)

func _register_remote(peer_id: int) -> void:
	if _session.can_accept_peer(peer_id) != OK:
		return
	if _session.add_remote_peer(peer_id) == OK:
		NetworkEvents.player_connected.emit(peer_id)

func _reject_peer(peer_id: int, reason: String) -> void:
	var peer: MultiplayerPeer = multiplayer.multiplayer_peer
	if peer != null:
		peer.disconnect_peer(peer_id)
	NetworkEvents.player_rejected.emit(peer_id, reason)

func _fail_connection(reason: String) -> void:
	if _state != _CS.CONNECTING:
		return
	_teardown()
	NetworkEvents.connection_failed.emit(reason)

func _teardown() -> void:
	if _tearing_down:
		return
	_tearing_down = true
	_connect_timer.stop()
	_clock.stop()
	var was_active: bool = _session.is_active()
	var remote_ids: Array[int] = _session.get_remote_peer_ids()
	_transport.close()
	_session.end()
	_set_state(_CS.DISCONNECTED)
	_tearing_down = false
	for id: int in remote_ids:
		NetworkEvents.player_disconnected.emit(id)
	if was_active:
		NetworkEvents.session_ended.emit()

func _set_state(new_state: int) -> void:
	if new_state == _state:
		return
	var old: int = _state
	_state = new_state
	NetworkEvents.connection_state_changed.emit(old, new_state)
