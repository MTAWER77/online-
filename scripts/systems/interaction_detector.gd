extends Area3D
## scripts/systems/interaction_detector.gd
## موجود جوه اللاعب. بيلاقي أقرب Interactable، وبيعرض نصه، ولما اللاعب يدوس E بيبعتله الطلب.
## شغال للاعب المحلي بس.

const INTERACTABLE_GROUP: StringName = &"interactable"

var _player: Node3D
var _target: Variant = null # أقرب حاجة قابلة للتفاعل (Variant عشان نناديها ديناميك)
var _label: Label


func _ready() -> void:
	_player = get_parent() as Node3D


func _process(_delta: float) -> void:
	if _player == null or not _player.get("is_local"):
		_target = null
		_hide_prompt()
		return
	_target = _find_best_target()
	_update_prompt()


func _unhandled_input(event: InputEvent) -> void:
	if _target == null or _player == null or not _player.get("is_local"):
		return
	if event.is_action_pressed("interact"):
		_target.request_interact()
		get_viewport().set_input_as_handled()


func _find_best_target() -> Variant:
	var best: Variant = null
	var best_distance: float = INF
	for raw in get_overlapping_areas():
		var area: Variant = raw
		if not area.is_in_group(INTERACTABLE_GROUP):
			continue
		if not area.can_interact(area.local_client_id()):
			continue
		var distance: float = _player.global_position.distance_to(area.global_position)
		if distance < best_distance:
			best_distance = distance
			best = area
	return best


# ---- نص التفاعل (E: Pick up ...) ----
func _update_prompt() -> void:
	if _target == null:
		_hide_prompt()
		return
	_ensure_label()
	_label.text = _target.get_prompt(_target.local_client_id())
	_label.visible = true


func _hide_prompt() -> void:
	if _label != null:
		_label.visible = false


func _ensure_label() -> void:
	if _label != null:
		return
	var layer := CanvasLayer.new()
	_label = Label.new()
	_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	_label.offset_top = -100.0
	_label.offset_bottom = -60.0
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	layer.add_child(_label)
	add_child(layer)
