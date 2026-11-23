@tool
class_name MotionEasing
extends RefCounted

## Stateless easing helpers.
##
## Every function maps a normalised segment position [code]t[/code] in the range
## 0..1 to an eased weight, also in 0..1. Value interpolation is handled
## separately in [MotionTrack] so that the same curves apply to floats,
## vectors and colors alike.

## Maximum iterations used when solving a cubic bezier for X. Matches the
## precision Godot's own bezier tracks use closely enough for editor work.
const BEZIER_SOLVE_ITERATIONS := 12
const BEZIER_SOLVE_EPSILON := 0.00001


## Named bezier handle pairs, in the (seconds-fraction, value-fraction) space
## [MotionKey] stores handles in. Applying a preset sets the outgoing handle of
## the left key and the incoming handle of the right one, and switches the left
## key to [constant MotionKey.Interp.BEZIER].
##
## Values mirror the CSS timing functions of the same names, which is what
## motion designers expect these words to mean.
const PRESETS := {
	"Ease": [Vector2(0.25, 0.1), Vector2(-0.25, 0.0)],
	"Ease In": [Vector2(0.42, 0.0), Vector2(0.0, 0.0)],
	"Ease Out": [Vector2(0.0, 0.0), Vector2(-0.42, 0.0)],
	"Ease In Out": [Vector2(0.42, 0.0), Vector2(-0.42, 0.0)],
	"Quad In": [Vector2(0.55, 0.085), Vector2(-0.32, -0.09)],
	"Quad Out": [Vector2(0.25, 0.46), Vector2(-0.55, 0.06)],
	"Expo In": [Vector2(0.95, 0.05), Vector2(-0.205, -0.04)],
	"Expo Out": [Vector2(0.19, 1.0), Vector2(-0.78, 0.0)],
	"Back Out": [Vector2(0.175, 0.885), Vector2(-0.68, 0.28)],
	"Anticipate": [Vector2(0.6, -0.28), Vector2(-0.265, 1.55)],
	"Linear": [Vector2(0.333, 0.333), Vector2(-0.333, -0.333)],
}


## Preset names in a stable order, for populating a menu.
static func preset_names() -> PackedStringArray:
	var out := PackedStringArray()
	for key in PRESETS:
		out.append(key)
	return out


## Returns [out_handle, in_handle] for [param name], or an empty array.
static func preset(name: String) -> Array:
	return PRESETS.get(name, [])


static func apply(interp: int, t: float) -> float:
	var w := clampf(t, 0.0, 1.0)
	match interp:
		MotionKey.Interp.CONSTANT:
			return 0.0
		MotionKey.Interp.LINEAR:
			return w
		MotionKey.Interp.EASE_IN:
			return w * w * w
		MotionKey.Interp.EASE_OUT:
			var inv := 1.0 - w
			return 1.0 - inv * inv * inv
		MotionKey.Interp.EASE_IN_OUT:
			if w < 0.5:
				return 4.0 * w * w * w
			var f := -2.0 * w + 2.0
			return 1.0 - (f * f * f) / 2.0
	return w


## Evaluates a cubic bezier segment whose control points are expressed as
## offsets from the two surrounding keys, normalised to the segment.
##
## [param out_handle] is the outgoing handle of the left key and
## [param in_handle] the incoming handle of the right key. Both are stored in
## (time, value) space. Callers must normalise [code]x[/code] by the segment
## duration; [code]y[/code] is already a fraction of the segment's value delta
## and is used as-is, which is why the presets are authored as CSS-style
## fractions rather than in the property's own units.
static func bezier_weight(out_handle: Vector2, in_handle: Vector2, t: float) -> float:
	var p1 := Vector2(clampf(out_handle.x, 0.0, 1.0), out_handle.y)
	var p2 := Vector2(clampf(1.0 + in_handle.x, 0.0, 1.0), 1.0 + in_handle.y)
	var u := _solve_bezier_x(p1.x, p2.x, clampf(t, 0.0, 1.0))
	return _cubic(0.0, p1.y, p2.y, 1.0, u)


static func _cubic(p0: float, p1: float, p2: float, p3: float, u: float) -> float:
	var inv := 1.0 - u
	return inv * inv * inv * p0 \
		+ 3.0 * inv * inv * u * p1 \
		+ 3.0 * inv * u * u * p2 \
		+ u * u * u * p3


## Bisection solve of the bezier X polynomial. Bisection rather than Newton
## because handles can be authored flat, which drives the derivative to zero
## and makes Newton diverge.
static func _solve_bezier_x(p1x: float, p2x: float, target_x: float) -> float:
	var low := 0.0
	var high := 1.0
	var mid := target_x
	for _i in BEZIER_SOLVE_ITERATIONS:
		mid = (low + high) * 0.5
		var x := _cubic(0.0, p1x, p2x, 1.0, mid)
		var diff := x - target_x
		if absf(diff) < BEZIER_SOLVE_EPSILON:
			return mid
		if diff > 0.0:
			high = mid
		else:
			low = mid
	return mid
