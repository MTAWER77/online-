@tool
extends VBoxContainer

## Bottom-panel UI: toolbar + dope sheet / curve view.
##
## Owns every mutation of the edited [MotionTimeline] so each one can be pushed
## through [EditorUndoRedoManager]. The canvases only report gestures.

const TimelineCanvas := preload("res://addons/godotion/editor/timeline_canvas.gd")
const CurveCanvas := preload("res://addons/godotion/editor/curve_canvas.gd")
const AddTrackDialog := preload("res://addons/godotion/editor/add_track_dialog.gd")
const ViewState := preload("res://addons/godotion/editor/timeline_view_state.gd")
const KeyClipboard := preload("res://addons/godotion/editor/key_clipboard.gd")
const GodotionTheme := preload("res://addons/godotion/editor/godotion_theme.gd")

## Context-menu ids for the track gutter.
enum TrackMenu { DELETE, DUPLICATE, OFFSET, SELECT_KEYS, CLEAR_KEYS, ADD_CUE }

## How close a selected key must sit to the playhead to absorb an auto-key.
const AUTOKEY_EPSILON := 0.0005

## Preview speed multipliers, and the index of the 1x entry.
const PREVIEW_SPEEDS := [0.25, 0.5, 1.0, 2.0]
const PREVIEW_SPEED_NAMES := ["0.25x", "0.5x", "1x", "2x"]
const PREVIEW_SPEED_DEFAULT := 2

## How long a status message stays up.
const STATUS_SECONDS := 4.0

## Interpolation labels, indexed by [enum MotionKey.Interp]. The three eases are
## named for the curve they are — cubic — so they no longer read as synonyms of
## the CSS-named bezier presets, which are a different thing entirely.
const INTERP_NAMES := ["Constant", "Linear", "Cubic In", "Cubic Out", "Cubic In-Out", "Bezier"]

var undo_redo: EditorUndoRedoManager

var _player: MotionPlayer
var _timeline: MotionTimeline
var _canvas: TimelineCanvas
var _curve: CurveCanvas
var _view: ViewState
var _clipboard: KeyClipboard

var _play_button: Button
var _stop_button: Button
var _key_button: Button
var _add_track_button: Button
var _delete_button: Button
var _snap_button: Button
var _loop_button: Button
var _region_button: Button
var _frames_button: Button
var _curve_button: Button
var _normalize_button: Button
var _save_button: Button
var _interp_picker: OptionButton
var _preset_picker: OptionButton
var _speed_picker: OptionButton
var _duration_spin: SpinBox
var _fps_spin: SpinBox
var _filter_edit: LineEdit
var _time_label: Label
## Readout of the selected key's value, which is otherwise invisible.
var _key_label: Label
var _title_label: Label
## Transient feedback line. Several actions used to succeed or decline in
## silence — Save on a built-in resource in particular did the right thing and
## looked broken.
var _status_label: Label
var _status_timer: Timer

var _add_dialog: AddTrackDialog
var _track_menu: PopupMenu
var _offset_dialog: ConfirmationDialog
var _offset_spin: SpinBox
var _marker_dialog: ConfirmationDialog
var _marker_edit: LineEdit
var _menu_track: MotionTrack = null
var _editing_marker: MotionMarker = null

var _previewing := false
## Baseline scene values for auto-key, keyed by track. Re-snapshotted whenever
## the value could legitimately change without the user having edited anything.
var _autokey_baseline: Dictionary = {}
var _suppress_autokey := false


func _ready() -> void:
	custom_minimum_size = Vector2(0, 300)
	_view = ViewState.new()
	_clipboard = KeyClipboard.new()
	_view.selection_changed.connect(_on_selection_changed)
	_view.view_changed.connect(_on_view_changed)
	_view.playhead_changed.connect(_on_playhead_moved)
	_build_toolbar()
	_build_views()
	_build_dialogs()

	_status_timer = Timer.new()
	_status_timer.one_shot = true
	_status_timer.wait_time = STATUS_SECONDS
	_status_timer.timeout.connect(func() -> void: _status_label.text = "")
	add_child(_status_timer)

	set_process(true)
	_refresh_controls()


## Shortcuts require the focus owner to sit inside the panel, and nothing in the
## toolbar takes focus. Without this the panel could be open, visible and
## focused-looking while every shortcut silently did nothing.
func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and is_visible_in_tree() and _canvas != null:
		var target: Control = _curve if _curve.visible else _canvas
		target.call_deferred("grab_focus")


## Shows a transient message in the toolbar.
func _status(message: String, error: bool = false) -> void:
	if _status_label == null:
		return
	_status_label.text = message
	_status_label.add_theme_color_override("font_color",
		Color("e06c75") if error else Color("8fd694"))
	_status_timer.start()


# -- construction -------------------------------------------------------------

func _build_toolbar() -> void:
	# HFlowContainer, not HBoxContainer. An HBox reports the *sum* of its
	# children as its minimum width, and a bottom panel's minimum width
	# propagates up to the editor's dock splitter — so two full toolbars of
	# buttons made the whole editor wider than the screen and pushed the
	# right-hand docks off the edge. A flow container's minimum is its widest
	# single child, so the toolbar wraps onto a second line instead.
	var bar := HFlowContainer.new()
	bar.add_theme_constant_override("h_separation", 4)
	add_child(bar)

	_make_button(bar, "|<", &"", "Go to start.").pressed.connect(_on_go_start)
	_make_button(bar, "", &"ArrowLeft", "Step back one frame.").pressed.connect(func() -> void: _step_frame(-1))
	_play_button = _make_button(bar, "Play", &"Play", "Preview the timeline in the editor viewport.")
	_play_button.pressed.connect(_on_play_pressed)
	_make_button(bar, "", &"ArrowRight", "Step forward one frame.").pressed.connect(func() -> void: _step_frame(1))
	_make_button(bar, ">|", &"", "Go to end.").pressed.connect(_on_go_end)
	_stop_button = _make_button(bar, "Stop", &"Stop", "Stop preview and rewind to 0.")
	_stop_button.pressed.connect(_on_stop_pressed)

	_loop_button = _make_button(bar, "", &"Loop", "Loop the editor preview.")
	_loop_button.toggle_mode = true

	_speed_picker = OptionButton.new()
	_speed_picker.tooltip_text = "Preview playback speed. Does not change the MotionPlayer's own speed_scale."
	_speed_picker.custom_minimum_size.x = 72
	for label in PREVIEW_SPEED_NAMES:
		_speed_picker.add_item(label)
	_speed_picker.select(PREVIEW_SPEED_DEFAULT)
	bar.add_child(_speed_picker)

	bar.add_child(VSeparator.new())

	_key_button = _make_button(bar, "Key", &"Key",
		"Key the playhead from each track's current scene value. Press again on an existing key to re-record it.")
	_key_button.pressed.connect(_on_key_pressed)
	_add_track_button = _make_button(bar, "Add Track", &"Add", "Add a track for a scene node.")
	_add_track_button.pressed.connect(_on_add_track_pressed)
	_delete_button = _make_button(bar, "", &"Remove", "Delete the selected keys.")
	_delete_button.pressed.connect(_on_delete_pressed)

	bar.add_child(VSeparator.new())

	_interp_picker = OptionButton.new()
	_interp_picker.tooltip_text = "Interpolation of the selected keys."
	_interp_picker.custom_minimum_size.x = 116
	# Named for the curve they actually are. They used to be "Ease In/Out",
	# which collided word-for-word with the CSS presets one dropdown along —
	# same words, different curves, no way to tell which you were getting.
	for name in INTERP_NAMES:
		_interp_picker.add_item(name)
	_interp_picker.item_selected.connect(_on_interp_selected)
	bar.add_child(_interp_picker)

	_preset_picker = OptionButton.new()
	_preset_picker.tooltip_text = "Apply an easing preset to the selected keys."
	_preset_picker.custom_minimum_size.x = 116
	_preset_picker.add_item("Preset…")
	for name in MotionEasing.preset_names():
		_preset_picker.add_item(name)
	_preset_picker.item_selected.connect(_on_preset_selected)
	bar.add_child(_preset_picker)

	bar.add_child(VSeparator.new())

	_snap_button = _make_button(bar, "Snap", &"SnapGrid", "Snap keys and the playhead to frames. Hold Ctrl to bypass.")
	_snap_button.toggle_mode = true
	_snap_button.button_pressed = true
	_snap_button.toggled.connect(func(on: bool) -> void: _view.snap_enabled = on)

	_make_button(bar, "Fit", &"Zoom", "Zoom so the whole duration is visible.") \
		.pressed.connect(func() -> void: _canvas.zoom_to_fit())
	_make_button(bar, "", &"ZoomMore", "Zoom to the selected keys.") \
		.pressed.connect(func() -> void: _canvas.zoom_to_selection())

	_curve_button = _make_button(bar, "Curves", &"EditBezier", "Switch between the dope sheet and the value graph.")
	_curve_button.toggle_mode = true
	_curve_button.toggled.connect(_on_curve_toggled)

	_normalize_button = _make_button(bar, "Norm", &"",
		"Scale each curve to its own value range, so a 0..1 track is readable next to a 0..600 one.")
	_normalize_button.toggle_mode = true
	_normalize_button.toggled.connect(func(on: bool) -> void: _curve.normalize = on)

	bar.add_child(VSeparator.new())

	_make_button(bar, "", &"Marker", "Add a marker at the playhead.").pressed.connect(_on_add_marker)
	_region_button = _make_button(bar, "Region", &"Loop", "Restrict playback to a loop region.")
	_region_button.toggle_mode = true
	_region_button.toggled.connect(_on_region_toggled)

	var bar2 := HFlowContainer.new()
	bar2.add_theme_constant_override("h_separation", 4)
	add_child(bar2)

	bar2.add_child(_make_label("Duration"))
	_duration_spin = SpinBox.new()
	_duration_spin.min_value = 0.1
	_duration_spin.max_value = 3600.0
	_duration_spin.step = 0.1
	_duration_spin.suffix = "s"
	_duration_spin.custom_minimum_size.x = 88
	_duration_spin.value_changed.connect(_on_duration_changed)
	bar2.add_child(_duration_spin)

	bar2.add_child(_make_label("FPS"))
	_fps_spin = SpinBox.new()
	_fps_spin.min_value = 1
	_fps_spin.max_value = 240
	_fps_spin.step = 1
	_fps_spin.custom_minimum_size.x = 64
	_fps_spin.value_changed.connect(_on_fps_changed)
	bar2.add_child(_fps_spin)

	_frames_button = _make_button(bar2, "Frames", &"Time", "Show the ruler in frames instead of seconds.")
	_frames_button.toggle_mode = true
	_frames_button.toggled.connect(func(on: bool) -> void: _canvas.show_frames = on)

	bar2.add_child(VSeparator.new())
	bar2.add_child(_make_label("Filter"))
	_filter_edit = LineEdit.new()
	_filter_edit.placeholder_text = "Track or property…"
	_filter_edit.custom_minimum_size.x = 160
	# Both views filter, or switching views silently changes what you are
	# looking at while the filter box still claims otherwise.
	_filter_edit.text_changed.connect(func(t: String) -> void:
		_canvas.filter_text = t
		_curve.filter_text = t)
	bar2.add_child(_filter_edit)

	_time_label = _make_readout(bar2, 108)

	bar2.add_child(VSeparator.new())
	_key_label = _make_readout(bar2, 300)
	_key_label.add_theme_color_override("font_color", Color("ffd166"))
	_key_label.tooltip_text = "The selected key: property, value, time and interpolation. '● REC' means it sits at the playhead and will absorb viewport moves."

	bar2.add_child(VSeparator.new())
	_status_label = _make_readout(bar2, 0)
	_status_label.add_theme_color_override("font_color", Color("8fd694"))

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar2.add_child(spacer)

	_title_label = _make_readout(bar2, 0)
	_title_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))

	_save_button = _make_button(bar2, "Save", &"Save", "Write the timeline resource to disk.")
	_save_button.pressed.connect(_on_save_pressed)


func _make_button(parent: Node, text: String, icon_name: StringName, tooltip: String) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tooltip
	button.focus_mode = Control.FOCUS_NONE
	var icon := GodotionTheme.icon(icon_name) if icon_name != &"" else null
	if icon != null:
		button.icon = icon
	elif button.text.is_empty():
		# Never leave a button with neither text nor icon — it would be invisible.
		button.text = tooltip.get_slice(" ", 0)
	parent.add_child(button)
	return button


func _make_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	return label


## A toolbar readout whose text length cannot widen the panel.
##
## A plain [Label] reports its full untruncated text as its minimum width, an
## [HBoxContainer] sums its children's minimums, and a bottom panel's minimum
## width propagates all the way up to the editor's dock splitter. So a timeline
## with a long name and a long resource path — `_title_label` shows both —
## silently forced the whole editor wider than the screen and pushed the
## right-hand docks off the edge. Trimming with an ellipsis drops the minimum to
## whatever is asked for here instead.
func _make_readout(parent: Control, min_width: int) -> Label:
	var label := Label.new()
	label.custom_minimum_size.x = min_width
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	parent.add_child(label)
	return label


func _build_views() -> void:
	_canvas = TimelineCanvas.new()
	_canvas.view = _view
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_canvas)

	_canvas.keys_dragged.connect(_on_keys_dragged)
	_canvas.track_enable_toggled.connect(_on_track_enable_toggled)
	_canvas.track_solo_toggled.connect(_on_track_solo_toggled)
	_canvas.track_lock_toggled.connect(_on_track_lock_toggled)
	_canvas.tracks_reordered.connect(_on_tracks_reordered)
	_canvas.delete_requested.connect(_on_delete_pressed)
	_canvas.key_double_clicked.connect(_on_key_double_clicked)
	_canvas.track_context_requested.connect(_on_track_context)
	_canvas.marker_moved.connect(_on_marker_moved)
	_canvas.marker_double_clicked.connect(_on_marker_double_clicked)
	_canvas.loop_region_changed.connect(_on_loop_region_changed)

	_curve = CurveCanvas.new()
	_curve.view = _view
	_curve.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_curve.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_curve.visible = false
	add_child(_curve)

	_curve.handles_dragged.connect(_on_handles_dragged)
	_curve.keys_dragged.connect(_on_keys_dragged)
	_curve.keys_revalued.connect(_on_keys_revalued)
	_curve.delete_requested.connect(_on_delete_pressed)


func _build_dialogs() -> void:
	_add_dialog = AddTrackDialog.new()
	_add_dialog.tracks_requested.connect(_on_tracks_requested)
	add_child(_add_dialog)

	_track_menu = PopupMenu.new()
	_build_track_menu(false)
	_track_menu.id_pressed.connect(_on_track_menu)
	add_child(_track_menu)

	_offset_dialog = ConfirmationDialog.new()
	_offset_dialog.title = "Track Time Offset"
	var obox := VBoxContainer.new()
	var olabel := Label.new()
	olabel.text = "Shifts this track in time without moving its keys."
	olabel.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	obox.add_child(olabel)
	_offset_spin = SpinBox.new()
	_offset_spin.min_value = -3600.0
	_offset_spin.max_value = 3600.0
	_offset_spin.step = 0.01
	_offset_spin.suffix = "s"
	obox.add_child(_offset_spin)
	_offset_dialog.add_child(obox)
	_offset_dialog.confirmed.connect(_on_offset_confirmed)
	add_child(_offset_dialog)

	_marker_dialog = ConfirmationDialog.new()
	_marker_dialog.title = "Rename Marker"
	_marker_edit = LineEdit.new()
	_marker_edit.custom_minimum_size.x = 240
	_marker_dialog.add_child(_marker_edit)
	_marker_dialog.confirmed.connect(_on_marker_renamed)
	add_child(_marker_dialog)


# -- external API -------------------------------------------------------------

func edit_player(player: MotionPlayer) -> void:
	# Stop the preview before swapping. Otherwise the outgoing player keeps its
	# triggers armed forever — nothing else would ever disarm it — and scrubbing
	# a different timeline would fire cues on a node the panel no longer shows.
	if _previewing:
		_set_previewing(false)
	_player = player
	set_timeline(player.timeline if player != null else null)
	_bind_root()
	_refresh_controls()


## Binds a timeline selected directly (e.g. the sub-resource in the inspector).
## Keeps the current player if the timeline belongs to it, so the panel does not
## lose the root it needs to add tracks and read values.
func edit_timeline(timeline: MotionTimeline) -> void:
	if _player == null or not is_instance_valid(_player) or _player.timeline != timeline:
		_player = null
	set_timeline(timeline)
	_bind_root()
	_refresh_controls()


func set_timeline(timeline: MotionTimeline) -> void:
	if _timeline == timeline:
		return
	_timeline = timeline
	_canvas.timeline = timeline
	_curve.timeline = timeline
	_view.clear()
	_autokey_baseline.clear()
	_bind_root()
	if timeline != null:
		_duration_spin.set_value_no_signal(timeline.duration)
		_fps_spin.set_value_no_signal(timeline.fps)
		_region_button.set_pressed_no_signal(timeline.loop_region_enabled)
		_canvas.zoom_to_fit()
	_refresh_controls()


func get_timeline() -> MotionTimeline:
	return _timeline


## Shortcut entry points, called by [code]plugin.gd[/code].
func key_at_playhead() -> void:
	_on_key_pressed()


func toggle_preview() -> void:
	if not _play_button.disabled:
		_on_play_pressed()


func _bind_root() -> void:
	_canvas.root_node = _resolve_root()


## The node that track paths are relative to. Falls back to the edited scene
## root when no player is bound, so a timeline opened on its own is editable.
func _resolve_root() -> Node:
	if _player == null or not is_instance_valid(_player):
		return EditorInterface.get_edited_scene_root()
	if _player.root_node.is_empty():
		return _player
	var root := _player.get_node_or_null(_player.root_node)
	return root if root != null else EditorInterface.get_edited_scene_root()


func _refresh_controls() -> void:
	var has_timeline := _timeline != null
	var has_selection := has_timeline and not _view.is_empty()
	_play_button.disabled = not has_timeline or _player == null
	_stop_button.disabled = _play_button.disabled
	_key_button.disabled = not has_timeline or _timeline.get_valid_tracks().is_empty()
	_add_track_button.disabled = not has_timeline
	_delete_button.disabled = not has_selection
	_interp_picker.disabled = not has_selection
	_preset_picker.disabled = not has_selection
	_duration_spin.editable = has_timeline
	_fps_spin.editable = has_timeline
	_save_button.disabled = not has_timeline
	_normalize_button.disabled = not _curve.visible
	_play_button.text = "Pause" if _previewing else "Play"

	if has_selection:
		var key := _view.lone_key()
		if key != null:
			_interp_picker.select(key.interp)
	_update_time_label()

	if has_timeline:
		var path := _timeline.resource_path
		_title_label.text = "%s  ·  %s" % [_timeline.timeline_name, path if path != "" else "(built-in)"]
	else:
		_title_label.text = ""


func _update_time_label() -> void:
	if _timeline == null:
		_time_label.text = ""
		_key_label.text = ""
		return
	var frame := roundi(_view.playhead * float(_timeline.fps))
	_time_label.text = "%.3fs · f%d" % [_view.playhead, frame]
	_key_label.text = _describe_selection()


## Plain-language readout of what is selected. Key values are otherwise only
## visible by hunting through the inspector, which is the first thing users ask
## for: "where are the keyframe values?"
func _describe_selection() -> String:
	var selection := _view.get_selection()
	if selection.is_empty():
		return "no key selected"
	if selection.size() > 1:
		return "%d keys selected" % selection.size()
	var track: MotionTrack = selection[0]["track"]
	var key: MotionKey = selection[0]["key"]
	var armed := absf(key.time + track.time_offset - _timeline.snap_to_frame(_view.playhead)) <= AUTOKEY_EPSILON
	return "%s = %s  @ %.3fs  %s%s" % [
		track.property, _format_value(key.value), key.time + track.time_offset,
		_interp_name(key.interp), "  ● REC" if armed else ""]


static func _format_value(value: Variant) -> String:
	match typeof(value):
		TYPE_FLOAT:
			return "%.3f" % value
		TYPE_VECTOR2:
			return "(%.2f, %.2f)" % [value.x, value.y]
		TYPE_VECTOR3:
			return "(%.2f, %.2f, %.2f)" % [value.x, value.y, value.z]
		TYPE_COLOR:
			return "#%s" % (value as Color).to_html(false)
	return str(value)


static func _interp_name(interp: int) -> String:
	if interp < 0 or interp >= INTERP_NAMES.size():
		return "?"
	return INTERP_NAMES[interp]


# -- selection ----------------------------------------------------------------

func _on_selection_changed() -> void:
	_snapshot_autokey()
	_refresh_controls()
	_canvas.queue_redraw()
	_curve.queue_redraw()
	# Push the lone selected key into Godot's own inspector so every value type
	# gets its native editor without us reimplementing one.
	var key := _view.lone_key()
	if key != null:
		EditorInterface.edit_resource(key)


func _on_view_changed() -> void:
	_canvas.queue_redraw()
	_curve.queue_redraw()


func _on_curve_toggled(on: bool) -> void:
	_canvas.visible = not on
	_curve.visible = on
	_curve.queue_redraw()
	_refresh_controls()
	# Focus follows the visible view, so Delete and the shortcuts keep working
	# across the toggle.
	(_curve if on else _canvas).call_deferred("grab_focus")


# -- editor preview -----------------------------------------------------------

func _process(delta: float) -> void:
	if _previewing and _timeline != null:
		_advance_preview(delta)
	_capture_autokey()


func _advance_preview(delta: float) -> void:
	var range_ := _timeline.get_play_range()
	var t: float = _view.playhead + delta * _preview_speed()
	if not _loop_button.button_pressed and _timeline.is_finished(t):
		_view.playhead = range_.y
		_apply_preview()
		_set_previewing(false)
		return
	_view.playhead = _timeline.wrap_time(t) if _loop_button.button_pressed else minf(t, range_.y)
	_apply_preview()


## Editor-preview speed only. The player's own [member MotionPlayer.speed_scale]
## is left alone: it is scene data, and scrubbing must not rewrite it.
func _preview_speed() -> float:
	if _speed_picker == null:
		return 1.0
	var index := clampi(_speed_picker.selected, 0, PREVIEW_SPEEDS.size() - 1)
	return PREVIEW_SPEEDS[index]


func _set_previewing(on: bool) -> void:
	_previewing = on
	# Arm the player's trigger tracks for the duration of the preview. Without
	# this a timeline's sound cues are audible only in a running game, and
	# pressing Play in the panel looks exactly like broken audio.
	if _player != null and is_instance_valid(_player):
		_player.set_editor_triggers_armed(on, _view.playhead)
	_refresh_controls()


func _apply_preview() -> void:
	if _player == null or not is_instance_valid(_player):
		return
	# Preview writes node <- key. Auto-key writes key <- node. Suppress capture
	# across the write and re-snapshot after, or every scrub would look like a
	# user edit and silently overwrite the selected key.
	_suppress_autokey = true
	_player.apply_at(_view.playhead)
	_suppress_autokey = false
	_snapshot_autokey()


func _on_play_pressed() -> void:
	_set_previewing(not _previewing)


func _on_stop_pressed() -> void:
	_set_previewing(false)
	_view.playhead = 0.0
	_apply_preview()


func _on_go_start() -> void:
	_view.playhead = _timeline.get_play_range().x if _timeline != null else 0.0
	_apply_preview()


func _on_go_end() -> void:
	if _timeline == null:
		return
	_view.playhead = _timeline.get_play_range().y
	_apply_preview()


func _step_frame(direction: int) -> void:
	if _timeline == null:
		return
	var step := 1.0 / float(_timeline.fps)
	_view.playhead = clampf(_view.playhead + step * direction, 0.0, _timeline.duration)
	_apply_preview()


func _on_playhead_moved(_time: float) -> void:
	_apply_preview()
	_update_time_label()
	_canvas.queue_redraw()
	_curve.queue_redraw()


# -- auto-key -----------------------------------------------------------------

## Records the current scene value of every selected key's track, so later
## comparisons measure user edits rather than preview writes.
func _snapshot_autokey() -> void:
	_autokey_baseline.clear()
	if _timeline == null:
		return
	var root := _resolve_root()
	if root == null:
		return
	for track in _view.selected_tracks():
		var value: Variant = _read_track_value(root, track)
		if value != null:
			_autokey_baseline[track] = value


func _read_track_value(root: Node, track: MotionTrack) -> Variant:
	if track.property.is_empty():
		return null
	# A trigger names a method. There is no pose to read, so every value-reading
	# path — the Key button, the auto-key baseline, the toolbar readout — has to
	# treat it as "no opinion" rather than reading a property that isn't there.
	if track.is_trigger():
		return null
	var node: Node = root if track.node_path.is_empty() else root.get_node_or_null(track.node_path)
	if node == null:
		return null
	return node.get_indexed(NodePath(track.property))


## Always-on auto-key: while keys are selected, a change to the tracked property
## that did not come from the preview is written onto those keys.
func _capture_autokey() -> void:
	if _suppress_autokey or _timeline == null or _view.is_empty() or undo_redo == null:
		return
	var root := _resolve_root()
	if root == null:
		return

	# Auto-key records AT THE PLAYHEAD, as every other editor does. A selected
	# key somewhere else in time must never absorb a pose from a different
	# moment: clicking a key to inspect it would otherwise arm it, and the next
	# move you made anywhere on the timeline would silently overwrite it —
	# flattening the very animation you were building.
	var time: float = _timeline.snap_to_frame(_view.playhead)
	var keys: Array = []
	var olds: Array = []
	var news: Array = []
	for entry in _view.get_selection():
		var track: MotionTrack = entry["track"]
		if track.locked or not _autokey_baseline.has(track):
			continue
		var key: MotionKey = entry["key"]
		if absf(key.time + track.time_offset - time) > AUTOKEY_EPSILON:
			continue
		var current: Variant = _read_track_value(root, track)
		if current == null:
			continue
		var baseline: Variant = _autokey_baseline[track]
		if typeof(current) == typeof(baseline) and current == baseline:
			continue
		if typeof(key.value) == typeof(current) and key.value == current:
			continue
		keys.append(key)
		olds.append(key.value)
		news.append(current)

	if keys.is_empty():
		return
	# MERGE_ENDS collapses a continuous viewport drag into one undo step rather
	# than one per frame.
	undo_redo.create_action("Godotion: Auto-Key", UndoRedo.MERGE_ENDS)
	for i in range(keys.size()):
		undo_redo.add_do_property(keys[i], "value", news[i])
		undo_redo.add_undo_property(keys[i], "value", olds[i])
	undo_redo.commit_action()
	_snapshot_autokey()
	_canvas.queue_redraw()
	_curve.queue_redraw()


# -- mutations (all undoable) -------------------------------------------------

func _on_duration_changed(value: float) -> void:
	if _timeline == null or is_equal_approx(_timeline.duration, value):
		return
	undo_redo.create_action("Godotion: Set Duration")
	undo_redo.add_do_property(_timeline, "duration", value)
	undo_redo.add_undo_property(_timeline, "duration", _timeline.duration)
	undo_redo.commit_action()
	_canvas.queue_redraw()


func _on_fps_changed(value: float) -> void:
	if _timeline == null or _timeline.fps == int(value):
		return
	undo_redo.create_action("Godotion: Set FPS")
	undo_redo.add_do_property(_timeline, "fps", int(value))
	undo_redo.add_undo_property(_timeline, "fps", _timeline.fps)
	undo_redo.commit_action()
	_canvas.queue_redraw()


func _on_track_enable_toggled(track: MotionTrack, enabled: bool) -> void:
	_toggle_track_flag(track, "enabled", enabled, "Godotion: Toggle Track")


func _on_track_solo_toggled(track: MotionTrack, solo: bool) -> void:
	_toggle_track_flag(track, "solo", solo, "Godotion: Solo Track")


func _on_track_lock_toggled(track: MotionTrack, locked: bool) -> void:
	_toggle_track_flag(track, "locked", locked, "Godotion: Lock Track")


func _toggle_track_flag(track: MotionTrack, property: String, value: bool, action: String) -> void:
	undo_redo.create_action(action)
	undo_redo.add_do_property(track, property, value)
	undo_redo.add_undo_property(track, property, not value)
	undo_redo.commit_action()
	_canvas.queue_redraw()


func _on_keys_dragged(tracks: Array, keys: Array, old_times: Array, new_times: Array) -> void:
	# The canvas already moved the keys live; register the inverse first so the
	# action is symmetrical, then re-apply on redo.
	undo_redo.create_action("Godotion: Move Keys")
	for i in range(keys.size()):
		undo_redo.add_do_property(keys[i], "time", new_times[i])
		undo_redo.add_undo_property(keys[i], "time", old_times[i])
	for track in tracks:
		undo_redo.add_do_method(track, "sort_keys")
		undo_redo.add_undo_method(track, "sort_keys")
	undo_redo.commit_action(false)
	# What the playhead samples just changed; show it rather than waiting for
	# the next scrub.
	_apply_preview()
	_canvas.queue_redraw()
	_curve.queue_redraw()


## Vertical drags in the curve view. The canvas already moved the value live, so
## the action is registered symmetrically with the do side already applied.
func _on_keys_revalued(keys: Array, olds: Array, news: Array) -> void:
	undo_redo.create_action("Godotion: Edit Key Value")
	for i in range(keys.size()):
		undo_redo.add_do_property(keys[i], "value", news[i])
		undo_redo.add_undo_property(keys[i], "value", olds[i])
	undo_redo.commit_action(false)
	_apply_preview()
	_canvas.queue_redraw()
	_curve.queue_redraw()


func _on_handles_dragged(keys: Array, olds: Array, news: Array, incoming: bool) -> void:
	var property := "in_handle" if incoming else "out_handle"
	undo_redo.create_action("Godotion: Edit Handle")
	for i in range(keys.size()):
		undo_redo.add_do_property(keys[i], property, news[i])
		undo_redo.add_undo_property(keys[i], property, olds[i])
	undo_redo.commit_action(false)
	_curve.queue_redraw()


func _on_key_pressed() -> void:
	if _timeline == null:
		return
	var root := _resolve_root()
	if root == null:
		push_warning("Godotion: cannot key — no scene root resolved.")
		return
	var time: float = _timeline.snap_to_frame(_view.playhead)
	var created: Array[MotionKey] = []
	var owners: Array[MotionTrack] = []
	# Re-keying an existing time records the current pose onto that key, rather
	# than silently doing nothing on the second press.
	var updated: Array[MotionKey] = []
	var old_values: Array = []
	var new_values: Array = []

	var selected := _view.selected_tracks()
	for track in _timeline.get_valid_tracks():
		if not track.enabled or track.locked or track.property.is_empty():
			continue
		if track.is_trigger():
			# A cue has no pose to read, so "key every track" cannot apply — one
			# press would otherwise drop a simultaneous cue on every trigger
			# track in the timeline. Only selected trigger rows receive one.
			if not selected.has(track):
				continue
			var cue_time := time - track.time_offset
			if track.find_key_at(cue_time) != null:
				continue
			var cue := MotionKey.new()
			cue.time = maxf(0.0, cue_time)
			cue.interp = MotionKey.Interp.CONSTANT
			created.append(cue)
			owners.append(track)
			continue
		var value: Variant = _read_track_value(root, track)
		if value == null:
			continue
		# Keys live in track-local time, so undo the offset before comparing.
		var local_time := time - track.time_offset
		var existing := track.find_key_at(local_time)
		if existing != null:
			if typeof(existing.value) == typeof(value) and existing.value == value:
				continue
			updated.append(existing)
			old_values.append(existing.value)
			new_values.append(value)
			continue
		var key := MotionKey.new()
		key.time = maxf(0.0, local_time)
		key.value = value
		created.append(key)
		owners.append(track)

	if created.is_empty() and updated.is_empty():
		return
	undo_redo.create_action("Godotion: Insert Keys" if updated.is_empty() else "Godotion: Key Pose")
	for i in range(created.size()):
		undo_redo.add_do_method(owners[i], "add_key", created[i])
		undo_redo.add_undo_method(owners[i], "remove_key", created[i])
	for i in range(updated.size()):
		undo_redo.add_do_property(updated[i], "value", new_values[i])
		undo_redo.add_undo_property(updated[i], "value", old_values[i])
	undo_redo.commit_action()
	_snapshot_autokey()
	_canvas.queue_redraw()
	_curve.queue_redraw()


func _on_delete_pressed() -> void:
	var selection := _view.get_selection()
	if selection.is_empty():
		return
	undo_redo.create_action("Godotion: Delete Keys")
	for entry in selection:
		var track: MotionTrack = entry["track"]
		if track.locked:
			continue
		undo_redo.add_do_method(track, "remove_key", entry["key"])
		undo_redo.add_undo_method(track, "add_key", entry["key"])
	undo_redo.commit_action()
	_view.clear()
	_canvas.queue_redraw()
	_curve.queue_redraw()


func _on_key_double_clicked(_track: MotionTrack, key: MotionKey) -> void:
	# Cycle interpolation. The toolbar dropdown is the discoverable path; this
	# stays as a shortcut for users who know it.
	var next: int = (key.interp + 1) % MotionKey.Interp.size()
	undo_redo.create_action("Godotion: Change Interpolation")
	undo_redo.add_do_property(key, "interp", next)
	undo_redo.add_undo_property(key, "interp", key.interp)
	undo_redo.commit_action()
	_refresh_controls()
	_canvas.queue_redraw()


func _on_interp_selected(index: int) -> void:
	var selection := _view.get_selection()
	if selection.is_empty():
		return
	undo_redo.create_action("Godotion: Set Interpolation")
	for entry in selection:
		if (entry["track"] as MotionTrack).locked:
			continue
		var key: MotionKey = entry["key"]
		undo_redo.add_do_property(key, "interp", index)
		undo_redo.add_undo_property(key, "interp", key.interp)
	undo_redo.commit_action()
	_canvas.queue_redraw()
	_curve.queue_redraw()


## Applies a preset to each selected key: switches it to BEZIER and sets its
## outgoing handle plus the next key's incoming handle, which is the pair that
## shapes the segment between them.
func _on_preset_selected(index: int) -> void:
	if index <= 0:
		return
	var name := _preset_picker.get_item_text(index)
	var handles := MotionEasing.preset(name)
	_preset_picker.select(0)
	if handles.size() != 2:
		return
	var selection := _view.get_selection()
	if selection.is_empty():
		return

	undo_redo.create_action("Godotion: Apply '%s'" % name)
	for entry in selection:
		var track: MotionTrack = entry["track"]
		if track.locked:
			continue
		var key: MotionKey = entry["key"]
		var keys := track.get_valid_keys()
		var idx := keys.find(key)
		if idx < 0 or idx == keys.size() - 1:
			continue
		undo_redo.add_do_property(key, "interp", MotionKey.Interp.BEZIER)
		undo_redo.add_undo_property(key, "interp", key.interp)
		undo_redo.add_do_property(key, "out_handle", handles[0])
		undo_redo.add_undo_property(key, "out_handle", key.out_handle)
		var next: MotionKey = keys[idx + 1]
		undo_redo.add_do_property(next, "in_handle", handles[1])
		undo_redo.add_undo_property(next, "in_handle", next.in_handle)
	undo_redo.commit_action()
	_refresh_controls()
	_canvas.queue_redraw()
	_curve.queue_redraw()


# -- clipboard and selection commands -----------------------------------------

func copy_keys() -> void:
	_clipboard.copy(_view.get_selection())


func cut_keys() -> void:
	copy_keys()
	_on_delete_pressed()


func paste_keys() -> void:
	if _timeline == null or _clipboard.is_empty():
		return
	var pasted := _clipboard.build_paste(_timeline, _timeline.snap_to_frame(_view.playhead))
	if pasted.is_empty():
		return
	undo_redo.create_action("Godotion: Paste Keys")
	for entry in pasted:
		undo_redo.add_do_method(entry["track"], "add_key", entry["key"])
		undo_redo.add_undo_method(entry["track"], "remove_key", entry["key"])
	undo_redo.commit_action()
	var entries: Array[Dictionary] = []
	for entry in pasted:
		entries.append(entry)
	_view.set_entries(entries)
	_canvas.queue_redraw()
	_curve.queue_redraw()


## Duplicates the selection in place, offset by one frame so the copies are
## grabbable rather than hidden underneath the originals.
func duplicate_keys() -> void:
	var selection := _view.get_selection()
	if selection.is_empty() or _timeline == null:
		return
	var step := 1.0 / float(_timeline.fps)
	var made: Array[Dictionary] = []
	for entry in selection:
		var track: MotionTrack = entry["track"]
		if track.locked:
			continue
		var copy := (entry["key"] as MotionKey).duplicate_key()
		copy.time = maxf(0.0, copy.time + step)
		made.append({"track": track, "key": copy})
	if made.is_empty():
		return
	undo_redo.create_action("Godotion: Duplicate Keys")
	for entry in made:
		undo_redo.add_do_method(entry["track"], "add_key", entry["key"])
		undo_redo.add_undo_method(entry["track"], "remove_key", entry["key"])
	undo_redo.commit_action()
	_view.set_entries(made)
	_canvas.queue_redraw()


func select_all_keys() -> void:
	if _timeline == null:
		return
	var entries: Array[Dictionary] = []
	for track in _timeline.get_valid_tracks():
		for key in track.get_valid_keys():
			entries.append({"track": track, "key": key})
	_view.set_entries(entries)


func invert_selection() -> void:
	if _timeline == null:
		return
	var entries: Array[Dictionary] = []
	for track in _timeline.get_valid_tracks():
		for key in track.get_valid_keys():
			if not _view.is_selected(key):
				entries.append({"track": track, "key": key})
	_view.set_entries(entries)


# -- markers and region -------------------------------------------------------

func _on_add_marker() -> void:
	if _timeline == null:
		return
	var time: float = _timeline.snap_to_frame(_view.playhead)
	if _timeline.get_marker_at(time) != null:
		return
	var marker := MotionMarker.new()
	marker.time = time
	marker.name = "Marker %d" % (_timeline.get_valid_markers().size() + 1)
	undo_redo.create_action("Godotion: Add Marker")
	undo_redo.add_do_method(_timeline, "add_marker", marker)
	undo_redo.add_undo_method(_timeline, "remove_marker", marker)
	undo_redo.commit_action()
	_canvas.queue_redraw()


func _on_marker_moved(marker: MotionMarker, old_time: float, new_time: float) -> void:
	undo_redo.create_action("Godotion: Move Marker")
	undo_redo.add_do_property(marker, "time", new_time)
	undo_redo.add_undo_property(marker, "time", old_time)
	undo_redo.add_do_method(_timeline, "sort_markers")
	undo_redo.add_undo_method(_timeline, "sort_markers")
	undo_redo.commit_action(false)
	_canvas.queue_redraw()


func _on_marker_double_clicked(marker: MotionMarker) -> void:
	_editing_marker = marker
	_marker_edit.text = marker.name
	_marker_dialog.popup_centered(Vector2i(320, 120))
	_marker_edit.grab_focus()
	_marker_edit.select_all()


func _on_marker_renamed() -> void:
	if _editing_marker == null:
		return
	undo_redo.create_action("Godotion: Rename Marker")
	undo_redo.add_do_property(_editing_marker, "name", _marker_edit.text)
	undo_redo.add_undo_property(_editing_marker, "name", _editing_marker.name)
	undo_redo.commit_action()
	_editing_marker = null
	_canvas.queue_redraw()


func _on_region_toggled(on: bool) -> void:
	if _timeline == null:
		return
	undo_redo.create_action("Godotion: Toggle Loop Region")
	undo_redo.add_do_property(_timeline, "loop_region_enabled", on)
	undo_redo.add_undo_property(_timeline, "loop_region_enabled", _timeline.loop_region_enabled)
	# A never-configured region would be zero-length and invisible; seed it to
	# the middle half of the timeline so there is something to drag.
	if on and _timeline.loop_region_end <= _timeline.loop_region_start:
		undo_redo.add_do_property(_timeline, "loop_region_start", _timeline.duration * 0.25)
		undo_redo.add_undo_property(_timeline, "loop_region_start", _timeline.loop_region_start)
		undo_redo.add_do_property(_timeline, "loop_region_end", _timeline.duration * 0.75)
		undo_redo.add_undo_property(_timeline, "loop_region_end", _timeline.loop_region_end)
	undo_redo.commit_action()
	_canvas.queue_redraw()


func _on_loop_region_changed(start: float, end: float) -> void:
	undo_redo.create_action("Godotion: Set Loop Region")
	undo_redo.add_do_property(_timeline, "loop_region_start", start)
	undo_redo.add_undo_property(_timeline, "loop_region_start", _timeline.loop_region_start)
	undo_redo.add_do_property(_timeline, "loop_region_end", end)
	undo_redo.add_undo_property(_timeline, "loop_region_end", _timeline.loop_region_end)
	undo_redo.commit_action(false)
	_canvas.queue_redraw()


# -- track context menu -------------------------------------------------------

# PopupMenu can neither hide nor reorder an item, so the menu is rebuilt each
# time it opens. `with_cue` gates the trigger-only first entry, which exists
# because the Key button cannot reach an empty trigger track: Key acts on the
# selection, selection is made of keys, and a track with no keys has none to
# select — a closed loop with no exit, which is exactly the shape of the
# re-keying bug this panel already had once.
func _build_track_menu(with_cue: bool) -> void:
	_track_menu.clear()
	if with_cue:
		_track_menu.add_item("Add Cue at Playhead", TrackMenu.ADD_CUE)
	_track_menu.add_item("Select Keys", TrackMenu.SELECT_KEYS)
	_track_menu.add_item("Set Time Offset…", TrackMenu.OFFSET)
	_track_menu.add_separator()
	_track_menu.add_item("Duplicate Track", TrackMenu.DUPLICATE)
	_track_menu.add_item("Clear Keys", TrackMenu.CLEAR_KEYS)
	_track_menu.add_item("Delete Track", TrackMenu.DELETE)


func _on_track_context(track: MotionTrack, at: Vector2) -> void:
	_menu_track = track
	_build_track_menu(track.is_trigger())
	_track_menu.position = Vector2i(_canvas.get_screen_position() + at)
	_track_menu.reset_size()
	_track_menu.popup()


func _on_track_menu(id: int) -> void:
	if _menu_track == null or _timeline == null:
		return
	match id:
		TrackMenu.ADD_CUE:
			_add_cue(_menu_track)
		TrackMenu.SELECT_KEYS:
			var entries: Array[Dictionary] = []
			for key in _menu_track.get_valid_keys():
				entries.append({"track": _menu_track, "key": key})
			_view.set_entries(entries)
		TrackMenu.OFFSET:
			_offset_spin.set_value_no_signal(_menu_track.time_offset)
			_offset_dialog.popup_centered(Vector2i(320, 140))
		TrackMenu.DUPLICATE:
			var copy := _menu_track.duplicate_track()
			undo_redo.create_action("Godotion: Duplicate Track")
			undo_redo.add_do_method(_timeline, "add_track", copy)
			undo_redo.add_undo_method(_timeline, "remove_track", copy)
			undo_redo.commit_action()
		TrackMenu.CLEAR_KEYS:
			var keys := _menu_track.get_valid_keys().duplicate()
			if keys.is_empty():
				return
			undo_redo.create_action("Godotion: Clear Keys")
			for key in keys:
				undo_redo.add_do_method(_menu_track, "remove_key", key)
				undo_redo.add_undo_method(_menu_track, "add_key", key)
			undo_redo.commit_action()
			_view.prune()
		TrackMenu.DELETE:
			undo_redo.create_action("Godotion: Delete Track")
			undo_redo.add_do_method(_timeline, "remove_track", _menu_track)
			undo_redo.add_undo_method(_timeline, "add_track", _menu_track)
			undo_redo.commit_action()
			_view.prune()
	_refresh_controls()
	_canvas.queue_redraw()


## Drops a cue on [param track] at the snapped playhead, undoably. Shared by the
## context menu and by the Key button's trigger branch so the two cannot drift.
func _add_cue(track: MotionTrack) -> bool:
	if track == null or _timeline == null or not track.is_trigger():
		return false
	if track.locked:
		_status("'%s' is locked." % track.get_display_name(), true)
		return false
	var time: float = _timeline.snap_to_frame(_view.playhead) - track.time_offset
	if track.find_key_at(time) != null:
		_status("There is already a cue at that time.", true)
		return false
	var cue := MotionKey.new()
	cue.time = maxf(0.0, time)
	# Nothing is interpolated out of a cue, and CONSTANT is the interpolation
	# that says so — it also keeps the dope sheet's glyph honest if the track is
	# ever switched back to PROPERTY mode.
	cue.interp = MotionKey.Interp.CONSTANT
	undo_redo.create_action("Godotion: Add Cue")
	undo_redo.add_do_method(track, "add_key", cue)
	undo_redo.add_undo_method(track, "remove_key", cue)
	undo_redo.commit_action()
	return true


func _on_offset_confirmed() -> void:
	if _menu_track == null:
		return
	undo_redo.create_action("Godotion: Set Time Offset")
	undo_redo.add_do_property(_menu_track, "time_offset", _offset_spin.value)
	undo_redo.add_undo_property(_menu_track, "time_offset", _menu_track.time_offset)
	undo_redo.commit_action()
	_canvas.queue_redraw()


## The canvas names the track to drop in front of, never a row number: rows are
## the filtered, null-free view, while [method MotionTimeline.move_track] splices
## the raw array. Mixing the two reordered to the wrong slot whenever a filter
## was set or the array had a hole in it.
func _on_tracks_reordered(track: MotionTrack, before: MotionTrack) -> void:
	if _timeline == null:
		return
	var from_index := _timeline.tracks.find(track)
	var to_index := _timeline.resolve_move_target(track, before)
	if from_index < 0 or to_index < 0:
		return
	undo_redo.create_action("Godotion: Reorder Tracks")
	undo_redo.add_do_method(_timeline, "move_track", from_index, to_index)
	undo_redo.add_undo_method(_timeline, "move_track", to_index, from_index)
	undo_redo.commit_action()
	_canvas.queue_redraw()


# -- add track flow -----------------------------------------------------------

func _on_add_track_pressed() -> void:
	if _timeline == null:
		return
	var root := _resolve_root()
	if root == null:
		push_warning("Godotion: no scene root to add tracks against. Open a scene, or set a valid root_node on the MotionPlayer.")
		return
	var preselected: Array[Node] = []
	for node in EditorInterface.get_selection().get_selected_nodes():
		if node != _player and (node == root or root.is_ancestor_of(node)):
			preselected.append(node)
	_add_dialog.open(root, _player, preselected)


func _on_tracks_requested(nodes: Array, property: String, mode: int) -> void:
	var root := _resolve_root()
	if root == null or _timeline == null:
		return
	var trigger := mode == MotionTrack.Mode.TRIGGER
	var new_tracks: Array[MotionTrack] = []
	var skipped := PackedStringArray()
	for node in nodes:
		# With a multi-node selection the list comes from the first node, so the
		# others may not have it. A trigger names a method, not a property, so
		# the two modes need different existence checks.
		var present := (node as Node).has_method(property) if trigger \
			else (node as Node).get_indexed(NodePath(property)) != null
		if not present:
			skipped.append((node as Node).name)
			continue
		var path := root.get_path_to(node)
		if _timeline.find_track(path, property) != null:
			continue
		var track := MotionTrack.new()
		track.mode = mode as MotionTrack.Mode
		track.node_path = path
		track.property = property
		new_tracks.append(track)

	if not skipped.is_empty():
		# A push_warning goes to the Output dock, which most users never have
		# open — say it where they are looking.
		var noun := "method" if trigger else "property"
		push_warning("Godotion: skipped %s — no '%s' %s." % [", ".join(skipped), property, noun])
		_status("Skipped %s — no '%s' %s." % [", ".join(skipped), property, noun], true)
	if new_tracks.is_empty():
		return
	undo_redo.create_action("Godotion: Add Track")
	for track in new_tracks:
		undo_redo.add_do_method(_timeline, "add_track", track)
		undo_redo.add_undo_method(_timeline, "remove_track", track)
	undo_redo.commit_action()
	_refresh_controls()
	_canvas.queue_redraw()


# -- saving -------------------------------------------------------------------

func _on_save_pressed() -> void:
	if _timeline == null:
		return
	# A built-in sub-resource is not path-less: it carries the owning scene's
	# path with a "::id" suffix, which ResourceSaver cannot write to. It has to
	# be saved by saving the scene instead.
	if _timeline.resource_path.is_empty() or _timeline.resource_path.contains("::"):
		EditorInterface.mark_scene_as_unsaved()
		_status("Built-in timeline — marked the scene dirty. Save the scene (Ctrl+S).")
		return
	var err := ResourceSaver.save(_timeline, _timeline.resource_path)
	if err != OK:
		push_error("Godotion: failed to save '%s' (error %d)." % [_timeline.resource_path, err])
		_status("Save failed (error %d) — see Output." % err, true)
		return
	_status("Saved %s" % _timeline.resource_path.get_file())
