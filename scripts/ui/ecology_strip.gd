class_name EcologyStrip
extends Control

## How the land is doing, always on screen under the season bar: per species how many
## there are and which way the number is going, how many are close to starving or to
## dying of thirst, how many were killed in the last minute; and how much grass each
## biome has left. A number turns amber when it is worth a look and red when it is bad
## (`EcologyReadout`). Like `ClimateIndicator` it is drawn, not laid out from labels, and
## kept out of the Tab panel so it stays up during play; the start menu hides it.

const PADDING := 10.0
const ROW_GAP := 3.0
const SWATCH := 9.0
const NAME_WIDTH := 112.0
const COLUMN_WIDTH := 88.0
const ARROW := 7.0
## The season bar's colours, so the two read as one block.
const BACKDROP := Color(0.06, 0.07, 0.08, 0.82)
const BORDER := Color(0.22, 0.24, 0.26)
const INK := Color(0.88, 0.9, 0.92)
const INK_DIM := Color(0.88, 0.9, 0.92, 0.58)
## Indexed by `EcologyReadout.Level`.
const LEVEL_INK := [INK, Color(0.98, 0.78, 0.36), Color(1.0, 0.47, 0.4)]
const RISING := Color(0.58, 0.84, 0.46)
const FALLING := Color(1.0, 0.52, 0.42)
const HEADERS := ["Всего", "Голодают", "Жаждут", "Убито"]

const EcologyReadoutScript := preload("res://scripts/ui/ecology_readout.gd")
const HudTextScript := preload("res://scripts/ui/hud_text.gd")

var simulation_manager: SimulationManager
var _species_ids: Array = []
var _colors: Dictionary = {}
## Species something eats. The others are never killed, and their column says so.
var _hunted: Dictionary = {}
var _capacity: Dictionary = {}
## The world `_capacity` was summed for. A new world, or the copy the worker hands the
## view, is another object, and the sum is taken again.
var _capacity_world: Object = null


func bind_manager(manager: SimulationManager) -> void:
	simulation_manager = manager
	_capacity_world = null
	_species_ids.clear()
	_colors.clear()
	_hunted.clear()
	var visuals: Dictionary = manager.config_bundle.get("visuals", {}).get("species", {})
	# In the registry's slot order, the order the charts and the help list them in.
	var ids: Array = manager.config_bundle.get("species", {}).keys()
	var registry = null if manager.world_state == null else manager.world_state.species_registry
	if registry != null:
		ids = registry.ids()
	for species_id in ids:
		_species_ids.append(str(species_id))
		_hunted[str(species_id)] = registry == null or not registry.predator_set(str(species_id)).is_empty()
		var rgba: Array = visuals.get(species_id, {}).get("ui_color", [0.8, 0.8, 0.8])
		_colors[str(species_id)] = Color(float(rgba[0]), float(rgba[1]), float(rgba[2]))
	if not manager.tick_completed.is_connected(_on_tick_completed):
		manager.tick_completed.connect(_on_tick_completed)
	_fit_height()
	queue_redraw()


## Tall enough for the header, a row per species and the grass line, at the theme's font.
func _fit_height() -> void:
	var font := get_theme_default_font()
	if font == null:
		return
	var line: float = font.get_height(get_theme_default_font_size())
	var lines := float(_species_ids.size() + 2)
	offset_bottom = offset_top + PADDING * 2.0 + lines * line + (lines - 1.0) * ROW_GAP


func _on_tick_completed(tick: int, _snapshot: Dictionary) -> void:
	if simulation_manager == null or not simulation_manager.should_refresh_ui_on_tick(tick):
		return
	if is_visible_in_tree():
		queue_redraw()


## What the strip shows now: `rows` per species and `grass` per biome, or empty without a
## world or a snapshot. Public so a test can read what is drawn without drawing it.
func readout() -> Dictionary:
	if simulation_manager == null or simulation_manager.world_state == null or simulation_manager.stats_system == null:
		return {}
	var stats = simulation_manager.stats_system
	var latest: Dictionary = stats.get_snapshot_view()
	if latest.is_empty():
		return {}
	var world = simulation_manager.world_state
	if _capacity_world != world:
		_capacity = EcologyReadoutScript.capacity_by_biome(world.resource_system, world.terrain_system)
		_capacity_world = world
	var reference: Dictionary = EcologyReadoutScript.reference_sample(stats.time_series, latest)
	return {
		"rows": EcologyReadoutScript.species_rows(latest, reference, _species_ids),
		"grass": EcologyReadoutScript.grass_rows(latest, _capacity, HudTextScript.BIOME_ORDER),
	}


func _draw() -> void:
	var font := get_theme_default_font()
	if font == null:
		return
	var font_size := get_theme_default_font_size()
	var rect := Rect2(Vector2.ZERO, size)
	draw_rect(rect, BACKDROP, true)
	draw_rect(rect, BORDER, false, 1.5)
	var line: float = font.get_height(font_size)
	var ascent: float = font.get_ascent(font_size)
	var shown := readout()
	if shown.is_empty():
		draw_string(font, Vector2(0.0, PADDING + ascent), "Нет данных", HORIZONTAL_ALIGNMENT_CENTER,
			size.x, font_size, INK_DIM)
		return

	var top := PADDING
	var name_x := PADDING + SWATCH + 6.0
	var columns_x := name_x + NAME_WIDTH
	draw_string(font, Vector2(name_x, top + ascent), "Вид", HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, INK_DIM)
	for index in range(HEADERS.size()):
		draw_string(font, Vector2(columns_x + COLUMN_WIDTH * index, top + ascent), HEADERS[index],
			HORIZONTAL_ALIGNMENT_RIGHT, COLUMN_WIDTH, font_size, INK_DIM)

	for row in shown["rows"]:
		top += line + ROW_GAP
		var baseline := top + ascent
		var species_id: String = row["id"]
		draw_rect(Rect2(PADDING, top + (line - SWATCH) * 0.5, SWATCH, SWATCH), _colors.get(species_id, INK), true)
		draw_string(font, Vector2(name_x, baseline), HudTextScript.species_label(species_id),
			HORIZONTAL_ALIGNMENT_LEFT, NAME_WIDTH, font_size, INK)
		# The total leaves room on its right for the arrow of where it is going.
		draw_string(font, Vector2(columns_x, baseline), str(row["population"]), HORIZONTAL_ALIGNMENT_RIGHT,
			COLUMN_WIDTH - ARROW - 5.0, font_size, INK)
		_draw_trend(Vector2(columns_x + COLUMN_WIDTH - ARROW, top + line * 0.5), int(row["trend"]))
		var cells := [[str(row["hungry"]), LEVEL_INK[int(row["hungry_level"])]],
			[str(row["thirsty"]), LEVEL_INK[int(row["thirsty_level"])]],
			[str(row["kills"]), LEVEL_INK[int(row["kills_level"])]] if _hunted.get(species_id, true) else ["—", INK_DIM]]
		for index in range(cells.size()):
			draw_string(font, Vector2(columns_x + COLUMN_WIDTH * (index + 1), baseline), cells[index][0],
				HORIZONTAL_ALIGNMENT_RIGHT, COLUMN_WIDTH, font_size, cells[index][1])

	top += line + ROW_GAP
	_draw_grass(font, font_size, Vector2(PADDING, top + ascent), shown["grass"])


## A small triangle: up and green while the species grows, down and red while it falls,
## nothing while it holds. A dash beside a number read as a minus sign.
func _draw_trend(centre: Vector2, direction: int) -> void:
	var half := ARROW * 0.5
	if direction > 0:
		draw_colored_polygon(PackedVector2Array([centre + Vector2(-half, half * 0.8),
			centre + Vector2(half, half * 0.8), centre + Vector2(0.0, -half * 0.9)]), RISING)
	elif direction < 0:
		draw_colored_polygon(PackedVector2Array([centre + Vector2(-half, -half * 0.8),
			centre + Vector2(half, -half * 0.8), centre + Vector2(0.0, half * 0.9)]), FALLING)


## «Трава: Луг 64% · Лес 51% · …», each share in its level's colour.
func _draw_grass(font: Font, font_size: int, origin: Vector2, grass: Array) -> void:
	var x := origin.x
	var label := "Трава:"
	draw_string(font, Vector2(x, origin.y), label, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, INK_DIM)
	x += font.get_string_size(label + " ", HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x
	if grass.is_empty():
		draw_string(font, Vector2(x, origin.y), "нет", HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, INK_DIM)
		return
	for index in range(grass.size()):
		var entry: Dictionary = grass[index]
		var text := "%s %d%%" % [HudTextScript.biome_label(entry["id"]), int(round(float(entry["share"]) * 100.0))]
		if index > 0:
			text = " · " + text
		draw_string(font, Vector2(x, origin.y), text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size,
			LEVEL_INK[int(entry["level"])])
		x += font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x
