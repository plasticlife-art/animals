shader_type canvas_item;

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;
uniform float blur_radius : hint_range(0.0, 4.0) = 1.6;
uniform vec4 overlay_color : source_color = vec4(0.08, 0.09, 0.1, 0.34);


void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 texel = SCREEN_PIXEL_SIZE * blur_radius * 2.0;

	vec3 blurred = texture(screen_texture, uv).rgb * 0.28;
	blurred += texture(screen_texture, uv + vec2(texel.x, 0.0)).rgb * 0.12;
	blurred += texture(screen_texture, uv - vec2(texel.x, 0.0)).rgb * 0.12;
	blurred += texture(screen_texture, uv + vec2(0.0, texel.y)).rgb * 0.12;
	blurred += texture(screen_texture, uv - vec2(0.0, texel.y)).rgb * 0.12;
	blurred += texture(screen_texture, uv + texel).rgb * 0.09;
	blurred += texture(screen_texture, uv - texel).rgb * 0.09;
	blurred += texture(screen_texture, uv + vec2(texel.x, -texel.y)).rgb * 0.09;
	blurred += texture(screen_texture, uv + vec2(-texel.x, texel.y)).rgb * 0.09;

	vec3 tinted = mix(blurred, overlay_color.rgb, overlay_color.a);
	COLOR = vec4(tinted, 1.0);
}
