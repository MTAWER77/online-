extends RefCounted
## scripts/systems/debug_log.gd
## طباعة موحدة للتشخيص: [الوقت][TAG] الرسالة. اقفلها كلها بـ DebugLog.enabled = false.

static var enabled: bool = true


static func say(tag: String, message: String) -> void:
	if enabled:
		print("[%7.2f][%s] %s" % [Time.get_ticks_msec() / 1000.0, tag, message])
