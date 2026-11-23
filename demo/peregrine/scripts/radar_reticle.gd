@tool
class_name PeregrineRadarReticle
extends Control

## The sweep behind the stat panel: three concentric rings, a crosshair, and a
## rotating spoke that fades along its length.
##
## [member rotation_angle] is in degrees and is animated across the whole nine
## seconds — the only track in the demo with no start or end beat, which is why
## it reads as ambient rather than as an event. Kept as a separate float from
## the node's own `rotation` so rotating the *sweep* never rotates the rings.

@export_range(-360.0, 360.0, 0.1) var rotation_angle: float = -38.0:
	set(v):
		rotation_angle = v
		queue_redraw()

@export var ring_color: Color = Color("87ceeb"):
	set(v):
		ring_color = v
		queue_redraw()

@export var sweep_color: Color = Color("ff6f43"):
	set(v):
		sweep_color = v
		queue_redraw()

@export_range(0.0, 1.0, 0.01) var outer_ring_opacity: float = 0.14:
	set(v):
		outer_ring_opacity = v
		queue_redraw()

@export_range(0.0, 1.0, 0.01) var inner_ring_opacity: float = 0.10:
	set(v):
		inner_ring_opacity = v
		queue_redraw()

@export_range(0.0, 1.0, 0.01) var sweep_opacity: float = 0.55:
	set(v):
		sweep_opacity = v
		queue_redraw()

## Inset of each successive ring, matching the reference's `inset-20` / `inset-40`.
const RING_INSETS := [0.0, 80.0, 160.0]
## Segments in the fading spoke. Enough that the falloff reads as a gradient
## rather than as bands at this size.
const SWEEP_SEGMENTS := 24


func _draw() -> void:
	var center := size * 0.5
	var radius := minf(size.x, size.y) * 0.5

	for i in range(RING_INSETS.size()):
		var r: float = radius - RING_INSETS[i]
		if r <= 0.0:
			continue
		var opacity := outer_ring_opacity if i == 0 else inner_ring_opacity
		draw_arc(center, r, 0.0, TAU, 96, Color(ring_color, opacity), 1.0, true)

	var cross := Color(ring_color, inner_ring_opacity)
	draw_line(Vector2(0.0, center.y), Vector2(size.x, center.y), cross, 1.0)
	draw_line(Vector2(center.x, 0.0), Vector2(center.x, size.y), cross, 1.0)

	# The spoke runs from the centre outward and fades to nothing. Drawn as
	# segments rather than one line so the alpha ramp survives — `draw_line`
	# takes a single colour, and a solid spoke is markedly harsher than the
	# reference's `to-transparent`.
	#
	# -90 deg puts zero at twelve o'clock, matching the CSS `origin-top` spoke
	# that rotates from straight up.
	var angle := deg_to_rad(rotation_angle - 90.0)
	var direction := Vector2(cos(angle), sin(angle))
	for i in range(SWEEP_SEGMENTS):
		var t0 := float(i) / SWEEP_SEGMENTS
		var t1 := float(i + 1) / SWEEP_SEGMENTS
		var alpha := sweep_opacity * (1.0 - t0)
		draw_line(center + direction * (radius * t0), center + direction * (radius * t1),
			Color(sweep_color, alpha), 1.5)
