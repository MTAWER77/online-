@tool
class_name PeregrineStatItem
extends Resource

## One row of the stat panel.
##
## Mirrors the `stats[]` element of the Remotion composition's Zod schema. The
## ranges match the schema's `.min()/.max()/.step()` so the inspector refuses
## the same values the original refused.

@export var label: String = "Top diving speed":
	set(v):
		label = v
		emit_changed()

@export var value: String = "389 km/h":
	set(v):
		value = v
		emit_changed()

## Meter fill, 0..1. Drives the `progress_fill` the timeline animates *towards*
## — the track keys 0 -> this, so editing it here changes where the bar lands
## without touching a key.
@export_range(0.0, 1.0, 0.01) var progress: float = 0.97:
	set(v):
		progress = clampf(v, 0.0, 1.0)
		emit_changed()

## Filename under the audio folder, fired by this row's trigger track.
@export var sfx: String = "digital-beeping-3.wav":
	set(v):
		sfx = v
		emit_changed()
