shader_type canvas_item;
render_mode unshaded;

// Samples one frame out of a sprite atlas per MultiMesh instance.
//
// The frame is chosen on the CPU in scripts/ui/agent_renderer.gd and handed
// over as instance custom data: x = column, y = row, both in whole frames.
// Horizontal facing is not handled here - the renderer mirrors the instance
// transform instead, which flips the quad and its UVs together for free.

// One frame's extent in UV space: frame_px / atlas_px on each axis.
uniform vec2 frame_size_uv = vec2(0.25, 0.2);
uniform vec4 outline_color : source_color = vec4(0.10, 0.08, 0.06, 0.9);
// Outline thickness in atlas texels. Zero disables the whole branch.
uniform float outline_width = 0.0;

varying flat vec2 v_frame;
varying flat vec4 v_tint;

void vertex() {
	v_frame = INSTANCE_CUSTOM.xy;
	// The instance colour is read here rather than in fragment() on purpose.
	// On the Compatibility renderer, reading the built-in COLOR inside
	// fragment() of a MultiMesh canvas_item shader corrupts the interpolated
	// UV - verified against this atlas, where it turned one frame into a
	// shrunken smear of several. Carrying the colour through a varying of our
	// own avoids it. Do not "simplify" this back to `* COLOR` in fragment().
	v_tint = COLOR;
}

void fragment() {
	// QuadMesh carries the 3D UV convention, where V grows upwards, while
	// texture rows are indexed downwards. Measured on the quad: V is 0.98 at
	// its top edge and 0.02 at its bottom. Flipping it here keeps the row
	// index in the custom data counting downwards from the top of the atlas,
	// which is how the sheet is laid out.
	vec2 frame_uv = vec2(UV.x, 1.0 - UV.y);
	vec2 frame_base = v_frame * frame_size_uv;
	vec2 uv = frame_base + frame_uv * frame_size_uv;
	vec4 texel = texture(TEXTURE, uv);
	vec4 result = texel * v_tint;

	// No early `return` here: Godot rejects it in the fragment processor, the
	// shader then fails to compile, and the fallback material draws the whole
	// atlas as a grid of frames instead of one sprite.
	if (outline_width > 0.0 && texel.a < 0.01) {
		vec2 step_uv = outline_width / vec2(textureSize(TEXTURE, 0));
		// Neighbour samples are clamped inside this frame's own rectangle.
		// Without the clamp the outline of one frame reads pixels out of the
		// frame packed next to it in the atlas.
		vec2 lo = frame_base;
		vec2 hi = frame_base + frame_size_uv - step_uv;
		float neighbour = 0.0;
		neighbour = max(neighbour, texture(TEXTURE, clamp(uv + vec2(step_uv.x, 0.0), lo, hi)).a);
		neighbour = max(neighbour, texture(TEXTURE, clamp(uv - vec2(step_uv.x, 0.0), lo, hi)).a);
		neighbour = max(neighbour, texture(TEXTURE, clamp(uv + vec2(0.0, step_uv.y), lo, hi)).a);
		neighbour = max(neighbour, texture(TEXTURE, clamp(uv - vec2(0.0, step_uv.y), lo, hi)).a);
		if (neighbour > 0.5) {
			result = vec4(outline_color.rgb, outline_color.a * v_tint.a);
		}
	}

	COLOR = result;
}
