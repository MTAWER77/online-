@tool
extends EditorPlugin

## Godotion entry point.
##
## Registers the bottom panel and routes scene-tree selection of a
## [MotionPlayer] (or an inspected [MotionTimeline]) into it. The runtime
## classes register themselves through [code]class_name[/code], so no
## [method EditorPlugin.add_custom_type] calls are needed — adding them would
## collide with the global script classes.

const TimelinePanel := preload("res://addons/godotion/editor/timeline_panel.gd")

var _panel: TimelinePanel
var _panel_button: Button


func _enter_tree() -> void:
	_panel = TimelinePanel.new()
	_panel.name = "Godotion"
	_panel.undo_redo = get_undo_redo()
	_panel_button = add_control_to_bottom_panel(_panel, "Godotion")


func _exit_tree() -> void:
	if _panel != null:
		remove_control_from_bottom_panel(_panel)
		_panel.queue_free()
		_panel = null
	_panel_button = null


func _get_plugin_name() -> String:
	return "Godotion"


func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_editor_theme().get_icon(&"Animation", &"EditorIcons")


func _handles(object: Object) -> bool:
	return object is MotionPlayer or object is MotionTimeline


func _edit(object: Object) -> void:
	if _panel == null:
		return
	if object is MotionPlayer:
		_panel.edit_player(object)
	elif object is MotionTimeline:
		# Selecting the timeline sub-resource in the inspector must not unbind
		# the player it belongs to — Add Track and Key both need its root_node.
		_panel.edit_timeline(object)


func _make_visible(visible: bool) -> void:
	if _panel_button == null:
		return
	if visible:
		make_bottom_panel_item_visible(_panel)
	elif _panel.get_timeline() == null:
		hide_bottom_panel()


## Editing shortcuts. Only fire while the panel is visible and actually has
## focus, so Ctrl+C in the script editor is never stolen.
func _shortcut_input(event: InputEvent) -> void:
	if _panel == null or not _panel.is_visible_in_tree() or _panel.get_timeline() == null:
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var focus := _panel.get_viewport().gui_get_focus_owner()
	if focus == null or not _panel.is_ancestor_of(focus):
		return
	# The panel's own text fields are inside the panel too. Ctrl+A in the filter
	# box means "select this text", not "select every key on the timeline".
	if focus is LineEdit or focus is TextEdit:
		return

	var handled := true
	if event.is_command_or_control_pressed():
		match event.keycode:
			KEY_C: _panel.copy_keys()
			KEY_X: _panel.cut_keys()
			KEY_V: _panel.paste_keys()
			KEY_D: _panel.duplicate_keys()
			KEY_A:
				if event.shift_pressed:
					_panel.invert_selection()
				else:
					_panel.select_all_keys()
			_: handled = false
	else:
		match event.keycode:
			KEY_K: _panel.key_at_playhead()
			KEY_SPACE: _panel.toggle_preview()
			_: handled = false

	if handled:
		get_viewport().set_input_as_handled()
