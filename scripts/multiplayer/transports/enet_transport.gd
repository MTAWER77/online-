class_name ENetTransport
extends TransportBase
## Transport مبني على ENet (مجاني ومدمج في Godot).
## ملاحظة: ENet اتصال مباشر IP:Port وليس فيه Relay ولا NAT traversal.

var _peer: ENetMultiplayerPeer = null

func get_transport_name() -> String:
	return "ENet"

func is_active() -> bool:
	return _peer != null

func create_host(port: int, max_clients: int) -> Error:
	if _api == null:
		return ERR_UNCONFIGURED
	if _peer != null:
		return ERR_ALREADY_IN_USE
	if not NetworkConfig.is_valid_port(port) or max_clients < 1:
		return ERR_INVALID_PARAMETER
	var p: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	var err: Error = p.create_server(port, max_clients)
	if err != OK:
		return err
	_attach_peer(p)
	return OK

func join(address: String, port: int) -> Error:
	if _api == null:
		return ERR_UNCONFIGURED
	if _peer != null:
		return ERR_ALREADY_IN_USE
	if not NetworkConfig.is_valid_address(address) or not NetworkConfig.is_valid_port(port):
		return ERR_INVALID_PARAMETER
	var p: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	var err: Error = p.create_client(address.strip_edges(), port)
	if err != OK:
		return err
	_attach_peer(p)
	return OK

func close() -> void:
	_disconnect_api_signals()
	if _peer != null:
		_peer.close()
		if _api != null and _api.multiplayer_peer == _peer:
			_api.multiplayer_peer = null
		_peer = null

func _attach_peer(p: ENetMultiplayerPeer) -> void:
	_peer = p
	_api.multiplayer_peer = p
	_connect_api_signals()
