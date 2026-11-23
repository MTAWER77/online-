shader_type canvas_item;

// The three stacked gradients Remotion's Backdrop draws over the photo, folded
// into one pass. Stop positions are the CSS ones verbatim, so the falloff can
// be compared against the reference frame by frame rather than by eye.
//
// Every constant is a uniform because the demo's whole point is that a human
// can change it. `species_stat_card.gd` mirrors these onto @export properties,
// which is what makes them reachable from a Godotion track.

uniform vec4 base_color : source_color = vec4(0.0667, 0.0745, 0.0824, 1.0);
uniform vec4 sky_color : source_color = vec4(0.529, 0.808, 0.922, 1.0);

// linear-gradient(90deg, base 97% 0%, base 84% 28%, base 22% 58%, base 12% 100%)
uniform float scrim_left : hint_range(0.0, 1.0) = 0.97;
uniform float scrim_mid : hint_range(0.0, 1.0) = 0.84;
uniform float scrim_mid_stop : hint_range(0.0, 1.0) = 0.28;
uniform float scrim_fade : hint_range(0.0, 1.0) = 0.22;
uniform float scrim_fade_stop : hint_range(0.0, 1.0) = 0.58;
uniform float scrim_right : hint_range(0.0, 1.0) = 0.12;

// linear-gradient(180deg, base 20% 0%, transparent 44%, base 76% 100%)
uniform float vignette_top : hint_range(0.0, 1.0) = 0.20;
uniform float vignette_clear_stop : hint_range(0.0, 1.0) = 0.44;
uniform float vignette_bottom : hint_range(0.0, 1.0) = 0.76;

// radial-gradient(circle at 80% 18%, sky 30%, transparent 28%) at 35% opacity
uniform vec2 glow_center = vec2(0.80, 0.18);
uniform float glow_radius : hint_range(0.0, 1.0) = 0.28;
uniform float glow_strength : hint_range(0.0, 1.0) = 0.30;
uniform float glow_opacity : hint_range(0.0, 1.0) = 0.35;

// Aspect of the frame, so the radial glow stays circular instead of stretching
// with the viewport the way a raw UV distance would.
uniform float aspect = 1.7777778;

// Piecewise-linear ramp across three stops, matching how a CSS gradient
// interpolates between listed positions rather than easing across the whole run.
float ramp(float t, float a, float b, float b_stop, float c, float c_stop, float d) {
	if (t < b_stop) {
		return mix(a, b, t / max(b_stop, 0.0001));
	}
	if (t < c_stop) {
		return mix(b, c, (t - b_stop) / max(c_stop - b_stop, 0.0001));
	}
	return mix(c, d, (t - c_stop) / max(1.0 - c_stop, 0.0001));
}

void fragment() {
	vec2 uv = UV;

	float scrim = ramp(uv.x, scrim_left, scrim_mid, scrim_mid_stop,
		scrim_fade, scrim_fade_stop, scrim_right);

	// Two independent runs meeting at the clear stop, not one ramp: the middle
	// of the frame is fully transparent in the reference, and a single ramp
	// through it would tint the subject.
	float vignette;
	if (uv.y < vignette_clear_stop) {
		vignette = mix(vignette_top, 0.0, uv.y / max(vignette_clear_stop, 0.0001));
	} else {
		vignette = mix(0.0, vignette_bottom,
			(uv.y - vignette_clear_stop) / max(1.0 - vignette_clear_stop, 0.0001));
	}

	// Alpha compositing, not addition: two 76% scrims stacked are 94% opaque,
	// never 152%. Summing them clipped the bottom-left corner to flat base.
	float alpha = scrim + vignette * (1.0 - scrim);

	vec2 to_glow = vec2((uv.x - glow_center.x) * aspect, uv.y - glow_center.y);
	float glow = smoothstep(glow_radius, 0.0, length(to_glow)) * glow_strength * glow_opacity;

	vec3 color = mix(base_color.rgb, sky_color.rgb, glow);
	COLOR = vec4(color, clamp(alpha, 0.0, 1.0));
}
