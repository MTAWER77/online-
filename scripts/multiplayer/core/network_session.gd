class_name NetworkSession
extends RefCounted
## حالة الجلسة: الدور (Host/Client)، الـ Peer ID المحلي، وقواعد القبول.
## يملك PlayerRegistry. لا يعرف Transport ولا يطلق Signals شبكية.

enum Role { NONE, HOST, CLIENT }

var registry: PlayerRegistry = PlayerRegistry.new()
var role: Role = Role.NONE
var local_peer_id: int = 0

func is_active() -> bool:
	return role != Role.NONE

func is_host() -> bool:
	return role == Role.HOST

func is_full() -> bool:
	return registry.is_full()

func start_host() -> Error:
	if is_active():
		return ERR_ALREADY_IN_USE
	registry.clear()
	var err: Error = registry.register(NetworkConfig.SERVER_PEER_ID, true)
	if err != OK:
		return err
	role = Role.HOST
	local_peer_id = NetworkConfig.SERVER_PEER_ID
	return OK

func start_client(local_id: int) -> Error:
	if is_active():
		return ERR_ALREADY_IN_USE
	if local_id <= 1:
		return ERR_INVALID_PARAMETER
	registry.clear()
	var err: Error = registry.register(local_id, false)
	if err != OK:
		return err
	role = Role.CLIENT
	local_peer_id = local_id
	return OK

## OK / ERR_UNCONFIGURED / ERR_INVALID_PARAMETER / ERR_ALREADY_EXISTS / ERR_CANT_ACQUIRE_RESOURCE
func can_accept_peer(peer_id: int) -> Error:
	if not is_active():
		return ERR_UNCONFIGURED
	if peer_id <= 0:
		return ERR_INVALID_PARAMETER
	if registry.has_player(peer_id):
		return ERR_ALREADY_EXISTS
	if registry.is_full():
		return ERR_CANT_ACQUIRE_RESOURCE
	return OK

func add_remote_peer(peer_id: int) -> Error:
	if not is_active():
		return ERR_UNCONFIGURED
	return registry.register(peer_id, peer_id == NetworkConfig.SERVER_PEER_ID)

func remove_remote_peer(peer_id: int) -> bool:
	if peer_id == local_peer_id:
		return false
	return registry.unregister(peer_id)

func get_remote_peer_ids() -> Array[int]:
	var out: Array[int] = []
	for id: int in registry.get_peer_ids():
		if id != local_peer_id:
			out.append(id)
	return out

func end() -> void:
	registry.clear()
	role = Role.NONE
	local_peer_id = 0
