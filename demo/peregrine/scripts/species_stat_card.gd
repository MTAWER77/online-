@tool
class_name PeregrineStatCard
extends Control

## Root of the species stat card. Distributes [member card_data] to the
## components and the audio bus, and nothing else.
##
## What this script deliberately does NOT do is animate. The Remotion original
## computes every spring inline, and the first Godot port of it kept that shape:
## a 200-line `_evaluate_frame(t)` that recomputed eases from hard-coded
## durations. Anything it drove was unreachable from the editor — changing when
## the panel slides in meant editing GDScript.
##
## Here the motion lives entirely in a [MotionTimeline], and this script's only
## job is content. If you find yourself wanting to add an `if t > ...` below,
## that beat belongs on the dope sheet instead.

@export var card_data: PeregrineCardData:
	set(v):
		if card_data == v:
			return
		if card_data != null and card_data.changed.is_connected(_apply):
			card_data.changed.disconnect(_apply)
		card_data = v
		if card_data != null and not card_data.changed.is_connected(_apply):
			card_data.changed.connect(_apply)
		_apply()

## Folder holding the cue files named by [PeregrineCardData].
@export_dir var audio_root: String = "res://demo/peregrine/assets/audio"


func _ready() -> void:
	if card_data != null and not card_data.changed.is_connected(_apply):
		card_data.changed.connect(_apply)
	_apply()


## Pushes every field of the data resource into the scene. Safe to call at any
## time, including before `_ready` while a setter fires during load — every
## lookup is null-guarded, because a track applied on frame zero arrives in
## exactly that window.
##
## Deliberately NOT gated on `is_inside_tree()`. That guard looks right and is
## the reason the generated scene shipped with every AudioStreamPlayer empty:
## inside a `SceneTree` script's `_initialize()` the root is not yet "in the
## tree", so the generator's own apply pass silently did nothing and `_ready`
## never ran to correct it. `get_node_or_null` needs no such gate.
func _apply() -> void:
	if card_data == null:
		return
	_apply_backdrop()
	_apply_badge()
	_apply_title()
	_apply_panel()
	_apply_stats()
	_apply_footer()
	_apply_audio()


func _apply_backdrop() -> void:
	var backdrop := get_node_or_null("Backdrop") as PeregrineBackdrop
	if backdrop == null:
		return
	backdrop.saturate = card_data.saturate
	backdrop.contrast = card_data.contrast
	backdrop.brightness = card_data.brightness
	backdrop.base_color = card_data.base
	backdrop.sky_color = card_data.sky

	var photo := backdrop.get_node_or_null("Photo") as TextureRect
	if photo != null and card_data.image != null:
		photo.texture = card_data.image
		# `object-position: x% y%` maps onto Godot's stretch modes only through
		# the pivot: KEEP_ASPECT_COVERED crops around the centre, so shifting the
		# focal point means shifting the node, not setting a property.
		photo.pivot_offset = Vector2(
			photo.size.x * card_data.focal_x * 0.01,
			photo.size.y * card_data.focal_y * 0.01)


func _apply_badge() -> void:
	var badge := get_node_or_null("LeftColumn/Badge") as PeregrineBadge
	if badge == null:
		return
	badge.visible = card_data.badge_show
	badge.text = card_data.badge_text
	badge.surface = card_data.badge_surface
	badge.border = card_data.sky
	badge.dot_color = card_data.coral
	badge.text_color = card_data.ink_pale


func _apply_title() -> void:
	var title := get_node_or_null("LeftColumn/HeroTitle") as PeregrineHeroTitle
	if title == null:
		return
	title.common_name = card_data.common_name
	title.scientific_name = card_data.scientific_name
	title.coral = card_data.coral
	title.sky = card_data.sky
	title.name_color = card_data.bone
	title.scientific_color = card_data.ink_soft


func _apply_panel() -> void:
	var panel := get_node_or_null("StatPanel") as PeregrineStatPanel
	if panel == null:
		return
	panel.eyebrow_text = card_data.panel_eyebrow
	panel.heading_text = card_data.panel_heading
	panel.monogram_text = card_data.monogram
	panel.index_label_text = card_data.index_label
	panel.index_code_text = card_data.index_code
	panel.surface = card_data.surface
	panel.border = card_data.sky

	var radar := panel.get_node_or_null("RadarReticle") as PeregrineRadarReticle
	if radar != null:
		radar.visible = card_data.radar
		radar.ring_color = card_data.sky
		radar.sweep_color = card_data.coral


## Text and colour only. The row's `progress_fill` is left alone: it is track
## territory, and writing it here would fight the timeline every frame.
func _apply_stats() -> void:
	var panel := get_node_or_null("StatPanel") as PeregrineStatPanel
	if panel == null:
		return
	var rows := panel.stat_rows()
	for i in range(rows.size()):
		if i >= card_data.stats.size():
			rows[i].visible = false
			continue
		var stat := card_data.stats[i]
		if stat == null:
			continue
		rows[i].visible = true
		rows[i].label_text = stat.label
		rows[i].value_text = stat.value
		rows[i].label_color = card_data.ink_stat
		rows[i].value_color = card_data.ink_data


func _apply_footer() -> void:
	var footer := get_node_or_null("FooterMeta") as PeregrineFooterMeta
	if footer == null:
		return
	footer.left_text = card_data.footer_left
	footer.right_text = card_data.footer_right
	footer.corner_text = card_data.footer_corner
	footer.muted = card_data.muted
	footer.coral = card_data.coral


## Streams and levels. The *timing* of every cue is on the timeline as a trigger
## track — this only decides what each player holds and how loud it is.
func _apply_audio() -> void:
	_set_player("Audio/Ambient", card_data.ambient_src, card_data.ambient_volume)
	_set_player("Audio/Badge", card_data.badge_src, card_data.badge_volume)
	_set_player("Audio/Title", card_data.title_src, card_data.title_volume)
	_set_player("Audio/Panel", card_data.panel_src, card_data.panel_volume)
	_set_player("Audio/Outro", card_data.outro_src, card_data.outro_volume)
	for i in range(card_data.stats.size()):
		var stat := card_data.stats[i]
		if stat != null:
			_set_player("Audio/Stat%d" % (i + 1), stat.sfx, card_data.stat_volume)


func _set_player(path: String, file: String, volume: float) -> void:
	var player := get_node_or_null(path) as AudioStreamPlayer
	if player == null or file.is_empty():
		return
	var stream_path := "%s/%s" % [audio_root, file]
	if ResourceLoader.exists(stream_path):
		player.stream = load(stream_path)
	else:
		push_warning("Godotion demo: no audio cue at '%s'." % stream_path)
	player.volume_db = PeregrineCardData.to_db(volume)
