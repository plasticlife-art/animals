extends SceneTree

# Throwaway diagnostic: runs the simulation headless and prints the distribution
# of hunger and of chosen actions, because averages hid a bimodal population -
# mean hunger sat at 29 while a tail of animals starved to death at 100.

var _water_count := 0
var _stats = null


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var ticks := int(args[0]) if args.size() > 0 else 900
	var selection := {}
	for index in range(1, args.size()):
		var pair: PackedStringArray = str(args[index]).split("=")
		if pair.size() == 2:
			selection[pair[0]] = pair[1]
	var bundle := ConfigLoader.load_config_bundle(selection)
	bundle["debug"]["lod"]["enabled"] = false
	var manager = preload("res://scripts/core/simulation_manager.gd").new()
	root.add_child(manager)
	manager.initialize(bundle, int(bundle["world"].get("seed", 3)))
	print("world %s cell %s spawns %s" % [
		bundle["world"]["world_size"], bundle["world"]["terrain"]["cell_size"],
		bundle["world"]["spawns"]])
	_water_count = manager.world_state.water_sources.size()
	_stats = manager.stats_system
	var report_at := [300, 600, 900, 1200, 1500, 2000, 2500, 3000]
	for tick in range(1, ticks + 1):
		manager.step_once()
		if tick in report_at:
			_report(manager, tick)
	quit(0)


func _report(manager, tick: int) -> void:
	var world = manager.world_state
	var buckets := PackedInt32Array([0, 0, 0, 0, 0])
	var actions := {}
	var states := {}
	var herbivores := 0
	for agent in world.get_living_agents():
		if agent.species_type != "herbivore":
			continue
		herbivores += 1
		buckets[clampi(int(agent.hunger / 20.0), 0, 4)] += 1
		var action := str(agent.current_action)
		actions[action] = int(actions.get(action, 0)) + 1
		var st := str(agent.ai_state)
		states[st] = int(states.get(st, 0)) + 1
	print("tick %d  herbivores %d  hunger buckets 0-20:%d 20-40:%d 40-60:%d 60-80:%d 80-100:%d" % [
		tick, herbivores, buckets[0], buckets[1], buckets[2], buckets[3], buckets[4]])
	print("    actions %s" % [actions])
	print("    crowding %s" % [_crowding(world)])
	# Feeding rate per herbivore per tick. The counters reset every tick despite
	# their "_total" names, so this is an instantaneous rate, not a lifetime sum.
	var consumed := float(world.performance_counters.get("grass_consumed_total", 0.0))
	print("    fed %.3f  water %d  thirst-deaths %d  starve-deaths %d" % [
		consumed / maxf(1.0, float(herbivores)), _water_count,
		int(_stats.counters.get("deaths_thirst", 0)), int(_stats.counters.get("deaths_starvation", 0))])


func _eating(world) -> int:
	var count := 0
	for agent in world.get_living_agents():
		if str(agent.state) == "eat":
			count += 1
	return count


## Nearest-neighbour spacing. Reported as a distribution because the mean hides
## exactly the thing being measured: a few isolated animals lift it while a
## packed herd sits far below it.
func _crowding(world) -> String:
	var living: Array = world.get_living_agents()
	var distances: Array = []
	for agent in living:
		var best := INF
		for other in living:
			if other.id == agent.id:
				continue
			var d: float = agent.position.distance_to(other.position)
			if d < best:
				best = d
		if best < INF:
			distances.append(best)
	if distances.is_empty():
		return "n/a"
	distances.sort()
	var overlapping: int = 0
	for d in distances:
		if d < 27.0:
			overlapping += 1
	return "median %.1f  p10 %.1f  closer-than-sprite %.0f%%" % [
		distances[distances.size() / 2], distances[distances.size() / 10],
		100.0 * float(overlapping) / float(distances.size())]
