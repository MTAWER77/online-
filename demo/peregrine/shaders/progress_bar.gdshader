shader_type canvas_item;

// A stat row's meter. `fill_amount` is driven by a Godotion track — it is the
// one uniform in this demo that is animated rather than merely animatable, and
// the reason StatRow exposes `progress_fill` as a plain float.
//
// Matches StatRow.tsx: a coral -> sky -> pale gradient across the filled span,
// a white leading cap, and a faint track behind the unfilled remainder.

uniform float fill_amount : hint_range(0.0, 1.0) = 0.0;
uniform vec4 color_start : source_color = vec4(1.0, 0.435, 0.263, 1.0);
uniform vec4 color_mid : source_color = vec4(0.529, 0.808, 0.922, 1.0);
uniform vec4 color_end : source_color = vec4(0.914, 0.969, 1.0, 1.0);
uniform vec4 track_color : source_color = vec4(1.0, 1.0, 1.0, 0.09);
uniform float cap_width : hint_range(0.0, 0.5) = 0.10;
uniform float cap_strength : hint_range(0.0, 1.0) = 0.75;
// Pixel height of the bar, so the pill ends stay round at any width.
uniform float bar_height = 9.0;
uniform float bar_width = 547.0;

float rounded_box(vec2 p, vec2 half_size, float radius) {
	vec2 q = abs(p) - half_size + radius;
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

void fragment() {
	vec2 bar_size = vec2(bar_width, bar_height);
	vec2 half_size = bar_size * 0.5;
	float radius = bar_height * 0.5;
	float outer = rounded_box(UV * bar_size - half_size, half_size, radius);
	float inside = 1.0 - smoothstep(-1.0, 0.0, outer);
	if (inside <= 0.0) {
		discard;
	}

	// A zero fill must draw no gradient at all. Dividing by a clamped epsilon
	// instead would light the first pixel column coral on an empty meter, which
	// reads as a bar that never actually starts at zero.
	if (fill_amount <= 0.0 || UV.x > fill_amount) {
		COLOR = vec4(track_color.rgb, track_color.a * inside);
	} else {
		float norm_x = UV.x / fill_amount;
		vec4 grad = mix(color_start, color_mid, smoothstep(0.0, 0.6, norm_x));
		grad = mix(grad, color_end, smoothstep(0.6, 1.0, norm_x));

		float cap = smoothstep(1.0 - cap_width, 1.0, norm_x) * cap_strength;
		grad.rgb += vec3(cap);

		COLOR = vec4(clamp(grad.rgb, vec3(0.0), vec3(1.0)), grad.a * inside);
	}
}
