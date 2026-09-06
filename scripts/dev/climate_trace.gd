extends SceneTree

# Throwaway: runs two simulated years and reports whether the seasons actually
# move the population, the grass and the herd's behaviour. Delete when verified.

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var years := float(args[0]) if args.size() > 0 else 2.0
	var climate_on := args.size() < 2 or args[1] != "off"
	var bundle := ConfigLoader.load_config_bundle()
	# Shipped world and spawns. An earlier scaled-down variant was abandoned:
	# halving the map and quartering the agents preserves density but not the
	# ecology, and that world starves its herbivores out with grass at the cap
	# whether the climate is on or off - so it could say nothing about seasons.
	bundle["world"]["climate"]["enabled"] = climate_on
	print("climate=%s" % ("on" if climate_on else "off"))
	var manager = preload("res://scripts/core/simulation_manager.gd").new()
	root.add_child(manager)
	manager.initialize(bundle, 3)
	var world = manager.world_state
	var climate = world.climate
	print("season  clock  night  regrow  metab  vision |  herb  pred  grass%%  rest%%  graze%%  starv")
	var total_ticks := int(480.0 * years * manager.tick_rate)
	var report_every := int(30.0 * manager.tick_rate)
	var initial_grass: float = world.resource_system.get_total_biomass()
	for i in range(total_ticks + 1):
		if i % report_every == 0:
			var snap: Dictionary = manager.stats_system.get_snapshot()
			var resting := 0
			var grazing := 0
			var alive := 0
			for a in world.living_agents:
				if a == null or not a.is_alive or a.species_type != "herbivore":
					continue
				alive += 1
				if a.state == "rest":
					resting += 1
				elif a.state == "eat":
					grazing += 1
			print("%-6s  %s  %5.2f  %6.3f  %5.3f  %6.3f | %5d %5d  %5.1f  %5.1f  %6.1f  %5d" % [
				climate.season_id, climate.clock_text(), climate.night_ratio,
				climate.regrowth_multiplier, climate.metabolism_multiplier, climate.perception_multiplier,
				int(snap.get("herbivore_population", 0)), int(snap.get("predator_population", 0)),
				100.0 * world.resource_system.get_total_biomass() / maxf(1.0, initial_grass),
				0.0 if alive == 0 else 100.0 * float(resting) / float(alive),
				0.0 if alive == 0 else 100.0 * float(grazing) / float(alive),
				int(snap.get("deaths_starvation", 0)),
			])
		manager.step_once()
	quit()
