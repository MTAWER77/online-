@tool
class_name PeregrineHeroTitle
extends Control

## The species name block: a gradient rule that wipes open, the display-weight
## common name, and the italic scientific name beneath it.
##
## [member line_width] is the wipe. Remotion animates the rule's CSS `width`
## from 0 to 152; here it is a float on this node, keyed the same way, and drawn
## in [method _draw] rather than sized on a child — a child's `size` is the kind
## of property a parent layout would fight over.

@export var common_name: String = "PEREGRINE FALCON":
	set(v):
		common_name = v
		_push_text()

@export var scientific_name: String = "Falco peregrinus":
	set(v):
		scientific_name = v
		_push_text()

## Width of the accent rule in pixels. Keyed 0 -> 152 over the title reveal.
@export_range(0.0, 400.0, 0.5) var line_width: float = 0.0:
	set(v):
		line_width = maxf(0.0, v)
		queue_redraw()

@export var line_height: float = 3.0:
	set(v):
		line_height = v
		queue_redraw()

@export var coral: Color = Color("ff6f43"):
	set(v):
		coral = v
		queue_redraw()

@export var sky: Color = Color("87ceeb"):
	set(v):
		sky = v
		queue_redraw()

@export var name_color: Color = Color("f4f2ed"):
	set(v):
		name_color = v
		_push_text()

@export var scientific_color: Color = Color("d8d9d7"):
	set(v):
		scientific_color = v
		_push_text()

## Line box of the common name, matching the `leading-[0.79]` the label is
## authored with. Used to reflow the scientific name under however many lines
## the name actually wraps to.
@export var name_line_height: float = 101.0:
	set(v):
		name_line_height = v
		_push_text()

## Gap between the two names, the reference's `mt-8`.
@export var scientific_gap: float = 32.0:
	set(v):
		scientific_gap = v
		_push_text()


func _ready() -> void:
	_push_text()


## coral -> sky -> transparent, the same three stops as the CSS gradient. Drawn
## as two rects because `draw_rect` takes one colour; a gradient texture would
## be a resource to keep in sync with two of the theme colours for no gain.
func _draw() -> void:
	if line_width <= 0.0:
		return
	var half := line_width * 0.5
	draw_rect(Rect2(0, 0, half, line_height), coral)
	draw_rect(Rect2(half, 0, half, line_height), sky)


func _push_text() -> void:
	var name_label: Label = get_node_or_null("CommonName")
	if name_label != null:
		name_label.text = common_name.to_upper()
		name_label.add_theme_color_override("font_color", name_color)
	var sci: Label = get_node_or_null("ScientificName")
	if sci != null:
		sci.text = scientific_name
		sci.add_theme_color_override("font_color", scientific_color)
	# Reflow under the actual line count. A fixed two-line offset is what the
	# layout numbers imply, but "PEREGRINE FALCON" fits on one line in this face
	# and the second line's worth of space then sits there as a hole — and any
	# shorter species name would open a bigger one.
	if name_label != null and sci != null:
		var lines := maxi(1, name_label.get_line_count())
		sci.position.y = name_label.position.y + lines * name_line_height + scientific_gap
