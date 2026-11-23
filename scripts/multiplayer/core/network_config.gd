class_name NetworkConfig
extends RefCounted
## ثوابت وإعدادات الشبكة + التحقق من المدخلات. لا يحتوي على حالة.

const DEFAULT_PORT: int = 7777
const MIN_PORT: int = 1024
const MAX_PORT: int = 65535
const MAX_PLAYERS: int = 2          # Host + Client
const MAX_CLIENTS: int = MAX_PLAYERS - 1
const CONNECT_TIMEOUT_SEC: float = 10.0
const PROTOCOL_VERSION: int = 1
const SERVER_PEER_ID: int = 1

enum ConnectionState {
	DISCONNECTED,
	CONNECTING,
	HOSTING,
	CONNECTED,
}

static func is_valid_port(port: int) -> bool:
	return port >= MIN_PORT and port <= MAX_PORT

static func is_valid_address(address: String) -> bool:
	var a: String = address.strip_edges()
	if a.is_empty() or a.length() > 253:
		return false
	return not a.contains(" ")

static func state_name(state: int) -> String:
	match state:
		ConnectionState.DISCONNECTED: return "DISCONNECTED"
		ConnectionState.CONNECTING: return "CONNECTING"
		ConnectionState.HOSTING: return "HOSTING"
		ConnectionState.CONNECTED: return "CONNECTED"
	return "UNKNOWN"
