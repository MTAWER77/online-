@tool
extends RefCounted

## Shared viewport and selection state for the timeline views.
##
## The dope sheet and the curve view are two Controls that must agree on zoom,
## pan, the playhead and what is selected — otherwise toggling between them
## loses the user's place. Both read and write this one object rather than
## trying to mirror each other's members.
##
## Deliberately editor-agnostic: no [EditorInterface], no undo. Mutations that
## need to be undoable still go through [code]timeline_panel.gd[/code].

signal selection_changed()
signal view_changed()
signal playhead_changed(time: float)

const MIN_PPS := 8.0
const MAX_PPS := 4000.0

## Pixels per second. Drives horizontal zoom.
var pixels_per_second: float = 120.0
## Time at the left edge of the lane area.
var pan_time: float = 0.0
## Vertical scroll of the track lanes, in pixels.
var v_offset: float = 0.0
var snap_enabled: bool = true

var playhead: float = 0.0:
	set(v):
		var clamped := maxf(0.0, v)
		if is_equal_approx(playhead, clamped):
			return
		playhead = clamped
		playhead_changed.emit(playhead)

## Selected keys as [code]{track, key}[/code] dictionaries.
var _selection: Array[Dictionary] = []


func notify_view_changed() -> void:
	view_changed.emit()


# -- selection ----------------------------------------------------------------

func get_selection() -> Array[Dictionary]:
	return _selection.duplicate()


func selection_size() -> int:
	return _selection.size()


func is_empty() -> bool:
	return _selection.is_empty()


func is_selected(key: MotionKey) -> bool:
	for entry in _selection:
		if entry["key"] == key:
			return true
	return false


## The single selected key, or null when the selection is empty or plural.
## Drives the inspector push, which can only show one resource.
func lone_key() -> MotionKey:
	if _selection.size() != 1:
		return null
	return _selection[0]["key"]


func clear() -> void:
	if _selection.is_empty():
		return
	_selection.clear()
	selection_changed.emit()


## Adds [param key], or removes it when [param additive] and already selected.
func select(track: MotionTrack, key: MotionKey, additive: bool) -> void:
	if not additive:
		_selection.clear()
	elif is_selected(key):
		for i in range(_selection.size()):
			if _selection[i]["key"] == key:
				_selection.remove_at(i)
				break
		selection_changed.emit()
		return
	_selection.append({"track": track, "key": key})
	selection_changed.emit()


## Replaces the selection wholesale. Used by box select and Select All.
func set_entries(entries: Array[Dictionary]) -> void:
	_selection = entries.duplicate()
	selection_changed.emit()


func add_entry(track: MotionTrack, key: MotionKey) -> void:
	if is_selected(key):
		return
	_selection.append({"track": track, "key": key})
	selection_changed.emit()


## Drops entries whose key is no longer in its track, which happens after an
## undo or a delete. Silent when nothing changed so it is safe to call often.
func prune() -> void:
	var kept: Array[Dictionary] = []
	for entry in _selection:
		var track: MotionTrack = entry["track"]
		if track != null and track.get_valid_keys().has(entry["key"]):
			kept.append(entry)
	if kept.size() == _selection.size():
		return
	_selection = kept
	selection_changed.emit()


## Distinct tracks touched by the selection.
func selected_tracks() -> Array[MotionTrack]:
	var out: Array[MotionTrack] = []
	for entry in _selection:
		var track: MotionTrack = entry["track"]
		if not out.has(track):
			out.append(track)
	return out


# -- coordinates --------------------------------------------------------------

func time_to_x(t: float, gutter: float) -> float:
	return gutter + (t - pan_time) * pixels_per_second


func x_to_time(x: float, gutter: float) -> float:
	return (x - gutter) / pixels_per_second + pan_time


func zoom_at(anchor_x: float, factor: float, gutter: float) -> void:
	var anchor_time := x_to_time(anchor_x, gutter)
	pixels_per_second = clampf(pixels_per_second * factor, MIN_PPS, MAX_PPS)
	pan_time = maxf(0.0, anchor_time - (anchor_x - gutter) / pixels_per_second)
	view_changed.emit()
