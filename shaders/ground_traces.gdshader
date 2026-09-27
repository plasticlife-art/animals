shader_type canvas_item;

// Tints the ground by what the ecology has done to it: bare earth where grass is
// grazed down, a richer green where it stands tall, and worn paths where animals walk.
// UV carries the world position of the fragment; each grid is sampled in its own
// extent, because the grass grid and the trail grid do not end on the same edge.

uniform sampler2D grass_tex : filter_nearest, repeat_disable;
uniform sampler2D cap_tex : filter_nearest, repeat_disable;
uniform sampler2D trail_tex : filter_nearest, repeat_disable;
uniform vec2 grass_extent = vec2(1.0);
uniform vec2 trail_extent = vec2(1.0);
uniform vec4 bare_color : source_color = vec4(0.54, 0.43, 0.27, 0.6);
uniform vec4 lush_color : source_color = vec4(0.16, 0.42, 0.14, 0.3);
uniform vec4 trail_color : source_color = vec4(0.86, 0.79, 0.6, 0.6);
// Grass as a share of what the cell can hold: the tint starts at `x` and is full at `y`.
uniform vec2 bare_range = vec2(0.4, 0.08);
uniform vec2 lush_range = vec2(0.62, 0.95);
// Distance walked through a trail cell, same meaning.
uniform vec2 trail_range = vec2(80.0, 800.0);
uniform float noise_size = 40.0;
uniform float noise_strength = 0.18;

// Float textures are read texel by texel and blended here, which every GLES3 driver
// can do; filtering them in hardware is an extension not all of them have.
float bilinear(sampler2D tex, vec2 uv) {
	ivec2 size = textureSize(tex, 0);
	vec2 p = uv * vec2(size) - 0.5;
	ivec2 i = ivec2(floor(p));
	vec2 f = p - vec2(i);
	ivec2 hi = size - ivec2(1);
	float a = texelFetch(tex, clamp(i, ivec2(0), hi), 0).r;
	float b = texelFetch(tex, clamp(i + ivec2(1, 0), ivec2(0), hi), 0).r;
	float c = texelFetch(tex, clamp(i + ivec2(0, 1), ivec2(0), hi), 0).r;
	float d = texelFetch(tex, clamp(i + ivec2(1, 1), ivec2(0), hi), 0).r;
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = p - i;
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

void fragment() {
	vec2 world = UV;
	// Two octaves, so edges break up at the scale of a tussock and of a herd.
	float noise = value_noise(world / noise_size) * 0.65 + value_noise(world / (noise_size * 0.27)) * 0.35;
	float jitter = (noise - 0.5) * 2.0 * noise_strength;

	float cap = bilinear(cap_tex, world / grass_extent);
	float share = cap > 1.0 ? bilinear(grass_tex, world / grass_extent) / cap : 0.5;
	float shown = share + jitter * 0.5;
	// `bare_range` runs downwards, and smoothstep is only defined for rising edges.
	float bare = (1.0 - smoothstep(bare_range.y, bare_range.x, shown)) * step(1.0, cap);
	float lush = smoothstep(lush_range.x, lush_range.y, shown) * step(1.0, cap);

	float wear = bilinear(trail_tex, world / trail_extent);
	float trail = smoothstep(trail_range.x, trail_range.y, wear * (1.0 + jitter * 1.5));

	vec3 rgb = bare > 0.0 ? bare_color.rgb : lush_color.rgb;
	float alpha = bare > 0.0 ? bare * bare_color.a : lush * lush_color.a;
	float trail_alpha = trail * trail_color.a;
	float out_alpha = trail_alpha + alpha * (1.0 - trail_alpha);
	rgb = (trail_color.rgb * trail_alpha + rgb * alpha * (1.0 - trail_alpha)) / max(out_alpha, 0.0001);
	COLOR = vec4(rgb, out_alpha);
}
