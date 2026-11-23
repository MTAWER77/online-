@tool
@icon("res://addons/godotion/icons/motion_track.svg")
class_name MotionTrack
extends Resource

## One animated property on one node.
##
## A track owns a time-sorted list of [MotionKey]s and knows how to sample
## itself at an arbitrary time. Tracks never touch the scene directly — that is
## [MotionPlayer]'s job — which keeps them usable from the editor panel and at
## runtime with identical results.

## Semantic grouping, used purely for the timeline's accent colouring.
enum Kind {
	TRANSFORM,
	ROTATION,
	SCALE,
	COLOR,
	OPACITY,
	CUSTOM,
	TRIGGER,
}

## What the track does to its node.
enum Mode {
	## Sample the track and write the result into [member property] every frame.
	PROPERTY,
	## Call the method named by [member property] once, as the playhead crosses
	## each key. Nothing is written and nothing is interpolated.
	TRIGGER,
}

## Whether this track writes a property or fires a method.
##
## A [constant Mode.TRIGGER] track is the only kind whose effect depends on the
## playhead *moving*: sampling it at a time tells you nothing, so [MotionPlayer]
## evaluates it by edge detection instead of by [method sample]. See
## [method collect_triggers].
@export var mode: Mode = Mode.PROPERTY:
	set(v):
		mode = v
		_kind_cache = -1
		_path_cache = NodePath()
		emit_changed()

## Path to the animated node, relative to [member MotionPlayer.root_node].
@export var node_path: NodePath = NodePath():
	set(v):
		node_path = v
		emit_changed()

## Property to drive. Sub-properties use Godot's colon syntax, e.g.
## [code]position:x[/code] or [code]modulate:a[/code].
##
## On a [constant Mode.TRIGGER] track this names a *method* to call instead —
## [code]play[/code] for an [AudioStreamPlayer], say. The colon syntax does not
## apply; the method is looked up on the resolved node itself.
@export var property: String = "":
	set(v):
		property = v
		_kind_cache = -1
		_path_cache = NodePath()
		emit_changed()

@export var enabled: bool = true:
	set(v):
		enabled = v
		emit_changed()

## Locked tracks are evaluated normally but refuse every edit made through the
## editor — dragging, deleting, auto-key capture.
@export var locked: bool = false:
	set(v):
		locked = v
		emit_changed()

## When any track in a timeline is soloed, only soloed tracks are applied.
@export var solo: bool = false:
	set(v):
		solo = v
		emit_changed()

## Shifts this track in time without moving its keys, which is what staggering
## a set of otherwise identical tracks needs. Positive values delay the track.
@export var time_offset: float = 0.0:
	set(v):
		time_offset = v
		emit_changed()

## Time-sorted keys. Prefer [method add_key] over mutating this directly so the
## ordering invariant holds.
##
## May contain [code]null[/code] holes: adding an element in the inspector
## creates an empty slot before the user assigns a resource to it. Read through
## [method get_valid_keys] rather than iterating this directly.
@export var keys: Array[MotionKey] = []:
	set(v):
		keys = v
		sort_keys()

## Overrides the auto-detected [enum Kind] when set to a valid value.
@export var kind_override: int = -1:
	set(v):
		kind_override = v
		_kind_cache = -1
		emit_changed()

var _kind_cache: int = -1
## Null-free, time-sorted view of [member keys], rebuilt on every mutation so
## sampling never pays for filtering.
var _valid_keys: Array[MotionKey] = []
## [member property] as a [NodePath], built once. [MotionPlayer] resolves this
## for every active track every frame; constructing it there allocated per frame.
var _path_cache: NodePath = NodePath()


## [member property] as the [NodePath] that [method Object.get_indexed] wants.
## Cached, so per-frame evaluation does not rebuild it.
func get_property_path() -> NodePath:
	if _path_cache.is_empty() and not property.is_empty():
		_path_cache = NodePath(property)
	return _path_cache


## Returns a [enum Kind] value. Typed as [int] because GDScript rejects casting
## a stored integer back into an enum type.
func get_kind() -> int:
	if kind_override >= 0:
		return kind_override
	# Mode wins over the name: a trigger track called "play" would otherwise
	# detect as CUSTOM and draw like an ordinary property track.
	if mode == Mode.TRIGGER:
		return Kind.TRIGGER
	if _kind_cache < 0:
		_kind_cache = _detect_kind(property)
	return _kind_cache


func is_trigger() -> bool:
	return mode == Mode.TRIGGER


static func _detect_kind(prop: String) -> int:
	var p := prop.to_lower()
	if p.begins_with("rotation") or p.contains("quaternion"):
		return Kind.ROTATION
	if p.begins_with("scale"):
		return Kind.SCALE
	if p == "modulate:a" or p == "self_modulate:a" or p.ends_with("alpha") or p.ends_with("opacity"):
		return Kind.OPACITY
	if p.contains("modulate") or p.contains("color"):
		return Kind.COLOR
	if p.begins_with("position") or p.begins_with("global_position") \
			or p.begins_with("offset") or p.begins_with("transform") or p.begins_with("skew"):
		return Kind.TRANSFORM
	return Kind.CUSTOM


func get_display_name() -> String:
	var node_name := String(node_path).get_file()
	if node_name.is_empty():
		node_name = "(root)"
	return node_name


## Null-free, time-sorted keys. Always read through this rather than
## [member keys], which may contain inspector-created holes.
func get_valid_keys() -> Array[MotionKey]:
	return _valid_keys


## Keeps [member keys] ordered by time and refreshes the null-free view.
## Called automatically by the mutators.
##
## Also re-subscribes to each key's [signal Resource.changed] — mirroring what
## [MotionTimeline] does for its tracks — so an edit to a key's value, time or
## interpolation propagates up to the panel and repaints it. Subscriptions are
## dropped first: a key removed from the array must stop repainting this track,
## and a stale connection also keeps the key alive.
func sort_keys() -> void:
	for key in _valid_keys:
		if key != null and key.changed.is_connected(_on_key_changed):
			key.changed.disconnect(_on_key_changed)
	keys.sort_custom(_compare_keys)
	_valid_keys = []
	for key in keys:
		if key == null:
			continue
		_valid_keys.append(key)
		if not key.changed.is_connected(_on_key_changed):
			key.changed.connect(_on_key_changed)
	emit_changed()


func _on_key_changed() -> void:
	emit_changed()


## Sorts by time, with null holes pushed to the end so they never get
## dereferenced mid-sort.
static func _compare_keys(a: MotionKey, b: MotionKey) -> bool:
	if a == null:
		return false
	if b == null:
		return true
	return a.time < b.time


func add_key(key: MotionKey) -> int:
	keys.append(key)
	sort_keys()
	return keys.find(key)


## Inserts a key at [param time], replacing any existing key within
## [param epsilon] seconds. Returns the key that now occupies that slot.
func set_key(time: float, value: Variant, interp: int = MotionKey.Interp.LINEAR, epsilon: float = 0.0005) -> MotionKey:
	var existing := find_key_at(time, epsilon)
	if existing != null:
		existing.value = value
		existing.interp = interp
		emit_changed()
		return existing
	var key := MotionKey.new()
	key.time = time
	key.value = value
	key.interp = interp
	add_key(key)
	return key


func find_key_at(time: float, epsilon: float = 0.0005) -> MotionKey:
	for key in _valid_keys:
		if absf(key.time - time) <= epsilon:
			return key
	return null


func remove_key(key: MotionKey) -> bool:
	var idx := keys.find(key)
	if idx < 0:
		return false
	keys.remove_at(idx)
	# sort_keys rebuilds the null-free view (and emits changed). Without it the
	# removed key keeps being drawn and sampled until some other mutation.
	sort_keys()
	return true


## Last keyed time, in timeline space (so [member time_offset] is included).
func get_length() -> float:
	if _valid_keys.is_empty():
		return 0.0
	return _valid_keys[_valid_keys.size() - 1].time + time_offset


## Smallest and largest keyed value, used by the curve view to scale its
## vertical axis. Returns [code]Vector2.ZERO[/code] when no key holds a number,
## which is indistinguishable from a genuine 0..0 range — gate on
## [method is_curve_editable] first rather than reading meaning into the zero.
func get_value_range() -> Vector2:
	var low := INF
	var high := -INF
	for key in _valid_keys:
		var v: Variant = key.value
		if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
			continue
		low = minf(low, float(v))
		high = maxf(high, float(v))
	if low > high:
		return Vector2.ZERO
	return Vector2(low, high)


## True when this track's value type can be drawn on the curve view.
func is_curve_editable() -> bool:
	# A trigger key's value is a call argument, not a position on a curve. Even
	# an all-float trigger track has no meaningful vertical axis.
	if mode == Mode.TRIGGER:
		return false
	for key in _valid_keys:
		var t := typeof(key.value)
		if t != TYPE_FLOAT and t != TYPE_INT:
			return false
	return not _valid_keys.is_empty()


## Samples the track. Returns [code]null[/code] when the track has no keys, so
## callers can distinguish "no opinion" from a keyed [code]0[/code].
##
## [param time] is timeline time; [member time_offset] is applied here so every
## caller — player, preview and curve view — staggers identically.
func sample(time: float) -> Variant:
	# Triggers have no value at a time, only at a crossing. Returning null keeps
	# every existing caller — player, preview, curve view — correct by default
	# rather than by remembering to check the mode.
	if mode == Mode.TRIGGER:
		return null
	time -= time_offset
	if _valid_keys.is_empty():
		return null
	if _valid_keys.size() == 1 or time <= _valid_keys[0].time:
		return _valid_keys[0].value
	var last := _valid_keys[_valid_keys.size() - 1]
	if time >= last.time:
		return last.value

	var idx := _segment_index(time)
	var from_key := _valid_keys[idx]
	var to_key := _valid_keys[idx + 1]
	var span := to_key.time - from_key.time
	if span <= 0.0:
		return to_key.value

	var t := (time - from_key.time) / span
	var weight: float
	if from_key.interp == MotionKey.Interp.BEZIER:
		var out_h := Vector2(from_key.out_handle.x / span, from_key.out_handle.y)
		var in_h := Vector2(to_key.in_handle.x / span, to_key.in_handle.y)
		weight = MotionEasing.bezier_weight(out_h, in_h, t)
	else:
		weight = MotionEasing.apply(from_key.interp, t)
	return interpolate_values(from_key.value, to_key.value, weight)


## Keys crossed by moving the playhead from [param from] to [param to], in time
## order. Both bounds are timeline time; [member time_offset] is applied here,
## exactly as [method sample] does it, so a staggered trigger track fires on the
## same beat its keys are drawn at.
##
## The interval is half-open — [code](from, to][/code] — which is what makes a
## cue fire once and only once. A closed interval would re-fire the key sitting
## exactly on the playhead every frame the playhead did not move; an open one
## would drop any key landing precisely on a frame boundary, which is where
## snapped keys land essentially always.
##
## Returns empty when [param to] is not greater than [param from], so seeking
## backwards is silent rather than firing everything in reverse.
func collect_triggers(from: float, to: float) -> Array[MotionKey]:
	var out: Array[MotionKey] = []
	if mode != Mode.TRIGGER or to <= from:
		return out
	var local_from := from - time_offset
	var local_to := to - time_offset
	for key in _valid_keys:
		if key.time > local_from and key.time <= local_to:
			out.append(key)
	return out


## Binary search for the key index whose segment contains [param time].
func _segment_index(time: float) -> int:
	var low := 0
	var high := _valid_keys.size() - 1
	while low < high - 1:
		var mid := (low + high) / 2
		if _valid_keys[mid].time <= time:
			low = mid
		else:
			high = mid
	return low


## Type-aware interpolation. Discrete types snap at the halfway point rather
## than erroring, which keeps bool/String properties usable on a track.
static func interpolate_values(a: Variant, b: Variant, weight: float) -> Variant:
	if typeof(a) != typeof(b):
		return b if weight >= 1.0 else a
	match typeof(a):
		TYPE_FLOAT:
			return lerpf(a, b, weight)
		TYPE_INT:
			return int(roundf(lerpf(float(a), float(b), weight)))
		TYPE_VECTOR2:
			return (a as Vector2).lerp(b, weight)
		TYPE_VECTOR3:
			return (a as Vector3).lerp(b, weight)
		TYPE_VECTOR4:
			return (a as Vector4).lerp(b, weight)
		TYPE_VECTOR2I:
			return Vector2i((a as Vector2i as Vector2).lerp(b as Vector2i as Vector2, weight).round())
		TYPE_VECTOR3I:
			return Vector3i((a as Vector3i as Vector3).lerp(b as Vector3i as Vector3, weight).round())
		TYPE_VECTOR4I:
			return Vector4i((a as Vector4i as Vector4).lerp(b as Vector4i as Vector4, weight).round())
		TYPE_RECT2:
			var ra := a as Rect2
			var rb := b as Rect2
			return Rect2(ra.position.lerp(rb.position, weight), ra.size.lerp(rb.size, weight))
		TYPE_BASIS:
			return (a as Basis).slerp(b, weight)
		TYPE_COLOR:
			return (a as Color).lerp(b, weight)
		TYPE_QUATERNION:
			return (a as Quaternion).slerp(b, weight)
		TYPE_TRANSFORM2D:
			return (a as Transform2D).interpolate_with(b, weight)
		TYPE_TRANSFORM3D:
			return (a as Transform3D).interpolate_with(b, weight)
	return b if weight >= 0.5 else a


## Deep copy, including the keys. Every authored field comes along — dropping
## [member time_offset] in particular defeated the main reason to duplicate a
## track at all, which is staggering an otherwise identical one.
func duplicate_track() -> MotionTrack:
	var copy := MotionTrack.new()
	copy.mode = mode
	copy.node_path = node_path
	copy.property = property
	copy.enabled = enabled
	copy.locked = locked
	copy.solo = solo
	copy.time_offset = time_offset
	copy.kind_override = kind_override
	var new_keys: Array[MotionKey] = []
	for key in _valid_keys:
		new_keys.append(key.duplicate_key())
	copy.keys = new_keys
	return copy
