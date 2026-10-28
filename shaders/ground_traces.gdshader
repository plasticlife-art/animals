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
// Ponds with levels (`WaterSystem`): the field above is to each pond's bank; `water_id_tex`
// says which pond owns a texel and `water_shrink_tex` (N x 1) how far that pond's water stands
// in from its bank. Between the bank and the water the bed shows, mud deepening inwards.
uniform float water_levels = 0.0;
uniform sampler2D water_id_tex : filter_nearest, repeat_disable;
uniform sampler2D water_shrink_tex : filter_nearest, repeat_disable;
uniform vec4 bed_color : source_color = vec4(0.50, 0.40, 0.28, 0.70);
uniform float bed_fade = 30.0;
// Fords (`WaterMask.FORD_ID` in `water_id_tex`, uploaded while a river has any): the river runs
// shallow there over a bar of sand and pebbles, the sand showing through and the stones breaking
// the water white, so a crossing reads at a glance.
uniform float water_fords = 0.0;
uniform vec4 ford_color : source_color = vec4(0.74, 0.72, 0.54, 0.90);
uniform vec4 ford_stone_color : source_color = vec4(0.46, 0.44, 0.39, 0.95);

// Biome borders: the terrain grid is square cells, so its biomes meet in a staircase. Near a
// cell's edge a fragment looks a noise-warped way into the neighbouring cell, the warp stepped to
// the art's pixel, and takes that cell's surface when it is another biome on the same level -
// a ragged pixel edge from both sides. `biome_tex` holds per cell the biome (r, index into
// `surface_uv`), the elevation (g) and whether it is walkable (b); obstacle cells draw above
// this layer, so they keep their square edges. Top-down the surface is read from the terrain
// atlas in world space (the tile map's own variant may differ); isometric it is the biome's
// colour, which is what the placeholder diamonds' top faces are.
uniform float borders_enabled = 0.0;
uniform sampler2D biome_tex : filter_nearest, repeat_disable;
uniform float cell_size = 96.0;
// How far into the next cell the warp may look, and the scale its noise varies over, in cells.
uniform float border_reach = 0.45;
uniform float border_noise = 0.7;
// World units per art pixel: the edge steps by whole pixels.
uniform float art_px = 3.0;
uniform sampler2D terrain_atlas : filter_nearest, repeat_disable;
uniform float tile_world = 48.0;
uniform vec2 tile_uv = vec2(0.1666, 0.25);
uniform vec2 surface_uv[4];
uniform float flat_colors = 0.0;
uniform vec4 biome_colors[4];
// Curved borders (`visuals.borders.mode` "field", `BiomeField`): each biome's blurred share of
// the ground per cell, read at the art pixel moved by a noise warp; the biome weighing most is
// drawn, the first two dithered within `field_dither` of a tie. A pixel near its cell's centre
// keeps its biome (`field_core`), and takes only a biome its 3x3 has on its level. In this mode
// `biome_tex` holds the field packed (`BiomeField.packed_image()`): three weights in rgb, the
// fourth what they leave of 1, and in a the biome (bits 0-1), walkable (2), "its 3x3 is all its
// biome" (3) and the height (4-7). No texture of its own: the shader has no unit to spare.
uniform float border_mode = 0.0;
uniform float field_warp = 0.3;
uniform float field_warp_scale = 1.5;
uniform float field_core = 0.2;
uniform float field_dither = 0.12;
const int BAYER[16] = int[16](0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);

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

// The water field with each pond shrunk to its level: each of the four texels around the
// fragment moved in by its own pond's shrink, then blended as `bilinear()` blends.
float shrunk_at(ivec2 cell) {
	float d = texelFetch(water_tex, cell, 0).r;
	float pond = texelFetch(water_id_tex, cell, 0).r;
	if (pond < 0.0) {
		return d;
	}
	return d + texelFetch(water_shrink_tex, ivec2(int(pond + 0.5), 0), 0).r;
}

float shrunk_distance(vec2 uv) {
	ivec2 size = textureSize(water_tex, 0);
	vec2 p = uv * vec2(size) - 0.5;
	ivec2 i = ivec2(floor(p));
	vec2 f = p - vec2(i);
	ivec2 hi = size - ivec2(1);
	float a = shrunk_at(clamp(i, ivec2(0), hi));
	float b = shrunk_at(clamp(i + ivec2(1, 0), ivec2(0), hi));
	float c = shrunk_at(clamp(i + ivec2(0, 1), ivec2(0), hi));
	float d = shrunk_at(clamp(i + ivec2(1, 1), ivec2(0), hi));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// How much of a ford the fragment is in, 0 to 1, blended between the four texels about it.
float ford_share(vec2 uv) {
	ivec2 size = textureSize(water_id_tex, 0);
	vec2 p = uv * vec2(size) - 0.5;
	ivec2 i = ivec2(floor(p));
	vec2 f = p - vec2(i);
	ivec2 hi = size - ivec2(1);
	float a = step(texelFetch(water_id_tex, clamp(i, ivec2(0), hi), 0).r, -1.5);
	float b = step(texelFetch(water_id_tex, clamp(i + ivec2(1, 0), ivec2(0), hi), 0).r, -1.5);
	float c = step(texelFetch(water_id_tex, clamp(i + ivec2(0, 1), ivec2(0), hi), 0).r, -1.5);
	float d = step(texelFetch(water_id_tex, clamp(i + ivec2(1, 1), ivec2(0), hi), 0).r, -1.5);
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

// An integer hash of a lattice point, 0..1: `BiomeField.ihash()` bit for bit.
float ihash(ivec2 p) {
	uint h = (uint(p.x) * 73856093u) ^ (uint(p.y) * 19349663u);
	h ^= h >> 13u;
	h *= 1274126177u;
	h ^= h >> 16u;
	return float(h & 65535u) / 65535.0;
}

float inoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = p - i;
	f = f * f * (3.0 - 2.0 * f);
	ivec2 c = ivec2(i);
	return mix(mix(ihash(c), ihash(c + ivec2(1, 0)), f.x), mix(ihash(c + ivec2(0, 1)), ihash(c + ivec2(1, 1)), f.x), f.y);
}

vec4 field_texel(ivec2 cell) {
	vec3 w = texelFetch(biome_tex, cell, 0).rgb;
	return vec4(w, max(0.0, 1.0 - w.r - w.g - w.b));
}

vec4 field_at(vec2 p) {
	ivec2 size = textureSize(biome_tex, 0);
	ivec2 i = ivec2(floor(p));
	vec2 f = p - vec2(i);
	ivec2 hi = size - ivec2(1);
	vec4 a = field_texel(clamp(i, ivec2(0), hi));
	vec4 b = field_texel(clamp(i + ivec2(1, 0), ivec2(0), hi));
	vec4 c = field_texel(clamp(i + ivec2(0, 1), ivec2(0), hi));
	vec4 d = field_texel(clamp(i + ivec2(1, 1), ivec2(0), hi));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// The packed cell byte: biome, walkable, uniform 3x3, height.
int field_bits(ivec2 cell) {
	return int(round(texelFetch(biome_tex, cell, 0).a * 255.0));
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

// A biome's surface at `world`: the terrain atlas's in world space, its colour isometric.
vec4 surface_of(int biome, vec2 world) {
	if (flat_colors > 0.5) {
		return vec4(biome_colors[biome].rgb, 1.0);
	}
	vec2 in_tile = fract(world / tile_world);
	vec4 texel = texture(terrain_atlas, surface_uv[biome] + in_tile * tile_uv);
	return vec4(texel.rgb, 1.0);
}

// The surface of the biome a border fragment takes from its neighbour, or no alpha when it
// keeps its own.
vec4 border_surface(vec2 world) {
	if (borders_enabled < 0.5) {
		return vec4(0.0);
	}
	vec2 in_cell = fract(world / cell_size);
	float edge = min(min(in_cell.x, 1.0 - in_cell.x), min(in_cell.y, 1.0 - in_cell.y));
	if (edge > border_reach) {
		return vec4(0.0);
	}
	ivec2 grid = textureSize(biome_tex, 0);
	ivec2 own_cell = clamp(ivec2(floor(world / cell_size)), ivec2(0), grid - ivec2(1));
	vec4 own = texelFetch(biome_tex, own_cell, 0);
	vec2 stepped = (floor(world / art_px) + 0.5) * art_px;
	vec2 noise_at = stepped / (cell_size * border_noise);
	vec2 warp = vec2(value_noise(noise_at), value_noise(noise_at + vec2(17.3, 5.9))) - vec2(0.5);
	ivec2 other_cell = ivec2(floor((stepped + warp * 2.0 * border_reach * cell_size) / cell_size));
	if (other_cell == own_cell || any(lessThan(other_cell, ivec2(0))) || any(greaterThanEqual(other_cell, grid))) {
		return vec4(0.0);
	}
	vec4 other = texelFetch(biome_tex, other_cell, 0);
	// Another biome, walkable, at the same height.
	if (other.b < 0.5 || abs(other.r - own.r) < 0.002 || abs(other.g - own.g) > 0.002) {
		return vec4(0.0);
	}
	int biome = clamp(int(round(other.r * 255.0)), 0, 3);
	return surface_of(biome, world);
}

// The biome a fragment takes over its own cell's on a curved border, or no alpha keeping its
// own. `pixel` is the world a screen pixel covers: drawn coarser than the art, the pixel steps
// and the dither are left out, which would only shimmer.
vec4 field_surface(vec2 world, float pixel) {
	if (borders_enabled < 0.5) {
		return vec4(0.0);
	}
	ivec2 grid = textureSize(biome_tex, 0);
	ivec2 own_cell = clamp(ivec2(floor(world / cell_size)), ivec2(0), grid - ivec2(1));
	int own = field_bits(own_cell);
	if ((own & 8) != 0) {
		return vec4(0.0);
	}
	int own_biome = own & 3;
	int own_level = own >> 4;
	bool crisp = pixel <= art_px;
	vec2 q = crisp ? (floor(world / art_px) + 0.5) * art_px : world;
	float scale = cell_size * field_warp_scale;
	vec2 warp = vec2(inoise(q / scale), inoise(q / scale + vec2(17.0, 5.0))) - vec2(0.5);
	// The core, shaped by half the warp: a lone cell of a biome stays a blob, not a coin.
	vec2 centre = (vec2(own_cell) + 0.5) * cell_size;
	if (distance(q + warp * field_warp * cell_size, centre) < field_core * cell_size) {
		return vec4(0.0);
	}
	vec4 w = field_at((q + warp * 2.0 * field_warp * cell_size) / cell_size - 0.5);
	int first = own_biome;
	int second = own_biome;
	float best = -1.0;
	float next = -1.0;
	for (int k = 0; k < 4; k++) {
		float weight = w[k];
		if (weight > best || (weight == best && k == own_biome)) {
			second = first;
			next = best;
			first = k;
			best = weight;
		} else if (weight > next) {
			second = k;
			next = weight;
		}
	}
	int chosen = first;
	if (crisp && field_dither > 0.0 && best - next < field_dither) {
		ivec2 px = ivec2(floor(world / art_px));
		float threshold = (float(BAYER[(px.y & 3) * 4 + (px.x & 3)]) + 0.5) / 16.0;
		if (threshold < 0.5 * (1.0 - (best - next) / field_dither)) {
			chosen = second;
		}
	}
	if (chosen == own_biome) {
		return vec4(0.0);
	}
	bool found = false;
	for (int dy = -1; dy <= 1; dy++) {
		for (int dx = -1; dx <= 1; dx++) {
			ivec2 c = own_cell + ivec2(dx, dy);
			if (any(lessThan(c, ivec2(0))) || any(greaterThanEqual(c, grid))) {
				continue;
			}
			int t = field_bits(c);
			if ((t & 4) != 0 && (t & 3) == chosen && (t >> 4) == own_level) {
				found = true;
			}
		}
	}
	if (!found) {
		return vec4(0.0);
	}
	return surface_of(chosen, world);
}

// A sand shore around each pond and the water over it, laid over `ground`, the grass and
// trail colour already worked out. Away from water `ground` comes back unchanged.
// `pixel` is how much world one screen pixel covers, so the water's edge stays a crisp
// line at any zoom. Ripples run on wall time, so ponds keep moving while paused.
vec4 with_water(vec4 ground, vec2 world, float noise, float pixel) {
	if (water_enabled < 0.5) {
		return ground;
	}
	float edge = (noise - 0.5) * 2.0 * edge_noise;
	// `d` to the bank, where the sand is; `w` to the water's edge, the bank itself while ponds
	// have no levels.
	float d = bilinear(water_tex, world / water_extent) + edge;
	if (d > shore_width + pixel) {
		return ground;
	}
	float sand = (1.0 - smoothstep(0.0, shore_width, d)) * shore_color.a;
	vec4 result = over(vec4(shore_color.rgb, sand), ground);
	float w = d;
	if (water_levels > 0.5) {
		w = shrunk_distance(world / water_extent) + edge;
		float bed = (1.0 - smoothstep(-pixel, pixel, d)) * smoothstep(0.0, bed_fade, -d) * bed_color.a;
		result = over(vec4(bed_color.rgb, bed), result);
	}
	float inside = 1.0 - smoothstep(-pixel, pixel, w);
	if (inside <= 0.0) {
		return result;
	}
	d = w;
	vec4 water = mix(shallow_color, deep_color, smoothstep(0.0, 1.0, -d / water_depth));
	vec2 flow = TIME * ripple_speed * vec2(1.0, 0.73);
	float ripple = value_noise(world / ripple_size + flow) - value_noise(world / (ripple_size * 0.61) - flow);
	water.rgb += ripple_strength * ripple;
	float foam = (1.0 - smoothstep(0.0, foam_width, -d)) * (0.6 + 0.4 * sin(TIME * 1.3 + d * 0.15));
	water = over(vec4(foam_color.rgb, foam * foam_color.a), water);
	if (water_fords > 0.5) {
		float ford = smoothstep(0.3, 0.7, ford_share(world / water_extent) + (noise - 0.5) * 0.4);
		if (ford > 0.0) {
			// In the art's own pixels: sand under clear water, stones a few pixels across with
			// their tops lit, and the odd white glint where the stream runs over them.
			vec2 px = floor(world / art_px);
			float stone = step(0.74, value_noise(px * 0.21));
			// Lit from the upper left, as the rest of the art: a stone's pixel whose upper-left
			// neighbour is no stone.
			float rim = stone * (1.0 - step(0.74, value_noise((px - vec2(1.0)) * 0.21)));
			vec3 bar = mix(shallow_color.rgb, ford_color.rgb, 0.62) + ripple_strength * ripple;
			bar = mix(bar, ford_stone_color.rgb, stone * ford_stone_color.a);
			bar = mix(bar, foam_color.rgb, rim * 0.6);
			float glint = step(0.9, value_noise(px * 0.3 + flow * 40.0));
			bar = mix(bar, foam_color.rgb, glint * foam_color.a);
			water = vec4(mix(water.rgb, bar, ford * ford_color.a), mix(water.a, 1.0, ford * 0.5));
		}
	}
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
	// Tile, then a neighbour's surface where the border reaches in, then the grass and trails.
	vec4 border = border_mode > 0.5 ? field_surface(world, pixel) : border_surface(world);
	vec4 ground = over(vec4(rgb, out_alpha), border);
	COLOR = with_water(ground, world, noise, pixel);
}
