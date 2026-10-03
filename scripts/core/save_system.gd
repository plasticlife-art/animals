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

const SAVE_VERSION := 3
const MIN_READABLE_VERSION := 1
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
		if header.is_empty() or not _is_readable_version(int(header.get("version", 0))):
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


## `story` is the view's story of the world (`StoryBook.export_state()`): names, family tree
## and pins. The simulation never reads it; a save without it loads with none.
static func save(manager, selection: Dictionary, path: String = "", story: Dictionary = {}) -> bool:
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
		"story": story.duplicate(true),
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
	var version := int(data.get("version", 0))
	if not _is_readable_version(version):
		push_error("Save file version %s is outside the supported range %d-%d: %s"
			% [data.get("version", 0), MIN_READABLE_VERSION, SAVE_VERSION, path])
		return {}
	if version == 1:
		data = _migrate_v1_to_v2(data)
	if int(data.get("version", 0)) == 2:
		data = _migrate_v2_to_v3(data)
	return data


static func _is_readable_version(version: int) -> bool:
	return version >= MIN_READABLE_VERSION and version <= SAVE_VERSION


## V1 did not store the resolved config bundle or the generic per-species sector
## census. Missing perception fields on agent records are already handled by
## each agent's runtime-state defaults during import.
static func _migrate_v1_to_v2(source: Dictionary) -> Dictionary:
	var data: Dictionary = source.duplicate(true)
	var selection: Dictionary = data.get("selection", {})
	data["config_bundle"] = ConfigLoader.load_config_bundle(selection)
	var world: Dictionary = data.get("world", {}).duplicate(true)
	var sectors = world.get("sectors", [])
	if sectors is Array:
		for index in sectors.size():
			if not (sectors[index] is Dictionary):
				continue
			var sector: Dictionary = sectors[index].duplicate(true)
			if not sector.has("species_counts"):
				var counts := {}
				# Sleeping sectors already hold the most reliable census in their
				# aggregate records. Prefer it when present because old flat counts
				# could lag until the next dormant update.
				var aggregates: Array = sector.get("dormant_aggregates", [])
				for aggregate in aggregates:
					if aggregate is Dictionary:
						var species_id := str(aggregate.get("species_type", ""))
						if species_id != "":
							counts[species_id] = int(counts.get(species_id, 0)) + int(aggregate.get("count", 0))
				if counts.is_empty():
					counts = {
						"herbivore": int(sector.get("herbivore_count", 0)),
						"predator": int(sector.get("predator_count", 0)),
					}
				sector["species_counts"] = counts
				sector["threat_score"] = float(counts.get("predator", 0))
			sector.erase("herbivore_count")
			sector.erase("predator_count")
			sectors[index] = sector
	world["sectors"] = sectors
	data["world"] = world
	data["version"] = 2
	return data


## V3 animals carry inherited traits (`Traits`) and sleeping groups their means. A v2 save has
## neither: its records read neutral traits, and its own config bundle has no `traits` block, so
## the world plays on without heredity, as it did when it was saved.
static func _migrate_v2_to_v3(source: Dictionary) -> Dictionary:
	var data: Dictionary = source
	data["version"] = 3
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
	var shipped: Dictionary = ConfigLoader.load_config_bundle(selection)
	manager.initialize(ConfigLoader.with_shipped_presentation(data.get("config_bundle", shipped), shipped),
		int(data.get("seed", 0)))
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
