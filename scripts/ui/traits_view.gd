extends Control

## The chronicle's «Черты»: each species' inherited traits over the world's life
## (`TraitHistory`). On the left the species, each with its numbers over time; «Все виды» above
## them lays every species over one chart a trait. A species chosen, its four traits get a chart
## each: the mean, a band one spread either side of it, and the marker (`Traits.MARKER`) dashed
## behind - how far chance alone carries a trait. Under the charts runs one time line for them
## all: the seasons, the droughts and the culls (`SeasonLedger`), and the species' numbers.
## «Общий масштаб» puts the four charts on one scale, to be compared.
##
## A click on a chart opens that trait alone: the chart large, what the chronicle concludes of it
## (`TraitInsights`), the founders against the living (`TraitHistory.founders`, the family tree's
## living), and who left young and who died of what, set against the living of the time. The
## pointer over a chart reads its values off at that time.
##
## Narrower than `NARROW` (the reserve upright), the species stand in a grid above the charts,
## two charts a row, and a trait alone has its parts one under another.

signal insight_requested

const TraitsScript := preload("res://scripts/agents/traits.gd")
const TraitHistoryScript := preload("res://scripts/story/trait_history.gd")
const TraitInsightsScript := preload("res://scripts/story/trait_insights.gd")
const HudTextScript := preload("res://scripts/ui/hud_text.gd")

const INK := Color(0.20, 0.13, 0.08)
const INK_DIM := Color(0.20, 0.13, 0.08, 0.55)
const FRAME := Color(0.20, 0.13, 0.08, 0.2)
const MARKER_INK := Color(0.30, 0.30, 0.34, 0.8)
const PICKED := Color(1.0, 1.0, 1.0, 0.32)
const TIP := Color(1.0, 0.97, 0.86, 0.96)
const SEASON_COLORS := {"spring": Color(0.61, 0.75, 0.42), "summer": Color(0.84, 0.72, 0.31),
	"autumn": Color(0.76, 0.49, 0.23), "winter": Color(0.79, 0.83, 0.86)}
const DROUGHT := Color(0.66, 0.39, 0.11)
const CULL := Color(0.55, 0.18, 0.12)
const KIND_COLORS := {"selection": Color(0.25, 0.49, 0.31), "cost": Color(0.66, 0.39, 0.11),
	"race": Color(0.48, 0.36, 0.23), "jump": Color(0.42, 0.25, 0.63), "bottleneck": Color(0.29, 0.33, 0.41),
	"trend": Color(0.45, 0.40, 0.30), "drift": Color(0.54, 0.48, 0.36)}
## Who left a trace, in the order the drill-down lists them (`TraitHistory` tally groups).
const GROUPS := ["parents", "predation", "starvation", "thirst", "old_age", "culled", "emigrated"]
const GROUP_LABELS := {"parents": "Родили детёнышей", "predation": "Съедены хищниками",
	"starvation": "Умерли от голода", "thirst": "Умерли от жажды", "old_age": "Умерли от старости",
	"culled": "Отстреляны", "emigrated": "Ушли из заповедника"}
const GOOD := Color(0.25, 0.49, 0.31)
const LIST_WIDTH := 148.0
const GAP := 18.0
const LEFT := 40.0
const RIGHT := 46.0
const STRIP := 92.0
## Narrower than this, the species go above the charts and a trait alone stacks its parts.
const NARROW := 600.0

var history = null
var species: Array = []
var now := 0.0
var calendar: Array = [120.0, 4]
var seasons: Array = []
var lineage = null
var insights: Array = []
## The species shown, "" for «Все виды»; the trait opened alone, -1 for none.
var shown_species := ""
var drilled := -1
var shared_scale := false
var _hover := Vector2(-1.0, -1.0)
## What a click hits, drawn this frame: `[[Rect2, Callable]]`.
var _hits: Array = []
## The plots under the pointer can read: `[[Rect2, species ids, trait index, span]]`.
var _plots: Array = []
var _living_histograms: Array = []


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP


func show_history(trait_history, entries: Array, time: float, world_calendar: Array, closed_seasons: Array = [],
		family = null, found: Array = []) -> void:
	history = trait_history
	species = entries
	now = time
	calendar = world_calendar
	seasons = closed_seasons
	lineage = family
	insights = found
	if shown_species != "" and _entry(shown_species).is_empty():
		shown_species = ""
		drilled = -1
	if shown_species == "" and drilled >= 0:
		drilled = -1
	_living_histograms = []
	if drilled >= 0 and lineage != null:
		var living: Dictionary = TraitHistoryScript.living_traits(lineage, [shown_species])
		_living_histograms = TraitHistoryScript.histograms(living.get(shown_species, []))
	queue_redraw()


## Opens `species_id`'s trait `index` alone, or the species' four with `index` -1.
func focus(species_id: String, index := -1) -> void:
	shown_species = species_id
	drilled = index if species_id != "" else -1
	queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_hover = event.position
		var over := false
		for hit in _hits:
			if Rect2(hit[0]).has_point(_hover):
				over = true
				break
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if over else Control.CURSOR_ARROW
		queue_redraw()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		for hit in _hits:
			if Rect2(hit[0]).has_point(event.position):
				Callable(hit[1]).call(event.position)
				accept_event()
				queue_redraw()
				return


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		_hover = Vector2(-1.0, -1.0)
		queue_redraw()


func _draw() -> void:
	_hits.clear()
	_plots.clear()
	var font := get_theme_default_font()
	if history == null or font == null:
		return
	if species.is_empty():
		draw_string(font, Vector2(8.0, 30.0), "В этом мире черты не наследуются.", HORIZONTAL_ALIGNMENT_LEFT,
			-1, 15, INK_DIM)
		return
	if history.points.size() < 2:
		draw_string(font, Vector2(0.0, 24.0), "Собираем данные: точка раз в %d с." % int(history.interval),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 14, INK_DIM)
		return
	if drilled >= 0 and shown_species != "":
		_draw_drill(font)
	elif _narrow():
		_draw_overview(font, _draw_grid(font))
	else:
		_draw_list(font)
		_draw_overview(font)
	_draw_tip(font)


# --- the species list ---------------------------------------------------------------------

func _draw_list(font: Font) -> void:
	var y := 0.0
	var all_rect := Rect2(0.0, y, LIST_WIDTH, 28.0)
	if shown_species == "":
		draw_rect(all_rect, PICKED, true)
	draw_string(font, Vector2(8.0, y + 19.0), "Все виды", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, INK)
	_hits.append([all_rect, func(_at): focus("")])
	y += 34.0
	for entry in species:
		var id := str(entry["id"])
		var rect := Rect2(0.0, y, LIST_WIDTH, 52.0)
		if id == shown_species:
			draw_rect(rect, PICKED, true)
			draw_rect(Rect2(rect.position, Vector2(3.0, rect.size.y)), entry["color"], true)
		draw_string(font, Vector2(8.0, y + 18.0), str(entry["label"]), HORIZONTAL_ALIGNMENT_LEFT, LIST_WIDTH - 44.0, 15,
			entry["color"])
		var counts := _counts(id)
		if not counts.is_empty():
			draw_string(font, Vector2(8.0, y + 18.0), str(int(counts[-1].y)), HORIZONTAL_ALIGNMENT_RIGHT,
				LIST_WIDTH - 14.0, 14, INK)
			_spark(Rect2(8.0, y + 26.0, LIST_WIDTH - 16.0, 20.0), counts, entry["color"])
		_hits.append([rect, func(_at): focus(id)])
		y += 56.0
	y += 4.0
	var box := Rect2(8.0, y, 14.0, 14.0)
	draw_rect(box, INK, false, 1.0)
	if shared_scale:
		draw_polyline(PackedVector2Array([box.position + Vector2(3, 7), box.position + Vector2(6, 11),
			box.position + Vector2(11, 3)]), INK, 2.0)
	draw_string(font, Vector2(28.0, y + 12.0), "общий масштаб", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, INK)
	_hits.append([Rect2(0.0, y - 4.0, LIST_WIDTH, 22.0), func(_at): _toggle_scale()])
	draw_multiline_string(font, Vector2(8.0, y + 34.0), "щелчок по линии откроет черту вида" if shown_species == ""
		else "щелчок по графику откроет черту", HORIZONTAL_ALIGNMENT_LEFT, LIST_WIDTH - 8.0, 12, -1, INK_DIM)
	if shown_species == "":
		return
	y += 34.0
	y += 30.0
	draw_dashed_line(Vector2(8.0, y), Vector2(26.0, y), MARKER_INK, 1.4, 3.0)
	draw_string(font, Vector2(32.0, y + 4.0), "метка: чистый дрейф", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, INK_DIM)
	y += 18.0
	var color: Color = _entry(shown_species)["color"]
	draw_rect(Rect2(8.0, y - 5.0, 18.0, 10.0), Color(color, 0.22), true)
	draw_string(font, Vector2(32.0, y + 4.0), "полоса: разброс", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, INK_DIM)


## The species list narrow: «Все виды» and each species three to a row, the scale's box and
## the legend under them. Returns where the charts may start.
func _draw_grid(font: Font) -> float:
	var columns := 3
	var cell := Vector2((size.x - 6.0 * (columns - 1)) / float(columns), 46.0)
	var items: Array = [""]
	for entry in species:
		items.append(str(entry["id"]))
	for position in range(items.size()):
		var id: String = items[position]
		var rect := Rect2(float(position % columns) * (cell.x + 6.0), float(floori(float(position) / float(columns))) * (cell.y + 4.0),
			cell.x, cell.y)
		if id == shown_species:
			draw_rect(rect, PICKED, true)
		_hits.append([rect, func(_at): focus(id)])
		if id == "":
			draw_string(font, rect.position + Vector2(8.0, 18.0), "Все виды", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, INK)
			continue
		var entry := _entry(id)
		if id == shown_species:
			draw_rect(Rect2(rect.position, Vector2(3.0, rect.size.y)), entry["color"], true)
		draw_string(font, rect.position + Vector2(8.0, 18.0), str(entry["label"]), HORIZONTAL_ALIGNMENT_LEFT,
			rect.size.x - 44.0, 14, entry["color"])
		var counts := _counts(id)
		if not counts.is_empty():
			draw_string(font, rect.position + Vector2(8.0, 18.0), str(int(counts[-1].y)), HORIZONTAL_ALIGNMENT_RIGHT,
				rect.size.x - 14.0, 13, INK)
			_spark(Rect2(rect.position + Vector2(8.0, 24.0), Vector2(rect.size.x - 16.0, 16.0)), counts, entry["color"])
	var y := ceilf(float(items.size()) / float(columns)) * (cell.y + 4.0) + 6.0
	var box := Rect2(8.0, y, 14.0, 14.0)
	draw_rect(box, INK, false, 1.0)
	if shared_scale:
		draw_polyline(PackedVector2Array([box.position + Vector2(3, 7), box.position + Vector2(6, 11),
			box.position + Vector2(11, 3)]), INK, 2.0)
	draw_string(font, Vector2(28.0, y + 12.0), "общий масштаб", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, INK)
	_hits.append([Rect2(0.0, y - 4.0, 150.0, 22.0), func(_at): _toggle_scale()])
	draw_string(font, Vector2(0.0, y + 12.0), "щелчок по линии откроет черту вида" if shown_species == ""
		else "щелчок по графику откроет черту", HORIZONTAL_ALIGNMENT_RIGHT, size.x, 12, INK_DIM)
	y += 22.0
	if shown_species != "":
		y += 8.0
		draw_dashed_line(Vector2(8.0, y), Vector2(26.0, y), MARKER_INK, 1.4, 3.0)
		draw_string(font, Vector2(32.0, y + 4.0), "метка: чистый дрейф", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, INK_DIM)
		var color: Color = _entry(shown_species)["color"]
		draw_rect(Rect2(196.0, y - 5.0, 18.0, 10.0), Color(color, 0.22), true)
		draw_string(font, Vector2(220.0, y + 4.0), "полоса: разброс", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, INK_DIM)
		y += 12.0
	return y + 10.0


# --- the charts and the time line ----------------------------------------------------------

## The charts right of the list, or narrow under `top` across the whole width.
func _draw_overview(font: Font, top := 0.0) -> void:
	var narrow := _narrow()
	var area := Rect2(0.0, top, size.x, size.y - top) if narrow else \
		Rect2(LIST_WIDTH + 16.0, 0.0, size.x - LIST_WIDTH - 16.0, size.y)
	var charts := Rect2(area.position, Vector2(area.size.x, area.size.y - STRIP))
	var ids: Array = [shown_species] if shown_species != "" else _ids()
	var shown := _traits_of(ids)
	# Four to a square; the newer traits make it three a row, the margins narrower to keep room.
	# Narrow, two a row whatever their number.
	var columns := 2 if shown.size() <= 4 or narrow else 3
	var rows := maxi(1, ceili(float(shown.size()) / float(columns)))
	var margins := Vector2(LEFT, RIGHT) if columns == 2 and not narrow else Vector2(40.0, 40.0)
	var cell := Vector2((charts.size.x - GAP * (columns - 1)) / float(columns), (charts.size.y - GAP * (rows - 1)) / float(rows))
	var shared := 0.0
	if shared_scale:
		for index in shown:
			shared = maxf(shared, _reach(index, _having(index, ids)))
	for position in range(shown.size()):
		var index: int = shown[position]
		var origin := charts.position + Vector2(float(position % columns) * (cell.x + GAP),
			float(floori(float(position) / float(columns))) * (cell.y + GAP))
		var rect := Rect2(origin, cell)
		draw_string(font, rect.position + Vector2(0.0, 13.0), str(HudTextScript.TRAIT_LABELS[index]),
			HORIZONTAL_ALIGNMENT_LEFT, rect.size.x, 14 if columns == 2 else 13, INK)
		var plot := Rect2(rect.position + Vector2(margins.x, 20.0), rect.size - Vector2(margins.x + margins.y, 22.0))
		var having := _having(index, ids)
		var reach := shared if shared_scale else _reach(index, having)
		_chart(font, plot, index, having, reach, true, margins)
		_hits.append([plot, func(at: Vector2): _drill_at(index, plot, reach, at)])
	var strip := Rect2(area.position.x + LEFT, charts.end.y + 6.0, area.size.x - LEFT - RIGHT, STRIP - 8.0)
	_time_line(font, strip, ids)


## The traits to chart for the species `ids`: every one any of them has, but the marker, in order.
func _traits_of(ids: Array) -> Array:
	var out: Array = []
	for index in range(HudTextScript.TRAIT_LABELS.size()):
		if index != HudTextScript.MARKER_TRAIT and not _having(index, ids).is_empty():
			out.append(index)
	return out


## Those of `ids` that have trait `index` (`{id, traits}` in their entry; all four first ones when
## an entry does not say).
func _having(index: int, ids: Array) -> Array:
	var out: Array = []
	for id in ids:
		var known: Array = _entry(str(id)).get("traits", range(HudTextScript.CORE_TRAITS))
		if known.has(index):
			out.append(id)
	return out


## One trait's chart in `plot` for the species `ids`: the dashed line of the species as written,
## each species' mean (one alone gets its band and the marker), the latest values at the end.
## `margins` are the room left of the plot for its scale and right of it for the latest values.
func _chart(font: Font, plot: Rect2, index: int, ids: Array, reach: float, compact: bool,
		margins := Vector2(LEFT, RIGHT)) -> void:
	draw_rect(plot, FRAME, false, 1.0)
	var middle := plot.get_center().y
	var left := margins.x
	draw_dashed_line(Vector2(plot.position.x, middle), Vector2(plot.end.x, middle), INK_DIM, 1.0, 4.0)
	draw_string(font, Vector2(plot.position.x - left, plot.position.y + 10.0), HudTextScript.percent_change(1.0 + reach),
		HORIZONTAL_ALIGNMENT_RIGHT, left - 5.0, 11, INK_DIM)
	draw_string(font, Vector2(plot.position.x - left, middle + 4.0), "вид", HORIZONTAL_ALIGNMENT_RIGHT, left - 5.0, 11, INK_DIM)
	draw_string(font, Vector2(plot.position.x - left, plot.end.y), HudTextScript.percent_change(1.0 - reach),
		HORIZONTAL_ALIGNMENT_RIGHT, left - 5.0, 11, INK_DIM)
	if not compact:
		_event_lines(plot)
	var alone := ids.size() == 1
	var ends: Array = []
	for id in ids:
		var entry := _entry(str(id))
		if alone:
			_band(plot, middle, reach, str(id), index, entry["color"])
			_line(plot, middle, reach, str(id), TraitsScript.MARKER, MARKER_INK, 1.3, true)
		_line(plot, middle, reach, str(id), index, entry["color"], 2.4 if alone else 2.0, false)
		var latest: Array = history.latest(str(id))
		if index < latest.size():
			ends.append([_y(plot, middle, reach, float(latest[index])), HudTextScript.percent_change(float(latest[index])),
				entry["color"]])
	ends.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
	var floor_y := -INF
	for end in ends:
		var y := maxf(float(end[0]) + 4.0, floor_y + 12.0)
		draw_string(font, Vector2(plot.end.x + 4.0, y), str(end[1]), HORIZONTAL_ALIGNMENT_LEFT, margins.y - 4.0, 11, end[2])
		floor_y = y
	_plots.append([plot, ids, index, reach])


func _line(plot: Rect2, middle: float, reach: float, id: String, index: int, color: Color, width: float, dashed: bool) -> void:
	var line := PackedVector2Array()
	for point in history.points:
		var means = point["values"].get(id)
		if means == null or index >= means.size():
			# Gone for a while: the line breaks rather than bridging the gap.
			_stroke(line, color, width, dashed)
			line = PackedVector2Array()
			continue
		line.append(Vector2(_x(plot, float(point["time"])), _y(plot, middle, reach, float(means[index]))))
	_stroke(line, color, width, dashed)


func _stroke(line: PackedVector2Array, color: Color, width: float, dashed: bool) -> void:
	if line.size() < 2:
		return
	if not dashed:
		draw_polyline(line, color, width, true)
		return
	# Dashes measured along the line, so they read as dashes however close the points lie.
	var dash := 5.0
	var walked := 0.0
	for position in range(1, line.size()):
		var from := line[position - 1]
		var to := line[position]
		var length := from.distance_to(to)
		var done := 0.0
		while done < length:
			var step := minf(dash - fmod(walked, dash), length - done)
			if int(walked / dash) % 2 == 0:
				draw_line(from.lerp(to, done / length), from.lerp(to, (done + step) / length), color, width, true)
			done += step
			walked += step


## The band one spread either side of the mean, where the points know it.
func _band(plot: Rect2, middle: float, reach: float, id: String, index: int, color: Color) -> void:
	var upper := PackedVector2Array()
	var lower := PackedVector2Array()
	for point in history.points:
		var means = point["values"].get(id)
		var spread = point.get("spread", {}).get(id)
		if means == null or spread == null or index >= means.size() or index >= spread.size():
			_fill_band(upper, lower, color)
			upper = PackedVector2Array()
			lower = PackedVector2Array()
			continue
		var x := _x(plot, float(point["time"]))
		upper.append(Vector2(x, _y(plot, middle, reach, float(means[index]) + float(spread[index]))))
		lower.append(Vector2(x, _y(plot, middle, reach, float(means[index]) - float(spread[index]))))
	_fill_band(upper, lower, color)


func _fill_band(upper: PackedVector2Array, lower: PackedVector2Array, color: Color) -> void:
	if upper.size() < 2:
		return
	# A band that folds on itself (a spread of nought) is not a polygon to fill: strips it is.
	for position in range(1, upper.size()):
		draw_colored_polygon(PackedVector2Array([upper[position - 1], upper[position], lower[position], lower[position - 1]]),
			Color(color, 0.2))


## The seasons, the droughts and culls, and the numbers of the species shown, on the charts' time.
func _time_line(font: Font, strip: Rect2, ids: Array) -> void:
	var y := strip.position.y
	for summary in seasons:
		var from := _x(strip, float(summary.get("start", 0.0)))
		var to := _x(strip, float(summary.get("end", 0.0)))
		if to <= strip.position.x or from >= strip.end.x:
			continue
		from = maxf(from, strip.position.x)
		to = minf(to, strip.end.x)
		draw_rect(Rect2(from, y, maxf(1.0, to - from), 7.0), SEASON_COLORS.get(str(summary.get("season_id", "")), FRAME), true)
	draw_string(font, Vector2(strip.position.x - LEFT, y + 8.0), "сезоны", HORIZONTAL_ALIGNMENT_RIGHT, LEFT - 5.0, 11, INK_DIM)
	var label_end := -INF
	for event in _events():
		var x := _x(strip, float(event["time"]))
		if x < strip.position.x or x > strip.end.x:
			continue
		var color: Color = event["color"]
		draw_colored_polygon(PackedVector2Array([Vector2(x - 4.0, y + 11.0), Vector2(x + 4.0, y + 11.0), Vector2(x, y + 18.0)]), color)
		if x > label_end:
			draw_string(font, Vector2(x + 6.0, y + 19.0), str(event["label"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, color)
			label_end = x + 6.0 + font.get_string_size(str(event["label"]), HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x + 8.0
	var area := Rect2(strip.position.x, y + 24.0, strip.size.x, strip.size.y - 40.0)
	draw_line(Vector2(area.position.x, area.end.y), Vector2(area.end.x, area.end.y), FRAME, 1.0)
	var most := 1.0
	for id in ids:
		for count in _counts(str(id)):
			most = maxf(most, count.y)
	for id in ids:
		var color: Color = _entry(str(id))["color"]
		var line := PackedVector2Array()
		for count in _counts(str(id)):
			# Each species against its own most when several share the strip: their shapes, not sizes.
			var scale := most if ids.size() == 1 else _most_count(str(id))
			line.append(Vector2(_x(area, count.x), area.end.y - count.y / scale * area.size.y))
		if line.size() >= 2:
			if ids.size() == 1:
				var fill := line.duplicate()
				fill.append(Vector2(line[-1].x, area.end.y))
				fill.append(Vector2(line[0].x, area.end.y))
				draw_colored_polygon(fill, Color(color, 0.18))
			draw_polyline(line, color, 1.5, true)
	draw_string(font, Vector2(strip.position.x - LEFT, area.position.y + 12.0), "числ." if ids.size() == 1 else "доля",
		HORIZONTAL_ALIGNMENT_RIGHT, LEFT - 5.0, 11, INK_DIM)
	if ids.size() == 1:
		draw_string(font, Vector2(strip.position.x - LEFT, area.end.y), "0", HORIZONTAL_ALIGNMENT_RIGHT, LEFT - 5.0, 11, INK_DIM)
		draw_string(font, Vector2(area.end.x + 4.0, area.position.y + 10.0), str(int(most)), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, INK_DIM)
	draw_string(font, Vector2(strip.position.x, strip.end.y + 2.0), "начало", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, INK_DIM)
	var age := HudTextScript.age_text(_last_time(), calendar)
	draw_string(font, Vector2(strip.position.x, strip.end.y + 2.0), age, HORIZONTAL_ALIGNMENT_RIGHT, strip.size.x, 11, INK_DIM)


## Faint lines across a chart where the time line has a drought or a cull.
func _event_lines(plot: Rect2) -> void:
	for event in _events():
		var x := _x(plot, float(event["time"]))
		if x >= plot.position.x and x <= plot.end.x:
			draw_line(Vector2(x, plot.position.y), Vector2(x, plot.end.y), Color(event["color"], 0.35), 1.0)


## `[{time, label, color}]`: the seasons a drought made harsher (the first of each run) and the
## seasons the player culled in.
func _events() -> Array:
	var out: Array = []
	var dry_before := false
	for summary in seasons:
		var dry := bool(summary.get("drought", false))
		if dry and not dry_before:
			out.append({"time": float(summary.get("start", 0.0)), "label": "засуха", "color": DROUGHT})
		dry_before = dry
		var culled := 0
		for counts in summary.get("species", {}).values():
			culled += int(counts.get("deaths", {}).get("culled", 0))
		if culled > 0:
			out.append({"time": float(summary.get("start", 0.0)), "label": "отстрел %d" % culled, "color": CULL})
	return out


# --- one trait alone ----------------------------------------------------------------------

func _draw_drill(font: Font) -> void:
	var entry := _entry(shown_species)
	var color: Color = entry["color"]
	var back := "‹ Все черты"
	var back_width := font.get_string_size(back, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x
	draw_string(font, Vector2(0.0, 16.0), back, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, GOOD)
	_hits.append([Rect2(0.0, 0.0, back_width + 8.0, 22.0), func(_at): focus(shown_species)])
	var narrow := _narrow()
	var title := "%s · %s" % [entry["label"], HudTextScript.TRAIT_LABELS[drilled]]
	# Narrow, the title and its numbers on lines of their own under «Все черты».
	var title_at := Vector2(0.0, 42.0) if narrow else Vector2(back_width + 20.0, 17.0)
	draw_string(font, title_at, title, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, color)
	var title_width := font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
	var latest: Array = history.latest(shown_species)
	var spread: Array = history.latest_spread(shown_species)
	var about := ""
	if drilled < latest.size():
		about = "%s от вида" % HudTextScript.percent_change(float(latest[drilled]))
	if drilled < spread.size():
		about += " · разброс ±%s" % TraitInsightsScript.percent(float(spread[drilled]))
	var about_at := Vector2(0.0, 62.0) if narrow else Vector2(back_width + 32.0 + title_width, 17.0)
	draw_string(font, about_at, about, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, INK_DIM)
	var card_width := 250.0
	var plot := Rect2(LEFT, 78.0, size.x - LEFT - RIGHT, 160.0) if narrow else \
		Rect2(LEFT, 34.0, size.x - card_width - LEFT - RIGHT - 12.0, 190.0)
	var reach := _reach(drilled, [shown_species])
	_chart(font, plot, drilled, [shown_species], reach, false)
	draw_string(font, Vector2(plot.position.x, plot.end.y + 14.0), "начало", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, INK_DIM)
	draw_string(font, Vector2(plot.position.x, plot.end.y + 14.0), HudTextScript.age_text(_last_time(), calendar),
		HORIZONTAL_ALIGNMENT_RIGHT, plot.size.x, 11, INK_DIM)
	var lower := plot.end.y + 34.0
	if narrow:
		# The card, the founders and the traces one under another, the traces taking what is left.
		_insight_card(font, Rect2(0.0, lower - 8.0, size.x, 160.0))
		var below := lower + 164.0
		var traces_height := maxf(210.0, (size.y - below) * 0.5)
		_histogram(font, Rect2(0.0, below, size.x, size.y - below - traces_height), color)
		_traces(font, Rect2(0.0, size.y - traces_height, size.x, traces_height), color)
		return
	_insight_card(font, Rect2(size.x - card_width, 34.0, card_width, lower - 46.0))
	_histogram(font, Rect2(0.0, lower, 320.0, size.y - lower), color)
	_traces(font, Rect2(350.0, lower, size.x - 350.0, size.y - lower), color)


func _insight_card(font: Font, rect: Rect2) -> void:
	draw_rect(rect, TIP, true)
	draw_rect(rect, INK_DIM, false, 1.0)
	var found := TraitInsightsScript.about(insights, shown_species, drilled)
	var x := rect.position.x + 12.0
	var width := rect.size.x - 24.0
	if found.is_empty():
		draw_multiline_string(font, Vector2(x, rect.position.y + 24.0),
			"Выводов об этой черте пока нет: она почти не сдвинулась, или данных мало.",
			HORIZONTAL_ALIGNMENT_LEFT, width, 13, -1, INK_DIM)
		return
	var finding: Dictionary = found[0]
	var kind := str(finding["kind"])
	var badge := str(TraitInsightsScript.KIND_LABELS.get(kind, kind))
	var badge_width := font.get_string_size(badge, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x + 14.0
	draw_rect(Rect2(x, rect.position.y + 10.0, badge_width, 19.0), KIND_COLORS.get(kind, INK_DIM), true)
	draw_string(font, Vector2(x + 7.0, rect.position.y + 24.0), badge, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
	_confidence(Vector2(rect.end.x - 50.0, rect.position.y + 19.0), int(finding["confidence"]))
	var y := rect.position.y + 48.0
	var title := str(finding["title"])
	draw_multiline_string(font, Vector2(x, y), title, HORIZONTAL_ALIGNMENT_LEFT, width, 14, 3, INK)
	y += font.get_multiline_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, width, 14, 3).y + 4.0
	var bottom := rect.end.y - (24.0 if found.size() > 1 else 6.0)
	var lines := int(floor((bottom - y) / 14.0))
	if lines > 0:
		draw_multiline_string(font, Vector2(x, y), str(finding["detail"]), HORIZONTAL_ALIGNMENT_LEFT, width, 11, lines, INK_DIM)
	if found.size() > 1:
		var more := "ещё %d в «Выводах» ›" % (found.size() - 1)
		draw_string(font, Vector2(x, rect.end.y - 8.0), more, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, GOOD)
		_hits.append([Rect2(x, rect.end.y - 22.0, font.get_string_size(more, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x, 18.0),
			func(_at): insight_requested.emit()])


func _confidence(at: Vector2, level: int) -> void:
	for dot in range(3):
		var center := at + Vector2(float(dot) * 13.0, 0.0)
		if dot < level:
			draw_circle(center, 4.5, INK)
		else:
			draw_arc(center, 4.5, 0.0, TAU, 16, INK, 1.0)


## The founders' spread of the trait, dashed, against the living's, filled; each as a share of its own.
func _histogram(font: Font, rect: Rect2, color: Color) -> void:
	draw_string(font, rect.position + Vector2(0.0, 14.0), "Каким вид был и каким стал", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, INK)
	var plot := Rect2(rect.position + Vector2(8.0, 26.0), Vector2(rect.size.x - 16.0, rect.size.y - 66.0))
	var founders: Array = history.founders.get(shown_species, [])
	var then_bins: Array = founders[drilled] if drilled < founders.size() else []
	var now_bins: Array = _living_histograms[drilled] if drilled < _living_histograms.size() else []
	var then_total := _sum(then_bins)
	var now_total := _sum(now_bins)
	var top := 0.0001
	for bins in [[then_bins, then_total], [now_bins, now_total]]:
		for count in bins[0]:
			top = maxf(top, float(count) / maxf(1.0, float(bins[1])))
	var width := plot.size.x / float(TraitHistoryScript.BINS)
	for bin in range(TraitHistoryScript.BINS):
		var x := plot.position.x + float(bin) * width
		if bin < now_bins.size() and now_total > 0:
			var height := float(now_bins[bin]) / float(now_total) / top * plot.size.y
			draw_rect(Rect2(x + 1.0, plot.end.y - height, width - 2.0, height), Color(color, 0.75), true)
		if bin < then_bins.size() and then_total > 0 and int(then_bins[bin]) > 0:
			var height := float(then_bins[bin]) / float(then_total) / top * plot.size.y
			var box := Rect2(x + 1.0, plot.end.y - height, width - 2.0, height)
			for edge in [[box.position, Vector2(box.end.x, box.position.y)], [box.position, Vector2(box.position.x, box.end.y)],
					[Vector2(box.end.x, box.position.y), box.end]]:
				draw_dashed_line(edge[0], edge[1], INK, 1.0, 2.0)
	draw_line(Vector2(plot.position.x, plot.end.y), plot.end, INK, 1.0)
	draw_dashed_line(Vector2(plot.get_center().x, plot.position.y), Vector2(plot.get_center().x, plot.end.y), INK_DIM, 1.0, 4.0)
	var reach := HudTextScript.percent_change(1.0 + TraitHistoryScript.BIN_REACH)
	draw_string(font, Vector2(plot.position.x, plot.end.y + 13.0), HudTextScript.percent_change(1.0 - TraitHistoryScript.BIN_REACH),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, INK_DIM)
	draw_string(font, Vector2(plot.position.x, plot.end.y + 13.0), "вид", HORIZONTAL_ALIGNMENT_CENTER, plot.size.x, 11, INK_DIM)
	draw_string(font, Vector2(plot.position.x, plot.end.y + 13.0), reach, HORIZONTAL_ALIGNMENT_RIGHT, plot.size.x, 11, INK_DIM)
	var legend_y := plot.end.y + 30.0
	draw_dashed_line(Vector2(plot.position.x, legend_y - 4.0), Vector2(plot.position.x + 14.0, legend_y - 4.0), INK, 1.0, 2.0)
	draw_string(font, Vector2(plot.position.x + 20.0, legend_y), "основатели" if then_total > 0 else "основатели неизвестны",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 12, INK_DIM)
	draw_rect(Rect2(plot.position.x + 150.0, legend_y - 9.0, 12.0, 10.0), Color(color, 0.75), true)
	draw_string(font, Vector2(plot.position.x + 168.0, legend_y), "живые сейчас: %d" % now_total, HORIZONTAL_ALIGNMENT_LEFT,
		-1, 12, INK)


## Who left young and who died of what over the whole history, each set against the living of
## its time (`TraitHistory.differential()`): bars either side of a line, the count beside.
func _traces(font: Font, rect: Rect2, color: Color) -> void:
	draw_string(font, rect.position + Vector2(0.0, 14.0), "Кто оставил след · за всю историю", HORIZONTAL_ALIGNMENT_LEFT,
		-1, 14, INK)
	var rows: Array = []
	var widest := 0.02
	for group in GROUPS:
		var told: Dictionary = history.differential(shown_species, group, drilled)
		if int(told["count"]) <= 0:
			continue
		rows.append([group, told])
		widest = maxf(widest, absf(float(told["diff"])))
	if rows.is_empty():
		draw_multiline_string(font, rect.position + Vector2(0.0, 40.0),
			"Пока никто не родился и не умер с тех пор, как летопись считает черты.", HORIZONTAL_ALIGNMENT_LEFT,
			rect.size.x - 8.0, 13, -1, INK_DIM)
		return
	var label_width := 140.0
	var axis := rect.position.x + label_width + (rect.size.x - label_width - 90.0) * 0.5
	var half := (rect.size.x - label_width - 90.0) * 0.5
	var y := rect.position.y + 28.0
	var row_height := minf(24.0, (rect.size.y - 54.0) / float(rows.size()))
	draw_line(Vector2(axis, y - 2.0), Vector2(axis, y + row_height * rows.size()), INK, 1.0)
	for row in rows:
		var group := str(row[0])
		var told: Dictionary = row[1]
		var diff := float(told["diff"])
		draw_string(font, Vector2(rect.position.x, y + row_height * 0.5 + 5.0), str(GROUP_LABELS[group]),
			HORIZONTAL_ALIGNMENT_LEFT, label_width - 6.0, 13, INK)
		var length := diff / widest * half
		var bar_color := GOOD if group == "parents" else (CULL if group in ["predation", "culled"] else DROUGHT)
		if group in ["old_age", "emigrated"]:
			bar_color = INK_DIM
		draw_rect(Rect2(axis + minf(0.0, length), y + 4.0, absf(length), row_height - 8.0), Color(bar_color, 0.85), true)
		var sign := "" if roundi(absf(diff) * 1000.0) == 0 else ("+" if diff > 0.0 else "−")
		var value := "%s%s · %d" % [sign, TraitInsightsScript.percent(diff), int(told["count"])]
		draw_string(font, Vector2(axis + half + 8.0, y + row_height * 0.5 + 5.0), value, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, INK)
		y += row_height
	draw_string(font, Vector2(rect.position.x, y + 18.0), "против живых в то же время; число — сколько зверей",
		HORIZONTAL_ALIGNMENT_LEFT, rect.size.x, 11, INK_DIM)


# --- the pointer's reading ----------------------------------------------------------------

func _draw_tip(font: Font) -> void:
	if _hover.x < 0.0:
		return
	for plot_info in _plots:
		var plot: Rect2 = plot_info[0]
		if not plot.has_point(_hover):
			continue
		var point := _nearest_point(plot, _hover.x)
		if point.is_empty():
			return
		var x := _x(plot, float(point["time"]))
		draw_line(Vector2(x, plot.position.y), Vector2(x, plot.end.y), INK, 1.0)
		var index := int(plot_info[2])
		var lines: Array = [[HudTextScript.age_text(float(point["time"]), calendar), INK]]
		for id in plot_info[1]:
			var means = point["values"].get(str(id))
			if means == null or index >= means.size():
				continue
			var text := HudTextScript.percent_change(float(means[index]))
			var spread = point.get("spread", {}).get(str(id))
			if Array(plot_info[1]).size() == 1 and spread != null and index < spread.size():
				text += "  ±%s" % TraitInsightsScript.percent(float(spread[index]))
			if Array(plot_info[1]).size() > 1:
				text = "%s %s" % [_entry(str(id))["label"], text]
			lines.append([text, _entry(str(id))["color"]])
		var width := 0.0
		for line in lines:
			width = maxf(width, font.get_string_size(str(line[0]), HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x)
		var box := Rect2(x + 8.0, plot.position.y + 6.0, width + 14.0, 8.0 + 15.0 * lines.size())
		if box.end.x > size.x:
			box.position.x = x - 8.0 - box.size.x
		draw_rect(box, TIP, true)
		draw_rect(box, INK_DIM, false, 1.0)
		for position in range(lines.size()):
			draw_string(font, box.position + Vector2(7.0, 17.0 + 15.0 * position), str(lines[position][0]),
				HORIZONTAL_ALIGNMENT_LEFT, -1, 12, lines[position][1])
		return


func _nearest_point(plot: Rect2, at_x: float) -> Dictionary:
	var best := {}
	var best_distance := INF
	for point in history.points:
		var distance := absf(_x(plot, float(point["time"])) - at_x)
		if distance < best_distance:
			best_distance = distance
			best = point
	return best


## A click on a chart: with one species shown, that trait alone; with all, the trait of the species
## whose line passes nearest the click.
func _drill_at(index: int, plot: Rect2, reach: float, at: Vector2) -> void:
	if shown_species != "":
		drilled = index
		return
	var point := _nearest_point(plot, at.x)
	var nearest := ""
	var best := INF
	for id in _having(index, _ids()):
		var means = point.get("values", {}).get(str(id))
		if means == null or index >= means.size():
			continue
		var distance := absf(_y(plot, plot.get_center().y, reach, float(means[index])) - at.y)
		if distance < best:
			best = distance
			nearest = str(id)
	if nearest != "":
		shown_species = nearest
		drilled = index


# --- helpers ------------------------------------------------------------------------------

func _narrow() -> bool:
	return size.x < NARROW


func _toggle_scale() -> void:
	shared_scale = not shared_scale


func _ids() -> Array:
	var ids: Array = []
	for entry in species:
		ids.append(str(entry["id"]))
	return ids


func _entry(id: String) -> Dictionary:
	for entry in species:
		if str(entry["id"]) == id:
			return entry
	return {}


## How far either side of 1.0 a chart of trait `index` reaches for `ids`: every mean, and one alone
## its band too.
func _reach(index: int, ids: Array) -> float:
	var reach := TraitHistoryScript.MIN_SPAN
	for id in ids:
		reach = maxf(reach, history.span(index, str(id)))
		if ids.size() == 1:
			reach = maxf(reach, history.span(TraitsScript.MARKER, str(id)))
			for point in history.points:
				var means = point["values"].get(str(id))
				var spread = point.get("spread", {}).get(str(id))
				if means != null and spread != null and index < means.size() and index < spread.size():
					reach = maxf(reach, (absf(float(means[index]) - 1.0) + float(spread[index])) * 1.05)
	return reach


## `[Vector2(time, count)]` for `id`, oldest first, from the points that counted it.
func _counts(id: String) -> Array:
	var out: Array = []
	for point in history.points:
		var counts: Dictionary = point.get("counts", {})
		if counts.has(id):
			out.append(Vector2(float(point["time"]), float(counts[id])))
	return out


func _most_count(id: String) -> float:
	var most := 1.0
	for count in _counts(id):
		most = maxf(most, count.y)
	return most


func _spark(rect: Rect2, counts: Array, color: Color) -> void:
	if counts.size() < 2:
		return
	var low := INF
	var high := -INF
	for count in counts:
		low = minf(low, count.y)
		high = maxf(high, count.y)
	var line := PackedVector2Array()
	for count in counts:
		line.append(Vector2(_x(rect, count.x), rect.end.y - (count.y - low) / maxf(1.0, high - low) * rect.size.y))
	draw_polyline(line, color, 1.3, true)


func _first_time() -> float:
	return float(history.points[0]["time"])


func _last_time() -> float:
	return maxf(now, float(history.points[-1]["time"]))


func _x(rect: Rect2, time: float) -> float:
	var first := _first_time()
	return rect.position.x + (time - first) / maxf(1.0, _last_time() - first) * rect.size.x


static func _y(plot: Rect2, middle: float, reach: float, value: float) -> float:
	return clampf(middle - (value - 1.0) / reach * plot.size.y * 0.5, plot.position.y, plot.end.y)


static func _sum(bins: Array) -> int:
	var total := 0
	for count in bins:
		total += int(count)
	return total
