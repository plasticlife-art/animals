class_name SaveSystem
extends RefCounted

## Writes and restores a running simulation.
##
## What is saved is only what a fresh `initialize(config, seed)` would not
## reproduce. Terrain is the clearest example: twelve thousand cells across
## seven parallel arrays, all regenerated bit-for-bit from the seed, so none of
## it is written. Loading therefore runs a normal initialization first and then
## replaces the layers that change over time.
##
## Stored with `store_var` rather than JSON. The state is full of `Vector2`,
## `Vector2i` and `PackedFloat32Array`, and `_sector_states` is keyed by
## `Vector2i` - none of which JSON can express without a conversion pass in both
## directions, which is one more thing to get subtly wrong.
##
## Fidelity: the generator's position is saved, so a loaded world continues from
## the same random stream. It is not, however, byte-identical to an uninterrupted
## run. Several hot loops iterate Dictionaries in insertion order and that order
## is rebuilt here by index, so an occasional tie is broken differently and the
## two runs drift apart over hundreds of ticks. Populations and behaviour match;
## individual trajectories eventually do not.

const SAVE_VERSION := 2
const SAVE_DIR := "user://saves"
const SLOTS := ["autosave_a.dat", "autosave_b.dat"]


static func slot_paths() -> Array:
	var paths: Array = []
	for slot in SLOTS:
		paths.append("%s/%s" % [SAVE_DIR, slot])
	return paths


## The most recent readable save, or "" when there is none.
##
## Two slots are written alternately so that a crash during a write cannot
## destroy the only copy; this is what picks the survivor.
static func latest_slot() -> String:
	var newest := ""
	var newest_tick := -1
	for path in slot_paths():
		if not FileAccess.file_exists(path):
			continue
		var header := _read_header(path)
		if header.is_empty() or int(header.get("version", 0)) != SAVE_VERSION:
			continue
		var tick := int(header.get("tick", -1))
		if tick > newest_tick:
			newest_tick = tick
			newest = path
	return newest


static func next_slot() -> String:
	var oldest := ""
	var oldest_tick := 1 << 62
	for path in slot_paths():
		if not FileAccess.file_exists(path):
			return path
		var header := _read_header(path)
		var tick := int(header.get("tick", -1))
		if tick < oldest_tick:
			oldest_tick = tick
			oldest = path
	return oldest


static func save(manager, selection: Dictionary, path: String = "") -> bool:
	if manager == null or manager.world_state == null:
		return false
	var world_data: Dictionary = manager.export_simulation_state()
	var target := path if path != "" else next_slot()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(SAVE_DIR))
	var file := FileAccess.open(target, FileAccess.WRITE)
	if file == null:
		push_error("Could not open save file for writing: %s" % target)
		return false
	file.store_var({
		"version": SAVE_VERSION,
		"selection": selection.duplicate(),
		"config_bundle": manager.config_bundle.duplicate(true),
		"seed": manager.seed,
		"tick": manager.current_tick,
		"simulation_time": manager.simulation_time,
		"accumulator": manager.accumulator,
		# Both halves: the seed alone rewinds to the beginning of the stream.
		"rng_seed": manager.rng.seed,
		"rng_state": manager.rng.state,
		"world": world_data,
		"stats": manager.stats_system.counters.duplicate(),
	}, true)
	file.close()
	return true


static func read(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var data = file.get_var(true)
	file.close()
	if typeof(data) != TYPE_DICTIONARY:
		push_error("Save file is not a dictionary: %s" % path)
		return {}
	# Only the current version. Version 1 predates the per-species sector census:
	# its sector states carry `herbivore_count` / `predator_count` and no
	# `species_counts`, so it would load without complaint and then report an
	# empty world to every prey-pressure and threat lookup - predators would
	# quietly stop finding herds. Rejected rather than migrated; the caller
	# already falls back to starting a fresh simulation.
	if int(data.get("version", 0)) != SAVE_VERSION:
		push_error("Save file version %s, expected %d: %s"
			% [data.get("version", 0), SAVE_VERSION, path])
		return {}
	return data


## Rebuilds `manager` from `data`, including regenerating the world.
##
## The order is load-bearing. `initialize` consumes the generator to build
## terrain, grass and the starting herds, so the saved generator position can
## only be restored after that - otherwise generation would immediately
## overwrite it.
static func restore(manager, data: Dictionary) -> bool:
	if manager == null or data.is_empty():
		return false
	var selection: Dictionary = data.get("selection", {})
	manager.initialize(data.get("config_bundle", ConfigLoader.load_config_bundle(selection)), int(data.get("seed", 0)))
	manager.world_state.import_state(data.get("world", {}))
	manager.current_tick = int(data.get("tick", 0))
	manager.simulation_time = float(data.get("simulation_time", 0.0))
	manager.accumulator = float(data.get("accumulator", 0.0))
	for key in data.get("stats", {}).keys():
		if manager.stats_system.counters.has(key):
			manager.stats_system.counters[key] = data["stats"][key]
	manager.rng.seed = int(data.get("rng_seed", manager.seed))
	manager.rng.state = int(data.get("rng_state", 0))
	# The snapshot the HUD and the charts read was taken during `initialize`, so
	# without this the interface shows the freshly generated world for a tick.
	manager.stats_system.refresh_snapshot(
		manager.world_state, manager.current_tick, manager.simulation_time)
	return true


## Only the cheap fields, for choosing between slots without parsing an entire
## world. `store_var` has no partial read, so this does pay to decode the whole
## file - it just throws the bulk away instead of holding onto it.
static func _read_header(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var data = file.get_var(true)
	file.close()
	if typeof(data) != TYPE_DICTIONARY:
		return {}
	# The version travels with the header so `latest_slot()` can skip a slot that
	# `read()` would refuse. Without it the setup screen offers Continue for a
	# save it cannot load, and the button silently starts a new world instead.
	return {
		"version": int(data.get("version", 0)),
		"tick": data.get("tick", -1),
		"seed": data.get("seed", 0),
		"selection": data.get("selection", {}),
	}
