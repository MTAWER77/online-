@tool
extends Control

## The value graph: one polyline per numeric track, with draggable bezier
## handles on the selected keys.
##
## Shares zoom, pan, playhead and selection with the dope sheet through
## [code]timeline_view_state.gd[/code], so toggling between the two views keeps
## the user's place. Like the dope sheet it never performs an undoable mutation:
## it moves handles live for feedback, then reports the gesture.

signal handles_dragged(keys: Array, olds: Array, news: Array, incoming: bool)
signal keys_dragged(tracks: Array, keys: Array, old_times: Array, new_times: Array)
## Vertical key drags. The whole point of a value graph, and previously the one
## gesture it did not support.
signal keys_revalued(keys: Array, olds: Array, news: Array)
signal delete_requested()

const GodotionTheme := preload("res://addons/godotion/editor/godotion_theme.gd")
## Typed rather than bare for the same inference reason as the dope sheet.
const ViewState := preload("res://addons/godotion/editor/timeline_view_state.gd")

const GUTTER_W := 248.0
const RULER_H := 26.0
const PAD := 18.0
const KEY_RADIUS := 4.5
const HANDLE_RADIUS := 4.0
const SCROLL_W := 12.0
## Vertical span used when a track's keys are all the same value.
const FLAT_SPAN := 1.0

var view: ViewState

var timeline: MotionTimeline:
	set(v):
		if timeline == v:
			return
		if timeline != null and timeline.changed.is_connected(_on_timeline_changed):
			timeline.changed.disconnect(_on_timeline_changed)
		timeline = v
		if timeline != null:
			timeline.changed.connect(_on_timeline_changed)
		_tracks_dirty = true
		queue_redraw()

## Mirrors the dope sheet's filter. Without it, toggling views silently changed
## which tracks you were looking at.
var filter_text: String = "":
	set(v):
		filter_text = v
		_tracks_dirty = true
		queue_redraw()

## Scales every track to its own range instead of one shared axis. A shared
## axis draws `modulate:a` (0..1) as a flat line next to `position:x` (0..600),
## which makes the graph useless for exactly the tracks people want to shape.
var normalize: bool = false:
	set(v):
		normalize = v
		queue_redraw()

var _drag_mode := DragMode.NONE
var _drag_key: MotionKey = null
var _drag_track: MotionTrack = null
var _drag_incoming := false
var _drag_start_handle := Vector2.ZERO
var _drag_start_time := 0.0
var _drag_start_value: Variant = null
var _drag_value_is_int := false
## Cursor offset from the key when the drag began, so the key does not jump.
var _drag_grab_offset := Vector2.ZERO
var _drag_moved := false
var _drag_origin := Vector2.ZERO
var _drag_start_pan := 0.0

var _curve_cache: Array[MotionTrack] = []
var _tracks_dirty := true
## Vertical ranges, recomputed once per draw rather than once per plotted pixel.
var _global_range := Vector2(0.0, FLAT_SPAN)
var _track_ranges: Dictionary = {}
## Held still during a value drag: rescaling the axis from the value being
## dragged makes the key chase the cursor.
var _ranges_frozen := false

var _h_scroll: HScrollBar
var _syncing := false

enum DragMode { NONE, HANDLE, KEY, SCRUB, PAN }


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(480, 160)
	_h_scroll = HScrollBar.new()
	_h_scroll.anchor_left = 0.0
	_h_scroll.anchor_right = 1.0
	_h_scroll.anchor_top = 1.0
	_h_scroll.anchor_bottom = 1.0
	_h_scroll.offset_left = GUTTER_W
	_h_scroll.offset_right = 0.0
	_h_scroll.offset_top = -SCROLL_W
	_h_scroll.offset_bottom = 0.0
	_h_scroll.value_changed.connect(_on_h_scroll)
	add_child(_h_scroll)


func _on_timeline_changed() -> void:
	_tracks_dirty = true
	queue_redraw()


func _on_h_scroll(value: float) -> void:
	if _syncing or view == null:
		return
	view.pan_time = maxf(0.0, value)
	view.notify_view_changed()
	queue_redraw()


func _sync_scrollbar() -> void:
	if _syncing or view == null or _h_scroll == null:
		return
	_syncing = true
	var visible_span := maxf(0.01, lane_width() / view.pixels_per_second)
	var keyed: float = timeline.get_keyed_length() if timeline != null else 0.0
	var total: float = maxf(timeline.duration if timeline != null else 0.0, keyed)
	_h_scroll.min_value = 0.0
	_h_scroll.max_value = maxf(total + visible_span * 0.25, visible_span)
	_h_scroll.page = visible_span
	_h_scroll.value = view.pan_time
	_h_scroll.visible = _h_scroll.max_value > visible_span
	_syncing = false


func lane_width() -> float:
	return maxf(64.0, size.x - GUTTER_W)


# -- coordinates --------------------------------------------------------------

func time_to_x(t: float) -> float:
	return view.time_to_x(t, GUTTER_W)


func x_to_time(x: float) -> float:
	return view.x_to_time(x, GUTTER_W)


## Tracks drawn in the graph: numeric ones only, honouring the filter.
## Non-numeric tracks have no meaningful vertical axis, so they are listed in
## the gutter as unavailable. Cached — this used to be walked per plotted pixel.
func _curve_tracks() -> Array[MotionTrack]:
	if not _tracks_dirty:
		return _curve_cache
	var out: Array[MotionTrack] = []
	if timeline != null:
		for track in timeline.get_valid_tracks():
			if track.is_curve_editable() and _matches_filter(track):
				out.append(track)
	_curve_cache = out
	_tracks_dirty = false
	return _curve_cache


func _matches_filter(track: MotionTrack) -> bool:
	if filter_text.is_empty():
		return true
	var needle := filter_text.to_lower()
	return track.get_display_name().to_lower().contains(needle) \
		or track.property.to_lower().contains(needle) \
		or String(track.node_path).to_lower().contains(needle)


## Recomputes the shared and per-track vertical ranges. Called once per draw:
## [method value_to_y] used to recompute the whole thing on every one of the
## several hundred points sampled per curve, per track.
func _refresh_ranges() -> void:
	if _ranges_frozen:
		return
	var low := INF
	var high := -INF
	var per: Dictionary = {}
	for track in _curve_tracks():
		var r := track.get_value_range()
		per[track] = _pad_range(r)
		low = minf(low, r.x)
		high = maxf(high, r.y)
	_track_ranges = per
	_global_range = _pad_range(Vector2(low, high)) if low <= high else Vector2(0.0, FLAT_SPAN)


## Pads a raw min/max so curves never touch the edges, and gives a flat track a
## span to be drawn in the middle of.
static func _pad_range(r: Vector2) -> Vector2:
	if is_equal_approx(r.x, r.y):
		return Vector2(r.x - FLAT_SPAN * 0.5, r.y + FLAT_SPAN * 0.5)
	var pad := (r.y - r.x) * 0.12
	return Vector2(r.x - pad, r.y + pad)


## The vertical range [param track] is plotted against: its own when
## [member normalize] is set, otherwise the range shared by every drawn track.
func track_range(track: MotionTrack) -> Vector2:
	if normalize and track != null and _track_ranges.has(track):
		return _track_ranges[track]
	return _global_range


func _plot_top() -> float:
	return RULER_H + PAD


func _plot_bottom() -> float:
	return size.y - PAD - SCROLL_W


## Y for a 0..1 position in the plot area, independent of any track's values.
func fraction_y(f: float) -> float:
	return _plot_bottom() - f * (_plot_bottom() - _plot_top())


func value_to_y(v: float, track: MotionTrack) -> float:
	var r := track_range(track)
	var span := maxf(0.0001, r.y - r.x)
	return _plot_bottom() - (v - r.x) / span * (_plot_bottom() - _plot_top())


func y_to_value(y: float, track: MotionTrack) -> float:
	var r := track_range(track)
	return r.x + (_plot_bottom() - y) / maxf(1.0, _plot_bottom() - _plot_top()) * (r.y - r.x)


# -- drawing ------------------------------------------------------------------

func _draw() -> void:
	var font := GodotionTheme.font()
	var fsize := GodotionTheme.font_size()
	var bg := GodotionTheme.color(&"dark_color_2", Color("21262d"))
	var gutter_bg := GodotionTheme.color(&"dark_color_3", Color("1a1e24"))
	var line_col := GodotionTheme.color(&"contrast_color_1", Color(1, 1, 1, 0.08))
	var text_col := GodotionTheme.color(&"font_color", Color("d4d7dd"))
	var accent := GodotionTheme.color(&"accent_color", Color("4b9fea"))

	draw_rect(Rect2(Vector2.ZERO, size), bg)
	_sync_scrollbar()
	if timeline == null:
		return
	_refresh_ranges()

	_draw_value_grid(font, fsize, line_col, text_col)
	_draw_time_grid(line_col)
	for track in _curve_tracks():
		_draw_curve(track)
	_draw_gutter(font, fsize, text_col, gutter_bg, line_col)
	_draw_playhead(accent)


## Gridlines sit at fixed fractions of the plot area. The labels are absolute
## values on the shared axis, and 0..1 fractions when every track is normalised
## to its own range — where a single absolute number would be a lie.
func _draw_value_grid(font: Font, fsize: int, line_col: Color, text_col: Color) -> void:
	var steps := 5
	for i in range(steps + 1):
		var f := float(i) / float(steps)
		var y := fraction_y(f)
		draw_line(Vector2(GUTTER_W, y), Vector2(size.x, y), line_col, 1.0)
		var label := "%.2f" % f if normalize else "%.2f" % (_global_range.x + (_global_range.y - _global_range.x) * f)
		draw_string(font, Vector2(GUTTER_W + 4, y - 3), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fsize - 3, Color(text_col, 0.4))


func _draw_time_grid(line_col: Color) -> void:
	var step := _pick_step()
	var t := floorf(view.pan_time / step) * step
	while true:
		var x := time_to_x(t)
		if x > size.x:
			break
		if x >= GUTTER_W:
			draw_line(Vector2(x, RULER_H), Vector2(x, size.y), line_col, 1.0)
		t += step


func _pick_step() -> float:
	var candidates := [0.05, 0.1, 0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 30.0, 60.0]
	for candidate in candidates:
		if candidate * view.pixels_per_second >= 64.0:
			return candidate
	return candidates[candidates.size() - 1]


## Samples the track densely across each segment so the drawn curve is the
## curve the runtime will actually produce — no separate curve maths to drift.
func _draw_curve(track: MotionTrack) -> void:
	var keys := track.get_valid_keys()
	if keys.is_empty():
		return
	var accent := GodotionTheme.accent_for(track)
	if not track.enabled:
		accent = Color(accent, 0.3)

	var points := PackedVector2Array()
	var first_x := time_to_x(keys[0].time + track.time_offset)
	var last_x := time_to_x(keys[keys.size() - 1].time + track.time_offset)
	var from_x := maxf(first_x, GUTTER_W)
	var to_x := minf(last_x, size.x)
	var x := from_x
	while x <= to_x:
		var sampled: Variant = track.sample(x_to_time(x))
		if sampled != null:
			points.append(Vector2(x, value_to_y(float(sampled), track)))
		x += 2.0
	if points.size() > 1:
		draw_polyline(points, accent, 2.0)

	for key in keys:
		var kx := time_to_x(key.time + track.time_offset)
		if kx < GUTTER_W - 8.0 or kx > size.x + 8.0:
			continue
		var ky := value_to_y(float(key.value), track)
		var selected := view.is_selected(key)
		if selected:
			_draw_handles(track, key, Vector2(kx, ky), accent)
		draw_circle(Vector2(kx, ky), KEY_RADIUS, accent)
		draw_arc(Vector2(kx, ky), KEY_RADIUS, 0.0, TAU, 12,
			Color(1, 1, 1, 0.95) if selected else Color(0, 0, 0, 0.6), 1.5)


func _draw_handles(track: MotionTrack, key: MotionKey, center: Vector2, accent: Color) -> void:
	var handle_col := Color(1, 1, 1, 0.75)
	for incoming in [true, false]:
		var p := handle_position(track, key, incoming)
		if p == Vector2.INF:
			continue
		draw_line(center, p, Color(handle_col, 0.5), 1.0)
		draw_rect(Rect2(p - Vector2(HANDLE_RADIUS, HANDLE_RADIUS),
			Vector2(HANDLE_RADIUS * 2, HANDLE_RADIUS * 2)), handle_col)


## Screen position of a key's bezier handle, or [constant Vector2.INF] when the
## handle is not applicable (a linear segment has nothing to grab).
func handle_position(track: MotionTrack, key: MotionKey, incoming: bool) -> Vector2:
	var keys := track.get_valid_keys()
	var idx := keys.find(key)
	if idx < 0:
		return Vector2.INF
	# The outgoing handle belongs to this key's segment; the incoming one to the
	# previous key's segment. Only draw handles that actually shape a curve.
	if incoming:
		if idx == 0 or keys[idx - 1].interp != MotionKey.Interp.BEZIER:
			return Vector2.INF
	elif key.interp != MotionKey.Interp.BEZIER or idx == keys.size() - 1:
		return Vector2.INF

	var handle: Vector2 = key.in_handle if incoming else key.out_handle
	var neighbour: MotionKey = keys[idx - 1] if incoming else keys[idx + 1]
	var value_span: float = float(neighbour.value) - float(key.value)
	var t := key.time + track.time_offset + handle.x
	var v := float(key.value) + handle.y * absf(value_span if not is_zero_approx(value_span) else FLAT_SPAN)
	return Vector2(time_to_x(t), value_to_y(v, track))


func _draw_gutter(font: Font, fsize: int, text_col: Color, gutter_bg: Color, line_col: Color) -> void:
	draw_rect(Rect2(0, 0, GUTTER_W, size.y), gutter_bg)
	draw_line(Vector2(GUTTER_W, 0), Vector2(GUTTER_W, size.y), line_col, 1.0)
	draw_rect(Rect2(0, 0, size.x, RULER_H), GodotionTheme.color(&"dark_color_1", Color("15191e")))
	draw_string(font, Vector2(10, RULER_H - 8), "Curves", HORIZONTAL_ALIGNMENT_LEFT, -1,
		fsize - 2, Color(text_col, 0.55))

	var y := RULER_H + 8.0
	var drawn := _curve_tracks()
	for track in drawn:
		draw_rect(Rect2(10, y + 3, 10, 3), GodotionTheme.accent_for(track))
		draw_string(font, Vector2(26, y + 8), "%s · %s" % [track.get_display_name(), track.property],
			HORIZONTAL_ALIGNMENT_LEFT, GUTTER_W - 34, fsize - 2, Color(text_col, 0.9))
		y += 14.0
		# Under normalisation the shared axis labels stop describing this track,
		# so its real span has to be legible here instead.
		if normalize:
			var raw := track.get_value_range()
			draw_string(font, Vector2(26, y + 6), "%.2f → %.2f" % [raw.x, raw.y],
				HORIZONTAL_ALIGNMENT_LEFT, GUTTER_W - 34, fsize - 4, Color(text_col, 0.45))
			y += 12.0
		y += 4.0

	# Say plainly why a track is missing rather than silently omitting it.
	var skipped := 0
	if timeline != null:
		for track in timeline.get_valid_tracks():
			if not track.is_curve_editable() or not _matches_filter(track):
				skipped += 1
	if skipped > 0:
		draw_string(font, Vector2(10, y + 12),
			"%d non-numeric track%s hidden" % [skipped, "" if skipped == 1 else "s"],
			HORIZONTAL_ALIGNMENT_LEFT, GUTTER_W - 20, fsize - 3, Color(text_col, 0.45))
	if drawn.is_empty() and skipped == 0:
		draw_string(font, Vector2(10, RULER_H + 24), "No keyed tracks yet.",
			HORIZONTAL_ALIGNMENT_LEFT, GUTTER_W - 20, fsize - 2, Color(text_col, 0.45))


func _draw_playhead(accent: Color) -> void:
	var x := time_to_x(view.playhead)
	if x < GUTTER_W or x > size.x:
		return
	draw_line(Vector2(x, 0), Vector2(x, size.y), accent, 1.0)


# -- hit testing --------------------------------------------------------------

func _handle_at(pos: Vector2) -> Dictionary:
	var drawn := _curve_tracks()
	for entry in view.get_selection():
		var track: MotionTrack = entry["track"]
		var key: MotionKey = entry["key"]
		# Only tracks actually on screen. A selection can outlive a filter
		# change, and an invisible handle that still takes the click is worse
		# than no handle at all.
		if not drawn.has(track):
			continue
		for incoming in [true, false]:
			var p := handle_position(track, key, incoming)
			if p != Vector2.INF and pos.distance_to(p) <= HANDLE_RADIUS + 3.0:
				return {"track": track, "key": key, "incoming": incoming}
	return {}


func _key_at(pos: Vector2) -> Dictionary:
	var best: Dictionary = {}
	var best_dist := KEY_RADIUS + 5.0
	for track in _curve_tracks():
		for key in track.get_valid_keys():
			var p := Vector2(time_to_x(key.time + track.time_offset), value_to_y(float(key.value), track))
			var dist := pos.distance_to(p)
			if dist < best_dist:
				best_dist = dist
				best = {"track": track, "key": key}
	return best


# -- input --------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if timeline == null:
		return
	if event is InputEventMouseButton:
		_handle_button(event)
	elif event is InputEventMouseMotion:
		_handle_motion(event)
	elif event is InputEventKey and event.pressed and event.keycode == KEY_DELETE:
		delete_requested.emit()
		accept_event()


func _handle_button(event: InputEventMouseButton) -> void:
	var pos := event.position

	if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		if not event.pressed:
			return
		var dir := 1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
		view.zoom_at(pos.x, 1.0 + dir * 0.15, GUTTER_W)
		queue_redraw()
		accept_event()
		return

	if event.button_index == MOUSE_BUTTON_MIDDLE:
		_drag_mode = DragMode.PAN if event.pressed else DragMode.NONE
		_drag_origin = pos
		_drag_start_pan = view.pan_time
		accept_event()
		return

	if event.button_index != MOUSE_BUTTON_LEFT:
		return

	if not event.pressed:
		_finish_drag()
		accept_event()
		return

	grab_focus()

	if pos.y < RULER_H:
		_drag_mode = DragMode.SCRUB
		_set_playhead_from_x(pos.x)
		accept_event()
		return

	var handle := _handle_at(pos)
	if not handle.is_empty():
		_drag_mode = DragMode.HANDLE
		_drag_key = handle["key"]
		_drag_track = handle["track"]
		_drag_incoming = handle["incoming"]
		_drag_start_handle = _drag_key.in_handle if _drag_incoming else _drag_key.out_handle
		_drag_moved = false
		accept_event()
		return

	var hit := _key_at(pos)
	if hit.is_empty():
		if not event.shift_pressed:
			view.clear()
		accept_event()
		return

	if not view.is_selected(hit["key"]):
		view.select(hit["track"], hit["key"], event.shift_pressed)
	_drag_mode = DragMode.KEY
	_drag_key = hit["key"]
	_drag_track = hit["track"]
	_drag_start_time = _drag_key.time
	_drag_start_value = _drag_key.value
	_drag_value_is_int = typeof(_drag_key.value) == TYPE_INT
	_drag_grab_offset = pos - Vector2(
		time_to_x(_drag_key.time + _drag_track.time_offset),
		value_to_y(float(_drag_key.value), _drag_track))
	# The axis is derived from the values being dragged, so leaving it live
	# would rescale the graph out from under the cursor mid-gesture.
	_ranges_frozen = true
	_drag_moved = false
	_drag_origin = pos
	queue_redraw()
	accept_event()


func _handle_motion(event: InputEventMouseMotion) -> void:
	match _drag_mode:
		DragMode.SCRUB:
			_set_playhead_from_x(event.position.x)
			accept_event()
		DragMode.PAN:
			view.pan_time = maxf(0.0, _drag_start_pan - (event.position.x - _drag_origin.x) / view.pixels_per_second)
			view.notify_view_changed()
			queue_redraw()
			accept_event()
		DragMode.HANDLE:
			_drag_handle(event.position)
			accept_event()
		DragMode.KEY:
			if _drag_track.locked:
				return
			var delta := (event.position.x - _drag_origin.x) / view.pixels_per_second
			var target := _drag_start_time + delta
			if view.snap_enabled and not event.ctrl_pressed:
				target = timeline.snap_to_frame(target + _drag_track.time_offset) - _drag_track.time_offset
			_drag_key.time = maxf(0.0, target)
			# Vertical movement edits the value — the gesture a value graph is
			# for. Shift pins the value so the drag is time-only.
			if not event.shift_pressed:
				var v := y_to_value(event.position.y - _drag_grab_offset.y, _drag_track)
				_drag_key.value = int(roundf(v)) if _drag_value_is_int else v
			_drag_moved = true
			_drag_track.sort_keys()
			queue_redraw()
			accept_event()


## Converts the mouse position back into the key's (time-offset, value-fraction)
## handle space, mirroring [method handle_position].
func _drag_handle(pos: Vector2) -> void:
	if _drag_track.locked:
		return
	var keys := _drag_track.get_valid_keys()
	var idx := keys.find(_drag_key)
	if idx < 0:
		return
	var neighbour: MotionKey = keys[idx - 1] if _drag_incoming else keys[idx + 1]
	var value_span: float = float(neighbour.value) - float(_drag_key.value)
	var scale: float = absf(value_span) if not is_zero_approx(value_span) else FLAT_SPAN

	var dt := x_to_time(pos.x) - (_drag_key.time + _drag_track.time_offset)
	var dv := (y_to_value(pos.y, _drag_track) - float(_drag_key.value)) / scale
	# Handles must stay on their own side of the key or the segment folds back
	# on itself and the bezier X solve stops being monotonic.
	if _drag_incoming:
		dt = minf(dt, -0.0001)
	else:
		dt = maxf(dt, 0.0001)

	var handle := Vector2(dt, dv)
	if _drag_incoming:
		_drag_key.in_handle = handle
	else:
		_drag_key.out_handle = handle
	_drag_moved = true
	queue_redraw()


func _finish_drag() -> void:
	match _drag_mode:
		DragMode.HANDLE:
			if _drag_moved and _drag_key != null:
				var now: Vector2 = _drag_key.in_handle if _drag_incoming else _drag_key.out_handle
				handles_dragged.emit([_drag_key], [_drag_start_handle], [now], _drag_incoming)
		DragMode.KEY:
			if _drag_moved and _drag_key != null:
				# Time and value are separate undo actions because they are
				# separate axes of the same drag: either may be a no-op.
				if not is_equal_approx(_drag_key.time, _drag_start_time):
					keys_dragged.emit([_drag_track], [_drag_key], [_drag_start_time], [_drag_key.time])
				if not _values_equal(_drag_key.value, _drag_start_value):
					keys_revalued.emit([_drag_key], [_drag_start_value], [_drag_key.value])
	_drag_mode = DragMode.NONE
	_drag_key = null
	_drag_track = null
	_drag_start_value = null
	_drag_moved = false
	_ranges_frozen = false
	_tracks_dirty = true
	queue_redraw()


static func _values_equal(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		return false
	if typeof(a) == TYPE_FLOAT:
		return is_equal_approx(a, b)
	return a == b


func _set_playhead_from_x(x: float) -> void:
	var t := maxf(0.0, x_to_time(x))
	if view.snap_enabled:
		t = timeline.snap_to_frame(t)
	view.playhead = clampf(t, 0.0, timeline.duration)
