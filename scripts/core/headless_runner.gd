class_name HeadlessRunner
extends Node

@export var total_ticks: int = 3600
@export var seed_override: int = -1
@export var export_on_finish: bool = true
@export var benchmark_profile: String = ""

const SimulationManagerScript = preload("res://scripts/core/simulation_manager.gd")
const ConfigLoaderScript = preload("res://scripts/core/config_loader.gd")


func _ready() -> void:
	call_deferred("_run_headless")


func _run_headless() -> void:
	var simulation_manager = SimulationManagerScript.new()
	add_child(simulation_manager)
	var config_override := _build_profile_override()
	simulation_manager.initialize(config_override, seed_override)
	var result := simulation_manager.run_headless(total_ticks, export_on_finish)
	print("Headless run completed: ", result)
	remove_child(simulation_manager)
	simulation_manager.shutdown()
	simulation_manager.free()
	await get_tree().process_frame
	get_tree().quit()


func _build_profile_override() -> Dictionary:
	if benchmark_profile == "":
		return {}
	var bundle: Dictionary = ConfigLoaderScript.load_config_bundle().duplicate(true)
	match benchmark_profile:
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
			return {}
	return bundle
