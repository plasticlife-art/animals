class_name TrailField
extends RefCounted

## Where animals have been walking.
##
## A grid finer than the grass, holding the distance walked through each cell. Every
## animal on its way somewhere adds to it from its real position, awake or asleep, and
## time wears it away by half every `half_life_seconds`. Herds that keep taking the same
## way to water leave a line; ground nobody crosses heals.
##
## Half a grass cell is about the width of a herd on the move. At a quarter, each
## animal drew its own hairline and no cell gathered enough wear to show.
##
## Only travel counts - walking to water, to a carcass, after prey, back to the herd.
## Grazing and wandering cover as much ground but go nowhere, and counting them put a
## blot under every herd and no path between them.
##
## Nothing in the simulation reads it. It exists so the player can see the paths the
## ecology has worn, which is why it is drawn in the normal view. It holds no
## randomness and steps a slice of the grid per tick, with the phase taken from the
## tick, so it replays and reloads exactly.

var enabled: bool = true
var cell_size: float = 48.0
var cols: int = 0
var rows: int = 0
var half_life_seconds: float = 900.0
var min_speed: float = 30.0
## Actions of an awake animal, and goals of a sleeping herd, that count as travel.
var travel_actions: Dictionary = {}
var travel_goals: Dictionary = {}
var decay_stride_ticks: int = 60
var _wear: PackedFloat32Array = PackedFloat32Array()


func initialize(world_config: Dictionary, world_size: Vector2, grass_cell_size: float) -> void:
	var config: Dictionary = world_config.get("trails", {})
	enabled = bool(config.get("enabled", true))
	# Sized in grass cells, so trails keep their width next to herds and pastures when
	# a map preset changes the grid.
	cell_size = maxf(1.0, grass_cell_size * float(config.get("cell_size_in_grass_cells", 0.5)))
	half_life_seconds = maxf(1.0, float(config.get("half_life_seconds", 900.0)))
	min_speed = maxf(0.0, float(config.get("min_speed", 30.0)))
	decay_stride_ticks = maxi(1, int(config.get("decay_stride_ticks", 60)))
	travel_actions = _name_set(config.get("travel_actions",
		["drink", "investigate_water", "scavenge_carcass", "hunt_prey", "join_herd"]), true)
	travel_goals = _name_set(config.get("travel_goals", ["water", "seek_carcass", "hunt", "regroup"]), false)
	cols = maxi(1, int(ceil(world_size.x / cell_size)))
	rows = maxi(1, int(ceil(world_size.y / cell_size)))
	_wear.resize(cols * rows)
	_wear.fill(0.0)


## Adds `distance`, walked over `seconds`, to the cell under `position`. Only going
## somewhere counts: a herd milling over its pasture at less than `min_speed` would
## otherwise wear a blot under itself within seconds and drown the paths out.
func deposit(position: Vector2, distance: float, seconds: float) -> void:
	if not enabled or distance <= 0.0 or _wear.is_empty() or distance < min_speed * seconds:
		return
	# Checked before the division: int() rounds towards zero, which would fold a step
	# just off the near edge back onto the map.
	if position.x < 0.0 or position.y < 0.0:
		return
	var x := int(position.x / cell_size)
	var y := int(position.y / cell_size)
	if x >= cols or y >= rows:
		return
	_wear[y * cols + x] += distance


## The same for a long step, spread along the way: a sleeping herd covers several
## cells between two coarse steps, and marking only where it lands draws a dotted line.
func deposit_segment(from: Vector2, to: Vector2, seconds: float) -> void:
	var distance := from.distance_to(to)
	if not enabled or distance < min_speed * seconds or distance <= 0.0:
		return
	var pieces := maxi(1, int(ceil(distance / (cell_size * 0.75))))
	var share := distance / float(pieces)
	for piece in range(pieces):
		deposit(from.lerp(to, (float(piece) + 0.5) / float(pieces)), share, 0.0)


func is_travel_action(action: StringName) -> bool:
	return travel_actions.has(action)


func is_travel_goal(goal_kind: String) -> bool:
	return travel_goals.has(goal_kind)


static func _name_set(names, as_string_names: bool) -> Dictionary:
	var result := {}
	if names is Array:
		for entry in names:
			if as_string_names:
				result[StringName(str(entry))] = true
			else:
				result[str(entry)] = true
	return result


func wear_at(position: Vector2) -> float:
	if _wear.is_empty():
		return 0.0
	var x := clampi(int(floor(position.x / cell_size)), 0, cols - 1)
	var y := clampi(int(floor(position.y / cell_size)), 0, rows - 1)
	return _wear[y * cols + x]


func step(delta: float, tick: int) -> void:
	if not enabled or _wear.is_empty():
		return
	var stride := decay_stride_ticks
	var keep := pow(0.5, delta * float(stride) / half_life_seconds)
	for index in range(posmod(tick, stride), _wear.size(), stride):
		var value := _wear[index]
		if value > 0.0:
			_wear[index] = 0.0 if value < 0.5 else value * keep


func get_cell_count() -> int:
	return _wear.size()


func export_cells() -> PackedFloat32Array:
	return _wear.duplicate()


func import_cells(cells) -> void:
	if cells is PackedFloat32Array and cells.size() == _wear.size():
		_wear = cells.duplicate()
