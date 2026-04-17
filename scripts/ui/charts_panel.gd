class_name ChartsPanel
extends PanelContainer

var simulation_manager: SimulationManager


func bind_manager(manager: SimulationManager) -> void:
	simulation_manager = manager
	simulation_manager.tick_completed.connect(_on_tick_completed)
	queue_redraw()


func request_refresh() -> void:
	if is_visible_in_tree():
		queue_redraw()


func _draw() -> void:
	var font = ThemeDB.fallback_font
	var font_size := ThemeDB.fallback_font_size
	var rect := Rect2(Vector2.ZERO, size)
	draw_rect(rect, Color(0.06, 0.07, 0.08, 0.82), true)
	draw_rect(rect, Color(0.22, 0.24, 0.26), false, 1.5)

	if simulation_manager == null or simulation_manager.stats_system == null:
		if font != null:
			draw_string(font, Vector2(16.0, 28.0), "Waiting for simulation", HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, Color.WHITE)
		return

	var series := simulation_manager.stats_system.get_series()
	if series.size() < 2:
		if font != null:
			draw_string(font, Vector2(16.0, 28.0), "Collecting telemetry", HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, Color.WHITE)
		return

	var population_rect := Rect2(14.0, 28.0, size.x - 28.0, size.y * 0.5 - 36.0)
	var trends_rect := Rect2(14.0, size.y * 0.54, size.x - 28.0, size.y * 0.34)
	_draw_chart_background(population_rect, "Population", font, font_size)
	_draw_chart_background(trends_rect, "Birth / Death Trends", font, font_size)

	_draw_series_line(series, population_rect, "herbivore_population", Color(0.61, 0.88, 0.52))
	_draw_series_line(series, population_rect, "predator_population", Color(0.98, 0.45, 0.2))
	_draw_combined_line(series, trends_rect, ["births_herbivore", "births_predator"], Color(0.39, 0.82, 1.0))
	_draw_combined_line(series, trends_rect, ["deaths_herbivore", "deaths_predator"], Color(1.0, 0.5, 0.65))

	if font != null:
		var latest: Dictionary = series[-1]
		draw_string(font, Vector2(20.0, size.y - 32.0), "H green  P orange  Births blue  Deaths pink", HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, Color(0.88, 0.9, 0.92))
		draw_string(
			font,
			Vector2(20.0, size.y - 16.0),
			"Avg energy %.1f  Avg hunger %.1f  Hunt %.2f" % [
				float(latest.get("average_energy", 0.0)),
				float(latest.get("average_hunger", 0.0)),
				float(latest.get("hunt_success_rate", 0.0)),
			],
			HORIZONTAL_ALIGNMENT_LEFT,
			-1.0,
			font_size,
			Color(0.88, 0.9, 0.92)
		)
		draw_string(font, Vector2(size.x - 190.0, size.y - 18.0), "Tick %d" % int(latest.get("tick", 0)), HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, Color(0.88, 0.9, 0.92))


func _draw_chart_background(rect: Rect2, label: String, font, font_size: int) -> void:
	draw_rect(rect, Color(0.11, 0.13, 0.14, 0.94), true)
	draw_rect(rect, Color(0.24, 0.27, 0.29), false, 1.0)
	if font != null:
		draw_string(font, rect.position + Vector2(8.0, 18.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, Color(0.92, 0.94, 0.95))


func _draw_series_line(series: Array, rect: Rect2, key: String, color: Color) -> void:
	var max_value := 0.0
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
