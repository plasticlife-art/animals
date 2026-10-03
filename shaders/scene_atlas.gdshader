shader_type canvas_item;
// Lit like the rest of the canvas, so `DayNightTint` darkens animals, props and carcasses
// at night along with the ground they stand on. Until 2026-10-03 this was an unshaded
// shader, which skips the canvas modulate as well as lights: at midnight the ground went
// dark blue and every animal and tree stayed in daylight.
//
// Wind: plants sway, everything else in this one batch keeps still. A prop is told by where
// its frame sits in the packed atlas - the props band (`props_uv`), cut into slots of
// `props_cell_uv` - and each slot has its weight (`sway_weights`, from `visuals.wind.weights`
// by prop group: trees, bushes and flowers sway, stones do not). Animals and bodies sit outside
// the band and read 0. The quad's top edge is sheared and its bottom edge, the ground point,
// stays put; VERTEX is still the quad's own (the instance transform is in MODEL_MATRIX), so a
// shift in canvas pixels is divided by the quad's width. The phase comes from where the prop
// stands, so a gust runs across the field rather than every tree nodding together.
varying flat vec4 region;
varying flat vec4 tint;

uniform bool wind_enabled = false;
uniform vec4 props_uv = vec4(0.0, 2.0, 0.0, 0.0);
uniform vec2 props_cell_uv = vec2(1.0, 1.0);
uniform int props_columns = 8;
uniform float sway_weights[64];
uniform float wind_amplitude_px = 3.0;
uniform float wind_speed = 1.4;
uniform float wind_gust = 0.35;
uniform float wind_wavelength_px = 900.0;

void vertex() {
	region = INSTANCE_CUSTOM;
	tint = COLOR;
	if (wind_enabled && region.y >= props_uv.y - 0.0001 && region.y < props_uv.y + props_uv.w) {
		ivec2 slot = ivec2(floor((region.xy - props_uv.xy) / props_cell_uv + vec2(0.5)));
		int index = slot.y * props_columns + slot.x;
		float weight = (index >= 0 && index < 64) ? sway_weights[index] : 0.0;
		if (weight > 0.0) {
			vec2 origin = MODEL_MATRIX[3].xy;
			float width = max(1.0, length(MODEL_MATRIX[0].xy));
			float phase = dot(origin, vec2(1.0, 0.6)) / max(1.0, wind_wavelength_px) * 6.2831853;
			float wave = sin(TIME * wind_speed + phase) + wind_gust * sin(TIME * wind_speed * 2.3 + phase * 1.7);
			// V grows upwards on this quad: 1 along its top edge, 0 along the ground.
			VERTEX.x += weight * wind_amplitude_px * wave * clamp(UV.y, 0.0, 1.0) / width;
		}
	}
}

void fragment() {
	vec2 pixel = TEXTURE_PIXEL_SIZE * 0.5;
	vec2 frame_uv = vec2(UV.x, 1.0 - UV.y);
	vec2 uv = clamp(region.xy + frame_uv * region.zw, region.xy + pixel, region.xy + region.zw - pixel);
	COLOR = texture(TEXTURE, uv) * tint;
}
