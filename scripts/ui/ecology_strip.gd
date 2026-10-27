class_name EcologyStrip
extends Control

## How the land is doing, always on screen under the season bar: per species how many
## there are and which way the number is going, how many are close to starving or to
## dying of thirst, how many were killed in the last minute; and how much grass each
## biome has left. A number turns amber when it is worth a look and red when it is bad
## (`EcologyReadout`). Like `ClimateIndicator` it is drawn, not laid out from labels, and
## kept out of the Tab panel so it stays up during play; the start menu hides it.
##
## Folded to one line unless opened - «Олени 244 ▲ · Лисы 24 · Тетерева 88 · Трава 48–56% ▾»,
## each count in the colour of its species' worst column - because the whole table took a
## good part of the top of the screen. A click on it opens or folds it.

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
## The folded line's height around its text, and the room the fold mark takes.
const FOLDED_PADDING := 6.0
const FOLD_MARK := 8.0

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
## The whole table (true) or the one line (false).
var expanded: bool = false
## The reserve on a phone: the species and their numbers only, no grass and no table; names dropped
## too when even that is wider than the strip.
var compact := false:
	set(value):
		compact = value
		if compact and expanded:
			set_expanded(false)
		queue_redraw()
## Where the folded line was drawn, which is where it takes clicks.
var _folded_box := Rect2()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_update_tooltip()


func _update_tooltip() -> void:
	tooltip_text = "Щёлкните, чтобы свернуть" if expanded else "Щёлкните, чтобы увидеть, сколько голодают, жаждут и убито"


## Opens the table or folds it to one line.
func set_expanded(value: bool) -> void:
	expanded = value
	_update_tooltip()
	_fit_height()
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if compact:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		set_expanded(not expanded)
		accept_event()


## Folded, only the line drawn takes the mouse: the rest of the strip's rect is the world's.
func _has_point(point: Vector2) -> bool:
	if expanded:
		return Rect2(Vector2.ZERO, size).has_point(point)
	return _folded_box.has_point(point)


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
	if not expanded:
		offset_bottom = offset_top + FOLDED_PADDING * 2.0 + line
		return
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
	var shown := readout()
	if not expanded:
		_draw_folded(font, font_size, shown)
		return
	var rect := Rect2(Vector2.ZERO, size)
	draw_rect(rect, BACKDROP, true)
	draw_rect(rect, BORDER, false, 1.5)
	var line: float = font.get_height(font_size)
	var ascent: float = font.get_ascent(font_size)
	if shown.is_empty():
		draw_string(font, Vector2(0.0, PADDING + ascent), "Нет данных", HORIZONTAL_ALIGNMENT_CENTER,
			size.x, font_size, INK_DIM)
		return
	# The fold mark in the header's swatch column, which is otherwise empty.
	_draw_fold_mark(Vector2(PADDING + SWATCH * 0.5, PADDING + line * 0.5), true)

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
		draw_string(font, Vector2(name_x, baseline), species_name(species_id),
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


## «Олени», «Лисы», «Тетерева»: the animals, as the cards and the feed call them.
static func species_name(species_id: String) -> String:
	return HudTextScript.capitalized(HudTextScript.animals_label(species_id))


## The worst of a species' columns, by `EcologyReadout.Level`: its count is drawn in that colour
## when the table is folded. Kills count only where something hunts it.
static func row_level(row: Dictionary, hunted := true) -> int:
	var level := maxi(int(row.get("hungry_level", 0)), int(row.get("thirsty_level", 0)))
	if hunted:
		level = maxi(level, int(row.get("kills_level", 0)))
	return level


## «Трава 48–56%», or «Трава 48%» when every biome has as much, and the worst biome's level;
## `{text, level}`.
static func grass_summary(grass: Array) -> Dictionary:
	if grass.is_empty():
		return {"text": "Трава: нет", "level": 0}
	var low := 100
	var high := 0
	var level := 0
	for entry in grass:
		var share := int(round(float(entry["share"]) * 100.0))
		low = mini(low, share)
		high = maxi(high, share)
		level = maxi(level, int(entry["level"]))
	return {"text": "Трава %d%%" % low if low == high else "Трава %d–%d%%" % [low, high], "level": level}


## The folded line as pieces, `[kind, ...]`, laid out from 0: a swatch, a count, a trend, a
## separator, the grass, the fold mark. Measured before it is drawn, to be centred.
func _folded_pieces(font: Font, font_size: int, shown: Dictionary) -> Array:
	var pieces: Array = []
	var x := 0.0
	var separator := " · "
	var separator_width := font.get_string_size(separator, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x
	for row in shown.get("rows", []):
		var species_id: String = row["id"]
		pieces.append(["swatch", x, _colors.get(species_id, INK)])
		x += SWATCH + 5.0
		var text := str(int(row["population"])) if shown.has("numbers_only") else "%s %d" % [species_name(species_id), int(row["population"])]
		pieces.append(["text", x, text, LEVEL_INK[row_level(row, _hunted.get(species_id, true))]])
		x += font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x
		if int(row["trend"]) != 0:
			pieces.append(["trend", x + 4.0 + ARROW * 0.5, int(row["trend"])])
			x += ARROW + 4.0
		pieces.append(["text", x, separator, INK_DIM])
		x += separator_width
	if compact:
		pieces.pop_back()
		x -= separator_width
		if x + PADDING * 2.0 > size.x and not shown.has("numbers_only"):
			var bare := shown.duplicate()
			bare["numbers_only"] = true
			return _folded_pieces(font, font_size, bare)
		pieces.append(["end", x])
		return pieces
	var grass := grass_summary(shown.get("grass", []))
	pieces.append(["text", x, str(grass["text"]), LEVEL_INK[int(grass["level"])]])
	x += font.get_string_size(str(grass["text"]), HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size).x
	pieces.append(["fold", x + 6.0 + FOLD_MARK * 0.5])
	x += FOLD_MARK + 6.0
	pieces.append(["end", x])
	return pieces


func _draw_folded(font: Font, font_size: int, shown: Dictionary) -> void:
	var line: float = font.get_height(font_size)
	var ascent: float = font.get_ascent(font_size)
	if shown.is_empty():
		_folded_box = Rect2()
		return
	var pieces := _folded_pieces(font, font_size, shown)
	var width: float = float(pieces.back()[1]) + PADDING * 2.0
	_folded_box = Rect2(Vector2((size.x - width) * 0.5, 0.0), Vector2(width, FOLDED_PADDING * 2.0 + line))
	draw_rect(_folded_box, BACKDROP, true)
	draw_rect(_folded_box, BORDER, false, 1.5)
	var left := _folded_box.position.x + PADDING
	var middle := FOLDED_PADDING + line * 0.5
	var baseline := FOLDED_PADDING + ascent
	for piece in pieces:
		match str(piece[0]):
			"swatch":
				draw_rect(Rect2(left + float(piece[1]), middle - SWATCH * 0.5, SWATCH, SWATCH), piece[2], true)
			"text":
				draw_string(font, Vector2(left + float(piece[1]), baseline), str(piece[2]),
					HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, piece[3])
			"trend":
				_draw_trend(Vector2(left + float(piece[1]), middle), int(piece[2]))
			"fold":
				_draw_fold_mark(Vector2(left + float(piece[1]), middle), false)


## ▾ where the table opens, ▴ where it folds.
func _draw_fold_mark(centre: Vector2, open: bool) -> void:
	var half := FOLD_MARK * 0.5
	var tip := -half * 0.6 if open else half * 0.6
	draw_colored_polygon(PackedVector2Array([centre + Vector2(-half, -tip), centre + Vector2(half, -tip),
		centre + Vector2(0.0, tip)]), INK_DIM)
