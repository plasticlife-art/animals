extends Control

## Season, year and clock, always on screen.
##
## Deliberately not part of the debug panel: `MainController._ready()` calls
## `set_hud_visible(false)`, so anything in there is invisible until Tab. The
## MiniMap is the precedent for "up during play, hidden by the start menu", and
## this follows it - including surviving Tab.

const PADDING := 10.0
const BAR_HEIGHT := 8.0
const ARC_HEIGHT := 18.0

var simulation_manager: SimulationManager

var _season_colors: Array = []
var _season_labels: Array = []


func bind_manager(manager: SimulationManager) -> void:
	simulation_manager = manager
	_cache_season_palette()
	if not simulation_manager.tick_completed.is_connected(_on_tick_completed):
		simulation_manager.tick_completed.connect(_on_tick_completed)
	queue_redraw()


## Read once at bind time so `_draw()` stays free of dictionary walks.
func _cache_season_palette() -> void:
	_season_colors.clear()
	_season_labels.clear()
	if simulation_manager == null:
		return
	var seasons: Array = simulation_manager.config_bundle.get("world", {}) \
		.get("climate", {}).get("seasons", [])
	for season in seasons:
		var raw: Array = season.get("band_color", [0.5, 0.5, 0.5, 0.5])
		_season_colors.append(Color(
			float(raw[0]), float(raw[1]), float(raw[2]),
			float(raw[3]) if raw.size() > 3 else 1.0))
		_season_labels.append(str(season.get("label", season.get("id", "?"))))


func _get_climate():
	if simulation_manager == null or simulation_manager.world_state == null:
		return null
	var climate = simulation_manager.world_state.climate
	if climate == null or not climate.enabled:
		return null
	return climate


func _draw() -> void:
	var climate = _get_climate()
	if climate == null:
		return
	var font := get_theme_default_font()
	var font_size := get_theme_default_font_size()
	if font == null:
		return

	var rect := Rect2(Vector2.ZERO, size)
	draw_rect(rect, Color(0.06, 0.07, 0.08, 0.82), true)
	draw_rect(rect, Color(0.22, 0.24, 0.26), false, 1.5)

	var line_height: float = font.get_height(font_size)
	var ink := Color(0.88, 0.9, 0.92)
	var baseline: float = PADDING + line_height

	var title := "%s · Год %d" % [climate.season_label, climate.year + 1]
	draw_string(font, Vector2(PADDING, baseline), title,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, ink)

	# Right-aligned from its measured width, so a wide font cannot push the
	# clock off the panel or into the title.
	var clock := climate.clock_text()
	var clock_width: float = font.get_string_size(
		clock, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x
	draw_string(font, Vector2(size.x - PADDING - clock_width, baseline), clock,
		HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, ink)

	var bar_top: float = baseline + 6.0
	_draw_season_bar(Rect2(PADDING, bar_top, size.x - PADDING * 2.0, BAR_HEIGHT), climate)
	_draw_day_arc(Rect2(PADDING, bar_top + BAR_HEIGHT + 6.0, size.x - PADDING * 2.0, ARC_HEIGHT), climate)


## Four segments, one per season, with a marker riding the year.
func _draw_season_bar(rect: Rect2, climate) -> void:
	var count: int = _season_colors.size()
	if count == 0:
		return
	var segment_width: float = rect.size.x / float(count)
	for index in range(count):
		var segment := Rect2(rect.position.x + segment_width * float(index), rect.position.y,
			segment_width, rect.size.y)
		var color: Color = _season_colors[index]
		# The band alphas are tuned for a wash behind chart lines; opaque here.
		var filled := Color(color.r, color.g, color.b, 1.0 if index == climate.season_index else 0.35)
		draw_rect(segment, filled, true)
	draw_rect(rect, Color(0.24, 0.27, 0.29), false, 1.0)

	var marker_x: float = rect.position.x + segment_width * (float(climate.season_index) + climate.season_progress)
	draw_line(Vector2(marker_x, rect.position.y - 2.0), Vector2(marker_x, rect.end.y + 2.0),
		Color(1.0, 1.0, 1.0, 0.9), 2.0)


## A flat day/night strip with the sun or moon riding the phase. Simpler to read
## at a glance than a real arc, and it survives any panel width.
func _draw_day_arc(rect: Rect2, climate) -> void:
	var day_config: Dictionary = simulation_manager.config_bundle.get("world", {}) \
		.get("climate", {}).get("day", {})
	var night_start: float = float(day_config.get("night_start_phase", 0.8))
	var night_end: float = float(day_config.get("night_end_phase", 0.22))

	draw_rect(rect, Color(0.55, 0.72, 0.92, 0.30), true)
	# The night wraps past midnight, so it is two rectangles, not one.
	draw_rect(Rect2(rect.position.x + rect.size.x * night_start, rect.position.y,
		rect.size.x * (1.0 - night_start), rect.size.y), Color(0.16, 0.19, 0.34, 0.75), true)
	draw_rect(Rect2(rect.position.x, rect.position.y,
		rect.size.x * night_end, rect.size.y), Color(0.16, 0.19, 0.34, 0.75), true)
	draw_rect(rect, Color(0.24, 0.27, 0.29), false, 1.0)

	var marker_x: float = rect.position.x + rect.size.x * climate.day_phase
	var marker_y: float = rect.position.y + rect.size.y * 0.5
	var glyph := Color(0.35, 0.42, 0.66) if climate.is_night else Color(1.0, 0.86, 0.45)
	draw_circle(Vector2(marker_x, marker_y), rect.size.y * 0.3, glyph)
	draw_arc(Vector2(marker_x, marker_y), rect.size.y * 0.3, 0.0, TAU, 12,
		Color(0.95, 0.96, 0.98, 0.8), 1.0)


func _on_tick_completed(tick: int, _snapshot: Dictionary) -> void:
	if simulation_manager == null or not simulation_manager.should_refresh_ui_on_tick(tick):
		return
	if is_visible_in_tree():
		queue_redraw()
