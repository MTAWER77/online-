@tool
class_name PeregrineCardData
extends Resource

## Everything the species stat card says and looks like, in one inspectable
## resource.
##
## This is a direct port of `speciesStatCardSchema` from the Remotion original —
## same fields, same groups, same ranges — so a value that was editable there is
## editable here. Swap this resource to retarget the whole graphic at a different
## species without touching a node.
##
## One group did not survive the port, deliberately. The schema's `timing` block
## exists there because a `<Sequence from={...}>` needs a number; here the timing
## *is* the keys, and moving a beat means dragging it on the dope sheet. The
## fields are kept below purely as the generator's source of truth, so re-running
## `tests/build_peregrine.gd` reproduces the same starting layout — they are not
## read at runtime. See [MotionTimeline] for the thing that actually owns timing.

@export_group("Identity")
@export var common_name: String = "PEREGRINE FALCON":
	set(v):
		common_name = v
		emit_changed()
@export var scientific_name: String = "Falco peregrinus":
	set(v):
		scientific_name = v
		emit_changed()

@export_group("Image")
@export var image: Texture2D = null:
	set(v):
		image = v
		emit_changed()
## Focal point as a percentage, matching CSS `object-position`.
@export_range(0.0, 100.0, 1.0) var focal_x: float = 52.0:
	set(v):
		focal_x = v
		emit_changed()
@export_range(0.0, 100.0, 1.0) var focal_y: float = 43.0:
	set(v):
		focal_y = v
		emit_changed()
@export_range(0.0, 2.0, 0.01) var saturate: float = 0.75:
	set(v):
		saturate = v
		emit_changed()
@export_range(0.5, 2.0, 0.01) var contrast: float = 1.06:
	set(v):
		contrast = v
		emit_changed()
@export_range(0.2, 1.5, 0.01) var brightness: float = 0.80:
	set(v):
		brightness = v
		emit_changed()
## Ken Burns end scale. The track keys 1.0 -> this across the full duration.
@export_range(1.0, 1.6, 0.01) var zoom: float = 1.15:
	set(v):
		zoom = v
		emit_changed()
## Ken Burns end drift in pixels. The track keys 0 -> this.
@export_range(-200.0, 200.0, 1.0) var drift_x: float = -28.0:
	set(v):
		drift_x = v
		emit_changed()

@export_group("Badge")
@export var badge_show: bool = true:
	set(v):
		badge_show = v
		emit_changed()
@export var badge_text: String = "SPECIES UNLOCKED":
	set(v):
		badge_text = v
		emit_changed()

@export_group("Panel")
@export var panel_eyebrow: String = "Flight performance":
	set(v):
		panel_eyebrow = v
		emit_changed()
@export var panel_heading: String = "Apex profile":
	set(v):
		panel_heading = v
		emit_changed()
@export var monogram: String = "FP":
	set(v):
		monogram = v
		emit_changed()
@export var index_label: String = "Biometric field index":
	set(v):
		index_label = v
		emit_changed()
@export var index_code: String = "FAL-PER · 001":
	set(v):
		index_code = v
		emit_changed()
@export var radar: bool = true:
	set(v):
		radar = v
		emit_changed()

@export_group("Stats")
## One to six rows. The generator builds a node and three tracks per entry, so
## changing the count means re-running `tests/build_peregrine.gd`; changing a
## row's text or target only needs a scene reload.
@export var stats: Array[PeregrineStatItem] = []:
	set(v):
		stats = v
		emit_changed()

@export_group("Footer")
@export var footer_left: String = "Order Falconiformes":
	set(v):
		footer_left = v
		emit_changed()
@export var footer_right: String = "Global range":
	set(v):
		footer_right = v
		emit_changed()
@export var footer_corner: String = "09.00 sec / Field study":
	set(v):
		footer_corner = v
		emit_changed()

@export_group("Theme")
@export var base: Color = Color("111315"):
	set(v):
		base = v
		emit_changed()
@export var surface: Color = Color("15191b"):
	set(v):
		surface = v
		emit_changed()
@export var sky: Color = Color("87ceeb"):
	set(v):
		sky = v
		emit_changed()
@export var coral: Color = Color("ff6f43"):
	set(v):
		coral = v
		emit_changed()
@export var bone: Color = Color("f4f2ed"):
	set(v):
		bone = v
		emit_changed()
@export var ink_stat: Color = Color("e8e9e7"):
	set(v):
		ink_stat = v
		emit_changed()
@export var ink_soft: Color = Color("d8d9d7"):
	set(v):
		ink_soft = v
		emit_changed()
@export var ink_data: Color = Color("bfeaff"):
	set(v):
		ink_data = v
		emit_changed()
@export var ink_pale: Color = Color("e9f7ff"):
	set(v):
		ink_pale = v
		emit_changed()
@export var muted: Color = Color("b7b9ba"):
	set(v):
		muted = v
		emit_changed()
@export var badge_surface: Color = Color("1b252a"):
	set(v):
		badge_surface = v
		emit_changed()
@export var monogram_ink: Color = Color("ffd2c5"):
	set(v):
		monogram_ink = v
		emit_changed()
@export var muted_dim: Color = Color("a7aaac"):
	set(v):
		muted_dim = v
		emit_changed()

@export_group("Audio")
@export var ambient_src: String = "ambient-air.wav"
@export var badge_src: String = "digital-beeping-1.wav"
@export var title_src: String = "digital-beeping-2.wav"
@export var panel_src: String = "digital-beeping-2.wav"
@export var outro_src: String = "outro-breath.wav"
@export_range(0.0, 4.0, 0.05) var outro_lead: float = 1.13
@export_range(0.0, 1.0, 0.01) var ambient_volume: float = 0.15
@export_range(0.0, 1.0, 0.01) var badge_volume: float = 0.72
@export_range(0.0, 1.0, 0.01) var title_volume: float = 0.68
@export_range(0.0, 1.0, 0.01) var panel_volume: float = 0.72
@export_range(0.0, 1.0, 0.01) var stat_volume: float = 0.68
@export_range(0.0, 1.0, 0.01) var outro_volume: float = 0.56

@export_group("Timing (generator input only)")
## Seconds. Read by `tests/build_peregrine.gd` when it lays out the keys, and by
## nothing else. After generation these are historical: drag the keys instead.
@export_range(0.0, 10.0, 0.05) var badge_at: float = 0.33
@export_range(0.0, 10.0, 0.05) var title_at: float = 1.2
@export_range(0.0, 10.0, 0.05) var panel_at: float = 2.6
@export_range(0.0, 12.0, 0.05) var stats_at: float = 4.2
@export_range(0.1, 3.0, 0.05) var stagger: float = 1.0
@export_range(0.3, 6.0, 0.05) var outro: float = 0.8


## Total length, ported from `durationInFramesFor()` so the Godot timeline and
## the Remotion composition agree on 9.00 seconds for the default props.
func total_duration() -> float:
	var last_stat_at := stats_at + maxf(0.0, stats.size() - 1) * stagger
	return last_stat_at + stagger + outro


## Volume in decibels for a linear 0..1 amplitude, which is the unit the schema
## uses. Silence maps to -80 dB rather than -inf, which Godot treats as inaudible
## without the NaN risk of log(0).
static func to_db(linear: float) -> float:
	return -80.0 if linear <= 0.0 else linear_to_db(linear)
