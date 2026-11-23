extends Node3D
## Auto-plays the trolley scene-motion animation if present.

func _ready() -> void:
	await get_tree().process_frame
	var found := find_children("*", "AnimationPlayer", true, false)
	if found.is_empty():
		return
	var ap: AnimationPlayer = found[0]
	var list := ap.get_animation_list()
	if list.is_empty():
		return
	for a in list:
		var s := String(a)
		if "scene" in s.to_lower() or "motion" in s.to_lower():
			var anim := ap.get_animation(s)
			if anim:
				anim.loop_mode = Animation.LOOP_LINEAR
			ap.play(s)
			return
	var anim0 := ap.get_animation(list[0])
	if anim0:
		anim0.loop_mode = Animation.LOOP_LINEAR
	ap.play(list[0])
