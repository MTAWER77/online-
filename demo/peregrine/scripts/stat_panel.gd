@tool
class_name PeregrineStatPanel
extends Control

## The glass card on the right: header, four stat rows, and an index footer.
##
## This node is a plain [Control], not a [PanelContainer], and its children are
## absolutely positioned rather than laid out by a [VBoxContainer]. That is not
## an oversight — it is the single structural decision that makes the demo work.
## A [Control] inside a [Container] has its position rewritten every layout pass,
## so a track writing `position:y` lands and is immediately overwritten. Godot
## reports no error; the keys simply do nothing. [method
## MotionPlayer.describe_layout_conflict] exists to name that exact failure, and
## every animated node here stays out of its way by construction.

@export var eyebrow_text: String = "Flight performance":
	set(v):
		eyebrow_text = v
		_push_text()

@export var heading_text: String = "Apex profile":
	set(v):
		heading_text = v
		_push_text()

@export var monogram_text: String = "FP":
	set(v):
		monogram_text = v
		_push_text()

@export var index_label_text: String = "Biometric field index":
	set(v):
		index_label_text = v
		_push_text()

@export var index_code_text: String = "FAL-PER · 001":
	set(v):
		index_code_text = v
		_push_text()

@export var surface: Color = Color("15191b"):
	set(v):
		surface = v
		_push_glass()

@export var border: Color = Color("87ceeb"):
	set(v):
		border = v
		_push_glass()

@export_range(0.0, 1.0, 0.01) var surface_opacity: float = 0.78:
	set(v):
		surface_opacity = v
		_push_glass()

@export_range(0.0, 1.0, 0.01) var border_opacity: float = 0.26:
	set(v):
		border_opacity = v
		_push_glass()

@export_range(0.0, 120.0, 1.0) var corner_radius: float = 34.0:
	set(v):
		corner_radius = v
		_push_glass()


func _ready() -> void:
	_push_text()
	_push_glass()


## Stat row nodes in order, for the generator and for anything that wants to
## walk them. Named rather than indexed so inserting a node above them in the
## tree cannot silently renumber the animation.
func stat_rows() -> Array[PeregrineStatRow]:
	var out: Array[PeregrineStatRow] = []
	var host := get_node_or_null("Content/Stats")
	if host == null:
		return out
	for child in host.get_children():
		var row := child as PeregrineStatRow
		if row != null:
			out.append(row)
	return out


func _push_glass() -> void:
	var glass: ColorRect = get_node_or_null("Glass")
	if glass == null or glass.material == null:
		return
	var mat := glass.material as ShaderMaterial
	mat.set_shader_parameter("panel_color", Color(surface, surface_opacity))
	mat.set_shader_parameter("border_color", Color(border, border_opacity))
	mat.set_shader_parameter("corner_radius", corner_radius)
	mat.set_shader_parameter("panel_size", size)


func _push_text() -> void:
	_set_label("Content/Eyebrow", eyebrow_text.to_upper())
	_set_label("Content/Heading", heading_text.to_upper())
	_set_label("Content/Monogram/Text", monogram_text)
	_set_label("Content/IndexLabel", index_label_text.to_upper())
	_set_label("Content/IndexCode", index_code_text)


func _set_label(path: String, value: String) -> void:
	var label: Label = get_node_or_null(path)
	if label != null:
		label.text = value
