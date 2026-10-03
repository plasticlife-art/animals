class_name TraitHistory
extends RefCounted

## The inherited traits of each species over the whole life of the world, for the chronicle's
## «Черты»: a point every `interval` simulated seconds with each species' four means, read off
## the stats snapshot (`trait_<name>_<species>`). The charts' own series keeps the last minutes,
## and a trait moves over generations, so this keeps everything: out of room, it drops every
## other point and samples half as often, and a world of any age fits in `MAX_POINTS`.
## Main thread only, kept with the story; nothing here reaches the simulation.

const TraitsScript := preload("res://scripts/agents/traits.gd")
const MAX_POINTS := 480
const START_INTERVAL := 30.0
## The least a chart's scale reaches either side of 1.0, so founders' noise is not drawn as a
## cliff.
const MIN_SPAN := 0.05

var interval: float = START_INTERVAL
## `[{time, values: {species: [speed, vision, appetite, longevity]}}]`, oldest first.
var points: Array = []
var _next_at: float = 0.0


## Takes a point from `metrics`, a stats snapshot, when the next is due, for `species_ids` - the
## species with heredity. One with nobody left is skipped: its mean would read 1.0.
func sample(now: float, metrics: Dictionary, species_ids: Array) -> void:
	if now < _next_at or metrics.is_empty() or species_ids.is_empty():
		return
	var values := {}
	for species_id in species_ids:
		if int(metrics.get("%s_population" % species_id, 0)) <= 0 \
				or not metrics.has("trait_speed_%s" % species_id):
			continue
		var means: Array = []
		for trait_name in TraitsScript.NAMES:
			means.append(float(metrics.get("trait_%s_%s" % [trait_name, species_id], 1.0)))
		values[species_id] = means
	points.append({"time": now, "values": values})
	_next_at = now + interval
	if points.size() > MAX_POINTS:
		var kept: Array = []
		for index in range(0, points.size(), 2):
			kept.append(points[index])
		points = kept
		interval *= 2.0


## How far either side of 1.0 a chart of trait `index` has to reach to hold every point.
func span(index: int) -> float:
	var reach := MIN_SPAN
	for point in points:
		for means in point["values"].values():
			reach = maxf(reach, absf(float(means[index]) - 1.0) * 1.15)
	return reach


## The latest means of `species_id`, or none.
func latest(species_id: String) -> Array:
	for position in range(points.size() - 1, -1, -1):
		var values: Dictionary = points[position]["values"]
		if values.has(species_id):
			return values[species_id]
	return []


func clear() -> void:
	interval = START_INTERVAL
	points.clear()
	_next_at = 0.0


func export_state() -> Dictionary:
	return {"interval": interval, "points": points.duplicate(true), "next_at": _next_at}


func import_state(data: Dictionary) -> void:
	clear()
	interval = maxf(START_INTERVAL, float(data.get("interval", START_INTERVAL)))
	points = data.get("points", []).duplicate(true)
	_next_at = float(data.get("next_at", 0.0))
