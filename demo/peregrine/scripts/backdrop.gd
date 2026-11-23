@tool
class_name PeregrineBackdrop
extends Control

## The photo layer, its colour grade and the scrim stack over it.
##
## The grade lives here as three plain floats rather than inside the material
## because a [MotionTrack] writes node properties, not shader uniforms. Exposing
## them means `saturate`, `contrast` and `brightness` are keyable — the backdrop
## can be graded over the shot, which the Remotion original's static CSS filter
## cannot do.

@onready var _photo: TextureRect = $Photo
@onready var _scrim: ColorRect = $Scrim

@export_range(0.0, 2.0, 0.01) var saturate: float = 0.75:
	set(v):
		saturate = v
		_push_grade()

@export_range(0.5, 2.0, 0.01) var contrast: float = 1.06:
	set(v):
		contrast = v
		_push_grade()

@export_range(0.2, 1.5, 0.01) var brightness: float = 0.80:
	set(v):
		brightness = v
		_push_grade()

@export var base_color: Color = Color("111315"):
	set(v):
		base_color = v
		_push_scrim()

@export var sky_color: Color = Color("87ceeb"):
	set(v):
		sky_color = v
		_push_scrim()


func _ready() -> void:
	_push_grade()
	_push_scrim()


## Written on every setter, including the ones that fire before `_ready` while
## the scene is still loading — hence the null guards rather than `@onready`
## alone. A track applied on frame zero arrives in exactly that window.
func _push_grade() -> void:
	var photo: TextureRect = _photo if _photo != null else get_node_or_null("Photo")
	if photo == null or photo.material == null:
		return
	var mat := photo.material as ShaderMaterial
	mat.set_shader_parameter("saturate_amount", saturate)
	mat.set_shader_parameter("contrast_amount", contrast)
	mat.set_shader_parameter("brightness_amount", brightness)


func _push_scrim() -> void:
	var scrim: ColorRect = _scrim if _scrim != null else get_node_or_null("Scrim")
	if scrim == null or scrim.material == null:
		return
	var mat := scrim.material as ShaderMaterial
	mat.set_shader_parameter("base_color", base_color)
	mat.set_shader_parameter("sky_color", sky_color)
