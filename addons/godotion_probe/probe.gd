@tool
extends EditorPlugin

## Drives Godotion's editor layer inside a real editor and asserts on the result.
##
##   godot --headless --editor --path . -- --godotion-probe
##
## Every serious defect in this plugin's history lived in the editor half —
## re-keying, auto-key arming, the built-in sub-resource save path, track
## reordering — and none of them are reachable from a plain `SceneTree` script.
## They need the real [EditorUndoRedoManager], the real inspector and the real
## `res://scene.tscn::Id` sub-resource paths. So this boots the editor, opens the
## demo, and calls the panel's own handlers exactly as a click would.
##
## Inert unless that command-line flag is present, so having it enabled in
## `project.godot` costs a normal editor session nothing.
##
## Probe the gestures a user actually performs, not the shortest path to the
## feature. Every historical bug here survived a probe that skipped the state a
## real user creates by clicking on things — a selection, most of all.

const FLAG := "--godotion-probe"
const DEMO := "res://demo/demo.tscn"
## Frames to let the editor finish building itself before driving it.
const WARMUP_FRAMES := 30

## Typed as the preloaded scripts, never left bare. A `preload`ed script without
## a `class_name` cannot be inferred through, so `:=` fails on every member
## access reached via an untyped member — and the errors land nowhere near the
## cause. This is the trap that has bitten this codebase most often.
const TimelinePanel := preload("res://addons/godotion/editor/timeline_panel.gd")
const TimelineCanvas := preload("res://addons/godotion/editor/timeline_canvas.gd")
const CurveCanvas := preload("res://addons/godotion/editor/curve_canvas.gd")

var _passed := 0
var _failed := 0
var _panel: TimelinePanel
var _player: MotionPlayer
var _root: Node


func _enter_tree() -> void:
	if not OS.get_cmdline_user_args().has(FLAG):
		return
	print("godotion-probe: armed")
	_boot()


## The editor is still assembling itself when plugins enter the tree — the
## bottom panel Godotion registers does not exist yet, and neither does the
## scene tab a scene would open into. Give it frames, not a single deferred
## call, then run and quit whatever happens: a probe that hangs is worse than
## one that fails, because CI just sits there.
func _boot() -> void:
	for i in range(WARMUP_FRAMES):
		await get_tree().process_frame
	var ok := false
	ok = _run()
	get_tree().quit(0 if ok else 1)


func _check(condition: bool, label: String) -> void:
	if condition:
		_passed += 1
	else:
		_failed += 1
		printerr("FAIL: %s" % label)


func _close(a: float, b: float, label: String, epsilon: float = 0.001) -> void:
	_check(absf(a - b) <= epsilon, "%s (got %f, expected %f)" % [label, a, b])


func _run() -> bool:
	print("")
	print("Godotion editor probe")

	if not _open_demo():
		printerr("FAIL: could not open %s with a Godotion panel bound" % DEMO)
		printerr("  scene root: %s" % _root)
		printerr("  player:     %s" % _player)
		printerr("  panel:      %s" % _panel)
		return false

	_probe_binding()
	_probe_keying()
	_probe_rekeying()
	_probe_autokey_arming()
	_probe_clipboard()
	_probe_selection_commands()
	_probe_interp_and_presets()
	_probe_lock_and_solo()
	_probe_reordering()
	_probe_markers_and_region()
	_probe_curve_view()
	_probe_trigger_tracks()
	_probe_panel_width()
	_probe_undo()

	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	return _failed == 0


func _open_demo() -> bool:
	EditorInterface.open_scene_from_path(DEMO)
	_root = EditorInterface.get_edited_scene_root()
	if _root == null:
		return false
	_player = _root.get_node_or_null("MotionPlayer") as MotionPlayer
	if _player == null:
		return false
	_panel = _find_panel(EditorInterface.get_base_control())
	if _panel == null:
		return false
	# Work on a throwaway timeline so a failed run cannot rewrite the committed
	# demo, and so each probe starts from a known-empty state.
	var scratch := MotionTimeline.new()
	scratch.duration = 4.0
	scratch.fps = 60
	_player.timeline = scratch
	_panel.edit_player(_player)
	return true


## The Godotion panel is a child of the editor's own tree, not ours. Find it by
## the script it runs rather than by a path that could change.
func _find_panel(node: Node) -> TimelinePanel:
	if node is TimelinePanel:
		return node
	for child in node.get_children():
		var found := _find_panel(child)
		if found != null:
			return found
	return null


func _timeline() -> MotionTimeline:
	return _panel.get_timeline()


func _card(index: int) -> Control:
	return _root.get_node("Card%d" % index) as Control


## Adds a track through the same entry point the Add Track dialog uses.
func _add_track(node: Node, property: String,
		mode: int = MotionTrack.Mode.PROPERTY) -> MotionTrack:
	_panel._on_tracks_requested([node], property, mode)
	return _timeline().find_track(_root.get_path_to(node), property)


func _set_playhead(time: float) -> void:
	_panel._view.playhead = time


func _select(track: MotionTrack, key: MotionKey) -> void:
	_panel._view.select(track, key, false)


# -- probes -------------------------------------------------------------------

func _probe_binding() -> void:
	_check(_panel.undo_redo != null, "the panel has an undo manager")
	_check(_timeline() == _player.timeline, "the panel binds the player's timeline")
	_check(_panel._resolve_root() == _root, "the panel resolves the scene root")


func _probe_keying() -> void:
	var card := _card(1)
	card.position = Vector2(80, 300)
	var track := _add_track(card, "position:y")
	_check(track != null, "Add Track creates a track")
	if track == null:
		return

	_set_playhead(0.0)
	_panel.key_at_playhead()
	_check(track.get_valid_keys().size() == 1, "Key inserts a key at the playhead")
	_close(float(track.get_valid_keys()[0].value), 300.0, "the key records the current pose")

	# The workflow that used to produce a flat curve: scrub, pose, key again.
	_set_playhead(1.0)
	card.position = Vector2(80, 100)
	_panel.key_at_playhead()
	_check(track.get_valid_keys().size() == 2, "a second Key inserts a second key")
	_close(float(track.sample(0.5)), 200.0, "the two keys interpolate")


func _probe_rekeying() -> void:
	var track := _timeline().find_track(_root.get_path_to(_card(1)), "position:y")
	if track == null:
		return
	# Pressing Key on an existing key used to be a silent no-op, which left a
	# key's value permanently unchangeable once created.
	_set_playhead(1.0)
	_card(1).position = Vector2(80, 50)
	_panel.key_at_playhead()
	_check(track.get_valid_keys().size() == 2, "re-keying does not add a key")
	_close(float(track.get_valid_keys()[1].value), 50.0, "re-keying rewrites the existing key")


func _probe_autokey_arming() -> void:
	var track := _timeline().find_track(_root.get_path_to(_card(1)), "position:y")
	if track == null:
		return
	var first := track.get_valid_keys()[0]
	var second := track.get_valid_keys()[1]

	# Armed: the selected key sits at the playhead, so a viewport move lands.
	_set_playhead(0.0)
	_select(track, first)
	_card(1).position = Vector2(80, 400)
	_panel._capture_autokey()
	_close(float(first.value), 400.0, "auto-key captures into the key at the playhead")

	# Not armed: the selected key is elsewhere in time. This is the bug that
	# flattened animations — clicking a key to read it armed it, and the next
	# move anywhere on the timeline overwrote it with the wrong pose.
	var before: float = float(second.value)
	_set_playhead(0.0)
	_select(track, second)
	_card(1).position = Vector2(80, 123)
	_panel._capture_autokey()
	_close(float(second.value), before, "auto-key ignores a key away from the playhead")

	# Scrubbing writes node <- key; that must never read back as a user edit.
	var keyed: float = float(first.value)
	_select(track, first)
	_set_playhead(0.0)
	_panel._apply_preview()
	_panel._capture_autokey()
	_close(float(first.value), keyed, "scrubbing does not corrupt the selected key")


func _probe_clipboard() -> void:
	var track := _timeline().find_track(_root.get_path_to(_card(1)), "position:y")
	if track == null:
		return
	var before := track.get_valid_keys().size()
	_select(track, track.get_valid_keys()[0])
	_panel.copy_keys()
	_set_playhead(2.0)
	_panel.paste_keys()
	_check(track.get_valid_keys().size() == before + 1, "paste adds a key")
	_check(track.find_key_at(2.0) != null, "paste anchors at the playhead")

	_panel.duplicate_keys()
	_check(track.get_valid_keys().size() == before + 2, "duplicate adds a key")


func _probe_selection_commands() -> void:
	var track := _timeline().find_track(_root.get_path_to(_card(1)), "position:y")
	if track == null:
		return
	_panel.select_all_keys()
	_check(_panel._view.selection_size() == track.get_valid_keys().size(), "Select All takes every key")
	_panel.invert_selection()
	_check(_panel._view.is_empty(), "inverting a full selection empties it")


func _probe_interp_and_presets() -> void:
	var track := _timeline().find_track(_root.get_path_to(_card(1)), "position:y")
	if track == null:
		return
	var first := track.get_valid_keys()[0]
	_select(track, first)
	_panel._on_interp_selected(MotionKey.Interp.EASE_IN_OUT)
	_check(first.interp == MotionKey.Interp.EASE_IN_OUT, "the dropdown sets interpolation")

	# The preset picker's item 0 is the "Preset…" placeholder.
	var index := 1
	_panel._preset_picker.select(index)
	_panel._on_preset_selected(index)
	_check(first.interp == MotionKey.Interp.BEZIER, "a preset switches the key to bezier")
	_check(first.out_handle != Vector2(0.25, 0.0), "a preset moves the outgoing handle")


func _probe_lock_and_solo() -> void:
	var card := _card(2)
	card.position = Vector2(280, 260)
	var track := _add_track(card, "position:y")
	if track == null:
		return
	_panel._on_track_solo_toggled(track, true)
	_check(_timeline().has_solo(), "solo registers")
	var active := _timeline().get_active_tracks()
	_check(active.size() == 1 and active[0] == track, "solo beats enable")
	_panel._on_track_solo_toggled(track, false)

	_set_playhead(3.0)
	_panel.key_at_playhead()
	var keyed := track.get_valid_keys().size()
	_panel._on_track_lock_toggled(track, true)
	_set_playhead(3.5)
	card.position = Vector2(280, 999)
	_panel.key_at_playhead()
	_check(track.get_valid_keys().size() == keyed, "a locked track refuses new keys")

	var key := track.get_valid_keys()[0]
	var value: float = float(key.value)
	_select(track, key)
	_set_playhead(key.time)
	card.position = Vector2(280, 111)
	_panel._capture_autokey()
	_close(float(key.value), value, "a locked track refuses auto-key")
	_panel._on_track_lock_toggled(track, false)


## The reorder fix: rows are the filtered, null-free view, while the timeline
## indexes its raw array. With a filter set the two disagreed, and the track
## landed in the wrong slot.
func _probe_reordering() -> void:
	var timeline := _timeline()
	var third := _add_track(_card(3), "position:y")
	if third == null:
		return
	var order_before := timeline.get_valid_tracks().duplicate()
	_check(order_before.size() >= 3, "three tracks to reorder")
	if order_before.size() < 3:
		return

	var last: MotionTrack = order_before[order_before.size() - 1]
	var first: MotionTrack = order_before[0]
	_panel._on_tracks_reordered(last, first)
	_check(timeline.get_valid_tracks()[0] == last, "a track dropped on the first row lands first")

	# Now with a filter active, which is where the row/index mismatch bit: a row
	# number and a raw array index stop agreeing the moment rows are a subset.
	var canvas: TimelineCanvas = _panel._canvas
	canvas.filter_text = "Card3"
	var rows := canvas.rows()
	_check(rows.size() == 1, "the filter narrows the rows to one")
	if rows.size() == 1:
		var filtered: MotionTrack = rows[0]
		var head_before: MotionTrack = timeline.get_valid_tracks()[0]
		_panel._on_tracks_reordered(filtered, head_before)
		_check(timeline.get_valid_tracks()[0] == filtered,
			"a filtered row still reorders to the right slot")
	canvas.filter_text = ""

	# And to the end.
	var head: MotionTrack = timeline.get_valid_tracks()[0]
	_panel._on_tracks_reordered(head, null)
	var tail := timeline.get_valid_tracks()
	_check(tail[tail.size() - 1] == head, "a track dropped past the last row lands last")


func _probe_markers_and_region() -> void:
	var timeline := _timeline()
	_set_playhead(1.5)
	_panel._on_add_marker()
	_check(timeline.get_valid_markers().size() == 1, "a marker is added at the playhead")
	var marker := timeline.get_valid_markers()[0]
	_close(marker.time, 1.5, "the marker sits at the playhead")

	_panel._on_add_marker()
	_check(timeline.get_valid_markers().size() == 1, "a second marker at the same time is refused")

	_panel._on_region_toggled(true)
	_check(timeline.loop_region_enabled, "the loop region turns on")
	_check(timeline.loop_region_end > timeline.loop_region_start,
		"an unconfigured region is seeded with a draggable span")
	var play_range := timeline.get_play_range()
	_close(play_range.x, timeline.loop_region_start, "the play range follows the region")
	_panel._on_region_toggled(false)


func _probe_curve_view() -> void:
	var track := _timeline().find_track(_root.get_path_to(_card(1)), "position:y")
	if track == null:
		return
	_panel._curve_button.button_pressed = true
	_check(_panel._curve.visible, "the curve view toggles on")

	var curve: CurveCanvas = _panel._curve
	curve.size = Vector2(1200, 400)
	curve.timeline = _timeline()
	var key := track.get_valid_keys()[0]
	_select(track, key)
	# Park the playhead on the key under test, so the preview write that follows
	# a value edit is sampling this key rather than some other moment.
	_set_playhead(key.time + track.time_offset)
	# _refresh_ranges rather than _draw: the engine refuses draw calls outside a
	# real NOTIFICATION_DRAW, and the ranges are the only part hit-testing needs.
	curve._refresh_ranges()

	# A bezier key's handle must be grabbable, and only on its own side.
	key.interp = MotionKey.Interp.BEZIER
	var handle := curve.handle_position(track, key, false)
	_check(handle != Vector2.INF, "a bezier key exposes its outgoing handle")
	var first_in := curve.handle_position(track, track.get_valid_keys()[0], true)
	_check(first_in == Vector2.INF, "the first key has no incoming handle to grab")

	# The gesture the value graph exists for, and did not have: drag vertically.
	var before: float = float(key.value)
	var y := curve.value_to_y(before, track)
	var moved: float = curve.y_to_value(y - 40.0, track)
	_check(not is_equal_approx(moved, before), "moving up the graph changes the value")
	# The canvas moves the key live and the panel registers the inverse, so the
	# probe has to apply it the same way a drag would before committing.
	key.value = moved
	_panel._on_keys_revalued([key], [before], [moved])
	_close(float(key.value), moved, "the value drag is committed to the key")
	_close(float(_card(1).position.y), moved, "and is pushed straight into the scene")

	# Per-track normalisation gives each track its own span rather than one
	# shared axis that flattens everything narrow.
	curve.normalize = true
	curve._refresh_ranges()
	_check(curve.track_range(track).y > curve.track_range(track).x, "a normalised track has a span")
	curve.normalize = false
	_panel._curve_button.button_pressed = false


## Trigger tracks through the editor, not the core. The firing rule is covered
## headlessly in `test_core.gd`; what only a real editor can show is that the
## panel's shared paths — Key, auto-key, the value readout — do not try to read
## a pose off a track that names a method.
func _probe_trigger_tracks() -> void:
	_panel._curve_button.button_pressed = false

	var speaker := AudioStreamPlayer.new()
	speaker.name = "ProbeSpeaker"
	_root.add_child(speaker)
	speaker.owner = _root

	var track := _add_track(speaker, "play", MotionTrack.Mode.TRIGGER)
	_check(track != null, "a trigger track can be created through the dialog path")
	if track == null:
		speaker.free()
		return
	_check(track.is_trigger(), "and comes back in TRIGGER mode")
	_check(track.get_kind() == MotionTrack.Kind.TRIGGER, "so it takes the trigger accent")

	# Key with nothing selected must not scatter a cue onto every trigger track
	# in the timeline just because they are all enabled.
	_panel._view.clear()
	_set_playhead(1.0)
	_panel._on_key_pressed()
	_check(track.get_valid_keys().is_empty(), "Key skips an unselected trigger row")

	# The first cue has to come from somewhere other than Key, which acts on a
	# selection made of keys this track does not yet have.
	_check(_panel._add_cue(track), "Add Cue reaches an empty trigger track")
	_check(track.get_valid_keys().size() == 1, "and creates exactly one cue")
	if track.get_valid_keys().is_empty():
		speaker.free()
		return
	_close(track.get_valid_keys()[0].time, 1.0, "the cue lands on the playhead")
	_check(not _panel._add_cue(track), "a second Add Cue on the same beat is refused")
	_check(track.get_valid_keys().size() == 1, "and adds nothing")

	# The gesture that broke every earlier version of this panel: scrub with a
	# key selected. Auto-key must not try to read `play` as a property and write
	# whatever null becomes into the cue.
	var cue := track.get_valid_keys()[0]
	_select(track, cue)
	var before: Variant = cue.value
	_set_playhead(2.5)
	_panel._capture_autokey()
	_set_playhead(1.0)
	_panel._capture_autokey()
	_check(cue.value == before, "auto-key leaves a trigger cue alone while scrubbing")
	_close(track.get_valid_keys()[0].time, 1.0, "and does not move it")

	# With a cue selected the track IS reachable from Key, and pressing it on a
	# fresh beat adds a second cue rather than overwriting the first.
	_select(track, cue)
	_set_playhead(2.0)
	_panel._on_key_pressed()
	_check(track.get_valid_keys().size() == 2, "Key adds a cue to a selected trigger row")

	# The dope sheet has to survive drawing it. A trigger track has no span bar
	# and no interpolation glyph, and `rows()` feeding a null-safe path matters
	# more here than the pixels.
	_panel._canvas.queue_redraw()
	_check(_panel._canvas.rows().has(track), "the trigger track appears as a row")

	# Editor playback must sound its cues. Scrubbing must not. Getting this
	# backwards is what made the peregrine demo's nine sound cues silent in the
	# editor, which is indistinguishable from broken audio.
	var fires: Array = []
	_player.trigger_fired.connect(func(_t: MotionTrack, _k: MotionKey) -> void: fires.append(null))
	_check(not _player.fire_triggers_in_editor, "scrubbing stays silent by default")

	_set_playhead(0.0)
	_set_playhead(1.5)
	_check(fires.is_empty(), "scrubbing across a cue fires nothing")

	_panel._set_previewing(true)
	_check(_player._editor_triggers_armed, "pressing Play arms triggers")
	_set_playhead(0.0)
	_set_playhead(1.5)
	_check(fires.size() == 1, "and the preview then sounds the cue it crosses")

	_panel._set_previewing(false)
	_check(not _player._editor_triggers_armed, "pausing disarms them again")
	fires.clear()
	_set_playhead(0.0)
	_set_playhead(1.5)
	_check(fires.is_empty(), "so scrubbing after a preview is silent again")

	# Play from exactly a cue must sound it — the window opens just behind the
	# resume position, matching what play() does at runtime.
	fires.clear()
	_set_playhead(1.0)
	_panel._set_previewing(true)
	_panel._apply_preview()
	_check(fires.size() == 1, "playing from exactly a cue sounds it")
	_panel._set_previewing(false)

	_timeline().remove_track(track)
	speaker.free()


## The bottom panel's minimum width propagates all the way to the editor's dock
## splitter, so an over-wide toolbar pushes the right-hand docks off the screen
## — silently, and only on machines narrower than the toolbar. It went unnoticed
## through v1.0 and v1.1 for exactly that reason, and surfaced only when a
## timeline with a long name and a long resource path made the readouts wide
## enough to break a 1080p editor. Assert it rather than trusting a look.
func _probe_panel_width() -> void:
	var width := _panel.get_combined_minimum_size().x
	# 700px leaves the scene tree and inspector room on a 1366px laptop, which
	# is the narrowest display worth supporting.
	_check(width <= 700.0, "the panel's minimum width stays modest (got %.0f)" % width)

	# The readouts are the unbounded part: their text length is user data. Set
	# an absurd one and confirm it changes nothing.
	var before := _panel.get_combined_minimum_size().x
	_timeline().timeline_name = "A timeline name long enough to have broken this: " + "x".repeat(400)
	_panel._refresh_controls()
	var after := _panel.get_combined_minimum_size().x
	_check(is_equal_approx(before, after),
		"a 450-character timeline name does not widen the panel (%.0f -> %.0f)" % [before, after])
	_timeline().timeline_name = "Probe"


func _probe_undo() -> void:
	var timeline := _timeline()
	var count := timeline.get_valid_tracks().size()
	var card := _card(3)
	var track := _add_track(card, "modulate:a")
	_check(timeline.get_valid_tracks().size() == count + 1, "adding a track grows the timeline")

	# The undo history the timeline lands in is the *scene's*, not the global
	# one, which is what makes Ctrl+Z and the scene dirty flag behave.
	_panel.undo_redo.get_history_undo_redo(_panel.undo_redo.get_object_history_id(timeline)).undo()
	_check(timeline.get_valid_tracks().size() == count, "undo removes the track again")
