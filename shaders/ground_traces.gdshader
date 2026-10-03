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

// Watering holes: a signed distance field, negative inside the water (`WaterMask`).
// Lengths are world units; the layer scales them from art pixels.
uniform sampler2D water_tex : filter_nearest, repeat_disable;
uniform vec2 water_extent = vec2(1.0);
uniform float water_enabled = 0.0;
uniform vec4 shallow_color : source_color = vec4(0.33, 0.60, 0.72, 0.85);
uniform vec4 deep_color : source_color = vec4(0.10, 0.28, 0.46, 0.93);
uniform vec4 foam_color : source_color = vec4(0.90, 0.96, 0.97, 0.55);
uniform vec4 shore_color : source_color = vec4(0.79, 0.71, 0.50, 0.50);
// How far in from the edge the water is at its deepest colour.
uniform float water_depth = 144.0;
uniform float shore_width = 36.0;
uniform float foam_width = 9.0;
// How far the noise moves the edge, so a pond is not a perfect circle.
uniform float edge_noise = 15.0;
uniform float ripple_size = 120.0;
uniform float ripple_speed = 0.06;
uniform float ripple_strength = 0.06;

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

// `top` over `bottom`, both straight alpha.
vec4 over(vec4 top, vec4 bottom) {
	float alpha = top.a + bottom.a * (1.0 - top.a);
	vec3 rgb = (top.rgb * top.a + bottom.rgb * bottom.a * (1.0 - top.a)) / max(alpha, 0.0001);
	return vec4(rgb, alpha);
}

// A sand shore around each pond and the water over it, laid over `ground`, the grass and
// trail colour already worked out. Away from water `ground` comes back unchanged.
// `pixel` is how much world one screen pixel covers, so the water's edge stays a crisp
// line at any zoom. Ripples run on wall time, so ponds keep moving while paused.
vec4 with_water(vec4 ground, vec2 world, float noise, float pixel) {
	if (water_enabled < 0.5) {
		return ground;
	}
	float d = bilinear(water_tex, world / water_extent) + (noise - 0.5) * 2.0 * edge_noise;
	if (d > shore_width + pixel) {
		return ground;
	}
	float sand = (1.0 - smoothstep(0.0, shore_width, d)) * shore_color.a;
	vec4 result = over(vec4(shore_color.rgb, sand), ground);
	float inside = 1.0 - smoothstep(-pixel, pixel, d);
	if (inside <= 0.0) {
		return result;
	}
	vec4 water = mix(shallow_color, deep_color, smoothstep(0.0, 1.0, -d / water_depth));
	vec2 flow = TIME * ripple_speed * vec2(1.0, 0.73);
	float ripple = value_noise(world / ripple_size + flow) - value_noise(world / (ripple_size * 0.61) - flow);
	water.rgb += ripple_strength * ripple;
	float foam = (1.0 - smoothstep(0.0, foam_width, -d)) * (0.6 + 0.4 * sin(TIME * 1.3 + d * 0.15));
	water = over(vec4(foam_color.rgb, foam * foam_color.a), water);
	return over(vec4(water.rgb, water.a * inside), result);
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
	float pixel = max(length(fwidth(world)), 0.001);
	COLOR = with_water(vec4(rgb, out_alpha), world, noise, pixel);
}
