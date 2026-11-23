@tool
@icon("res://addons/godotion/icons/motion_timeline.svg")
class_name MotionTimeline
extends Resource

## A saveable collection of [MotionTrack]s plus playback metadata.
##
## Save as a [code].tres[/code] next to your scene and point a [MotionPlayer]
## at it. The same resource is what the Godotion bottom panel edits.

enum LoopMode {
	NONE,
	LOOP,
	PING_PONG,
}

@export var timeline_name: String = "Timeline":
	set(v):
		timeline_name = v
		emit_changed()

## Authored length in seconds. Playback clamps to this even if keys extend
## past it, so shortening the timeline is non-destructive.
@export_range(0.1, 3600.0, 0.1, "or_greater") var duration: float = 5.0:
	set(v):
		duration = maxf(0.1, v)
		emit_changed()

## Frame rate used for snapping and ruler subdivisions in the editor.
@export_range(1, 240, 1) var fps: int = 60:
	set(v):
		fps = maxi(1, v)
		emit_changed()

@export var loop_mode: LoopMode = LoopMode.NONE:
	set(v):
		loop_mode = v
		emit_changed()

## May contain [code]null[/code] holes: adding an element in the inspector
## creates an empty slot before the user assigns a resource to it. Read through
## [method get_valid_tracks] rather than iterating this directly.
@export var tracks: Array[MotionTrack] = []:
	set(v):
		tracks = v
		_rebuild_valid_tracks()

## Named landmarks on the timeline. May contain [code]null[/code] holes for the
## same inspector reason as [member tracks]; read via [method get_valid_markers].
@export var markers: Array[MotionMarker] = []:
	set(v):
		markers = v
		sort_markers()

## Restricts preview and playback to a sub-range when [member loop_region_end]
## is greater than [member loop_region_start]. Authoring aid; playback honours
## it through [method wrap_time].
@export var loop_region_start: float = 0.0:
	set(v):
		loop_region_start = maxf(0.0, v)
		emit_changed()

@export var loop_region_end: float = 0.0:
	set(v):
		loop_region_end = maxf(0.0, v)
		emit_changed()

@export var loop_region_enabled: bool = false:
	set(v):
		loop_region_enabled = v
		emit_changed()

## Null-free view of [member tracks].
var _valid_tracks: Array[MotionTrack] = []
var _valid_markers: Array[MotionMarker] = []
## Cached result of [method get_active_tracks], which the player calls every
## frame. Invalidated by any change that could alter solo, enable or property.
var _active_cache: Array[MotionTrack] = []
var _active_dirty: bool = true


## Null-free tracks. Always read through this rather than [member tracks].
func get_valid_tracks() -> Array[MotionTrack]:
	return _valid_tracks


## Refreshes the null-free view and re-subscribes to each track's [signal
## Resource.changed], so edits made in the inspector propagate up to the panel.
## Subscriptions are dropped first: a track removed from the array must stop
## repainting this timeline, and a stale connection also keeps it alive.
func _rebuild_valid_tracks() -> void:
	for track in _valid_tracks:
		if track != null and track.changed.is_connected(_on_track_changed):
			track.changed.disconnect(_on_track_changed)
	_valid_tracks = []
	for track in tracks:
		if track == null:
			continue
		_valid_tracks.append(track)
		if not track.changed.is_connected(_on_track_changed):
			track.changed.connect(_on_track_changed)
	_active_dirty = true
	emit_changed()


func _on_track_changed() -> void:
	_active_dirty = true
	emit_changed()


## Null-free, time-sorted markers.
func get_valid_markers() -> Array[MotionMarker]:
	return _valid_markers


## Keeps [member markers] ordered by time and refreshes the null-free view.
func sort_markers() -> void:
	for marker in _valid_markers:
		if marker != null and marker.changed.is_connected(_on_track_changed):
			marker.changed.disconnect(_on_track_changed)
	markers.sort_custom(_compare_markers)
	_valid_markers = []
	for marker in markers:
		if marker == null:
			continue
		_valid_markers.append(marker)
		if not marker.changed.is_connected(_on_track_changed):
			marker.changed.connect(_on_track_changed)
	emit_changed()


static func _compare_markers(a: MotionMarker, b: MotionMarker) -> bool:
	if a == null:
		return false
	if b == null:
		return true
	return a.time < b.time


func add_marker(marker: MotionMarker) -> int:
	markers.append(marker)
	sort_markers()
	return markers.find(marker)


func remove_marker(marker: MotionMarker) -> bool:
	var idx := markers.find(marker)
	if idx < 0:
		return false
	markers.remove_at(idx)
	sort_markers()
	return true


## Nearest marker within [param epsilon] seconds of [param time], or null.
func get_marker_at(time: float, epsilon: float = 0.0005) -> MotionMarker:
	for marker in _valid_markers:
		if absf(marker.time - time) <= epsilon:
			return marker
	return null


## True when any track is soloed. While that holds, [MotionPlayer] applies only
## soloed tracks — the standard mixer convention.
func has_solo() -> bool:
	for track in _valid_tracks:
		if track.solo:
			return true
	return false


## Tracks that should actually be written this frame, honouring solo and enable.
##
## The result is cached: the player calls this every frame, and rebuilding an
## array per frame is pure garbage. Any track change invalidates it.
func get_active_tracks() -> Array[MotionTrack]:
	if not _active_dirty:
		return _active_cache
	var soloing := has_solo()
	var out: Array[MotionTrack] = []
	for track in _valid_tracks:
		if track.property.is_empty():
			continue
		if soloing:
			if track.solo:
				out.append(track)
		elif track.enabled:
			out.append(track)
	_active_cache = out
	_active_dirty = false
	return _active_cache


## Effective playback range: the loop region when one is active, else the whole
## authored duration.
func get_play_range() -> Vector2:
	if loop_region_enabled and loop_region_end > loop_region_start:
		return Vector2(loop_region_start, minf(loop_region_end, duration))
	return Vector2(0.0, duration)


func add_track(track: MotionTrack) -> int:
	tracks.append(track)
	_rebuild_valid_tracks()
	return tracks.size() - 1


func remove_track(track: MotionTrack) -> bool:
	var idx := tracks.find(track)
	if idx < 0:
		return false
	tracks.remove_at(idx)
	if track.changed.is_connected(_on_track_changed):
		track.changed.disconnect(_on_track_changed)
	_rebuild_valid_tracks()
	return true


## Moves a track within [member tracks]. Indices are into the raw array, holes
## included, and are clamped rather than rejected so a drag past either end
## lands sensibly.
func move_track(from_index: int, to_index: int) -> bool:
	if from_index < 0 or from_index >= tracks.size():
		return false
	var target := clampi(to_index, 0, tracks.size() - 1)
	if target == from_index:
		return false
	var track := tracks[from_index]
	tracks.remove_at(from_index)
	tracks.insert(target, track)
	_rebuild_valid_tracks()
	return true


## Raw index that [method move_track] needs in order to land [param track]
## immediately before [param before] — or at the end when [param before] is
## null. Returns -1 when the move is impossible or a no-op.
##
## This exists because the editor names a *track* to drop in front of, while
## [method move_track] splices raw indices. Converting between the two by hand
## in the UI meant a row number from the filtered, null-free view was fed to an
## array index, which reordered to the wrong slot whenever a filter was active
## or the array had a hole. The conversion belongs here, where it is testable.
func resolve_move_target(track: MotionTrack, before: MotionTrack) -> int:
	var from_index := tracks.find(track)
	if from_index < 0 or track == before:
		return -1
	var to_index := tracks.size() if before == null else tracks.find(before)
	if to_index < 0:
		return -1
	# move_track removes before it inserts, so everything past the source slides
	# down one: a target beyond the source has to come back by one to still land
	# in front of the track it names.
	if from_index < to_index:
		to_index -= 1
	to_index = clampi(to_index, 0, tracks.size() - 1)
	return -1 if to_index == from_index else to_index


func find_track(node_path: NodePath, property: String) -> MotionTrack:
	for track in _valid_tracks:
		if track.node_path == node_path and track.property == property:
			return track
	return null


## Returns the existing track for this node/property pair, creating it if
## needed. Does not push an undo step — callers in the editor must do that.
func get_or_create_track(node_path: NodePath, property: String) -> MotionTrack:
	var track := find_track(node_path, property)
	if track != null:
		return track
	track = MotionTrack.new()
	track.node_path = node_path
	track.property = property
	add_track(track)
	return track


## Longest keyed time across all tracks, ignoring [member duration].
func get_keyed_length() -> float:
	var longest := 0.0
	for track in _valid_tracks:
		longest = maxf(longest, track.get_length())
	return longest


func snap_to_frame(time: float) -> float:
	return roundf(time * float(fps)) / float(fps)


## Maps a raw playback position onto the timeline according to [member loop_mode],
## within the active play range (the loop region when one is set).
func wrap_time(time: float) -> float:
	if duration <= 0.0:
		return 0.0
	var range_ := get_play_range()
	var start := range_.x
	var span := range_.y - range_.x
	if span <= 0.0:
		return start
	match loop_mode:
		LoopMode.LOOP:
			return start + fposmod(time - start, span)
		LoopMode.PING_PONG:
			var cycle := fposmod(time - start, span * 2.0)
			return start + (cycle if cycle <= span else span * 2.0 - cycle)
	return clampf(time, start, range_.y)


## How many complete loop cycles have elapsed at [param time]. A [constant
## LoopMode.PING_PONG] cycle is one full there-and-back, so both looping modes
## count one cycle per return to the start — which is what [signal
## MotionPlayer.looped] means.
##
## Returns 0 for a non-looping timeline, and can go negative for a time before
## the play range starts.
func get_cycle(time: float) -> int:
	if loop_mode == LoopMode.NONE:
		return 0
	var range_ := get_play_range()
	var span := range_.y - range_.x
	if span <= 0.0:
		return 0
	if loop_mode == LoopMode.PING_PONG:
		span *= 2.0
	return floori((time - range_.x) / span)


## Returns [code]true[/code] once a non-looping timeline has run past its end.
func is_finished(time: float) -> bool:
	return loop_mode == LoopMode.NONE and time >= get_play_range().y
