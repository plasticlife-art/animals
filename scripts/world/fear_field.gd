class_name FearField
extends RefCounted

## Where prey have learnt to expect predators.
##
## A coarse grid of risk over the map. A kill adds to the cell it happened in and, less,
## to the cells around it; so does a herd being scared. Time wears the risk away by
## half every `half_life_seconds`. Grazers that are not yet hungry keep off cells above
## their tolerance, so grass regrows where predators hunt - the trophic cascade.
##
## It holds no randomness and steps a slice of the grid per tick, with the phase taken
## from the tick, so it replays and reloads exactly.

var enabled: bool = true
var cell_size: float = 384.0
var cols: int = 0
var rows: int = 0
var half_life_seconds: float = 480.0
var kill_risk: float = 1.0
var scare_risk: float = 0.05
var hunt_pressure_risk: float = 0.1
var decay_stride_ticks: int = 18
var _risk: PackedFloat32Array = PackedFloat32Array()


func initialize(world_config: Dictionary, world_size: Vector2, grass_cell_size: float) -> void:
	var config: Dictionary = world_config.get("fear", {})
	enabled = bool(config.get("enabled", true))
	# Sized in grass cells, so the field keeps its proportion to herds and pastures
	# when a map preset changes the grid.
	cell_size = maxf(1.0, grass_cell_size * float(config.get("cell_size_in_grass_cells", 4.0)))
	half_life_seconds = maxf(1.0, float(config.get("half_life_seconds", 480.0)))
	kill_risk = float(config.get("kill_risk", 1.0))
	scare_risk = float(config.get("scare_risk", 0.05))
	hunt_pressure_risk = float(config.get("hunt_pressure_risk", 0.1))
	decay_stride_ticks = maxi(1, int(config.get("decay_stride_ticks", 18)))
	cols = maxi(1, int(ceil(world_size.x / cell_size)))
	rows = maxi(1, int(ceil(world_size.y / cell_size)))
	_risk.resize(cols * rows)
	_risk.fill(0.0)


## Adds `amount` at `position`: all of it to that cell, half to the four beside it and
## a quarter to the four diagonal ones.
func deposit(position: Vector2, amount: float) -> void:
	if not enabled or amount <= 0.0 or _risk.is_empty():
		return
	var cx := clampi(int(floor(position.x / cell_size)), 0, cols - 1)
	var cy := clampi(int(floor(position.y / cell_size)), 0, rows - 1)
	for dy in range(-1, 2):
		var y := cy + dy
		if y < 0 or y >= rows:
			continue
		for dx in range(-1, 2):
			var x := cx + dx
			if x < 0 or x >= cols:
				continue
			var share := 1.0 if dx == 0 and dy == 0 else (0.5 if dx == 0 or dy == 0 else 0.25)
			_risk[y * cols + x] += amount * share


func risk_at(position: Vector2) -> float:
	if _risk.is_empty():
		return 0.0
	var x := clampi(int(floor(position.x / cell_size)), 0, cols - 1)
	var y := clampi(int(floor(position.y / cell_size)), 0, rows - 1)
	return _risk[y * cols + x]


func step(delta: float, tick: int) -> void:
	if not enabled or _risk.is_empty():
		return
	var stride := decay_stride_ticks
	var keep := pow(0.5, delta * float(stride) / half_life_seconds)
	for index in range(posmod(tick, stride), _risk.size(), stride):
		var value := _risk[index]
		if value > 0.0:
			_risk[index] = 0.0 if value < 0.0005 else value * keep


func get_cell_count() -> int:
	return _risk.size()


func get_risk(index: int) -> float:
	return _risk[index] if index >= 0 and index < _risk.size() else 0.0


func get_cell_rect(index: int) -> Rect2:
	@warning_ignore("integer_division")
	return Rect2(float(index % cols) * cell_size, float(index / cols) * cell_size, cell_size, cell_size)


func export_cells() -> PackedFloat32Array:
	return _risk.duplicate()


func import_cells(cells) -> void:
	if cells is PackedFloat32Array and cells.size() == _risk.size():
		_risk = cells.duplicate()
