shader_type canvas_item;
render_mode unshaded;
// The weather over the map (`WeatherOverlay`): rain streaks, snowflakes, drifting fog and the
// tint of heat, drawn on one rect over the whole screen and under the panels. Everything is cut
// to art pixels (`pixel`) so it sits with the pixel art, and anchored to the world (`scroll`, the
// camera's offset in screen pixels) so it does not slide with the screen as the camera pans.
// `time` is the simulation's: the weather stops when the game is paused.

uniform float time = 0.0;
uniform vec2 scroll = vec2(0.0);
uniform vec2 rect_size = vec2(1600.0, 900.0);
uniform float pixel = 3.0;
uniform float rain = 0.0;
uniform float snow = 0.0;
uniform float fog = 0.0;
uniform float heat = 0.0;
// The day's light (`Climate.light_color`): at night the weather dims with the world.
uniform vec4 light : source_color = vec4(1.0);

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

vec4 over(vec4 below, vec3 colour, float alpha) {
	float a = clamp(alpha, 0.0, 1.0);
	float out_a = a + below.a * (1.0 - a);
	vec3 out_rgb = out_a > 0.0 ? (colour * a + below.rgb * below.a * (1.0 - a)) / out_a : vec3(0.0);
	return vec4(out_rgb, out_a);
}

void fragment() {
	// The art pixel this fragment falls in, counted in the world's frame.
	vec2 cell = floor((UV * rect_size + scroll) / pixel);
	vec4 colour = vec4(0.0);

	if (heat > 0.0) {
		colour = over(colour, vec3(1.0, 0.78, 0.38), heat * 0.10);
	}
	if (rain > 0.0) {
		colour = over(colour, vec3(0.20, 0.26, 0.36), rain * 0.16);
	}
	if (fog > 0.0) {
		float drift = value_noise(cell * 0.035 + vec2(time * 0.10, time * 0.03)) * 0.65
			+ value_noise(cell * 0.09 - vec2(time * 0.05, 0.0)) * 0.35;
		colour = over(colour, vec3(0.86, 0.88, 0.90), fog * (0.18 + 0.42 * smoothstep(0.35, 0.85, drift)));
	}
	if (rain > 0.0) {
		// Slanting streaks: each column has drops at its own phase, falling fast.
		vec2 slanted = vec2(cell.x + floor(cell.y * 0.4), cell.y);
		float column = slanted.x;
		float length_cells = 9.0;
		float fall = slanted.y - time * 70.0 - hash(vec2(column, 3.1)) * 400.0;
		float drop = floor(fall / length_cells);
		float within = fract(fall / length_cells);
		float present = step(1.0 - rain * 0.17, hash(vec2(column, drop)));
		float streak = present * step(within, 0.32);
		colour = over(colour, vec3(0.78, 0.85, 0.96), streak * 0.65);
	}
	if (snow > 0.0) {
		// Flakes on a drifting grid, one at most in each cell, swaying as they fall.
		float size = 11.0;
		vec2 moved = cell + vec2(sin(time * 0.8 + cell.y * 0.07) * 2.0, -time * 9.0);
		vec2 home = floor(moved / size);
		vec2 within = moved - home * size;
		vec2 spot = floor(vec2(hash(home + 1.7), hash(home + 5.3)) * (size - 2.0));
		float present = step(1.0 - snow * 0.45, hash(home));
		float flake = present * step(abs(within.x - spot.x - 0.5), 0.6) * step(abs(within.y - spot.y - 0.5), 0.6);
		colour = over(colour, vec3(0.97, 0.98, 1.0), flake * 0.9);
	}
	colour.rgb *= mix(vec3(1.0), light.rgb, 0.85);
	COLOR = colour;
}
