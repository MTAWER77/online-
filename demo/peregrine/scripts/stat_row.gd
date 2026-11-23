@tool
class_name PeregrineStatRow
extends Control

## A label, a value and a meter.
##
## [member progress_fill] is the property three of this demo's tracks exist to
## drive. It is a plain float on a plain [Control] — not a [Range], not a
## container child — precisely so a [MotionTrack] can reach it. The bar's shader
## reads it through [method _push_fill].

@export var label_text: String = "Top diving speed":
	set(v):
		label_text = v
		_push_text()

@export var value_text: String = "389 km/h":
	set(v):
		value_text = v
		_push_text()

## Current meter fill, 0..1. Keyed 0 -> the stat's `progress` over the reveal.
@export_range(0.0, 1.0, 0.001) var progress_fill: float = 0.0:
	set(v):
		progress_fill = clampf(v, 0.0, 1.0)
		_push_fill()

@export var label_color: Color = Color("e8e9e7"):
	set(v):
		label_color = v
		_push_text()

@export var value_color: Color = Color("bfeaff"):
	set(v):
		value_color = v
		_push_text()


func _ready() -> void:
	_push_text()
	_push_fill()


func _push_fill() -> void:
	var bar: ColorRect = get_node_or_null("Bar")
	if bar == null or bar.material == null:
		return
	(bar.material as ShaderMaterial).set_shader_parameter("fill_amount", progress_fill)


func _push_text() -> void:
	var label: Label = get_node_or_null("Label")
	if label != null:
		label.text = label_text.to_upper()
		label.add_theme_color_override("font_color", label_color)
	var value: Label = get_node_or_null("Value")
	if value != null:
		value.text = value_text
		value.add_theme_color_override("font_color", value_color)
