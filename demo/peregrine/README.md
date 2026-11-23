# Peregrine Hero Stat Card

A 1920x1080, nine-second motion graphic: a species card that reveals a badge, a
title, a glass stat panel and four animated meters over a photographic backdrop,
with nine synchronised sound cues.

It is a port of a [Remotion](https://remotion.dev) composition
(`species-stat-card`), rebuilt so that **nothing about it requires code to
change.** Every value the original exposed through its Zod schema is an exported
property here, and every beat the original computed inline is a key you can drag.

Open `peregrine.tscn`, select **MotionPlayer**, and the Godotion panel binds to
32 tracks across 9 nodes.

## What is where

| File | What it holds |
| --- | --- |
| `peregrine.tscn` | The scene. Generated — see below. |
| `peregrine_timeline.tres` | All 32 tracks, ~60 keys, 5 markers. |
| `peregrine_card.tres` | Every string, colour and number. The Zod schema, ported. |
| `scripts/` | One script per component, each exposing its own properties. |
| `shaders/` | Backdrop scrim, image grade, glass panel, meter fill. |

## Editing it

**Text, colours, stats, image grade** — select the root `PeregrineCard` node and
open `Card Data` in the inspector. It is grouped the way the original schema was:
Identity, Image, Badge, Panel, Stats, Footer, Theme, Audio. Changing anything
there updates the scene immediately, in the editor.

**Timing** — drag keys on the Godotion panel. The markers (Badge, Title, Panel,
Stats, Outro) mark the five beats. The four stat rows are staggered with
per-track `time_offset` rather than four sets of shifted keys, so retiming the
whole cascade is one number per row: right-click a row → **Set Time Offset**.

**Easing** — select two keys and pick from the **Preset** dropdown, or switch to
the curve view and drag the bezier handles.

**Sound** — the nine pink rows are trigger tracks. Each fires `play()` on an
`AudioStreamPlayer` as the playhead crosses its cue. Drag a cue to re-time it;
right-click a row → **Add Cue at Playhead** to add one. Pressing **Play** in the
panel sounds them; scrubbing stays silent unless you turn on
`fire_triggers_in_editor` on the MotionPlayer.

**Which streams play** — `Card Data → Audio`. Twelve cues ship in
`assets/audio/`; the defaults use six of them, and the rest are alternates.

## Regenerating

The scene and timeline are generated, and the generated files are committed:

```bash
godot --headless --path . --script res://tests/build_peregrine.gd
```

Re-run it after changing the layout constants or the number of stats. Everything
else — text, colour, timing, easing — is meant to be edited in the editor and
will be **overwritten** by a regeneration.

Stills, for comparing against the reference:

```bash
godot --path . --resolution 1920x1080 --script res://tests/capture_peregrine.gd -- 0.5 3.5 9.0
```

That one cannot run `--headless`: the dummy rasteriser produces no image.

## Two things worth knowing

**There are no `Container` nodes in this scene, anywhere.** That is not an
oversight. A `Control` inside a `Container` has its `position` rewritten every
layout pass, so a track writing `position:y` lands and is immediately
overwritten — Godot reports no error and the keys simply do nothing. It is the
single most common way a Godotion scene silently fails, which is why
`MotionPlayer.describe_layout_conflict()` exists to name it. Every animated node
here is absolutely positioned inside a plain `Control` so the conflict cannot
arise. If you add a node you intend to animate, keep it out of containers.

**The springs do not overshoot.** The Remotion original uses physics springs,
and "spring" suggests bounce, so an earlier port of this graphic reached for an
ease-out-back curve on the stat rows. That is wrong. Running the damping ratios
`c / (2*sqrt(k*m))` on the four springs gives 1.40, 1.68, 1.82 and 1.47 —
every one is **overdamped**, so none of them overshoot at all. The tracks here
use `Expo Out`, which has the right shape: fast departure, long settle, no
bounce.

## Credits

Photograph of a peregrine falcon, CC BY-SA 4.0. Fonts: Barlow Condensed,
Cormorant Garamond, IBM Plex Mono (all SIL Open Font License). Audio cues are
procedurally generated originals.
