@tool
class_name MotionMarker
extends Resource

## A named point on a [MotionTimeline].
##
## Markers carry no behaviour — they are authoring landmarks that the panel
## draws on the ruler and snaps the playhead to. Cue points for game code are
## the intended runtime use: read them back with
## [method MotionTimeline.get_marker_at].

@export var name: String = "Marker":
	set(v):
		name = v
		emit_changed()

@export var time: float = 0.0:
	set(v):
		time = maxf(0.0, v)
		emit_changed()

@export var color: Color = Color("f0c674"):
	set(v):
		color = v
		emit_changed()


func duplicate_marker() -> MotionMarker:
	var copy := MotionMarker.new()
	copy.name = name
	copy.time = time
	copy.color = color
	return copy
