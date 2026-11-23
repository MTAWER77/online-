extends Control
## واجهة اختبار الشبكة + تشخيص الساعة. تتحدث من إشارات NetworkEvents وإشارات NetworkClock،
## والقيم المتغيرة باستمرار (الوقت) تتحدث كل 0.1 ثانية.
## تعتمد على Autoload: NetworkEvents ثم NetworkManager.

const _CS = NetworkConfig.ConnectionState
const DIAG_INTERVAL_SEC: float = 0.1
const SNAPSHOT_CAPACITY: int = 32

@onready var _ip_edit: LineEdit = %IpEdit
@onready var _port_edit: LineEdit = %PortEdit
@onready var _host_button: Button = %HostButton
@onready var _join_button: Button = %JoinButton
@onready var _disconnect_button: Button = %DisconnectButton
@onready var _status_label: Label = %StatusLabel
@onready var _peer_id_label: Label = %PeerIdLabel
@onready var _count_label: Label = %PlayerCountLabel
@onready var _players_list: ItemList = %PlayersList
@onready var _clock_state_label: Label = %ClockStateLabel
@onready var _host_time_label: Label = %HostTimeLabel
@onready var _offset_label: Label = %OffsetLabel
@onready var _rtt_label: Label = %RttLabel
@onready var _snapshot_label: Label = %SnapshotCountLabel

var _note: String = ""
var _diag_accum: float = 0.0
## يخزّن تاريخ عينات الساعة (rtt/offset) كلقطات: استخدام فعلي لـ SnapshotBuffer (بدون مزامنة لاعب).
var _clock_history: SnapshotBuffer = SnapshotBuffer.new(SNAPSHOT_CAPACITY)

func _ready() -> void:
	_ip_edit.text = "127.0.0.1"
	_port_edit.text = str(NetworkConfig.DEFAULT_PORT)
	_host_button.pressed.connect(_on_host_pressed)
	_join_button.pressed.connect(_on_join_pressed)
	_disconnect_button.pressed.connect(_on_disconnect_pressed)
	NetworkEvents.connection_state_changed.connect(_on_state_changed)
	NetworkEvents.host_started.connect(_on_host_started)
	NetworkEvents.join_started.connect(_on_join_started)
	NetworkEvents.connected_to_host.connect(_on_connected_to_host)
	NetworkEvents.connection_failed.connect(_on_connection_failed)
	NetworkEvents.server_disconnected.connect(_on_server_disconnected)
	NetworkEvents.player_connected.connect(_on_player_connected)
	NetworkEvents.player_disconnected.connect(_on_player_disconnected)
	NetworkEvents.player_rejected.connect(_on_player_rejected)
	NetworkEvents.session_ended.connect(_on_session_ended)
	var clock: NetworkClock = NetworkManager.get_clock()
	clock.sample_added.connect(_on_clock_sample)
	clock.sync_state_changed.connect(_on_clock_sync_changed)
	_refresh()

func _process(delta: float) -> void:
	_diag_accum += delta
	if _diag_accum >= DIAG_INTERVAL_SEC:
		_diag_accum = 0.0
		_refresh_diagnostics()

# ---------- أزرار ----------

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
		_set_note("Invalid port (%d-%d)" % [NetworkConfig.MIN_PORT, NetworkConfig.MAX_PORT])
		return -1
	return text.to_int()

# ---------- إشارات الشبكة ----------

func _on_state_changed(_old_state: int, _new_state: int) -> void:
	_refresh()

func _on_host_started(port: int) -> void:
	_set_note("Hosting on port %d, waiting for a client" % port)

func _on_join_started(address: String, port: int) -> void:
	_set_note("Connecting to %s:%d ..." % [address, port])

func _on_connected_to_host() -> void:
	_set_note("Connected to host")

func _on_connection_failed(reason: String) -> void:
	_set_note("Connection failed: %s" % reason)

func _on_server_disconnected() -> void:
	_set_note("Host disconnected")

func _on_player_connected(peer_id: int) -> void:
	_set_note("Player %d joined" % peer_id)

func _on_player_disconnected(peer_id: int) -> void:
	_set_note("Player %d left" % peer_id)

func _on_player_rejected(peer_id: int, reason: String) -> void:
	_set_note("Rejected peer %d: %s" % [peer_id, reason])

func _on_session_ended() -> void:
	_clock_history.clear()
	_set_note("Session ended")

# ---------- إشارات الساعة ----------

func _on_clock_sample(rtt_usec: int, offset_sec: float) -> void:
	var clock: NetworkClock = NetworkManager.get_clock()
	_clock_history.add(clock.get_local_time(), {"rtt_ms": float(rtt_usec) / 1000.0, "offset": offset_sec})
	_refresh_diagnostics()

func _on_clock_sync_changed(synced: bool) -> void:
	if not synced:
		_clock_history.clear()
	_refresh_diagnostics()

# ---------- عرض ----------

func _set_note(text: String) -> void:
	_note = text
	_refresh()

func _refresh() -> void:
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
	var local_id: int = NetworkManager.get_local_peer_id()
	_peer_id_label.text = "Local Peer ID: %s" % (str(local_id) if local_id > 0 else "-")
	var registry: PlayerRegistry = NetworkManager.get_registry()
	_count_label.text = "Players: %d / %d" % [registry.get_count(), NetworkConfig.MAX_PLAYERS]
	_players_list.clear()
	for id: int in registry.get_peer_ids():
		var info: PlayerRegistry.PlayerInfo = registry.get_player(id)
		var role: String = "Host" if info.is_host else "Client"
		var suffix: String = " (You)" if id == local_id else ""
		_players_list.add_item("Peer %d - %s%s" % [id, role, suffix])
	_refresh_diagnostics()

func _refresh_diagnostics() -> void:
	var clock: NetworkClock = NetworkManager.get_clock()
	_clock_state_label.text = "Clock: %s" % clock.get_state_text()
	if not clock.is_running():
		_host_time_label.text = "Estimated Host Time: -"
		_offset_label.text = "Clock Offset: -"
		_rtt_label.text = "RTT: -"
	elif clock.get_role() == NetworkClock.Role.HOST:
		_host_time_label.text = "Estimated Host Time: %.3f s" % clock.get_network_time()
		_offset_label.text = "Clock Offset: 0.000 s (reference)"
		_rtt_label.text = "RTT: - (host)"
	else:
		_host_time_label.text = "Estimated Host Time: %.3f s" % clock.get_network_time()
		_offset_label.text = "Clock Offset: %.4f s" % clock.get_offset()
		_rtt_label.text = "RTT: %.1f ms" % clock.get_rtt_ms()
	_snapshot_label.text = "Clock Snapshots: %d / %d" % [_clock_history.size(), SNAPSHOT_CAPACITY]
