extends Node
## Event Bus مركزي للشبكة (Autoload باسم NetworkEvents).
## لا منطق هنا: فقط إشارات يطلقها NetworkManager ويسمعها الباقي.
## ملاحظة: بدون class_name لتفادي تعارض اسم الـ Autoload.

signal connection_state_changed(old_state: int, new_state: int)
signal host_started(port: int)
signal join_started(address: String, port: int)
signal connected_to_host()
signal connection_failed(reason: String)
signal server_disconnected()
signal player_connected(peer_id: int)
signal player_disconnected(peer_id: int)
signal player_rejected(peer_id: int, reason: String)
signal session_ended()
