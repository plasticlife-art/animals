class_name ChartsPanel
extends PanelContainer

var simulation_manager: SimulationManager

## Read once at bind time so `_draw()` stays free of dictionary walks.
var _season_colors: Array = []


func bind_manager(manager: SimulationManager) -> void:
	simulation_manager = manager
	_cache_season_colors()
	if not simulation_manager.tick_completed.is_connected(_on_tick_completed):
		simulation_manager.tick_completed.connect(_on_tick_completed)
	queue_redraw()


func request_refresh() -> void:
	if is_visible_in_tree():
		queue_redraw()


## Padding around the panel's contents, and the gap between the two charts.
const PADDING := 14.0
const CHART_GAP := 10.0
## The trend lines, named once so the curve and its legend entry cannot drift.
const BIRTHS_COLOR := Color(0.39, 0.82, 1.0)
const DEATHS_COLOR := Color(1.0, 0.5, 0.65)
const LEGEND_GAP := 12.0


func _draw() -> void:
	# The panel's own theme, not ThemeDB's fallback. The fallback is a fixed
	# 16 px regardless of the HUD's type scale, so this used to be the one part
	# of the interface that ignored the theme entirely.
	var font := get_theme_default_font()
	var font_size := get_theme_default_font_size()
	var rect := Rect2(Vector2.ZERO, size)
	draw_rect(rect, Color(0.06, 0.07, 0.08, 0.82), true)
	draw_rect(rect, Color(0.22, 0.24, 0.26), false, 1.5)
	if font == null:
		return
	var line_height: float = font.get_height(font_size)

	if simulation_manager == null or simulation_manager.stats_system == null:
		draw_string(font, Vector2(PADDING, PADDING + line_height), "Waiting for simulation",
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, Color.WHITE)
		return

	var series := simulation_manager.stats_system.get_series()
	if series.size() < 2:
		draw_string(font, Vector2(PADDING, PADDING + line_height), "Collecting telemetry",
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, Color.WHITE)
		return

	# The two footer lines are measured and reserved before the charts are laid
	# out. Placing them at fixed offsets from the bottom, as this did, put them
	# underneath the lower chart as soon as the type scale changed.
	var footer_height: float = line_height * 2.0 + 4.0
	var charts_height: float = maxf(40.0, size.y - PADDING * 2.0 - footer_height)
	var chart_width: float = size.x - PADDING * 2.0
	var population_height: float = charts_height * 0.55
	var population_rect := Rect2(PADDING, PADDING, chart_width, population_height)
	var trends_rect := Rect2(
		PADDING, population_rect.end.y + CHART_GAP,
		chart_width, charts_height - population_height - CHART_GAP)
	_draw_chart_background(population_rect, "Population", font, font_size)
	_draw_chart_background(trends_rect, "Birth / Death Trends", font, font_size)
	_draw_season_bands(series, population_rect)
	_draw_season_bands(series, trends_rect)

	# One shared vertical scale for the population lines. Normalizing each against
	# its own maximum made a herd of 300 and a flock of 30 draw the same height,
	# which is exactly the comparison this chart exists to show.
	var population_keys: Array = []
	var population_colors: Array = []
	var birth_keys: Array = []
	var death_keys: Array = []
	for entry in _species_entries():
		population_keys.append("%s_population" % entry["id"])
		population_colors.append(entry["color"])
		birth_keys.append("births_%s" % entry["id"])
		death_keys.append("deaths_%s" % entry["id"])
	var population_max := _series_max(series, population_keys)
	for index in range(population_keys.size()):
		_draw_series_line(series, population_rect, population_keys[index], population_colors[index], population_max)
	_draw_combined_line(series, trends_rect, birth_keys, BIRTHS_COLOR)
	_draw_combined_line(series, trends_rect, death_keys, DEATHS_COLOR)

	var latest: Dictionary = series[-1]
	var ink := Color(0.88, 0.9, 0.92)
	var stats_baseline: float = size.y - PADDING
	var legend_baseline: float = stats_baseline - line_height
	# Each name in the colour of its own line. The legend used to name the colour
	# in words - "H green  P orange" - which stopped saying anything once it was
	# generated from the species registry instead of written out by hand, leaving
	# a row of bare names and no way to tell which curve was which.
	var legend: Array = []
	for entry in _species_entries():
		legend.append([String(entry["label"]), entry["color"]])
	legend.append(["Births", BIRTHS_COLOR])
	legend.append(["Deaths", DEATHS_COLOR])
	# The tick counter shares this baseline from the right, so the legend stops
	# rather than running underneath it - with a fourth species and a five-digit
	# tick the two would otherwise meet in the middle.
	var tick_text := "Tick %d" % int(latest.get("tick", 0))
	var tick_width: float = font.get_string_size(
		tick_text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x
	var legend_limit: float = size.x - PADDING - tick_width - LEGEND_GAP
	var legend_x: float = PADDING
	for item in legend:
		var text: String = item[0]
		var text_width: float = font.get_string_size(
			text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x
		if legend_x + text_width > legend_limit:
			break
		draw_string(font, Vector2(legend_x, legend_baseline), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, item[1])
		legend_x += text_width + LEGEND_GAP
	draw_string(font, Vector2(PADDING, stats_baseline),
		"Avg energy %.1f  Avg hunger %.1f  Hunt %.2f" % [
			float(latest.get("average_energy", 0.0)),
			float(latest.get("average_hunger", 0.0)),
			float(latest.get("hunt_success_rate", 0.0)),
		],
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, ink)
	# Right-aligned from its measured width rather than a guessed offset, so a
	# five-digit tick cannot run off the panel or into the line beside it. Both
	# measured above, where the legend needs the same number to know where to stop.
	draw_string(font, Vector2(size.x - PADDING - tick_width, legend_baseline), tick_text,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, ink)


func _cache_season_colors() -> void:
	_season_colors.clear()
	if simulation_manager == null:
		return
	for season in simulation_manager.config_bundle.get("world", {}) \
			.get("climate", {}).get("seasons", []):
		var raw: Array = season.get("band_color", [0.5, 0.5, 0.5, 0.1])
		_season_colors.append(Color(
			float(raw[0]), float(raw[1]), float(raw[2]),
			float(raw[3]) if raw.size() > 3 else 0.1))


## Contiguous runs of one season, washed in behind the lines. Taken from the
## series itself rather than from the clock, so the bands stay aligned with the
## samples even after a save is loaded mid-year.
##
## A single run spanning the whole window is skipped: that is either a disabled
## clock (every row reports season 0) or a window narrower than one season, and
## either way a full-width flat tint carries no information.
func _draw_season_bands(series: Array, rect: Rect2) -> void:
	var count := series.size()
	if _season_colors.is_empty() or count < 2:
		return
	var runs: Array = []
	var run_start := 0
	var run_index := int(series[0].get("season_index", -1))
	for index in range(1, count + 1):
		var next_index := -999 if index == count else int(series[index].get("season_index", -1))
		if next_index == run_index:
			continue
		if run_index >= 0 and run_index < _season_colors.size():
			runs.append([run_start, index - 1, run_index])
		run_start = index
		run_index = next_index
	if runs.size() < 2:
		return
	for run in runs:
		var span_from: float = rect.position.x + (float(run[0]) / maxf(1.0, count - 1.0)) * rect.size.x
		var span_to: float = rect.position.x + (float(run[1]) / maxf(1.0, count - 1.0)) * rect.size.x
		draw_rect(Rect2(span_from, rect.position.y, maxf(1.0, span_to - span_from), rect.size.y),
			_season_colors[run[2]], true)


func _draw_chart_background(rect: Rect2, label: String, font, font_size: int) -> void:
	draw_rect(rect, Color(0.11, 0.13, 0.14, 0.94), true)
	draw_rect(rect, Color(0.24, 0.27, 0.29), false, 1.0)
	if font != null:
		draw_string(font, rect.position + Vector2(8.0, 18.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, Color(0.92, 0.94, 0.95))


## Species in registry order, with the colour and name the rest of the interface
## uses for them. Read from `visuals.json` so the chart, the minimap and the
## sprites cannot disagree about what a species looks like.
func _species_entries() -> Array:
	var entries: Array = []
	if simulation_manager == null:
		return entries
	var species_visuals: Dictionary = simulation_manager.config_bundle.get("visuals", {}).get("species", {})
	var species_config: Dictionary = simulation_manager.config_bundle.get("species", {})
	var ids: Array = species_config.keys()
	ids.sort_custom(func(a, b):
		return int(species_config[a].get("role", {}).get("slot", 0)) < int(species_config[b].get("role", {}).get("slot", 0)))
	for species_id in ids:
		var rgb: Array = species_visuals.get(species_id, {}).get("ui_color", [0.8, 0.8, 0.8])
		entries.append({
			"id": str(species_id),
			"color": Color(float(rgb[0]), float(rgb[1]), float(rgb[2])),
			"label": str(species_config[species_id].get("role", {}).get("label", species_id)),
		})
	return entries


func _series_max(series: Array, keys: Array) -> float:
	var max_value := 0.0
	for row in series:
		for key in keys:
			max_value = maxf(max_value, float(row.get(key, 0.0)))
	return maxf(max_value, 1.0)


func _draw_series_line(series: Array, rect: Rect2, key: String, color: Color, max_value: float = 0.0) -> void:
	if max_value <= 0.0:
		for row in series:
			max_value = maxf(max_value, float(row.get(key, 0.0)))
	if max_value <= 0.0:
		max_value = 1.0

	var points := PackedVector2Array()
	var count := series.size()
	for index in range(count):
		var value := float(series[index].get(key, 0.0))
		var x := rect.position.x + (float(index) / maxf(1.0, count - 1.0)) * rect.size.x
		var y := rect.end.y - (value / max_value) * (rect.size.y - 20.0)
		points.append(Vector2(x, y))

	if points.size() >= 2:
		draw_polyline(points, color, 2.0, true)


func _draw_combined_line(series: Array, rect: Rect2, keys: Array, color: Color) -> void:
	var max_value := 0.0
	for row in series:
		var combined := 0.0
		for key in keys:
			combined += float(row.get(key, 0.0))
		max_value = maxf(max_value, combined)
	if max_value <= 0.0:
		max_value = 1.0

	var points := PackedVector2Array()
	var count := series.size()
	for index in range(count):
		var combined := 0.0
		for key in keys:
			combined += float(series[index].get(key, 0.0))
		var x := rect.position.x + (float(index) / maxf(1.0, count - 1.0)) * rect.size.x
		var y := rect.end.y - (combined / max_value) * (rect.size.y - 20.0)
		points.append(Vector2(x, y))

	if points.size() >= 2:
		draw_polyline(points, color, 2.0, true)


func _on_tick_completed(tick: int, snapshot: Dictionary) -> void:
	if int(snapshot.get("tick", -1)) != tick:
		return
	if simulation_manager == null or not simulation_manager.should_refresh_ui_on_tick(tick):
		return
	request_refresh()
