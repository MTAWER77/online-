@tool
extends Control

## The dope sheet: gutter, ruler, track lanes, keys and playhead.
##
## Owns hit-testing and drag gestures but never performs an undoable mutation —
## it moves keys live during a drag for feedback, then reports the gesture so
## [code]timeline_panel.gd[/code] can register a single symmetrical undo step.
##
## Viewport and selection state lives in the shared
## [code]timeline_view_state.gd[/code] so the curve view stays in sync.

signal keys_dragged(tracks: Array, keys: Array, old_times: Array, new_times: Array)
signal track_enable_toggled(track: MotionTrack, enabled: bool)
signal track_solo_toggled(track: MotionTrack, solo: bool)
signal track_lock_toggled(track: MotionTrack, locked: bool)
## Reports the drop as "put [param track] immediately before [param before]",
## with a null [param before] meaning "at the end". Deliberately not a row
## index: rows are the filtered, null-free view, and feeding that number to
## [method MotionTimeline.move_track] — which indexes the raw array — reordered
## to the wrong slot whenever a filter was set or the array had a hole.
signal tracks_reordered(track: MotionTrack, before: MotionTrack)
signal delete_requested()
signal key_double_clicked(track: MotionTrack, key: MotionKey)
signal track_context_requested(track: MotionTrack, at: Vector2)
signal marker_moved(marker: MotionMarker, old_time: float, new_time: float)
signal marker_double_clicked(marker: MotionMarker)
signal loop_region_changed(start: float, end: float)

const GodotionTheme := preload("res://addons/godotion/editor/godotion_theme.gd")
## Typed as the preloaded script, not left bare: a `preload`ed script without a
## `class_name` cannot be inferred through, so `:=` fails on every member access.
const ViewState := preload("res://addons/godotion/editor/timeline_view_state.gd")

const GUTTER_W := 248.0
const RULER_H := 26.0
const ROW_H := 26.0
const ICON_SIZE := 16.0
const KEY_RADIUS := 5.5
## Gutter hit zones, as x ranges.
const TOGGLE_X := Vector2(8.0, 20.0)
const SOLO_X := Vector2(24.0, 36.0)
const LOCK_X := Vector2(40.0, 52.0)

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
		_rows_dirty = true
		queue_redraw()

## Scene root used to resolve node paths for icon lookup.
var root_node: Node = null:
	set(v):
		root_node = v
		queue_redraw()

## Tracks whose display name or property matches this are shown; empty shows all.
var filter_text: String = "":
	set(v):
		filter_text = v
		_rows_dirty = true
		queue_redraw()

var _drag_mode := DragMode.NONE
var _drag_origin := Vector2.ZERO
var _drag_start_times: Array[float] = []
var _drag_start_pan := 0.0
var _drag_moved := false
var _box_end := Vector2.ZERO
var _box_additive := false
var _drag_marker: MotionMarker = null
var _drag_marker_start := 0.0
var _drag_row_track: MotionTrack = null
var _drag_row_to := -1
var _region_edge := 0
var _last_click_key: MotionKey = null
var _last_click_msec := 0

## Cached result of [method rows]. It was recomputed — and reallocated — by
## every draw pass and every hit test, a dozen times a frame.
var _rows_cache: Array[MotionTrack] = []
var _rows_dirty := true

var _h_scroll: HScrollBar
var _v_scroll: VScrollBar
## Guards the two-way scrollbar/view binding against feeding itself.
var _syncing := false

const SCROLL_W := 12.0

enum DragMode { NONE, SCRUB, KEYS, PAN, BOX, MARKER, ROW, REGION }


func _ready() -> void:
	focus_mode = Control.FOCUS_ALL
	mouse_filter = Control.MOUSE_FILTER_STOP
	custom_minimum_size = Vector2(480, 160)
	_build_scrollbars()


## Wheel and middle-drag were the only way to move around, which is not
## discoverable and gives no sense of how much timeline lies off-screen.
func _build_scrollbars() -> void:
	_h_scroll = HScrollBar.new()
	_h_scroll.anchor_left = 0.0
	_h_scroll.anchor_right = 1.0
	_h_scroll.anchor_top = 1.0
	_h_scroll.anchor_bottom = 1.0
	_h_scroll.offset_left = GUTTER_W
	_h_scroll.offset_right = -SCROLL_W
	_h_scroll.offset_top = -SCROLL_W
	_h_scroll.offset_bottom = 0.0
	_h_scroll.value_changed.connect(_on_h_scroll)
	add_child(_h_scroll)

	_v_scroll = VScrollBar.new()
	_v_scroll.anchor_left = 1.0
	_v_scroll.anchor_right = 1.0
	_v_scroll.anchor_top = 0.0
	_v_scroll.anchor_bottom = 1.0
	_v_scroll.offset_left = -SCROLL_W
	_v_scroll.offset_right = 0.0
	_v_scroll.offset_top = RULER_H
	_v_scroll.offset_bottom = -SCROLL_W
	_v_scroll.value_changed.connect(_on_v_scroll)
	add_child(_v_scroll)


func _on_timeline_changed() -> void:
	_rows_dirty = true
	queue_redraw()


func _on_h_scroll(value: float) -> void:
	if _syncing or view == null:
		return
	view.pan_time = maxf(0.0, value)
	view.notify_view_changed()
	queue_redraw()


func _on_v_scroll(value: float) -> void:
	if _syncing or view == null:
		return
	view.v_offset = clampf(value, 0.0, max_v_offset())
	view.notify_view_changed()
	queue_redraw()


## Pushes the current zoom/pan into the bars. Called from [method _draw], which
## is where every gesture converges, rather than from each of them.
func _sync_scrollbars() -> void:
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

	var lane_h := maxf(1.0, size.y - RULER_H - SCROLL_W)
	_v_scroll.min_value = 0.0
	_v_scroll.max_value = maxf(content_height(), lane_h)
	_v_scroll.page = lane_h
	_v_scroll.value = view.v_offset
	_v_scroll.visible = content_height() > lane_h
	_syncing = false


## Width of the lane area, excluding the gutter and the vertical scrollbar.
func lane_width() -> float:
	return maxf(64.0, size.x - GUTTER_W - SCROLL_W)


# -- coordinate helpers -------------------------------------------------------

func time_to_x(t: float) -> float:
	return view.time_to_x(t, GUTTER_W)


func x_to_time(x: float) -> float:
	return view.x_to_time(x, GUTTER_W)


func row_y(index: int) -> float:
	return RULER_H + index * ROW_H - view.v_offset


## Rows map to the filtered, null-free track view — never to raw indices into
## [member MotionTimeline.tracks]. Cached; [member _rows_dirty] is set by the
## timeline's own [signal Resource.changed] and by a filter change.
func rows() -> Array[MotionTrack]:
	if not _rows_dirty:
		return _rows_cache
	var out: Array[MotionTrack] = []
	if timeline != null:
		for track in timeline.get_valid_tracks():
			if _matches_filter(track):
				out.append(track)
	_rows_cache = out
	_rows_dirty = false
	return _rows_cache


func _matches_filter(track: MotionTrack) -> bool:
	if filter_text.is_empty():
		return true
	var needle := filter_text.to_lower()
	return track.get_display_name().to_lower().contains(needle) \
		or track.property.to_lower().contains(needle) \
		or String(track.node_path).to_lower().contains(needle)


func content_height() -> float:
	return rows().size() * ROW_H


func max_v_offset() -> float:
	return maxf(0.0, content_height() - (size.y - RULER_H - SCROLL_W))


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
	_sync_scrollbars()

	if timeline == null:
		var msg := "Select a MotionPlayer, or create a timeline to begin."
		draw_string(font, Vector2(GUTTER_W * 0.5, size.y * 0.5), msg,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fsize, Color(text_col, 0.6))
		return

	_draw_lane_background(line_col)
	_draw_ruler(font, fsize, text_col, line_col, accent)
	_draw_tracks(font, fsize, text_col, line_col)
	_draw_gutter(font, fsize, text_col, gutter_bg, line_col)
	_draw_box(accent)
	_draw_playhead(font, fsize, accent)


func _draw_lane_background(line_col: Color) -> void:
	var lane_h := size.y - RULER_H
	# Shade beyond the authored duration so overruns are obvious.
	var end_x := time_to_x(timeline.duration)
	if end_x < size.x:
		draw_rect(Rect2(maxf(end_x, GUTTER_W), RULER_H, size.x - maxf(end_x, GUTTER_W), lane_h),
			Color(0, 0, 0, 0.18))

	# Shade outside the loop region, which reads as "this part will not play".
	if timeline.loop_region_enabled and timeline.loop_region_end > timeline.loop_region_start:
		var rs := time_to_x(timeline.loop_region_start)
		var re := time_to_x(timeline.loop_region_end)
		if rs > GUTTER_W:
			draw_rect(Rect2(GUTTER_W, RULER_H, minf(rs, size.x) - GUTTER_W, lane_h), Color(0, 0, 0, 0.22))
		if re < size.x:
			draw_rect(Rect2(maxf(re, GUTTER_W), RULER_H, size.x - maxf(re, GUTTER_W), lane_h), Color(0, 0, 0, 0.22))

	for i in range(rows().size()):
		var y := row_y(i)
		if y + ROW_H < RULER_H or y > size.y:
			continue
		if i % 2 == 1:
			draw_rect(Rect2(GUTTER_W, y, size.x - GUTTER_W, ROW_H), Color(1, 1, 1, 0.02))
		draw_line(Vector2(GUTTER_W, y + ROW_H), Vector2(size.x, y + ROW_H), line_col, 1.0)


func _draw_ruler(font: Font, fsize: int, text_col: Color, line_col: Color, accent: Color) -> void:
	draw_rect(Rect2(0, 0, size.x, RULER_H), GodotionTheme.color(&"dark_color_1", Color("15191e")))

	var step := _pick_ruler_step()
	var t := floorf(view.pan_time / step) * step
	while true:
		var x := time_to_x(t)
		if x > size.x:
			break
		if x >= GUTTER_W:
			draw_line(Vector2(x, 0), Vector2(x, size.y), line_col, 1.0)
			draw_string(font, Vector2(x + 4, RULER_H - 8), _format_time(t),
				HORIZONTAL_ALIGNMENT_LEFT, -1, fsize - 2, Color(text_col, 0.75))
		t += step
	draw_line(Vector2(0, RULER_H), Vector2(size.x, RULER_H), line_col, 1.0)

	_draw_loop_region(accent)
	_draw_markers(font, fsize, text_col)


func _draw_loop_region(accent: Color) -> void:
	if not timeline.loop_region_enabled or timeline.loop_region_end <= timeline.loop_region_start:
		return
	var rs := clampf(time_to_x(timeline.loop_region_start), GUTTER_W, size.x)
	var re := clampf(time_to_x(timeline.loop_region_end), GUTTER_W, size.x)
	draw_rect(Rect2(rs, 0, re - rs, 4), Color(accent, 0.8))
	# Grab handles at each edge.
	draw_rect(Rect2(rs - 2, 0, 4, RULER_H), Color(accent, 0.5))
	draw_rect(Rect2(re - 2, 0, 4, RULER_H), Color(accent, 0.5))


func _draw_markers(font: Font, fsize: int, text_col: Color) -> void:
	for marker in timeline.get_valid_markers():
		var x := time_to_x(marker.time)
		if x < GUTTER_W or x > size.x:
			continue
		draw_line(Vector2(x, RULER_H), Vector2(x, size.y), Color(marker.color, 0.28), 1.0)
		var flag := PackedVector2Array([
			Vector2(x, RULER_H - 12), Vector2(x + 9, RULER_H - 9),
			Vector2(x, RULER_H - 6),
		])
		draw_colored_polygon(flag, marker.color)
		draw_string(font, Vector2(x + 12, RULER_H - 6), marker.name,
			HORIZONTAL_ALIGNMENT_LEFT, 90, fsize - 3, Color(text_col, 0.8))


func _pick_ruler_step() -> float:
	var frame := 1.0 / float(maxi(1, timeline.fps if timeline != null else 60))
	var candidates := [frame, frame * 2.0, frame * 5.0, 0.1, 0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 30.0, 60.0, 300.0]
	for candidate in candidates:
		if candidate * view.pixels_per_second >= 64.0:
			return candidate
	return candidates[candidates.size() - 1]


func _format_time(t: float) -> String:
	if timeline != null and show_frames:
		return "%d" % roundi(t * float(timeline.fps))
	if view.pixels_per_second > 400.0:
		return "%.2fs" % t
	if t >= 60.0:
		return "%d:%05.2f" % [int(t / 60.0), fmod(t, 60.0)]
	return "%.2fs" % t


## Ruler labels as frame numbers rather than seconds.
var show_frames: bool = false:
	set(v):
		show_frames = v
		queue_redraw()


func _draw_tracks(font: Font, fsize: int, text_col: Color, line_col: Color) -> void:
	var track_rows := rows()
	for i in range(track_rows.size()):
		var track: MotionTrack = track_rows[i]
		var y := row_y(i)
		if y + ROW_H < RULER_H or y > size.y:
			continue
		var accent := GodotionTheme.accent_for(track)
		if not track.enabled:
			accent = Color(accent, 0.35)
		var mid := y + ROW_H * 0.5

		# Span bar between the first and last key, in timeline space. Trigger
		# tracks get none: nothing is interpolated between two cues, and a bar
		# joining them would claim otherwise.
		var track_keys := track.get_valid_keys()
		if track_keys.size() > 1 and not track.is_trigger():
			var x0 := time_to_x(track_keys[0].time + track.time_offset)
			var x1 := time_to_x(track_keys[track_keys.size() - 1].time + track.time_offset)
			var from_x := maxf(x0, GUTTER_W)
			var to_x := minf(x1, size.x)
			if to_x > from_x:
				draw_line(Vector2(from_x, mid), Vector2(to_x, mid), Color(accent, 0.45), 2.0)

		for key in track_keys:
			var x := time_to_x(key.time + track.time_offset)
			if x < GUTTER_W - KEY_RADIUS or x > size.x + KEY_RADIUS:
				continue
			if track.is_trigger():
				_draw_trigger_key(Vector2(x, mid), accent, view.is_selected(key))
			else:
				_draw_key(Vector2(x, mid), accent, view.is_selected(key), key.interp)

		# Drop indicator while reordering rows. A target one past the last row
		# means "drop at the end", drawn on that row's bottom edge.
		if _drag_mode == DragMode.ROW:
			if _drag_row_to == i:
				draw_line(Vector2(0, y), Vector2(size.x, y), Color(1, 1, 1, 0.7), 2.0)
			elif _drag_row_to == track_rows.size() and i == track_rows.size() - 1:
				draw_line(Vector2(0, y + ROW_H), Vector2(size.x, y + ROW_H), Color(1, 1, 1, 0.7), 2.0)


## A cue, not a pose. Drawn as a stem with a pennant so it cannot be mistaken
## for any of the interpolation glyphs below — a trigger key has no
## interpolation to encode, and reading one as "linear" would be misleading.
func _draw_trigger_key(center: Vector2, accent: Color, selected: bool) -> void:
	var r := KEY_RADIUS
	var outline_col := Color(1, 1, 1, 0.95) if selected else Color(0, 0, 0, 0.6)
	draw_line(center + Vector2(0, -r), center + Vector2(0, r), accent, 2.0)
	var points := PackedVector2Array([
		center + Vector2(0, -r), center + Vector2(r * 1.4, -r * 0.45),
		center + Vector2(0, 0.1 * r),
	])
	draw_colored_polygon(points, accent)
	var outline := points.duplicate()
	outline.append(points[0])
	draw_polyline(outline, outline_col, 1.5)


## Key glyphs encode interpolation, so the mode is readable without clicking:
## square holds, diamond is linear, the eases lean, bezier is a circle.
func _draw_key(center: Vector2, accent: Color, selected: bool, interp: int) -> void:
	var r := KEY_RADIUS
	var outline_col := Color(1, 1, 1, 0.95) if selected else Color(0, 0, 0, 0.6)
	if interp == MotionKey.Interp.BEZIER:
		draw_circle(center, r, accent)
		draw_arc(center, r, 0.0, TAU, 16, outline_col, 1.5)
		return
	var points: PackedVector2Array
	match interp:
		MotionKey.Interp.CONSTANT:
			points = PackedVector2Array([
				center + Vector2(-r, -r), center + Vector2(r, -r),
				center + Vector2(r, r), center + Vector2(-r, r),
			])
		MotionKey.Interp.EASE_IN:
			points = PackedVector2Array([
				center + Vector2(-r, -r), center + Vector2(r, 0),
				center + Vector2(-r, r),
			])
		MotionKey.Interp.EASE_OUT:
			points = PackedVector2Array([
				center + Vector2(r, -r), center + Vector2(-r, 0),
				center + Vector2(r, r),
			])
		MotionKey.Interp.EASE_IN_OUT:
			points = PackedVector2Array([
				center + Vector2(0, -r), center + Vector2(r * 0.7, 0),
				center + Vector2(0, r), center + Vector2(-r * 0.7, 0),
			])
		_:
			points = PackedVector2Array([
				center + Vector2(0, -r), center + Vector2(r, 0),
				center + Vector2(0, r), center + Vector2(-r, 0),
			])
	draw_colored_polygon(points, accent)
	var outline := points.duplicate()
	outline.append(points[0])
	draw_polyline(outline, outline_col, 1.5)


func _draw_gutter(font: Font, fsize: int, text_col: Color, gutter_bg: Color, line_col: Color) -> void:
	draw_rect(Rect2(0, 0, GUTTER_W, size.y), gutter_bg)
	draw_line(Vector2(GUTTER_W, 0), Vector2(GUTTER_W, size.y), line_col, 1.0)
	draw_string(font, Vector2(10, RULER_H - 8), "Tracks", HORIZONTAL_ALIGNMENT_LEFT, -1,
		fsize - 2, Color(text_col, 0.55))

	var track_rows := rows()
	for i in range(track_rows.size()):
		var track: MotionTrack = track_rows[i]
		var y := row_y(i)
		if y + ROW_H < RULER_H or y > size.y:
			continue
		var accent := GodotionTheme.accent_for(track)
		var alpha := 1.0 if track.enabled else 0.4

		draw_rect(Rect2(0, y + 3, 3, ROW_H - 6), Color(accent, alpha))

		var cy := y + (ROW_H - 12) * 0.5
		# Enable (mute) toggle.
		var toggle := Rect2(TOGGLE_X.x, cy, 12, 12)
		draw_rect(toggle, Color(accent, 0.85 if track.enabled else 0.0))
		draw_rect(toggle, Color(accent, 0.85), false, 1.0)
		# Solo.
		var solo := Rect2(SOLO_X.x, cy, 12, 12)
		var solo_col := Color("f0c674")
		draw_rect(solo, Color(solo_col, 0.9 if track.solo else 0.0))
		draw_rect(solo, Color(solo_col, 0.7), false, 1.0)
		draw_string(font, Vector2(SOLO_X.x + 3, cy + 10), "S", HORIZONTAL_ALIGNMENT_LEFT, -1,
			fsize - 4, Color(0, 0, 0, 0.8) if track.solo else Color(solo_col, 0.7))
		# Lock.
		var lock := Rect2(LOCK_X.x, cy, 12, 12)
		var lock_col := Color("e06c75")
		draw_rect(lock, Color(lock_col, 0.9 if track.locked else 0.0))
		draw_rect(lock, Color(lock_col, 0.7), false, 1.0)
		draw_string(font, Vector2(LOCK_X.x + 3, cy + 10), "L", HORIZONTAL_ALIGNMENT_LEFT, -1,
			fsize - 4, Color(0, 0, 0, 0.8) if track.locked else Color(lock_col, 0.7))

		var node := _resolve_track_node(track)
		var icon := GodotionTheme.icon_for_node(node)
		if icon != null:
			draw_texture_rect(icon, Rect2(58, y + (ROW_H - ICON_SIZE) * 0.5, ICON_SIZE, ICON_SIZE),
				false, Color(1, 1, 1, alpha))

		draw_string(font, Vector2(80, y + ROW_H * 0.5 + 4), track.get_display_name(),
			HORIZONTAL_ALIGNMENT_LEFT, 76, fsize, Color(text_col, alpha))
		var prop := track.property
		if not is_zero_approx(track.time_offset):
			prop += "  %+.2fs" % track.time_offset
		draw_string(font, Vector2(160, y + ROW_H * 0.5 + 4), prop,
			HORIZONTAL_ALIGNMENT_LEFT, GUTTER_W - 166, fsize - 2, Color(accent, alpha))

		draw_line(Vector2(0, y + ROW_H), Vector2(GUTTER_W, y + ROW_H), line_col, 1.0)


func _draw_box(accent: Color) -> void:
	if _drag_mode != DragMode.BOX:
		return
	var rect := _box_rect()
	draw_rect(rect, Color(accent, 0.12))
	draw_rect(rect, Color(accent, 0.7), false, 1.0)


func _draw_playhead(font: Font, fsize: int, accent: Color) -> void:
	var x := time_to_x(view.playhead)
	if x < GUTTER_W or x > size.x:
		return
	draw_line(Vector2(x, 0), Vector2(x, size.y), accent, 1.0)
	var head := PackedVector2Array([
		Vector2(x - 6, 0), Vector2(x + 6, 0), Vector2(x + 6, 10), Vector2(x, 16), Vector2(x - 6, 10),
	])
	draw_colored_polygon(head, accent)


func _resolve_track_node(track: MotionTrack) -> Node:
	if root_node == null:
		return null
	if track.node_path.is_empty():
		return root_node
	return root_node.get_node_or_null(track.node_path)


# -- hit testing --------------------------------------------------------------

func _row_at(pos: Vector2) -> int:
	if pos.y < RULER_H or timeline == null:
		return -1
	var index := int((pos.y + view.v_offset - RULER_H) / ROW_H)
	if index < 0 or index >= rows().size():
		return -1
	return index


func _key_at(pos: Vector2) -> Dictionary:
	var row := _row_at(pos)
	if row < 0 or pos.x < GUTTER_W:
		return {}
	var track: MotionTrack = rows()[row]
	var mid := row_y(row) + ROW_H * 0.5
	if absf(pos.y - mid) > KEY_RADIUS + 3.0:
		return {}
	var best: MotionKey = null
	var best_dist := KEY_RADIUS + 4.0
	for key in track.get_valid_keys():
		var dist := absf(time_to_x(key.time + track.time_offset) - pos.x)
		if dist < best_dist:
			best_dist = dist
			best = key
	if best == null:
		return {}
	return {"track": track, "key": best}


func _marker_at(pos: Vector2) -> MotionMarker:
	if timeline == null or pos.y > RULER_H:
		return null
	for marker in timeline.get_valid_markers():
		if absf(time_to_x(marker.time) - pos.x) <= 6.0:
			return marker
	return null


## 1 for the region start edge, 2 for the end edge, 0 for neither.
func _region_edge_at(pos: Vector2) -> int:
	if timeline == null or not timeline.loop_region_enabled or pos.y > RULER_H:
		return 0
	if timeline.loop_region_end <= timeline.loop_region_start:
		return 0
	if absf(time_to_x(timeline.loop_region_start) - pos.x) <= 4.0:
		return 1
	if absf(time_to_x(timeline.loop_region_end) - pos.x) <= 4.0:
		return 2
	return 0


func _box_rect() -> Rect2:
	return Rect2(_drag_origin.min(_box_end), (_box_end - _drag_origin).abs())


func get_track_at(pos: Vector2) -> MotionTrack:
	var row := _row_at(pos)
	return null if row < 0 else rows()[row]


# -- input --------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if timeline == null:
		return

	if event is InputEventMouseButton:
		_handle_button(event)
	elif event is InputEventMouseMotion:
		_handle_motion(event)
	elif event is InputEventKey and event.pressed:
		_handle_key(event)


func _handle_key(event: InputEventKey) -> void:
	match event.keycode:
		KEY_DELETE:
			delete_requested.emit()
			accept_event()
		KEY_LEFT, KEY_RIGHT:
			# Nudge by one frame, or ten with Shift.
			if view.is_empty():
				return
			var step := 1.0 / float(timeline.fps)
			if event.shift_pressed:
				step *= 10.0
			_nudge(step if event.keycode == KEY_RIGHT else -step)
			accept_event()


func _nudge(delta: float) -> void:
	var selection := view.get_selection()
	var tracks: Array = []
	var keys: Array = []
	var old_times: Array = []
	var new_times: Array = []
	for entry in selection:
		var track: MotionTrack = entry["track"]
		if track.locked:
			continue
		var key: MotionKey = entry["key"]
		old_times.append(key.time)
		key.time = maxf(0.0, key.time + delta)
		tracks.append(track)
		keys.append(key)
		new_times.append(key.time)
	if keys.is_empty():
		return
	for track in tracks:
		(track as MotionTrack).sort_keys()
	keys_dragged.emit(tracks, keys, old_times, new_times)
	queue_redraw()


func _handle_button(event: InputEventMouseButton) -> void:
	var pos := event.position

	if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		if not event.pressed:
			return
		var dir := 1.0 if event.button_index == MOUSE_BUTTON_WHEEL_UP else -1.0
		if event.is_command_or_control_pressed():
			view.zoom_at(pos.x, 1.0 + dir * 0.15, GUTTER_W)
		elif event.shift_pressed:
			view.pan_time = maxf(0.0, view.pan_time - dir * (80.0 / view.pixels_per_second))
		else:
			view.v_offset = clampf(view.v_offset - dir * ROW_H * 2.0, 0.0, max_v_offset())
		view.notify_view_changed()
		queue_redraw()
		accept_event()
		return

	if event.button_index == MOUSE_BUTTON_MIDDLE:
		_drag_mode = DragMode.PAN if event.pressed else DragMode.NONE
		_drag_origin = pos
		_drag_start_pan = view.pan_time
		accept_event()
		return

	if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		var track := get_track_at(pos)
		if track != null and pos.x < GUTTER_W:
			track_context_requested.emit(track, pos)
			accept_event()
		return

	if event.button_index != MOUSE_BUTTON_LEFT:
		return

	if not event.pressed:
		_finish_drag()
		accept_event()
		return

	grab_focus()

	if pos.x < GUTTER_W:
		_press_gutter(pos, event)
		return

	if pos.y < RULER_H:
		_press_ruler(pos)
		return

	_press_lane(pos, event)


func _press_gutter(pos: Vector2, event: InputEventMouseButton) -> void:
	var row := _row_at(pos)
	if row < 0:
		accept_event()
		return
	var track: MotionTrack = rows()[row]
	var cy := row_y(row) + (ROW_H - 12) * 0.5
	var in_row := pos.y >= cy - 2 and pos.y <= cy + 14
	if in_row and pos.x >= TOGGLE_X.x and pos.x <= TOGGLE_X.y:
		track_enable_toggled.emit(track, not track.enabled)
	elif in_row and pos.x >= SOLO_X.x and pos.x <= SOLO_X.y:
		track_solo_toggled.emit(track, not track.solo)
	elif in_row and pos.x >= LOCK_X.x and pos.x <= LOCK_X.y:
		track_lock_toggled.emit(track, not track.locked)
	else:
		# Select the whole track's keys, and arm a reorder drag.
		var entries: Array[Dictionary] = []
		if event.shift_pressed:
			entries = view.get_selection()
		for key in track.get_valid_keys():
			entries.append({"track": track, "key": key})
		view.set_entries(entries)
		_drag_mode = DragMode.ROW
		_drag_origin = pos
		_drag_row_track = track
		_drag_row_to = row
		_drag_moved = false
	queue_redraw()
	accept_event()


func _press_ruler(pos: Vector2) -> void:
	var edge := _region_edge_at(pos)
	if edge != 0:
		_drag_mode = DragMode.REGION
		_region_edge = edge
		accept_event()
		return

	var marker := _marker_at(pos)
	if marker != null:
		var now := Time.get_ticks_msec()
		if marker == _drag_marker and now - _last_click_msec < 400:
			marker_double_clicked.emit(marker)
			_drag_marker = null
			accept_event()
			return
		_last_click_msec = now
		_drag_mode = DragMode.MARKER
		_drag_marker = marker
		_drag_marker_start = marker.time
		accept_event()
		return

	_drag_mode = DragMode.SCRUB
	_set_playhead_from_x(pos.x)
	accept_event()


func _press_lane(pos: Vector2, event: InputEventMouseButton) -> void:
	var hit := _key_at(pos)
	if hit.is_empty():
		# Empty lane space starts a box select rather than only clearing.
		_drag_mode = DragMode.BOX
		_drag_origin = pos
		_box_end = pos
		_box_additive = event.shift_pressed or event.is_command_or_control_pressed()
		if not _box_additive:
			view.clear()
		accept_event()
		return

	var now := Time.get_ticks_msec()
	if hit["key"] == _last_click_key and now - _last_click_msec < 400:
		key_double_clicked.emit(hit["track"], hit["key"])
		_last_click_key = null
		accept_event()
		return
	_last_click_key = hit["key"]
	_last_click_msec = now

	if not view.is_selected(hit["key"]):
		view.select(hit["track"], hit["key"], event.shift_pressed)
	_begin_key_drag(pos)
	accept_event()


func _handle_motion(event: InputEventMouseMotion) -> void:
	match _drag_mode:
		DragMode.SCRUB:
			_set_playhead_from_x(event.position.x)
			accept_event()
		DragMode.PAN:
			view.pan_time = maxf(0.0, _drag_start_pan - (event.position.x - _drag_origin.x) / view.pixels_per_second)
			view.v_offset = clampf(view.v_offset - event.relative.y, 0.0, max_v_offset())
			view.notify_view_changed()
			queue_redraw()
			accept_event()
		DragMode.KEYS:
			_drag_keys(event)
			accept_event()
		DragMode.BOX:
			_box_end = event.position
			_apply_box()
			queue_redraw()
			accept_event()
		DragMode.MARKER:
			var t := maxf(0.0, x_to_time(event.position.x))
			if view.snap_enabled and not event.ctrl_pressed:
				t = timeline.snap_to_frame(t)
			_drag_marker.time = t
			_drag_moved = true
			queue_redraw()
			accept_event()
		DragMode.ROW:
			# Below the last row is a legitimate target — "move to the end" —
			# not a miss to be ignored.
			var row := _row_at(event.position)
			if row < 0 and event.position.y > RULER_H \
					and event.position.y + view.v_offset - RULER_H > content_height():
				row = rows().size()
			if row >= 0 and row != _drag_row_to:
				_drag_row_to = row
				_drag_moved = true
				queue_redraw()
			accept_event()
		DragMode.REGION:
			var rt := maxf(0.0, x_to_time(event.position.x))
			if view.snap_enabled and not event.ctrl_pressed:
				rt = timeline.snap_to_frame(rt)
			if _region_edge == 1:
				timeline.loop_region_start = minf(rt, timeline.loop_region_end - 0.01)
			else:
				timeline.loop_region_end = maxf(rt, timeline.loop_region_start + 0.01)
			_drag_moved = true
			queue_redraw()
			accept_event()


func _drag_keys(event: InputEventMouseMotion) -> void:
	var delta := (event.position.x - _drag_origin.x) / view.pixels_per_second
	if absf(event.position.x - _drag_origin.x) > 2.0:
		_drag_moved = true
	var selection := view.get_selection()
	for i in range(selection.size()):
		var track: MotionTrack = selection[i]["track"]
		if track.locked:
			continue
		var key: MotionKey = selection[i]["key"]
		var target := _drag_start_times[i] + delta
		if view.snap_enabled and not event.ctrl_pressed:
			# Snap in timeline space so an offset track still lands on frames.
			target = timeline.snap_to_frame(target + track.time_offset) - track.time_offset
		key.time = maxf(0.0, target)
	for track in view.selected_tracks():
		track.sort_keys()
	queue_redraw()


func _apply_box() -> void:
	var rect := _box_rect()
	var entries: Array[Dictionary] = []
	if _box_additive:
		entries = view.get_selection()
	var track_rows := rows()
	for i in range(track_rows.size()):
		var track: MotionTrack = track_rows[i]
		var mid := row_y(i) + ROW_H * 0.5
		if mid < rect.position.y or mid > rect.end.y:
			continue
		for key in track.get_valid_keys():
			var x := time_to_x(key.time + track.time_offset)
			if x < rect.position.x or x > rect.end.x:
				continue
			var already := false
			for entry in entries:
				if entry["key"] == key:
					already = true
					break
			if not already:
				entries.append({"track": track, "key": key})
	view.set_entries(entries)


func _begin_key_drag(pos: Vector2) -> void:
	_drag_mode = DragMode.KEYS
	_drag_origin = pos
	_drag_moved = false
	_drag_start_times.clear()
	for entry in view.get_selection():
		_drag_start_times.append((entry["key"] as MotionKey).time)


## Ends the gesture. Key drags report as one batch so the panel can register a
## single undo step for the whole move.
func _finish_drag() -> void:
	match _drag_mode:
		DragMode.KEYS:
			if _drag_moved:
				_emit_key_move()
		DragMode.MARKER:
			if _drag_moved and _drag_marker != null:
				marker_moved.emit(_drag_marker, _drag_marker_start, _drag_marker.time)
				timeline.sort_markers()
		DragMode.ROW:
			if _drag_moved and _drag_row_track != null:
				# Resolve the row to the track it names before leaving this
				# script — row indices mean nothing to the timeline.
				var order := rows()
				var before: MotionTrack = order[_drag_row_to] if _drag_row_to >= 0 and _drag_row_to < order.size() else null
				if before != _drag_row_track:
					tracks_reordered.emit(_drag_row_track, before)
		DragMode.REGION:
			if _drag_moved:
				loop_region_changed.emit(timeline.loop_region_start, timeline.loop_region_end)
	_drag_mode = DragMode.NONE
	_drag_moved = false
	_drag_row_track = null
	_drag_row_to = -1
	queue_redraw()


func _emit_key_move() -> void:
	var tracks: Array = []
	var keys: Array = []
	var old_times: Array = []
	var new_times: Array = []
	var selection := view.get_selection()
	for i in range(selection.size()):
		var key: MotionKey = selection[i]["key"]
		if i >= _drag_start_times.size() or is_equal_approx(key.time, _drag_start_times[i]):
			continue
		tracks.append(selection[i]["track"])
		keys.append(key)
		old_times.append(_drag_start_times[i])
		new_times.append(key.time)
	if not keys.is_empty():
		keys_dragged.emit(tracks, keys, old_times, new_times)


func _set_playhead_from_x(x: float) -> void:
	var t := maxf(0.0, x_to_time(x))
	if view.snap_enabled:
		t = timeline.snap_to_frame(t)
	view.playhead = clampf(t, 0.0, timeline.duration)


## Fits the authored duration to the visible lane width.
func zoom_to_fit() -> void:
	if timeline == null:
		return
	var lane_w := lane_width() - 4.0
	view.pixels_per_second = clampf(lane_w / maxf(0.1, timeline.duration), view.MIN_PPS, view.MAX_PPS)
	view.pan_time = 0.0
	view.notify_view_changed()
	queue_redraw()


## Fits the selected keys, or everything when nothing is selected.
func zoom_to_selection() -> void:
	if timeline == null:
		return
	var selection := view.get_selection()
	if selection.size() < 2:
		zoom_to_fit()
		return
	var low := INF
	var high := -INF
	for entry in selection:
		var t: float = (entry["key"] as MotionKey).time + (entry["track"] as MotionTrack).time_offset
		low = minf(low, t)
		high = maxf(high, t)
	var span := maxf(0.05, high - low)
	var lane_w := lane_width() - 4.0
	view.pixels_per_second = clampf(lane_w / (span * 1.15), view.MIN_PPS, view.MAX_PPS)
	view.pan_time = maxf(0.0, low - span * 0.075)
	view.notify_view_changed()
	queue_redraw()
