extends SceneTree

# How early a hunt and a birth can be seen coming, for the reserve's camera. Not part of the game.
#
#   Godot --headless --path . --script res://scripts/dev/director_probe.gd -- <seed> <seconds> <out.json>
# Runs the reserve's world (its selection, all awake) and every SAMPLE seconds notes for each
# hunter whether it is hungry enough to hunt and able to (not hunting yet, not at a carcass), on
# patrol besides, and how near its nearest prey is, and for every animal whether it is going to a
# mate. At each hunt's start
# (`HuntStarted`, the first of an episode) and each birth (`AgentReproduced`) it reads back how
# long each sign had held: the lead a camera would have had. And for each sign's start, whether
# the event followed within WINDOW seconds: how often the sign is right.
const SAMPLE := 0.5
const WINDOW := 25.0
const RADII := [700.0, 1000.0, 1400.0]
const HUNTERS := ["predator", "wolf"]
const HUNTING := ["seek_prey", "chase", "flank", "attack", "search_last_seen"]
const AT_CARCASS := ["seek_carcass", "feed_carcass"]

var _now := 0.0
var _hunts: Array = []
var _births: Array = []
var _open: Dictionary = {}
var _signs: Dictionary = {}
var _onsets: Array = []
var _repro_since: Dictionary = {}
var _repro_onsets: Array = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var run_seed := int(args[0])
	var seconds := float(args[1])
	var out := str(args[2])
	var reserve: Dictionary = ConfigLoader._load_json("res://data/config/reserve.json")
	var bundle: Dictionary = ConfigLoader.load_reserve_bundle(reserve)
	var manager = preload("res://scripts/core/simulation_manager.gd").new()
	manager.initialize(bundle, run_seed)
	manager.set_lod_enabled(false)
	manager.event_bus.event_emitted.connect(_on_event)
	var world = manager.world_state
	var sample_ticks := int(round(SAMPLE * manager.tick_rate))
	var total_ticks := int(ceil(seconds * manager.tick_rate))
	for tick in range(total_ticks):
		manager.step_once()
		_now = world.current_time
		if tick % sample_ticks == 0:
			_sample(world)
	var report := {"seed": run_seed, "seconds": seconds, "hunts": _hunt_summary(), "births": _birth_summary(),
		"sign_precision": _precision()}
	var file := FileAccess.open(out, FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print(JSON.stringify(report, "  "))
	quit()


func _sample(world) -> void:
	var prey_by_hunter := {}
	for species in HUNTERS:
		prey_by_hunter[species] = PackedVector2Array()
	for agent in world.living_agents:
		if agent == null or not agent.is_alive:
			continue
		for species in HUNTERS:
			if world.species_registry.prey_set(species).has(agent.species_type):
				prey_by_hunter[species].append(agent.position)
		var going: bool = str(agent.state) == "reproduce" and agent.target_agent_id >= 0
		if going and not _repro_since.has(agent.id):
			_repro_since[agent.id] = _now
			_repro_onsets.append({"id": agent.id, "at": _now})
		elif not going:
			_repro_since.erase(agent.id)
	for agent in world.living_agents:
		if agent == null or not agent.is_alive or not HUNTERS.has(agent.species_type):
			continue
		var state := str(agent.state)
		var hungry: bool = not HUNTING.has(state) and not AT_CARCASS.has(state) and agent.is_feeding_allowed() \
			and agent.energy > float(agent.hunt.get("min_chase_energy", 0.0))
		var patrol: bool = hungry and state == "patrol"
		var nearest := INF
		for point in prey_by_hunter[agent.species_type]:
			nearest = minf(nearest, agent.position.distance_to(point))
		var signs: Dictionary = _signs.get(agent.id, {})
		_hold(agent.id, signs, "hungry", hungry)
		_hold(agent.id, signs, "patrol", patrol)
		for radius in RADII:
			_hold(agent.id, signs, "near_%d" % int(radius), hungry and nearest <= radius)
			_hold(agent.id, signs, "patrol_%d" % int(radius), patrol and nearest <= radius)
		_signs[agent.id] = signs


func _hold(id: int, signs: Dictionary, key: String, on: bool) -> void:
	if on and not signs.has(key):
		signs[key] = _now
		_onsets.append({"id": id, "sign": key, "at": _now})
	elif not on:
		signs.erase(key)


func _on_event(event: Dictionary) -> void:
	var kind := str(event.get("type", ""))
	var id := int(event.get("agent_id", -1))
	var at := float(event.get("time_seconds", _now))
	match kind:
		"HuntStarted":
			if HUNTERS.has(str(event.get("species", ""))) and not _open.has(id):
				var leads := {}
				for key in _signs.get(id, {}).keys():
					leads[key] = at - float(_signs[id][key])
				_open[id] = {"id": id, "species": str(event["species"]), "at": at, "leads": leads}
		"PredationSuccess", "PredationFailed":
			if _open.has(id):
				var hunt: Dictionary = _open[id]
				hunt["length"] = at - float(hunt["at"])
				hunt["caught"] = kind == "PredationSuccess"
				_hunts.append(hunt)
				_open.erase(id)
		"AgentReproduced":
			var data: Dictionary = event.get("data", {})
			var lead := -1.0
			for key in ["parent_a_id", "parent_b_id"]:
				var parent := int(data.get(key, -1))
				if _repro_since.has(parent):
					lead = maxf(lead, at - float(_repro_since[parent]))
			_births.append({"species": str(event.get("species", "")), "at": at, "lead": lead,
				"parents": [int(data.get("parent_a_id", -1)), int(data.get("parent_b_id", -1))]})


static func _percentiles(values: Array) -> Dictionary:
	if values.is_empty():
		return {"n": 0}
	var sorted := values.duplicate()
	sorted.sort()
	var pick := func(q: float) -> float: return snappedf(float(sorted[clampi(int(q * (sorted.size() - 1)), 0, sorted.size() - 1)]), 0.1)
	return {"n": sorted.size(), "p10": pick.call(0.1), "p25": pick.call(0.25), "p50": pick.call(0.5), "p75": pick.call(0.75),
		"p90": pick.call(0.9)}


func _hunt_summary() -> Dictionary:
	var by_species := {}
	for hunt in _hunts:
		var species := str(hunt["species"])
		if not by_species.has(species):
			by_species[species] = {"length": [], "caught": 0, "leads": {}}
		var entry: Dictionary = by_species[species]
		entry["length"].append(float(hunt["length"]))
		entry["caught"] += 1 if bool(hunt["caught"]) else 0
		for key in ["hungry", "patrol"] + RADII.map(func(r): return "near_%d" % int(r)) + RADII.map(func(r): return "patrol_%d" % int(r)):
			if not entry["leads"].has(key):
				entry["leads"][key] = []
			entry["leads"][key].append(float(hunt["leads"].get(key, 0.0)))
	var summary := {}
	for species in by_species.keys():
		var entry: Dictionary = by_species[species]
		var leads := {}
		for key in entry["leads"].keys():
			leads[key] = _percentiles(entry["leads"][key])
		summary[species] = {"hunts": entry["length"].size(), "caught": entry["caught"], "length": _percentiles(entry["length"]),
			"lead": leads}
	return summary


func _birth_summary() -> Dictionary:
	var by_species := {}
	for birth in _births:
		var species := str(birth["species"])
		if not by_species.has(species):
			by_species[species] = {"leads": [], "unsigned": 0}
		if float(birth["lead"]) < 0.0:
			by_species[species]["unsigned"] += 1
		else:
			by_species[species]["leads"].append(float(birth["lead"]))
	var summary := {}
	for species in by_species.keys():
		summary[species] = {"births": by_species[species]["leads"].size() + by_species[species]["unsigned"],
			"no_sign": by_species[species]["unsigned"], "lead": _percentiles(by_species[species]["leads"])}
	return summary


## For each sign's start, whether its event followed within WINDOW: a hunt by the same hunter,
## a birth with it for a parent. Starts too near the end to tell are left out.
func _precision() -> Dictionary:
	var hunt_starts := {}
	for hunt in _hunts:
		if not hunt_starts.has(int(hunt["id"])):
			hunt_starts[int(hunt["id"])] = []
		hunt_starts[int(hunt["id"])].append(float(hunt["at"]))
	for hunt in _open.values():
		if not hunt_starts.has(int(hunt["id"])):
			hunt_starts[int(hunt["id"])] = []
		hunt_starts[int(hunt["id"])].append(float(hunt["at"]))
	var result := {}
	for onset in _onsets:
		if float(onset["at"]) > _now - WINDOW:
			continue
		var key := str(onset["sign"])
		if not result.has(key):
			result[key] = {"starts": 0, "followed": 0, "wait": []}
		result[key]["starts"] += 1
		for start in hunt_starts.get(int(onset["id"]), []):
			if float(start) >= float(onset["at"]) and float(start) - float(onset["at"]) <= WINDOW:
				result[key]["followed"] += 1
				result[key]["wait"].append(float(start) - float(onset["at"]))
				break
	var birth_by_parent := {}
	for birth in _births:
		for parent in birth["parents"]:
			if not birth_by_parent.has(int(parent)):
				birth_by_parent[int(parent)] = []
			birth_by_parent[int(parent)].append(float(birth["at"]))
	var going := {"starts": 0, "followed": 0, "wait": []}
	for onset in _repro_onsets:
		if float(onset["at"]) > _now - WINDOW:
			continue
		going["starts"] += 1
		for at in birth_by_parent.get(int(onset["id"]), []):
			if float(at) >= float(onset["at"]) and float(at) - float(onset["at"]) <= WINDOW:
				going["followed"] += 1
				going["wait"].append(float(at) - float(onset["at"]))
				break
	result["reproduce"] = going
	for key in result.keys():
		result[key]["wait"] = _percentiles(result[key]["wait"])
	return result
