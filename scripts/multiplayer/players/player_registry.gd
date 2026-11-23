class_name PlayerRegistry
extends RefCounted
## سجل اللاعبين داخل الجلسة: peer_id -> PlayerInfo. لا يعرف شيئًا عن الشبكة.

signal player_registered(peer_id: int)
signal player_unregistered(peer_id: int)
signal registry_cleared()

class PlayerInfo extends RefCounted:
	var peer_id: int = 0
	var is_host: bool = false
	var joined_msec: int = 0

var _players: Dictionary = {}  # int -> PlayerInfo

func register(peer_id: int, is_host: bool = false) -> Error:
	if peer_id <= 0:
		return ERR_INVALID_PARAMETER
	if _players.has(peer_id):
		return ERR_ALREADY_EXISTS
	if _players.size() >= NetworkConfig.MAX_PLAYERS:
		return ERR_CANT_ACQUIRE_RESOURCE
	var info: PlayerInfo = PlayerInfo.new()
	info.peer_id = peer_id
	info.is_host = is_host
	info.joined_msec = Time.get_ticks_msec()
	_players[peer_id] = info
	player_registered.emit(peer_id)
	return OK

func unregister(peer_id: int) -> bool:
	if not _players.has(peer_id):
		return false
	_players.erase(peer_id)
	player_unregistered.emit(peer_id)
	return true

func has_player(peer_id: int) -> bool:
	return _players.has(peer_id)

## صاحب الـ Peer ID (null لو غير موجود).
func get_player(peer_id: int) -> PlayerInfo:
	return _players.get(peer_id, null) as PlayerInfo

func get_peer_ids() -> Array[int]:
	var ids: Array[int] = []
	for key: Variant in _players.keys():
		ids.append(int(key))
	ids.sort()
	return ids

func get_count() -> int:
	return _players.size()

func is_full() -> bool:
	return _players.size() >= NetworkConfig.MAX_PLAYERS

func clear() -> void:
	if _players.is_empty():
		return
	_players.clear()
	registry_cleared.emit()

## لقطة قابلة للإرسال/الحفظ لإعادة بناء الحالة بعد الاتصال.
func to_snapshot() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id: int in get_peer_ids():
		var info: PlayerInfo = _players[id] as PlayerInfo
		out.append({"peer_id": info.peer_id, "is_host": info.is_host})
	return out

## يتحقق من اللقطة كاملة قبل أي تعديل؛ لو فيها خطأ يبقى السجل كما هو.
func restore_from_snapshot(snapshot: Array) -> Error:
	if snapshot.size() > NetworkConfig.MAX_PLAYERS:
		return ERR_INVALID_DATA
	var seen: Dictionary = {}
	for entry: Variant in snapshot:
		if not (entry is Dictionary):
			return ERR_INVALID_DATA
		var d: Dictionary = entry as Dictionary
		if not (d.get("peer_id") is int) or int(d["peer_id"]) <= 0:
			return ERR_INVALID_DATA
		if seen.has(int(d["peer_id"])):
			return ERR_INVALID_DATA
		seen[int(d["peer_id"])] = true
	clear()
	for entry: Variant in snapshot:
		var d: Dictionary = entry as Dictionary
		var err: Error = register(int(d["peer_id"]), bool(d.get("is_host", false)))
		if err != OK:
			return err
	return OK
