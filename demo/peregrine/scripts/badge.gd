@tool
class_name PeregrineBadge
extends Control

## The "SPECIES UNLOCKED" pill: a translucent capsule, a coral status dot with a
## halo, and mono-spaced tracking-heavy text.
##
## Drawn rather than assembled from a [StyleBoxFlat] and child rects so every
## part of it — capsule fill, border, dot radius, halo spread — is a plain
## exported property, and therefore keyable. The halo in particular is worth
## animating; a static dot is the one part of the reference that reads as flat.

@export var text: String = "SPECIES UNLOCKED":
	set(v):
		text = v
		_push_text()

@export var surface: Color = Color("1b252a"):
	set(v):
		surface = v
		queue_redraw()

@export var border: Color = Color("87ceeb"):
	set(v):
		border = v
		queue_redraw()

@export var dot_color: Color = Color("ff6f43"):
	set(v):
		dot_color = v
		queue_redraw()

@export var text_color: Color = Color("e9f7ff"):
	set(v):
		text_color = v
		_push_text()

@export_range(0.0, 1.0, 0.01) var surface_opacity: float = 0.55:
	set(v):
		surface_opacity = v
		queue_redraw()

@export_range(0.0, 1.0, 0.01) var border_opacity: float = 0.45:
	set(v):
		border_opacity = v
		queue_redraw()

## Radius of the soft ring around the status dot. Keyable, so the badge can
## pulse on its cue instead of arriving inert.
@export_range(0.0, 24.0, 0.1) var dot_halo: float = 9.0:
	set(v):
		dot_halo = v
		queue_redraw()

@export_range(0.0, 1.0, 0.01) var dot_halo_opacity: float = 0.4:
	set(v):
		dot_halo_opacity = v
		queue_redraw()

const DOT_RADIUS := 6.0
const DOT_CENTER_X := 32.0


func _ready() -> void:
	_push_text()


func _draw() -> void:
	draw_style_box(_capsule(), Rect2(Vector2.ZERO, size))
	var center := Vector2(DOT_CENTER_X, size.y * 0.5)
	if dot_halo > DOT_RADIUS:
		draw_circle(center, dot_halo, Color(dot_color, dot_halo_opacity))
	draw_circle(center, DOT_RADIUS, dot_color)


func _capsule() -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = Color(surface, surface_opacity)
	box.border_color = Color(border, border_opacity)
	box.set_border_width_all(1)
	var radius := int(size.y * 0.5)
	box.set_corner_radius_all(radius)
	return box


func _push_text() -> void:
	var label: Label = get_node_or_null("Text")
	if label != null:
		label.text = text
		label.add_theme_color_override("font_color", text_color)
