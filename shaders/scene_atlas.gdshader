shader_type canvas_item;
render_mode unshaded;
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
