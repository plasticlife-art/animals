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

const SAVE_VERSION := 4
const MIN_READABLE_VERSION := 1
const SAVE_DIR := "user://saves"
## The sandbox's slots, and a scenario's: a scenario played does not write over the world the
## player left in the sandbox.
const SLOTS := ["autosave_a.dat", "autosave_b.dat"]
const SCENARIO_SLOTS := ["scenario_a.dat", "scenario_b.dat"]
## The living reserve's (`--reserve`): never Continue's, and never over the player's worlds.
const RESERVE_SLOTS := ["reserve_a.dat", "reserve_b.dat"]
const KIND_SANDBOX := "sandbox"
const KIND_SCENARIO := "scenario"
const KIND_RESERVE := "reserve"

## Where the slots are; a test points it elsewhere so it never touches the player's saves.
static var save_dir: String = SAVE_DIR
## The pool task writing a save (`save_exported()`), or -1.
static var _writing_task: int = -1


## The slots of `kind` (`KIND_SANDBOX`, `KIND_SCENARIO`, `KIND_RESERVE`), or of the player's two
## by default.
static func slot_paths(kind: String = "") -> Array:
	var names: Array = []
	if kind == KIND_RESERVE:
		names.append_array(RESERVE_SLOTS)
	if kind == "" or kind == KIND_SANDBOX:
		names.append_array(SLOTS)
	if kind == "" or kind == KIND_SCENARIO:
		names.append_array(SCENARIO_SLOTS)
	var paths: Array = []
	for slot in names:
		paths.append("%s/%s" % [save_dir, slot])
	return paths


## The most recently written readable save of either kind, or "" when there is none: what
## Continue opens.
##
## Two slots of each kind are written alternately so that a crash during a write cannot
## destroy the only copy; this is what picks the survivor. Saves are told apart by when they
## were written (`saved_at`), then by tick: a tick says nothing between two worlds, and a world
## begun anew after a long one used to lose Continue to the old one's higher tick. A save from
## before `saved_at` counts as the oldest.
static func latest_slot(kind: String = "") -> String:
	var newest := ""
	var newest_key := [-1.0, -1]
	for path in slot_paths(kind):
		if not FileAccess.file_exists(path):
			continue
		var header := _read_header(path)
		if header.is_empty() or not _is_readable_version(int(header.get("version", 0))):
			continue
		var key := _age_key(header)
		if _is_later(key, newest_key):
			newest_key = key
			newest = path
	return newest


## The slot of `kind` the next save goes to: an empty one, else the older of the two.
static func next_slot(kind: String = KIND_SANDBOX) -> String:
	var oldest := ""
	var oldest_key := [INF, 1 << 62]
	for path in slot_paths(kind):
		if not FileAccess.file_exists(path):
			return path
		var key := _age_key(_read_header(path))
		if _is_later(oldest_key, key):
			oldest_key = key
			oldest = path
	return oldest


## Which kind of slot `manager`'s world saves to.
static func kind_of(manager) -> String:
	if manager != null and manager.config_bundle.has("reserve"):
		return KIND_RESERVE
	return KIND_SCENARIO if manager != null and manager.scenario != null and manager.scenario.is_active() else KIND_SANDBOX


static func _age_key(header: Dictionary) -> Array:
	return [float(header.get("saved_at", 0.0)), int(header.get("tick", -1))]


static func _is_later(key: Array, than: Array) -> bool:
	return float(key[0]) > float(than[0]) or (float(key[0]) == float(than[0]) and int(key[1]) > int(than[1]))


## `story` is the view's story of the world (`StoryBook.export_state()`): names, family tree
## and pins. The simulation never reads it; a save without it loads with none. A scenario's score
## (`ScenarioRunner`) goes under `scenario`, and the save into the scenario's slots. A reserve's
## viewers (`ReserveSession.export_state()`) go under `reserve`, the save into the reserve's slots.
static func save(manager, selection: Dictionary, path: String = "", story: Dictionary = {}, reserve: Dictionary = {}) -> bool:
	if manager == null or manager.world_state == null:
		return false
	var world_data: Dictionary = manager.export_simulation_state()
	var target := path if path != "" else next_slot(kind_of(manager))
	return _write(target, _payload(manager, world_data, selection, story, reserve))


## As `save()`, for the world `SimulationManager.world_exported` brought: the rest is read now, in
## the handler, where it is the same tick's, and the rest is done on a pool thread - choosing the
## slot (which reads both slots whole) and writing it, into a temporary file first, renamed over
## the slot once whole - so the game does not wait on it.
static func save_exported(manager, world_data: Dictionary, selection: Dictionary, story: Dictionary = {},
		reserve: Dictionary = {}) -> void:
	var payload := _payload(manager, world_data, selection, story, reserve)
	finish_writing()
	_writing_task = WorkerThreadPool.add_task(_write_next.bind(kind_of(manager), payload), false, "Autosave")


static func _write_next(kind: String, payload: Dictionary) -> void:
	_write(next_slot(kind), payload)


## Waits for a save still being written (`save_exported()`), as before quitting.
static func finish_writing() -> void:
	if _writing_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_writing_task)
		_writing_task = -1


static func _payload(manager, world_data: Dictionary, selection: Dictionary, story: Dictionary, reserve: Dictionary) -> Dictionary:
	return {
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
		"scenario": manager.scenario.export_state() if kind_of(manager) == KIND_SCENARIO else {},
		"reserve": reserve.duplicate(true),
		"saved_at": Time.get_unix_time_from_system(),
	}


## Writes `payload` to `target` by way of a temporary file beside it, so a slot is never left
## half written.
static func _write(target: String, payload: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(target.get_base_dir()))
	var partial := target + ".part"
	var file := FileAccess.open(partial, FileAccess.WRITE)
	if file == null:
		push_error("Could not open save file for writing: %s" % partial)
		return false
	file.store_var(payload, true)
	file.close()
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(partial), ProjectSettings.globalize_path(target)) == OK


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
	if int(data.get("version", 0)) == 3:
		data = _migrate_v3_to_v4(data)
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


## V4 worlds carry the player's state (`PlayerState`: the powers' charges and cooldowns, the
## orders given, the ponds dug), which the seed cannot make again. A v3 save has none: the powers
## start as configured, and its own bundle, from before them, takes them as shipped
## (`ConfigLoader.with_shipped_presentation()`). The version moved so an older build refuses a
## world with dug ponds rather than lose them.
static func _migrate_v3_to_v4(source: Dictionary) -> Dictionary:
	var data: Dictionary = source
	data["version"] = 4
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
	# After the world and its clock: the score's own herd and goals are the saved ones, measured
	# against the world as it was saved.
	manager.import_scenario(data.get("scenario", {}))
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
		"saved_at": float(data.get("saved_at", 0.0)),
		"scenario": str(data.get("config_bundle", {}).get("challenge", {}).get("id", "")),
	}
