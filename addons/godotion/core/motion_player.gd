@tool
@icon("res://addons/godotion/icons/motion_player.svg")
class_name MotionPlayer
extends Node

## Runtime evaluator for a [MotionTimeline].
##
## Add one to your scene, assign a timeline, and every frame it resolves each
## track's node path relative to [member root_node] and writes the sampled
## value. Node resolution is cached; call [method invalidate_cache] if you
## reparent or rename animated nodes at runtime.

signal started()
signal finished()
signal looped()
## Emitted whenever the playhead moves, including editor scrubbing.
signal time_changed(time: float)
## Emitted as the playhead crosses a key on a [constant MotionTrack.Mode.TRIGGER]
## track, after the track's method has been called. Lets a scene react to a cue
## without the cue having to be a method call on the animated node itself.
signal trigger_fired(track: MotionTrack, key: MotionKey)

@export var timeline: MotionTimeline:
	set(v):
		if timeline == v:
			return
		timeline = v
		invalidate_cache()
		_time = 0.0
		_fired_through = -1.0
		update_configuration_warnings()

## Nodes in the timeline are resolved relative to this node. Defaults to the
## MotionPlayer's own parent, matching how AnimationPlayer behaves in practice.
@export var root_node: NodePath = NodePath(".."):
	set(v):
		root_node = v
		invalidate_cache()

## Play as soon as the node enters the tree (not in the editor).
@export var autoplay: bool = false

@export_range(0.0, 8.0, 0.01, "or_greater") var speed_scale: float = 1.0

## Apply values while stopped too. Useful for scrub-driven scenes.
@export var apply_when_stopped: bool = true

## Whether trigger tracks fire while the editor is *scrubbing*.
##
## Off by default, and deliberately so: a dope sheet full of sound cues turns
## every drag of the playhead into a burst of overlapping one-shots.
##
## This does not gate editor *playback*. Pressing Play in the Godotion panel
## arms triggers for the duration of the preview regardless — a preview that
## silently drops every cue is indistinguishable from broken audio, which is
## exactly how this read the first time someone pressed Play on a timeline with
## nine sound cues on it. See [method set_editor_triggers_armed].
@export var fire_triggers_in_editor: bool = false

var _time: float = 0.0
var _playing: bool = false
## Set by the editor panel while its preview is rolling. Deliberately not
## exported: this is transport state, not scene data, and persisting it would
## silently arm scrubbing in the next session.
var _editor_triggers_armed: bool = false
## Timeline position the trigger tracks have already been evaluated up to.
## Negative so that a key at exactly 0.0 is still inside the first half-open
## window and fires on the opening frame.
var _fired_through: float = -1.0
var _node_cache: Dictionary = {}
var _warned_paths: Dictionary = {}
## Argument count of each trigger track's method, probed once per track. Firing
## a no-arg method with an argument is a hard error in GDScript, so the arity
## has to be known before the first call rather than discovered by crashing.
var _trigger_arity: Dictionary = {}
## Properties already probed for existence, successes included, so a healthy
## track costs no extra lookup after the first frame.
var _probed_paths: Dictionary = {}
## Tracks already checked for a layout conflict, so the warning fires once.
var _checked_tracks: Dictionary = {}


func _ready() -> void:
	if Engine.is_editor_hint():
		set_process(false)
		return
	if autoplay and timeline != null:
		play()
	set_process(_playing)


func _process(delta: float) -> void:
	if not _playing or timeline == null:
		return
	_time += delta * speed_scale

	if timeline.is_finished(_time):
		# The end of the *play range*, which is the loop region when one is set —
		# parking on `duration` left the playhead outside the range it just played.
		_time = timeline.get_play_range().y
		apply_at(_time)
		stop(false)
		time_changed.emit(_time)
		finished.emit()
		return

	# Wrapping is done here, not only inside apply_at: leaving _time to grow
	# without bound made get_time() meaningless on a looping timeline and let
	# `looped` fire only on the first crossing, never once per cycle.
	var cycle := timeline.get_cycle(_time)
	_time = timeline.wrap_time(_time)
	apply_at(_time)
	time_changed.emit(_time)
	if cycle > 0:
		looped.emit()


## Current playhead position in seconds.
func get_time() -> float:
	return _time


func is_playing() -> bool:
	return _playing


func play(from: float = -1.0) -> void:
	if timeline == null:
		push_warning("MotionPlayer '%s' has no timeline assigned." % name)
		return
	# Clamped into the play range so a loop region cannot start out of bounds,
	# which would otherwise register as a completed cycle on the first frame.
	var range_ := timeline.get_play_range()
	_time = clampf(from if from >= 0.0 else _time, range_.x, range_.y)
	# Arm the trigger window just behind the start, so a cue sitting exactly on
	# the first frame fires — without reaching back over cues that starting
	# mid-timeline deliberately skipped.
	_fired_through = _time - WRAP_EPSILON
	_playing = true
	set_process(true)
	started.emit()


func pause() -> void:
	_playing = false
	set_process(false)


## Stops playback. [param reset] rewinds to the start of the play range — the
## loop region's start when one is active, not necessarily zero.
func stop(reset: bool = true) -> void:
	_playing = false
	set_process(false)
	if reset:
		_time = timeline.get_play_range().x if timeline != null else 0.0
		# Close the trigger window on the new position first. Rewinding is not a
		# performance, so a cue parked at the start must not sound on Stop.
		_fired_through = _time
		if apply_when_stopped:
			apply_at(_time)


## Moves the playhead without changing the play state. Clamped to the play
## range, so seeking on a region-limited timeline cannot land outside it.
func seek(time: float, apply: bool = true) -> void:
	if timeline == null:
		return
	var range_ := timeline.get_play_range()
	_time = clampf(time, range_.x, range_.y)
	# A seek is a jump, not a traversal: it must not fire every cue it flew over.
	# Closing the window on the destination before applying makes the jump silent
	# in both directions, while leaving playback from here onward correct.
	_fired_through = _time
	if apply and (apply_when_stopped or _playing):
		apply_at(_time)
	time_changed.emit(_time)


## Writes every enabled track's sampled value into the scene.
func apply_at(time: float) -> void:
	if timeline == null:
		return
	var root := _resolve_root()
	if root == null:
		return
	var local_time := timeline.wrap_time(time)
	# get_active_tracks resolves solo-over-enable, so the editor preview and the
	# runtime cannot disagree about which tracks are live.
	for track in timeline.get_active_tracks():
		var value: Variant = track.sample(local_time)
		if value == null:
			continue
		var node := _resolve_node(root, track.node_path)
		if node == null:
			continue
		_apply_value(node, track, value)
	# After the writes, so a cue that inspects the scene sees the pose it belongs
	# to rather than the previous frame's.
	_advance_triggers(root, local_time)


## Distance behind the playhead that the trigger window opens at, so a key
## landing exactly on a start boundary is still inside a half-open interval.
const WRAP_EPSILON := 0.000001


## Arms or disarms trigger firing for an editor preview.
##
## Called by the Godotion panel around its Play/Pause, so a preview sounds its
## cues while a scrub stays silent. [param from_time] is the position playback
## resumes at; the window opens just behind it, so a cue sitting exactly on the
## playhead sounds when you press Play on it — matching what [method play] does
## at runtime — without reaching back over cues you deliberately scrubbed past.
func set_editor_triggers_armed(armed: bool, from_time: float = -1.0) -> void:
	_editor_triggers_armed = armed
	if armed:
		_fired_through = (from_time if from_time >= 0.0 else _fired_through) - WRAP_EPSILON


## Fires every trigger key between [member _fired_through] and [param local_time],
## then closes the window on the new position.
func _advance_triggers(root: Node, local_time: float) -> void:
	if Engine.is_editor_hint() and not (fire_triggers_in_editor or _editor_triggers_armed):
		_fired_through = local_time
		return
	if local_time > _fired_through:
		_fire_window(root, _fired_through, local_time)
		_fired_through = local_time
		return
	if local_time < _fired_through:
		# Going backwards. Under LOOP that is a wrap mid-playback, and the cues
		# between the old position and the end still belong to the cycle that
		# just ended — so finish it, then open the next one at the range start.
		#
		# PING_PONG is excluded on purpose: it reverses rather than wraps, so the
		# same movement is a genuine backwards traversal with no cycle to flush.
		# Anything else backwards is a scrub, which stays silent.
		if _playing and timeline.loop_mode == MotionTimeline.LoopMode.LOOP:
			var range_ := timeline.get_play_range()
			_fire_window(root, _fired_through, range_.y)
			_fire_window(root, range_.x - WRAP_EPSILON, local_time)
		_fired_through = local_time


func _fire_window(root: Node, from: float, to: float) -> void:
	for track in timeline.get_active_tracks():
		if not track.is_trigger():
			continue
		var keys := track.collect_triggers(from, to)
		if keys.is_empty():
			continue
		var node := _resolve_node(root, track.node_path)
		if node == null:
			continue
		for key in keys:
			_fire(node, track, key)


func _fire(node: Node, track: MotionTrack, key: MotionKey) -> void:
	if not _trigger_arity.has(track):
		if not node.has_method(track.property):
			_trigger_arity[track] = -1
			push_warning("Godotion: node '%s' has no method '%s' to trigger." % [
				node.name, track.property])
		else:
			_trigger_arity[track] = _method_arity(node, track.property)
	var arity: int = _trigger_arity[track]
	if arity < 0:
		return
	# The key's value is an argument only where the method has somewhere to put
	# it — `AudioStreamPlayer.play(from_position)` takes one, `queue_free` takes
	# none, and passing one anyway is a hard error rather than a warning.
	if arity >= 1:
		node.call(track.property, key.value)
	else:
		node.call(track.property)
	trigger_fired.emit(track, key)


static func _method_arity(node: Node, method: String) -> int:
	for entry in node.get_method_list():
		if entry.name == method:
			return (entry.args as Array).size()
	return 0


func _apply_value(node: Node, track: MotionTrack, value: Variant) -> void:
	# set_indexed handles both plain properties and sub-paths like "position:x".
	# It fails silently on unknown paths, so we probe once and warn.
	#
	# "Once" means once: the cache used to record only failures, so a healthy
	# track re-ran get_indexed every frame forever. The path is cached on the
	# track for the same reason — building it here allocated per track per frame.
	var path := track.get_property_path()
	if not _probed_paths.has(track.property):
		_probed_paths[track.property] = true
		if node.get_indexed(path) == null:
			_warned_paths[track.property] = true
			push_warning("Godotion: node '%s' has no property '%s'." % [node.name, track.property])
	if _warned_paths.has(track.property):
		return
	if not _checked_tracks.has(track):
		_checked_tracks[track] = true
		var conflict := describe_layout_conflict(node, track.property)
		if not conflict.is_empty():
			push_warning("Godotion: %s" % conflict)
	node.set_indexed(path, value)


## Properties a [Container] overwrites on its children every layout pass.
const CONTAINER_MANAGED := ["position", "size", "offset_left", "offset_top",
	"offset_right", "offset_bottom", "global_position"]


## Explains why a track will visibly do nothing, or returns an empty string when
## there is no conflict.
##
## The case that matters: a [Control] parented to a [Container] has its position
## and size rewritten by the parent on every sort. Writing them from a track is
## not an error — the value lands and is then immediately overwritten — so it
## looks exactly like "the keyframes do nothing" with no message anywhere.
static func describe_layout_conflict(node: Node, property: String) -> String:
	var control := node as Control
	if control == null:
		return ""
	var base := property.get_slice(":", 0)
	if not CONTAINER_MANAGED.has(base):
		return ""
	var parent := control.get_parent() as Container
	if parent == null:
		return ""
	return ("'%s' is a Control inside %s '%s', which overwrites '%s' every layout pass. "
		+ "The track is being applied but the container immediately undoes it. "
		+ "Animate a wrapper node, or use scale/rotation/modulate instead.") % [
			control.name, parent.get_class(), parent.name, base]


func _resolve_root() -> Node:
	if root_node.is_empty():
		return self
	var node := get_node_or_null(root_node)
	if node == null and not _warned_paths.has("__root__"):
		_warned_paths["__root__"] = true
		push_warning("Godotion: MotionPlayer '%s' cannot resolve root_node '%s'." % [name, root_node])
	return node


func _resolve_node(root: Node, path: NodePath) -> Node:
	if _node_cache.has(path):
		var cached: Node = _node_cache[path]
		if is_instance_valid(cached):
			return cached
		_node_cache.erase(path)
	var node: Node = root if path.is_empty() else root.get_node_or_null(path)
	if node == null:
		if not _warned_paths.has(path):
			_warned_paths[path] = true
			push_warning("Godotion: cannot resolve animated node '%s' under '%s'." % [path, root.name])
		return null
	_node_cache[path] = node
	return node


## Drops cached node lookups. Call after reparenting animated nodes.
func invalidate_cache() -> void:
	_node_cache.clear()
	_warned_paths.clear()
	_probed_paths.clear()
	_checked_tracks.clear()
	_trigger_arity.clear()


func _get_configuration_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	if timeline == null:
		warnings.append("Assign a MotionTimeline resource to animate anything.")
	elif timeline.get_valid_tracks().is_empty():
		warnings.append("The assigned MotionTimeline has no tracks yet.")
	if root_node.is_empty():
		warnings.append("root_node is empty; animated node paths will resolve against the MotionPlayer itself.")
	elif get_node_or_null(root_node) == null:
		warnings.append("root_node '%s' does not resolve to a node." % root_node)
	return warnings
