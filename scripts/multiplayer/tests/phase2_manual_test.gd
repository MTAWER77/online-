extends Node
## اختبار يدوي بنسختين/ثلاث. اربطه بمشهد Node.
## الوسائط: -- --host   أو   -- --join [ip]   (أو Debug > Run Multiple Instances)

func _ready() -> void:
	NetworkEvents.connection_state_changed.connect(func(o: int, n: int) -> void:
		print("[state] %s -> %s" % [NetworkConfig.state_name(o), NetworkConfig.state_name(n)]))
	NetworkEvents.host_started.connect(func(p: int) -> void: print("[host_started] port ", p))
	NetworkEvents.join_started.connect(func(a: String, p: int) -> void: print("[join_started] ", a, ":", p))
	NetworkEvents.connected_to_host.connect(func() -> void: print("[connected_to_host] me=", NetworkManager.get_local_peer_id()))
	NetworkEvents.connection_failed.connect(func(r: String) -> void: print("[connection_failed] ", r))
	NetworkEvents.server_disconnected.connect(func() -> void: print("[server_disconnected]"))
	NetworkEvents.player_connected.connect(func(id: int) -> void:
		print("[player_connected] ", id, " | registry=", NetworkManager.get_registry().get_peer_ids()))
	NetworkEvents.player_disconnected.connect(func(id: int) -> void:
		print("[player_disconnected] ", id, " | registry=", NetworkManager.get_registry().get_peer_ids()))
	NetworkEvents.player_rejected.connect(func(id: int, r: String) -> void: print("[player_rejected] ", id, " ", r))
	NetworkEvents.session_ended.connect(func() -> void: print("[session_ended]"))
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if "--host" in args:
		print("host_game -> ", error_string(NetworkManager.host_game()))
	elif "--join" in args:
		var i: int = args.find("--join")
		var ip: String = args[i + 1] if i + 1 < args.size() else "127.0.0.1"
		print("join_game -> ", error_string(NetworkManager.join_game(ip)))
	else:
		print("Use: -- --host   or   -- --join [ip]")
