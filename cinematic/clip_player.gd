extends Node3D
## Plays named clips on the first AnimationPlayer under this node (shopper / cashier kit).

var _ap: AnimationPlayer

func _ready() -> void:
	_find_ap()

func _find_ap() -> void:
	var found := find_children("*", "AnimationPlayer", true, false)
	if found.size() > 0:
		_ap = found[0] as AnimationPlayer

func play_clip(clip: String, speed: float = 1.0) -> void:
	if _ap == null:
		_find_ap()
	if _ap == null:
		return
	for a in _ap.get_animation_list():
		var s := String(a)
		if s == clip or s.ends_with("/" + clip) or s.to_lower() == clip.to_lower():
			var anim := _ap.get_animation(s)
			if anim:
				anim.loop_mode = Animation.LOOP_LINEAR
			_ap.speed_scale = speed
			_ap.play(s, 0.12)
			return

func set_speed(speed: float) -> void:
	if _ap == null:
		_find_ap()
	if _ap:
		_ap.speed_scale = speed
