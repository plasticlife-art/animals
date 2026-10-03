shader_type canvas_item;

// Tints the ground by what the ecology has done to it: how much grass a cell holds, from
// bare earth through dry straw to a richer green, and worn paths where animals walk.
// UV carries the world position of the fragment; each grid is sampled in its own
// extent, because the grass grid and the trail grid do not end on the same edge.

uniform sampler2D grass_tex : filter_nearest, repeat_disable;
uniform sampler2D cap_tex : filter_nearest, repeat_disable;
uniform sampler2D trail_tex : filter_nearest, repeat_disable;
uniform vec2 grass_extent = vec2(1.0);
uniform vec2 trail_extent = vec2(1.0);
uniform vec4 bare_color : source_color = vec4(0.50, 0.38, 0.22, 0.70);
uniform vec4 dry_color : source_color = vec4(0.78, 0.68, 0.34, 0.42);
uniform vec4 mid_color : source_color = vec4(0.48, 0.58, 0.26, 0.10);
uniform vec4 lush_color : source_color = vec4(0.12, 0.40, 0.12, 0.42);
uniform vec4 trail_color : source_color = vec4(0.86, 0.79, 0.6, 0.6);
// Grass as a share of what the cell can hold, where each colour above is reached in
// full: bare earth, dry straw, the tile as drawn, lush grass. Between two it blends.
uniform vec4 grass_stops = vec4(0.08, 0.30, 0.55, 0.92);
// Distance walked through a trail cell: the trail starts at `x` and is full at `y`.
uniform vec2 trail_range = vec2(80.0, 800.0);
uniform float noise_size = 40.0;
uniform float noise_strength = 0.16;
// Off, the layer draws nothing of grass or trails.
uniform float ground_enabled = 1.0;

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

vec4 premultiplied(vec4 c) {
	return vec4(c.rgb * c.a, c.a);
}

// The colour a grass share is drawn with. Blended premultiplied, so a faint stop gives
// way to the next one's hue instead of dragging it towards its own. `GroundTraces.
// grass_tint()` is the same function in script, for tests; keep the two in step.
vec4 grass_tint(float share) {
	vec4 low = mid_color;
	vec4 high = lush_color;
	float t = smoothstep(grass_stops.z, grass_stops.w, share);
	if (share <= grass_stops.y) {
		low = bare_color;
		high = dry_color;
		t = smoothstep(grass_stops.x, grass_stops.y, share);
	} else if (share <= grass_stops.z) {
		low = dry_color;
		high = mid_color;
		t = smoothstep(grass_stops.y, grass_stops.z, share);
	}
	vec4 mixed = mix(premultiplied(low), premultiplied(high), t);
	return vec4(mixed.rgb / max(mixed.a, 0.0001), mixed.a);
}

void fragment() {
	vec2 world = UV;
	// Two octaves, so edges break up at the scale of a tussock and of a herd.
	float noise = value_noise(world / noise_size) * 0.65 + value_noise(world / (noise_size * 0.27)) * 0.35;
	float jitter = (noise - 0.5) * 2.0 * noise_strength;

	float cap = bilinear(cap_tex, world / grass_extent);
	float share = cap > 1.0 ? bilinear(grass_tex, world / grass_extent) / cap : 0.5;
	vec4 tint = grass_tint(share + jitter * 0.5);

	float wear = bilinear(trail_tex, world / trail_extent);
	float trail = smoothstep(trail_range.x, trail_range.y, wear * (1.0 + jitter * 1.5));

	vec3 rgb = tint.rgb;
	float alpha = tint.a * step(1.0, cap) * ground_enabled;
	float trail_alpha = trail * trail_color.a * ground_enabled;
	float out_alpha = trail_alpha + alpha * (1.0 - trail_alpha);
	rgb = (trail_color.rgb * trail_alpha + rgb * alpha * (1.0 - trail_alpha)) / max(out_alpha, 0.0001);
	COLOR = vec4(rgb, out_alpha);
}
