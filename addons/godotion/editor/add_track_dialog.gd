@tool
extends ConfirmationDialog

## Node + property picker for creating tracks.
##
## Picks the node itself rather than depending on the Scene dock selection —
## requiring an invisible prior selection was the single most confusing thing
## about the first version. A Scene dock selection still seeds the dialog when
## present, but is never required.
##
## Emits [signal tracks_requested] with the chosen nodes and property; creating
## the tracks (undoably) is the panel's job.

signal tracks_requested(nodes: Array, property: String, mode: int)

const GodotionTheme := preload("res://addons/godotion/editor/godotion_theme.gd")

## Property types worth keyframing. Anything else is filtered out because
## [MotionTrack] cannot interpolate it meaningfully.
const ANIMATABLE_TYPES := [
	TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4,
	TYPE_VECTOR2I, TYPE_VECTOR3I, TYPE_VECTOR4I, TYPE_RECT2,
	TYPE_COLOR, TYPE_QUATERNION, TYPE_TRANSFORM2D, TYPE_TRANSFORM3D,
]

## Sub-properties offered per type, so a single axis or channel can be keyed on
## its own. Keying one float is what makes the curve view usable, so every
## type that has components gets them listed — not just Vector2/3 and Color.
const COMPONENTS := {
	TYPE_VECTOR2: ["x", "y"],
	TYPE_VECTOR2I: ["x", "y"],
	TYPE_VECTOR3: ["x", "y", "z"],
	TYPE_VECTOR3I: ["x", "y", "z"],
	TYPE_VECTOR4: ["x", "y", "z", "w"],
	TYPE_VECTOR4I: ["x", "y", "z", "w"],
	TYPE_QUATERNION: ["x", "y", "z", "w"],
	TYPE_COLOR: ["r", "g", "b", "a"],
}

var _node_tree: Tree
var _property_picker: OptionButton
var _filter_edit: LineEdit
var _target_label: Label
var _mode_picker: OptionButton
var _root: Node = null
var _skip_node: Node = null


func _init() -> void:
	title = "Add Motion Track"
	ok_button_text = "Add Track"

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)

	_target_label = Label.new()
	_target_label.text = "Pick a node to animate. Ctrl-click for several."
	_target_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	box.add_child(_target_label)

	_node_tree = Tree.new()
	_node_tree.select_mode = Tree.SELECT_MULTI
	_node_tree.hide_root = false
	_node_tree.custom_minimum_size = Vector2(380, 240)
	_node_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_node_tree.multi_selected.connect(_on_multi_selected)
	box.add_child(_node_tree)

	var mode_row := HBoxContainer.new()
	var mode_label := Label.new()
	mode_label.text = "Track type"
	mode_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	mode_row.add_child(mode_label)
	_mode_picker = OptionButton.new()
	_mode_picker.add_item("Property — write a value every frame", MotionTrack.Mode.PROPERTY)
	_mode_picker.add_item("Trigger — call a method on each key", MotionTrack.Mode.TRIGGER)
	_mode_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mode_picker.item_selected.connect(func(_i: int) -> void: _refresh_properties())
	mode_row.add_child(_mode_picker)
	box.add_child(mode_row)

	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = "Property"
	label.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	row.add_child(label)

	_filter_edit = LineEdit.new()
	_filter_edit.placeholder_text = "Filter…"
	_filter_edit.custom_minimum_size.x = 110
	_filter_edit.text_changed.connect(func(_t: String) -> void: _refresh_properties())
	row.add_child(_filter_edit)

	_property_picker = OptionButton.new()
	_property_picker.custom_minimum_size.x = 220
	_property_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_property_picker)
	box.add_child(row)

	add_child(box)
	confirmed.connect(_on_confirmed)


## Repopulates from [param root], skipping [param skip_node] (the MotionPlayer —
## animating the thing driving the animation is never what the user means).
func open(root: Node, skip_node: Node, preselected: Array[Node]) -> void:
	_root = root
	_skip_node = skip_node
	_node_tree.clear()
	_populate(root, null)

	if preselected.is_empty():
		var first := _node_tree.get_root()
		if first != null:
			var child := first.get_first_child()
			(child if child != null else first).select(0)
	else:
		for node in preselected:
			var item := _find_item(root.get_path_to(node))
			if item != null:
				item.select(0)

	_refresh_properties()
	popup_centered(Vector2i(480, 460))


func _populate(node: Node, parent: TreeItem) -> void:
	if node == _skip_node:
		return
	var item := _node_tree.create_item(parent)
	item.set_text(0, node.name)
	item.set_metadata(0, _root.get_path_to(node))
	var icon := GodotionTheme.icon_for_node(node)
	if icon != null:
		item.set_icon(0, icon)
	if node != _root:
		item.set_tooltip_text(0, String(_root.get_path_to(node)))
	for child in node.get_children():
		_populate(child, item)


func _find_item(path: NodePath, from: TreeItem = null) -> TreeItem:
	var item := from if from != null else _node_tree.get_root()
	if item == null:
		return null
	if item.get_metadata(0) == path:
		return item
	var child := item.get_first_child()
	while child != null:
		var found := _find_item(path, child)
		if found != null:
			return found
		child = child.get_next()
	return null


func selected_nodes() -> Array[Node]:
	var out: Array[Node] = []
	if _root == null:
		return out
	var item := _node_tree.get_next_selected(null)
	while item != null:
		var path: NodePath = item.get_metadata(0)
		var node: Node = _root if path.is_empty() else _root.get_node_or_null(path)
		if node != null:
			out.append(node)
		item = _node_tree.get_next_selected(item)
	return out


func _on_multi_selected(_item: TreeItem, _column: int, _selected: bool) -> void:
	_refresh_properties()


## Rebuilds the property list from the first selected node, preserving the
## current choice when the new node also exposes it.
func _refresh_properties() -> void:
	var previous := ""
	if _property_picker.selected >= 0:
		previous = _property_picker.get_item_text(_property_picker.selected)

	_property_picker.clear()
	var nodes := selected_nodes()
	if nodes.is_empty():
		_target_label.text = "Pick a node to animate. Ctrl-click for several."
		get_ok_button().disabled = true
		return

	var trigger := selected_mode() == MotionTrack.Mode.TRIGGER
	var needle := _filter_edit.text.to_lower()
	var candidates := collect_triggerable_methods(nodes[0]) if trigger \
		else collect_animatable_properties(nodes[0])
	for prop in candidates:
		if not needle.is_empty() and not prop.to_lower().contains(needle):
			continue
		_property_picker.add_item(prop)
		if prop == previous:
			_property_picker.select(_property_picker.item_count - 1)

	var has_properties := _property_picker.item_count > 0
	get_ok_button().disabled = not has_properties
	if not has_properties:
		_target_label.text = "'%s' exposes no matching %s." % [
			nodes[0].name, "methods" if trigger else "properties"]
		return

	var names := PackedStringArray()
	for node in nodes:
		names.append(node.name)
	if nodes.size() == 1:
		_target_label.text = "Target: %s" % names[0]
	else:
		_target_label.text = "Targets: %s  (properties from '%s')" % [", ".join(names), names[0]]


## Engine bookkeeping that is technically an animatable type but never sensible
## to key. These sort first in `get_property_list()`, so without this filter the
## picker's default selection is `process_mode` for every node in existence —
## a track that provably cannot move anything on screen.
const EXCLUDED := [
	"process_mode", "process_priority", "process_physics_priority",
	"process_thread_group", "process_thread_group_order",
	"process_thread_messages", "physics_interpolation_mode",
	"auto_translate_mode", "editor_description", "unique_name_in_owner",
	"scene_file_path", "owner", "multiplayer", "script",
]

## Properties worth offering first, most-animated first. Anything not listed
## keeps its natural order after these.
const PREFERRED := [
	"position", "global_position", "rotation", "global_rotation", "scale",
	"global_scale", "skew", "size", "modulate", "self_modulate", "color",
	"offset_left", "offset_top", "offset_right", "offset_bottom",
	"pivot_offset", "visible", "z_index",
]


## Flattens a node's exported properties into keyable paths, expanding vector
## and color components so users can key a single axis or the alpha channel.
##
## Ordered so the first entry is something worth animating: the dropdown's
## default selection is whatever lands at index 0, and users reasonably trust it.
static func collect_animatable_properties(node: Node) -> PackedStringArray:
	var preferred := PackedStringArray()
	var rest := PackedStringArray()
	for entry in node.get_property_list():
		var usage: int = entry["usage"]
		if usage & PROPERTY_USAGE_EDITOR == 0 or usage & PROPERTY_USAGE_CATEGORY != 0:
			continue
		var type: int = entry["type"]
		if not ANIMATABLE_TYPES.has(type):
			continue
		var name: String = entry["name"]
		if name.begins_with("_") or name.contains("/") or EXCLUDED.has(name):
			continue
		var bucket := preferred if PREFERRED.has(name) else rest
		bucket.append(name)
		for component in COMPONENTS.get(type, []):
			bucket.append("%s:%s" % [name, component])

	# Emit PREFERRED in its own order rather than the node's.
	var out := PackedStringArray()
	for wanted in PREFERRED:
		for candidate in preferred:
			if candidate == wanted or candidate.begins_with(wanted + ":"):
				out.append(candidate)
	out.append_array(rest)
	return out



## Methods a trigger track can usefully call: no required arguments, and not the
## accessor noise that dominates any Godot object's method list.
##
## The arity rule is the important one — [MotionPlayer] passes the key's value
## when the method has a slot for it, so anything needing two or more arguments
## can never be called correctly and is not worth offering.
static func collect_triggerable_methods(node: Node) -> PackedStringArray:
	var preferred := PackedStringArray()
	var rest := PackedStringArray()
	for entry in node.get_method_list():
		var name: String = entry["name"]
		if name.begins_with("_"):
			continue
		if name.begins_with("set_") or name.begins_with("get_") or name.begins_with("is_") \
				or name.begins_with("has_") or name.begins_with("add_") \
				or name.begins_with("remove_") or name.begins_with("find_"):
			continue
		var args: Array = entry["args"]
		var defaults: Array = entry["default_args"]
		if args.size() - defaults.size() > 0:
			continue
		if args.size() > 1:
			continue
		var bucket := preferred if PREFERRED_METHODS.has(name) else rest
		bucket.append(name)

	var out := PackedStringArray()
	for wanted in PREFERRED_METHODS:
		if preferred.has(wanted):
			out.append(wanted)
	out.append_array(rest)
	return out


## Cue-shaped methods, offered first. `play` heads the list because a sound or
## a particle burst is what a trigger track is overwhelmingly for, and the
## dropdown's default selection is whatever lands at index 0.
const PREFERRED_METHODS := [
	"play", "stop", "restart", "emit", "show", "hide", "queue_free",
	"grab_focus", "advance",
]


func selected_mode() -> int:
	if _mode_picker == null or _mode_picker.selected < 0:
		return MotionTrack.Mode.PROPERTY
	return _mode_picker.get_item_id(_mode_picker.selected)


func _on_confirmed() -> void:
	if _property_picker.selected < 0:
		return
	var nodes := selected_nodes()
	if nodes.is_empty():
		return
	tracks_requested.emit(
		nodes, _property_picker.get_item_text(_property_picker.selected), selected_mode())
