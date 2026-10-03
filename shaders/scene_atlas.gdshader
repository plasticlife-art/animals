shader_type canvas_item;
// Lit like the rest of the canvas, so `DayNightTint` darkens animals, props and carcasses
// at night along with the ground they stand on. Until 2026-10-03 this was an unshaded
// shader, which skips the canvas modulate as well as lights: at midnight the ground went
// dark blue and every animal and tree stayed in daylight.
varying flat vec4 region;
varying flat vec4 tint;
void vertex() {
	region = INSTANCE_CUSTOM;
	tint = COLOR;
}
void fragment() {
	vec2 pixel = TEXTURE_PIXEL_SIZE * 0.5;
	vec2 frame_uv = vec2(UV.x, 1.0 - UV.y);
	vec2 uv = clamp(region.xy + frame_uv * region.zw, region.xy + pixel, region.xy + region.zw - pixel);
	COLOR = texture(TEXTURE, uv) * tint;
}
