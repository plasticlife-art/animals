extends SceneTree

## The reserve's island left to itself for hours: no viewers, LOD on, stepped inline as fast as
## it goes - what the balance of a closed world is tuned by, where a species lost is lost for good.
## A line every `SAMPLE_SECONDS` simulated seconds: each species' count, births and deaths by cause
## since the last line; for each species with territories its dens (pairs, one holder, vacant),
## the lone holders by sex, and the grown ones with no den by sex; `pairs` why the dens' pairs had
## no young in the breeding season's plateau (`_check_pairs()`, every `PAIR_CHECK_SECONDS`); `need`
## the grown ones' mean hunger and energy and the share strong enough to breed; and for prey `by`,
## who ate them. The probe only reads the world, so a run with these columns is the run without.
## The run stops when a species the world began with is gone, and ends with one summary line: each
## species' lowest count and when, and what was lost when.
##
##   Godot --headless --path . --script res://scripts/dev/island_probe.gd -- seed hours [out.json]
##       [section.path.to.key=value ...]
##
## Trailing `key=value` pairs override the reserve's bundle, as in `ecology_audit.gd`. A seed
## gives the same run each time (the world draws from its own stream only).

const SAMPLE_SECONDS := 300.0
## How often, in the breeding season's plateau, each den's pair is asked why it is not breeding.
const PAIR_CHECK_SECONDS := 10.0
const TraitsScript := preload("res://scripts/agents/traits.gd")

var births := {}
var deaths := {}
## species -> {reason: pair checks}: what held a pair holding a den back (`_blocker()`).
var pair_checks := {}
## prey species -> {hunter species: kills}: who ate whom, awake and asleep.
var eaten_by := {}
var world_ref: WorldState


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
	world_ref = world
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
	var check_ticks: int = maxi(1, int(PAIR_CHECK_SECONDS * float(manager.tick_rate)))
	for tick in range(1, total_ticks + 1):
		manager.step_once()
		if tick % check_ticks == 0:
			_check_pairs(world)
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
				if pair_checks.has(species_id):
					line += " pairs %s" % _causes(pair_checks[species_id]).trim_prefix("-")
				var needs := _needs(world, species_id)
				sample["dens"][species_id]["needs"] = needs
				line += " need h%.0f e%.0f fit%.0f%%" % [needs["hunger"], needs["energy"], 100.0 * needs["fit_share"]]
			if eaten_by.has(species_id):
				line += " by %s" % _causes(eaten_by[species_id]).trim_prefix("-")
		print(line)
		sample["pair_checks"] = pair_checks.duplicate(true)
		sample["eaten_by"] = eaten_by.duplicate(true)
		samples.append(sample)
		births.clear()
		deaths.clear()
		pair_checks.clear()
		eaten_by.clear()
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
			var data: Dictionary = event.get("data", {})
			var cause := str(data.get("cause", "?"))
			if not deaths.has(species):
				deaths[species] = {}
			deaths[species][cause] = int(deaths[species].get(cause, 0)) + 1
			if cause == "predation":
				var hunter := str(data.get("killer_species", ""))
				if hunter == "" and world_ref != null:
					var killer = world_ref.get_agent(int(event.get("other_agent_id", -1)))
					hunter = "?" if killer == null else str(killer.species_type)
				if not eaten_by.has(species):
					eaten_by[species] = {}
				eaten_by[species][hunter] = int(eaten_by[species].get(hunter, 0)) + 1


## In the plateau of a species' breeding season (`WorldState.breeding_value()` 1), why each den
## held by a pair has no young coming, tallied in `pair_checks`: the first of the female's, then
## the male's, of `young`, `cd` (resting since the last young), `energy`, `hunger`, `thirst`;
## with both ready `cap` when the species is at its capacity, else where they are - `ready`
## asleep in one sector (the sleeping step can breed them), `awake` both awake, `split` asleep in
## two sectors or one awake and one asleep (neither step can).
func _check_pairs(world: WorldState) -> void:
	var sleepers := {}
	for key in world._sector_states.keys():
		for record in world._sector_states[key].get("dormant_records", []):
			sleepers[int(record.get("id", -1))] = [key, record]
	var counts := {}
	for species_id in world.territories.keys():
		if world.breeding_value(species_id) < 1.0:
			continue
		var reproduction: Dictionary = world.config_bundle["species"][species_id].get("reproduction", {})
		var tally: Dictionary = pair_checks.get(species_id, {})
		if counts.is_empty():
			counts = _counts(world)
		var capped := int(counts.get(species_id, 0)) >= world.get_reproductive_capacity(species_id)
		for territory in world.territory_registry(species_id).territories:
			var male := int(territory["male"])
			var female := int(territory["female"])
			if male == TerritoryRegistry.NOBODY or female == TerritoryRegistry.NOBODY:
				continue
			var reason := _blocker(world, female, sleepers, reproduction)
			if reason == "":
				reason = _blocker(world, male, sleepers, reproduction)
			if reason == "" and capped:
				reason = "cap"
			if reason == "":
				var asleep_female: Variant = sleepers.get(female)
				var asleep_male: Variant = sleepers.get(male)
				if asleep_female == null and asleep_male == null:
					reason = "awake"
				elif asleep_female != null and asleep_male != null and asleep_female[0] == asleep_male[0]:
					reason = "ready"
				else:
					reason = "split"
			tally[reason] = int(tally.get(reason, 0)) + 1
		pair_checks[species_id] = tally


## One animal's needs, awake or asleep: [age, cooldown, energy, hunger, thirst, sex, longevity],
## or [] when it is neither.
static func _state_of(world: WorldState, animal_id: int, sleepers: Dictionary) -> Array:
	var agent = world.get_agent(animal_id)
	if agent != null:
		return [agent.age, agent.reproduction_cooldown, agent.energy, agent.hunger, agent.thirst, agent.sex,
			agent.trait_longevity]
	if sleepers.has(animal_id):
		var record: Dictionary = sleepers[animal_id][1]
		return [float(record.get("age", 0.0)), float(record.get("reproduction_cooldown", 0.0)),
			float(record.get("energy", 0.0)), float(record.get("hunger", 0.0)), float(record.get("thirst", 0.0)),
			str(record.get("sex", AgentBase.SEX_FEMALE)), float(TraitsScript.of_record(record)[TraitsScript.LONGEVITY])]
	return []


## What keeps one animal from breeding now, "" for nothing.
static func _blocker(world: WorldState, animal_id: int, sleepers: Dictionary, reproduction: Dictionary) -> String:
	var state := _state_of(world, animal_id, sleepers)
	if state.is_empty():
		return "gone"
	if float(state[0]) < float(reproduction.get("maturity_age", 0.0)) * float(state[6]):
		return "young"
	if float(state[1]) > 0.0:
		return "cd"
	if float(state[2]) < AgentBase.breeding_energy_threshold(reproduction, str(state[5]), INF):
		return "energy"
	if float(state[3]) > float(reproduction.get("max_hunger", 100.0)):
		return "hunger"
	if float(state[4]) > float(reproduction.get("max_thirst", 100.0)):
		return "thirst"
	return ""


## The grown animals of a species: mean hunger and energy, and the share strong enough to breed
## (energy at the threshold, hunger and thirst under the limits) whatever the season.
static func _needs(world: WorldState, species_id: String) -> Dictionary:
	var reproduction: Dictionary = world.config_bundle["species"][species_id].get("reproduction", {})
	var grown := float(reproduction.get("maturity_age", 0.0))
	var hunger := 0.0
	var energy := 0.0
	var fit := 0
	var count := 0
	var states: Array = []
	for agent in world.living_agents:
		if agent != null and agent.is_alive and agent.species_type == species_id:
			states.append([agent.age, agent.energy, agent.hunger, agent.thirst, agent.sex])
	for key in world._sector_states.keys():
		for record in world._sector_states[key].get("dormant_records", []):
			if str(record.get("species_type", "")) == species_id:
				states.append([float(record.get("age", 0.0)), float(record.get("energy", 0.0)),
					float(record.get("hunger", 0.0)), float(record.get("thirst", 0.0)), str(record.get("sex", ""))])
	for state in states:
		if float(state[0]) < grown:
			continue
		count += 1
		hunger += float(state[2])
		energy += float(state[1])
		if float(state[1]) >= AgentBase.breeding_energy_threshold(reproduction, str(state[4]), INF) \
				and float(state[2]) <= float(reproduction.get("max_hunger", 100.0)) \
				and float(state[3]) <= float(reproduction.get("max_thirst", 100.0)):
			fit += 1
	var n := maxf(1.0, float(count))
	return {"hunger": hunger / n, "energy": energy / n, "fit_share": float(fit) / n, "grown": count}


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
