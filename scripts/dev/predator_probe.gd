extends SceneTree

# What predators were doing before they died. Not part of the game.
#
#   Godot --headless --path . --script res://scripts/dev/predator_probe.gd -- <seed> lod|off <seconds> <out.json> [a.b.c=value ...]
# Runs like `ecology_audit.gd` (same LOD view, same overrides) and samples every
# predator, awake or asleep, every SAMPLE seconds: needs, energy, what it was doing
# (the live state or the sleeping group's goal), and how far the nearest prey and the
# nearest carcass it may still eat were. The last HISTORY samples of each one are
# kept and written out for every predator that died, with the cause, so the lead-up
# to each death can be read back. `bands` sums the same fields by hunger band, and
# `timeline` gives once a minute the count, births so far and who could breed. This is
# what found predators starving around the LOD window and the first litters ageing as
# one cohort (see the Dormant sectors section of ARCHITECTURE.md).
const SAMPLE := 2.0
const HISTORY := 60
const SPECIES := "predator"

var _live_causes := {}
var _dormant_deaths: Array = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var run_seed := int(args[0])
	var use_lod := str(args[1]).to_lower() == "lod"
	var seconds := float(args[2])
	var out := str(args[3])
	var bundle: Dictionary = ConfigLoader.load_config_bundle(ConfigLoader.default_selection())
	# Overrides as `ecology_audit.gd` takes them: JSON values, missing sections created.
	for index in range(4, args.size()):
		var pair := str(args[index]).split("=", true, 1)
		var keys := pair[0].split(".")
		var node: Dictionary = bundle
		for k in range(keys.size() - 1):
			if not (node.get(keys[k]) is Dictionary):
				node[keys[k]] = {}
			node = node[keys[k]]
		var value: Variant = JSON.parse_string(pair[1])
		node[keys[keys.size() - 1]] = value if value != null or pair[1] == "null" else pair[1]
	var manager = preload("res://scripts/core/simulation_manager.gd").new()
	manager.initialize(bundle, run_seed)
	manager.set_lod_enabled(use_lod)
	if use_lod:
		var center: Vector2 = manager.world_state.bounds.get_center()
		manager.set_lod_view(Rect2(center - Vector2.ONE * 0.5, Vector2.ONE), center, true)
	manager.event_bus.event_emitted.connect(_on_event)
	var world = manager.world_state
	var species_config: Dictionary = bundle.species[SPECIES]
	var prey_ids: Array = species_config.role.get("eats_species", [])
	var carrion_age := float(species_config.role.get("carrion_max_age_seconds", INF))
	var sample_ticks := int(round(SAMPLE * manager.tick_rate))
	var histories := {}
	var bands := {}
	var deaths: Array = []
	var timeline: Array = []
	var total_ticks := int(ceil(seconds * manager.tick_rate))
	for tick in range(total_ticks):
		manager.step_once()
		if tick % sample_ticks != 0:
			continue
		var prey_points := PackedVector2Array()
		var carcass_points := PackedVector2Array()
		var hunters: Array = []
		for agent in world.living_agents:
			if agent == null or not agent.is_alive:
				continue
			if agent.species_type in prey_ids:
				prey_points.append(agent.position)
			elif agent.species_type == SPECIES:
				hunters.append({"id": agent.id, "live": true, "pos": agent.position, "h": agent.hunger, "th": agent.thirst,
					"e": agent.energy, "age": agent.age, "do": str(agent.state), "ai": str(agent.ai_state),
					"act": str(agent.current_action), "chasing": agent.target_agent_id != -1,
					"carcass": agent.target_carcass_id != -1, "sex": agent.sex, "cd": agent.reproduction_cooldown})
		for sector_key in world._sector_states.keys():
			var sector_state: Dictionary = world._sector_states[sector_key]
			if not bool(sector_state.get("dormant", false)):
				continue
			var goals := {}
			for aggregate in sector_state.get("dormant_aggregates", []):
				goals["%s:%d" % [str(aggregate.get("species_type", "")), int(aggregate.get("group_id", -1))]] = str(aggregate.get("goal_kind", "wander"))
			for record in sector_state.get("dormant_records", []):
				var species := str(record.get("species_type", ""))
				var position: Vector2 = record.get("position", Vector2.ZERO)
				if species in prey_ids:
					prey_points.append(position)
				elif species == SPECIES:
					hunters.append({"id": int(record.get("id", -1)), "live": false, "pos": position,
						"h": float(record.get("hunger", 0.0)), "th": float(record.get("thirst", 0.0)),
						"e": float(record.get("energy", 0.0)), "age": float(record.get("age", 0.0)),
						"do": goals.get("%s:%d" % [species, int(record.get("group_id", -1))], "?"), "ai": "", "act": "",
						"chasing": false, "carcass": false, "sex": str(record.get("sex", "")),
						"cd": float(record.get("reproduction_cooldown", 0.0))})
		for carcass in world.carcasses.values():
			if float(carcass.get("meat_remaining", 0.0)) <= 0.0:
				continue
			if world.current_time - float(carcass.get("created_at", 0.0)) > carrion_age:
				continue
			carcass_points.append(carcass.get("position", Vector2.ZERO))
		var seen := {}
		var hungry := 0
		var live_count := 0
		for hunter in hunters:
			var position: Vector2 = hunter.pos
			var row := {"t": snappedf(world.current_time, 0.1), "live": hunter.live, "h": snappedf(hunter.h, 0.1),
				"th": snappedf(hunter.th, 0.1), "e": snappedf(hunter.e, 0.1), "do": hunter.do, "ai": hunter.ai,
				"act": hunter.act, "chasing": hunter.chasing, "carcass": hunter.carcass,
				"prey_d": snappedf(_nearest(position, prey_points), 1.0), "carc_d": snappedf(_nearest(position, carcass_points), 1.0),
				"pos": [snappedf(position.x, 1.0), snappedf(position.y, 1.0)], "age": snappedf(hunter.age, 1.0)}
			seen[hunter.id] = true
			if not histories.has(hunter.id):
				histories[hunter.id] = []
			histories[hunter.id].append(row)
			if histories[hunter.id].size() > HISTORY:
				histories[hunter.id].pop_front()
			if hunter.live:
				live_count += 1
			if hunter.h >= 60.0:
				hungry += 1
			var band := "%d" % mini(4, int(hunter.h / 20.0))
			if not bands.has(band):
				bands[band] = {"n": 0, "live": 0, "do": {}, "prey_d": 0.0, "carc_d_seen": 0, "e": 0.0, "th": 0.0, "chasing": 0}
			var b: Dictionary = bands[band]
			b.n += 1
			if hunter.live:
				b.live += 1
			var key: String = ("live:" if hunter.live else "sleep:") + str(hunter.do)
			b.do[key] = int(b.do.get(key, 0)) + 1
			b.prey_d += minf(row.prey_d, 5000.0)
			if row.carc_d < 1000.0:
				b.carc_d_seen += 1
			b.e += hunter.e
			b.th += hunter.th
			if hunter.chasing:
				b.chasing += 1
		for id in histories.keys():
			if seen.has(id):
				continue
			var history: Array = histories[id]
			var last: Dictionary = history.back()
			var cause := str(_live_causes.get(id, ""))
			if cause == "":
				cause = _match_dormant_death(Vector2(last.pos[0], last.pos[1]))
			deaths.append({"id": id, "cause": cause, "time": world.current_time, "history": history})
			histories.erase(id)
		_live_causes.clear()
		_dormant_deaths.clear()
		if tick % (sample_ticks * 30) == 0:
			var breeding := _breeding_readiness(hunters, species_config.reproduction, float(species_config.perception.get("mate_search_radius", 80.0)))
			timeline.append({"t": snappedf(world.current_time, 1.0), "predators": hunters.size(), "live": live_count,
				"hungry": hungry, "prey": prey_points.size(), "fresh_carcasses": carcass_points.size(),
				"births": int(manager.stats_system.counters.get("births_%s" % SPECIES, 0)),
				"capacity": world.get_reproductive_capacity(SPECIES), "breeding": breeding})
			print("t=%.0f predators=%d live=%d hungry=%d prey=%d deaths=%d" % [world.current_time, hunters.size(), live_count, hungry, prey_points.size(), deaths.size()])
	var result := {"bands": bands, "deaths": deaths, "timeline": timeline, "counters": manager.stats_system.counters}
	var file := FileAccess.open(out, FileAccess.WRITE)
	file.store_string(JSON.stringify(result))
	file.close()
	print("done ", out, " deaths ", deaths.size())
	manager.free()
	quit()


func _on_event(event: Dictionary) -> void:
	if str(event.get("type", "")) != "AgentDied" or str(event.get("species", "")) != SPECIES:
		return
	var data: Dictionary = event.get("data", {})
	if int(event.get("agent_id", -1)) != -1:
		_live_causes[int(event.agent_id)] = str(data.get("cause", ""))
	else:
		var position: Dictionary = event.get("position", {})
		_dormant_deaths.append({"pos": Vector2(float(position.get("x", 0.0)), float(position.get("y", 0.0))), "cause": str(data.get("cause", ""))})


## Who could breed right now, and what stops the rest: each failed condition of
## `AgentBase.can_reproduce()` is counted once per animal it stops. `matched` counts ready
## females with a ready male within `mate_search_radius`; `partnered` counts animals of
## either sex with one of the other within that radius, ready or not, and `alone` those
## with no animal of their species within it.
func _breeding_readiness(hunters: Array, reproduction: Dictionary, mate_radius: float) -> Dictionary:
	var result := {"ready_female": 0, "ready_male": 0, "matched": 0, "young": 0, "cooldown": 0, "energy": 0, "hunger": 0, "thirst": 0,
		"partnered": 0, "alone": 0, "males": 0, "females": 0, "male_energy": 0, "male_cooldown": 0, "male_age": 0.0, "female_age": 0.0}
	var males := PackedVector2Array()
	var females := PackedVector2Array()
	for hunter in hunters:
		if str(hunter.sex) == AgentBase.SEX_MALE:
			males.append(hunter.pos)
			result.males += 1
			result.male_age += float(hunter.age)
			if float(hunter.e) < float(reproduction.get("energy_threshold", INF)):
				result.male_energy += 1
			if float(hunter.cd) > 0.0:
				result.male_cooldown += 1
		else:
			females.append(hunter.pos)
			result.females += 1
			result.female_age += float(hunter.age)
	result.male_age = snappedf(result.male_age / maxf(1.0, float(result.males)), 1.0)
	result.female_age = snappedf(result.female_age / maxf(1.0, float(result.females)), 1.0)
	for hunter in hunters:
		var is_male := str(hunter.sex) == AgentBase.SEX_MALE
		if _nearest(hunter.pos, females if is_male else males) <= mate_radius:
			result.partnered += 1
		var own := males if is_male else females
		var others := 0
		for point in own:
			if point.distance_to(hunter.pos) <= mate_radius:
				others += 1
		if others <= 1 and _nearest(hunter.pos, females if is_male else males) > mate_radius:
			result.alone += 1
	var ready_males := PackedVector2Array()
	var ready_females := PackedVector2Array()
	for hunter in hunters:
		var ready := true
		if float(hunter.age) < float(reproduction.get("maturity_age", 0.0)):
			result.young += 1
			ready = false
		if float(hunter.cd) > 0.0:
			result.cooldown += 1
			ready = false
		if float(hunter.e) < float(reproduction.get("energy_threshold", INF)):
			result.energy += 1
			ready = false
		if float(hunter.h) > float(reproduction.get("max_hunger", 100.0)):
			result.hunger += 1
			ready = false
		if float(hunter.th) > float(reproduction.get("max_thirst", 100.0)):
			result.thirst += 1
			ready = false
		if not ready:
			continue
		if str(hunter.sex) == AgentBase.SEX_MALE:
			result.ready_male += 1
			ready_males.append(hunter.pos)
		else:
			result.ready_female += 1
			ready_females.append(hunter.pos)
	for female in ready_females:
		if _nearest(female, ready_males) <= mate_radius:
			result.matched += 1
	return result


## The cause of the sleeping death reported nearest where the animal was last seen.
## Sleeping deaths carry no id, so this pairs them by place within one sample.
func _match_dormant_death(position: Vector2) -> String:
	var best := -1
	var best_distance := INF
	for index in range(_dormant_deaths.size()):
		var distance := position.distance_to(_dormant_deaths[index].pos)
		if distance < best_distance:
			best = index
			best_distance = distance
	if best < 0:
		return "unknown"
	var cause := str(_dormant_deaths[best].cause) + ":asleep"
	_dormant_deaths.remove_at(best)
	return cause


func _nearest(position: Vector2, points: PackedVector2Array) -> float:
	var best := INF
	for point in points:
		best = minf(best, position.distance_squared_to(point))
	return sqrt(best) if best < INF else 99999.0
