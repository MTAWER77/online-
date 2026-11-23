@tool
class_name PeregrineFooterMeta
extends Control

## The two strips of metadata along the bottom edge.
##
## Static in the reference — no [Sequence] wraps it, so it is on screen for the
## whole nine seconds. It gets no tracks by default, but it is a plain [Control]
## with a `modulate` like everything else, so adding one is a right-click.

@export var left_text: String = "Order Falconiformes":
	set(v):
		left_text = v
		_push_text()

@export var right_text: String = "Global range":
	set(v):
		right_text = v
		_push_text()

@export var corner_text: String = "09.00 sec / Field study":
	set(v):
		corner_text = v
		_push_text()

@export var muted: Color = Color("b7b9ba"):
	set(v):
		muted = v
		_push_text()

@export var coral: Color = Color("ff6f43"):
	set(v):
		coral = v
		queue_redraw()

const DOT_RADIUS := 2.0
## Gap either side of the separator dot, matching the reference's `gap-5`.
const GAP := 20.0


func _ready() -> void:
	_push_text()


## The coral separator between the two left-hand strings. Drawn here rather than
## given a node of its own because its position depends on where the left label
## ends, which a node would have to be kept in sync with by hand.
func _draw() -> void:
	var left: Label = get_node_or_null("Left")
	if left == null:
		return
	var x := left.position.x + left.size.x + GAP
	draw_circle(Vector2(x, left.position.y + left.size.y * 0.5), DOT_RADIUS, coral)


func _push_text() -> void:
	# Only the left string is shrink-wrapped. `Corner` is a full-width,
	# right-aligned label — calling reset_size() on it collapses that width to
	# the text, and the right alignment then has nothing to align against, so
	# all three strings pile up in the same place at x=0.
	_set_label("Left", left_text.to_upper(), Color(muted, 0.7), true)
	_set_label("Right", right_text.to_upper(), Color(muted, 0.7), true)
	_set_label("Corner", corner_text.to_upper(), Color(1, 1, 1, 0.45), false)
	# Reflow rather than trusting authored offsets: editing `left_text` in the
	# inspector has to move the dot and the right-hand string with it, or the
	# footer is the one part of the card that cannot actually be edited freely.
	var left: Label = get_node_or_null("Left")
	var right: Label = get_node_or_null("Right")
	if left != null and right != null:
		right.position.x = left.position.x + left.size.x + GAP * 2.0
	queue_redraw()


func _set_label(path: String, value: String, color: Color, shrink: bool) -> void:
	var label: Label = get_node_or_null(path)
	if label == null:
		return
	label.text = value
	label.add_theme_color_override("font_color", color)
	if shrink:
		label.reset_size()
