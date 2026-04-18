extends SceneTree

const ConfigLoaderScript = preload("res://scripts/core/config_loader.gd")
const SimulationManagerScript = preload("res://scripts/core/simulation_manager.gd")


func _initialize() -> void:
	var args: Array = OS.get_cmdline_user_args()
	var profile := "current"
	var total_ticks := 240
	if args.size() >= 1 and str(args[0]) != "":
		profile = str(args[0])
	if args.size() >= 2:
		total_ticks = maxi(1, int(args[1]))

	var simulation_manager = SimulationManagerScript.new()
	root.add_child(simulation_manager)
	simulation_manager.initialize(_build_profile_bundle(profile), -1)
	var result := simulation_manager.run_headless(total_ticks, false)
	print("Headless benchmark profile=%s ticks=%d snapshot=%s" % [
		profile,
		total_ticks,
		JSON.stringify(result.get("snapshot", {})),
	])
	root.remove_child(simulation_manager)
	simulation_manager.shutdown()
	simulation_manager.free()
	await process_frame
	quit()


func _build_profile_bundle(profile: String) -> Dictionary:
	var bundle: Dictionary = ConfigLoaderScript.load_config_bundle().duplicate(true)
	match profile:
		"current":
			bundle["world"]["spawns"] = {
				"herbivore_count": 220,
				"predator_count": 18,
				"herbivore_group_count": 12,
			}
		"750":
			bundle["world"]["spawns"] = {
				"herbivore_count": 690,
				"predator_count": 60,
				"herbivore_group_count": 24,
			}
		"1500":
			bundle["world"]["spawns"] = {
				"herbivore_count": 1380,
				"predator_count": 120,
				"herbivore_group_count": 40,
			}
		_:
			push_error("Unknown benchmark profile: %s" % profile)
	return bundle
