shader_type canvas_item;

// Remotion applies `filter: saturate() contrast() brightness()` to the backdrop
// photo. CSS runs those in the order written, and the order is not commutative
// — contrast pivots around mid-grey, so brightening first moves the pivot — so
// they are applied here in the same sequence rather than folded together.
//
// Existing as a shader rather than a baked-in look is the point: all three are
// uniforms, mirrored onto @export properties, and therefore keyable. Grading
// the photo over the shot is something the Remotion original cannot animate.

uniform float saturate_amount : hint_range(0.0, 2.0) = 0.75;
uniform float contrast_amount : hint_range(0.5, 2.0) = 1.06;
uniform float brightness_amount : hint_range(0.2, 1.5) = 0.80;

// Rec. 709 luma, which is what a browser's saturate() filter uses.
const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);

void fragment() {
	vec4 src = texture(TEXTURE, UV);

	vec3 color = src.rgb;
	color = mix(vec3(dot(color, LUMA)), color, saturate_amount);
	color = (color - 0.5) * contrast_amount + 0.5;
	color = color * brightness_amount;

	COLOR = vec4(clamp(color, vec3(0.0), vec3(1.0)), src.a);
}
