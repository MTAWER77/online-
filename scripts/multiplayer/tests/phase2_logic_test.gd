extends Node
## اختبار آلي (Registry + Session + Manager). اربطه بمشهد Node وشغّله.
## يحتاج Autoload: NetworkEvents ثم NetworkManager.

var _pass: int = 0
var _fail: int = 0

func _check(name: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("PASS  ", name)
	else:
		_fail += 1
		print("FAIL  ", name)

func _ready() -> void:
	_test_registry()
	_test_session()
	_test_manager_local()
	await _test_connection_failed()
	print("== %d passed, %d failed ==" % [_pass, _fail])

func _test_registry() -> void:
	var r: PlayerRegistry = PlayerRegistry.new()
	_check("registry: register 1", r.register(1, true) == OK)
	_check("registry: duplicate rejected", r.register(1) == ERR_ALREADY_EXISTS)
	_check("registry: invalid id", r.register(0) == ERR_INVALID_PARAMETER)
	_check("registry: register 2", r.register(55) == OK)
	_check("registry: full rejects third", r.register(77) == ERR_CANT_ACQUIRE_RESOURCE)
	_check("registry: owner lookup", r.get_player(55) != null and r.get_player(55).peer_id == 55)
	_check("registry: unknown owner null", r.get_player(99) == null)
	_check("registry: ids sorted", r.get_peer_ids() == [1, 55])
	var snap: Array[Dictionary] = r.to_snapshot()
	_check("registry: unregister", r.unregister(55) and not r.has_player(55))
	_check("registry: unregister missing", not r.unregister(55))
	_check("registry: restore snapshot", r.restore_from_snapshot(snap) == OK and r.get_count() == 2)
	var bad: Array = [{"peer_id": 5}, {"peer_id": 5}]
	_check("registry: bad snapshot rejected, unchanged", r.restore_from_snapshot(bad) == ERR_INVALID_DATA and r.get_count() == 2)
	r.clear()
	_check("registry: clear", r.get_count() == 0)

func _test_session() -> void:
	var s: NetworkSession = NetworkSession.new()
	_check("session: inactive initially", not s.is_active())
	_check("session: add before start", s.add_remote_peer(9) == ERR_UNCONFIGURED)
	_check("session: start_host", s.start_host() == OK and s.is_host() and s.local_peer_id == 1)
	_check("session: start twice", s.start_host() == ERR_ALREADY_IN_USE)
	_check("session: can accept", s.can_accept_peer(9) == OK)
	_check("session: add remote", s.add_remote_peer(9) == OK)
	_check("session: duplicate", s.can_accept_peer(9) == ERR_ALREADY_EXISTS)
	_check("session: full", s.can_accept_peer(10) == ERR_CANT_ACQUIRE_RESOURCE)
	_check("session: remote ids", s.get_remote_peer_ids() == [9])
	_check("session: cannot remove local", not s.remove_remote_peer(1))
	_check("session: remove remote", s.remove_remote_peer(9))
	s.end()
	_check("session: end cleans", not s.is_active() and s.registry.get_count() == 0)
	_check("session: client bad id", s.start_client(1) == ERR_INVALID_PARAMETER)
	_check("session: start_client", s.start_client(123) == OK and not s.is_host())

func _test_manager_local() -> void:
	_check("manager: join invalid port", NetworkManager.join_game("127.0.0.1", 80) == ERR_INVALID_PARAMETER)
	_check("manager: join empty address", NetworkManager.join_game("", 7777) == ERR_INVALID_PARAMETER)
	_check("manager: not ready before", not NetworkManager.is_network_ready())
	_check("manager: host ok", NetworkManager.host_game(7791) == OK)
	_check("manager: state HOSTING", NetworkManager.get_state() == NetworkConfig.ConnectionState.HOSTING)
	_check("manager: ready", NetworkManager.is_network_ready())
	_check("manager: host twice blocked", NetworkManager.host_game(7791) == ERR_ALREADY_IN_USE)
	_check("manager: join while hosting blocked", NetworkManager.join_game("127.0.0.1", 7791) == ERR_ALREADY_IN_USE)
	_check("manager: registry has host", NetworkManager.get_registry().get_count() == 1)
	_check("manager: disconnect", NetworkManager.disconnect_session() == OK)
	_check("manager: cleaned", NetworkManager.get_state() == NetworkConfig.ConnectionState.DISCONNECTED and NetworkManager.get_registry().get_count() == 0 and not NetworkManager.is_network_ready())
	_check("manager: disconnect idempotent", NetworkManager.disconnect_session() == OK)
	_check("manager: host again after cleanup", NetworkManager.host_game(7791) == OK)
	NetworkManager.disconnect_session()

func _test_connection_failed() -> void:
	print("... waiting for connection failure (up to ~10s)")
	_check("manager: join starts", NetworkManager.join_game("127.0.0.1", 7799) == OK)
	_check("manager: state CONNECTING", NetworkManager.get_state() == NetworkConfig.ConnectionState.CONNECTING)
	var reason: String = await NetworkEvents.connection_failed
	print("      reason = ", reason)
	_check("manager: failure -> DISCONNECTED", NetworkManager.get_state() == NetworkConfig.ConnectionState.DISCONNECTED)
	_check("manager: failure -> registry empty", NetworkManager.get_registry().get_count() == 0)
