extends SceneTree

## The reserve's island left to itself for hours: no viewers, LOD on, stepped inline as fast as
## it goes - what the balance of a closed world is tuned by, where a species lost is lost for good.
## A line every `SAMPLE_SECONDS` simulated seconds: each species' count, births and deaths by cause
## since the last line; for each species with territories its dens (pairs, one holder, vacant),
## the lone holders by sex, and the grown ones with no den by sex. The run stops when a species the
## world began with is gone, and ends with one summary line: each species' lowest count and when,
## and what was lost when.
##
##   Godot --headless --path . --script res://scripts/dev/island_probe.gd -- seed hours [out.json]
##       [section.path.to.key=value ...]
##
## Trailing `key=value` pairs override the reserve's bundle, as in `ecology_audit.gd`. A seed
## gives the same run each time (the world draws from its own stream only).

const SAMPLE_SECONDS := 300.0

var births := {}
var deaths := {}


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var run_seed := int(args[0]) if args.size() > 0 else 7
	var hours := float(args[1]) if args.size() > 1 else 12.0
	var output_path := ""
	var overrides: Array = []
	for index in range(2, args.size()):
		if "=" in str(args[index]):
			overrides.append(str(args[index]))
		else:
			output_path = str(args[index])
	var bundle := ConfigLoader.load_reserve_bundle(ConfigLoader.load_reserve_config())
	for item in overrides:
		_override(bundle, str(item))
	var manager = preload("res://scripts/core/simulation_manager.gd").new()
	manager.initialize(bundle, run_seed)
	manager.set_lod_enabled(true)
	var world: WorldState = manager.world_state
	manager.event_bus.event_emitted.connect(_on_event)
	var species_ids: Array = []
	for species_id in _counts(world).keys():
		species_ids.append(species_id)
	species_ids.sort()
	var lowest := {}
	for species_id in species_ids:
		lowest[species_id] = [INF, 0.0]
	var lost := {}
	var samples: Array = []
	var started := Time.get_ticks_msec()
	print("island probe seed %d, %.1f h, %s" % [run_seed, hours, " ".join(overrides)])
	var total_ticks: int = int(hours * 3600.0 * float(manager.tick_rate))
	var sample_ticks: int = int(SAMPLE_SECONDS * float(manager.tick_rate))
	for tick in range(1, total_ticks + 1):
		manager.step_once()
		if tick % sample_ticks != 0:
			continue
		var now: float = float(tick) / float(manager.tick_rate)
		var counts := _counts(world)
		var line := "%6.0f (%5.0f w)" % [now, float(Time.get_ticks_msec() - started) / 1000.0]
		var sample := {"t": now, "counts": counts, "births": births.duplicate(true), "deaths": deaths.duplicate(true), "dens": {}}
		for species_id in species_ids:
			var count := int(counts.get(species_id, 0))
			if count < float(lowest[species_id][0]):
				lowest[species_id] = [count, now]
			if count == 0 and not lost.has(species_id):
				lost[species_id] = now
			line += " | %s %d +%d %s" % [species_id, count, int(births.get(species_id, 0)), _causes(deaths.get(species_id, {}))]
			if world.territory_registry(species_id) != null:
				var dens := _dens(world, species_id)
				sample["dens"][species_id] = dens
				line += " dens %d/%d/%d lone M%d F%d homeless M%d F%d" % [dens["pairs"], dens["singles"], dens["vacant"],
					dens["lone_male"], dens["lone_female"], dens["homeless_male"], dens["homeless_female"]]
		print(line)
		samples.append(sample)
		births.clear()
		deaths.clear()
		if not lost.is_empty():
			break
	var summary := "SUMMARY seed %d:" % run_seed
	for species_id in species_ids:
		summary += " %s min %d@%.0f" % [species_id, int(lowest[species_id][0]), float(lowest[species_id][1])]
	summary += " | lost %s | %.0f s simulated" % [str(lost), float(manager.current_tick) / manager.tick_rate]
	print(summary)
	if output_path != "":
		var file := FileAccess.open(output_path, FileAccess.WRITE)
		file.store_string(JSON.stringify({"seed": run_seed, "overrides": overrides, "lowest": lowest, "lost": lost,
			"samples": samples}))
		file.close()
	manager.shutdown()
	manager.free()
	quit(0)


func _on_event(event: Dictionary) -> void:
	var species := str(event.get("species", ""))
	match str(event.get("type", "")):
		"AgentBorn":
			births[species] = int(births.get(species, 0)) + 1
		"AgentDied":
			var cause := str(event.get("data", {}).get("cause", "?"))
			if not deaths.has(species):
				deaths[species] = {}
			deaths[species][cause] = int(deaths[species].get(cause, 0)) + 1


## Every animal by species, awake or asleep.
static func _counts(world: WorldState) -> Dictionary:
	var counts := {}
	for agent in world.living_agents:
		if agent != null and agent.is_alive:
			counts[agent.species_type] = int(counts.get(agent.species_type, 0)) + 1
	for key in world._sector_states.keys():
		for record in world._sector_states[key].get("dormant_records", []):
			var species := str(record.get("species_type", ""))
			counts[species] = int(counts.get(species, 0)) + 1
	return counts


## A species' dens and who is without one: `{pairs, singles, vacant, lone_male, lone_female,
## homeless_male, homeless_female}` - lone, a den held by one of that sex; homeless, grown
## (`dispersal_age_seconds`) and holding none.
static func _dens(world: WorldState, species_id: String) -> Dictionary:
	var registry := world.territory_registry(species_id)
	var dens := registry.census()
	dens["lone_male"] = 0
	dens["lone_female"] = 0
	for territory in registry.territories:
		var male := int(territory["male"]) != TerritoryRegistry.NOBODY
		var female := int(territory["female"]) != TerritoryRegistry.NOBODY
		if male != female:
			dens["lone_male" if male else "lone_female"] += 1
	var grown := float(world.territory_config(species_id).get("dispersal_age_seconds", 240.0))
	dens["homeless_male"] = 0
	dens["homeless_female"] = 0
	var animals: Array = []
	for agent in world.living_agents:
		if agent != null and agent.is_alive and agent.species_type == species_id:
			animals.append([agent.id, agent.sex, agent.age])
	for key in world._sector_states.keys():
		for record in world._sector_states[key].get("dormant_records", []):
			if str(record.get("species_type", "")) == species_id:
				animals.append([int(record.get("id", -1)), str(record.get("sex", "")), float(record.get("age", 0.0))])
	for animal in animals:
		if float(animal[2]) >= grown and registry.territory_of(int(animal[0])) == -1:
			dens["homeless_male" if str(animal[1]) == AgentBase.SEX_MALE else "homeless_female"] += 1
	return dens


static func _causes(by_cause: Dictionary) -> String:
	var parts: Array = []
	var keys := by_cause.keys()
	keys.sort()
	for cause in keys:
		parts.append("%s%d" % [_short(str(cause)), int(by_cause[cause])])
	return "-" + ",".join(parts) if not parts.is_empty() else ""


static func _short(cause: String) -> String:
	return {"predation": "eaten", "starvation": "hunger", "thirst": "thirst", "old_age": "age", "emigrated": "lost",
		"culled": "cull"}.get(cause, cause)


static func _override(bundle: Dictionary, item: String) -> void:
	var parts: PackedStringArray = item.split("=", false, 1)
	var path: PackedStringArray = parts[0].split(".")
	var target: Dictionary = bundle
	for step in range(path.size() - 1):
		if not target.has(path[step]) or not (target[path[step]] is Dictionary):
			target[path[step]] = {}
		target = target[path[step]]
	var parsed: Variant = JSON.parse_string(parts[1])
	target[path[path.size() - 1]] = parsed if parsed != null else parts[1]
