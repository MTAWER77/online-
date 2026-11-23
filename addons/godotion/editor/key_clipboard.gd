@tool
extends RefCounted

## Copy/paste buffer for keys.
##
## Stores detached [MotionKey] duplicates plus the track each came from and the
## time offset from the earliest copied key. Pasting re-anchors that shape at
## the playhead, so a copied gesture keeps its internal timing.
##
## Tracks are held as weak-ish plain references: a paste checks each one is
## still in the target timeline before using it, and falls back to matching by
## node path and property. That survives an undo that rebuilt the track array.

class Entry:
	var key: MotionKey
	var offset: float
	var node_path: NodePath
	var property: String

	func _init(p_key: MotionKey, p_offset: float, p_track: MotionTrack) -> void:
		key = p_key
		offset = p_offset
		node_path = p_track.node_path
		property = p_track.property


var _entries: Array[Entry] = []


func is_empty() -> bool:
	return _entries.is_empty()


func size() -> int:
	return _entries.size()


## Copies [param selection] ([code]{track, key}[/code] dictionaries). The
## earliest key becomes the anchor, so pasting reproduces relative timing.
func copy(selection: Array[Dictionary]) -> void:
	_entries.clear()
	if selection.is_empty():
		return
	var earliest := INF
	for entry in selection:
		earliest = minf(earliest, (entry["key"] as MotionKey).time)
	for entry in selection:
		var key: MotionKey = entry["key"]
		_entries.append(Entry.new(key.duplicate_key(), key.time - earliest, entry["track"]))


## Builds the keys a paste at [param time] would produce, without mutating
## anything. Returns [code][{track, key}][/code] for the caller to push through
## undo. Entries whose track no longer exists are dropped.
func build_paste(timeline: MotionTimeline, time: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if timeline == null:
		return out
	for entry in _entries:
		var track := timeline.find_track(entry.node_path, entry.property)
		if track == null:
			continue
		var key := entry.key.duplicate_key()
		key.time = maxf(0.0, time + entry.offset)
		out.append({"track": track, "key": key})
	return out


func clear() -> void:
	_entries.clear()
