shader_type canvas_item;

// The stat panel's frosted card: rounded fill, hairline sky border, and the
// inset white highlight along the top edge that sells the glass.
//
// The original version of this shader took a `corner_radius` uniform and never
// read it, so the panel drew as a hard rectangle over a scene whose reference
// has a 34px radius. The rounding is done here properly, in pixel space, so the
// radius stays circular on a panel that is not square.

uniform vec4 panel_color : source_color = vec4(0.0823, 0.098, 0.1058, 0.78);
uniform vec4 border_color : source_color = vec4(0.529, 0.808, 0.922, 0.26);
uniform float corner_radius : hint_range(0.0, 120.0) = 34.0;
uniform float border_width : hint_range(0.0, 8.0) = 1.0;
uniform float highlight_strength : hint_range(0.0, 1.0) = 0.12;
// Set from the script to the panel's own rect, so radius and border stay in
// pixels rather than scaling with the node.
uniform vec2 panel_size = vec2(675.0, 770.0);

// Signed distance to a rounded box, negative inside.
float rounded_box(vec2 p, vec2 half_size, float radius) {
	vec2 q = abs(p) - half_size + radius;
	return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

void fragment() {
	vec2 half_size = panel_size * 0.5;
	vec2 p = UV * panel_size - half_size;
	float radius = min(corner_radius, min(half_size.x, half_size.y));
	float dist = rounded_box(p, half_size, radius);

	// One pixel of feather, so the corners are anti-aliased rather than stepped.
	float inside = 1.0 - smoothstep(-1.0, 0.0, dist);
	if (inside <= 0.0) {
		discard;
	}

	vec4 col = panel_color;

	// Inset specular along the top edge — brightest at the top, gone by ~2% down.
	float highlight = smoothstep(0.02, 0.0, UV.y) * highlight_strength;
	col.rgb += vec3(highlight);

	// Border rides the outer edge of the same distance field, so it follows the
	// corners instead of cutting across them.
	float border = smoothstep(-border_width, 0.0, dist);
	col = mix(col, vec4(border_color.rgb, max(col.a, border_color.a)), border * border_color.a);

	COLOR = vec4(col.rgb, col.a * inside);
}
